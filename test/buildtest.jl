# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
using VibePkg.Depots: depot_stack
using VibePkg.Configs: Config
using VibePkg.Registries: RegistryInstance, reachable_registries
using VibePkg.Environments
using VibePkg.Planning: plan_develop, plan_resolve
using VibePkg.Execution
using VibePkg.BuildOps
using VibePkg.TestOps
using VibePkg.EnvFiles: Project, Compat, with_project, read_manifest,
    entry_path, entry_version, entry_tree_hash
using VibePkg.Errors: PkgError

const BT_UUID = UUID("bbbbbbbb-1111-2222-3333-444444444444")
const FB_UUID = UUID("facadefa-1111-2222-3333-444444444444")
const SP_UUID = UUID("cccccccc-1111-2222-3333-444444444444")
const LG_UUID = UUID("eeeeeeee-1111-2222-3333-444444444444")
const QP_UUID = UUID("dddddddd-1111-2222-3333-444444444444")
const TP_UUID = UUID("ffffffff-1111-2222-3333-444444444444")
const RP_UUID = UUID("abababab-1111-2222-3333-444444444444")
const DP_UUID = UUID("cdcdcdcd-1111-2222-3333-444444444444")
const LD_UUID = UUID("babababa-1111-2222-3333-444444444444")
const PR_UUID = UUID("dededede-1111-2222-3333-444444444444")
const EX_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")   # Example

# a fresh single-depot environment with `pkg` dev'd into it
function dev_fixture(dir, pkg)
    depot = mkpath(joinpath(dir, "depot"))
    depots = depot_stack([depot])
    envdir = mkpath(joinpath(dir, "env"))
    env = load_environment(envdir; depots)
    planned = plan_develop(env, RegistryInstance[], Config(depots), pkg)
    write_environment(env, planned)
    return load_environment(envdir; depots), depots
end

@testset "build and test ops" begin
    mktempdir() do dir
        # a dev'd package with a build script and a test suite
        pkg = joinpath(dir, "BTPkg")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "deps"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "BTPkg"
            uuid = "$BT_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "BTPkg.jl"), "module BTPkg\nanswer() = 42\nend\n")
        write(
            joinpath(pkg, "deps", "build.jl"), """
            write(joinpath(@__DIR__, "built.txt"), "ok")
            """
        )
        write(
            joinpath(pkg, "test", "Project.toml"), """
            [deps]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            """
        )
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using BTPkg, Test
            @test BTPkg.answer() == 42
            @test !isempty(ARGS) ? ARGS[1] == "extra" : true
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        planned = plan_develop(env, RegistryInstance[], Config(depots), pkg)
        write_environment(env, planned)
        env = load_environment(envdir; depots)

        # build: runs deps/build.jl, logs to deps/build.log for dev'd pkgs
        BuildOps.build!(env, depots, [BT_UUID]; io = devnull)
        @test isfile(joinpath(pkg, "deps", "built.txt"))
        @test isfile(joinpath(pkg, "deps", "build.log"))

        # test: sandbox resolve + subprocess run.
        # Pkg.jl new.jl "test: printing" — the run prints a "Testing" banner
        # and a "<pkg> tests passed" line on success.
        testio = IOBuffer()
        TestOps.test!(env, RegistryInstance[], Config(depots), BT_UUID; test_args = ["extra"], io = testio)
        testout = String(take!(testio))
        @test occursin("Running tests...", testout)
        @test occursin("BTPkg tests passed", testout)

        # a failing test returns (name, process); the report helper raises
        # the pinned message (bare for exit code 1, annotated otherwise)
        write(joinpath(pkg, "test", "runtests.jl"), "error(\"boom\")\n")
        failed = TestOps.test!(env, RegistryInstance[], Config(depots), BT_UUID; io = devnull)
        @test failed !== nothing
        err = try
            TestOps.report_test_failures([failed])
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test err.msg == "Package BTPkg errored during testing"
        write(joinpath(pkg, "test", "runtests.jl"), "exit(2)\n")
        failed2 = TestOps.test!(env, RegistryInstance[], Config(depots), BT_UUID; io = devnull)
        err = try
            TestOps.report_test_failures([failed, failed2])
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test err.msg == "Packages errored during testing:\n• BTPkg\n• BTPkg (exit code: 2)"
    end
