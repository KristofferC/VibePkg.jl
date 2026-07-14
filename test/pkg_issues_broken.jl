# @test_broken regression tests for open Pkg.jl bugs that STILL REPRODUCE in
# VibePkg (verdict PERSISTS in test/PKG_ISSUES_AUDIT.md). Each testset asserts
# the *correct* behavior wrapped in `@test_broken`, so the suite records it as
# Broken today and will report an "Unexpected Pass" the moment the bug is fixed
# — at which point the testset is moved into test/pkg_issues.jl as a passing
# `@test`. See test/PKG_ISSUES_AUDIT.md for the per-issue evidence.
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


@testset "Pkg.jl#4705 dev'd dep [sources] to absent path leaks [broken]" begin
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
            @test_broken begin
                planned = plan_develop(env0, regs, cfg, leakydir)
                ex_version = entry_version(planned.manifest[EXAMPLE_UUID])
                ex_version == v"0.5.1"
            end
        end
    end
end

@testset "Pkg.jl#4580 instantiate ignores offline for artifact downloads [broken]" begin
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

            # Correct behavior under JULIA_PKG_OFFLINE=1: instantiate must not
            # attempt to download the artifact (and thus must not throw the
            # "failed to install artifact ... from any of: https://..."
            # PkgError). Today instantiate ignores offline and throws.
            @test_broken (
                VibePkg.Execution.instantiate!(env, regs, cfg; io = devnull);
                true
            )
        end
    end
end

@testset "Pkg.jl#4579 registry update ignores JULIA_PKG_OFFLINE [broken]" begin
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
        old_depots = copy(Base.DEPOT_PATH)
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots])
            VibePkg.API.OFFLINE_MODE[] = true
            @test VibePkg.API.is_offline()          # precondition: we ARE offline

            withenv("JULIA_PKG_SERVER" => url) do
                # This is exactly what `pkg> registry update` invokes.
                VibePkg.Registry.update(; io = devnull)
            end

            # Correct behavior: offline mode must issue NO network request, so
            # the package server sees zero /registries hits. It currently makes
            # the request regardless of JULIA_PKG_OFFLINE.
            @test_broken hits[] == 0
        finally
            VibePkg.API.OFFLINE_MODE[] = old_offline
            append!(empty!(Base.DEPOT_PATH), old_depots)
            close(server)
        end
    end
end

@testset "Pkg.jl#4553 uncompress_registry resolves `..` path segments [broken]" begin
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
    @test_broken haskey(VibePkg.Fetch.uncompress_registry(path), "Registry.toml")
end

@testset "Pkg.jl#4351 nested [sources] rev change not picked up on resolve [broken]" begin
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
            PkgB = {url = "$pkgB", rev = "$c1"}
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
        @test_broken entry_repo_rev(e2) == c2
        @test_broken entry_tree_hash(e2) == git_tree_hash(pkgB, c2)
    end
end

@testset "Pkg.jl#4131 sysimage build-number mismatch downgrades JLL on update [broken]" begin
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
                @test_broken entry_version(updated.manifest[EXAMPLE_UUID]) == v"0.5.1"
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

@testset "Pkg.jl#4103 is_manifest_current misses deved dep Project change [broken]" begin
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
            @test_broken VibePkg.Environments.is_manifest_current(env2) === false
        end
    end
end

@testset "Pkg.jl#4082 dependencies() must not write manifest_usage.toml [broken]" begin
    mktempdir() do dir
        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        proj = mkpath(joinpath(dir, "proj"))
        try
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")

            # Synthetic env with a Manifest.toml on disk (offline: Example only).
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            env = load_environment(proj; depots)
            planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            write_environment(env, planned)
            @test isfile(joinpath(proj, "Manifest.toml"))

            # Clear any pre-existing usage log; precondition = no log on disk.
            usage_file = joinpath(depot, "logs", "manifest_usage.toml")
            Base.rm(usage_file; force = true)
            @test !isfile(usage_file)

            # A read-only query on the active environment.
            VibePkg.dependencies()

            # Desired: dependencies() is side-effect free and records no
            # manifest usage. Today it calls log_usage and writes the file.
            @test_broken !isfile(usage_file)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end

