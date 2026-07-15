# Public-API option parity with Pkg (audit 2026-07-12): every documented
# kwarg of Pkg's `public` functions exists here and behaves — PackageMode
# enums, add target=/prefer_loaded_versions=, test allow_reresolve=/Cmd
# args, precompile options, activate prev=, readonly, @pkg_str.

# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Logging
using LibGit2
using Base: UUID
using VibePkg
using VibePkg.Configs: Config
using VibePkg: PKGMODE_PROJECT, PKGMODE_MANIFEST, PackageMode
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries, RegistryInstance
using VibePkg.Environments
using VibePkg.Planning
using VibePkg.Planning: PackageRequest
using VibePkg.EnvFiles: entry_version
using VibePkg.Errors: PkgError
import VibePkg.API
import VibePkg.REPLMode

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

const VIBEPKG_UUID = UUID("3f0b6c73-7bb3-486f-8fc9-2db233a17ba0")

# run `f` with the fixture registry active, a fresh depot, and `dir`'s
# project activated — the pattern every API-level check here needs
function with_api_env(f, dir)
    old_active = Base.ACTIVE_PROJECT[]
    old_depot_path = copy(Base.DEPOT_PATH)
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    depot = mkpath(joinpath(dir, "depot"))
    make_test_registry(depot)
    proj = mkpath(joinpath(dir, "proj"))
    return try
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        copy!(Base.DEPOT_PATH, [depot])
        Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")
        f(proj, depot)
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depot_path)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
    end
end

@testset "PackageMode enums" begin
    @test VibePkg.Configs.mode_symbol(PKGMODE_PROJECT) === :project
    @test VibePkg.Configs.mode_symbol(PKGMODE_MANIFEST) === :manifest
    @test VibePkg.Configs.mode_symbol(:project) === :project
    @test_throws PkgError VibePkg.Configs.mode_symbol(:bogus)
    @test PackageMode isa Type

    # accepted by the ops that take `mode` (rm/up/status)
    mktempdir() do dir
        with_api_env(dir) do proj, depot
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            env = load_environment(proj; depots)
            planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            write_environment(env, planned)

            buf = IOBuffer()
            VibePkg.status(; mode = PKGMODE_MANIFEST, io = buf)
            @test occursin("Example", String(take!(buf)))

            VibePkg.rm("Example"; mode = PKGMODE_MANIFEST, io = devnull)
            env = load_environment(proj; depots)
            @test isempty(env.project.deps)
        end
    end
end

@testset "status/why positional packages" begin
    mktempdir() do dir
        with_api_env(dir) do proj, depot
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            env = load_environment(proj; depots)
            planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            write_environment(env, planned)

            # name filter, uuid filter, and the No Matches line
            out = sprint(io -> VibePkg.status("Example"; io))
            @test occursin("Example", out)
            out = sprint(io -> VibePkg.status(PackageSpec(uuid = EXAMPLE_UUID); io))
            @test occursin("Example", out)
            out = sprint(io -> VibePkg.status("Nope"; io))
            @test occursin("No Matches", out)
            @test !occursin("Example", out)
            # in manifest mode a match brings its dependencies along
            out = sprint(io -> VibePkg.status("Example"; mode = PKGMODE_MANIFEST, io))
            @test occursin("Example", out) && occursin("Test", out)

            # why takes vectors and PackageSpecs
            out = sprint(io -> VibePkg.why(["Example"]; io))
            @test occursin("Example", out)
            out = sprint(io -> VibePkg.why(PackageSpec(uuid = EXAMPLE_UUID); io))
            @test occursin("Example", out)

            # vpkg> st Example parses to a status filter
            REPLMode.TEST_MODE[] = true
            try
                api, args, _ = only(REPLMode.do_cmd("st Example"))
                @test api === API.status
                @test only(args) isa Vector{PackageSpec}
                @test only(only(args)).name == "Example"
            finally
                REPLMode.TEST_MODE[] = false
            end
        end
    end
end

