# Regression tests for FIXED open Pkg.jl issues, discovered by auditing
# https://github.com/JuliaLang/Pkg.jl/issues against VibePkg. Each @testset
# pins the *correct* (fixed) behavior for one issue so a future regression
# fails. See test/PKG_ISSUES_AUDIT.md for the full audit (persists/fixed per
# issue). Every testset here is self-contained (offline, Example fixture or a
# synthetic local package) — no network.
#
# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()
using Test
using Base: UUID
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries
using VibePkg.Environments: load_environment, write_environment
using VibePkg.Planning
using VibePkg.Planning: PackageRequest
using VibePkg.EnvFiles: entry_version, is_path_tracked, is_registry_tracked
using VibePkg.Errors: PkgError
if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

# Windows-safe interpolation: TOML basic strings treat `\` as an escape and
# file:// URLs need /-separated absolute paths, so slash any temp path that
# gets spliced into a TOML string or URL.
slashpath(p::AbstractString) = replace(p, '\\' => '/')
function file_url(p::AbstractString)
    p = slashpath(p)
    return startswith(p, '/') ? "file://" * p : "file:///" * p
end

@testset "Pkg.jl#4688 precompile/instantiate after [sources] path->url switch" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)

        # A synthetic local package tracked by `develop` path.
        devuuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        devdir = mkpath(joinpath(dir, "DevEx"))
        write(
            joinpath(devdir, "Project.toml"),
            """
            name = "DevEx"
            uuid = "$devuuid"
            version = "0.1.0"
            """,
        )
        mkpath(joinpath(devdir, "src"))
        write(joinpath(devdir, "src", "DevEx.jl"), "module DevEx\nend\n")

        projfile = joinpath(mkpath(joinpath(dir, "proj")), "Project.toml")

        old = copy(Base.DEPOT_PATH)
        oldp = Base.ACTIVE_PROJECT[]
        oldg = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = projfile

            # develop DevEx by path: records a `[sources] {path=...}` entry and a
            # path-tracked manifest entry.
            VibePkg.develop(; path = devdir, io = devnull)
            env = load_environment(; depots = depot_stack([depot]))
            @test is_path_tracked(env.manifest[UUID(devuuid)])

            # Hand-edit `[sources]` from a path to a url WITHOUT reinstantiating,
            # leaving a stale path-tracked manifest. This is the exact state that
            # crashed old Pkg with `MethodError joinpath(::Nothing)`.
            write(
                projfile,
                """
                [deps]
                DevEx = "$devuuid"

                [sources]
                DevEx = {url = "https://example.com/DevEx.jl.git"}
                """,
            )

            # The fixed behavior: both operations complete cleanly (no MethodError).
            @test VibePkg.instantiate(io = devnull) === nothing
            @test VibePkg.precompile(io = devnull) === nothing

            # The stale path-tracked source is still honored (url in [sources] is
            # inert until a re-resolve), so the manifest entry is unchanged.
            env2 = load_environment(; depots = depot_stack([depot]))
            @test is_path_tracked(env2.manifest[UUID(devuuid)])
        finally
            copy!(Base.DEPOT_PATH, old)
            Base.ACTIVE_PROJECT[] = oldp
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldg
        end
    end
end

@testset "Pkg.jl#4676 [sources] SCP-like URL with non-git user" begin
    isurl = VibePkg.Utils.isurl
    # SCP-like URLs from non-standard hosts with a non-`git` user are URLs.
    @test isurl("deploy@ghe.example.com:org/A.git") == true
    @test isurl("ci-bot@internal-git.corp:team/pkg.git") == true
    # And plain paths are NOT mistaken for URLs.
    @test isurl("../local/path") == false
    @test isurl("/abs/local/path") == false

    # End-to-end: a [sources] entry with such a URL parses as `url` (not `path`)
    # and round-trips through write/read verbatim (no path normalization).
    scp_url = "deploy@ghe.example.com:org/A.git"
    toml = """
    name = "Root"
    uuid = "$(UUID(1))"

    [deps]
    A = "$(UUID(2))"

    [sources]
    A = {url = "$scp_url"}
    """
    proj = VibePkg.EnvFiles.read_project(IOBuffer(toml))
    src = proj.sources["A"]
    @test src.url == scp_url
    @test src.path === nothing
    @test isurl(src.url) == true

    # write -> read round-trip preserves the URL string unchanged.
    io = IOBuffer()
    VibePkg.EnvFiles.write_project(io, proj)
    seekstart(io)
    proj2 = VibePkg.EnvFiles.read_project(io)
    @test proj2.sources["A"].url == scp_url
    @test proj2.sources["A"].path === nothing
end

@testset "Pkg.jl#4675 two @version pkgs add without subdir error" begin
    VibePkg.REPLMode.TEST_MODE[] = true
    try
        capture(s) = only(VibePkg.REPLMode.do_cmd(s))
        # Reported MWE: `add Example@0.1 Scratch@0.1` erroneously threw
        # "Package name/uuid must precede subdir specifier". It must now parse
        # cleanly into two package specs, each at its requested version.
        api, args, _ = capture("add Example@0.1 Scratch@0.1")
        @test api === VibePkg.API.add
        @test length(args[1]) == 2
        @test args[1][1].name == "Example" && args[1][1].version == "0.1"
        @test args[1][2].name == "Scratch" && args[1][2].version == "0.1"
    finally
        VibePkg.REPLMode.TEST_MODE[] = false
    end
end

@testset "Pkg.jl#4668 concurrent install mv guard" begin
    mv = VibePkg.Utils.mv_temp_dir_retries
    mktempdir() do dir
        # Case 1: target already exists because a concurrent installer won the
        # race. The loser's rename-into-place must be a no-op SUCCESS (isdir
        # wins), NOT a "could not open ... for writing: Permission denied" throw.
        src1 = mkpath(joinpath(dir, "src1"))
        write(joinpath(src1, "loser.txt"), "loser")
        winner = mkpath(joinpath(dir, "target"))
        write(joinpath(winner, "installed.txt"), "winner")
        @test mv(src1, winner; set_permissions = false) === nothing
        # The winner's install is preserved: the loser did not clobber it.
        @test isdir(winner)
        @test read(joinpath(winner, "installed.txt"), String) == "winner"
        @test !ispath(joinpath(winner, "loser.txt"))

        # Case 2: a genuine move into a non-existent target still succeeds and
        # relocates the payload (the guard did not break the normal path).
        src2 = mkpath(joinpath(dir, "src2"))
        write(joinpath(src2, "payload.txt"), "hello")
        dest = joinpath(dir, "newtarget")
        @test !ispath(dest)
        @test mv(src2, dest; set_permissions = false) === nothing
        @test isdir(dest)
        @test read(joinpath(dest, "payload.txt"), String) == "hello"
    end
end

@testset "Pkg.jl#4659 dev source missing errors cleanly" begin
    BB = UUID("12345678-1234-1234-1234-123456789012")
    mktempdir() do depot
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            # Project has a [sources] git entry for BaseBenchmarks (as in the report),
            # while the Manifest tracks it by a path that does not exist.
            write(
                joinpath(envdir, "Project.toml"), """
                [deps]
                BaseBenchmarks = "$BB"

                [sources]
                BaseBenchmarks = { url = "https://github.com/JuliaCI/BaseBenchmarks.jl", rev = "master" }
                """
            )
            missing_path = joinpath(dir, "does_not_exist", "BaseBenchmarks")
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "$VERSION"
                manifest_format = "2.0"

                [[deps.BaseBenchmarks]]
                path = "$(slashpath(missing_path))"
                uuid = "$BB"
                version = "0.1.0"
                """
            )
            env = load_environment(envdir; depots)
            # The path-tracked entry must be recognised as such...
            @test is_path_tracked(env.manifest[BB])
            # ...and instantiate must report a clean, typed error (not an internal
            # MethodError) naming the missing path.
            err = try
                VibePkg.Execution.instantiate!(env, regs, Config(depots); io = devnull)
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin(r"Package .* is expected at path", sprint(showerror, err))

            # Conflict variant from the report: the manifest entry ALSO carries a
            # repo url and a git-tree-sha1 alongside the (missing) path. `path`
            # must still win at parse and produce the same clean PkgError rather
            # than crashing an @assert / MethodError.
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "$VERSION"
                manifest_format = "2.0"

                [[deps.BaseBenchmarks]]
                path = "~/.julia/dev/BaseBenchmarks"
                repo-url = "https://github.com/JuliaCI/BaseBenchmarks.jl"
                git-tree-sha1 = "0000000000000000000000000000000000000000"
                uuid = "$BB"
                version = "0.1.0"
                """
            )
            env2 = load_environment(envdir; depots)
            @test is_path_tracked(env2.manifest[BB])
            err2 = try
                VibePkg.Execution.instantiate!(env2, regs, Config(depots); io = devnull)
                nothing
            catch e
                e
            end
            @test err2 isa PkgError
            @test occursin(r"Package .* is expected at path", sprint(showerror, err2))
        end
    end
end

@testset "Pkg.jl#4654 versioned add overrides a pin" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            cfg = Config(depots)
            # add Example (resolves to newest non-yanked 0.5.1), then pin it
            env = plan_add(env, regs, cfg, [PackageRequest("Example", nothing, nothing)])
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"
            env = plan_pin(env, regs, cfg, [PackageRequest("Example", nothing, nothing)])
            @test env.manifest[EXAMPLE_UUID].pinned == true
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"
            # add a DIFFERENT version than the pin: must honor the explicit
            # request (move to 0.5.0, drop the pin), not silently keep 0.5.1
            planned = plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.0")])
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.0"
            @test planned.manifest[EXAMPLE_UUID].pinned == false
        end
    end
end

@testset "Pkg.jl#4650 dev over registry entry drops tree-hash, no write assert" begin
    import TOML
    using VibePkg.EnvFiles: entry_tree_hash, entry_path, parse_manifest, render_manifest

    # --- Plan level: add (registry-tracked) then develop a local copy ---
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            # local checkout carrying the registered Example name/uuid
            devex = joinpath(dir, "Example")
            mkpath(joinpath(devex, "src"))
            write(
                joinpath(devex, "Project.toml"), """
                name = "Example"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.0"
                """
            )
            write(joinpath(devex, "src", "Example.jl"), "module Example end\n")

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)

            # 1) registry-tracked: gets a tree-hash and no path
            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1")])
            reg_entry = env.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(reg_entry)
            @test entry_tree_hash(reg_entry) !== nothing
            @test entry_path(reg_entry) === nothing

            # 2) develop the local copy over the very same uuid: must become
            #    path-tracked and shed the tree-hash (can't hold both).
            planned = plan_develop(env, regs, Config(depots), devex)
            dev_entry = planned.manifest[EXAMPLE_UUID]
            @test is_path_tracked(dev_entry)
            @test entry_path(dev_entry) !== nothing
            @test entry_tree_hash(dev_entry) === nothing   # tree-hash dropped

            # 3) persisting must NOT hit the old write_manifest @assert, and the
            #    round-trip must preserve path-tracking with no tree-hash.
            write_environment(env, planned)            # no AssertionError
            env2 = load_environment(envdir; depots)
            rt = env2.manifest[EXAMPLE_UUID]
            @test is_path_tracked(rt)
            @test entry_tree_hash(rt) === nothing
            @test !occursin("git-tree-sha1", render_manifest(env2.manifest))
        end
    end

    # --- Unit level: parse a raw entry that carries BOTH path and
    #     git-tree-sha1; repair-at-parse must yield PathTracked/no tree-hash ---
    text = """
    manifest_format = "2.0"

    [[deps.Example]]
    path = "/some/local/Example"
    git-tree-sha1 = "2222222222222222222222222222222222222222"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    version = "0.5.0"
    """
    m = parse_manifest(TOML.parse(text), "test")
    e = m[EXAMPLE_UUID]
    @test is_path_tracked(e)
    @test entry_path(e) !== nothing
    @test entry_tree_hash(e) === nothing
    # and re-rendering the repaired entry no longer writes a conflicting hash
    @test !occursin("git-tree-sha1", render_manifest(m))
end

@testset "Pkg.jl#4644 dev pkg new dep reflected in manifest" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            foodir = joinpath(dir, "Foo")
            mkpath(joinpath(foodir, "src"))
            foo_uuid = UUID("11111111-1111-1111-1111-111111111111")
            write(
                joinpath(foodir, "Project.toml"),
                "name = \"Foo\"\nuuid = \"$foo_uuid\"\nversion = \"0.1.0\"\n"
            )
            write(joinpath(foodir, "src", "Foo.jl"), "module Foo\nend\n")

            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)

            # dev Foo (no deps) into the global-like env, persist + reload
            planned = plan_develop(env0, regs, cfg, foodir)
            write_environment(env0, planned)
            env1 = load_environment(envdir; depots)
            @test is_path_tracked(env1.manifest[foo_uuid])
            @test isempty(env1.manifest[foo_uuid].deps)
            @test !haskey(env1.manifest, EXAMPLE_UUID)

            # add Example as a dep to Foo's on-disk Project.toml (with compat)
            write(
                joinpath(foodir, "Project.toml"),
                "name = \"Foo\"\nuuid = \"$foo_uuid\"\nversion = \"0.1.0\"\n\n" *
                    "[deps]\nExample = \"$EXAMPLE_UUID\"\n\n" *
                    "[compat]\nExample = \"0.5\"\n"
            )

            # re-resolve: env must pick up the dev pkg's updated dep list,
            # not the stale manifest deps (the reported #4644 bug).
            env2 = plan_resolve(env1, regs, cfg)
            write_environment(env1, env2)
            env3 = load_environment(envdir; depots)

            @test haskey(env3.manifest[foo_uuid].deps, "Example")
            @test haskey(env3.manifest, EXAMPLE_UUID)
            @test entry_version(env3.manifest[EXAMPLE_UUID]) == v"0.5.1"
        end
    end
end

@testset "Pkg.jl#4636 symlinked relative dev path preserved" begin
    if Sys.iswindows()
        # relative symlinks require privileges on Windows; skip there
        @test_skip true
    else
        mktempdir() do depot
            make_test_registry(depot)
            depots = depot_stack([depot]); regs = reachable_registries(depots)
            mktempdir() do dir
                dir = realpath(dir)
                local entry_path = VibePkg.EnvFiles.entry_path
                mypkg_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                # the REAL package lives outside the env, under dir/store/MyPkg
                storedir = joinpath(dir, "store", "MyPkg")
                mkpath(storedir)
                write(
                    joinpath(storedir, "Project.toml"), """
                    name = "MyPkg"
                    uuid = "$mypkg_uuid"
                    version = "0.1.0"
                    """
                )
                # env with a project-root RELATIVE symlink packages/MyPkg -> ../../store/MyPkg
                envdir = mkpath(joinpath(dir, "env"))
                write(joinpath(envdir, "Project.toml"), "")
                mkpath(joinpath(envdir, "packages"))
                link = joinpath(envdir, "packages", "MyPkg")
                symlink(joinpath("..", "..", "store", "MyPkg"), link)
                @test islink(link)
                @test isdir(link)                       # resolves through the link
                # the symlink target relative to the env is NOT "packages/MyPkg"
                @test relpath(realpath(link), envdir) != "packages/MyPkg"

                env = load_environment(envdir; depots)
                planned = plan_develop(env, regs, Config(depots), "packages/MyPkg")

                uuid = UUID(mypkg_uuid)
                # in-plan: [sources] and manifest entry keep the given relative path,
                # NOT the realpath-resolved symlink target
                @test planned.project.sources["MyPkg"].path == "packages/MyPkg"
                @test is_path_tracked(planned.manifest[uuid])
                @test entry_path(planned.manifest[uuid]) == "packages/MyPkg"

                # persist + reload: the preserved path survives the round-trip
                @test write_environment(env, planned)
                reloaded = load_environment(envdir; depots)
                @test reloaded.project.sources["MyPkg"].path == "packages/MyPkg"
                @test entry_path(reloaded.manifest[uuid]) == "packages/MyPkg"
            end
        end
    end
end

@testset "Pkg.jl#4622 build re-resolve keeps unregistered url-add path-tracked" begin
    # A mono-repo with a dev'd subpackage `Sub` that depends on an
    # unregistered package `Unreg` (stand-in for a url-added pkg: it is
    # path-tracked in the manifest but NOT in any registry). `pkg> build`
    # re-resolves the shared manifest via plan_resolve; before the fix the
    # collect_fixed pass tried to look Unreg up in the registry and failed
    # with `Unreg has no known versions`. The guard at src/Planning.jl:447-458
    # must instead preserve the manifest's path tracking.
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            dir = realpath(dir)
            unreg_uuid = UUID("11111111-2222-3333-4444-555555555555")
            sub_uuid = UUID("66666666-7777-8888-9999-aaaaaaaaaaaa")

            unregdir = joinpath(dir, "Unreg"); mkpath(unregdir)
            write(
                joinpath(unregdir, "Project.toml"), """
                name = "Unreg"
                uuid = "$unreg_uuid"
                version = "0.1.0"
                """
            )

            subdir = joinpath(dir, "Sub"); mkpath(subdir)
            write(
                joinpath(subdir, "Project.toml"), """
                name = "Sub"
                uuid = "$sub_uuid"
                version = "0.1.0"

                [deps]
                Unreg = "$unreg_uuid"
                """
            )

            projdir = joinpath(dir, "proj"); mkpath(projdir)
            write(joinpath(projdir, "Project.toml"), "")

            env0 = load_environment(projdir; depots)
            env1 = plan_develop(env0, regs, cfg, unregdir)
            env2 = plan_develop(env1, regs, cfg, subdir)
            write_environment(env0, env2)

            env = load_environment(projdir; depots)
            @test !is_registry_tracked(env.manifest[unreg_uuid])
            @test is_path_tracked(env.manifest[unreg_uuid])

            # This is exactly what `pkg> build` runs when it re-resolves.
            local resolved
            @test (resolved = plan_resolve(env, regs, cfg)) isa VibePkg.Environments.Environment
            @test haskey(resolved.manifest, unreg_uuid)
            @test !is_registry_tracked(resolved.manifest[unreg_uuid])
            @test is_path_tracked(resolved.manifest[unreg_uuid])
            @test !is_registry_tracked(resolved.manifest[sub_uuid])

            # and again through plan_up (full upgrade re-resolve)
            up = plan_up(env, regs, cfg)
            @test !is_registry_tracked(up.manifest[unreg_uuid])
            @test is_path_tracked(up.manifest[unreg_uuid])
        end
    end
end

@testset "Pkg.jl#4599 lazy and regular artifact installs share one interface" begin
    local Tar = VibePkg.Fetch.Tar
    local p7zip = VibePkg.Fetch.p7zip_jll.p7zip
    local sha256 = VibePkg.ArtifactOps.sha256
    local SHA1 = Base.SHA1
    local tree_hash = VibePkg.TreeHash.tree_hash
    local ensure_artifacts_installed! = VibePkg.ArtifactOps.ensure_artifacts_installed!
    local A = VibePkg.Artifacts

    # content dir -> tar -> gzip, served over file://
    build_gz = function (dir, label)
        content = mkpath(joinpath(dir, label))
        write(joinpath(content, "$label.txt"), "$label payload\n")
        hash = SHA1(tree_hash(content))
        tarball = joinpath(dir, "$label.tar")
        Tar.create(content, tarball)
        gz = joinpath(dir, "$label.tar.gz")
        run(pipeline(`$(p7zip()) a -tgzip $gz $tarball`; stdout = devnull))
        sha = bytes2hex(open(sha256, gz))
        return (; hash, gz, sha)
    end
    file_url = function (path)
        path = replace(path, '\\' => '/')
        startswith(path, '/') || (path = "/$path")
        return "file://$path"
    end

    mktempdir() do dir
        reg = build_gz(dir, "regularthing")   # non-lazy: the batch/regular path
        laz = build_gz(dir, "lazything")       # lazy: the on-demand path

        pkg = mkpath(joinpath(dir, "MixedPkg"))
        atoml = joinpath(pkg, "Artifacts.toml")
        write(
            atoml, """
            [regularthing]
            git-tree-sha1 = "$(reg.hash)"

                [[regularthing.download]]
                url = "$(file_url(reg.gz))"
                sha256 = "$(reg.sha)"

            [lazything]
            git-tree-sha1 = "$(laz.hash)"
            lazy = true

                [[lazything.download]]
                url = "$(file_url(laz.gz))"
                sha256 = "$(laz.sha)"
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # Pin the FIXED behavior: both code paths run through the SAME artifact
        # installer, so their install/progress interface is identical. Before
        # the fix these were two separate code paths (Operations.download_artifacts
        # vs Artifacts.ensure_artifact_installed) with divergent progress UIs.
        pushfirst!(Base.DEPOT_PATH, depot)
        try
            withenv("JULIA_PKG_SERVER" => "") do
                buf_regular = IOBuffer()
                buf_lazy = IOBuffer()

                # regular/batch path: instantiate-style install, skips the lazy one
                new = ensure_artifacts_installed!(depots, pkg; server = nothing, io = buf_regular)
                @test new == ["regularthing"]

                # on-demand/lazy path: the entry point lazy loading bottoms out in
                @test !A.artifact_exists(laz.hash)
                lazy_path = A.ensure_artifact_installed("lazything", atoml; io = buf_lazy)
                @test isdir(lazy_path)
                @test A.artifact_exists(laz.hash)

                # interface parity: identical (empty, non-fancy) progress output
                out_regular = take!(buf_regular)
                out_lazy = take!(buf_lazy)
                @test out_regular == out_lazy
                @test isempty(out_regular)
            end
        finally
            popfirst!(Base.DEPOT_PATH)
        end
    end
end

@testset "Pkg.jl#4590 conflicting workspace [sources] rev renders consistently" begin
    local describe = VibePkg.Display.describe
    local print_status = VibePkg.Display.print_status
    local entry_repo_rev = VibePkg.EnvFiles.entry_repo_rev
    local entry_repo_url = VibePkg.EnvFiles.entry_repo_url
    local is_repo_tracked = VibePkg.EnvFiles.is_repo_tracked
    local FOO_UUID = UUID("11111111-1111-1111-1111-111111111111")
    local url = "https://example.com/Foo.jl.git"

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])

        root = mkpath(joinpath(dir, "root"))
        # Root project: workspace with member `sub`; [sources] pins Foo at rev v1.9.0
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["sub"]

            [deps]
            Foo = "$FOO_UUID"

            [sources]
            Foo = { url = "$url", rev = "v1.9.0" }
            """
        )
        # Shared root manifest: Foo repo-tracked, CONSISTENT at version 1.9.0 / repo-rev v1.9.0
        write(
            joinpath(root, "Manifest.toml"), """
            julia_version = "1.11.0"
            manifest_format = "2.0"

            [[deps.Foo]]
            uuid = "$FOO_UUID"
            version = "1.9.0"
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            repo-url = "$url"
            repo-rev = "v1.9.0"
            """
        )
        # Member declares a CONFLICTING [sources] rev (v1.10.0) for the same shared dep.
        sub = mkpath(joinpath(root, "sub"))
        mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"), """
            name = "SubPkg"
            uuid = "5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5a"
            version = "0.1.0"

            [deps]
            Foo = "$FOO_UUID"

            [sources]
            Foo = { url = "$url", rev = "v1.10.0" }
            """
        )
        write(joinpath(sub, "src", "SubPkg.jl"), "module SubPkg end\n")

        # Activate the member: it finds the shared root manifest.
        env = load_environment(sub; depots)
        entry = env.manifest[FOO_UUID]

        # FIXED: describe draws BOTH version and rev from the same manifest entry.
        # The old Pkg bug rendered `v1.9.0 ...#v1.10.0` (version from manifest,
        # rev URL crossed with the active project's [sources]). Here they agree.
        @test is_repo_tracked(entry)
        @test entry_version(entry) == v"1.9.0"
        @test entry_repo_rev(entry) == "v1.9.0"
        @test entry_repo_url(entry) == url
        @test describe(entry) == "v1.9.0 `$url#v1.9.0`"
        # No cross-contamination from the member's conflicting rev.
        @test !occursin("v1.10.0", describe(entry))

        # print_status must not show the mismatched-rev cross either, in both
        # the plain and the --workspace views.
        for ws in (false, true)
            s = sprint(io -> print_status(io, env; workspace = ws))
            @test occursin("Foo", s)
            @test occursin("v1.9.0", s)
            @test !occursin("v1.9.0 ...#v1.10.0", s)
        end
    end
end

@testset "Pkg.jl#4588 [sources] path dep resolves; dependencies()/status() don't crash" begin
    tm_uuid = UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    mktempdir() do dir
        # synthetic local package at <dir>/deps/TestModule, referenced from
        # <dir>/env/Project.toml via a relative `[sources]` path — the shape
        # of the reported MWE (backslashes on Windows, forward-slashes here;
        # on Windows both are path separators so they resolve identically).
        pkgdir = mkpath(joinpath(dir, "deps", "TestModule"))
        mkpath(joinpath(pkgdir, "src"))
        write(
            joinpath(pkgdir, "Project.toml"),
            "name = \"TestModule\"\nuuid = \"$tm_uuid\"\nversion = \"0.1.0\"\n"
        )
        write(joinpath(pkgdir, "src", "TestModule.jl"), "module TestModule\nend\n")

        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"),
            """
            [deps]
            TestModule = "$tm_uuid"

            [sources]
            TestModule = {path = "../deps/TestModule"}
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        old = copy(Base.DEPOT_PATH)
        oldp = Base.ACTIVE_PROJECT[]
        oldg = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")

            # before the fix this raised MethodError: no method matching
            # project_rel_path(::EnvCache, ::Nothing)
            @test (VibePkg.instantiate(); true)

            deps = VibePkg.dependencies()
            ent = get(deps, tm_uuid, nothing)
            @test ent !== nothing
            @test ent.is_tracking_path
            @test ent.source !== nothing
            @test isdir(ent.source)
            @test realpath(ent.source) == realpath(pkgdir)

            @test (VibePkg.status(io = devnull); true)
        finally
            copy!(Base.DEPOT_PATH, old)
            Base.ACTIVE_PROJECT[] = oldp
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldg
        end
    end