end

# preferences flatten into the sandboxes exactly as Pkg's Base.get_preferences
# capture: test-level prefs win over the parent environment's, the parent's
# JuliaLocalPreferences.toml is recognized (and masks LocalPreferences.toml),
# and the build sandbox is anchored at the package's own project instead
@testset "sandbox preferences (Pkg parity)" begin
    mktempdir() do dir
        pkg = joinpath(dir, "PrefPkg")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "deps"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "PrefPkg"
            uuid = "$PR_UUID"
            version = "0.1.0"

            [preferences.PrefPkg]
            from_pkg_project = "yes"
            """
        )
        write(joinpath(pkg, "src", "PrefPkg.jl"), "module PrefPkg\nend\n")
        # the build sandbox has no deps/Project.toml, so its preference
        # cascade is anchored at the package's own project
        write(
            joinpath(pkg, "deps", "build.jl"), """
            prefs = get(Base.get_preferences(), "PrefPkg", Dict{String, Any}())
            get(prefs, "from_pkg_project", "") == "yes" || error("package [preferences] missing in the build sandbox")
            get(prefs, "from_parent_local", "") == "yes" || error("parent preferences missing in the build sandbox")
            write(joinpath(@__DIR__, "prefs_ok.txt"), "ok")
            """
        )
        write(
            joinpath(pkg, "test", "Project.toml"), """
            [preferences.PrefPkg]
            from_test_project = "yes"
            vs_parent = "test"
            vs_test_local = "test-project"
            """
        )
        write(
            joinpath(pkg, "test", "LocalPreferences.toml"), """
            [PrefPkg]
            from_test_local = "yes"
            vs_test_local = "test-local"
            """
        )
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            prefs = get(Base.get_preferences(), "PrefPkg", Dict{String, Any}())
            get(prefs, "from_test_project", "") == "yes" || error("test/Project.toml [preferences] missing")
            get(prefs, "from_test_local", "") == "yes" || error("test/LocalPreferences.toml missing")
            get(prefs, "vs_test_local", "") == "test-local" || error("test/LocalPreferences.toml should win over the test project table")
            get(prefs, "from_parent_project", "") == "yes" || error("parent project [preferences] missing")
            get(prefs, "from_parent_local", "") == "yes" || error("parent JuliaLocalPreferences.toml missing")
            get(prefs, "vs_parent_local", "") == "local" || error("parent JuliaLocalPreferences.toml should win over the parent project table")
            get(prefs, "vs_parent", "") == "test" || error("test preferences should win over the parent environment's")
            haskey(prefs, "only_in_plain_local") && error("LocalPreferences.toml should be masked by JuliaLocalPreferences.toml")
            haskey(prefs, "from_pkg_project") && error("the package's own [preferences] are not part of the test cascade")
            """
        )

        env, depots = dev_fixture(dir, pkg)
        envdir = joinpath(dir, "env")
        open(joinpath(envdir, "Project.toml"), "a") do io
            write(
                io, """

                [preferences.PrefPkg]
                from_parent_project = "yes"
                vs_parent = "parent"
                vs_parent_local = "project"
                """
            )
        end
        write(
            joinpath(envdir, "JuliaLocalPreferences.toml"), """
            [PrefPkg]
            from_parent_local = "yes"
            vs_parent_local = "local"
            """
        )
        # ignored while JuliaLocalPreferences.toml exists next to it
        write(
            joinpath(envdir, "LocalPreferences.toml"), """
            [PrefPkg]
            only_in_plain_local = "yes"
            """
        )
        env = load_environment(envdir; depots)

        @test TestOps.test!(env, RegistryInstance[], Config(depots), PR_UUID; io = devnull) === nothing
        BuildOps.build!(env, depots, [PR_UUID]; io = devnull)
        @test isfile(joinpath(pkg, "deps", "prefs_ok.txt"))
    end