@testset "add target = :weakdeps/:extras" begin
    mktempdir() do dir
        with_api_env(dir) do proj, depot
            VibePkg.add("Example"; target = :weakdeps, io = devnull)
            depots = depot_stack([depot])
            env = load_environment(proj; depots)
            @test env.project.weakdeps["Example"] == EXAMPLE_UUID
            @test isempty(env.project.deps)
            @test isempty(env.manifest.deps)      # nothing resolved or installed

            VibePkg.add("Example"; target = :extras, io = devnull)
            env = load_environment(proj; depots)
            @test env.project.extras["Example"] == EXAMPLE_UUID

            @test_throws PkgError VibePkg.add("Example"; target = :bogus, io = devnull)

            # a real `add` promotes the name out of [weakdeps] (plan level:
            # the API add would also install the fixture's fake tree)
            regs = reachable_registries(depots)
            planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            @test !haskey(planned.project.weakdeps, "Example")
            @test planned.project.deps["Example"] == EXAMPLE_UUID
        end
    end
end

@testset "add prefer_loaded_versions" begin
    # the resolver honors preferred versions: with a preference for 0.5.0
    # the plan lands there, without it the latest (0.5.1) wins
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        env = load_environment(mkpath(joinpath(dir, "proj")); depots)

        planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")])
        @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1"

        preferred_versions = Dict(EXAMPLE_UUID => v"0.5.0")
        planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")]; preferred_versions)
        @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.0"

        # collect_preferred_loaded_versions: loaded non-stdlib packages not
        # in the manifest (VibePkg itself qualifies), stdlibs never
        preferred = API.collect_preferred_loaded_versions(env)
        @test haskey(preferred, VIBEPKG_UUID)
        @test !haskey(preferred, TEST_UUID)   # Test is a stdlib

        # already-in-manifest packages are not preference candidates
        @test !haskey(API.collect_preferred_loaded_versions(planned), EXAMPLE_UUID)

        # the kwarg is REPL-default, API-off (Pkg parity)
        @test !API.in_repl_mode()
        @test Base.ScopedValues.with(() -> API.in_repl_mode(), API.IN_REPL_MODE => true)
    end
end

@testset "readonly" begin
    mktempdir() do dir
        with_api_env(dir) do proj, depot
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            env = load_environment(proj; depots)
            planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            write_environment(env, planned)
            API.record_undo!(env, planned)

            @test VibePkg.readonly() == false
            @test VibePkg.readonly(true; io = devnull) == false   # returns previous state
            @test VibePkg.readonly() == true
            @test occursin("readonly = true", read(joinpath(proj, "Project.toml"), String))

            # every mutating op refuses with the pinned message
            err = try
                VibePkg.rm("Example"; io = devnull)
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("Cannot modify read-only environment", err.msg)

            # An old snapshot has readonly=false, but it must not be able to
            # bypass the current environment's guard. The rejected write also
            # must not consume the undo step.
            @test_throws PkgError VibePkg.undo(; io = devnull)
            @test VibePkg.readonly() == true
            @test haskey(load_environment(proj; depots).project.deps, "Example")

            @test VibePkg.readonly(false; io = devnull) == true
            VibePkg.undo(; io = devnull)
            @test isempty(load_environment(proj; depots).project.deps)
            VibePkg.redo(; io = devnull)
            @test haskey(load_environment(proj; depots).project.deps, "Example")
            VibePkg.rm("Example"; io = devnull)
            @test isempty(load_environment(proj; depots).project.deps)
        end
    end
end

@testset "activate prev" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_prev = VibePkg.API.PREV_ENV_PATH[]
    try
        mktempdir() do dir
            a = mkpath(joinpath(dir, "a"))
            b = mkpath(joinpath(dir, "b"))
            VibePkg.activate(a; io = devnull)
            VibePkg.activate(b; io = devnull)
            VibePkg.activate(; prev = true, io = devnull)
            @test dirname(Base.active_project()) == realpath(a)
            VibePkg.activate(; prev = true, io = devnull)   # toggles back
            @test dirname(Base.active_project()) == realpath(b)

            @test_throws PkgError VibePkg.activate(a; prev = true, io = devnull)
            @test_throws PkgError VibePkg.activate(; prev = true, temp = true, io = devnull)

            VibePkg.API.PREV_ENV_PATH[] = ""
            @test_throws PkgError VibePkg.activate(; prev = true, io = devnull)
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        VibePkg.API.PREV_ENV_PATH[] = old_prev
    end
