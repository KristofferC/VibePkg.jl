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

@testset "Pkg.jl#2525 dev/rev repo url ignores version-winning registry [broken]" begin
    mktempdir() do depot
        # TestRegistry: Example @ 0.5.0/0.5.1(max)/1.0.0(yanked),
        # repo = https://example.com/Example.jl.git
        make_test_registry(depot)

        # OtherRegistry: same Example UUID, a DIFFERENT fork repo url, and a
        # LOWER max version (only 0.5.0). Its name sorts before "TestRegistry",
        # so reachable_registries lists it first.
        other = joinpath(depot, "registries", "OtherRegistry")
        opkg = joinpath(other, "E", "Example")
        mkpath(opkg)
        write(
            joinpath(other, "Registry.toml"), """
            name = "OtherRegistry"
            uuid = "13338594-aafe-5451-b93e-139f81909106"

            [packages]
            $EXAMPLE_UUID = { name = "Example", path = "E/Example" }
            """
        )
        write(
            joinpath(opkg, "Package.toml"), """
            name = "Example"
            uuid = "$EXAMPLE_UUID"
            repo = "https://OTHER-FORK.example.com/Example.jl.git"
            """
        )
        write(
            joinpath(opkg, "Versions.toml"), """
            ["0.5.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            """
        )

        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)

        # Precondition: OtherRegistry is consulted first (alphabetical).
        @test VibePkg.Registries.registry_name.(regs) == ["OtherRegistry", "TestRegistry"]

        mktempdir() do envdir
            env = load_environment(envdir; depots)
            # Precondition: the *version* add resolves to 0.5.1 — a version
            # supplied ONLY by TestRegistry (example.com). So Pkg.add points
            # the manifest at the TestRegistry fork.
            planned = plan_add(env, regs, cfg, [PackageRequest("Example")])
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # Precondition (documents the buggy state): the url a rev/branch add
            # would use — registered_repo_url, first-registry-wins — points at
            # the OTHER fork instead, which does not even carry 0.5.1.
            @test VibePkg.Planning.registered_repo_url(regs, EXAMPLE_UUID) ==
                "https://OTHER-FORK.example.com/Example.jl.git"

            # CRUX (desired, currently false): a rev/branch add and a plain
            # `add` must agree on the registry. The repo url should come from
            # the same registry whose version `add` selected (TestRegistry),
            # not from whichever registry happens to sort first.
            @test_broken VibePkg.Planning.registered_repo_url(regs, EXAMPLE_UUID) ==
                "https://example.com/Example.jl.git"
        end
    end
end

@testset "Pkg.jl#2303 manifest constraint misreported as explicit requirement [broken]" begin
    ResolverError = VibePkg.Resolve.ResolverError
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # Dev package A depends on Example, with compat initially pinning
            # Example to =0.5.0, so developing A records Example@0.5.0 in the
            # manifest.
            Auuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            Adir = joinpath(dir, "A"); mkpath(joinpath(Adir, "src"))
            projpath = joinpath(Adir, "Project.toml")
            write(
                projpath, """
                name = "A"
                uuid = "$Auuid"
                version = "0.1.0"

                [deps]
                Example = "$EXAMPLE_UUID"

                [compat]
                Example = "=0.5.0"
                """
            )
            write(joinpath(Adir, "src", "A.jl"), "module A\nend\n")

            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)
            planned = plan_develop(env0, regs, cfg, Adir)
            write_environment(env0, planned)

            # Precondition (holds today): the manifest pins Example@0.5.0 —
            # this is the ONLY origin of the 0.5.0 constraint (no explicit
            # requirement for Example was ever given).
            env1 = load_environment(envdir; depots)
            @test entry_version(env1.manifest[EXAMPLE_UUID]) == v"0.5.0"

            # Now edit A's compat on disk to require =0.5.1 (no re-develop).
            # `resolve` preserves the manifest's Example@0.5.0 while A now
            # demands =0.5.1 -> genuinely unsatisfiable -> ResolverError.
            write(projpath, replace(read(projpath, String), "=0.5.0" => "=0.5.1"))

            env2 = load_environment(envdir; depots)
            err = try
                plan_resolve(env2, regs, cfg)
                nothing
            catch e
                e
            end
            msg = err === nothing ? "" : replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")

            # Preconditions (hold today): it throws a ResolverError, and the
            # A-origin 0.5.1 constraint IS correctly attributed to A.
            @test err isa ResolverError
            @test occursin("restricted to versions 0.5.1 by A", msg)

            # CORRECT behavior: the 0.5.0 constraint comes solely from the
            # preserved manifest/fixed version, so the resolver explanation must
            # attribute it to that, NOT to "an explicit requirement" (no explicit
            # requirement for Example exists). Today it prints
            #   restricted to versions 0.5.0 by an explicit requirement
            # (Planning.jl turns each manifest node's version into a Requires
            # entry, which graphtype.jl labels :explicit_requirement) -> the
            # assertion is false -> Broken. Flips to Unexpected Pass once the
            # manifest-origin constraint is labeled correctly.
            @test_broken !occursin("restricted to versions 0.5.0 by an explicit requirement", msg)
        end
    end