end

@testset "Pkg.jl#4587 app develop relative path installs and runs anywhere" begin
    local AppsOps = VibePkg.AppsOps
    local read_manifest = VibePkg.EnvFiles.read_manifest
    local entry_path = VibePkg.EnvFiles.entry_path
    local RegistryInstance = VibePkg.Registries.RegistryInstance
    local APP_UUID = UUID("abcdabcd-abcd-abcd-abcd-abcdabcdabcd")
    # run a shim, capturing both streams; surface them only on failure
    local run_shim = function (shim::String, args::String...)
        cmd = Sys.iswindows() ? `cmd /c $shim $args` : `sh $shim $args`
        buf = IOBuffer()
        p = run(pipeline(ignorestatus(cmd); stdout = buf, stderr = buf))
        output = String(take!(buf))
        success(p) || error("shim run failed ($cmd):\n$output")
        return output
    end

    mktempdir() do dir
        pkg = joinpath(dir, "Runic")
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "Runic"
            uuid = "$APP_UUID"
            version = "0.1.0"

            [apps]
            runic = {}
            """
        )
        write(
            joinpath(pkg, "src", "Runic.jl"), """
            module Runic
            function (@main)(args)
                println("runic ran ok")
                return 0
            end
            end
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # The MWE: cd into the package dir and develop the app with path = "."
        cd(pkg) do
            AppsOps.app_develop(Config(depots), RegistryInstance[], "."; io = devnull)
        end

        shim = AppsOps.shim_path(depots, "runic")
        @test isfile(shim)

        # the relative "." must have been absolutized into the manifest
        entry = read_manifest(AppsOps.app_manifest_file(depots))[APP_UUID]
        recorded = entry_path(entry)
        @test isabspath(recorded)
        @test realpath(recorded) == realpath(pkg)

        # #4587 core: the shim works regardless of the caller's cwd, because
        # the recorded load path is absolute (not resolved against pwd)
        out = mktempdir() do other
            cd(other) do
                run_shim(shim)
            end
        end
        @test occursin("runic ran ok", out)
    end
end

@testset "Pkg.jl#4586 rm in workspace member with URL [sources] entry" begin
    FOO_UUID = UUID("f0000000-0000-0000-0000-000000000001")
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["sub"]
            """
        )
        sub = mkpath(joinpath(root, "sub"))
        mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"), """
            name = "SubPkg"
            uuid = "5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5a"
            version = "0.1.0"

            [deps]
            Example = "$EXAMPLE_UUID"
            Foo = "$FOO_UUID"

            [sources]
            Example = {url = "https://example.com/Example.jl.git"}
            """
        )
        write(joinpath(sub, "src", "SubPkg.jl"), "module SubPkg end\n")

        # Shared root manifest: Example is URL/repo-tracked (path === nothing),
        # which is exactly the shape that made sync_sources call
        # rebase_path(..., nothing) -> normpath(::Nothing).
        write(
            joinpath(root, "Manifest.toml"), """
            julia_version = "1.11.0"
            manifest_format = "2.0"

            [[deps.Example]]
            uuid = "$EXAMPLE_UUID"
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            repo-url = "https://example.com/Example.jl.git"
            version = "0.5.1"

            [[deps.Foo]]
            uuid = "$FOO_UUID"
            git-tree-sha1 = "3333333333333333333333333333333333333333"
            version = "1.0.0"

            [[deps.SubPkg]]
            uuid = "5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5a"
            path = "sub"
            version = "0.1.0"

                [deps.SubPkg.deps]
                Example = "$EXAMPLE_UUID"
                Foo = "$FOO_UUID"
            """
        )

        # Load the workspace member: project_file lives in sub/, manifest_file
        # at the root -> the two files are in *different* directories.
        env = load_environment(sub; depots)
        @test env.manifest_file == joinpath(realpath(root), "Manifest.toml")

        # rm Foo, then persist. The pre-fix bug crashed here inside
        # sync_sources while re-deriving [sources] for the remaining
        # URL-tracked Example.
        planned = plan_rm(env, [PackageRequest("Foo", nothing, nothing)])
        @test !haskey(planned.project.deps, "Foo")
        @test write_environment(env, planned)          # no MethodError(normpath, Nothing)

        # The URL [sources] entry for Example survives the rewrite.
        reloaded = load_environment(sub; depots)
        @test !haskey(reloaded.project.deps, "Foo")
        src = reloaded.project.sources["Example"]
        @test src.url == "https://example.com/Example.jl.git"
        @test src.path === nothing
    end
end

@testset "Pkg.jl#4557 git registry fast-forwards to origin without rebase" begin
    LibGit2 = VibePkg.Git.LibGit2
    sig = LibGit2.Signature("tester", "tester@example.com")

    # Write a Registry.toml + one payload file, stage and commit them.
    function commit_registry!(repo, dir, content)
        write(
            joinpath(dir, "Registry.toml"), """
            name = "Fixture"
            uuid = "11111111-2222-3333-4444-555555555555"
            repo = "https://example.invalid/Fixture.git"
            [packages]
            """
        )
        write(joinpath(dir, "payload.txt"), content)
        LibGit2.add!(repo, "Registry.toml", "payload.txt")
        return LibGit2.commit(repo, "content=$content"; author = sig, committer = sig)
    end

    mktempdir() do root
        # 1. Build a local upstream git registry (non-bare so we can advance it).
        upstream = mkpath(joinpath(root, "upstream"))
        up = LibGit2.init(upstream)
        commit_registry!(up, upstream, "one")

        # 2. Clone it full-depth exactly the way add_registry_from_source! does.
        clone = joinpath(root, "clone")
        repo = VibePkg.Git.ensure_clone(devnull, clone, upstream)
        close(repo)
        @test isfile(joinpath(clone, "Registry.toml"))

        # A fresh clone is already at upstream HEAD: nothing to move.
        @test VibePkg.Registries.update_git_registry!(clone; io = devnull) == false

        # 3. Advance the upstream with a new commit.
        new_head = commit_registry!(up, upstream, "two")
        LibGit2.close(up)

        # 4. update_git_registry! must fetch + fast-forward (no rebase step) and
        #    land exactly on the upstream HEAD.
        @test VibePkg.Registries.update_git_registry!(clone; io = devnull) == true

        moved = LibGit2.with(LibGit2.GitRepo(clone)) do r
            LibGit2.head_oid(r)
        end
        @test moved == new_head
        @test read(joinpath(clone, "payload.txt"), String) == "two"

        # 5. A second call with no upstream change is a no-op (idempotent).
        @test VibePkg.Registries.update_git_registry!(clone; io = devnull) == false
    end
end

@testset "Pkg.jl#4424 stale stdlib compat does not break resolve" begin
    local RANDOM_UUID = UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c")
    local stdlib_version = VibePkg.Stdlibs.stdlib_version
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        envdir = mkpath(joinpath(dir, "env"))
        # A Project that depends on the Random stdlib but carries a [compat]
        # bound that excludes the current stdlib version — the cross-Julia
        # mismatch of #4424 (e.g. a project auto-compatted on an older Julia).
        # `~1.9` = [1.9.0, 1.10.0) excludes the current stdlib Random 1.11.0.
        write(
            joinpath(envdir, "Project.toml"), """
            name = "TestCompat"
            uuid = "12345678-1234-1234-1234-1234567890ab"

            [deps]
            Random = "$RANDOM_UUID"

            [compat]
            Random = "~1.9"
            """
        )
        env = load_environment(envdir; depots)
        # The stale, unsatisfiable stdlib compat must NOT make resolve throw.
        local plan
        @test (plan = plan_resolve(env, regs, Config(depots)); true)
        # Random still lands in the manifest at its true (non-upgradable)
        # stdlib version; the excluded compat entry is ignored.
        @test haskey(plan.manifest, RANDOM_UUID)
        @test entry_version(plan.manifest[RANDOM_UUID]) == stdlib_version(RANDOM_UUID, VERSION)
        @test is_registry_tracked(plan.manifest[RANDOM_UUID])
    end
end

@testset "Pkg.jl#4413 undo after resolve on a stale manifest" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        # a project that requires Example paired with a stale/empty manifest —
        # the out-of-date precondition from the MWE
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            Example = "$EXAMPLE_UUID"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$(VERSION)"
            manifest_format = "2.0"
            """
        )

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        try
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            depots = depot_stack()

            # fresh session: no undo state exists for this project yet
            @test !haskey(VibePkg.API.UNDO_STACKS, Base.ACTIVE_PROJECT[])
            @test !haskey(load_environment(; depots).manifest.deps, EXAMPLE_UUID)

            # resolve is the FIRST mutating op of the session; it adds Example
            VibePkg.resolve(; io = devnull)
            @test haskey(load_environment(; depots).manifest.deps, EXAMPLE_UUID)

            # #4413: undo must NOT error with "no more states left" — it reverts
            @test VibePkg.undo(; io = devnull) === nothing
            @test !haskey(load_environment(; depots).manifest.deps, EXAMPLE_UUID)

            # and redo re-applies the resolve
            VibePkg.redo(; io = devnull)
            @test haskey(load_environment(; depots).manifest.deps, EXAMPLE_UUID)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

@testset "Pkg.jl#4409 workspace respects member weakdeps/extensions" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            sub_uuid = UUID("5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5a")
            root = mkpath(joinpath(dir, "root"))
            # root: workspace + a real dep on Example (installable offline fixture)
            write(
                joinpath(root, "Project.toml"), """
                [workspace]
                projects = ["sub"]

                [deps]
                Example = "$EXAMPLE_UUID"
                SubPkg = "$sub_uuid"
                """
            )
            # member: declares a weakdep on Example backing an extension.
            # Before the fix, resolving the workspace threw KeyError because
            # the member's weakdeps were not collected under the member uuid.
            sub = mkpath(joinpath(root, "sub"))
            mkpath(joinpath(sub, "src"))
            write(
                joinpath(sub, "Project.toml"), """
                name = "SubPkg"
                uuid = "$sub_uuid"
                version = "0.1.0"

                [weakdeps]
                Example = "$EXAMPLE_UUID"

                [extensions]
                SubExampleExt = "Example"
                """
            )
            write(joinpath(sub, "src", "SubPkg.jl"), "module SubPkg end\n")

            env = load_environment(root; depots)

            # The core regression: neither of these may throw (KeyError pre-fix).
            planned_resolve = plan_resolve(env, regs, Config(depots))
            @test haskey(planned_resolve.manifest, EXAMPLE_UUID)
            @test is_path_tracked(planned_resolve.manifest[sub_uuid])

            planned_up = plan_up(env, regs, Config(depots))
            @test haskey(planned_up.manifest, EXAMPLE_UUID)
            @test is_path_tracked(planned_up.manifest[sub_uuid])
        end
    end
end

@testset "Pkg.jl#4356 test in workspace must not inject [sources]" begin
    A_UUID = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    B_UUID = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # Workspace root with two members: A depends on sibling member B
        # (path-tracked in the shared manifest, NO [sources] in A's project)
        # and A/test is itself a workspace member — the exact shape from the
        # bug report (ChunkCodecs LibSnappy dep on ChunkCodecCore).
        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["A", "A/test", "B"]
            """
        )
        a = mkpath(joinpath(root, "A"))
        mkpath(joinpath(a, "src"))
        write(
            joinpath(a, "Project.toml"), """
            name = "APkg"
            uuid = "$A_UUID"
            version = "0.1.0"

            [deps]
            BPkg = "$B_UUID"
            """
        )
        write(joinpath(a, "src", "APkg.jl"), "module APkg end\n")
        # A's test project is a workspace member (the sandbox-free in-place
        # test path). It depends on A itself and on Example.
        atest = mkpath(joinpath(a, "test"))
        write(
            joinpath(atest, "Project.toml"), """
            [deps]
            APkg = "$A_UUID"
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(atest, "runtests.jl"), "using Test\n@test true\n")
        b = mkpath(joinpath(root, "B"))
        mkpath(joinpath(b, "src"))
        write(
            joinpath(b, "Project.toml"), """
            name = "BPkg"
            uuid = "$B_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(b, "src", "BPkg.jl"), "module BPkg end\n")

        # Establish the shared root manifest (all members path-tracked in it).
        env_root = load_environment(root; depots)
        write_environment(env_root, plan_resolve(env_root, regs, Config(depots)))

        # Snapshot A's Project.toml exactly as it sits on disk.
        a_project_file = joinpath(a, "Project.toml")
        before = read(a_project_file, String)
        @test !occursin("[sources]", before)

        # Re-derive A's environment and persist it the way an op (including
        # the in-place workspace-member test path, which calls
        # Execution.instantiate! -> write_environment on the test env) would.
        # The bug injected `[sources] BPkg = {path=...}` for the sibling
        # member; the fix keeps the project untouched.
        env_a = load_environment(a; depots)
        @test is_path_tracked(env_a.manifest[B_UUID])   # B path-tracked in shared manifest
        write_environment(env_a, plan_resolve(env_a, regs, Config(depots)))

        after = read(a_project_file, String)
        @test after == before                 # A/Project.toml is byte-for-byte unchanged
        @test !occursin("[sources]", after)   # no spurious [sources] section
        @test isempty(VibePkg.EnvFiles.read_project(a_project_file).sources)

        # Same guarantee from the test member itself (the project the test
        # daemon actually instantiates in place).
        atest_file = joinpath(atest, "Project.toml")
        test_before = read(atest_file, String)
        env_test = load_environment(atest; depots)
        write_environment(env_test, plan_resolve(env_test, regs, Config(depots)))
        @test read(atest_file, String) == test_before
        @test !occursin("[sources]", read(atest_file, String))
    end
end

@testset "Pkg.jl#4349 force_latest_compat honors julia version bounds" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        foo_uuid = UUID("11111111-2222-3333-4444-555555555555")
        # a synthetic registry where the numerically-newest version (2.0.0)
        # can never resolve on this julia (julia = "99"), while the older
        # 1.0.0 is compatible
        reg = joinpath(depot, "registries", "R4349")
        pkg = joinpath(reg, "F", "Foo")
        mkpath(pkg)
        write(
            joinpath(reg, "Registry.toml"), """
            name = "R4349"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.com/R4349.git"

            [packages]
            $foo_uuid = { name = "Foo", path = "F/Foo" }
            """
        )
        write(
            joinpath(pkg, "Package.toml"), """
            name = "Foo"
            uuid = "$foo_uuid"
            repo = "https://example.com/Foo.jl.git"
            """
        )
        write(
            joinpath(pkg, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"

            ["2.0.0"]
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            """
        )
        write(
            joinpath(pkg, "Compat.toml"), """
            ["1.0.0"]
            julia = "1.6-1"

            ["2.0.0"]
            julia = "99"
            """
        )

        regs = reachable_registries(depot_stack([depot]))
        project = VibePkg.EnvFiles.with_project(
            VibePkg.EnvFiles.Project();
            deps = Dict("Foo" => foo_uuid),
            compat = Dict("Foo" => VibePkg.EnvFiles.Compat("1, 2")),
        )
        # tested package uuid (not Foo) so Foo is processed by the tightening
        pkg_uuid = UUID("99999999-9999-9999-9999-999999999999")

        forced = VibePkg.TestOps.force_latest_compat(
            project, pkg_uuid, regs;
            allow_earlier_backwards_compatible_versions = false,
        )
        # FIXED: the floor is the julia-compatible 1.0.0, not the newest-but-
        # unresolvable 2.0.0. Buggy Pkg floored to >= 2.0.0 (excluding 1.0.0).
        @test v"1.0.0" in forced.compat["Foo"].val

        # end-to-end: the forced compat still resolves (no crash), picking the
        # julia-compatible 1.0.0. A buggy >= 2.0.0 floor would make Foo
        # unresolvable here (julia = "99").
        envdir = mkpath(joinpath(dir, "env"))
        base = load_environment(envdir; depots = depot_stack([depot]))
        forced_env = VibePkg.Environments.Environment(
            base.project_file, base.manifest_file, forced, base.manifest,
        )
        planned = plan_resolve(forced_env, regs, Config(depot_stack([depot])))
        @test entry_version(planned.manifest[foo_uuid]) == v"1.0.0"
    end
end

@testset "Pkg.jl#4237 add in workspace member keeps [sources] clean" begin
    VENDORED_UUID = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
    SUB_UUID = UUID("5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5a")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            root = mkpath(joinpath(dir, "root"))
            write(
                joinpath(root, "Project.toml"), """
                [workspace]
                projects = ["sub"]
                """
            )
            # a vendored (path-tracked, non-registry) package living OUTSIDE the member
            vendordir = mkpath(joinpath(root, "vendor", "Vendored"))
            mkpath(joinpath(vendordir, "src"))
            write(
                joinpath(vendordir, "Project.toml"), """
                name = "Vendored"
                uuid = "$VENDORED_UUID"
                version = "0.1.0"
                """
            )
            write(joinpath(vendordir, "src", "Vendored.jl"), "module Vendored end\n")

            # the workspace member: pre-existing [deps] + [sources] pointing at the vendor dir
            sub = mkpath(joinpath(root, "sub"))
            mkpath(joinpath(sub, "src"))
            write(
                joinpath(sub, "Project.toml"), """
                name = "Sub"
                uuid = "$SUB_UUID"
                version = "0.1.0"

                [deps]
                Vendored = "$VENDORED_UUID"

                [sources]
                Vendored = {path = "../vendor/Vendored"}
                """
            )
            write(joinpath(sub, "src", "Sub.jl"), "module Sub end\n")

            # load the member; it detects the workspace and the shared root manifest
            env = load_environment(sub; depots)
            @test env.manifest_file == joinpath(realpath(root), "Manifest.toml")
            @test length(env.workspace) == 1

            # add a registry package inside the member, then persist + reload
            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1")])
            write_environment(env, planned)
            env2 = load_environment(sub; depots)

            srcs = env2.project.sources

            # (1) no spurious self entry for the member's own name
            @test !haskey(srcs, "Sub")
            # (2) no bogus path="." entry anywhere in [sources]
            @test !any(s -> s.path == ".", values(srcs))
            # (3) the pre-existing foreign [sources] entry is preserved and still points at the vendor dir
            @test haskey(srcs, "Vendored")
            vsrc = srcs["Vendored"]
            @test vsrc.path !== nothing && vsrc.path != "."
            @test realpath(normpath(joinpath(dirname(env2.project_file), vsrc.path))) == realpath(vendordir)
            # (4) Example is registry-tracked with no [sources] entry
            @test !haskey(srcs, "Example")
            @test entry_version(env2.manifest[EXAMPLE_UUID]) == v"0.5.1"
            @test is_registry_tracked(env2.manifest[EXAMPLE_UUID])
            @test is_path_tracked(env2.manifest[VENDORED_UUID])
        end
    end
end

@testset "Pkg.jl#4221 workspace resolve populates shared manifest and status reports it" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # Root workspace with NO top-level deps; a `docs` member depends on
        # Example (Documenter stand-in). This is the #4221 MWE shape.
        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["docs"]
            """
        )
        docs = mkpath(joinpath(root, "docs"))
        write(
            joinpath(docs, "Project.toml"), """
            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"

            [compat]
            Example = "0.5"
            """
        )

        env = load_environment(root; depots)

        # BEFORE resolve: manifest is empty, so `st -m` correctly reports
        # an empty manifest (nothing has been resolved yet).
        before = sprint(io -> VibePkg.Display.print_status(io, env; manifest_mode = true))
        @test occursin("(empty manifest)", before)

        # resolve seeds the resolver with the member's deps even though the
        # root has none, so the deps-less root still resolves Example into
        # the shared manifest (Planning.jl collect_fixed).
        planned = plan_resolve(env, regs, Config(depots))
        @test haskey(planned.manifest, EXAMPLE_UUID)
        @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1"

        # persist the shared manifest at the root and reload it
        write_environment(env, planned)
        @test isfile(joinpath(root, "Manifest.toml"))
        env2 = load_environment(root; depots)

        # AFTER resolve: `st -m` reports the workspace-resolved packages and
        # NOT "empty manifest" (the #4221 defect: it reported nothing).
        after = sprint(io -> VibePkg.Display.print_status(io, env2; manifest_mode = true))
        @test occursin("Example", after)
        @test !occursin("(empty manifest)", after)
    end
end

@testset "Pkg.jl#4212 free --all frees all applicable packages" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # all_requests(env, :manifest) is what `free --all` feeds to plan_free:
        # name/uuid only, never a path/repo (the field does not even exist),
        # which is why VibePkg cannot hit Pkg's name-or-UUID rejection.
        all_reqs = VibePkg.API.all_requests

        # (A) the exact #4212 trigger: a dev'd (path-tracked) registered Example.
        # `free --all` returns it to registry tracking, no rejection.
        mktempdir() do dir
            devex = joinpath(dir, "Example")
            mkpath(joinpath(devex, "src"))
            write(
                joinpath(devex, "Project.toml"), """
                name = "Example"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.1"
                """
            )
            write(joinpath(devex, "src", "Example.jl"), "module Example end\n")
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1")])
            env = plan_develop(env, regs, Config(depots), devex)
            @test is_path_tracked(env.manifest[EXAMPLE_UUID])

            reqs = all_reqs(env, :manifest)
            @test all(r -> r.name !== nothing && r.uuid !== nothing, reqs)

            # `free --all` ⇒ err_if_free = false; must NOT throw
            freed = plan_free(env, regs, Config(depots), reqs; err_if_free = false)
            entry = freed.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(entry)
            @test !is_path_tracked(entry)
            @test entry_version(entry) == v"0.5.1"
        end

        # (B) a manifest whose package is already registry-tracked-and-unpinned
        # (nothing to free): `free --all` must quietly leave it be, NOT reject
        # with the "expected package to be pinned…" error (err_if_free = false).
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1")])
            @test is_registry_tracked(env.manifest[EXAMPLE_UUID])
            @test !env.manifest[EXAMPLE_UUID].pinned

            reqs = all_reqs(env, :manifest)
            # err_if_free = true (the per-package form) WOULD reject the already-free dep…
            @test_throws PkgError plan_free(env, regs, Config(depots), reqs; err_if_free = true)
            # …but `free --all` passes err_if_free = false ⇒ no-op, unchanged.
            freed = plan_free(env, regs, Config(depots), reqs; err_if_free = false)
            entry = freed.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(entry)
            @test entry_version(entry) == v"0.5.1"
        end
    end
end

@testset "Pkg.jl#4157 changing [sources] rev triggers full re-resolution" begin
    LibGit2 = VibePkg.Git.LibGit2
    SHA1 = Base.SHA1
    Git = VibePkg.Git
    entry_tree_hash = VibePkg.EnvFiles.entry_tree_hash
    entry_repo_rev = VibePkg.EnvFiles.entry_repo_rev

    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # A local git repo for synthetic package `Foo` with two commits that
        # produce distinct trees (revA, revB).
        FOO_UUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        src = joinpath(dir, "Foo")
        mkpath(joinpath(src, "src"))
        write(
            joinpath(src, "Project.toml"), """
            name = "Foo"
            uuid = "$FOO_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(src, "src", "Foo.jl"), "module Foo end\n")
        repo = LibGit2.init(src)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("tester", "tester@example.com")
        cA = string(LibGit2.commit(repo, "A"; author = sig, committer = sig))
        write(joinpath(src, "src", "Foo.jl"), "module Foo\nconst X = 2\nend\n")
        LibGit2.add!(repo, ".")
        cB = string(LibGit2.commit(repo, "B"; author = sig, committer = sig))
        LibGit2.close(repo)
        @test cA != cB

        # canonical Git tree object id for a rev
        tree_of = function (rev)
            r = LibGit2.GitRepo(src)
            o = t = nothing
            try
                o = LibGit2.GitObject(r, rev)
                t = LibGit2.peel(LibGit2.GitTree, o)
                return SHA1(string(LibGit2.GitHash(t)))
            finally
                t !== nothing && close(t)
                o !== nothing && close(o)
                close(r)
            end
        end
        treeA = tree_of(cA)
        treeB = tree_of(cB)
        @test treeA != treeB

        fetcher = Git.source_fetcher(depots; io = devnull)

        projdir = mkpath(joinpath(dir, "proj"))
        proj = joinpath(projdir, "Project.toml")
        write(
            proj, """
            [deps]
            Foo = "$FOO_UUID"

            [sources]
            Foo = {url = "$(slashpath(src))", rev = "$cA"}
            """
        )
        env = load_environment(projdir; depots)
        plan = plan_resolve(env, regs, Config(depots); fetcher)
        entryA = plan.manifest[UUID(FOO_UUID)]
        @test entry_repo_rev(entryA) == cA
        @test entry_tree_hash(entryA) == treeA

        # persist revA's manifest, then flip the source rev to B
        write_environment(env, plan)
        write(
            proj, """
            [deps]
            Foo = "$FOO_UUID"

            [sources]
            Foo = {url = "$(slashpath(src))", rev = "$cB"}
            """
        )
        env2 = load_environment(projdir; depots)
        # stale revA tree is still present before re-resolving
        @test entry_tree_hash(env2.manifest[UUID(FOO_UUID)]) == treeA

        # re-resolution must do a FULL re-resolve: new rev + new tree
        plan2 = plan_resolve(env2, regs, Config(depots); fetcher)
        entryB = plan2.manifest[UUID(FOO_UUID)]
        @test entry_repo_rev(entryB) == cB
        @test entry_tree_hash(entryB) == treeB
        @test entry_tree_hash(entryB) != treeA
    end