end

@testset "test op: Cmd args and allow_reresolve" begin
    mktempdir() do dir
        pkg = joinpath(dir, "CmdPkg")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "CmdPkg"
            uuid = "dddddddd-1111-2222-3333-444444444444"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "CmdPkg.jl"), "module CmdPkg end\n")
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            @assert ARGS == ["extra"]
            @assert Base.JLOptions().depwarn == 0
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        planned = Planning.plan_develop(env, RegistryInstance[], Config(depots), pkg)
        write_environment(env, planned)
        env = load_environment(envdir; depots)

        # Cmd forms of julia_args/test_args reach the subprocess; a clean
        # resolve under allow_reresolve = false never needs the fallback
        failed = VibePkg.TestOps.test!(
            env, RegistryInstance[], Config(depots), UUID("dddddddd-1111-2222-3333-444444444444");
            julia_args = `--depwarn=no`, test_args = `extra`,
            allow_reresolve = false, io = devnull,
        )
        @test failed === nothing
    end
end

@testset "test op: allow_reresolve recovers a yanked manifest version" begin
    mktempdir() do dir
        fx = LocalPkgServer.ensure!()
        depot = mkpath(joinpath(dir, "depot"))
        pkg = mkpath(joinpath(dir, "ReresolvePkg"))
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        pkg_uuid = UUID("cccccccc-1111-2222-3333-444444444444")

        write(
            joinpath(pkg, "Project.toml"), """
            name = "ReresolvePkg"
            uuid = "$pkg_uuid"
            version = "0.1.0"

            [deps]
            Example = "$EXAMPLE_UUID"

            [compat]
            Example = "0.5"

            [extras]
            Test = "$TEST_UUID"

            [targets]
            test = ["Test"]
            """
        )
        write(
            joinpath(pkg, "src", "ReresolvePkg.jl"),
            "module ReresolvePkg\nimport Example\nexample_version() = Base.pkgversion(Example)\nend\n",
        )
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using Test, ReresolvePkg
            @test ReresolvePkg.example_version() == v"0.5.0"
            """
        )

        # A tiny registry whose package trees are served by LocalPkgServer.
        # Version 0.5.1 remains in the checked-in manifest below but has been
        # yanked from the registry, while 0.5.0 is the surviving fallback.
        regpkg = mkpath(joinpath(depot, "registries", "YankedRegistry", "E", "Example"))
        write(
            joinpath(depot, "registries", "YankedRegistry", "Registry.toml"), """
            name = "YankedRegistry"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.invalid/YankedRegistry"

            [packages]
            $EXAMPLE_UUID = { name = "Example", path = "E/Example" }
            """
        )
        write(
            joinpath(regpkg, "Package.toml"), """
            name = "Example"
            uuid = "$EXAMPLE_UUID"
            repo = "$(fx.git_repo)"
            """
        )
        write(
            joinpath(regpkg, "Versions.toml"), """
            ["0.5.0"]
            git-tree-sha1 = "$(fx.version_hashes["0.5.0"])"

            ["0.5.1"]
            git-tree-sha1 = "$(fx.version_hashes["0.5.1"])"
            yanked = true
            """
        )
        write(
            joinpath(pkg, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Example]]
            git-tree-sha1 = "$(fx.version_hashes["0.5.1"])"
            uuid = "$EXAMPLE_UUID"
            version = "0.5.1"

            [[deps.ReresolvePkg]]
            deps = ["Example"]
            path = "."
            uuid = "$pkg_uuid"
            version = "0.1.0"
            """
        )

        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            Base.ACTIVE_PROJECT[] = joinpath(pkg, "Project.toml")
            copy!(Base.DEPOT_PATH, [depot])
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true

            # The child must use the same fresh depot into which this API call
            # installs the recovered package source.
            withenv("JULIA_DEPOT_PATH" => depot) do
                # Preserve-exact must expose the broken checked-in manifest when
                # fallback is forbidden.
                @test_throws VibePkg.Resolve.ResolverError VibePkg.test(
                    ; allow_reresolve = false, io = devnull,
                )

                # With fallback enabled, exercise the real public sandbox flow:
                # resolve fails, plan_up picks 0.5.0, its source is installed from
                # the local server, and the test subprocess observes that version.
                output = IOBuffer()
                test_error = try
                    VibePkg.test(; allow_reresolve = true, io = output)
                    nothing
                catch err
                    err
                end
                text = String(take!(output))
                test_error === nothing || println(stderr, text)
                @test test_error === nothing
                @test occursin("Could not use exact versions", text)
                @test occursin("Successfully re-resolved", text)
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end