end

@testset "Pkg.jl#2211 resolve upgrade of dev'd pkg's indirect dep [broken]" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # Synthetic dev pkg TmpPkg depends on Example, pinned via compat
            # to exactly 0.5.0.
            tmpdir = joinpath(dir, "TmpPkg")
            mkpath(joinpath(tmpdir, "src"))
            tmp_uuid = UUID("11111111-1111-1111-1111-111111111111")
            write(
                joinpath(tmpdir, "Project.toml"),
                "name = \"TmpPkg\"\nuuid = \"$tmp_uuid\"\nversion = \"0.1.0\"\n\n" *
                    "[deps]\nExample = \"$EXAMPLE_UUID\"\n\n" *
                    "[compat]\nExample = \"=0.5.0\"\n"
            )
            write(joinpath(tmpdir, "src", "TmpPkg.jl"), "module TmpPkg\nend\n")

            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)

            # dev TmpPkg, then resolve: Example (the indirect dep) lands at 0.5.0
            env1 = plan_develop(env0, regs, cfg, tmpdir)
            write_environment(env0, env1)
            env2 = load_environment(envdir; depots)
            env3 = plan_resolve(env2, regs, cfg)
            write_environment(env2, env3)
            env4 = load_environment(envdir; depots)
            # precondition: this DOES hold today — Example pinned to 0.5.0
            @test entry_version(env4.manifest[EXAMPLE_UUID]) == v"0.5.0"

            # Now bump TmpPkg's compat to require exactly 0.5.1 and re-resolve.
            # Correct behavior: resolve upgrades the single indirect dep to
            # 0.5.1. Bug #2211: resolve instead throws an Unsatisfiable-
            # requirements ResolverError citing a nonexistent explicit 0.5.0
            # requirement (the stale manifest version pinned by PRESERVE_ALL).
            write(
                joinpath(tmpdir, "Project.toml"),
                "name = \"TmpPkg\"\nuuid = \"$tmp_uuid\"\nversion = \"0.1.0\"\n\n" *
                    "[deps]\nExample = \"$EXAMPLE_UUID\"\n\n" *
                    "[compat]\nExample = \"=0.5.1\"\n"
            )
            @test_broken begin
                env5 = plan_resolve(env4, regs, cfg)
                entry_version(env5.manifest[EXAMPLE_UUID]) == v"0.5.1"
            end
        end
    end
end