@testset "Pkg.jl#4068 develop of a path package does not trigger Pkg.build [broken]" begin
    mktempdir() do dir
        # save/restore global process state (mirrors public_api.jl with_api_env)
        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            depot = mkpath(joinpath(dir, "depot"))
            make_test_registry(depot)
            proj = mkpath(joinpath(dir, "proj"))
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")

            # a synthetic local package with a deps/build.jl that drops a sentinel
            devpkg = joinpath(dir, "BuildMe")
            mkpath(joinpath(devpkg, "src"))
            mkpath(joinpath(devpkg, "deps"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "BuildMe"
                uuid = "bb111111-2222-3333-4444-555555555555"
                version = "0.1.0"
                """
            )
            write(joinpath(devpkg, "src", "BuildMe.jl"), "module BuildMe\nend\n")
            sentinel = joinpath(devpkg, "deps", "BUILD_RAN")
            write(
                joinpath(devpkg, "deps", "build.jl"), """
                write(raw"$sentinel", "ran")
                """
            )

            # precondition: the build has not run before develop
            @test !isfile(sentinel)

            VibePkg.develop(VibePkg.PackageSpec(path = devpkg); io = devnull)

            # the dev'd package is now tracked by path (develop itself worked)
            env = load_environment(proj; depots = depot_stack([depot]))
            @test is_path_tracked(env.manifest[UUID("bb111111-2222-3333-4444-555555555555")])

            # CORRECT behavior: develop should have triggered the build, so the
            # sentinel exists. It currently does NOT (run_plan only builds newly
            # *installed* pkgs; path entries are never added) -> Broken.
            @test_broken isfile(sentinel)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end

@testset "Pkg.jl#4006 ResolverError color baked at construction, not decided in showerror [broken]" begin
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
    @test_broken !occursin("\e[", plain)
end

@testset "Pkg.jl#3901 resolver errors drop JLL build numbers [broken]" begin
    # Two versions that differ ONLY in build metadata (+1 vs +2), as a JLL
    # would produce. The resolver formats "possible versions are: ..." using
    # range_compressed_versionspec / VersionSpec, both of which stringify
    # through VersionBound (major/minor/patch only). Build metadata is dropped,
    # so a build-conflict error prints "1.18.0" for both, making it illegible.
    v1 = v"1.18.0+1"
    v2 = v"1.18.0+2"

    # Precondition (holds today): the two versions ARE distinct.
    @test v1 != v2

    # Single-version spec: currently renders "1.18.0", losing "+1".
    single = string(VibePkg.Versions.VersionSpec(v1))
    @test single == "1.18.0"                      # buggy state today

    # Compressed spec over the two builds collapses to one indistinct string.
    compressed = string(VibePkg.Resolve.range_compressed_versionspec([v1, v2]))
    @test compressed == "1.18.0"                  # buggy state today

    # CORRECT behavior (currently fails): resolver version strings must keep
    # build metadata so the two conflicting builds are distinguishable.
    @test_broken occursin("+1", single)
    @test_broken single != string(VibePkg.Versions.VersionSpec(v2))
    @test_broken occursin("+1", compressed) && occursin("+2", compressed)
end

@testset "Pkg.jl#3853 wrong name mapped to a registered UUID is silently accepted [broken]" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            # Project.toml declares `WrongName` mapped to Example's real UUID —
            # the analog of the report's `ForwardDiff = <WebIO-UUID>`.
            write(
                joinpath(dir, "Project.toml"), """
                [deps]
                WrongName = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            env = load_environment(dir; depots)

            # Precondition (holds today): the registry says this UUID is `Example`,
            # so the declared name `WrongName` disagrees with the registry.
            @test env.project.deps["WrongName"] == EXAMPLE_UUID
            @test Planning.registered_name(regs, EXAMPLE_UUID) == "Example"

            # Correct behavior: planning an add of the mis-named dep must reject the
            # name/UUID mismatch. Today plan_add silently succeeds (installing the
            # UUID's real package `Example` under the bogus name `WrongName`), so
            # this records Broken; it flips to Unexpected Pass once the mismatch is
            # detected. The op is inside the try so the file never crashes.
            threw_mismatch = try
                plan_add(env, regs, Config(depots), [PackageRequest("WrongName")])
                false
            catch e
                e isa PkgError
            end
            @test_broken threw_mismatch
        end
    end
end