@testset "precompile options" begin
    mktempdir() do dir
        with_api_env(dir) do proj, depot
            pkg = joinpath(dir, "PrecompPkg")
            mkpath(joinpath(pkg, "src"))
            write(
                joinpath(pkg, "Project.toml"), """
                name = "PrecompPkg"
                uuid = "ffffffff-1111-2222-3333-444444444444"
                version = "0.1.0"
                """
            )
            write(joinpath(pkg, "src", "PrecompPkg.jl"), "module PrecompPkg end\n")
            depots = depot_stack([depot])
            env = load_environment(proj; depots)
            planned = Planning.plan_develop(env, RegistryInstance[], Config(depots), pkg)
            write_environment(env, planned)

            io = IOBuffer()
            VibePkg.precompile(; strict = true, timing = true, io)
            # Pkg.jl api.jl "timing mode" — timing = true prints a "Precompiling"
            # banner with a per-package elapsed time and the package name.
            pcout = String(take!(io))
            @test occursin("Precompiling", pcout)
            @test occursin(r"\d+\.\d+ ?m?s", pcout)      # e.g. "181.3 ms" or "0.5 s"
            @test occursin("PrecompPkg", pcout)

            VibePkg.precompile("PrecompPkg"; io = devnull)                     # positional form
            VibePkg.precompile(PackageSpec(name = "PrecompPkg"); io = devnull) # spec form

            # Pkg.jl api.jl "delayed precompilation with do-syntax" — auto-
            # precompilation is deferred while the do-block runs, then restored,
            # so batched manifest changes precompile once at block end.
            @test VibePkg.API.AUTO_PRECOMPILE_ENABLED[]           # enabled to start
            observed = Ref(true)
            VibePkg.precompile(io = devnull) do
                observed[] = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
            end
            @test observed[] == false                             # deferred inside
            @test VibePkg.API.AUTO_PRECOMPILE_ENABLED[]           # restored after
        end
    end
end

# Pkg.jl api.jl "instantiate" — instantiate triggers precompilation of the
# environment when auto-precompilation is enabled.
@testset "instantiate precompiles" begin
    mktempdir() do dir
        with_api_env(dir) do proj, depot
            pkg = joinpath(dir, "InstPCPkg")
            mkpath(joinpath(pkg, "src"))
            write(
                joinpath(pkg, "Project.toml"), """
                name = "InstPCPkg"
                uuid = "eeeeeeee-1111-2222-3333-444444444444"
                version = "0.1.0"
                """
            )
            write(joinpath(pkg, "src", "InstPCPkg.jl"), "module InstPCPkg end\n")
            depots = depot_stack([depot])
            env = load_environment(proj; depots)
            write_environment(env, Planning.plan_develop(env, RegistryInstance[], Config(depots), pkg))

            io = IOBuffer()
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "true") do
                VibePkg.instantiate(io = io)         # freshly dev'd → must precompile it
            end
            @test occursin("Precompiling", String(take!(io)))
        end
    end
end