end

# a throwing deps/build.jl: the build op raises a PkgError naming the
# package and surfacing the tail of the build log
@testset "build: failure surfaces the log tail" begin
    mktempdir() do dir
        pkg = joinpath(dir, "FailBuild")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "deps"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "FailBuild"
            uuid = "$FB_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "FailBuild.jl"), "module FailBuild\nend\n")
        write(
            joinpath(pkg, "deps", "build.jl"), """
            println("about to explode")
            error("kaboom-build-marker")
            """
        )

        env, depots = dev_fixture(dir, pkg)
        err = try
            BuildOps.build!(env, depots, [FB_UUID]; io = devnull)
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("Error building `FailBuild`", err.msg)
        @test occursin("kaboom-build-marker", err.msg)      # the log tail
        # the full log is on disk (deps/build.log for a dev'd package)
        @test isfile(joinpath(pkg, "deps", "build.log"))
        @test occursin("kaboom-build-marker", read(joinpath(pkg, "deps", "build.log"), String))
    end
end

# the `[sources]` alternative to workspaces: test/Project.toml declares the
# parent package via a path source and gets its OWN test/Manifest.toml,
# resolved independently of the package's own manifest; running the tests
# honors that environment. Path deps also propagate into the sandbox:
#   Pkg.jl#361 — the tested package's own [sources] path dep (QPkg) resolves
#                to its dev path inside the sandbox
#   Pkg.jl#567 — a test dep declared by path (TPkg) whose own [sources]
#                declare a further path dep (RPkg) loads during the run
@testset "test: sources-based test/Project.toml" begin
    mktempdir() do dir
        # QPkg: a [sources] path dep of the tested package itself
        qpkg = joinpath(dir, "QPkg")
        mkpath(joinpath(qpkg, "src"))
        write(
            joinpath(qpkg, "Project.toml"), """
            name = "QPkg"
            uuid = "$QP_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(qpkg, "src", "QPkg.jl"), "module QPkg\nqval() = 7\nend\n")
        # RPkg: a [sources] path dep of the test-only dep TPkg
        rpkg = joinpath(dir, "RPkg")
        mkpath(joinpath(rpkg, "src"))
        write(
            joinpath(rpkg, "Project.toml"), """
            name = "RPkg"
            uuid = "$RP_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(rpkg, "src", "RPkg.jl"), "module RPkg\nrval() = 10\nend\n")
        # TPkg: a test-only dep declared by path, itself depending on RPkg by path
        tpkg = joinpath(dir, "TPkg")
        mkpath(joinpath(tpkg, "src"))
        write(
            joinpath(tpkg, "Project.toml"), """
            name = "TPkg"
            uuid = "$TP_UUID"
            version = "0.1.0"

            [deps]
            RPkg = "$RP_UUID"

            [sources]
            RPkg = {path = "../RPkg"}
            """
        )
        write(joinpath(tpkg, "src", "TPkg.jl"), "module TPkg\nusing RPkg\ntval() = RPkg.rval() + 1\nend\n")

        pkg = joinpath(dir, "SrcPkg")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "SrcPkg"
            uuid = "$SP_UUID"
            version = "0.1.0"

            [deps]
            QPkg = "$QP_UUID"

            [sources]
            QPkg = {path = "../QPkg"}
            """
        )
        write(joinpath(pkg, "src", "SrcPkg.jl"), "module SrcPkg\nusing QPkg\nanswer() = 43\nend\n")
        write(
            joinpath(pkg, "test", "Project.toml"), """
            [deps]
            SrcPkg = "$SP_UUID"
            TPkg = "$TP_UUID"

            [sources]
            SrcPkg = {path = ".."}
            TPkg = {path = "../../TPkg"}
            """
        )
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using SrcPkg
            SrcPkg.answer() == 43 || error("bad answer")
            using TPkg
            TPkg.tval() == 11 || error("bad tval")
            qpath = Base.locate_package(Base.PkgId(Base.UUID("$QP_UUID"), "QPkg"))
            qpath !== nothing || error("QPkg does not resolve in the sandbox")
            realpath(qpath) == realpath($(repr(joinpath(qpkg, "src", "QPkg.jl")))) ||
                error("QPkg resolved away from its dev path: " * qpath)
            """
        )

        env, depots = dev_fixture(dir, pkg)

        # resolving the test project as an environment of its own creates a
        # separate test/Manifest.toml with the parent tracked from the path
        tenv = load_environment(joinpath(pkg, "test"); depots)
        planned = plan_resolve(tenv, RegistryInstance[], Config(depots))
        Execution.apply!(tenv, planned, RegistryInstance[], Config(depots); io = devnull)
        test_manifest_file = joinpath(pkg, "test", "Manifest.toml")
        @test isfile(test_manifest_file)
        @test !isfile(joinpath(pkg, "Manifest.toml"))      # the package's own manifest is untouched
        tentry = read_manifest(test_manifest_file)[SP_UUID]
        @test entry_path(tentry) == ".."
        @test entry_version(tentry) == v"0.1.0"

        # tests run against the sources-based environment and pass; the
        # sandbox merge warns that the parent slice wins over the relative
        # path entry in test/Manifest.toml (documented parent-wins merge)
        failed = @test_logs (:warn, r"overrides the one in test/Manifest\.toml") match_mode = :any begin
            TestOps.test!(env, RegistryInstance[], Config(depots), SP_UUID; io = devnull)
        end
        @test failed === nothing
    end