end

@testset "Pkg.jl#4108 completion list has no non-dispatchable commands" begin
    REPLMode = VibePkg.REPLMode
    cands, _ = REPLMode.completions_for("")
    # `package` must not be offered as a start-of-line completion
    @test "package" ∉ cands
    @test isempty(REPLMode.completions_for("pack")[1])
    # and it must not be a recognized command either
    @test_throws PkgError REPLMode.do_cmd("package"; io = devnull)
    # regression guard: every start-of-line candidate is dispatchable
    dispatchable = union(Set(keys(REPLMode.command_specs())), Set(["registry", "app", "help"]))
    @test issubset(Set(cands), dispatchable)
end

@testset "Pkg.jl#3684 force_latest_compat skips unregistered dep that has compat" begin
    mktempdir() do depot
        make_test_registry(depot)
        regs = reachable_registries(depot_stack([depot]))
        # The tested package (never floored against itself).
        pkg_uuid = UUID("bbbbbbbb-1111-2222-3333-444444444444")
        # An unregistered dependency (not in the offline registry) that DOES
        # carry a [compat] entry — the exact #3684 trigger: Pkg reduced with
        # `maximum` over the (empty) compatible-versions set only when the dep
        # had compat, crashing with "reducing over an empty collection".
        unreg_uuid = UUID("99999999-9999-9999-9999-999999999999")
        project = VibePkg.EnvFiles.with_project(
            VibePkg.EnvFiles.Project();
            deps = Dict("Example" => EXAMPLE_UUID, "Unreg" => unreg_uuid),
            compat = Dict(
                "Example" => VibePkg.EnvFiles.Compat("0.5"),
                "Unreg" => VibePkg.EnvFiles.Compat("1.2.3"),
            ),
        )

        # #3684: no crash, even though Unreg has compat but no registry entry.
        local forced
        @test (
            forced = VibePkg.TestOps.force_latest_compat(
                project, pkg_uuid, regs;
                allow_earlier_backwards_compatible_versions = false,
            )
        ) isa VibePkg.EnvFiles.Project

        # The unregistered dep's compat is preserved untouched (not floored,
        # not dropped) — it was simply skipped.
        @test haskey(forced.compat, "Unreg")
        @test forced.compat["Unreg"].val == project.compat["Unreg"].val
        @test v"1.2.3" in forced.compat["Unreg"].val

        # The registered dep is still floored to the latest compatible version
        # (0.5.1 resolves; 0.5.0 is excluded once floored at 0.5.1).
        @test v"0.5.1" in forced.compat["Example"].val
        @test !(v"0.5.0" in forced.compat["Example"].val)
    end
end

@testset "Pkg.jl#3185 stdin stays open/readable during test" begin
    using VibePkg.Registries: RegistryInstance
    mktempdir() do dir
        pkg = joinpath(dir, "StdinPkg")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "StdinPkg"
            uuid = "eeeeeeee-1111-2222-3333-444444444444"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "StdinPkg.jl"), "module StdinPkg end\n")
        # #3185: on 1.6/1.7 stdin was closed/unavailable inside Pkg.test.
        # Fixed behavior: stdin is open, readable, and delivers parent content.
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            @assert isopen(stdin)
            @assert isreadable(stdin)
            @assert readline(stdin) == "ping"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        planned = Planning.plan_develop(env, RegistryInstance[], Config(depots), pkg)
        write_environment(env, planned)
        env = load_environment(envdir; depots)

        pipe = Pipe()
        Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
        write(pipe, "ping\n")
        close(pipe.in)

        failed = redirect_stdin(pipe) do
            VibePkg.TestOps.test!(
                env, RegistryInstance[], Config(depots),
                UUID("eeeeeeee-1111-2222-3333-444444444444");
                allow_reresolve = false, io = devnull,
            )
        end
        close(pipe)
        @test failed === nothing
    end
end

@testset "Pkg.jl#2922 interrupting test does not orphan sandbox child" begin
    TestOps = VibePkg.TestOps

    # true iff process `pid` still exists (unix `kill -0`, windows `tasklist`)
    alive = function (pid)
        if Sys.iswindows()
            out = try
                read(`tasklist /FI "PID eq $pid" /NH /FO CSV`, String)
            catch
                return false
            end
            return occursin("\"$pid\"", out)
        else
            try
                run(pipeline(`kill -0 $pid`; stdout = devnull, stderr = devnull))
                return true
            catch
                return false
            end
        end
    end

    mktempdir() do dir
        # a synthetic sandbox package: empty Project.toml + a runtests.jl that
        # records its own pid and then loops for 120s swallowing interrupts, so
        # nothing but an external kill can stop it.
        write(joinpath(dir, "Project.toml"), "")
        testdir = mkpath(joinpath(dir, "test"))
        pidfile = joinpath(dir, "child.pid")
        runtests = joinpath(testdir, "runtests.jl")
        write(
            runtests, """
            Base.exit_on_sigint(false)
            write(raw"$pidfile", string(getpid()))
            flush(stdout)
            t0 = time()
            while time() - t0 < 120
                try
                    sleep(0.05)
                catch
                end
            end
            """
        )

        # launch the test subprocess exactly as Pkg.test's driver does, inside a
        # task we can inject an InterruptException into (the REPL raw-mode ^C
        # case where the signal reaches only the parent, not the child).
        task = @async try
            TestOps.run_test_process(
                "Sandbox", dir, runtests, dir;
                coverage = false, julia_args = String[], test_args = String[],
                autoprecompile = false, io = devnull,
            )
        catch
        end

        # wait for the child to boot and publish its pid
        child_pid = nothing
        t0 = time()
        while time() - t0 < 60
            if isfile(pidfile)
                s = strip(read(pidfile, String))
                if !isempty(s)
                    child_pid = parse(Int, s)
                    break
                end
            end
            sleep(0.1)
        end

        @test child_pid !== nothing
        @test child_pid !== nothing && alive(child_pid)

        try
            # simulate ^C reaching only the driver task
            schedule(task, InterruptException(); error = true)

            # #2922: interrupting the driver must terminate the child test
            # session, never orphan it. subprocess_handler forwards SIGINT and
            # escalates to SIGKILL after 4s, so the child dies well inside the
            # 8s poll window even though it swallows interrupts.
            child_dead = false
            t1 = time()
            while time() - t1 < 8
                if !alive(child_pid)
                    child_dead = true
                    break
                end
                sleep(0.1)
            end
            @test child_dead
        finally
            # never leave a stray child running past the test
            if child_pid !== nothing
                forcekill = Sys.iswindows() ? `taskkill /F /PID $child_pid` : `kill -9 $child_pid`
                try
                    run(pipeline(forcekill; stdout = devnull, stderr = devnull))
                catch
                end
            end
        end
    end
end

@testset "Pkg.jl#3112 add does not mutate caller request/env in place" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)

            # Caller-owned request object; the non-bang plan must not touch it.
            req = PackageRequest("Example", nothing, "0.5.1")

            # Snapshot the input environment before planning.
            @test isempty(env0.manifest)
            deps_before = copy(env0.project.deps)

            planned = plan_add(env0, regs, Config(depots), [req])

            # The caller's request object is untouched (the #3112 defect).
            @test req.uuid === nothing
            @test req.version == "0.5.1"
            @test req.name == "Example"

            # The input environment is untouched: no in-place manifest/deps writes.
            @test isempty(env0.manifest)
            @test env0.project.deps == deps_before
            @test !haskey(env0.project.deps, "Example")

            # The resolved package lives only in the freshly returned plan.
            @test planned !== env0
            @test haskey(planned.manifest, EXAMPLE_UUID)
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1"
            @test planned.project.deps["Example"] == EXAMPLE_UUID
        end
    end
end

@testset "Pkg.jl#4063 version with build number rejected cleanly" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            cfg = Config(depots)

            # The reported symptom was a raw `ArgumentError: invalid base 10
            # digit '+'` leaking out of the public add API. The guard in
            # request_version_spec must convert that into a clean PkgError.
            err = try
                plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.1+0")])
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test !(err isa ArgumentError)
            @test occursin("invalid version specifier", lowercase(sprint(showerror, err)))

            # Control: the same spec without the build tag resolves fine.
            env2 = plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])
            @test entry_version(env2.manifest[EXAMPLE_UUID]) == v"0.5.1"
        end
    end
end

@testset "Pkg.jl#3996 progress bar honors displaysize width" begin
    using VibePkg.MiniProgressBars: MiniProgressBar, show_progress

    render(dsize) = begin
        bar = MiniProgressBar(
            header = "Updating", mode = :percentage,
            width = 1000, current = 50, max = 100,
            always_reprint = true
        )
        io = IOContext(IOBuffer(), :color => true, :displaysize => dsize)
        show_progress(io, bar)
        String(take!(io.io))
    end

    out80 = render((24, 80))
    out200 = render((24, 200))

    n80 = count(==('━'), out80)
    n200 = count(==('━'), out200)

    # The bar sizes to displaysize(io)[2], not a hardcoded 80: a wider terminal
    # yields strictly more glyphs.
    @test n200 > n80
    # And the 80-col render stays well under 80 (terminal width is the binding
    # constraint here, since p.width = 1000).
    @test n80 < 80
    @test n80 > 0

    # Explicit termwidth kwarg overrides displaysize and drives the width.
    bar = MiniProgressBar(
        header = "Updating", mode = :percentage,
        width = 1000, current = 50, max = 100,
        always_reprint = true
    )
    io = IOContext(IOBuffer(), :color => true, :displaysize => (24, 80))
    show_progress(io, bar; termwidth = 200)
    n_explicit = count(==('━'), String(take!(io.io)))
    @test n_explicit == n200
end

@testset "Pkg.jl#3991 devved dependency is used when testing" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)

        # A dev'd Example whose source carries a marker the *registered*
        # Example (0.5.x/1.0.0) does not have. Its directory name contains
        # "ExampleDev" so the test can assert the loaded source path.
        exdev = mkpath(joinpath(dir, "ExampleDev"))
        write(
            joinpath(exdev, "Project.toml"),
            """
            name = "Example"
            uuid = "$(EXAMPLE_UUID)"
            version = "0.5.1"
            """,
        )
        mkpath(joinpath(exdev, "src"))
        write(
            joinpath(exdev, "src", "Example.jl"),
            "module Example\nconst DEVMARKER = 424242\nend\n",
        )

        # The package under test: depends on Example, and its tests assert
        # that the *dev'd* Example source is the one that loads.
        puuid = "aaaaaaaa-1111-2222-3333-444444444444"
        pdir = mkpath(joinpath(dir, "P"))
        write(
            joinpath(pdir, "Project.toml"),
            """
            name = "P"
            uuid = "$puuid"
            version = "0.1.0"

            [deps]
            Example = "$(EXAMPLE_UUID)"
            """,
        )
        mkpath(joinpath(pdir, "src"))
        write(joinpath(pdir, "src", "P.jl"), "module P\nusing Example\nend\n")
        mkpath(joinpath(pdir, "test"))
        write(
            joinpath(pdir, "test", "Project.toml"),
            """
            [deps]
            Example = "$(EXAMPLE_UUID)"
            Test = "$(TEST_UUID)"
            """,
        )
        write(
            joinpath(pdir, "test", "runtests.jl"),
            """
            using Example, Test
            @testset "devved dep is used" begin
                @test isdefined(Example, :DEVMARKER)
                @test Example.DEVMARKER == 424242
                @test occursin("ExampleDev", pathof(Example))
            end
            """,
        )

        projfile = joinpath(mkpath(joinpath(dir, "proj")), "Project.toml")

        old = copy(Base.DEPOT_PATH)
        oldp = Base.ACTIVE_PROJECT[]
        oldg = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = projfile

            # Dev the dependency first, then the package that tests it. Both
            # are path-tracked, so the test sandbox resolves entirely offline.
            VibePkg.develop(; path = exdev, io = devnull)
            VibePkg.develop(; path = pdir, io = devnull)

            env = load_environment(; depots = depot_stack([depot]))
            @test is_path_tracked(env.manifest[EXAMPLE_UUID])

            # The fixed behavior: Pkg.test's sandbox loads the dev'd Example
            # source (with DEVMARKER), not a registered version. If the bug
            # were present the subprocess assertions would fail and `test`
            # would throw.
            @test VibePkg.test(["P"]; io = devnull) === nothing
        finally
            copy!(Base.DEPOT_PATH, old)
            Base.ACTIVE_PROJECT[] = oldp
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldg
        end
    end
end

@testset "Pkg.jl#3947 status with non-weakdep extension trigger" begin
    host_uuid = UUID("ee44ee44-ee44-4e44-8e44-ee44ee44ee44")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            # Dev host whose extension trigger is a *strong* dep (in [deps],
            # with NO [weakdeps] table at all) — the exact #3947 shape.
            host = joinpath(dir, "ExtHost")
            mkpath(joinpath(host, "src"))
            write(
                joinpath(host, "Project.toml"), """
                name = "ExtHost"
                uuid = "$host_uuid"
                version = "0.1.0"

                [deps]
                Example = "$EXAMPLE_UUID"

                [extensions]
                ExampleExt = "Example"

                [compat]
                Example = "0.5"
                """
            )
            write(joinpath(host, "src", "ExtHost.jl"), "module ExtHost end\n")
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            write_environment(env, plan_develop(env, regs, Config(depots), host))
            env = load_environment(envdir; depots)
            # record the extension (dev'd project is readable) into the manifest
            manifest = VibePkg.Execution.fixups_from_projectfile(env, depots)
            env = VibePkg.Environments.Environment(
                env.project_file, env.manifest_file, env.project, manifest, env.workspace
            )
            entry = env.manifest[host_uuid]
            # extension present, trigger is a strong dep, weakdeps genuinely empty
            @test entry.exts == Dict("ExampleExt" => "Example")
            @test isempty(entry.weakdeps)
            @test haskey(entry.deps, "Example")

            # #3947: status must NOT throw a KeyError on the non-weakdep trigger
            s = sprint(io -> VibePkg.Display.print_status(io, env; extensions = true))
            @test s isa String
            @test occursin("ExampleExt", s)

            # the info helper resolves the uuid via [deps] fallback, not weakdeps[extdep]
            info = VibePkg.Display.status_ext_info(host_uuid, entry)
            @test info !== nothing
            @test info[1].weakdeps == [("Example", info[1].weakdeps[1][2])]
        end
    end
end

@testset "Pkg.jl#3937 SHA stdlib stays bundled, not upgraded from registry" begin
    local stdlib_version = VibePkg.Stdlibs.stdlib_version
    local entry_tree_hash = VibePkg.EnvFiles.entry_tree_hash
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        reg = make_test_registry(depot)

        # Inject a competing *registered* SHA advertising only v1.6.7 (far newer
        # than the stdlib bundled with this Julia). This is the CI/Documenter
        # shape from the report, where a registry offered a high SHA version.
        shapkg = mkpath(joinpath(reg, "S", "SHA"))
        write(
            joinpath(shapkg, "Package.toml"), """
            name = "SHA"
            uuid = "$SHA_UUID"
            repo = "https://example.com/SHA.jl.git"
            """
        )
        write(
            joinpath(shapkg, "Versions.toml"), """
            ["1.6.7"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            """
        )
        # Register SHA alongside Example in the registry index.
        write(
            joinpath(reg, "Registry.toml"), """
            name = "TestRegistry"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.com/TestRegistry.git"

            [packages]
            7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
            $SHA_UUID = { name = "SHA", path = "S/SHA" }
            """
        )

        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do envroot
            envdir = mkpath(joinpath(envroot, "env"))
            env = load_environment(envdir; depots)
            planned = plan_add(env, regs, Config(depots), [PackageRequest("SHA", nothing, nothing)])

            entry = planned.manifest[SHA_UUID]
            # FIXED: SHA resolves to the stdlib version bundled with this Julia
            # (e.g. 0.7.0), NOT the registry's v1.6.7 — the #3937 bad upgrade.
            @test entry_version(entry) == stdlib_version(SHA_UUID, VERSION)
            @test entry_version(entry) != v"1.6.7"
            # A stdlib entry is not path-tracked and carries no tree-hash: it is
            # served from the Julia install, not fetched from the registry.
            @test !is_path_tracked(entry)
            @test entry_tree_hash(entry) === nothing
        end
    end
end

@testset "Pkg.jl#3918 registry add URL#branch errors clearly, no silent wrong-branch" begin
    # Build a local git registry repo with a `foo` branch off the default branch.
    mktempdir() do repo
        function git(args...)
            run(pipeline(`git -C $repo $args`; stdout = devnull, stderr = devnull))
        end
        write(
            joinpath(repo, "Registry.toml"), """
            name = "MyReg"
            uuid = "11111111-2222-3333-4444-555555555555"
            repo = "$(file_url(repo))"

            [packages]
            """
        )
        git("init", "-q")
        git("config", "user.email", "t@t.t")
        git("config", "user.name", "t")
        git("add", "-A")
        git("commit", "-q", "-m", "init")
        git("branch", "foo")

        mktempdir() do depot
            depots = depot_stack([depot])
            # A branch-qualified registry URL must error clearly (no `#rev` parsing;
            # the whole spec is handed to git clone and fails loudly) rather than
            # silently landing on the wrong branch or writing a broken refspec.
            spec = file_url(repo) * "#foo"
            @test_throws PkgError VibePkg.Registries.add_registry!(depots, spec)
            # Nothing was installed.
            @test isempty(reachable_registries(depots))

            # Sanity: the same repo without the `#foo` suffix installs cleanly,
            # proving the error above is specifically about the branch suffix.
            name = VibePkg.Registries.add_registry!(depots, file_url(repo))
            @test name == "MyReg"
            @test !isempty(reachable_registries(depots))
        end
    end
end

@testset "Pkg.jl#3914 tilde-path completion offset" begin
    if Sys.iswindows()
        # expanduser is a no-op on Windows ('~' never expands), so the
        # tilde-offset bug cannot occur there; skip.
        @test_skip true
    else
        mktempdir() do tmphome
            # Create subdirs whose names share the typed 'jul' prefix.
            mkpath(joinpath(tmphome, "julcode"))
            mkpath(joinpath(tmphome, "juldocuments"))
            mkpath(joinpath(tmphome, "other"))

            # Sanity: expanduser('~') must be materially longer than the typed '~'
            # (the Pkg #3914 bug was the offset computed against the EXPANDED path).
            withenv("HOME" => tmphome) do
                @test length(expanduser("~")) > 1

                cands, word = VibePkg.REPLMode.completions_for("activate ~/jul")

                # Fixed behavior: the word-to-replace is the RAW typed fragment,
                # NOT the expanduser-expanded path. This keeps the LineEdit offset
                # correct.
                @test word == "~/jul"
                @test word == String(match(r"[^\s]*$", "activate ~/jul").match)

                # Candidates preserve the tilde and match the raw fragment, so the
                # replaced buffer range lines up with what the user typed.
                @test !isempty(cands)
                @test all(c -> startswith(c, "~/"), cands)
                @test all(c -> startswith(c, word), cands)
                @test "~/julcode" in cands
                @test "~/juldocuments" in cands
                @test !("~/other" in cands)
            end
        end
    end
end

@testset "Pkg.jl#3908 expanduser tab-completion stays graceful" begin
    using VibePkg.REPLMode: completions_for
    # `~.` is a `~user` form that `expanduser` cannot expand: it throws a bare
    # ArgumentError. Tab-completion must swallow that and return empty candidates
    # rather than crashing the REPL (the original Pkg.jl#3908 bug).
    for partial in ("activate ~.", "dev ~.", "develop ~.", "add ~.")
        local cands, word
        @test begin
            cands, word = completions_for(partial)  # never throws
            true
        end
        @test isempty(cands)
        @test word == "~."
    end
    # The plain path-completion form must also not blow up.
    @test isempty(completions_for("activate ~.")[1])
end

@testset "Pkg.jl#3902 jll build number preserved when registry build superseded" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        jll_uuid = UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
        pkg = mkpath(joinpath(depot, "registries", "JllRegistry", "D", "Dummy_jll"))
        write(
            joinpath(depot, "registries", "JllRegistry", "Registry.toml"), """
            name = "JllRegistry"
            uuid = "33338594-aafe-5451-b93e-139f81909106"

            [packages]
            $jll_uuid = { name = "Dummy_jll", path = "D/Dummy_jll" }
            """
        )
        write(
            joinpath(pkg, "Package.toml"), """
            name = "Dummy_jll"
            uuid = "$jll_uuid"
            repo = "https://example.com/Dummy_jll.git"
            """
        )
        # Registry carries ONLY 1.0.0+2 — the build (+1) the manifest is pinned
        # to has been superseded and is no longer registered.
        write(
            joinpath(pkg, "Versions.toml"), """
            ["1.0.0+2"]
            git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            """
        )
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            Dummy_jll = "$jll_uuid"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Dummy_jll]]
            git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            uuid = "$jll_uuid"
            version = "1.0.0+1"
            """
        )
        env = load_environment(envdir; depots)
        # The reported bug (Pkg.jl#3902) surfaced as an Unsatisfiable/ResolverError
        # here; the fix (jll_fix in resolve_versions) must keep the resolve GREEN
        # and hold the manifest's build number instead of moving to +2.
        local plan
        @test (plan = plan_resolve(env, regs, Config(depots)); true)
        entry = plan.manifest[jll_uuid]
        @test entry_version(entry) == v"1.0.0+1"
    end
end

@testset "Pkg.jl#3892 dev .. relative path parses without a case/existence check" begin
    # Root cause of the original bug: Pkg's REPL parser gated `.`/`..`/path
    # words behind `casesensitive_isdir(expanduser(word))`, which walks each
    # path component and compares it case-sensitively against the parent's
    # readdir listing. On Windows, cd'ing with wrong case made pwd() (hence the
    # absolute form of `..`) carry wrong-case components, so the check returned
    # false and `pkg> dev ..` aborted with "`..` appears to be a local path,
    # but directory does not exist" — even though Pkg.develop(path="..") worked.
    #
    # VibePkg's identifier_fields must classify `.`/`..` (and dotted relative
    # paths) as a path spec purely lexically, never touching the filesystem.
    @test VibePkg.REPLMode.identifier_fields("..") == (; path = "..")
    @test VibePkg.REPLMode.identifier_fields(".") == (; path = ".")
    @test VibePkg.REPLMode.identifier_fields("../MyPackage") == (; path = "../MyPackage")

    # The classification must be independent of the process's cwd and of any
    # (wrong-case) directory on disk: run from a temp dir whose real name has a
    # different case than what we would type, and confirm the parse is
    # unchanged. On a case-insensitive FS this is exactly the Windows scenario.
    mktempdir() do dir
        realsub = mkpath(joinpath(dir, "MyPackage"))
        old = pwd()
        try
            cd(realsub)
            # `..` still resolves to a pure path spec regardless of cwd casing.
            @test VibePkg.REPLMode.identifier_fields("..") == (; path = "..")
            # A wrong-case sibling reference that does NOT exist on disk still
            # parses as a path (no existence check) — the fixed behavior.
            @test VibePkg.REPLMode.identifier_fields("../nosuchdir") ==
                (; path = "../nosuchdir")
        finally
            cd(old)
        end
    end

    # End-to-end at the parser boundary: `dev ..` produces a develop spec whose
    # path is the untouched `..`, matching Pkg.develop(path="..").
    specs = VibePkg.REPLMode.parse_package_word("..")
    @test specs.path == ".."
end

@testset "Pkg.jl#3891 workspace member manifest diff shows change not spurious add" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # workspace root with a `test` member; both declare Example.
        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["test"]

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        member = mkpath(joinpath(root, "test"))
        mkpath(joinpath(member, "src"))
        write(
            joinpath(member, "Project.toml"), """
            name = "TestMember"
            uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
            version = "0.1.0"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(member, "src", "TestMember.jl"), "module TestMember end\n")

        # a local checkout of Example to develop at a version above the registry
        devex = joinpath(dir, "ExampleDev")
        mkpath(joinpath(devex, "src"))
        write(
            joinpath(devex, "Project.toml"), """
            name = "Example"
            uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
            version = "0.5.4"
            """
        )
        write(joinpath(devex, "src", "Example.jl"), "module Example end\n")

        # load the member: it resolves the shared ROOT manifest
        env = load_environment(member; depots)
        @test env.manifest_file == joinpath(realpath(root), "Manifest.toml")

        # develop Example (path-tracked v0.5.4) into the shared manifest, persist
        write_environment(env, plan_develop(env, regs, Config(depots), devex))

        # reload the member's env: its OLD state must see the pre-existing
        # shared-manifest entry (path-tracked v0.5.4), NOT an empty manifest.
        old_env = load_environment(member; depots)
        old_entry = get(old_env.manifest, EXAMPLE_UUID, nothing)
        @test old_entry !== nothing
        @test is_path_tracked(old_entry)
        @test entry_version(old_entry) == v"0.5.4"

        # free Example in the member -> off the path, back to registry tracking
        freed = plan_free(old_env, regs, Config(depots), [PackageRequest("Example")])
        @test is_registry_tracked(freed.manifest[EXAMPLE_UUID])
        @test !is_path_tracked(freed.manifest[EXAMPLE_UUID])

        # #3891: the manifest diff must render the real change of the
        # pre-existing v0.5.4 entry (a `~ ... ⇒` modification), NOT a
        # misleading `+ Example` add line (the bug loaded the member's OLD
        # env with an empty manifest, so it never saw the shared entry).
        out = sprint(
            io -> VibePkg.Display.print_env_diff(io, old_env, freed; registries = regs, depots)
        )
        @test occursin("Example v0.5.4", out)
        @test occursin("⇒", out)
        @test !occursin("+ Example", out)
    end