# Pkg.jl api.jl "Pkg.precompile" — the mutating API operations that promise
# auto-precompilation really populate the cache, and an immediately following
# manual precompile is consequently a no-op.  A local Git repository exercises
# both add and branch-update without a registry or network connection.
@testset "auto-precompile triggers and no-op detection" begin
    old_auto = API.AUTO_PRECOMPILE_ENABLED[]
    try
        API.AUTO_PRECOMPILE_ENABLED[] = true
        @test withenv("JULIA_PKG_PRECOMPILE_AUTO" => "true") do
            API.should_autoprecompile()
        end
        @test !withenv("JULIA_PKG_PRECOMPILE_AUTO" => "false") do
            API.should_autoprecompile()
        end
        API.AUTO_PRECOMPILE_ENABLED[] = false
        @test !withenv("JULIA_PKG_PRECOMPILE_AUTO" => "true") do
            API.should_autoprecompile()
        end
        API.AUTO_PRECOMPILE_ENABLED[] = true

        mktempdir() do dir
            with_api_env(dir) do proj, depot
                pkg = joinpath(dir, "AutoPrecompilePkg")
                mkpath(joinpath(pkg, "src"))
                mkpath(joinpath(pkg, "deps"))
                project_file = joinpath(pkg, "Project.toml")
                source_file = joinpath(pkg, "src", "AutoPrecompilePkg.jl")
                write(
                    project_file, """
                    name = "AutoPrecompilePkg"
                    uuid = "dddddddd-aaaa-bbbb-cccc-111111111111"
                    version = "0.1.0"
                    """
                )
                write(source_file, "module AutoPrecompilePkg\nconst VALUE = 1\nend\n")
                write(joinpath(pkg, "deps", "build.jl"), "nothing\n")

                repo = LibGit2.init(pkg)
                try
                    sig = LibGit2.Signature("fixture", "fixture@localhost")
                    LibGit2.add!(repo, ".")
                    LibGit2.commit(repo, "initial"; author = sig, committer = sig)
                    head = LibGit2.head(repo)
                    branch = try
                        LibGit2.shortname(head)
                    finally
                        close(head)
                    end

                    function assert_triggered_then_noop(f)
                        io = IOBuffer()
                        f(io)
                        @test occursin("Precompiling", String(take!(io)))
                        VibePkg.precompile(; io)
                        @test !occursin("Precompiling", String(take!(io)))
                    end

                    withenv("JULIA_PKG_PRECOMPILE_AUTO" => "true") do
                        # add precompiles only the requested package/closure
                        assert_triggered_then_noop() do io
                            VibePkg.add(PackageSpec(path = pkg, rev = branch); io)
                        end

                        # Clearing the cache makes build's auto-precompile
                        # observable without relying on source timestamp granularity.
                        cache = joinpath(
                            depot, "compiled", "v$(VERSION.major).$(VERSION.minor)",
                            "AutoPrecompilePkg",
                        )
                        Base.rm(cache; force = true, recursive = true)
                        assert_triggered_then_noop() do io
                            VibePkg.build("AutoPrecompilePkg"; io)
                        end

                        # Move the tracked branch. `up` must fetch the new tree and
                        # precompile it; the follow-up manual call must see it cached.
                        write(
                            project_file, """
                            name = "AutoPrecompilePkg"
                            uuid = "dddddddd-aaaa-bbbb-cccc-111111111111"
                            version = "0.1.1"
                            """
                        )
                        write(source_file, "module AutoPrecompilePkg\nconst VALUE = 2\nend\n")
                        LibGit2.add!(repo, ".")
                        LibGit2.commit(repo, "update"; author = sig, committer = sig)
                        assert_triggered_then_noop() do io
                            VibePkg.update("AutoPrecompilePkg"; io)
                        end
                    end
                finally
                    close(repo)
                end
            end
        end
    finally
        API.AUTO_PRECOMPILE_ENABLED[] = old_auto
    end
end