end

# legacy [extras] + [targets]: with no test/Project.toml the sandbox
# project is generated from the `test` target — targeted extras become
# sandbox deps, untargeted ones do not
@testset "test: legacy [extras]/[targets] sandbox deps" begin
    mktempdir() do dir
        regular_dep = joinpath(dir, "LegacyDep")
        mkpath(joinpath(regular_dep, "src"))
        write(
            joinpath(regular_dep, "Project.toml"), """
            name = "LegacyDep"
            uuid = "$LD_UUID"
            version = "0.2.0"
            """
        )
        write(joinpath(regular_dep, "src", "LegacyDep.jl"), "module LegacyDep\nanswer() = 45\nend\n")

        pkg = joinpath(dir, "LegacyT")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "LegacyT"
            uuid = "$LG_UUID"
            version = "0.1.0"

            [deps]
            LegacyDep = "$LD_UUID"

            [sources]
            LegacyDep = {path = "../LegacyDep"}

            [compat]
            LegacyDep = "0.2"

            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
            UUIDs = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"

            [targets]
            test = ["Test", "TOML"]

            [preferences.LegacyT]
            from_pkg_project = "yes"
            vs_pkg_local = "project"
            """
        )
        # with no test/Project.toml the preference cascade is anchored at
        # the package's own project (Pkg parity)
        write(
            joinpath(pkg, "LocalPreferences.toml"), """
            [LegacyT]
            from_pkg_local = "yes"
            vs_pkg_local = "local"
            """
        )
        write(joinpath(pkg, "src", "LegacyT.jl"), "module LegacyT\nanswer() = 44\nend\n")
        # the runtests assert on the sandbox project itself: the targeted
        # extra is a dep, the untargeted one is not
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            import TOML
            deps = TOML.parsefile(Base.active_project())["deps"]
            haskey(ENV, "JULIA_PROJECT") && error("JULIA_PROJECT leaked into test subprocess")
            Base.LOAD_PATH[1] == "@" || error("active project is not first on LOAD_PATH")
            length(Base.LOAD_PATH) == 2 || error("unexpected LOAD_PATH entries: \$(Base.LOAD_PATH)")
            startswith(Base.active_project(), Base.LOAD_PATH[2]) || error("sandbox is not on LOAD_PATH")
            haskey(deps, "Test") || error("Test missing from sandbox project deps")
            haskey(deps, "TOML") || error("TOML missing from sandbox project deps")
            haskey(deps, "LegacyDep") || error("regular dependency missing from sandbox project deps")
            haskey(deps, "UUIDs") && error("UUIDs (untargeted extra) leaked into sandbox deps")
            Base.identify_package("UUIDs") === nothing || error("undeclared stdlib is loadable")
            haskey(deps, "LegacyT") || error("tested package missing from sandbox project deps")
            using Test, LegacyDep, LegacyT
            @test LegacyT.answer() == 44
            @test LegacyDep.answer() == 45
            prefs = get(Base.get_preferences(), "LegacyT", Dict{String, Any}())
            get(prefs, "from_pkg_project", "") == "yes" || error("package [preferences] missing from the legacy sandbox")
            get(prefs, "from_pkg_local", "") == "yes" || error("package LocalPreferences.toml missing from the legacy sandbox")
            get(prefs, "vs_pkg_local", "") == "local" || error("package LocalPreferences.toml should win over its project table")
            """
        )

        env, depots = dev_fixture(dir, pkg)
        sandbox = TestOps.sandbox_project(pkg, "LegacyT", LG_UUID, env.project)
        @test sandbox.deps["LegacyDep"] == LD_UUID
        @test haskey(sandbox.deps, "TOML")
        @test sandbox.compat["LegacyDep"] == Compat("0.2")
        @test sandbox.sources["LegacyDep"].path == regular_dep
        @test !haskey(sandbox.deps, "UUIDs")
        @test TestOps.test!(env, RegistryInstance[], Config(depots), LG_UUID; io = devnull) === nothing
    end