end

@testset "Pkg.jl#1249 yanked manifest version re-resolves for test deps" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            write(
                joinpath(envdir, "Project.toml"), """
                [deps]
                Example = "$EXAMPLE_UUID"
                """
            )
            # Manifest pins Example to the now-yanked 1.0.0 (git-tree-sha1 3333…)
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "$VERSION"
                manifest_format = "2.0"

                [[deps.Example]]
                git-tree-sha1 = "3333333333333333333333333333333333333333"
                uuid = "$EXAMPLE_UUID"
                version = "1.0.0"
                """
            )
            env = load_environment(envdir; depots)

            # Tier 1 (PRESERVE_ALL / Pkg.resolve): the yanked, explicitly-pinned
            # manifest version leaves no candidate, so the resolver errors — this
            # is the exact failure the reporter hit.
            @test_throws VibePkg.Resolve.ResolverError plan_resolve(env, regs, Config(depots))

            # Tier 2 (recovery / re-resolve, what Pkg.test falls back to): must
            # succeed and move Example off the yanked 1.0.0 to the latest
            # resolvable 0.5.1.
            recovered = plan_up(env, regs, Config(depots), PackageRequest[])
            @test entry_version(recovered.manifest[EXAMPLE_UUID]) == v"0.5.1"
        end
    end
end

@testset "Pkg.jl#3609 test subprocess crash output is surfaced" begin
    local run_test_process = VibePkg.TestOps.run_test_process
    local failure_reason = VibePkg.TestOps.failure_reason
    local report_test_failures = VibePkg.TestOps.report_test_failures

    mktempdir() do dir
        # A synthetic package source whose test/runtests.jl writes its OWN
        # output to stdout and then exits non-1 (deterministic stand-in for the
        # reported segfault: exercises the exact surfacing path in
        # run_test_process without needing a real crash).
        source = mkpath(joinpath(dir, "Crasher"))
        mkpath(joinpath(source, "test"))
        runtests = joinpath(source, "test", "runtests.jl")
        sentinel = "TEST-PROCESS-OWN-OUTPUT-3609"
        write(
            runtests, """
            println("$sentinel")
            flush(stdout)
            exit(42)
            """
        )
        # a bare sandbox project dir (the tests import nothing)
        project_dir = mkpath(joinpath(dir, "sandbox"))
        write(joinpath(project_dir, "Project.toml"), "")

        # Drive the subprocess runner directly (autoprecompile=false, no
        # install harness). It pipes the child's stdout/stderr through the op io.
        io = IOBuffer()
        result = run_test_process(
            "Crasher", project_dir, runtests, source;
            coverage = false, julia_args = String[], test_args = String[],
            autoprecompile = false, io,
        )

        # A failing subprocess returns (name, process) rather than nothing.
        @test result !== nothing
        name, p = result
        @test name == "Crasher"

        # FIXED behavior (a): the test process's OWN stdout is surfaced through
        # the op io — not swallowed in favor of a Pkg-internal stacktrace.
        captured = String(take!(io))
        @test occursin(sentinel, captured)

        # FIXED behavior (b): the non-1 exit code is reported verbatim, so the
        # failure annotation names it rather than hiding it.
        @test Base.process_exited(p)
        @test p.exitcode == 42
        @test failure_reason(p) == " (exit code: 42)"

        # And the collected-failure report throws a typed PkgError that carries
        # that exit-code annotation (no internal Pkg/Operations stacktrace).
        err = try
            report_test_failures([(name, p)])
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("(exit code: 42)", sprint(showerror, err))
        @test occursin("Crasher", sprint(showerror, err))
    end
end

@testset "Pkg.jl#3588 rm removes developed external stdlib" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            # A synthetic dev package that impersonates a bundled stdlib
            # (Random's name+UUID) at a bogus high external version — the
            # offline analog of `add <url to a shipped stdlib>`.
            random_uuid = UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c")
            devpkg = joinpath(dir, "Random")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "Random"
                uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
                version = "99.9.0"
                """
            )
            write(joinpath(devpkg, "src", "Random.jl"), "module Random end\n")

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)

            # develop records a valid path-tracked direct dep, not a broken orphan
            # Pkg's test harness disables sysimage-version respect while it
            # substitutes external stdlibs. Mirror that explicit escape hatch:
            # Random is itself baked into the running sysimage.
            developed = plan_develop(
                env, regs, Config(depots; respect_sysimage_versions = false), devpkg,
            )
            @test haskey(developed.manifest, random_uuid)
            @test is_path_tracked(developed.manifest[random_uuid])
            @test developed.project.deps["Random"] == random_uuid

            # persist and reload — entry survives a round-trip
            write_environment(env, developed)
            reloaded = load_environment(envdir; depots)
            @test haskey(reloaded.manifest, random_uuid)
            @test is_path_tracked(reloaded.manifest[random_uuid])

            # rm actually removes it (the bug: rm printed "No Changes" and
            # left a broken leftover entry). Both project dep and manifest
            # entry must be gone.
            removed = plan_rm(reloaded, [PackageRequest("Random")]; mode = :project)
            @test !haskey(removed.project.deps, "Random")
            @test !haskey(removed.manifest, random_uuid)

            # and the removal survives a write + reload
            write_environment(reloaded, removed)
            final = load_environment(envdir; depots)
            @test !haskey(final.project.deps, "Random")
            @test !haskey(final.manifest, random_uuid)
        end
    end
end

@testset "Pkg.jl#3562 compat completion never emits a version string" begin
    local REPLMode = VibePkg.REPLMode
    mktempdir() do dir
        # An active project whose [compat] carries a comma-separated version
        # range string — the exact shape #3562's completion wrongly spliced
        # onto the command line unquoted.
        proj = joinpath(dir, "Project.toml")
        write(
            proj, """
            name = "Root"
            uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

            [deps]
            Example = "$(EXAMPLE_UUID)"

            [compat]
            Example = "0.5, 0.5.1, 1.0"
            """
        )
        oldp = Base.ACTIVE_PROJECT[]
        try
            Base.ACTIVE_PROJECT[] = proj

            # `compat <TAB>` offers dependency NAMES, not versions.
            cands, _ = REPLMode.completions_for("compat ")
            @test "Example" in cands

            # `compat Example <TAB>` re-offers dependency names and must NOT
            # emit a version-like candidate (would splice an unquoted, comma-
            # bearing string that then fails to parse — the #3562 regression).
            cands, _ = REPLMode.completions_for("compat Example ")
            @test cands == VibePkg.REPLMode.environment_dependency_names()
            @test "Example" in cands
            @test all(c -> !occursin(',', c) && !occursin(r"^\d", c), cands)

            # Nothing is completed for a version-position prefix either.
            cands, _ = REPLMode.completions_for("compat Example 0")
            @test isempty(cands)
        finally
            Base.ACTIVE_PROJECT[] = oldp
        end
    end
end

@testset "Pkg.jl#3551 develop path keeps weakdeps/extensions out of deps" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)

        # A synthetic local package with [weakdeps] + [extensions]. Example is a
        # weak-only dep (registered but never force-required, so no fetch), the
        # exact shape of the report's NDTensors/CUDA case.
        foouuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        foodir = mkpath(joinpath(dir, "Foo"))
        write(
            joinpath(foodir, "Project.toml"),
            """
            name = "Foo"
            uuid = "$foouuid"
            version = "0.1.0"

            [weakdeps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"

            [extensions]
            FooExt = "Example"
            """,
        )
        mkpath(joinpath(foodir, "src"))
        write(joinpath(foodir, "src", "Foo.jl"), "module Foo\nend\n")

        projfile = joinpath(mkpath(joinpath(dir, "proj")), "Project.toml")

        old = copy(Base.DEPOT_PATH)
        oldp = Base.ACTIVE_PROJECT[]
        oldg = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = projfile

            # develop by PATH into a fresh env with no prior manifest entry.
            # The report's bug moved the weakdep into [deps] and raised a
            # ResolverError; the fix reads weakdeps/exts from Foo's own
            # Project.toml after install.
            @test VibePkg.develop(; path = foodir, io = devnull) === nothing

            env = load_environment(; depots = depot_stack([depot]))
            entry = env.manifest[UUID(foouuid)]

            @test is_path_tracked(entry)
            # weakdep stays weak, is NOT promoted into deps
            @test EXAMPLE_UUID in values(entry.weakdeps)
            @test !(EXAMPLE_UUID in values(entry.deps))
            # extension section is preserved
            @test entry.exts["FooExt"] == "Example"
        finally
            copy!(Base.DEPOT_PATH, old)
            Base.ACTIVE_PROJECT[] = oldp
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldg
        end
    end
end

@testset "Pkg.jl#3550 free recovers from dev'd dep whose upstream compat exceeds bound" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            dir = realpath(dir)

            # A synthetic local `Example` package to `develop` into, at a
            # version (0.5.1) that satisfies the project's `[compat] 0.5`.
            devex = joinpath(dir, "Example")
            mkpath(joinpath(devex, "src"))
            write(
                joinpath(devex, "Project.toml"), """
                name = "Example"
                uuid = "$EXAMPLE_UUID"
                version = "0.5.1"
                """
            )
            write(joinpath(devex, "src", "Example.jl"), "module Example end\n")

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)

            # (1) add registry Example @0.5.1 and pin project compat to "0.5"
            env = plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])
            env = plan_compat_entry(env, "Example", "0.5")
            write_environment(load_environment(envdir; depots), env)
            env = load_environment(envdir; depots)
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # (2) develop the local Example (still 0.5.1, satisfies compat)
            env = plan_develop(env, regs, cfg, devex)
            write_environment(load_environment(envdir; depots), env)
            env = load_environment(envdir; depots)
            @test is_path_tracked(env.manifest[EXAMPLE_UUID])
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # (3) simulate an "upstream fetch": the on-disk dev Project bumps
            # its version above the project's 0.5 compat bound.
            write(
                joinpath(devex, "Project.toml"), """
                name = "Example"
                uuid = "$EXAMPLE_UUID"
                version = "1.0.0"
                """
            )

            # The bug (#3550): the environment is now wedged — resolve/up can
            # only see the dev'd 1.0.0, which has an empty intersection with the
            # project's 0.5 compat, and there is no recovery through resolve.
            @test_throws VibePkg.Resolve.ResolverError plan_resolve(env, regs, cfg)
            @test_throws VibePkg.Resolve.ResolverError plan_up(env, regs, cfg)

            # The fix: `free` breaks the deadlock — it must NOT get stuck on the
            # "empty intersection" compat error. It drops the dev source and
            # re-resolves the freed package to a registry version within compat.
            freed = plan_free(env, regs, cfg, [PackageRequest("Example", nothing, nothing)])
            entry = freed.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(entry)
            @test !is_path_tracked(entry)
            @test entry_version(entry) == v"0.5.1"

            # …and the environment resolves cleanly again after freeing.
            write_environment(env, freed)
            env = load_environment(envdir; depots)
            resolved = plan_resolve(env, regs, cfg)
            @test entry_version(resolved.manifest[EXAMPLE_UUID]) == v"0.5.1"
        end
    end
end

@testset "Pkg.jl#3545 dev pkg with weakdep into shared env" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # Synthetic local package Foo mirroring HiddenMarkovModels.jl's shape:
            # a [weakdeps] on the registered Example (stand-in for HMMBase) backing
            # an extension. This is the package being `pkg> dev .`'d.
            foo_uuid = UUID("11111111-1111-1111-1111-111111111111")
            foodir = joinpath(dir, "Foo")
            mkpath(joinpath(foodir, "src"))
            write(
                joinpath(foodir, "Project.toml"), """
                name = "Foo"
                uuid = "$foo_uuid"
                version = "0.1.0"

                [weakdeps]
                Example = "$EXAMPLE_UUID"

                [extensions]
                FooExt = "Example"
                """
            )
            write(joinpath(foodir, "src", "Foo.jl"), "module Foo end\n")

            # --- Case 1: shared/named env with a PRE-EXISTING manifest that
            # already has the weakdep (Example) added. This is the exact MWE:
            # `]activate @myenv; dev .` where the env is persistent (non-temp).
            # The reported bug crashed here with "Foo depends on <weakdep>, but no
            # such entry exists in the manifest".
            envdir = mkpath(joinpath(dir, "shared"))
            env0 = load_environment(envdir; depots)
            env1 = plan_add(env0, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])
            write_environment(env0, env1)
            envA = load_environment(envdir; depots)
            @test is_registry_tracked(envA.manifest[EXAMPLE_UUID])

            # dev Foo into that persistent env: must succeed, no PkgError.
            local plannedA
            @test (plannedA = plan_develop(envA, regs, cfg, foodir)) isa
                VibePkg.Environments.Environment
            @test is_path_tracked(plannedA.manifest[foo_uuid])
            @test entry_version(plannedA.manifest[foo_uuid]) == v"0.1.0"
            # the pre-existing weakdep entry is untouched (still registry-tracked)
            @test is_registry_tracked(plannedA.manifest[EXAMPLE_UUID])
            write_environment(envA, plannedA)
            reA = load_environment(envdir; depots)
            @test is_path_tracked(reA.manifest[foo_uuid])

            # --- Case 2: EMPTY persistent named env (weakdep NOT present). dev .
            # must still succeed and must NOT drag the unrelated weakdep Example
            # into the manifest.
            emptydir = mkpath(joinpath(dir, "empty"))
            env0b = load_environment(emptydir; depots)
            local plannedB
            @test (plannedB = plan_develop(env0b, regs, cfg, foodir)) isa
                VibePkg.Environments.Environment
            @test is_path_tracked(plannedB.manifest[foo_uuid])
            # weakdep is not force-added when absent
            @test !haskey(plannedB.manifest, EXAMPLE_UUID)
        end
    end
end