# Pkg.jl api.jl "Pkg.precompile" (no-op detection) + "waiting for trailing
# tasks" — precompiling twice is a no-op the second time; precompile-time
# stderr from a package (trailing IO) is surfaced; and a package that errors
# during precompilation soft-errors under the default but throws under strict.
@testset "precompile behaviors" begin
    mktempdir() do dir
        with_api_env(dir) do proj, depot
            depots = depot_stack([depot])
            n = Ref(0)
            function devgen(name, body)
                n[] += 1
                p = joinpath(dir, name)
                mkpath(joinpath(p, "src"))
                write(joinpath(p, "Project.toml"), "name = \"$name\"\nuuid = \"aaaaaaaa-0000-0000-0000-00000000000$(n[])\"\nversion = \"0.1.0\"\n")
                write(joinpath(p, "src", "$name.jl"), body)
                env = load_environment(proj; depots)
                write_environment(env, Planning.plan_develop(env, RegistryInstance[], Config(depots), p))
                return p
            end

            # no-op detection: first precompile compiles, second does nothing
            devgen("OkPkg", "module OkPkg end\n")
            io = IOBuffer()
            VibePkg.precompile(; io)
            @test occursin("Precompiling", String(take!(io)))
            io = IOBuffer()
            VibePkg.precompile(; io)
            @test !occursin("Precompiling", String(take!(io)))     # already precompiled

            # trailing IO: a package that writes to stderr during precompilation
            # has that output surfaced in the precompile log
            devgen("TrailPkg", "module TrailPkg\nprintln(stderr, \"waiting for IO to finish\")\nsleep(1)\nend\n")
            io = IOBuffer()
            VibePkg.precompile(; io)
            s = String(take!(io))
            @test occursin("Precompiling", s)
            @test occursin("waiting for IO to finish", s)

            # broken dep: an explicitly requested package that errors during
            # precompilation makes precompile raise, and the error names the
            # offending package. (Requested explicitly because on Julia 1.13+
            # Base.Precompilation only throws for requested packages or under
            # `strict`; a bare `precompile()` soft-errors.)
            devgen("BrokenDep", "module BrokenDep\nerror(\"boom\")\nend\n")
            err = try
                VibePkg.precompile(["BrokenDep"]; io = devnull)
                nothing
            catch e
                e
            end
            @test err !== nothing
            @test occursin("BrokenDep", sprint(showerror, err))
        end
    end
end

# Pkg.jl api.jl's circular-precompile regression: Base.Precompilation must
# diagnose a cycle instead of trying to schedule it (and potentially
# deadlocking).  Keep the graph entirely local; the manifest is all Base needs
# to discover the cycle, so this test never resolves or contacts a registry.
@testset "precompile diagnoses circular dependencies" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        packages = mkpath(joinpath(dir, "packages"))
        names = ["CircularDep1", "CircularDep2", "CircularDep3"]
        uuids = [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            "33333333-3333-3333-3333-333333333333",
        ]

        for (i, name) in pairs(names)
            next = mod1(i + 1, length(names))
            pkg = mkpath(joinpath(packages, name))
            mkpath(joinpath(pkg, "src"))
            write(
                joinpath(pkg, "Project.toml"),
                "name = \"$name\"\nuuid = \"$(uuids[i])\"\nversion = \"0.1.0\"\n\n" *
                    "[deps]\n$(names[next]) = \"$(uuids[next])\"\n",
            )
            write(joinpath(pkg, "src", "$name.jl"), "module $name\nend\n")
        end

        write(
            joinpath(envdir, "Project.toml"),
            "[deps]\n" * join(
                ("$(names[i]) = \"$(uuids[i])\"" for i in eachindex(names)), "\n"
            ) * "\n",
        )
        entries = String[]
        for (i, name) in pairs(names)
            next = mod1(i + 1, length(names))
            push!(
                entries, """
                [[deps.$name]]
                deps = ["$(names[next])"]
                path = "../packages/$name"
                uuid = "$(uuids[i])"
                version = "0.1.0"
                """
            )
        end
        write(
            joinpath(envdir, "Manifest.toml"),
            "julia_version = \"$VERSION\"\nmanifest_format = \"2.0\"\n\n" *
                join(entries, "\n"),
        )

        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        try
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            copy!(Base.DEPOT_PATH, [depot])
            precompile_output = IOBuffer()
            log_output = IOBuffer()
            withenv("JULIA_PKG_OFFLINE" => "true") do
                # Julia 1.12 emits the diagnostic with @warn; newer Base
                # versions may write it to `io`. Capture both public channels.
                with_logger(SimpleLogger(log_output, Logging.Warn)) do
                    VibePkg.precompile(; io = precompile_output)
                end
            end
            output = String(take!(precompile_output)) * String(take!(log_output))
            @test occursin("Circular dependency detected", output)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
        end
    end