end

# a single-package fixture registry (the make_test_registry pattern) where
# Example 0.5.1's julia compat excludes the running julia
function make_flc_registry(depot)
    reg = joinpath(depot, "registries", "FLCRegistry")
    pkg = joinpath(reg, "E", "Example")
    mkpath(pkg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "FLCRegistry"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "https://example.com/FLCRegistry.git"

        [packages]
        $EX_UUID = { name = "Example", path = "E/Example" }
        """
    )
    write(
        joinpath(pkg, "Package.toml"), """
        name = "Example"
        uuid = "$EX_UUID"
        repo = "https://example.com/Example.jl.git"
        """
    )
    write(
        joinpath(pkg, "Versions.toml"), """
        ["0.5.0"]
        git-tree-sha1 = "$("1"^40)"

        ["0.5.1"]
        git-tree-sha1 = "$("2"^40)"
        """
    )
    write(
        joinpath(pkg, "Compat.toml"), """
        ["0.5.0"]
        julia = "1"

        ["0.5.1"]
        julia = "2"
        """
    )
    return reg
end

@testset "test: force_latest_compat" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_flc_registry(depot)
        regs = reachable_registries(depot_stack([depot]))
        project = with_project(
            Project();
            deps = Dict("Example" => EX_UUID, "Unreg" => UUID("99999999-9999-9999-9999-999999999999")),
            compat = Dict("Example" => Compat("0.5")),
        )
        # Pkg.jl#4349 — 0.5.1 requires julia 2 and can never resolve, so the
        # forced compat must floor at 0.5.0, not 0.5.1
        forced = TestOps.force_latest_compat(
            project, BT_UUID, regs;
            allow_earlier_backwards_compatible_versions = false,
        )
        @test v"0.5.0" in forced.compat["Example"].val
        # Pkg.jl#3684 — an unregistered dep is skipped, not an error
        @test !haskey(forced.compat, "Unreg")
    end
end

# Pkg.jl#1423 — the test sandbox reuses the parent manifest's versions of
# shared deps (the manifest slice) instead of re-resolving them to latest
@testset "test: sandbox manifest keeps the parent's versions" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        devp = joinpath(dir, "DevP")
        mkpath(joinpath(devp, "src"))
        write(
            joinpath(devp, "Project.toml"), """
            name = "DevP"
            uuid = "$DP_UUID"
            version = "0.1.0"

            [deps]
            Example = "$EX_UUID"
            """
        )
        write(joinpath(devp, "src", "DevP.jl"), "module DevP\nend\n")
        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            DevP = "$DP_UUID"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Example]]
            git-tree-sha1 = "$("1"^40)"
            uuid = "$EX_UUID"
            version = "0.5.0"

            [[deps.DevP]]
            path = "../DevP"
            uuid = "$DP_UUID"
            version = "0.1.0"
            deps = ["Example"]
            """
        )
        env = load_environment(envdir; depots)
        sliced = Execution.sandbox_manifest(env, depots, DP_UUID)
        @test entry_version(sliced[EX_UUID]) == v"0.5.0"       # not re-resolved
        @test entry_tree_hash(sliced[EX_UUID]) == SHA1("1"^40)
        @test realpath(entry_path(sliced[DP_UUID])) == realpath(devp)
    end