@testset "Pkg.jl#3541 add promotes weakdep to hard dep and resolve keeps it" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            # Project with Example ONLY in [weakdeps], empty [deps]
            write(
                joinpath(envdir, "Project.toml"), """
                name = "MyPkg"
                uuid = "11111111-1111-1111-1111-111111111111"

                [deps]

                [weakdeps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            env0 = load_environment(envdir; depots)
            @test !haskey(env0.project.deps, "Example")
            @test haskey(env0.project.weakdeps, "Example")

            # add Example (currently a weakdep) -> should PROMOTE to a hard dep
            added = plan_add(env0, regs, cfg, [PackageRequest("Example", nothing, nothing)])
            @test added.project.deps["Example"] == EXAMPLE_UUID          # in [deps]
            @test !haskey(added.project.weakdeps, "Example")             # left [weakdeps]
            @test haskey(added.manifest, EXAMPLE_UUID)                   # in manifest
            @test entry_version(added.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # persist and reload: promotion is durable on disk
            @test write_environment(env0, added)
            reloaded = load_environment(envdir; depots)
            @test reloaded.project.deps["Example"] == EXAMPLE_UUID
            @test !haskey(reloaded.project.weakdeps, "Example")
            @test haskey(reloaded.manifest, EXAMPLE_UUID)

            # a subsequent resolve must NOT drop Example (the reported bug)
            resolved = plan_resolve(reloaded, regs, cfg)
            @test resolved.project.deps["Example"] == EXAMPLE_UUID
            @test !haskey(resolved.project.weakdeps, "Example")
            @test haskey(resolved.manifest, EXAMPLE_UUID)
            @test entry_version(resolved.manifest[EXAMPLE_UUID]) == v"0.5.1"
        end
    end
end

@testset "Pkg.jl#3527 add --preserve=all won't upgrade a dep to a julia-incompatible version" begin
    using VibePkg.Configs: PRESERVE_ALL, PRESERVE_NONE

    APP_UUID = UUID("a0000000-0000-0000-0000-0000000000a1")
    LIB_UUID = UUID("b0000000-0000-0000-0000-0000000000b2")

    # A synthetic 2-package registry mirroring #3527: App depends on Lib in the
    # range 1-2. Lib@1.0.0 supports the running julia; Lib@2.0.0 requires a
    # far-future julia (the CompilerSupportLibraries_jll analogue that needed a
    # newer julia than the host). A correct `add --preserve=all` must never move
    # an already-resolved Lib@1.0.0 up to the julia-incompatible Lib@2.0.0.
    make_fixture_registry = function (depot)
        reg = joinpath(depot, "registries", "Fixture3527")
        appdir = joinpath(reg, "A", "App")
        libdir = joinpath(reg, "L", "Lib")
        mkpath(appdir)
        mkpath(libdir)
        write(
            joinpath(reg, "Registry.toml"), """
            name = "Fixture3527"
            uuid = "c0000000-0000-0000-0000-0000000000c3"
            repo = "https://example.com/Fixture3527.git"

            [packages]
            $APP_UUID = { name = "App", path = "A/App" }
            $LIB_UUID = { name = "Lib", path = "L/Lib" }
            """
        )

        write(
            joinpath(appdir, "Package.toml"), """
            name = "App"
            uuid = "$APP_UUID"
            repo = "https://example.com/App.jl.git"
            """
        )
        write(
            joinpath(appdir, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            """
        )
        write(
            joinpath(appdir, "Deps.toml"), """
            ["1"]
            Lib = "$LIB_UUID"
            """
        )
        write(
            joinpath(appdir, "Compat.toml"), """
            ["1"]
            Lib = "1-2"
            julia = "1.6.0-999"
            """
        )

        write(
            joinpath(libdir, "Package.toml"), """
            name = "Lib"
            uuid = "$LIB_UUID"
            repo = "https://example.com/Lib.jl.git"
            """
        )
        write(
            joinpath(libdir, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "2222222222222222222222222222222222222222"

            ["2.0.0"]
            git-tree-sha1 = "3333333333333333333333333333333333333333"
            """
        )
        # Lib@1.0.0 fits the running julia; Lib@2.0.0 demands a far-future julia
        # (excludes any real host), so it must never be selected.
        write(
            joinpath(libdir, "Compat.toml"), """
            ["1.0.0"]
            julia = "1.6.0-999"

            ["2.0.0"]
            julia = "999.0.0-999"
            """
        )
        return reg
    end

    mktempdir() do depot
        make_fixture_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)

        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)

            # Seed the env: resolve App -> Lib. The resolver must land on Lib@1.0.0
            # because Lib@2.0.0's julia compat excludes the running host.
            seeded = plan_add(env, regs, cfg, [PackageRequest("App", nothing, "1.0.0")])
            @test entry_version(seeded.manifest[APP_UUID]) == v"1.0.0"
            @test entry_version(seeded.manifest[LIB_UUID]) == v"1.0.0"

            # Persist and reload so we start from a real, already-resolved manifest
            # (the shape of the reporter's "env already resolved" state).
            write_environment(env, seeded)
            resolved_env = load_environment(envdir; depots)
            @test entry_version(resolved_env.manifest[LIB_UUID]) == v"1.0.0"

            # The #3527 core: `add --preserve=all App@1.0.0` must HOLD every existing
            # manifest entry. Before the fix, the transitive Lib was free to upgrade
            # to Lib@2.0.0 — a version whose julia compat excludes the host. FIXED:
            # Lib stays pinned at 1.0.0 and no julia-incompatible version is chosen.
            plan = plan_add(
                resolved_env, regs, cfg, [PackageRequest("App", nothing, "1.0.0")];
                preserve = PRESERVE_ALL,
            )
            @test entry_version(plan.manifest[APP_UUID]) == v"1.0.0"
            @test entry_version(plan.manifest[LIB_UUID]) == v"1.0.0"

            # Control: even with preserve=none the resolver still refuses the
            # julia-incompatible Lib@2.0.0 and holds Lib@1.0.0 — confirming the
            # fixture's julia gate is what rules out the bad upgrade, not luck.
            plan_none = plan_add(
                resolved_env, regs, cfg, [PackageRequest("App", nothing, "1.0.0")];
                preserve = PRESERVE_NONE,
            )
            @test entry_version(plan_none.manifest[LIB_UUID]) == v"1.0.0"
        end
    end
end

@testset "Pkg.jl#3518 resolve works when deps are not instantiated" begin
    # Report: in an environment whose registry-tracked deps are NOT installed
    # on disk, `resolve` errored with "Expected package Foo to exist at path
    # ...". resolve must instead recompute the manifest from project+registry
    # without requiring the dependency to be present on disk. The disk-existence
    # error lives in collect_fixed, which resolve_with_preserve only feeds
    # path/repo-tracked nodes, so a registry-tracked dep must resolve fine with
    # nothing installed.
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            projdir = mkpath(joinpath(dir, "proj"))
            write(joinpath(projdir, "Project.toml"), "")

            # Build a manifest that pins Example 0.5.1 (registry-tracked), then
            # persist and reload it — WITHOUT ever installing anything.
            env0 = load_environment(projdir; depots)
            env1 = plan_add(env0, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])
            write_environment(env0, env1)

            env = load_environment(projdir; depots)
            @test is_registry_tracked(env.manifest[EXAMPLE_UUID])
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # Nothing is installed on disk: the depot has no populated package
            # tree for Example.
            pkgdir = joinpath(depot, "packages")
            @test !isdir(pkgdir) || isempty(readdir(pkgdir))

            # resolve on the un-instantiated env must NOT throw the disk-existence
            # error; it recomputes the manifest from project + registry.
            local resolved
            @test (resolved = plan_resolve(env, regs, cfg)) isa VibePkg.Environments.Environment
            @test haskey(resolved.manifest, EXAMPLE_UUID)
            @test is_registry_tracked(resolved.manifest[EXAMPLE_UUID])
            @test entry_version(resolved.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # still nothing installed — resolve did not require instantiation.
            @test !isdir(pkgdir) || isempty(readdir(pkgdir))
        end
    end
end

@testset "Pkg.jl#3463 registry status lists same-named registries in every depot" begin
    mktempdir() do dir
        d1 = mkpath(joinpath(dir, "d1"))
        d2 = mkpath(joinpath(dir, "d2"))
        make_test_registry(d1)
        make_test_registry(d2)
        # discovery layer already sees both (same name+uuid, one per depot)
        @test length(reachable_registries(depot_stack([d1, d2]))) == 2

        # status layer reads Base.DEPOT_PATH; drive it with both depots and
        # capture output. Offline avoids any package-server query.
        old = copy(Base.DEPOT_PATH)
        oldoff = VibePkg.API.OFFLINE_MODE[]
        try
            VibePkg.API.OFFLINE_MODE[] = true
            copy!(Base.DEPOT_PATH, [d1, d2])
            buf = IOBuffer()
            VibePkg.Registry.status(; io = buf)
            out = String(take!(buf))
            # both instances of the same-named registry printed, one header
            # (`[23338594] TestRegistry`) per depot. The bug would print only one.
            @test count("[23338594] TestRegistry", out) == 2
        finally
            copy!(Base.DEPOT_PATH, old)
            VibePkg.API.OFFLINE_MODE[] = oldoff
        end
    end
end

@testset "Pkg.jl#3434 rev resolves against actual default branch (not hardcoded master)" begin
    Git = VibePkg.Git
    mktempdir() do dir
        # Build a git repo whose ONLY branch is `main` (no master anywhere),
        # plus a tag. `git init -b main` forces the default branch regardless
        # of the host's init.defaultBranch config.
        src = joinpath(dir, "MainPkg")
        mkpath(joinpath(src, "src"))
        write(
            joinpath(src, "Project.toml"), """
            name = "MainPkg"
            uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
            version = "0.1.0"
            """
        )
        write(joinpath(src, "src", "MainPkg.jl"), "module MainPkg end\n")
        git(a...) = run(
            setenv(
                `git -C $src $a`,
                "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@e.x",
                "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@e.x"
            )
        )
        git("init", "-q", "-b", "main")
        git("add", ".")
        git("commit", "-q", "-m", "initial")
        git("tag", "v0.1.0")

        # Guard the premise: the repo really has `main` and no `master`.
        branches = readchomp(`git -C $src branch --list`)
        @test occursin("main", branches)
        @test !occursin("master", branches)

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # rev = nothing must read the repository's actual default branch
        # (`main`) rather than assuming `master`. The pre-fix bug raised
        # "invalid git HEAD (reference 'refs/heads/master' not found)".
        rp = Git.materialize_repo_package!(depots, src; io = devnull)
        @test rp.name == "MainPkg"
        @test rp.rev == "main"

        # an explicit rev = "main" resolves through the fetch/lookup path
        rp_main = Git.materialize_repo_package!(depots, src; rev = "main", io = devnull)
        @test rp_main.rev == "main"
        @test rp_main.tree_hash == rp.tree_hash

        # a tag on that same branch resolves too
        rp_tag = Git.materialize_repo_package!(depots, src; rev = "v0.1.0", io = devnull)
        @test rp_tag.rev == "v0.1.0"
        @test rp_tag.tree_hash == rp.tree_hash
    end
end

@testset "Pkg.jl#3412 up does not re-download an up-to-date registry" begin
    # server-backed "General" installed from the local pkg server; an update
    # against the same server must be a no-op (Pkg.jl#3412: `up` used to
    # unconditionally re-download the registry no matter the options).
    LocalPkgServer.ensure!()
    server = VibePkg.Configs.pkg_server()
    @test server !== nothing
    Dates = VibePkg.Registries.Dates
    mktempdir() do depot
        depots = depot_stack([depot])
        added = VibePkg.Registries.add_default_registries!(depots; io = devnull)
        @test "General" in added

        reg_dir = joinpath(depot, "registries")
        snapshot() = Dict(
            f => (mtime(joinpath(reg_dir, f)), stat(joinpath(reg_dir, f)).inode)
                for f in readdir(reg_dir)
        )
        before = snapshot()

        # cooldown ~0 defeats the persisted-log cooldown skip, so the skip is
        # forced through the tree-hash comparison (installed == server) — the
        # actual fix — rather than a trivial time gate.
        buf = IOBuffer()
        updated = VibePkg.Registries.update_registries!(
            depots; server, io = buf, update_cooldown = Dates.Millisecond(0),
        )
        @test isempty(updated)                                   # nothing re-downloaded
        @test !occursin("Updating registry", String(take!(buf))) # no unconditional print
        @test snapshot() == before                               # installed files untouched

        # a second, immediate update in the same session is likewise a no-op:
        # the literal MWE (session already updated) must not re-download either
        buf2 = IOBuffer()
        @test isempty(
            VibePkg.Registries.update_registries!(
                depots; server, io = buf2, update_cooldown = Dates.Millisecond(0),
            )
        )
        @test isempty(String(take!(buf2)))
        @test snapshot() == before
    end
end

@testset "Pkg.jl#3411 add by url with explicit uuid" begin
    # Reproduces the MWE `Pkg.add(PackageSpec(url=..., uuid=...))`. On the
    # url path the spec's name is `nothing` — the bug's precondition. Old Pkg
    # crashed in the sysimage check with
    # `MethodError: no method matching Base.PkgId(::UUID, ::Nothing)`.
    fx = LocalPkgServer.ensure!()
    git_repo = fx.git_repo
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        projfile = joinpath(mkpath(joinpath(dir, "proj")), "Project.toml")

        old = copy(Base.DEPOT_PATH)
        oldp = Base.ACTIVE_PROJECT[]
        oldg = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        olda = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = projfile

            spec = VibePkg.API.PackageSpec(url = git_repo, uuid = EXAMPLE_UUID)
            @test spec.name === nothing        # the bug's precondition
            @test spec.uuid == UUID(EXAMPLE_UUID)

            # The fixed behavior: add succeeds (no MethodError PkgId(::UUID,::Nothing)).
            @test VibePkg.add([spec]; io = devnull) === nothing

            env = load_environment(; depots = depot_stack([depot]))
            entry = env.manifest[UUID(EXAMPLE_UUID)]
            @test entry.name == "Example"
            # url-tracked, and the source url is recorded in the project
            @test VibePkg.EnvFiles.is_repo_tracked(entry)
            @test haskey(env.project.sources, "Example")
        finally
            copy!(Base.DEPOT_PATH, old)
            Base.ACTIVE_PROJECT[] = oldp
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldg
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = olda
        end
    end
end

@testset "Pkg.jl#3335 pin version with build metadata rejected cleanly" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            cfg = Config(depots)

            # Install Example first so the pin has something to act on.
            planned = plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # The reported symptom (#3335) was a raw `ArgumentError: invalid
            # base 10 digit '+'` leaking out of `pin FakePkg@0.1.2+3`. The
            # guard in request_version_spec must convert that into a clean
            # PkgError before it reaches the user on the pin path too.
            err = try
                plan_pin(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.1+3")])
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test !(err isa ArgumentError)
            @test occursin("invalid version specifier", lowercase(sprint(showerror, err)))
        end
    end
end

@testset "Pkg.jl#3138 add REPL vs API path#rev parity" begin
    import LibGit2
    using VibePkg.REPLMode: parse_package_word
    using VibePkg.EnvFiles: entry_repo_rev, entry_repo_url, is_repo_tracked

    mktempdir() do dir
        # A local git repo holding package `Foo`, with a `mybranch` branch,
        # standing in offline for the network MWE (oheil/Luxor.jl#multi_drawing).
        foo_uuid = UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")
        src = joinpath(dir, "Foo")
        mkpath(joinpath(src, "src"))
        write(
            joinpath(src, "Project.toml"), """
            name = "Foo"
            uuid = "$foo_uuid"
            version = "0.1.0"
            """
        )
        write(joinpath(src, "src", "Foo.jl"), "module Foo end\n")
        repo = LibGit2.init(src)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("tester", "tester@example.com")
        LibGit2.commit(repo, "initial"; author = sig, committer = sig)
        LibGit2.branch!(repo, "mybranch")
        LibGit2.close(repo)

        # Core mechanism: the REPL word `<repo>#mybranch` and the API kwargs
        # build the SAME immutable PackageSpec — a single rev "mybranch",
        # never a doubled "mybranch#<default>".
        spec_repl = parse_package_word(src * "#mybranch")
        spec_api = VibePkg.PackageSpec(path = src, rev = "mybranch")
        @test spec_repl.path == src
        @test spec_repl.rev == "mybranch"
        @test spec_repl.url === nothing
        @test spec_repl == spec_api

        # End to end: adding both ways into separate envs yields identical
        # repo-tracked manifest entries (same url, same rev — no doubling).
        depot = mkpath(joinpath(dir, "depot"))
        # a registry-less depot would bootstrap General over git (Pkg parity)
        make_test_registry(depot)
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        env_repl = mkpath(joinpath(dir, "env_repl"))
        env_api = mkpath(joinpath(dir, "env_api"))
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            withenv("JULIA_PKG_SERVER" => "") do
                Base.ACTIVE_PROJECT[] = joinpath(env_repl, "Project.toml")
                VibePkg.add([spec_repl]; io = devnull)
                Base.ACTIVE_PROJECT[] = joinpath(env_api, "Project.toml")
                VibePkg.add(path = src, rev = "mybranch", io = devnull)
            end
        finally
            copy!(Base.DEPOT_PATH, old_depots)
            Base.ACTIVE_PROJECT[] = old_active
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end

        depots = depot_stack([depot])
        e_repl = load_environment(env_repl; depots).manifest[foo_uuid]
        e_api = load_environment(env_api; depots).manifest[foo_uuid]
        @test is_repo_tracked(e_repl) && is_repo_tracked(e_api)
        @test entry_repo_rev(e_repl) == "mybranch"
        @test entry_repo_rev(e_repl) == entry_repo_rev(e_api)
        @test entry_repo_url(e_repl) == entry_repo_url(e_api) == src

        # The report's actual misuse `add(path="<repo>#mybranch")` must NOT
        # silently produce a doubled rev — it errors cleanly on a missing path.
        @test_throws PkgError VibePkg.add(path = src * "#mybranch", io = devnull)
    end
end

@testset "Pkg.jl#3119 up upgrades and never downgrades" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # Seed the manifest at the OLDER installable version 0.5.0.
            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)
            seeded = plan_add(env0, regs, cfg, [PackageRequest("Example", nothing, "0.5.0")])
            @test entry_version(seeded.manifest[EXAMPLE_UUID]) == v"0.5.0"
            write_environment(env0, seeded)
            env = load_environment(envdir; depots)

            # `up` must UPGRADE 0.5.0 -> 0.5.1 (symptom A was: up leaves it stuck).
            up_all = plan_up(env, regs, cfg)
            @test entry_version(up_all.manifest[EXAMPLE_UUID]) == v"0.5.1"
            up_tgt = plan_up(env, regs, cfg, [PackageRequest("Example", nothing, nothing)])
            @test entry_version(up_tgt.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # Now seed at the NEWEST installable 0.5.1 and confirm `up` never
            # DOWNGRADES it to 0.5.0 (symptom B, the reported bug), nor jumps to
            # the yanked 1.0.0.
            envdir2 = mkpath(joinpath(dir, "env2"))
            e0 = load_environment(envdir2; depots)
            seeded2 = plan_add(e0, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])
            @test entry_version(seeded2.manifest[EXAMPLE_UUID]) == v"0.5.1"
            write_environment(e0, seeded2)
            env2 = load_environment(envdir2; depots)

            @test entry_version(plan_up(env2, regs, cfg).manifest[EXAMPLE_UUID]) == v"0.5.1"
            @test entry_version(
                plan_up(env2, regs, cfg, [PackageRequest("Example", nothing, nothing)]).manifest[EXAMPLE_UUID],
            ) == v"0.5.1"
        end
    end
end

@testset "Pkg.jl#3063 compat viewer/editor works on non-TTY io" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        old = copy(Base.DEPOT_PATH)
        oldp = Base.ACTIVE_PROJECT[]
        oldg = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            projdir = mkpath(joinpath(dir, "proj"))
            projfile = joinpath(projdir, "Project.toml")
            write(
                projfile, """
                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

                [compat]
                Example = "0.5"
                julia = "1"
                """
            )
            Base.ACTIVE_PROJECT[] = projfile

            # The reported bug: invoking the interactive compat editor with an
            # io that isn't a real TTY did a raw!/ccall on io.handle and errored.
            # In VibePkg the compat surface just prints/edits and must never
            # touch raw-mode on a non-TTY io. The viewer path must run clean.
            iobuf = IOBuffer()
            @test (VibePkg.compat(; io = iobuf); true)
            out = String(take!(iobuf))
            @test occursin("Compat", out)
            @test occursin("Example", out)
        finally
            copy!(Base.DEPOT_PATH, old)
            Base.ACTIVE_PROJECT[] = oldp
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldg
        end
    end
end

@testset "Pkg.jl#2743 clean up bad registry tarball on EOF" begin
    using Base: SHA1
    local tree_hash = VibePkg.TreeHash.tree_hash
    local registries_dir = VibePkg.Depots.registries_dir
    local GENERAL_UUID = VibePkg.Registries.GENERAL_UUID
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        # a minimal but valid directory registry to pack into a tarball
        regdir = mkpath(joinpath(dir, "registry"))
        write(
            joinpath(regdir, "Registry.toml"), """
            name = "General"
            uuid = "$GENERAL_UUID"
            repo = "https://example.invalid/General"

            [packages]
            """
        )
        hash = SHA1(bytes2hex(tree_hash(regdir)))

        # serve the tarball at /registry/<uuid>/<hash>, but TRUNCATED to half
        # its bytes so decompression/tree-hash verification hits EOF
        files = mkpath(joinpath(dir, "files"))
        tarball = joinpath(files, "registry", string(GENERAL_UUID), string(hash))
        LocalPkgServer.gzip_tarball(regdir, tarball)
        bytes = read(tarball)
        write(tarball, bytes[1:(length(bytes) ÷ 2)])

        srv = LocalPkgServer.start_server(files)
        try
            # the issue's crash: EOF while verifying the corrupt tarball
            @test_throws EOFError VibePkg.Registries.install_server_registry!(
                depot, srv.url, GENERAL_UUID, hash; io = devnull
            )
            # FIXED behavior: nothing bad is left behind — no half .tar.gz and
            # no stub .toml under registries/ (the download went to a tempname
            # outside the registries dir and was cleaned up)
            rd = registries_dir(depot)
            @test !isdir(rd) || isempty(readdir(rd))
        finally
            close(srv.server)
        end
    end
end

@testset "Pkg.jl#2664 Overrides.toml suppresses artifact download" begin
    # MWE: an Overrides.toml hash-form redirect for a non-lazy artifact must
    # stop the original (undownloadable) artifact from being scheduled for
    # download, mirroring the report's IntelOpenMP_jll / Overrides.toml case.
    toml_path(p) = replace(p, '\\' => '/')
    mktempdir() do dir
        # a package declaring one non-lazy artifact with an unreachable source
        hash = "1d5cc7b8" * "0"^32                 # fixed git-tree-sha1 (as in the report)
        pkg = mkpath(joinpath(dir, "IntelOpenMP_jll"))
        write(
            joinpath(pkg, "Artifacts.toml"), """
            [IntelOpenMP]
            git-tree-sha1 = "$hash"

                [[IntelOpenMP.download]]
                url = "https://example.invalid/intelopenmp.tar.gz"
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # CONTROL: with no Overrides.toml the artifact IS scheduled for install
        installs = VibePkg.ArtifactOps.collect_artifact_installs(depots, pkg)
        @test length(installs) == 1
        @test first(installs)[1] == "IntelOpenMP"

        # override the artifact to a local dir via <depot>/artifacts/Overrides.toml
        override_dir = mkpath(joinpath(dir, "local-intelopenmp"))
        mkpath(joinpath(depot, "artifacts"))
        write(
            joinpath(depot, "artifacts", "Overrides.toml"), """
            $hash = "$(toml_path(override_dir))"
            """
        )

        # FIXED behavior: the overridden artifact is NOT scheduled for download
        @test isempty(VibePkg.ArtifactOps.collect_artifact_installs(depots, pkg))
    end
end

@testset "Pkg.jl#2615 Overrides.toml redirect must not mark downloaded pkg as →" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1")])
            entry = env.manifest[EXAMPLE_UUID]
            @test entry_version(entry) == v"0.5.1"

            # Materialize Example's source tree so it counts as "downloaded".
            th = VibePkg.EnvFiles.entry_tree_hash(entry)
            srcpath = VibePkg.Depots.find_installed(depots, "Example", EXAMPLE_UUID, th)[1]
            mkpath(srcpath)

            # Reproduce the #2615 trigger: an artifacts Overrides.toml redirecting
            # Example's UUID to a now-invalid path in the depot. This is unrelated
            # to package source and must NOT influence the `→` status marker.
            artdir = mkpath(joinpath(depot, "artifacts"))
            write(
                joinpath(artdir, "Overrides.toml"), """
                [7876af07-990d-54b4-ab0e-23690620f79a]
                some_artifact = "/nonexistent/invalid/path"
                """
            )

            # Fixed behavior: source tree present => downloaded, regardless of the redirect.
            @test VibePkg.Display.entry_downloaded(env, EXAMPLE_UUID, entry, depots) == true
            out = sprint(io -> VibePkg.Display.print_status(io, env; depots))
            @test occursin("Example", out)
            @test !occursin("→", out)
            @test !occursin("not downloaded", out)

            # Negative control: the `→` mechanism is live — removing the source tree
            # (with the same Overrides.toml still in place) DOES flag it.
            Base.rm(srcpath; recursive = true, force = true)
            @test VibePkg.Display.entry_downloaded(env, EXAMPLE_UUID, entry, depots) == false
            out2 = sprint(io -> VibePkg.Display.print_status(io, env; depots))
            @test occursin("→", out2)
            @test occursin("not downloaded", out2)
        end
    end
end

@testset "Pkg.jl#2590 artifact download failure is reported" begin
    local AO = VibePkg.ArtifactOps
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        hash = "0000000000000000000000000000000000000001"
        # a package root declaring one non-lazy artifact whose only download
        # source is unreachable (isolate!'s dead proxy blocks it)
        pkg = mkpath(joinpath(dir, "BlockedPkg"))
        write(
            joinpath(pkg, "Artifacts.toml"), """
            [foo]
            git-tree-sha1 = "$hash"

                [[foo.download]]
                url = "https://blocked.invalid/foo.tar.gz"
                sha256 = "$("0"^64)"
            """
        )
        # a non-lazy artifact is collected for install
        installs = AO.collect_artifact_installs(depots, pkg)
        @test length(installs) == 1
        name, meta = installs[1]
        @test name == "foo"

        # the download failure must be REPORTED, not silently swallowed: with a
        # pkg server configured the install throws PkgError naming *both* the
        # failed server endpoint and the download URL (rather than proceeding
        # as though the artifact were absent)
        err = @test_throws PkgError AO.ensure_artifact_installed!(
            depots, name, meta; server = "https://pkgserver.invalid", io = devnull,
        )
        msg = sprint(showerror, err.value)
        @test occursin("failed to install artifact", lowercase(msg))
        @test occursin("https://blocked.invalid/foo.tar.gz", msg)
        @test occursin("https://pkgserver.invalid", msg)

        # and with no pkg server, the sole download URL is still surfaced
        err2 = @test_throws PkgError AO.ensure_artifact_installed!(
            depots, name, meta; server = nothing, io = devnull,
        )
        msg2 = sprint(showerror, err2.value)
        @test occursin("failed to install artifact", lowercase(msg2))
        @test occursin("https://blocked.invalid/foo.tar.gz", msg2)
    end
end

@testset "Pkg.jl#2584 interrupted/corrupt registry update leaves registry intact" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        # a private copy of the fixture files so we can republish a bogus index
        files = joinpath(dir, "files")
        cp(joinpath(ENV["VIBEPKG_TEST_FIXTURES"], "files"), files)
        srv = LocalPkgServer.start_server(files)
        try
            depot = mkpath(joinpath(dir, "depot"))
            depots = depot_stack([depot])
            reg_dir = joinpath(depot, "registries")

            # bootstrap a real, usable General registry from the local server
            withenv("JULIA_PKG_SERVER" => srv.url) do
                added = VibePkg.Registries.add_default_registries!(depots; io = devnull)
                @test !isempty(added)
            end

            # snapshot the installed registries dir byte-for-byte
            snapshot = root -> begin
                d = Dict{String, Vector{UInt8}}()
                for (r, _, fs) in walkdir(root), f in fs
                    p = joinpath(r, f)
                    d[relpath(p, root)] = read(p)
                end
                d
            end
            before = snapshot(reg_dir)
            @test !isempty(before)

            # republish the index: advertise a fabricated NEW tree hash whose
            # tarball body is corrupt (not a tarball at all). This models the
            # torn state a ctrl-C mid-download / bad transfer produces.
            bogus_hash = "0123456789abcdef0123456789abcdef01234567"
            corrupt = joinpath(files, "registry", LocalPkgServer.GENERAL_UUID, bogus_hash)
            mkpath(dirname(corrupt))
            write(corrupt, "this is not a gzip tarball\n")
            write(joinpath(files, "registries"), "/registry/$(LocalPkgServer.GENERAL_UUID)/$bogus_hash\n")

            # force an update (cooldown 0 so it actually attempts the download);
            # the fixed code downloads to a temp path outside the registries dir,
            # verifies the decompressed tree hash, and refuses to swap on failure
            updated = withenv("JULIA_PKG_SERVER" => srv.url) do
                VibePkg.Registries.update_registries!(
                    depots;
                    update_cooldown = VibePkg.Registries.Dates.Second(0),
                    io = devnull,
                )
            end

            # FIXED behavior: General was NOT reported updated, and the on-disk
            # registry is byte-for-byte unchanged (no partial/corrupt swap)
            @test !("General" in updated)
            @test snapshot(reg_dir) == before

            # ...and the registry is still fully usable afterwards
            regs = reachable_registries(depots)
            @test any(r -> VibePkg.Registries.registry_name(r) == "General", regs)
            mktempdir() do envdir
                env = load_environment(envdir; depots)
                planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
                @test entry_version(planned.manifest[EXAMPLE_UUID]) >= v"0.5.5"
            end
        finally
            close(srv.server)
        end
    end
end

@testset "Pkg.jl#2451 pin preserves unrelated manifest versions" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # synthetic path package depending on the registered Example
            root_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            rootdir = mkpath(joinpath(dir, "Root"))
            write(
                joinpath(rootdir, "Project.toml"), """
                name = "Root"
                uuid = "$root_uuid"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            ROOT = UUID(root_uuid)

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)

            # force unrelated Example DOWN to the older 0.5.0 (registry also
            # has 0.5.1, which a naive resolve would prefer)
            env = plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.0")])
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.0"

            # develop the synthetic package; Example stays preserved at 0.5.0
            env = plan_develop(env, regs, cfg, rootdir)
            @test is_path_tracked(env.manifest[ROOT])
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.0"

            # THE FIX (Pkg.jl#2451): pinning Root must not resolve/bump the
            # unrelated Example from 0.5.0 up to 0.5.1
            env = plan_pin(env, regs, cfg, [PackageRequest("Root", nothing, nothing)])
            @test env.manifest[ROOT].pinned
            @test is_path_tracked(env.manifest[ROOT])
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.0"
        end
    end
end

@testset "Pkg.jl#2433 registry update is independent of the active project" begin
    local Registries = VibePkg.Registries
    fx = LocalPkgServer.ensure!()  # starts the local server, sets JULIA_PKG_SERVER
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        # fresh-depot bootstrap: install General as a packed server registry
        Registries.add_default_registries!(depots; io = devnull)
        stub = joinpath(depot, "registries", "General.toml")
        @test isfile(stub)
        # the freshly installed stub records the server's current tree hash
        current = Registries.TOML.parsefile(stub)["git-tree-sha1"]::String
        @test current == fx.registry_hash

        # an activated project (a real Project.toml on disk) to point at
        projdir = mkpath(joinpath(dir, "proj"))
        proj = joinpath(projdir, "Project.toml")
        write(proj, "")

        # force update_registries! to actually re-fetch: rewrite the stub's
        # git-tree-sha1 to a stale value and clear the per-registry cooldown
        stale = "0000000000000000000000000000000000000000"
        function force_refetch()
            s = Registries.TOML.parsefile(stub)
            s["git-tree-sha1"] = stale
            open(io -> Registries.TOML.print(io, s), stub, "w")
            Base.rm(Registries.registry_update_log_file(depot); force = true)
            return
        end

        # run the very path `up` uses (op_context with :force) once from an
        # activated project and once from the default (no active project);
        # both must refetch and restore the stub to the correct tree hash
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot])
            function run_from(active)
                force_refetch()
                @test Registries.TOML.parsefile(stub)["git-tree-sha1"] == stale
                Base.ACTIVE_PROJECT[] = active
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                VibePkg.API.op_context(; io = devnull, update_registry = :force)
                return Registries.TOML.parsefile(stub)["git-tree-sha1"]::String
            end

            from_project = run_from(proj)      # bug #2433: this used to fail to fetch
            from_default = run_from(nothing)

            @test from_project == fx.registry_hash
            @test from_default == fx.registry_hash
            @test from_project == from_default
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

@testset "Pkg.jl#2381 add does not blame the dependency for a broken project package" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        # the ACTIVE project package `Foo` is syntactically broken and will
        # never precompile; the bug was that adding a dependency blamed the
        # dependency ("1 dependency errored" / "✗ Foo") for Foo's failure.
        write(
            joinpath(envdir, "Project.toml"), """
            name = "Foo"
            uuid = "f00df00d-1111-2222-3333-444444444444"
            version = "0.1.0"
            """
        )
        mkpath(joinpath(envdir, "src"))
        write(joinpath(envdir, "src", "Foo.jl"), "module Foo\nf(\nend\n")

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = true
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            out = IOBuffer()
            # opt back into auto-precompile (isolate! disabled it globally)
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "true") do
                @test VibePkg.add("Example"; io = out) === nothing
            end
            text = String(take!(out))
            # add narrows auto-precompile to the added package's closure, so
            # the dependency precompiles cleanly and the broken project
            # package Foo is never touched / never blamed.
            if Base.JLOptions().use_compiled_modules == 1
                @test occursin("✓ Example", text)
            else
                @test !occursin("Precompiling", text)
            end
            @test !occursin("✗ Foo", text)
            @test !occursin("dependency errored", text)
            reloaded = load_environment(joinpath(envdir, "Project.toml"); depots = depot_stack(copy(Base.DEPOT_PATH)))
            @test entry_version(reloaded.manifest[UUID("7876af07-990d-54b4-ab0e-23690620f79a")]) >= v"0.5.0"
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

@testset "Pkg.jl#2368 archive format from magic bytes not URL extension" begin
    local Fetch = VibePkg.Fetch
    local Tar = VibePkg.Fetch.Tar
    local Zstd = VibePkg.Fetch.Zstd_jll

    # Build source content and a plain tar of it.
    mktempdir() do work
        src = mkpath(joinpath(work, "src"))
        write(joinpath(src, "hello.txt"), "hello 2368\n")
        mkpath(joinpath(src, "sub"))
        write(joinpath(src, "sub", "b.txt"), "nested\n")

        tarpath = joinpath(work, "content.tar")
        open(tarpath, "w") do io
            Tar.create(src, io)
        end

        # A zstd tarball, but named with a WRONG (.gz) extension — as if a
        # random-id URL / Content-Disposition mismatch handed us this name.
        zst_wrongext = joinpath(work, "download.gz")
        run(pipeline(`$(Zstd.zstd()) -q -c $tarpath`, stdout = zst_wrongext))

        # A gzip tarball, but named with a WRONG (.zst) extension and with no
        # extension at all (the reported Google-Drive/Dropbox scenario).
        gz_wrongext = joinpath(work, "download.zst")
        gz_noext = joinpath(work, "uc_export_download_id_RANDOM")
        run(`$(Fetch.p7zip_jll.p7zip()) a -tgzip -bso0 -bsp0 $gz_wrongext $tarpath`)
        cp(gz_wrongext, gz_noext)

        # Format must be decided by magic bytes, never by the filename.
        @test occursin("zstd", string(Fetch.get_extract_cmd(zst_wrongext)))
        @test occursin("7z", string(Fetch.get_extract_cmd(gz_wrongext)))
        @test occursin("7z", string(Fetch.get_extract_cmd(gz_noext)))

        # And unpack must extract the original tree regardless of the name.
        for f in (zst_wrongext, gz_wrongext, gz_noext)
            dest = mktempdir(work)
            Fetch.unpack(f, dest)
            @test read(joinpath(dest, "hello.txt"), String) == "hello 2368\n"
            @test read(joinpath(dest, "sub", "b.txt"), String) == "nested\n"
        end
    end
end

@testset "Pkg.jl#1654 relative dev resolves without mangled/duplicated path" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            dir = realpath(dir)
            local entry_path = VibePkg.EnvFiles.entry_path
            app = mkpath(joinpath(dir, "App"))
            pkga_uuid = "aaaaaaaa-1111-2222-3333-444444444444"
            pkgb_uuid = "bbbbbbbb-1111-2222-3333-444444444444"
            # App/PkgA — the package to be dev'd
            pkga = mkpath(joinpath(app, "PkgA"))
            write(
                joinpath(pkga, "Project.toml"), """
                name = "PkgA"
                uuid = "$pkga_uuid"
                version = "0.1.0"
                """
            )
            # App/PkgB — the active project, dev happens from here
            pkgb = mkpath(joinpath(app, "PkgB"))
            write(
                joinpath(pkgb, "Project.toml"), """
                name = "PkgB"
                uuid = "$pkgb_uuid"
                version = "0.1.0"
                """
            )

            env = load_environment(pkgb; depots)
            # develop a RELATIVE path "../PkgA" (relative to the active project PkgB)
            planned = plan_develop(env, regs, Config(depots), joinpath("..", "PkgA"))

            uuida = UUID(pkga_uuid)
            expected = joinpath("..", "PkgA")
            # [sources] keeps the given relative path — no absolute/duplicated mangling
            @test planned.project.sources["PkgA"].path == expected
            @test is_path_tracked(planned.manifest[uuida])
            @test entry_path(planned.manifest[uuida]) == expected
            # explicitly assert the mangled duplicate path from the bug is NOT produced
            @test !occursin("~", planned.project.sources["PkgA"].path)
            @test !occursin(app, planned.project.sources["PkgA"].path)

            # persist + reload: PkgB's Project.toml is updated in place with the
            # clean path (stored /-separated on all platforms)
            @test write_environment(env, planned)
            reloaded = load_environment(pkgb; depots)
            @test reloaded.project.sources["PkgA"].path == slashpath(expected)
            @test entry_path(reloaded.manifest[uuida]) == expected

            # no literal '~' directory (nor mangled duplicate tree) created anywhere
            offenders = String[]
            for (root, dirs, _) in walkdir(dir)
                for d in dirs
                    d == "~" && push!(offenders, joinpath(root, d))
                end
            end
            @test isempty(offenders)

            # a non-resolvable relative path must error CLEANLY, not silently mangle
            @test_throws PkgError plan_develop(env, regs, Config(depots), joinpath(".", "PkgA"))
        end
    end
end

@testset "Pkg.jl#1155 multi-range compat serializes as a string, not a TOML array" begin
    local Compat = VibePkg.EnvFiles.Compat
    local semver_spec = VibePkg.Versions.semver_spec
    local TOML = VibePkg.EnvFiles.TOML

    # The bug (Pkg.jl#1155): a VersionSpec with multiple ranges could be printed as
    # an invalid bare TOML array like `julia = [0.1, 0.8-1]`. VibePkg serializes the
    # original compat string instead, and never hands a VersionSpec to TOML.print.
    compat_str = "0.1, 0.8 - 1"
    spec = semver_spec(compat_str)
    @test length(spec.ranges) > 1   # genuinely multi-range, the trigger condition

    proj = VibePkg.EnvFiles.Project()
    proj.compat["julia"] = Compat(spec, compat_str)

    io = IOBuffer()
    VibePkg.EnvFiles.write_project(io, proj)
    out = String(take!(io))

    # Fixed behavior: emitted as a quoted string, not a bracketed array.
    @test occursin("julia = \"0.1, 0.8 - 1\"", out)
    @test !occursin("julia = [", out)   # NOT the invalid bare-array form

    # And it round-trips back to a String (not a Vector) through TOML.
    parsed = TOML.parse(out)
    @test parsed["compat"]["julia"] isa AbstractString
    @test !(parsed["compat"]["julia"] isa AbstractVector)
    @test parsed["compat"]["julia"] == compat_str

    # The reported invalid path — passing a raw VersionSpec straight to TOML.print —
    # does NOT silently emit an invalid array; VibePkg's writer rejects unknown types.
    @test_throws PkgError VibePkg.EnvFiles.write_project(IOBuffer(), Dict("julia" => spec))
end

@testset "Pkg.jl#3012 outdated ⌃ marker agrees with update" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # Seed the manifest at the OLDER installable version 0.5.0; the
            # registry has 0.5.1 (installable) plus a yanked 1.0.0.
            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)
            seeded = plan_add(env0, regs, cfg, [PackageRequest("Example", nothing, "0.5.0")])
            @test entry_version(seeded.manifest[EXAMPLE_UUID]) == v"0.5.0"
            write_environment(env0, seeded)
            env = load_environment(envdir; depots)

            # The reported bug: `status` paints the ⌃ "may be upgradable"
            # marker, yet `up` reports No Changes and never moves the package.
            # Assert the marker is present AND that it is *accurate* — nothing
            # holds the upgrade back, so it renders ⌃ (not the ⌅ "blocked"
            # glyph) and shows the "may be upgradable" footer.
            s = sprint(io -> VibePkg.Display.print_status(io, env; registries = regs))
            @test occursin("⌃", s)
            @test occursin("may be upgradable", s)
            @test !occursin("⌅", s)

            # `up` must ACTUALLY move 0.5.0 -> 0.5.1, both for the whole
            # environment and for a targeted `up Example`. Marker and update
            # agree: the ⌃ is only shown because a real upgrade is installable.
            up_all = plan_up(env, regs, cfg)
            @test entry_version(up_all.manifest[EXAMPLE_UUID]) == v"0.5.1"
            up_tgt = plan_up(env, regs, cfg, [PackageRequest("Example", nothing, nothing)])
            @test entry_version(up_tgt.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # After the upgrade the ⌃ marker must clear: 0.5.1 is the newest
            # non-yanked version, so `status` shows no upgradable glyph/footer.
            after = sprint(io -> VibePkg.Display.print_status(io, up_all; registries = regs))
            @test !occursin("⌃", after)
            @test !occursin("may be upgradable", after)
        end
    end
end

@testset "Pkg.jl#2935 name-add resolves registry url over stale fork" begin
    LibGit2 = VibePkg.Git.LibGit2
    TOML = VibePkg.EnvFiles.TOML
    entry_repo_url = VibePkg.EnvFiles.entry_repo_url
    is_repo_tracked = VibePkg.EnvFiles.is_repo_tracked
    read_manifest = VibePkg.EnvFiles.read_manifest
    uuid = UUID("dddddddd-2935-2935-2935-dddddddddddd")

    mktempdir() do dir
        dir = realpath(dir)

        # canonical upstream repo — the url the registry points at
        canonical = joinpath(dir, "Canonical")
        mkpath(joinpath(canonical, "src"))
        write(
            joinpath(canonical, "Project.toml"), """
            name = "ForkPkg"
            uuid = "$uuid"
            version = "0.1.0"
            """
        )
        write(joinpath(canonical, "src", "ForkPkg.jl"), "module ForkPkg end\n")
        repo = LibGit2.init(canonical)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("tester", "tester@example.com")
        commit = string(LibGit2.commit(repo, "initial"; author = sig, committer = sig))
        # tree sha1 for the registry Versions.toml
        obj = LibGit2.GitObject(repo, commit)
        tree = LibGit2.peel(LibGit2.GitTree, obj)
        tree_sha = string(LibGit2.GitHash(tree))
        LibGit2.close(tree); LibGit2.close(obj); LibGit2.close(repo)

        # a fork at a DIFFERENT url (full copy, so it carries `commit` too)
        fork = joinpath(dir, "Fork")
        cp(canonical, fork)
        @test fork != canonical

        # registry declaring ForkPkg with repo == canonical url
        depot = mkpath(joinpath(dir, "depot"))
        reg = joinpath(depot, "registries", "ForkTestRegistry")
        pkgdir = mkpath(joinpath(reg, "F", "ForkPkg"))
        write(
            joinpath(reg, "Registry.toml"), """
            name = "ForkTestRegistry"
            uuid = "77777777-2935-2935-2935-777777777777"
            repo = "https://example.invalid/ForkTestRegistry"

            [packages]
            $uuid = { name = "ForkPkg", path = "F/ForkPkg" }
            """
        )
        open(joinpath(pkgdir, "Package.toml"), "w") do io
            TOML.print(io, Dict("name" => "ForkPkg", "uuid" => string(uuid), "repo" => canonical))
        end
        write(
            joinpath(pkgdir, "Versions.toml"), """
            ["0.1.0"]
            git-tree-sha1 = "$tree_sha"
            """
        )

        envdir = mkpath(joinpath(dir, "env"))

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            withenv("JULIA_PKG_SERVER" => "") do
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")

                # STEP 1: add from the FORK url+rev — records the fork url
                VibePkg.add(url = fork, rev = commit, io = devnull)
                m1 = read_manifest(joinpath(envdir, "Manifest.toml"))[uuid]
                @test is_repo_tracked(m1)
                @test entry_repo_url(m1) == fork
                src1 = load_environment(envdir; depots = depot_stack(copy(Base.DEPOT_PATH))).project.sources["ForkPkg"]
                @test src1.url == fork

                # STEP 2: add BY NAME + same rev — must resolve the CANONICAL
                # registry url, overwriting the stale fork url (Pkg.jl#2935)
                VibePkg.add(name = "ForkPkg", rev = commit, io = devnull)
                m2 = read_manifest(joinpath(envdir, "Manifest.toml"))[uuid]
                @test is_repo_tracked(m2)
                @test entry_repo_url(m2) == canonical   # not the stale fork
                @test entry_repo_url(m2) != fork
                src2 = load_environment(envdir; depots = depot_stack(copy(Base.DEPOT_PATH))).project.sources["ForkPkg"]
                @test src2.url == canonical
                @test src2.url != fork
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end

@testset "Pkg.jl#2244 add with orphan manifest and missing project" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            cfg = Config(depots)

            # 1. Build a real Manifest.toml by adding Example, then persist it.
            env0 = load_environment(envdir; depots)
            env1 = plan_add(env0, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])
            write_environment(env0, env1)
            @test isfile(joinpath(envdir, "Manifest.toml"))

            # 2. Inject an orphan, path-tracked manifest entry (Foo) that no
            #    project dep references — the stale entry from the bug report.
            #    Its source dir exists (a real on-disk dev package) so it is a
            #    valid fixed package; the fix must still drop it as unreachable.
            FOO_UUID = UUID("11111111-1111-1111-1111-111111111111")
            foopath = mkpath(joinpath(dir, "Foo"))
            write(
                joinpath(foopath, "Project.toml"), """
                name = "Foo"
                uuid = "$FOO_UUID"
                version = "0.1.0"
                """
            )
            mkpath(joinpath(foopath, "src"))
            write(joinpath(foopath, "src", "Foo.jl"), "module Foo end\n")
            open(joinpath(envdir, "Manifest.toml"), "a") do io
                write(
                    io, """

                    [[deps.Foo]]
                    path = "$(slashpath(foopath))"
                    uuid = "$FOO_UUID"
                    version = "0.1.0"
                    """
                )
            end

            # 3. Delete Project.toml: manifest exists, project missing (the MWE).
            Base.rm(joinpath(envdir, "Project.toml"))
            @test isfile(joinpath(envdir, "Manifest.toml"))
            @test !isfile(joinpath(envdir, "Project.toml"))

            # 4. Reload targeting the (absent) Project.toml file directly, and
            #    re-run `add Example`. The old Pkg bug either installed unrelated
            #    packages or threw "could not find entry with uuid ... in manifest".
            env2 = load_environment(joinpath(envdir, "Project.toml"); depots)
            @test isempty(env2.project.deps)          # project genuinely empty
            @test haskey(env2.manifest, FOO_UUID)     # orphan seen on load

            planned = plan_add(env2, regs, cfg, [PackageRequest("Example", nothing, "0.5.1")])

            # FIXED behavior: succeeds cleanly, adds only Example, and prunes the
            # orphan Foo entry instead of resolving/installing it.
            @test collect(values(planned.project.deps)) == [EXAMPLE_UUID]
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1"
            @test !haskey(planned.manifest, FOO_UUID)
        end
    end
end

@testset "Pkg.jl#2205 local package copy never trips source_path assertion" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)

        # (1) A manifest entry with NEITHER a path NOR a tree_hash — the exact
        # shape old Pkg asserted on (`sourcepath !== nothing`). The fix guards
        # it: source_path returns nothing and is_package_downloaded returns
        # false WITHOUT throwing.
        ghost = Planning.Node(;
            name = "Ghost",
            uuid = UUID("00000000-0000-0000-0000-0000000000aa"),
            version = nothing, path = nothing, tree_hash = nothing,
        )
        @test Planning.source_path(env.manifest_file, ghost, depots) === nothing
        local downloaded
        @test (downloaded = Planning.is_package_downloaded(env.manifest_file, ghost, depots)) === false

        # (2) A genuine local copy of a package present on disk: develop it and
        # confirm the same code path reports it as downloaded (the healthy side
        # of the branch that used to assert).
        localpkg = joinpath(dir, "LocalFoo")
        mkpath(joinpath(localpkg, "src"))
        foo_uuid = UUID("00000000-0000-0000-0000-0000000000f0")
        write(
            joinpath(localpkg, "Project.toml"), """
            name = "LocalFoo"
            uuid = "$foo_uuid"
            version = "0.1.0"
            """
        )
        write(joinpath(localpkg, "src", "LocalFoo.jl"), "module LocalFoo\nend\n")

        planned = plan_develop(env, regs, Config(depots), localpkg)
        entry = planned.manifest[foo_uuid]
        node = Planning.entry_to_node(foo_uuid, entry, entry_version(entry))
        sp = Planning.source_path(planned.manifest_file, node, depots)
        @test sp !== nothing
        @test sp == localpkg
        @test Planning.is_package_downloaded(planned.manifest_file, node, depots) === true
    end
end

@testset "Pkg.jl#2168 rm package named with ∂ (U+2202)" begin
    # Name parsing must handle ∂ (U+2202) like any other unicode identifier,
    # so a package that develop/add accepts can also be rm'd.
    parse_package_word = VibePkg.REPLMode.parse_package_word
    RegistryInstance = VibePkg.Registries.RegistryInstance

    # (1) micro-syntax parser keeps the ∂-name intact (old Pkg lexer rejected it)
    @test parse_package_word("∂Components").name == "∂Components"
    @test Base.isidentifier("∂Components")

    # (2) full REPL statement parses `rm ∂xxxxx` to the rm command, name intact
    #     (the reported bug: "Unable to parse `∂xxxxx` as a package")
    cmd = VibePkg.REPLMode.parse_statement(VibePkg.REPLMode.tokenize_words("rm ∂xxxxx"))
    @test cmd.api === VibePkg.rm
    @test cmd.args[1] == ["∂xxxxx"]

    # (3) end-to-end offline develop + rm cycle of a synthetic ∂-named dev package
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        devdir = joinpath(dir, "∂Components")
        mkpath(joinpath(devdir, "src"))
        write(
            joinpath(devdir, "Project.toml"), """
            name = "∂Components"
            uuid = "11111111-1111-1111-1111-111111111111"
            version = "0.1.0"
            """
        )
        write(joinpath(devdir, "src", "∂Components.jl"), "module ∂Components\nend\n")

        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        @test isempty(env.project.deps)

        planned = plan_develop(env, RegistryInstance[], Config(depots), devdir)
        @test haskey(planned.project.deps, "∂Components")
        write_environment(env, planned)

        env2 = load_environment(envdir; depots)
        @test haskey(env2.project.deps, "∂Components")

        # rm must succeed (the bug: "Unable to parse `∂xxxxx` as a package")
        rmplan = plan_rm(env2, [PackageRequest("∂Components")])
        @test !haskey(rmplan.project.deps, "∂Components")
        @test isempty(rmplan.project.deps)
    end
end

@testset "Pkg.jl#2092 interrupted artifact install leaves no read-only partial" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        artifacts_dir = VibePkg.Depots.artifacts_dir(depot)

        # A dummy file to "download" over file:// — its bytes are irrelevant
        # because we make extraction throw before they are ever read.
        dummy = joinpath(dir, "dummy.tar.gz")
        write(dummy, "not-a-real-tarball")
        p = replace(dummy, '\\' => '/')
        startswith(p, '/') || (p = "/" * p)
        url = "file://" * p

        hex = "a"^40  # arbitrary valid tree-hash string; never checked (unpack throws first)
        meta = Dict{String, Any}(
            "git-tree-sha1" => hex,
            "download" => Any[Dict{String, Any}("url" => url)],  # no sha256 → no verify
        )
        final_path = joinpath(artifacts_dir, hex)

        # Simulate a Ctrl-C during extraction: write a partial tree into the
        # (writable temp) destination, then throw InterruptException — exactly
        # the interruption the issue is about.
        @eval VibePkg.Fetch function unpack(tarball::String, dest::String)
            write(joinpath(dest, "partial.txt"), "half-extracted\n")
            throw(InterruptException())
        end
        try
            # invokelatest so the freshly-redefined `unpack` is dispatched
            @test_throws InterruptException Base.invokelatest(
                VibePkg.ArtifactOps.ensure_artifact_installed!,
                d, "victim", meta; server = nothing, io = devnull,
            )

            # FIXED behavior: no partial artifact dir lands at the final path…
            @test !isdir(final_path)
            @test !VibePkg.ArtifactOps.artifact_tree_path(d, Base.SHA1(hex))[2]

            # …and whatever half-extracted content remains is removable
            # (the pre-fix bug left a read-only dir that `rm -rf` could not delete).
            @test isdir(artifacts_dir)
            Base.rm(artifacts_dir; recursive = true, force = true)
            @test !isdir(artifacts_dir)
        finally
            # restore the real extractor so concatenated testsets are unaffected
            @eval VibePkg.Fetch function unpack(
                    tarball::String, dest::String;
                    copy_symlinks::Union{Nothing, Bool} = copy_symlinks_mode(),
                )
                return open(get_extract_cmd(tarball)) do io
                    Tar.extract(io, dest; copy_symlinks)
                end
            end
        end
    end
end

@testset "Pkg.jl#2013 completion of paths with spaces in pkg mode" begin
    using VibePkg: REPLMode
    mktempdir() do dir
        pkgdir = joinpath(dir, "dir with spaces")
        mkdir(pkgdir)
        write(joinpath(pkgdir, "Project.toml"), "name = \"WithSpaces\"\nuuid = \"00000000-0000-0000-0000-000000000001\"\n")
        mkdir(joinpath(dir, "nospace"))
        cd(dir) do
            # The reported #2013 corruption was `dev dir<TAB>` ->
            # `dev dir with spaces\`. Current Pkg completion legitimately
            # includes local directories, so pin the intact directory spelling
            # and reject only the corrupt trailing-backslash form.
            for verb in ("dev dir", "develop dir")
                cands, word = REPLMode.completions_for(verb)
                @test cands isa Vector           # never throws
                @test word == "dir"
                @test joinpath("dir with spaces", "") in cands
                if !Sys.iswindows()
                    @test !("dir with spaces\\" in cands)
                end
            end

            # `dev "dir<TAB>` (inside a double quote) must also not crash and
            # must not emit a path candidate.
            cands, word = REPLMode.completions_for("dev \"dir")
            @test cands isa Vector
            @test word == "\"dir"
            @test !any(c -> occursin(' ', c), cands)

            # The one path-completing verb, `activate`, returns space-containing
            # directories as raw, unescaped candidates and never mangles them
            # with a trailing backslash.
            acands, _ = REPLMode.completions_for("activate ./")
            @test "./dir with spaces" in acands
            @test !any(c -> endswith(c, '\\'), acands)
        end
    end
end

@testset "Pkg.jl#1430 instantiate with dirty registry gives no AssertionError" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            # Registry-tracked Example entry pinned to a version whose tree hash
            # is ABSENT from the (dirty/out-of-date) registry, and with NO
            # git-tree-sha1 in the manifest — exactly the reported scenario.
            write(
                joinpath(envdir, "Project.toml"), """
                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "$(VERSION)"
                manifest_format = "2.0"

                [[deps.Example]]
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.4.0"
                """
            )
            env = load_environment(envdir; depots)
            @test is_registry_tracked(env.manifest[EXAMPLE_UUID])
            # The hash-less registry-tracked entry must be SKIPPED, not trigger
            # an internal `AssertionError: haskey(hashes, uuid)` from a registry
            # version_data! lookup. Fixed behavior: instantiate! returns cleanly
            # with nothing to install.
            local installed
            try
                installed = VibePkg.Execution.instantiate!(env, regs, cfg; io = devnull)
            catch err
                @test !(err isa AssertionError)
                rethrow(err)
            end
            @test installed isa AbstractVector
            @test isempty(installed)
        end
    end
end

@testset "Pkg.jl#1231 registry rename keeps Project.toml and Manifest consistent" begin
    local FOO_UUID = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    # Write a synthetic single-package registry where `regname` is the name
    # under which FOO_UUID is registered. Rewriting with a new name simulates
    # an upstream package rename (same UUID, new name) — the core of #1231.
    write_foo_registry = function (depot, regname)
        reg = joinpath(depot, "registries", "RenameReg")
        pkg = joinpath(reg, "F", regname)
        mkpath(pkg)
        write(
            joinpath(reg, "Registry.toml"), """
            name = "RenameReg"
            uuid = "d0d0d0d0-0000-0000-0000-0000000000ff"
            repo = "https://example.com/RenameReg.git"

            [packages]
            aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa = { name = "$regname", path = "F/$regname" }
            """
        )
        write(
            joinpath(pkg, "Package.toml"), """
            name = "$regname"
            uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            repo = "https://example.com/$regname.jl.git"
            """
        )
        write(
            joinpath(pkg, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "4444444444444444444444444444444444444444"
            """
        )
        return reg
    end

    mktempdir() do depot
        # 1) Register FOO_UUID under name "Foo" and add it.
        write_foo_registry(depot, "Foo")
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Foo", nothing, "1.0.0")])
            @test env.project.deps["Foo"] == FOO_UUID
            @test env.manifest[FOO_UUID].name == "Foo"
            @test write_environment(load_environment(envdir; depots), env)

            # 2) Simulate the upstream rename: same UUID now registered as
            #    "Foo_renamed". Reload registries so the new name is visible.
            Base.rm(joinpath(depot, "registries", "RenameReg"); recursive = true)
            write_foo_registry(depot, "Foo_renamed")
            regs2 = reachable_registries(depots)
            # sanity: the registry really does report the new name now
            local uuids = VibePkg.Registries.uuids_from_name(only(regs2), "Foo_renamed")
            @test FOO_UUID in uuids

            # 3) `up` after the rename must NOT desync Project.toml from the
            #    Manifest (the #1231 bug). Both must keep the original key.
            env2 = load_environment(envdir; depots)
            env2 = plan_up(env2, regs2, Config(depots))

            # FIXED behavior: Project.toml [deps] key is unchanged, and the
            # sole manifest entry's name matches that project key — the env
            # stays internally consistent and loadable (not the broken state
            # where status/Manifest show "Foo_renamed" while [deps] lags).
            @test haskey(env2.project.deps, "Foo")
            @test env2.project.deps["Foo"] == FOO_UUID
            @test env2.manifest[FOO_UUID].name == "Foo"
            local projkey = only(collect(keys(env2.project.deps)))
            @test env2.manifest[env2.project.deps[projkey]].name == projkey
        end
    end
end

@testset "Pkg.jl#1218 build skips read-only secondary depot" begin
    mktempdir() do dir
        # two-depot stack: depot1 is the writable primary, depot2 secondary
        depot1 = mkpath(joinpath(dir, "depot1"))
        depot2 = mkpath(joinpath(dir, "depot2"))
        depots = depot_stack([depot1, depot2])

        # a registry-tracked package whose *installed source* lives in depot2
        foo_uuid = UUID("f00df00d-1218-1218-1218-121812181218")
        tree_hash = Base.SHA1("a"^40)
        slug = Base.version_slug(foo_uuid, tree_hash)
        source = mkpath(joinpath(depot2, "packages", "Foo", slug))
        mkpath(joinpath(source, "src"))
        mkpath(joinpath(source, "deps"))
        write(joinpath(source, "src", "Foo.jl"), "module Foo\nend\n")
        # a build script that only prints (must not write into the read-only tree)
        write(joinpath(source, "deps", "build.jl"), "println(\"Building Foo in read-only depot\")\n")

        # an environment (in the writable tempdir) whose manifest tracks Foo
        # from the registry, resolving to the installed tree in depot2
        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            Foo = "$foo_uuid"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Foo]]
            uuid = "$foo_uuid"
            version = "1.0.0"
            git-tree-sha1 = "$("a"^40)"
            """
        )
        env = load_environment(envdir; depots)
        entry = env.manifest[foo_uuid]
        @test is_registry_tracked(entry)
        @test !is_path_tracked(entry)

        # FIXED behavior: the build log for a registry-tracked package goes to
        # the primary (writable) depot's scratchspaces, never the depot that
        # holds the source (depot2)
        log_file = VibePkg.BuildOps.build_log_file(depots, entry, source)
        @test startswith(log_file, joinpath(depot1, "scratchspaces"))
        @test !startswith(log_file, depot2)

        # make the secondary depot read-only, then build: it must NOT error
        chmod(depot2, 0o500; recursive = true)
        try
            err = try
                VibePkg.BuildOps.build!(env, depots, [foo_uuid]; io = devnull)
                nothing
            catch e
                e
            end
            @test err === nothing
            # the log really landed under the writable primary depot
            @test isfile(log_file)
        finally
            # restore write perms so the tempdir can be cleaned up
            chmod(depot2, 0o700; recursive = true)
        end
    end
end

@testset "Pkg.jl#1212 instantiate installs newly-registered dep with no Manifest" begin
    # The report: a project with only a Project.toml (no Manifest) whose dep
    # was registered after the last `up`. `instantiate` silently failed to
    # install the dep, so `using Foo` errored until an explicit `up`. The
    # fixed behavior: `instantiate` on a Manifest-less project resolves and
    # actually installs every recorded dependency from the registry.
    fx = LocalPkgServer.ensure!()   # local pkg server + JULIA_PKG_SERVER
    local find_installed = VibePkg.Depots.find_installed
    local entry_tree_hash = VibePkg.EnvFiles.entry_tree_hash

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        # A registry carrying Example @ 0.5.5 with the REAL fixture hash so the
        # source is actually downloadable from the local pkg server.
        reg = joinpath(depot, "registries", "RealReg")
        pkgdir = mkpath(joinpath(reg, "E", "Example"))
        write(
            joinpath(reg, "Registry.toml"), """
            name = "RealReg"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.invalid/RealReg"

            [packages]
            $(EXAMPLE_UUID) = { name = "Example", path = "E/Example" }
            """
        )
        write(
            joinpath(pkgdir, "Package.toml"), """
            name = "Example"
            uuid = "$(EXAMPLE_UUID)"
            repo = "$(slashpath(fx.git_repo))"
            """
        )
        write(
            joinpath(pkgdir, "Versions.toml"), """
            ["0.5.5"]
            git-tree-sha1 = "$(fx.version_hashes["0.5.5"])"
            """
        )

        proj = mkpath(joinpath(dir, "proj"))
        # Project.toml with the Example dep and NO Manifest.toml -- exactly the
        # reported starting state.
        write(
            joinpath(proj, "Project.toml"), """
            [deps]
            Example = "$(EXAMPLE_UUID)"
            """
        )
        @test !isfile(joinpath(proj, "Manifest.toml"))

        old = copy(Base.DEPOT_PATH)
        oldp = Base.ACTIVE_PROJECT[]
        oldg = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            # Registry is already present in the depot; pretend it was refreshed
            # this session so instantiate does not reach for the network to
            # update RealReg (whose repo is a dead url). The defect under test is
            # purely whether instantiate installs the recorded-but-uninstalled
            # dep, not the registry refresh mechanism.
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")

            # Fixed behavior: instantiate completes cleanly.
            @test VibePkg.instantiate(io = devnull) === nothing

            # A Manifest is now written recording Example...
            @test isfile(joinpath(proj, "Manifest.toml"))
            depots = depot_stack(copy(Base.DEPOT_PATH))
            env = load_environment(; depots)
            u = UUID(EXAMPLE_UUID)
            @test haskey(env.manifest.deps, u)
            ent = env.manifest.deps[u]
            @test entry_version(ent) == v"0.5.5"

            # ...and the source is actually installed and importable, not just
            # recorded (the crux of the report: `using Foo` used to error).
            th = entry_tree_hash(ent.tracking)
            path, installed = find_installed(depots, "Example", u, th)
            @test installed
            @test isfile(joinpath(path, "src", "Example.jl"))
        finally
            copy!(Base.DEPOT_PATH, old)
            Base.ACTIVE_PROJECT[] = oldp
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldg
        end
    end
end

@testset "Pkg.jl#710 add runs deps/build.jl" begin
    mktempdir() do dir
        buildpkg_uuid = "aaaaaaaa-0710-0710-0710-000000000710"
        general_uuid = LocalPkgServer.GENERAL_UUID
        marker = joinpath(dir, "BUILD_RAN.txt")

        # a registry package whose deps/build.jl writes an external marker
        src = mkpath(joinpath(dir, "BuildPkg"))
        mkpath(joinpath(src, "src"))
        mkpath(joinpath(src, "deps"))
        write(
            joinpath(src, "Project.toml"), """
            name = "BuildPkg"
            uuid = "$buildpkg_uuid"
            version = "0.1.0"
            """
        )
        write(joinpath(src, "src", "BuildPkg.jl"), "module BuildPkg\nend\n")
        write(joinpath(src, "deps", "build.jl"), "write($(repr(marker)), \"BUILD_RAN\")\n")

        # tarball + a synthetic General registry carrying BuildPkg, laid out
        # for the pkg-server protocol and served over a local HTTP listener
        pkg_hash = bytes2hex(VibePkg.TreeHash.tree_hash(src))
        files = mkpath(joinpath(dir, "files"))
        LocalPkgServer.gzip_tarball(src, joinpath(files, "package", buildpkg_uuid, pkg_hash))
        reg = mkpath(joinpath(dir, "registry"))
        write(
            joinpath(reg, "Registry.toml"), """
            name = "General"
            uuid = "$general_uuid"
            repo = "https://example.invalid/General"

            [packages]
            $buildpkg_uuid = { name = "BuildPkg", path = "B/BuildPkg" }
            """
        )
        rpkg = mkpath(joinpath(reg, "B", "BuildPkg"))
        write(
            joinpath(rpkg, "Package.toml"), """
            name = "BuildPkg"
            uuid = "$buildpkg_uuid"
            repo = "https://example.invalid/BuildPkg.jl.git"
            """
        )
        write(
            joinpath(rpkg, "Versions.toml"), """
            ["0.1.0"]
            git-tree-sha1 = "$pkg_hash"
            """
        )
        reg_hash = bytes2hex(VibePkg.TreeHash.tree_hash(reg))
        LocalPkgServer.gzip_tarball(reg, joinpath(files, "registry", general_uuid, reg_hash))
        write(joinpath(files, "registries"), "/registry/$general_uuid/$reg_hash\n")

        srv = LocalPkgServer.start_server(files)
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            withenv("JULIA_PKG_SERVER" => srv.url) do
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                VibePkg.add("BuildPkg"; io = devnull)
            end
            # #710: `add` of a registry package with a deps/build.jl must run
            # the build step automatically — no manual `build` needed
            @test isfile(marker)
            @test read(marker, String) == "BUILD_RAN"
            env = load_environment(envdir; depots = depot_stack())
            @test entry_version(env.manifest[UUID(buildpkg_uuid)]) == v"0.1.0"
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            close(srv.server)
        end
    end
end

@testset "Pkg.jl#4705 dev'd dep [sources] to absent path leaks" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # LeakyPkg depends on Example (registered), but carries its OWN
            # [sources] entry pointing Example at ../Example, which does NOT
            # exist. When LeakyPkg is used as a *developed dep*, its private
            # [sources] must be ignored and Example resolved from the registry.
            leakydir = joinpath(dir, "LeakyPkg")
            mkpath(joinpath(leakydir, "src"))
            leaky_uuid = UUID("22222222-2222-2222-2222-222222222222")
            write(
                joinpath(leakydir, "Project.toml"), """
                name = "LeakyPkg"
                uuid = "$leaky_uuid"
                version = "0.1.0"

                [deps]
                Example = "$EXAMPLE_UUID"

                [sources]
                Example = {path = "../Example"}
                """
            )
            write(joinpath(leakydir, "src", "LeakyPkg.jl"), "module LeakyPkg\nend\n")
            # ../Example deliberately absent

            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)

            # Correct behavior: developing LeakyPkg must NOT throw an
            # "expected package Example to exist at path" error, and Example
            # must resolve from the registry at 0.5.1.
            local ex_version = nothing
            @test begin
                planned = plan_develop(env0, regs, cfg, leakydir)
                ex_version = entry_version(planned.manifest[EXAMPLE_UUID])
                ex_version == v"0.5.1"
            end
        end
    end
end

@testset "Pkg.jl#4006 ResolverError color baked at construction, not decided in showerror" begin
    Resolve = VibePkg.Resolve
    Versions = VibePkg.Versions
    VersionSpec = Versions.VersionSpec
    VersionRange = Versions.VersionRange
    Requires = Resolve.Requires
    Fixed = Resolve.Fixed
    ResolverError = Resolve.ResolverError

    uA = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    uB = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    uC = UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")

    # synthetic A/B/C graph (mirrors test/resolve.jl `solve`): requiring A=2 and
    # B=1 is unsatisfiable (A@2 needs B@2) -> Resolve.ResolverError
    function solve(reqs)
        vr(s) = VersionRange(s)
        deps = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
            uA => [Dict(vr("1") => Set([uB]), vr("2") => Set([uB]))],
            uB => [Dict{VersionRange, Set{UUID}}()],
            uC => [Dict{VersionRange, Set{UUID}}()],
        )
        compat = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
            uA => [Dict(vr("1") => Dict(uB => VersionSpec("1")), vr("2") => Dict(uB => VersionSpec("2")))],
            uB => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
            uC => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
        )
        weak_deps = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
            uA => [Dict{VersionRange, Set{UUID}}()],
            uB => [Dict{VersionRange, Set{UUID}}()],
            uC => [Dict{VersionRange, Set{UUID}}()],
        )
        weak_compat = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
            uA => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
            uB => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
            uC => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
        )
        versions = Dict{UUID, Vector{VersionNumber}}(
            uA => [v"1.0.0", v"1.1.0", v"2.0.0"],
            uB => [v"1.0.0", v"2.0.0"],
            uC => [v"1.0.0"],
        )
        versions_per_registry = Dict{UUID, Vector{Set{VersionNumber}}}(
            u => [Set(vs)] for (u, vs) in versions
        )
        names = Dict{UUID, String}(uA => "A", uB => "B", uC => "C")
        graph = Resolve.Graph(
            deps, compat, weak_deps, weak_compat, versions, versions_per_registry,
            names, reqs, Dict{UUID, Fixed}(), false, VERSION, Dict{UUID, VersionNumber}(),
        )
        Resolve.simplify_graph!(graph)
        return Resolve.resolve(graph)
    end

    # Build the ResolverError while the process stderr reports color support.
    # `logstr` (Resolve/graphtype.jl) bakes ANSI codes into the message based on
    # `stderr`'s color at *construction* time.
    err = nothing
    pipe = Pipe()
    old_stderr = stderr
    try
        redirect_stderr(IOContext(pipe, :color => true))
        err = try
            solve(Requires(uA => VersionSpec("2"), uB => VersionSpec("1")))
        catch e
            e
        end
    finally
        redirect_stderr(old_stderr)
        close(pipe)
    end

    # preconditions that DO hold today (the buggy state)
    @test err isa ResolverError
    @test occursin("\e[", err.msg)   # ANSI escapes hardcoded into the stored message

    # CRUX: color should be decided by showerror's target IO. Rendering to an IO
    # with color disabled must yield NO ANSI escapes. Today the stored msg leaks
    # its baked-in escapes, so this is false -> Broken (flips to pass once fixed).
    plain = sprint(io -> showerror(io, err); context = :color => false)
    @test !occursin("\e[", plain)
end

@testset "Pkg.jl#3420 Registry.rm rejects SubString/AbstractString" begin
    # Precondition (holds today): the positional method exists for String,
    # establishing the buggy state where only concrete String is accepted.
    @test hasmethod(VibePkg.Registry.rm, Tuple{String})

    # Correct behavior: Registry.rm should accept any AbstractString (e.g. a
    # SubString) rather than throwing a MethodError. Today the signature is
    # typed `String...`, so a SubString matches no method — this is @test.
    @test hasmethod(VibePkg.Registry.rm, Tuple{SubString{String}})

    # Behavioral crux: calling rm with a SubString should NOT throw a
    # MethodError (it should reach the normal code path and, for a missing
    # registry, raise a PkgError). Currently it throws MethodError -> the
    # `!(e isa MethodError)` predicate is false -> records Broken.
    @test try
        VibePkg.Registry.rm(SubString("NoSuchRegistry3420", 1))
        true
    catch e
        !(e isa MethodError)
    end
end

@testset "Pkg.jl#3365 tree_hash ENOTDIRs on a non-directory special file" begin
    if Sys.iswindows()
        # no /dev/null-style character device to hash on Windows; skip
        @test_skip true
    else
        # `/dev/null` is a character device present on macOS/Linux without root.
        devnode = "/dev/null"

        # Preconditions (hold today): the path exists but is not a directory — this
        # is exactly the shape that trips the unguarded top-level `readdir(root)` in
        # TreeHash.tree_hash (src/TreeHash.jl:106).
        @test ispath(devnode)
        @test !isdir(devnode)

        # CORRECT behavior: hashing a non-directory root must be handled gracefully —
        # either return a valid hash (treating a non-dir root the way git does) or
        # throw a clean VibePkg ArgumentError. It must NOT surface a raw Base.IOError
        # (ENOTDIR) from an unguarded readdir. Today it throws that IOError, so this
        # records Broken; it flips to an Unexpected Pass once tree_hash guards the
        # root. The op is inside the try so the file never crashes.
        graceful = try
            VibePkg.TreeHash.tree_hash(devnode)
            true
        catch e
            e isa ArgumentError
        end
        @test graceful
    end
end

@testset "Pkg.jl#3150 pinned pkg wrongly marked upgradable (⌃)" begin
    print_status = VibePkg.Display.print_status
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)

            # add Example@0.5.0 (registry also ships 0.5.1; 1.0.0 is yanked) and
            # pin it there, then persist + reload.
            added = plan_add(env0, regs, cfg, [PackageRequest("Example", nothing, "0.5.0")])
            pinned = plan_pin(added, regs, cfg, [PackageRequest("Example")])
            write_environment(env0, pinned)
            env = load_environment(envdir; depots)

            # Example is pinned at 0.5.0; a newer registry version (0.5.1) exists
            # but `up` cannot move a pin, so status must NOT flag it upgradable.
            @test env.manifest[EXAMPLE_UUID].pinned
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.0"
            s = sprint(io -> print_status(io, env; registries = regs))
            @test !occursin("⌃", s)   # fixed: pinned entry gets no ⌃ gutter

            # ...but `up` cannot move a pinned package (both targeted and whole-env).
            pu = plan_up(env, regs, cfg, [PackageRequest("Example")])
            puall = plan_up(env, regs, cfg)
            up_moved = entry_version(pu.manifest[EXAMPLE_UUID]) != v"0.5.0" ||
                entry_version(puall.manifest[EXAMPLE_UUID]) != v"0.5.0"
            @test !up_moved   # up correctly refuses to move the pin

            # CORRECT behavior: the ⌃ marker must only appear when up can actually
            # install a newer version (⌃ ⇒ up upgrades). For a pinned package up
            # can't move, so ⌃ should be suppressed. Today it is shown though up
            # does nothing -> the invariant is false -> Broken. Flips to a pass
            # once print_status stops flagging pinned entries.
            @test (!occursin("⌃", s)) || up_moved
        end
    end
end

@testset "Pkg.jl#2894 setprotocol! drops non-standard SSH port" begin
    # Pure/offline: exercise the URL rewriter directly. After
    # setprotocol!(domain="domain", protocol="ssh"), an scp-style URL that
    # carries an explicit SSH port must have that port preserved in the
    # emitted ssh:// URL, not folded into the path.
    setproto = VibePkg.Git.setprotocol!
    normalize = VibePkg.Git.normalize_url

    setproto(; domain = "domain", protocol = "ssh")

    input = "user@domain:2222/git-server/repos/ARTime.git"
    got = normalize(input)

    # It becomes an ssh:// URL with the git user, and (fixed) the non-standard
    # port 2222 is preserved as a real port component, not swallowed into the path.
    @test got == "ssh://git@domain:2222/git-server/repos/ARTime.git"
end

@testset "Pkg.jl#1657 malformed platform Artifacts.toml entry throws TypeError not PkgError" begin
    ArtifactOps = VibePkg.ArtifactOps
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # A synthetic package whose Artifacts.toml has a PLATFORM-SPECIFIC entry
        # (a `[[MyArtifact]]` array element carrying platform keys) that declares
        # `os` but OMITS the required `arch` key. The Artifacts stdlib's
        # `unpack_platform` returns `nothing` for such an entry, which is then
        # typeasserted to `Platform` during selection.
        pkgroot = joinpath(dir, "Foo")
        mkpath(joinpath(pkgroot, "src"))
        write(joinpath(pkgroot, "src", "Foo.jl"), "module Foo end\n")
        write(
            joinpath(pkgroot, "Artifacts.toml"), """
            [[MyArtifact]]
            git-tree-sha1 = "0000000000000000000000000000000000000000"
            os = "windows"
            """
        )

        # Precondition (holds today): the malformed Artifacts.toml is on disk.
        @test isfile(joinpath(pkgroot, "Artifacts.toml"))

        # CORRECT behavior: collecting artifact installs over a malformed
        # Artifacts.toml must surface a graceful VibePkg PkgError naming the bad
        # entry, NOT a raw `TypeError: expected Platform, got Nothing` typeassert
        # leaking from the artifact-selection internals. Today it throws that
        # TypeError, so `threw_pkgerror` is false -> Broken (flips to Unexpected
        # Pass once the malformed entry is reported gracefully). The op is inside
        # the try so the file never crashes.
        threw_pkgerror = try
            ArtifactOps.collect_artifact_installs(depots, pkgroot)
            false   # wrongly succeeded (no error at all)
        catch e
            e isa PkgError
        end
        @test threw_pkgerror
    end
end

@testset "Pkg.jl#1236 successful add of a repo package skips deps/build.jl" begin
    LibGit2 = VibePkg.Git.LibGit2
    mktempdir() do dir
        # A local git-repo package that ships deps/build.jl (no deps, so no
        # registry/server is needed). build.jl writes an absolute marker file
        # whose presence proves the build step actually ran.
        repo = mkpath(joinpath(dir, "BuildDep"))
        mkpath(joinpath(repo, "src"))
        mkpath(joinpath(repo, "deps"))
        uuid = UUID("aaaa1236-1111-2222-3333-444444444444")
        marker = joinpath(dir, "BUILD_RAN.txt")
        write(
            joinpath(repo, "Project.toml"), """
            name = "BuildDep"
            uuid = "$uuid"
            version = "0.1.0"
            """
        )
        write(joinpath(repo, "src", "BuildDep.jl"), "module BuildDep\nend\n")
        write(joinpath(repo, "deps", "build.jl"), "write($(repr(marker)), \"built\")\n")

        gr = LibGit2.init(repo)
        LibGit2.add!(gr, ".")
        sig = LibGit2.Signature("tester", "tester@example.com")
        LibGit2.commit(gr, "initial"; author = sig, committer = sig)
        LibGit2.branch!(gr, "main")
        LibGit2.close(gr)

        # with_api_env-style isolation: fresh depot + activated empty project,
        # registry-update gate held so the offline add never touches the net.
        old_active = Base.ACTIVE_PROJECT[]
        old_depot = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        depot = mkpath(joinpath(dir, "depot"))
        # a registry must exist so the offline `add` doesn't attempt a
        # (network) registry update and fail for an unrelated reason
        make_test_registry(depot)
        proj = mkpath(joinpath(dir, "proj"))
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")

            # #1236 desired behavior: a successful `add` always runs the newly
            # added package's deps/build.jl. VibePkg materializes the repo tree
            # on disk *before* resolve/apply, so the package is never counted
            # as "newly installed" and its build step is skipped -> marker
            # absent -> Broken today; flips to a pass once add builds it.
            @test begin
                VibePkg.add(VibePkg.PackageSpec(path = repo, rev = "main"); io = devnull)
                isfile(marker)
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end

@testset "Pkg.jl#4553 uncompress_registry resolves `..` path segments" begin
    if Sys.iswindows()
        # Win32 collapses `..` lexically before hitting the filesystem, so the
        # symlink-then-dotdot divergence this test needs cannot exist; skip
        @test_skip true
    else
        Tar = VibePkg.Fetch.Tar
        p7zip_jll = VibePkg.Fetch.p7zip_jll

        root = mktempdir()
        dir1 = mkpath(joinpath(root, "dir1"))
        dir2 = mkpath(joinpath(root, "dir2"))
        dir2sub = mkpath(joinpath(dir2, "sub"))

        # Build a minimal gzip-compressed registry tarball containing Registry.toml
        src = mkpath(joinpath(root, "regsrc"))
        write(joinpath(src, "Registry.toml"), "name = \"General\"\n")
        plain = joinpath(root, "General.tar")
        Tar.create(src, plain)
        real_tarball = joinpath(dir2, "General.tar.gz")
        run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $real_tarball $plain`; stdout = devnull))

        # symlink dir1/mylink -> dir2/sub, so that a `..`-containing path resolves
        # (via the kernel) to the real tarball, but collapses lexically to a file
        # that does not exist.
        symlink(dir2sub, joinpath(dir1, "mylink"))
        path = joinpath(dir1, "mylink", "..", "General.tar.gz")

        # Preconditions establishing the buggy state (these hold today):
        @test isfile(path)                                    # kernel-resolved: exists
        @test realpath(path) == realpath(real_tarball)        # realpath -> dir2/General.tar.gz
        @test !isfile(joinpath(dir1, "General.tar.gz"))       # lexical collapse target: missing

        # Correct behavior: uncompress_registry should realpath the argument (like
        # upstream Pkg.jl get_extract_cmd) so 7z opens the real tarball. Today it
        # passes the raw `..` path to 7z, which collapses it lexically to a
        # nonexistent file and throws "Cannot open the file as archive".
        @test haskey(VibePkg.Fetch.uncompress_registry(path), "Registry.toml")
    end
end

@testset "Pkg.jl#3644 test_subprocess_flags forces --warn-overwrite=yes" begin
    # `test_subprocess_flags` should mirror the parent's `--warn-overwrite`
    # setting (like it does for depwarn/inline/startup-file), not hardcode
    # `yes`. Build the flags the test subprocess would be launched with.
    flags = collect(
        VibePkg.TestOps.test_subprocess_flags(
            "/x"; coverage = false, julia_args = ``
        )
    )

    # Precondition (holds today): exactly one --warn-overwrite token is emitted.
    wo = filter(startswith("--warn-overwrite="), flags)
    @test length(wo) == 1

    # The parent's own warn_overwrite setting (0 = no, 1 = yes). In this
    # process it is 0 (no), so the mirrored flag *should* be `no`.
    parent = Base.JLOptions().warn_overwrite == 1 ? "yes" : "no"
    @test parent == "no"   # precondition: parent has warnings off

    # CRUX (desired behavior, currently violated): the emitted token mirrors
    # the parent instead of being a constant `yes`. Today it is `yes` -> false
    # -> records Broken; once fixed to mirror, it flips to Unexpected Pass.
    @test only(wo) == "--warn-overwrite=$(parent)"
end

@testset "Pkg.jl#4103 is_manifest_current misses deved dep Project change" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # synthetic local dev package, initially NO deps
            devdir = joinpath(dir, "DevPkg"); mkpath(joinpath(devdir, "src"))
            devuuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            projpath = joinpath(devdir, "Project.toml")
            write(projpath, "name = \"DevPkg\"\nuuid = \"$devuuid\"\nversion = \"0.1.0\"\n")
            write(joinpath(devdir, "src", "DevPkg.jl"), "module DevPkg\nend\n")

            envdir = joinpath(dir, "myproj"); mkpath(envdir)
            env0 = load_environment(envdir; depots)

            # develop DevPkg into myproj, then resolve to record project_hash
            planned = plan_resolve(plan_develop(env0, regs, cfg, devdir), regs, cfg)
            write_environment(env0, planned)
            env1 = load_environment(envdir; depots)

            # precondition: right after resolve the manifest IS current
            @test VibePkg.Environments.is_manifest_current(env1) === true
            @test !any(e -> e.name == "Example", values(env1.manifest.deps))

            # now the DEVED package gains a dep on Example — manifest is now stale
            write(projpath, "name = \"DevPkg\"\nuuid = \"$devuuid\"\nversion = \"0.1.0\"\n\n[deps]\nExample = \"7876af07-990d-54b4-ab0e-23690620f79a\"\n")

            # reactivate myproj from disk
            env2 = load_environment(envdir; depots)

            # manifest still lacks Example (setup sanity — this holds today)
            @test !any(e -> e.name == "Example", values(env2.manifest.deps))

            # CORRECT behavior: staleness should be detected -> false.
            # BUG #4103: is_manifest_current still returns true. -> Broken.
            @test VibePkg.Environments.is_manifest_current(env2) === false
        end
    end
end

@testset "Pkg.jl#4351 nested [sources] rev change not picked up on resolve" begin
    # resolve must propagate a hand-edited `[sources]` rev change that lives
    # inside a path-tracked dep's OWN Project.toml (a nested source), the same
    # way it already does for the active project's top-level [sources].
    LibGit2 = VibePkg.Git.LibGit2
    Git = VibePkg.Git
    entry_repo_rev = VibePkg.EnvFiles.entry_repo_rev
    entry_tree_hash = VibePkg.EnvFiles.entry_tree_hash
    is_repo_tracked = VibePkg.EnvFiles.is_repo_tracked
    no_regs = VibePkg.Registries.RegistryInstance[]

    git_tree_hash = function (repo_path, rev)
        repo = LibGit2.GitRepo(repo_path)
        obj = LibGit2.GitObject(repo, rev)
        tree = LibGit2.peel(LibGit2.GitTree, obj)
        h = Base.SHA1(string(LibGit2.GitHash(tree)))
        close(tree); close(obj); close(repo)
        return h
    end
    quiet = f -> Base.ScopedValues.with(f, VibePkg.Utils.DEFAULT_IO => devnull)

    PKGA_UUID = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    PKGB_UUID = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")

    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # PkgB: a real local git repo with two commits (different trees)
        pkgB = joinpath(dir, "PkgB")
        mkpath(joinpath(pkgB, "src"))
        write(
            joinpath(pkgB, "Project.toml"), """
            name = "PkgB"
            uuid = "$PKGB_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkgB, "src", "PkgB.jl"), "module PkgB end\n")
        repo = LibGit2.init(pkgB)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("t", "t@e.com")
        c1 = string(LibGit2.commit(repo, "first"; author = sig, committer = sig))
        LibGit2.close(repo)
        write(joinpath(pkgB, "src", "PkgB.jl"), "module PkgB\nf() = 2\nend\n")
        repo = LibGit2.GitRepo(pkgB)
        LibGit2.add!(repo, ".")
        c2 = string(LibGit2.commit(repo, "second"; author = sig, committer = sig))
        LibGit2.close(repo)

        # PkgA: a path-tracked package whose OWN [sources] pins PkgB to c1
        pkgA = joinpath(dir, "PkgA")
        mkpath(pkgA)
        write(
            joinpath(pkgA, "Project.toml"), """
            name = "PkgA"
            uuid = "$PKGA_UUID"
            version = "0.1.0"

            [deps]
            PkgB = "$PKGB_UUID"

            [sources]
            PkgB = {url = "$(slashpath(pkgB))", rev = "$c1"}
            """
        )

        # root project deps PkgA via a path [sources]
        projdir = joinpath(dir, "proj")
        mkpath(projdir)
        write(
            joinpath(projdir, "Project.toml"), """
            [deps]
            PkgA = "$PKGA_UUID"

            [sources]
            PkgA = {path = "../PkgA"}
            """
        )

        fetcher = Git.source_fetcher(depots; io = devnull)

        # resolve #1: manifest records PkgB @ c1
        env = load_environment(projdir; depots)
        plan1 = quiet(() -> plan_resolve(env, no_regs, Config(depots); fetcher))
        write_environment(env, plan1)
        e1 = plan1.manifest[PKGB_UUID]
        @test is_repo_tracked(e1)                                   # precondition
        @test entry_repo_rev(e1) == c1                              # precondition
        @test entry_tree_hash(e1) == git_tree_hash(pkgB, c1)        # precondition
        @test c1 != c2 && git_tree_hash(pkgB, c1) != git_tree_hash(pkgB, c2)

        # edit the NESTED [sources] rev c1 -> c2 inside PkgA's Project.toml
        paf = joinpath(pkgA, "Project.toml")
        write(paf, replace(read(paf, String), c1 => c2))

        # resolve #2 on the already-resolved env
        env2 = load_environment(projdir; depots)
        plan2 = quiet(() -> plan_resolve(env2, no_regs, Config(depots); fetcher))
        e2 = plan2.manifest[PKGB_UUID]

        # CORRECT behavior: the nested rev change reaches the manifest.
        # Today it does not (PkgB stays pinned at c1) -> Broken.
        @test entry_repo_rev(e2) == c2
        @test entry_tree_hash(e2) == git_tree_hash(pkgB, c2)
    end