end

@testset "@pkg_str and exports" begin
    REPLMode.TEST_MODE[] = true
    try
        calls = pkg"status --manifest"
        @test length(calls) == 1
        api, args, opts = calls[1]
        @test api === API.status
        @test (:mode => :manifest) in opts
    finally
        REPLMode.TEST_MODE[] = false
    end

    # Pkg's exported option-value names all resolve
    for name in (
            :PackageMode, :PKGMODE_MANIFEST, :PKGMODE_PROJECT,
            :UpgradeLevel, :UPLEVEL_MAJOR, :UPLEVEL_MINOR, :UPLEVEL_PATCH,
            :PreserveLevel, :PRESERVE_TIERED_INSTALLED, :PRESERVE_TIERED,
            :PRESERVE_ALL_INSTALLED, :PRESERVE_ALL, :PRESERVE_DIRECT,
            :PRESERVE_SEMVER, :PRESERVE_NONE,
            :Registry, :Apps, Symbol("@pkg_str"),
        )
        @test name in names(VibePkg)
    end
    # Pkg's `public` verbs are public here too
    for name in (:gc, :precompile, :readonly, :redo, :undo)
        @test Base.ispublic(VibePkg, name)
    end
end

# src/VibePkg.jl keeps three parallel lists (alias consts, `export`s, `public`
# declarations); these structural invariants catch drift between them without
# maintaining a fourth list here.
@testset "alias/export/public list consistency" begin
    # every exported or `public` name resolves to a real binding
    for n in names(VibePkg)          # includes `public` names
        @test isdefined(VibePkg, n)
    end
    # every alias const re-exposing an API/Git function or type is part of
    # the public surface (exported or marked `public`)
    checked = 0
    for source in (VibePkg.API, VibePkg.Git)
        for n in names(VibePkg; all = true)
            startswith(String(n), "#") && continue
            (isdefined(VibePkg, n) && isdefined(source, n)) || continue
            val = getglobal(VibePkg, n)
            val isa Module && continue
            val === getglobal(source, n) || continue
            checked += 1
            @test Base.ispublic(VibePkg, n)
        end
    end
    @test checked >= 27              # the alias block (aliases can share targets)
end

# status_compat_info must not mix metadata across registries: only registries
# that actually ship `max_version` may vote on its julia compatibility (compat
# queries work on compressed ranges, so a registry lacking the version would
# otherwise answer `nothing`, i.e. "compatible", for it)
@testset "status_compat_info julia compat across registries" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        function write_reg(name, reg_uuid, versions_toml, compat_toml)
            reg = joinpath(depot, "registries", name)
            pkg = joinpath(reg, "E", "Example")
            mkpath(pkg)
            write(
                joinpath(reg, "Registry.toml"), """
                name = "$name"
                uuid = "$reg_uuid"
                repo = "https://example.com/$name.git"

                [packages]
                7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
                """
            )
            write(
                joinpath(pkg, "Package.toml"), """
                name = "Example"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                repo = "https://example.com/Example.jl.git"
                """
            )
            write(joinpath(pkg, "Versions.toml"), versions_toml)
            write(joinpath(pkg, "Compat.toml"), compat_toml)
            return
        end
        # RegA ships 0.5.0 and 0.9.0; 0.9.0 needs a future julia
        write_reg(
            "RegA", "aaaaaaaa-aafe-5451-b93e-139f81909106",
            """
            ["0.5.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"

            ["0.9.0"]
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            """,
            """
            ["0.5"]
            julia = "1"

            ["0.9"]
            julia = "2"
            """
        )
        # RegB ships only 0.5.0: it must get no vote on 0.9.0's julia compat
        write_reg(
            "RegB", "bbbbbbbb-aafe-5451-b93e-139f81909106",
            """
            ["0.5.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            """,
            """
            ["0.5"]
            julia = "1"
            """
        )
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        @test length(regs) == 2
        proj = mkpath(joinpath(dir, "proj"))
        env = load_environment(proj; depots)
        planned = Planning.plan_add(env, regs, Config(depots), [PackageRequest("Example")])
        write_environment(env, planned)
        env = load_environment(proj; depots)
        entry = env.manifest[EXAMPLE_UUID]
        @test entry_version(entry) == v"0.5.0"    # 0.9.0 excluded by julia compat
        cinfo = VibePkg.Display.status_compat_info(env, EXAMPLE_UUID, entry, regs)
        @test cinfo !== nothing
        holding, maxv, _ = cinfo
        @test maxv == v"0.9.0"
        @test "julia" in holding                  # RegB must not vouch for 0.9.0
    end