@testset "Pkg.jl#2028 semver_spec all-zero inconsistency [broken]" begin
    semver_spec = VibePkg.Versions.semver_spec
    # `throws(s)` is true iff semver_spec rejects `s`. The desired, consistent
    # contract is that the whole all-zero family ("0", "0.0", "0.0.0") is
    # treated identically. Today only "0.0.0" is rejected.
    throws(s) = try
        semver_spec(s)
        false
    catch
        true
    end
    # Precondition that holds today: "0.0.0" is rejected.
    @test throws("0.0.0")
    # Crux: "0" and "0.0" SHOULD be rejected the same way, but are currently
    # accepted, so `throws(...)` is false now -> Broken. When the guard is made
    # consistent, these flip to Unexpected Pass.
    @test_broken throws("0")
    @test_broken throws("0.0")
end

@testset "Pkg.jl#2023 malformed target crashes update/develop [broken]" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)
        mktempdir() do dir
            # BadPkg declares `[targets] test = ["Test"]` but Test is absent
            # from [deps], [weakdeps] and [extras]. Historically Pkg validates
            # every project it reads (including dependency/dev projects), so a
            # single malformed project aborts the whole develop/update with an
            # internal validation PkgError. A malformed target should be
            # tolerated / reported gracefully, not crash resolution.
            baddir = joinpath(dir, "BadPkg")
            mkpath(joinpath(baddir, "src"))
            bad_uuid = UUID("33333333-4444-5555-6666-777788889999")
            write(
                joinpath(baddir, "Project.toml"), """
                name = "BadPkg"
                uuid = "$bad_uuid"
                version = "0.1.0"

                [targets]
                test = ["Test"]
                """
            )
            write(joinpath(baddir, "src", "BadPkg.jl"), "module BadPkg end\n")

            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)

            # Correct behavior: developing BadPkg must NOT throw the
            # "Dependency `Test` in target `test` not listed in `deps`,
            # `weakdeps` or `extras`" validation PkgError. Today it does.
            @test_broken (plan_develop(env0, regs, cfg, baddir); true)
        end
    end
end

@testset "Pkg.jl#2007 symlinked depot out-of-tree dev path resolves [broken]" begin
    if Sys.iswindows()
        # creating symlinks requires privileges on Windows; skip there
        @test_skip true
    else
        mktempdir() do depot
            make_test_registry(depot)
            depots = depot_stack([depot]); regs = reachable_registries(depots)
            cfg = Config(depots)
            mktempdir() do base
                base = realpath(base)
                local entry_path = VibePkg.EnvFiles.entry_path

                # A real "julia home" nested deep, plus a *shallower* symlink to
                # it — mirrors `~/.julia -> /data/julia` where the two paths sit
                # at different depths.
                realhome = joinpath(base, "a", "b", "realdepot"); mkpath(realhome)
                jl = joinpath(base, "jl")                       # the shallow symlink
                symlink(realhome, jl)
                @test islink(jl)

                # Default env addressed through the SYMLINK (this is what ends up
                # on Julia's LOAD_PATH: it is NOT realpath'd when code is loaded).
                env_symlink_dir = joinpath(jl, "environments", "v1"); mkpath(env_symlink_dir)
                write(joinpath(env_symlink_dir, "Project.toml"), "")
                # The same dir seen through the real path, at a different depth.
                env_real_dir = joinpath(realhome, "environments", "v1")
                @test realpath(env_symlink_dir) == env_real_dir
                # depth differs -> no lexical relative path from the symlink dir
                # can reach a sibling of the real home
                @test length(splitpath(env_symlink_dir)) != length(splitpath(env_real_dir))

                # Out-of-tree developed package, sibling of the *real* home.
                mypkg_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                pkgdir = joinpath(base, "a", "b", "pkg_test", "MyPkg"); mkpath(pkgdir)
                write(
                    joinpath(pkgdir, "Project.toml"), """
                    name = "MyPkg"
                    uuid = "$mypkg_uuid"
                    version = "0.1.0"
                    """
                )

                # Load the env via the symlink; find_project_file realpath's the
                # project file, so env.manifest_file is the DEEP real path.
                env = load_environment(env_symlink_dir; depots)
                @test dirname(env.manifest_file) == env_real_dir

                # `dev ../../../pkg_test/MyPkg` (relative, as a user would type it
                # from the env). plan_develop interprets it against the realpath'd
                # env dir and stores the relpath against that deep dir.
                rel_in = relpath(pkgdir, env_real_dir)
                planned = plan_develop(env, regs, cfg, rel_in)

                uuid = UUID(mypkg_uuid)
                @test is_path_tracked(planned.manifest[uuid])
                recorded = entry_path(planned.manifest[uuid])

                # How Julia Base resolves a manifest path: lexically (normpath),
                # relative to the NON-realpath'd manifest dir on the LOAD_PATH,
                # i.e. the shallow symlink dir.
                resolved = isabspath(recorded) ? recorded :
                    normpath(joinpath(env_symlink_dir, recorded))

                # CORRECT behavior: whatever path is recorded must actually point
                # at the developed package when loaded through the symlink depot.
                # Today `recorded` is a relpath computed against the deeper real
                # dir, so it overshoots to a nonexistent dir -> realpath throws.
                @test_broken realpath(resolved) == realpath(pkgdir)
            end
        end
    end