end

# Pkg.jl#3691 — loading VibePkg must not change the active project (the
# precompile workload activates temp projects; nothing may leak into a
# plain `using`)
@testset "loading VibePkg leaves the active project alone" begin
    mktempdir() do dir
        proj = mkpath(joinpath(dir, "proj"))
        write(joinpath(proj, "Project.toml"), "")
        sep = Sys.iswindows() ? ';' : ':'
        cmd = addenv(
            `$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --compiled-modules=no --project=$proj -e 'using VibePkg; print(Base.active_project())'`,
            "JULIA_LOAD_PATH" => join(["@", pkgdir(TestOps), "@stdlib"], sep),
            "JULIA_DEPOT_PATH" => LocalPkgServer.worker_depot_path(),
            "JULIA_PROJECT" => nothing,
        )
        @test read(cmd, String) == joinpath(proj, "Project.toml")
    end
end

# Pkg.jl new.jl "test/threads" — the thread spec passed to the test subprocess
# honors JULIA_NUM_THREADS verbatim (including the "n,m" default,interactive
# form) and otherwise reflects the current process's thread pools.
@testset "test thread spec" begin
    tspec() = withenv(() -> TestOps.test_threads_spec(), "JULIA_NUM_THREADS" => nothing)
    # explicit values pass straight through
    for v in ("1", "2", "4", "2,0", "3,1", "auto")
        @test withenv(() -> TestOps.test_threads_spec(), "JULIA_NUM_THREADS" => v) == v
    end
    # unset: reflects the running thread pools; interactive pool → "n,m"
    s = tspec()
    if Threads.nthreads(:interactive) > 0
        @test s == "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"
    else
        @test s == "$(Threads.nthreads(:default))"
    end
end

# Pkg.jl pkg.jl "coverage specific path" — the test subprocess coverage flag
# accepts a bare bool (tracked at the package source, or off) or a string that
# is passed through verbatim as the --code-coverage argument (e.g. a tracefile).
@testset "test coverage flag" begin
    flag(cov) = begin
        m = match(r"--code-coverage=(\S+)", string(TestOps.test_subprocess_flags("/proj"; coverage = cov, julia_args = String[])))
        m === nothing ? nothing : m.captures[1]
    end
    @test flag(false) == "none"
    @test flag(true) == "@/proj"                    # tracked at the package source
    @test flag("/tmp/trace.info") == "/tmp/trace.info"   # explicit path passthrough
    @test flag("user") == "user"
end