end

if :version in fieldnames(Base.PkgOrigin)
    @testset "sysimage functionality" begin
        old_sysimage_modules = copy(Base._sysimage_modules)
        old_pkgorigins = copy(Base.pkgorigins)
        old_respect = API.RESPECT_SYSIMAGE_VERSIONS[]
        pkgid = Base.PkgId(EXAMPLE_UUID, "Example")
        try
            # Base.in_sysimage consults these mutable tables, so this exercises
            # the real public-operation branches without building a custom
            # sysimage. The local package server supplies every registry/tree
            # involved below.
            pkgid in Base._sysimage_modules || push!(Base._sysimage_modules, pkgid)
            Base.pkgorigins[pkgid] = Base.PkgOrigin(nothing, nothing, v"0.5.1")

            LocalPkgServer.ensure!()
            mktempdir() do dir
                depot = mkpath(joinpath(dir, "depot"))
                project = mkpath(joinpath(dir, "project"))
                old_active = Base.ACTIVE_PROJECT[]
                old_depot_path = copy(Base.DEPOT_PATH)
                old_gate = API.UPDATED_REGISTRY_THIS_SESSION[]
                try
                    Base.ACTIVE_PROJECT[] = joinpath(project, "Project.toml")
                    copy!(Base.DEPOT_PATH, [depot])
                    # Bootstrap General from the local server, then avoid an
                    # unnecessary second registry refresh in each operation.
                    API.UPDATED_REGISTRY_THIS_SESSION[] = true

                    VibePkg.respect_sysimage_versions()
                    @test API.RESPECT_SYSIMAGE_VERSIONS[]
                    VibePkg.add("Example"; io = devnull)
                    env = load_environment(; depots = depot_stack([depot]))
                    @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"

                    output = sprint(io -> VibePkg.status(; outdated = true, io))
                    @test occursin("Example v0.5.1", output)
                    @test occursin("[sysimage]", output)

                    @test_throws PkgError VibePkg.add(
                        ; name = "Example", rev = "master", io = devnull,
                    )
                    @test_throws PkgError VibePkg.develop("Example"; io = devnull)

                    # Disabling the guard restores ordinary resolution and
                    # permits both repository tracking operations.
                    VibePkg.respect_sysimage_versions(false)
                    @test !API.RESPECT_SYSIMAGE_VERSIONS[]
                    VibePkg.add("Example"; io = devnull)
                    env = load_environment(; depots = depot_stack([depot]))
                    @test entry_version(env.manifest[EXAMPLE_UUID]) != v"0.5.1"

                    VibePkg.add(; name = "Example", rev = "master", io = devnull)
                    env = load_environment(; depots = depot_stack([depot]))
                    @test VibePkg.EnvFiles.is_repo_tracked(env.manifest[EXAMPLE_UUID])

                    VibePkg.develop("Example"; io = devnull)
                    env = load_environment(; depots = depot_stack([depot]))
                    @test VibePkg.EnvFiles.is_path_tracked(env.manifest[EXAMPLE_UUID])
                finally
                    Base.ACTIVE_PROJECT[] = old_active
                    copy!(Base.DEPOT_PATH, old_depot_path)
                    API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
                end
            end
        finally
            copy!(Base._sysimage_modules, old_sysimage_modules)
            copy!(Base.pkgorigins, old_pkgorigins)
            VibePkg.respect_sysimage_versions(old_respect)
        end
    end
end
