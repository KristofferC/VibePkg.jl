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

            # Correct behavior: offline mode must issue NO network request, so
            # the package server sees zero /registries hits. It currently makes
            # the request regardless of JULIA_PKG_OFFLINE.
            @test_broken hits[] == 0
        finally
            VibePkg.API.OFFLINE_MODE[] = old_offline
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
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


@testset "Pkg.jl#3795 build-metadata dep added but version not bumped [broken]" begin
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
        @test_broken (version_bumped || deps_kept_empty)
    end
end

@testset "Pkg.jl#3644 test_subprocess_flags forces --warn-overwrite=yes [broken]" begin
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
    @test_broken only(wo) == "--warn-overwrite=$(parent)"
end

@testset "Pkg.jl#3555 instantiate without a Manifest forces a redundant registry update [broken]" begin
    # Install a recording spy on `update_registries!` so we can observe whether an
    # operation triggers a registry update. For the plain-directory test registry
    # the real function is already a no-op (no `.git`, no `.tree_info.toml`), so a
    # recorder returning `String[]` is behavior-preserving here — it just counts calls.
    Core.eval(
        VibePkg.Registries, quote
            isdefined(@__MODULE__, :_SPY_UPD_CALLS) || (global _SPY_UPD_CALLS = Ref(0))
            function update_registries!(depots_arg::DepotStack; kwargs...)
                _SPY_UPD_CALLS[] += 1
                return String[]
            end
        end
    )
    spy = VibePkg.Registries._SPY_UPD_CALLS

    mktempdir() do dir
        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        old_offline = VibePkg.API.OFFLINE_MODE[]
        old_ap = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        try
            depot = mkpath(joinpath(dir, "depot"))
            make_test_registry(depot)
            proj = mkpath(joinpath(dir, "proj"))
            # the session has already updated the registry, and we are online:
            # exactly the MWE's precondition
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            VibePkg.API.OFFLINE_MODE[] = false
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")

            # a synthetic local path package with no registered deps: `develop`
            # creates a Project + Manifest without touching the network
            devpkg = joinpath(dir, "Solo")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "Solo"
                uuid = "5c111111-2222-3333-4444-555555555555"
                version = "0.1.0"
                """
            )
            write(joinpath(devpkg, "src", "Solo.jl"), "module Solo\nend\n")

            VibePkg.develop(VibePkg.PackageSpec(path = devpkg); io = devnull)

            manifest_file = load_environment(proj; depots = depot_stack([depot])).manifest_file
            @test isfile(manifest_file)   # precondition: a manifest now exists

            # (A) instantiate WITH the manifest present must not update the registry
            spy[] = 0
            VibePkg.instantiate(io = devnull)
            @test spy[] == 0              # precondition: no update when manifest present

            # (B) delete the manifest, then instantiate again. The session already
            # updated the registry this session, so a manifest-less instantiate must
            # NOT force yet another registry update.
            Base.rm(manifest_file; force = true)
            @test !isfile(manifest_file)  # precondition: the manifest is gone

            spy[] = 0
            VibePkg.instantiate(io = devnull)

            # CORRECT behavior: no forced registry update on the manifest-less path.
            # Today instantiate() -> up() -> op_context(update_registry = :force),
            # which updates unconditionally despite UPDATED_REGISTRY_THIS_SESSION[]
            # -> spy[] == 1 -> Broken.
            @test_broken spy[] == 0
        finally
            spy[] = 0
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            VibePkg.API.OFFLINE_MODE[] = old_offline
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_ap
        end
    end
end

@testset "Pkg.jl#3496 up of unregistered pkg forces registry update [broken]" begin
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
                @test_broken begin
                    VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                    # Drop the per-depot registry update log so the `:force`
                    # update's 1-second cooldown can never skip the fetch —
                    # otherwise the `develop` above (which warms the log) makes
                    # this timing-dependent.
                    rm(VibePkg.Registries.registry_update_log_file(depot); force = true)
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

@testset "Pkg.jl#3494 compat does not include DEV version [broken]" begin
    semver_spec = VibePkg.Versions.semver_spec

    # Precondition (holds today): a plain-numeric prerelease-free specifier
    # parses fine, so the parser itself is wired up.
    @test v"0.5.1" in semver_spec("=0.5.1")

    # Part 1: a prerelease specifier like `=0.5.0-dev` MUST be accepted and the
    # resulting spec MUST contain the prerelease version. Today the [compat]
    # parser has no prerelease branch, so semver_spec throws
    # `invalid version specifier: "=0.5.0-dev"` (Versions.jl:435). Wrapped so
    # the desired-but-absent behavior records Broken.
    @test_broken v"0.5.0-dev" in semver_spec("=0.5.0-dev")

    # Part 2: `=0.5.0` must NOT silently match the 0.5.0-dev prerelease. Today
    # VersionBound equality ignores prerelease tags, so v"0.5.0-dev" wrongly
    # falls inside `=0.5.0`. Assert the correct exclusion (currently false).
    @test_broken !(v"0.5.0-dev" in semver_spec("=0.5.0"))
end

@testset "Pkg.jl#3420 Registry.rm rejects SubString/AbstractString [broken]" begin
    # Precondition (holds today): the positional method exists for String,
    # establishing the buggy state where only concrete String is accepted.
    @test hasmethod(VibePkg.Registry.rm, Tuple{String})

    # Correct behavior: Registry.rm should accept any AbstractString (e.g. a
    # SubString) rather than throwing a MethodError. Today the signature is
    # typed `String...`, so a SubString matches no method — this is @test_broken.
    @test_broken hasmethod(VibePkg.Registry.rm, Tuple{SubString{String}})

    # Behavioral crux: calling rm with a SubString should NOT throw a
    # MethodError (it should reach the normal code path and, for a missing
    # registry, raise a PkgError). Currently it throws MethodError -> the
    # `!(e isa MethodError)` predicate is false -> records Broken.
    @test_broken try
        VibePkg.Registry.rm(SubString("NoSuchRegistry3420", 1))
        true
    catch e
        !(e isa MethodError)
    end
end

@testset "Pkg.jl#3365 tree_hash ENOTDIRs on a non-directory special file [broken]" begin
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
    @test_broken graceful
end

@testset "Pkg.jl#3326 symlinked Project.toml Manifest unreachable by loader [broken]" begin
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

                # PRECONDITIONS (buggy state; hold today): VibePkg follows the
                # symlink via safe_realpath, so the Manifest lands next to the
                # symlink TARGET (realdir), and NOT beside the symlink (linkdir).
                @test env.manifest_file == joinpath(realdir, "Manifest.toml")
                @test isfile(joinpath(realdir, "Manifest.toml"))
                @test !isfile(joinpath(linkdir, "Manifest.toml"))

                # CORRECT behavior: when Julia's own loader activates the
                # symlinked project (linkdir/Project.toml — the path the user
                # activated), it must be able to locate the Manifest so that
                # `using Example` works. Base.project_file_manifest_path uses
                # abspath(dirname(project_file)) with NO realpath, so it looks
                # only in linkdir, finds nothing, and returns `nothing` — the
                # dep "required but does not seem to be installed". -> Broken.
                @test_broken Base.project_file_manifest_path(link_project) !== nothing
            end
        end
    end
end

@testset "Pkg.jl#3269 artifact extraction does not preserve tarball file permissions [broken]" begin
    mktempdir() do dir
        # 1. Build a source tree with one file whose mode is -rw-r----- (0o640):
        #    owner read/write, group read, NO other-read. This is the "raw"
        #    (non-644) permission a tarball can legitimately carry.
        srcdir = mkpath(joinpath(dir, "src"))
        fpath = joinpath(srcdir, "secret.txt")
        write(fpath, "hello")
        chmod(fpath, 0o640)
        @test (filemode(fpath) & 0o777) == 0o640      # source really is 0o640

        # 2. Pack it with the SYSTEM tar, which stores the true 0o640 mode in the
        #    header (Tar.jl's own create would normalize it away).
        tarball = joinpath(dir, "art.tar.gz")
        run(pipeline(`tar -czf $tarball -C $srcdir .`; stdout = devnull, stderr = devnull))

        # 3. Extract through VibePkg's real artifact extraction path
        #    (Fetch.unpack -> Tar.extract).
        ex = mkpath(joinpath(dir, "extracted"))
        VibePkg.Fetch.unpack(tarball, ex)
        exf = joinpath(ex, "secret.txt")
        @test isfile(exf)

        # Precondition documenting the buggy state (holds today): Tar.extract
        # normalizes every non-exec file to 0o644, spuriously ADDING other-read,
        # so the extracted mode is 0o644 instead of the original 0o640.
        @test (filemode(exf) & 0o777) == 0o644

        # CORRECT behavior: extraction should preserve the tarball's original
        # permissions (0o640 — no spurious o+r). Today it does not (it is 0o644),
        # so this records Broken; it flips to Unexpected Pass once #3269 is fixed.
        @test_broken (filemode(exf) & 0o777) == 0o640
    end
end

@testset "Pkg.jl#3150 pinned pkg wrongly marked upgradable (⌃) [broken]" begin
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

            # buggy state that holds today: Example is pinned at 0.5.0, yet
            # status still flags it upgradable with the ⌃ gutter.
            @test env.manifest[EXAMPLE_UUID].pinned
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.0"
            s = sprint(io -> print_status(io, env; registries = regs))
            @test occursin("⌃", s)

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
            @test_broken (!occursin("⌃", s)) || up_moved
        end
    end
end

@testset "Pkg.jl#2922 interrupting test orphans sandbox child [broken]" begin
    TestOps = VibePkg.TestOps

    # true iff process `pid` still exists (unix `kill -0`)
    alive = function (pid)
        try
            run(pipeline(`kill -0 $pid`; stdout = devnull, stderr = devnull))
            return true
        catch
            return false
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

        # preconditions establishing the buggy state (hold today)
        @test child_pid !== nothing
        @test child_pid !== nothing && alive(child_pid)

        try
            # simulate ^C reaching only the driver task
            schedule(task, InterruptException(); error = true)

            # CORRECT behavior: interrupting the driver must reliably terminate
            # the child test session. A correct implementation escalates to
            # SIGKILL within a few seconds; poll a generous 8s window. Today the
            # synchronous `run(...)` orphans the child, so it stays alive -> the
            # assertion is false -> Broken (flips to Unexpected Pass once fixed).
            child_dead = false
            t1 = time()
            while time() - t1 < 8
                if !alive(child_pid)
                    child_dead = true
                    break
                end
                sleep(0.1)
            end
            @test_broken child_dead
        finally
            # never leave the orphan running past the test
            if child_pid !== nothing
                try
                    run(pipeline(`kill -9 $child_pid`; stdout = devnull, stderr = devnull))
                catch
                end
            end
        end
    end
end

@testset "Pkg.jl#2894 setprotocol! drops non-standard SSH port [broken]" begin
    # Pure/offline: exercise the URL rewriter directly. After
    # setprotocol!(domain="domain", protocol="ssh"), an scp-style URL that
    # carries an explicit SSH port must have that port preserved in the
    # emitted ssh:// URL, not folded into the path.
    setproto = VibePkg.Git.setprotocol!
    normalize = VibePkg.Git.normalize_url

    setproto(; domain = "domain", protocol = "ssh")

    input = "user@domain:2222/git-server/repos/ARTime.git"
    got = normalize(input)

    # Precondition that DOES hold today: it becomes an ssh:// URL with the
    # git user, and the buggy output swallows the port into the path.
    @test got == "ssh://git@domain/2222/git-server/repos/ARTime.git"

    # The CORRECT behavior: port 2222 preserved as a real port component.
    @test_broken got == "ssh://git@domain:2222/git-server/repos/ARTime.git"
end