end

@testset "Pkg.jl#3795 build-metadata dep added but version not bumped" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        foo_uuid = UUID("f0000000-0000-0000-0000-000000000000")
        bar_uuid = UUID("ba000000-0000-0000-0000-000000000000")
        regroot = mkpath(joinpath(depot, "registries", "JllRegistry"))
        write(
            joinpath(regroot, "Registry.toml"), """
            name = "JllRegistry"
            uuid = "33338594-aafe-5451-b93e-139f81909106"

            [packages]
            $foo_uuid = { name = "Foo_jll", path = "F/Foo_jll" }
            $bar_uuid = { name = "Bar_jll", path = "B/Bar_jll" }
            """
        )

        # Foo_jll: two versions differing ONLY in build metadata (+0, +1).
        foo = mkpath(joinpath(regroot, "F", "Foo_jll"))
        write(
            joinpath(foo, "Package.toml"), """
            name = "Foo_jll"
            uuid = "$foo_uuid"
            repo = "https://example.com/Foo_jll.git"
            """
        )
        write(
            joinpath(foo, "Versions.toml"), """
            ["1.21.0+0"]
            git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

            ["1.21.0+1"]
            git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            """
        )
        # Deps.toml keys on major.minor.patch, so the ["1.21.0"] range
        # unavoidably covers BOTH builds — build metadata cannot be expressed
        # in a VersionRange (see src/Versions.jl:43-45).
        write(
            joinpath(foo, "Deps.toml"), """
            ["1.21.0"]
            Bar_jll = "$bar_uuid"
            """
        )

        # Bar_jll: a plain resolvable jll.
        bar = mkpath(joinpath(regroot, "B", "Bar_jll"))
        write(
            joinpath(bar, "Package.toml"), """
            name = "Bar_jll"
            uuid = "$bar_uuid"
            repo = "https://example.com/Bar_jll.git"
            """
        )
        write(
            joinpath(bar, "Versions.toml"), """
            ["1.0.0+0"]
            git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"
            """
        )

        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # Environment: project depends on Foo_jll; manifest pins Foo_jll at the
        # +0 build with NO deps (as an older registry, lacking the +1 build,
        # would have produced it).
        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            Foo_jll = "$foo_uuid"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Foo_jll]]
            git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            uuid = "$foo_uuid"
            version = "1.21.0+0"
            """
        )

        env = load_environment(envdir; depots)

        # Precondition (holds today): the pinned entry is +0 with empty deps.
        @test entry_version(env.manifest[foo_uuid]) == v"1.21.0+0"
        @test !haskey(env.manifest[foo_uuid].deps, "Bar_jll")

        plan = plan_resolve(env, regs, Config(depots))
        foo_entry = plan.manifest[foo_uuid]

        # CORRECT behavior: the resolved manifest must be self-consistent. Since
        # jll_fix keeps Foo_jll pinned at the +0 build (its git-tree-sha1), the
        # dep list must stay consistent with that build — i.e. either the
        # version bumps to +1 (the build that gained the Bar_jll dep) OR the
        # dep list stays empty. Today resolve leaves the version at +0 while
        # ALSO adding Bar_jll (from the ["1.21.0"] range) -> an invalid manifest
        # (both branches false) -> Broken. Flips to Unexpected Pass once fixed.
        version_bumped = entry_version(foo_entry) == v"1.21.0+1"
        deps_kept_empty = !haskey(foo_entry.deps, "Bar_jll")
        @test (version_bumped || deps_kept_empty)
    end
end

@testset "Pkg.jl#3496 up of unregistered pkg forces registry update" begin
    LibGit2 = VibePkg.Git.LibGit2
    mktempdir() do dir
        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        old_offline = VibePkg.API.OFFLINE_MODE[]
        try
            # Reset globals a prior test may have left dirty: offline mode would
            # make `up` skip the registry fetch entirely (masking the bug), and
            # the process-wide registry cache must not shadow our git-backed reg.
            VibePkg.API.OFFLINE_MODE[] = false
            empty!(VibePkg.Registries.REGISTRY_CACHE)
            depot = mkpath(joinpath(dir, "depot"))
            reg = make_test_registry(depot)

            # Turn the offline TestRegistry into a git-backed registry whose
            # `origin` points at a dead remote. A *forced* registry update then
            # takes the git branch of update_registries!, which prints
            # "Updating git-repo `<url>`" before failing to fetch.
            deadurl = "http://127.0.0.1:9/TestRegistry.git"
            let repo = LibGit2.init(reg)
                LibGit2.add!(repo, ".")
                sig = LibGit2.Signature("t", "t@e.com")
                LibGit2.commit(repo, "reg"; author = sig, committer = sig)
                LibGit2.set_remote_url(repo, "origin", deadurl)
                LibGit2.close(repo)
            end

            # Isolate global process state to this depot/project (public_api's
            # with_api_env pattern) and disable the package server so only the
            # git-backed registry path can run.
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            proj = mkpath(joinpath(dir, "proj"))
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")

            withenv("JULIA_PKG_SERVER" => "") do
                # An unregistered, path-tracked package: `Foo` is NOT in any
                # registry (only Example is), added via develop.
                foo = joinpath(dir, "Foo")
                mkpath(joinpath(foo, "src"))
                write(
                    joinpath(foo, "Project.toml"), """
                    name = "Foo"
                    uuid = "f0000000-0000-0000-0000-000000000001"
                    version = "0.1.0"
                    """
                )
                write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
                VibePkg.develop(VibePkg.PackageSpec(path = foo); io = devnull)

                env = load_environment(proj; depots = depot_stack([depot]))
                @test is_path_tracked(env.manifest[UUID("f0000000-0000-0000-0000-000000000001")])

                # CORRECT behavior: `up Foo` on an unregistered (path-tracked)
                # package must NOT force a registry update, so the git-backed
                # registry is never fetched and no "Updating git-repo" line is
                # emitted. Today `_up_requests` unconditionally passes
                # update_registry=:force, so the registry IS fetched -> the
                # output contains "git-repo" -> Broken (flips to Unexpected
                # Pass once `up` skips the forced update for unregistered pkgs).
                buf = IOBuffer()
                @test begin
                    VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                    # Drop the per-depot registry update log so the `:force`
                    # update's 1-second cooldown can never skip the fetch —
                    # otherwise the `develop` above (which warms the log) makes
                    # this timing-dependent.
                    Base.rm(VibePkg.Registries.registry_update_log_file(depot); force = true)
                    VibePkg.up("Foo"; io = buf)
                    !occursin("git-repo", String(take!(buf)))
                end
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            VibePkg.API.OFFLINE_MODE[] = old_offline
        end
    end
end

@testset "Pkg.jl#4131 sysimage build-number mismatch downgrades JLL on update" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            # 1. add Example: the registry resolves the latest non-yanked 0.5.1
            env = load_environment(dir; depots)
            added = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            @test entry_version(added.manifest[EXAMPLE_UUID]) == v"0.5.1"
            write_environment(env, added)

            # 2. fake a sysimage-baked Example whose recorded (Project.toml)
            #    version is an OLDER build (0.5.0) than what the registry ships
            #    (0.5.1) — mirroring a JLL whose sysimaged build number differs
            #    from the registered one (#4131). Restore global state after.
            pkgid = Base.PkgId(EXAMPLE_UUID, "Example")
            in_sys_before = pkgid in Base._sysimage_modules
            had_origin = haskey(Base.pkgorigins, pkgid)
            saved_origin = get(Base.pkgorigins, pkgid, nothing)
            try
                in_sys_before || push!(Base._sysimage_modules, pkgid)
                Base.pkgorigins[pkgid] = Base.PkgOrigin(nothing, nothing, v"0.5.0")

                # 3. update the pinned-to-0.5.1 environment
                env2 = load_environment(dir; depots)
                updated = plan_up(env2, regs, Config(depots))

                # CORRECT behavior: `update` must not spuriously downgrade a
                # package to the sysimaged build; 0.5.1 should be kept. Today the
                # candidate filter drops every version != pkgorigin.version with
                # no build-number normalization, so it downgrades to 0.5.0.
                @test entry_version(updated.manifest[EXAMPLE_UUID]) == v"0.5.1"
            finally
                in_sys_before || filter!(!=(pkgid), Base._sysimage_modules)
                if had_origin
                    Base.pkgorigins[pkgid] = saved_origin
                else
                    delete!(Base.pkgorigins, pkgid)
                end
            end
        end
    end
end

@testset "Pkg.jl#3555 instantiate without a Manifest forces a redundant registry update" begin
    # Sockets is a stdlib dep of VibePkg; bind it locally (no top-level using).
    Sockets = Base.require(Base.PkgId(UUID("6462fe0b-24de-5631-8697-dd941f90decc"), "Sockets"))

    # A tiny server that tallies hits on the /registries endpoint — the request
    # a server-backed registry update issues against the package server. This
    # lets us observe whether an operation forced a registry update WITHOUT any
    # monkeypatch: we just count real network requests to a local socket.
    function count_registries_hits(hits)
        port, server = Sockets.listenany(Sockets.localhost, 43127)
        @async while isopen(server)
            sock = try
                Sockets.accept(server)
            catch
                break
            end
            @async try
                req = readline(sock)
                while !isempty(readline(sock))
                end
                parts = split(req)
                target = length(parts) >= 2 ? String(parts[2]) : ""
                target == "/registries" && (hits[] += 1)
                # empty 200 so Fetch.download succeeds (no matching hashes)
                write(sock, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            catch
            finally
                close(sock)
            end
        end
        return "http://127.0.0.1:$(Int(port))", server
    end

    mktempdir() do dir
        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        old_offline = VibePkg.API.OFFLINE_MODE[]
        old_ap = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        depot = mkpath(joinpath(dir, "depot"))
        # An unpacked, server-installed registry: Registry.toml + .tree_info.toml
        # (a resolvable uuid + a recorded tree hash) is exactly the shape a
        # forced registry update queries the package server's /registries
        # endpoint about — so a redundant update shows up as a socket hit.
        reg = make_test_registry(depot)
        write(
            joinpath(reg, ".tree_info.toml"),
            "git-tree-sha1 = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n",
        )

        hits = Ref(0)
        url, server = count_registries_hits(hits)
        try
            # Reset process-wide state a prior test may have left dirty, so the
            # forced update genuinely runs (not short-circuited) and re-reads
            # this depot's registry rather than a cached instance.
            empty!(VibePkg.Registries.REGISTRY_CACHE)
            # the session has ALREADY updated the registry, and we are online:
            # exactly the MWE's precondition (a second update is redundant).
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            VibePkg.API.OFFLINE_MODE[] = false
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            # ONLY this fresh depot on the stack — including the persistent warm
            # depots would let their registry update-logs put them on cooldown
            # on a re-run, making hits[] flaky.
            copy!(Base.DEPOT_PATH, [depot])

            # A project depending on Example with NO Manifest.toml.
            proj = mkpath(joinpath(dir, "proj"))
            write(
                joinpath(proj, "Project.toml"), """
                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")
            @test !isfile(joinpath(proj, "Manifest.toml"))   # precondition: no manifest

            # Drop the per-depot registry update log so the forced update's
            # 1-second cooldown can never skip the /registries fetch — otherwise
            # the measurement would be timing-dependent.
            Base.rm(VibePkg.Registries.registry_update_log_file(depot); force = true)
            hits[] = 0
            withenv("JULIA_PKG_SERVER" => url) do
                # instantiate of a manifest-less project routes to `up()`, which
                # forces a registry update. That redundant /registries fetch is
                # issued in `op_context` BEFORE any resolve/install, so we still
                # observe it even though the sourceless Example install then
                # fails; the failure is irrelevant to what we measure.
                try
                    VibePkg.instantiate(io = devnull)
                catch
                end
            end

            # CORRECT behavior: a manifest-less instantiate, with the registry
            # already updated this session, must NOT force yet another registry
            # re-download -> zero /registries hits. Today instantiate() -> up()
            # -> op_context(update_registry = :force) fetches unconditionally
            # despite UPDATED_REGISTRY_THIS_SESSION[] -> hits[] >= 1 -> Broken
            # (flips to Unexpected Pass once the redundant update is dropped).
            @test hits[] == 0
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            VibePkg.API.OFFLINE_MODE[] = old_offline
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_ap
            close(server)
        end
    end
