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
            @test occursin("Cannot modify a readonly environment", err.msg)

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
            VibePkg.precompile("PrecompPkg"; io = devnull)                     # positional form
            VibePkg.precompile(PackageSpec(name = "PrecompPkg"); io = devnull) # spec form
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