end

@testset "Pkg.jl#1829 up Package doesn't upgrade Package it could [broken]" begin
    POR_UUID = UUID("b0000000-0000-0000-0000-000000000001")
    CUT_UUID = UUID("c0000000-0000-0000-0000-000000000002")

    mktempdir() do depot
        # Two-package offline registry: Porcelain (direct dep) depends on the
        # indirect dep Cutlery. Porcelain 1.0.0 requires Cutlery "1"; Porcelain
        # 2.0.0 requires Cutlery "2". Both Cutlery builds exist.
        reg = joinpath(depot, "registries", "UpRegistry")
        mkpath(reg)
        write(
            joinpath(reg, "Registry.toml"), """
            name = "UpRegistry"
            uuid = "13338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.com/UpRegistry.git"

            [packages]
            $POR_UUID = { name = "Porcelain", path = "P/Porcelain" }
            $CUT_UUID = { name = "Cutlery", path = "C/Cutlery" }
            """
        )

        por = mkpath(joinpath(reg, "P", "Porcelain"))
        write(
            joinpath(por, "Package.toml"), """
            name = "Porcelain"
            uuid = "$POR_UUID"
            repo = "https://example.com/Porcelain.jl.git"
            """
        )
        write(
            joinpath(por, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"

            ["2.0.0"]
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            """
        )
        write(
            joinpath(por, "Deps.toml"), """
            ["1"]
            Cutlery = "$CUT_UUID"

            ["2"]
            Cutlery = "$CUT_UUID"
            """
        )
        write(
            joinpath(por, "Compat.toml"), """
            ["1"]
            Cutlery = "1"

            ["2"]
            Cutlery = "2"
            """
        )

        cut = mkpath(joinpath(reg, "C", "Cutlery"))
        write(
            joinpath(cut, "Package.toml"), """
            name = "Cutlery"
            uuid = "$CUT_UUID"
            repo = "https://example.com/Cutlery.jl.git"
            """
        )
        write(
            joinpath(cut, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "3333333333333333333333333333333333333333"

            ["2.0.0"]
            git-tree-sha1 = "4444444444444444444444444444444444444444"
            """
        )

        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        cfg = Config(depots)

        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env0 = load_environment(envdir; depots)

            # Seed the manifest at Porcelain=1.0.0, Cutlery=1.0.0.
            added = plan_add(env0, regs, cfg, [PackageRequest("Porcelain", nothing, "1.0.0")])
            write_environment(env0, added)
            env = load_environment(envdir; depots)

            # Preconditions (buggy state, hold today): the env is pinned at the
            # old builds and both are upgradable.
            @test entry_version(env.manifest[POR_UUID]) == v"1.0.0"
            @test entry_version(env.manifest[CUT_UUID]) == v"1.0.0"

            # A bare `up` DOES upgrade Porcelain 1.0.0 => 2.0.0 (and Cutlery too):
            # so an upgrade is genuinely available.
            bare = plan_up(env, regs, cfg)
            @test entry_version(bare.manifest[POR_UUID]) == v"2.0.0"
            @test entry_version(bare.manifest[CUT_UUID]) == v"2.0.0"

            # CORRECT behavior: `up Porcelain` should upgrade Porcelain whenever a
            # bare `up` would — i.e. to 2.0.0. Today the targeted branch sets
            # effective_preserve = PRESERVE_ALL, freezing the indirect dep Cutlery
            # at 1.0.0, so Porcelain 2.0.0 (which needs Cutlery "2") is unreachable
            # and `up Porcelain` reports no change (stays 1.0.0) -> Broken. Flips
            # to Unexpected Pass once #1829 is fixed.
            targeted = plan_up(env, regs, cfg, [PackageRequest("Porcelain")])
            @test_broken entry_version(targeted.manifest[POR_UUID]) == v"2.0.0"
        end
    end
end

@testset "Pkg.jl#1568 version spec with build metadata rejected [broken]" begin
    VersionSpec = VibePkg.Versions.VersionSpec

    # Precondition (holds today): an ordinary version specifier parses and the
    # spec contains that version, so the parser is wired up for plain versions.
    @test v"2.23.0" in VersionSpec("2.23.0")

    # CRUX 1 (parser root cause): feature request #1568 asks Pkg to support
    # version numbers carrying build metadata (e.g. `2.23.0+1`, exactly what a
    # JLL like Git_jll produces). Such a specifier should be accepted and match
    # that exact version. Today VersionBound splits on '.' and
    # `parse(Int64, "0+1")` throws `ArgumentError: invalid base 10 digit '+'`,
    # so VersionSpec("2.23.0+1") throws -> Broken. Flips to Unexpected Pass once
    # build metadata is supported.
    @test_broken v"2.23.0+1" in VersionSpec("2.23.0+1")

    # CRUX 2 (user-facing MWE): `Pkg.add(PackageSpec(name="Git_jll",
    # version="2.23.0+1"))` / `add Git_jll@2.23.0+1`. Adapted to the offline
    # Example fixture, plan_add with a build-metadata version must not be
    # rejected as an invalid specifier. Today plan_request_version catches the
    # parser's ArgumentError and raises PkgError "invalid version specifier",
    # so `rejected_as_invalid` is true -> Broken. Once #1568 is implemented the
    # specifier is accepted (parsing no longer errors), so this flips to an
    # Unexpected Pass. The op is inside the try, so the file never crashes.
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            env = load_environment(dir; depots)
            rejected_as_invalid = try
                plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1+1")])
                false
            catch e
                e isa PkgError && occursin("invalid version specifier", sprint(showerror, e))
            end
            @test_broken !rejected_as_invalid
        end
    end
end

@testset "Pkg.jl#708 add git repo containing a submodule raises GitError [broken]" begin
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

        # Precondition (holds today): the repo really contains a submodule.
        @test isfile(joinpath(src, ".gitmodules"))

        # CORRECT behavior: adding a git package that contains a submodule must
        # succeed — materialize_repo_package! should return a RepoPackage with
        # the right name/uuid and an installed source tree on disk. Today the
        # force-checkout of a tree carrying a submodule gitlink out of the bare
        # clone cache throws `GitError(Class:Submodule, cannot get submodules
        # without a working tree)`, so this records Broken; it flips to an
        # Unexpected Pass once #708 is fixed. The op is inside @test_broken, so
        # the throw is captured and the file never crashes.
        @test_broken begin
            rp = Git.materialize_repo_package!(depots, src; io = devnull)
            rp.name == "SubModPkg" && rp.uuid == SUBMOD_UUID && isdir(rp.path)
        end
    end
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