end

@testset "Pkg.jl#4580 instantiate ignores offline for artifact downloads" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot]); regs = reachable_registries(depots)
        mktempdir() do dir
            # A dev package declaring a NON-lazy, not-installed artifact whose
            # only source is a (dead) download URL: instantiating it can only
            # succeed by hitting the network.
            arti = joinpath(dir, "ArtiPkg")
            mkpath(joinpath(arti, "src"))
            uuid = "11112222-3333-4444-5555-666677778888"
            write(
                joinpath(arti, "Project.toml"), """
                name = "ArtiPkg"
                uuid = "$uuid"
                version = "0.1.0"
                """
            )
            write(joinpath(arti, "src", "ArtiPkg.jl"), "module ArtiPkg end\n")
            write(
                joinpath(arti, "Artifacts.toml"), """
                [myart]
                git-tree-sha1 = "0000000000000000000000000000000000000000"

                    [[myart.download]]
                    url = "https://example.invalid/myart.tar.gz"
                    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
                """
            )

            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)
            planned = plan_develop(env0, regs, Config(depots), arti)
            write_environment(env0, planned)
            env = load_environment(envdir; depots)

            # Precondition: the env is set up and offline is genuinely on.
            @test is_path_tracked(env.manifest[UUID(uuid)])
            cfg = Config(depots; offline = true, io = devnull)
            @test cfg.offline

            # under JULIA_PKG_OFFLINE=1 instantiate must not attempt to
            # download the artifact (and thus must not throw the "failed to
            # install artifact" PkgError); the missing artifact is skipped
            @test (
                VibePkg.Execution.instantiate!(env, regs, cfg; io = devnull);
                true
            )
        end
    end
end

@testset "Pkg.jl#4579 registry update ignores JULIA_PKG_OFFLINE" begin
    # Sockets is a stdlib dep of VibePkg; bind it locally (no top-level using).
    Sockets = Base.require(Base.PkgId(UUID("6462fe0b-24de-5631-8697-dd941f90decc"), "Sockets"))

    # A tiny server that just tallies hits on the /registries endpoint —
    # the request every registry update issues against the package server.
    function count_registries_hits(hits)
        port, server = Sockets.listenany(Sockets.localhost, 43117)
        @async while isopen(server)
            sock = try
                Sockets.accept(server)
            catch
                break
            end
            @async try
                req = readline(sock)
                while !isempty(readline(sock))
                end
                parts = split(req)
                target = length(parts) >= 2 ? String(parts[2]) : ""
                target == "/registries" && (hits[] += 1)
                # empty 200 so Fetch.download succeeds (no matching hashes)
                write(sock, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            catch
            finally
                close(sock)
            end
        end
        return "http://127.0.0.1:$(Int(port))", server
    end

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        # An unpacked, server-installed registry: Registry.toml + .tree_info.toml
        # (a resolvable uuid + a recorded tree hash) is exactly the shape that
        # `registry update` queries the server about.
        reg = make_test_registry(depot)
        write(
            joinpath(reg, ".tree_info.toml"),
            "git-tree-sha1 = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n",
        )

        hits = Ref(0)
        url, server = count_registries_hits(hits)

        old_offline = VibePkg.API.OFFLINE_MODE[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        old_depots = copy(Base.DEPOT_PATH)
        try
            # Reset process-wide state a prior test may have left dirty, so the
            # registry update genuinely runs (not short-circuited) and re-reads
            # this depot's registry rather than a cached instance.
            empty!(VibePkg.Registries.REGISTRY_CACHE)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
            # ONLY this fresh depot on the stack — including the persistent warm
            # depots would let their registry update-logs (written on the first
            # run) put them on cooldown on a re-run, making hits[] flaky.
            copy!(Base.DEPOT_PATH, [depot])
            VibePkg.API.OFFLINE_MODE[] = true
            @test VibePkg.API.is_offline()          # precondition: we ARE offline

            withenv("JULIA_PKG_SERVER" => url) do
                # This is exactly what `pkg> registry update` invokes.
                VibePkg.Registry.update(; io = devnull)
            end

            # offline mode issues no network request at all: the package
            # server sees zero /registries hits
            @test hits[] == 0
        finally
            VibePkg.API.OFFLINE_MODE[] = old_offline
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            append!(empty!(Base.DEPOT_PATH), old_depots)
            close(server)
        end
    end
end

@testset "Pkg.jl#708 add git repo containing a submodule" begin
    Git = VibePkg.Git
    LibGit2 = VibePkg.Git.LibGit2
    SUBMOD_UUID = UUID("70808080-0708-0708-0708-070870870870")

    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # A second local git repo, to be embedded as a submodule.
        subrepo = joinpath(dir, "SubDep")
        mkpath(subrepo)
        write(joinpath(subrepo, "README.md"), "submodule content\n")
        let repo = LibGit2.init(subrepo)
            LibGit2.add!(repo, ".")
            sig = LibGit2.Signature("tester", "tester@example.com")
            LibGit2.commit(repo, "sub initial"; author = sig, committer = sig)
            LibGit2.close(repo)
        end

        # The package repo: a valid Julia package that also carries a genuine
        # git submodule (a .gitmodules file + a gitlink tree entry). LibGit2's
        # Julia API cannot add submodules, so the CLI git does the setup;
        # protocol.file.allow=always permits a local-path submodule source.
        src = joinpath(dir, "SubModPkg")
        mkpath(joinpath(src, "src"))
        write(
            joinpath(src, "Project.toml"), """
            name = "SubModPkg"
            uuid = "$SUBMOD_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(src, "src", "SubModPkg.jl"), "module SubModPkg end\n")
        run(pipeline(`git -C $src init -q`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $src -c protocol.file.allow=always submodule add $subrepo vendor/sub`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $src -c user.name=tester -c user.email=t@e.com add -A`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $src -c user.name=tester -c user.email=t@e.com commit -q -m initial`; stdout = devnull, stderr = devnull))

        # Precondition: the repo really contains a submodule.
        @test isfile(joinpath(src, ".gitmodules"))

        # Adding a git package that contains a submodule succeeds: the
        # force-checkout of a tree carrying a submodule gitlink out of the
        # bare clone cache used to throw `GitError(Class:Submodule, cannot
        # get submodules without a working tree)`.
        rp = Git.materialize_repo_package!(depots, src; io = devnull)
        @test rp.name == "SubModPkg"
        @test rp.uuid == SUBMOD_UUID
        @test isdir(rp.path)
    end
end

@testset "Pkg.jl#3326 Manifest of a symlinked Project.toml reachable by loader" begin
    if Sys.iswindows()
        # symlinks require privileges on Windows; skip there
        @test_skip true
    else
        mktempdir() do depot
            make_test_registry(depot)
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            mktempdir() do dir
                dir = realpath(dir)
                # the REAL project lives in realdir/Project.toml
                realdir = joinpath(dir, "myproj")
                mkpath(realdir)
                write(
                    joinpath(realdir, "Project.toml"), """
                    [deps]
                    Example = "$EXAMPLE_UUID"
                    """
                )

                # linkdir/Project.toml is a SYMLINK to ../myproj/Project.toml —
                # the scenario from the report (activate the symlinked project).
                linkdir = joinpath(dir, "myprojlink")
                mkpath(linkdir)
                link_project = joinpath(linkdir, "Project.toml")
                symlink(joinpath("..", "myproj", "Project.toml"), link_project)
                @test islink(link_project)

                # activate + instantiate the symlinked project: plan_add(Example)
                # and persist the resulting Manifest.
                env = load_environment(link_project; depots)
                planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
                write_environment(env, planned)

                # The environment's identity is the path the user activated:
                # the final project-file symlink is preserved (only its parent
                # directory is canonicalized), so the Manifest lands beside
                # the symlink (linkdir), NOT beside the symlink target.
                @test env.manifest_file == joinpath(linkdir, "Manifest.toml")
                @test isfile(joinpath(linkdir, "Manifest.toml"))
                @test !isfile(joinpath(realdir, "Manifest.toml"))

                # Julia's own loader activates project files by path with NO
                # realpath (abspath(dirname(project_file)) only), so with the
                # Manifest beside the symlink `using Example` resolves.
                @test Base.project_file_manifest_path(link_project) ==
                    joinpath(linkdir, "Manifest.toml")
            end
        end
    end
end
