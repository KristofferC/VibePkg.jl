# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
import LibGit2
import VibePkg
using VibePkg.Depots: depot_stack, find_installed
using VibePkg.Configs: Config
using VibePkg.Registries: RegistryInstance, reachable_registries,
    add_default_registries!, registry_info
using VibePkg.Environments
using VibePkg.Planning: plan_add, plan_develop, plan_resolve
using VibePkg.Execution
using VibePkg.BuildOps
using VibePkg.TestOps
using VibePkg.EnvFiles: Project, Compat, with_project, read_manifest,
    entry_path, entry_version, entry_tree_hash, entry_repo_url,
    is_repo_tracked
using VibePkg.Errors: PkgError
using VibePkg.TreeHash: tree_hash
import TOML

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
const CL_UUID = UUID("acacacac-1111-2222-3333-444444444444")
const VB_UUID = UUID("bcbcbcbc-1111-2222-3333-444444444444")
const LW_UUID = UUID("aeaeaeae-1111-2222-3333-444444444444")
const NF_UUID = UUID("adadadad-1111-2222-3333-444444444444")
const TC_UUID = UUID("afafafaf-1111-2222-3333-444444444444")
const MT_UUID = UUID("cececece-1111-2222-3333-444444444444")
const RG_UUID = UUID("dfdfdfdf-1111-2222-3333-444444444444")
const AI_UUID = UUID("edededed-1111-2222-3333-444444444444")
const TH_UUID = UUID("edededed-2222-3333-4444-555555555555")
const REQUIRE_UUID = UUID("edededed-3333-4444-5555-666666666666")
const INSTALLED_BUILD_UUID = UUID("74736554-676b-5064-6c69-75426c696146")
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

# A one-package pkg server scoped to the installed-build-log test. Keeping it
# separate from LocalPkgServer's shared General fixture prevents the extra
# registered name from changing registry enumeration or completion tests.
function installed_build_server(dir)
    files = mkpath(joinpath(dir, "build-server", "files"))
    pkg = mkpath(joinpath(dir, "build-server", "package"))
    mkpath(joinpath(pkg, "src"))
    mkpath(joinpath(pkg, "deps"))
    write(
        joinpath(pkg, "Project.toml"), """
        name = "FailBuild"
        uuid = "$INSTALLED_BUILD_UUID"
        version = "0.1.0"
        """
    )
    write(joinpath(pkg, "src", "FailBuild.jl"), "module FailBuild\nend\n")
    write(
        joinpath(pkg, "deps", "build.jl"),
        "println(\"installed-build-log-marker\")\nerror(\"installed-build-failure\")\n",
    )
    package_hash = bytes2hex(tree_hash(pkg))
    LocalPkgServer.gzip_tarball(
        pkg, joinpath(files, "package", string(INSTALLED_BUILD_UUID), package_hash),
    )

    registry = mkpath(joinpath(dir, "build-server", "registry"))
    write(
        joinpath(registry, "Registry.toml"), """
        name = "General"
        uuid = "$(LocalPkgServer.GENERAL_UUID)"
        repo = "https://example.invalid/General"

        [packages]
        $INSTALLED_BUILD_UUID = { name = "FailBuild", path = "F/FailBuild" }
        """
    )
    reg_pkg = mkpath(joinpath(registry, "F", "FailBuild"))
    write(
        joinpath(reg_pkg, "Package.toml"), """
        name = "FailBuild"
        uuid = "$INSTALLED_BUILD_UUID"
        repo = "https://example.invalid/FailBuild.jl"
        """
    )
    write(
        joinpath(reg_pkg, "Versions.toml"), """
        ["0.1.0"]
        git-tree-sha1 = "$package_hash"
        """
    )
    registry_hash = bytes2hex(tree_hash(registry))
    LocalPkgServer.gzip_tarball(
        registry,
        joinpath(files, "registry", LocalPkgServer.GENERAL_UUID, registry_hash),
    )
    write(
        joinpath(files, "registries"),
        "/registry/$(LocalPkgServer.GENERAL_UUID)/$registry_hash\n",
    )
    return LocalPkgServer.start_server(files)
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
        # Pkg.jl new.jl "test: printing" — the run prints its testing banner,
        # both sandbox status views, and a success line.
        testio = IOBuffer()
        TestOps.test!(env, RegistryInstance[], Config(depots), BT_UUID; test_args = ["extra"], io = testio)
        testout = String(take!(testio))
        @test occursin(r"Testing BTPkg", testout)
        @test occursin(r"Status `.+Project\.toml`", testout)
        @test occursin(r"Status `.+Manifest\.toml`", testout)
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
        @test err.msg == "Package BTPkg failed during testing"
        write(joinpath(pkg, "test", "runtests.jl"), "exit(2)\n")
        failed2 = TestOps.test!(env, RegistryInstance[], Config(depots), BT_UUID; io = devnull)
        err = try
            TestOps.report_test_failures([failed, failed2])
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test err.msg == "The following packages failed during testing:\n• BTPkg\n• BTPkg (exit code: 2)"
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
        @test occursin("Error building FailBuild", err.msg)
        @test occursin("kaboom-build-marker", err.msg)      # the log tail
        # the full log is on disk (deps/build.log for a dev'd package)
        @test isfile(joinpath(pkg, "deps", "build.log"))
        @test occursin("kaboom-build-marker", read(joinpath(pkg, "deps", "build.log"), String))
    end
end

# Pkg.jl new.jl "Build log location" — content-addressed packages are
# immutable depot installs, so add-triggered build output belongs to Pkg's
# tree-hash-keyed scratchspace rather than the installed package's deps/ dir.
@testset "build: installed package log uses Pkg scratchspace" begin
    mktempdir() do dir
        server = installed_build_server(dir)
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        try
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            copy!(Base.DEPOT_PATH, [depot])
            err = withenv("JULIA_PKG_SERVER" => server.url) do
                try
                    VibePkg.add("FailBuild"; io = devnull)
                    nothing
                catch e
                    e
                end
            end
            @test err isa PkgError
            @test occursin("installed-build-log-marker", err.msg)

            depots = depot_stack([depot])
            env = load_environment(envdir; depots)
            entry = env.manifest[INSTALLED_BUILD_UUID]
            hash = entry_tree_hash(entry)
            source, installed = find_installed(
                depots, "FailBuild", INSTALLED_BUILD_UUID, hash,
            )
            @test installed
            @test !isfile(joinpath(source, "deps", "build.log"))

            scratch_root = joinpath(depot, "scratchspaces")
            log_file = joinpath(
                scratch_root, VibePkg.BuildOps.PKG_SCRATCH_UUID, string(hash), "build.log",
            )
            @test isfile(log_file)
            @test occursin("installed-build-log-marker", read(log_file, String))
            tag = joinpath(scratch_root, "CACHEDIR.TAG")
            @test isfile(tag)
            @test startswith(
                read(tag, String), "Signature: 8a477f597d28d172789f06886806bc55",
            )
            usage_file = joinpath(depot, "logs", "scratch_usage.toml")
            @test isfile(usage_file)
            usage = TOML.parsefile(usage_file)
            @test haskey(usage, dirname(log_file))
            @test only(usage[dirname(log_file)])["parent_projects"] == [env.project_file]
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depots)
            close(server.server)
        end
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
        failed = @test_logs (:warn, r"Parent environment version .* overrides test manifest version") match_mode = :any begin
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

# Pkg.jl new.jl "test sandboxing" — an explicit test/Project.toml's
# compatibility bounds constrain its test-only dependencies, and a test dep
# already tracking an unregistered repository in the active graph keeps that
# source in the temporary sandbox manifest. Both fixtures are hermetic: Example
# comes from LocalPkgServer and RepoTestDep from a local git repository.
@testset "test: modern test deps honor compat and preserve repo source" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        # An unregistered test dependency with a real git source.
        repo_dep = realpath(mkpath(joinpath(dir, "RepoTestDep")))
        mkpath(joinpath(repo_dep, "src"))
        write(
            joinpath(repo_dep, "Project.toml"), """
            name = "RepoTestDep"
            uuid = "$RG_UUID"
            version = "0.1.0"
            """
        )
        write(
            joinpath(repo_dep, "src", "RepoTestDep.jl"),
            "module RepoTestDep\nanswer() = 48\nend\n",
        )
        repo = LibGit2.init(repo_dep)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("fixture", "fixture@localhost")
        LibGit2.commit(repo, "initial"; author = sig, committer = sig)
        LibGit2.close(repo)

        pkg = joinpath(dir, "ModernTestDeps")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "ModernTestDeps"
            uuid = "$MT_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "ModernTestDeps.jl"), "module ModernTestDeps\nend\n")
        write(
            joinpath(pkg, "test", "Project.toml"), """
            [deps]
            Example = "$EX_UUID"
            RepoTestDep = "$RG_UUID"
            TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"

            [compat]
            Example = "=0.5.2"
            RepoTestDep = "0.1"
            """
        )
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using Example, RepoTestDep, TOML
            pkgversion(Example) == v"0.5.2" ||
                error("modern test compat was ignored: loaded Example \$(pkgversion(Example))")
            RepoTestDep.answer() == 48 || error("repo-tracked test dependency did not load")
            manifest = TOML.parsefile(joinpath(dirname(Base.active_project()), "Manifest.toml"))
            repo_entry = only(manifest["deps"]["RepoTestDep"])
            get(repo_entry, "repo-url", nothing) == $(repr(repo_dep)) ||
                error("repo source was lost in the sandbox manifest: \$repo_entry")
            """
        )

        env, depots = dev_fixture(dir, pkg)
        add_default_registries!(depots; io = devnull)
        regs = reachable_registries(depots)
        example_reg = only(filter(reg -> haskey(reg, EX_UUID), regs))
        @test maximum(keys(registry_info(example_reg, example_reg[EX_UUID]).version_info)) == v"0.5.5"

        # Put the unregistered test dep in the active graph as repo-tracked;
        # sandbox_preserve must carry this exact source into Pkg.test.
        repo_pkg = VibePkg.Git.materialize_repo_package!(depots, repo_dep; io = devnull)
        planned = plan_add(env, regs, Config(depots), [repo_pkg])
        write_environment(env, planned)
        env = load_environment(dirname(env.project_file); depots)
        repo_entry = env.manifest[RG_UUID]
        @test is_repo_tracked(repo_entry)
        @test entry_repo_url(repo_entry) == repo_dep

        sandbox = TestOps.sandbox_project(pkg, "ModernTestDeps", MT_UUID, env.project)
        @test sandbox.compat["Example"] == Compat("=0.5.2")
        @test sandbox.compat["RepoTestDep"] == Compat("0.1")
        test_io = IOBuffer()
        subprocess_depots = join([joinpath(dir, "depot"); Base.DEPOT_PATH[2:end]], LocalPkgServer.DEPOT_SEP)
        result = withenv("JULIA_DEPOT_PATH" => subprocess_depots) do
            TestOps.test!(env, regs, Config(depots), MT_UUID; io = test_io)
        end
        result === nothing || error("ModernTestDeps test subprocess failed:\n" * String(take!(test_io)))
        @test result === nothing
    end
end

# Pkg.jl new.jl "test targets should also honor compat" — the legacy test
# target's compat is part of the synthesized sandbox project and constrains
# resolution of a registry-backed, test-only dependency.  The local package
# server offers Example through 0.5.5, so loading 0.5.2 proves the constraint
# was applied rather than merely accepting the resolver's latest version.
@testset "test: legacy target honors compat" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        pkg = joinpath(dir, "TargetCompat")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        selected = joinpath(pkg, "test", "selected-version.txt")
        write(
            joinpath(pkg, "Project.toml"), """
            name = "TargetCompat"
            uuid = "$TC_UUID"
            version = "0.1.0"

            [extras]
            Example = "$EX_UUID"

            [targets]
            test = ["Example"]

            [compat]
            Example = "=0.5.2"
            """
        )
        write(joinpath(pkg, "src", "TargetCompat.jl"), "module TargetCompat\nend\n")
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using Example
            selected = pkgversion(Example)
            write($(repr(selected)), string(selected))
            selected == v"0.5.2" || error("legacy test-target compat was ignored: loaded Example \$selected")
            """
        )

        env, depots = dev_fixture(dir, pkg)
        add_default_registries!(depots; io = devnull)
        regs = reachable_registries(depots)
        example_reg = only(filter(reg -> haskey(reg, EX_UUID), regs))
        @test maximum(keys(registry_info(example_reg, example_reg[EX_UUID]).version_info)) == v"0.5.5"
        sandbox = TestOps.sandbox_project(pkg, "TargetCompat", TC_UUID, env.project)
        @test sandbox.deps["Example"] == EX_UUID
        @test sandbox.compat["Example"] == Compat("=0.5.2")
        test_io = IOBuffer()
        # The subprocess must search the same operation depot into which
        # Execution.apply! installs the registry-backed test dependency.
        subprocess_depots = join([joinpath(dir, "depot"); Base.DEPOT_PATH[2:end]], LocalPkgServer.DEPOT_SEP)
        result = withenv("JULIA_DEPOT_PATH" => subprocess_depots) do
            TestOps.test!(env, regs, Config(depots), TC_UUID; io = test_io)
        end
        result === nothing || error("TargetCompat test subprocess failed:\n" * String(take!(test_io)))
        @test result === nothing
        @test read(selected, String) == "0.5.2"
    end
end

# Pkg.jl new.jl "test: fallback when no project file exists" — a package
# with neither test/Project.toml nor legacy [extras]/[targets] still gets a
# runnable sandbox containing the tested package and its regular dependencies.
@testset "test: fallback without test project or targets" begin
    mktempdir() do dir
        pkg = joinpath(dir, "NoTargets")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "NoTargets"
            uuid = "$NF_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "NoTargets.jl"), "module NoTargets\nanswer() = 47\nend\n")
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using NoTargets
            NoTargets.answer() == 47 || error("fallback sandbox did not load the tested package")
            """
        )

        env, depots = dev_fixture(dir, pkg)
        sandbox = TestOps.sandbox_project(pkg, "NoTargets", NF_UUID, env.project)
        @test sandbox.deps == Dict("NoTargets" => NF_UUID)
        @test isempty(sandbox.sources)
        @test TestOps.test!(env, RegistryInstance[], Config(depots), NF_UUID; io = devnull) === nothing
    end
end

# Pkg.jl new.jl "using a test/REQUIRE file" — retain the deprecated Pkg2
# compatibility path for packages that still declare test dependencies by
# name. Version text is deliberately ignored, as in upstream Pkg; this local
# fixture covers registry and stdlib name resolution without network access.
@testset "test: deprecated test/REQUIRE dependencies" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        pkg = joinpath(dir, "LegacyRequire")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "src", "LegacyRequire.jl"), "module LegacyRequire\nend\n")
        write(
            joinpath(pkg, "test", "REQUIRE"), """
            # Pkg2 version bounds are ignored by the compatibility shim.
            @legacy-platform Example 99
            Test
            """
        )
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using Example, Test
            @test Example.domath(37) == 42
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"),
            "[deps]\nLegacyRequire = \"$REQUIRE_UUID\"\n",
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.LegacyRequire]]
            path = $(repr(pkg))
            uuid = "$REQUIRE_UUID"
            version = "0.0.0"
            """,
        )
        env = load_environment(envdir; depots)
        add_default_registries!(depots; io = devnull)
        regs = reachable_registries(depots)
        sandbox = TestOps.sandbox_project(
            pkg, "LegacyRequire", REQUIRE_UUID, env.project;
            registries = regs, package_deps = env.manifest[REQUIRE_UUID].deps,
        )
        @test sandbox.deps["Example"] == EX_UUID
        @test sandbox.deps["Test"] == UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")

        result = Ref{Any}()
        test_io = IOBuffer()
        subprocess_depots = join(
            [joinpath(dir, "depot"); Base.DEPOT_PATH[2:end]], LocalPkgServer.DEPOT_SEP,
        )
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            Base.ACTIVE_PROJECT[] = env.project_file
            copy!(Base.DEPOT_PATH, [depot; old_depots[2:end]])
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            @test_logs (:warn, r"using test/REQUIRE files is deprecated") match_mode = :any begin
                result[] = withenv("JULIA_DEPOT_PATH" => subprocess_depots) do
                    VibePkg.test("LegacyRequire"; io = test_io)
                end
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depots)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
        result[] === nothing || error(
            "LegacyRequire test subprocess failed:\n" * String(take!(test_io)),
        )
        @test result[] === nothing
    end
end

# Pkg.jl pkg.jl "test should instantiate" / #324 — testing an active package
# must materialize a registry-backed dependency recorded in its manifest even
# when the operation starts from a depot containing neither a registry nor the
# package source. The fixture is served entirely by LocalPkgServer.
@testset "test auto-instantiates a missing manifest source" begin
    server = LocalPkgServer.ensure!()
    mktempdir() do dir
        pkg = joinpath(dir, "AutoInstantiate")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "AutoInstantiate"
            uuid = "$AI_UUID"
            version = "0.1.0"

            [deps]
            Example = "$EX_UUID"

            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

            [targets]
            test = ["Test"]
            """
        )
        write(
            joinpath(pkg, "src", "AutoInstantiate.jl"),
            "module AutoInstantiate\nusing Example\nanswer() = Example.domath(37)\nend\n",
        )
        marker = joinpath(pkg, "test", "ran.txt")
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using AutoInstantiate, Example, Test
            @test AutoInstantiate.answer() == 42
            @test pkgversion(Example) == v"0.5.2"
            write($(repr(marker)), "ok")
            """
        )
        example_hash = server.version_hashes["0.5.2"]
        write(
            joinpath(pkg, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Example]]
            git-tree-sha1 = "$example_hash"
            uuid = "$EX_UUID"
            version = "0.5.2"
            """
        )

        depot = realpath(mkpath(joinpath(dir, "fresh-depot")))
        operation_depots = [depot; Base.DEPOT_PATH[2:end]]
        _, installed_before = find_installed(
            depot_stack([depot]), "Example", EX_UUID, SHA1(example_hash),
        )
        @test !installed_before
        @test !ispath(joinpath(depot, "registries"))

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        test_io = IOBuffer()
        try
            Base.ACTIVE_PROJECT[] = joinpath(pkg, "Project.toml")
            copy!(Base.DEPOT_PATH, operation_depots)
            withenv(
                "JULIA_DEPOT_PATH" => join(operation_depots, LocalPkgServer.DEPOT_SEP),
                "JULIA_PKG_SERVER" => server.url,
            ) do
                VibePkg.test(; io = test_io)
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depots)
        end

        output = String(take!(test_io))
        source, installed_after = find_installed(
            depot_stack([depot]), "Example", EX_UUID, SHA1(example_hash),
        )
        @test installed_after
        @test TOML.parsefile(joinpath(source, "Project.toml"))["version"] == "0.5.2"
        @test read(marker, String) == "ok"
        @test occursin("AutoInstantiate tests passed", output)
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

# Pkg.jl new.jl "test/threads" — exercise the complete boundary, not only the
# string helper above: both JULIA_NUM_THREADS and an explicit --threads flag
# must determine the default and interactive pools observed by runtests.jl.
@testset "test thread pools propagate to the subprocess" begin
    mktempdir() do dir
        pkg = joinpath(dir, "ThreadFixture")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        marker = joinpath(pkg, "test", "observed.txt")
        write(
            joinpath(pkg, "Project.toml"), """
            name = "ThreadFixture"
            uuid = "$TH_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "ThreadFixture.jl"), "module ThreadFixture\nend\n")
        write(
            joinpath(pkg, "test", "runtests.jl"), """
            using ThreadFixture
            observed = (Threads.nthreads(:default), Threads.nthreads(:interactive))
            expected = (
                parse(Int, ENV["EXPECTED_NUM_THREADS_DEFAULT"]),
                parse(Int, ENV["EXPECTED_NUM_THREADS_INTERACTIVE"]),
            )
            observed == expected || error("thread pools: observed=\$observed expected=\$expected")
            write($(repr(marker)), join(observed, ','))
            """
        )
        env, depots = dev_fixture(dir, pkg)
        config = Config(depots)

        function run_threads(expected::Tuple{Int, Int}; env_threads = nothing, julia_args = String[])
            Base.rm(marker; force = true)
            result = withenv(
                "JULIA_NUM_THREADS" => env_threads,
                "EXPECTED_NUM_THREADS_DEFAULT" => string(expected[1]),
                "EXPECTED_NUM_THREADS_INTERACTIVE" => string(expected[2]),
            ) do
                TestOps.test!(
                    env, RegistryInstance[], config, TH_UUID;
                    julia_args, autoprecompile = false, io = devnull,
                )
            end
            @test result === nothing
            @test read(marker, String) == join(expected, ',')
        end

        for (spec, expected) in (
                ("1", (1, 0)),
                ("2", (2, 1)),
                ("2,0", (2, 0)),
            )
            run_threads(expected; env_threads = spec)
        end
        for (spec, expected) in (
                ("1", (1, 0)),
                ("2", (2, 1)),
                ("2,0", (2, 0)),
            )
            run_threads(expected; julia_args = ["--threads=$spec"])
        end
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

# the --depwarn flag passed to the test subprocess mirrors all three parent
# states (0=no, 1=yes, 2=error): a parent started with --depwarn=no must not
# upgrade its test subprocesses to --depwarn=yes
@testset "test flags mirror the parent depwarn state" begin
    # in-process: the emitted flag maps whatever this process runs with
    flags = string(TestOps.test_subprocess_flags("/proj"; coverage = false, julia_args = String[]))
    @test occursin("--depwarn=$(("no", "yes", "error")[Base.JLOptions().depwarn + 1])", flags)
    # subprocess: pin each parent state and read the emitted flag back
    sep = Sys.iswindows() ? ';' : ':'
    probe = """
    using VibePkg
    flags = string(VibePkg.TestOps.test_subprocess_flags("/proj"; coverage = false, julia_args = String[]))
    print(match(r"--depwarn=(\\w+)", flags).captures[1])
    """
    for state in ("no", "yes", "error")
        cmd = addenv(
            `$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --depwarn=$state -e $probe`,
            "JULIA_LOAD_PATH" => join(["@", pkgdir(TestOps), "@stdlib"], sep),
            "JULIA_DEPOT_PATH" => LocalPkgServer.worker_depot_path(),
            "JULIA_PROJECT" => nothing,
        )
        @test read(cmd, String) == state
    end
end

# the test/build sandboxes are scoped to the run (mktempdir-do): they are
# removed as soon as the subprocess finishes — on success and failure alike —
# not left behind for process-exit cleanup
@testset "sandboxes are cleaned up deterministically" begin
    mktempdir() do dir
        pkg = joinpath(dir, "CleanPkg")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "deps"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "CleanPkg"
            uuid = "$CL_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "CleanPkg.jl"), "module CleanPkg\nend\n")
        # both subprocesses record their sandbox (the active project's dir)
        record = repr(joinpath(dir, "sandboxes.txt"))
        write(
            joinpath(pkg, "deps", "build.jl"),
            "open(io -> println(io, dirname(Base.active_project())), $record, \"a\")\n"
        )
        write(
            joinpath(pkg, "test", "runtests.jl"),
            "open(io -> println(io, dirname(Base.active_project())), $record, \"a\")\n" *
                "get(ENV, \"CLEANPKG_FAIL\", \"\") == \"1\" && exit(3)\n"
        )

        env, depots = dev_fixture(dir, pkg)
        BuildOps.build!(env, depots, [CL_UUID]; io = devnull)
        @test TestOps.test!(env, RegistryInstance[], Config(depots), CL_UUID; io = devnull) === nothing
        failed = withenv("CLEANPKG_FAIL" => "1") do
            TestOps.test!(env, RegistryInstance[], Config(depots), CL_UUID; io = devnull)
        end
        @test failed !== nothing
        sandboxes = readlines(joinpath(dir, "sandboxes.txt"))
        @test length(sandboxes) == 3           # build + passing test + failing test
        for sandbox in sandboxes
            @test !ispath(sandbox)
        end
    end
end

# verbose builds route the subprocess output through the op's io (never the
# process-global stdout/stderr) and skip the log file
@testset "build: verbose output routes through io" begin
    mktempdir() do dir
        pkg = joinpath(dir, "VerbosePkg")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "deps"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "VerbosePkg"
            uuid = "$VB_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "VerbosePkg.jl"), "module VerbosePkg\nend\n")
        write(joinpath(pkg, "deps", "build.jl"), "println(\"verbose-build-marker\")\n")

        env, depots = dev_fixture(dir, pkg)
        iob = IOBuffer()
        # an IOContext-wrapped io is unwrapped for the subprocess pipeline
        BuildOps.build!(env, depots, [VB_UUID]; verbose = true, io = IOContext(iob, :color => false))
        out = String(take!(iob))
        @test occursin("Building", out)                  # the banner
        @test occursin("verbose-build-marker", out)      # the subprocess output
        @test !isfile(joinpath(pkg, "deps", "build.log"))

        # a verbose failure still raises the pinned error, with the output
        # in the io stream rather than a log tail
        write(joinpath(pkg, "deps", "build.jl"), "error(\"verbose-kaboom-marker\")\n")
        err = try
            BuildOps.build!(env, depots, [VB_UUID]; verbose = true, io = iob)
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test err.msg == "Build failed for VerbosePkg"
        @test occursin("verbose-kaboom-marker", String(take!(iob)))
        @test !isfile(joinpath(pkg, "deps", "build.log"))
    end
end

# Pkg.jl#4700 — test-sandbox precompilation runs in this process, but the
# tests themselves run in a fresh subprocess. A stale package that is loaded
# here therefore must not produce Base's "different version is currently
# loaded" warning during Pkg.test precompilation.
@testset "test precompile suppresses loaded-package warning (#4700)" begin
    mktempdir() do dir
        pkg = joinpath(dir, "LoadedDuringTest")
        mkpath(joinpath(pkg, "src"))
        mkpath(joinpath(pkg, "test"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "LoadedDuringTest"
            uuid = "$LW_UUID"
            version = "0.1.0"
            """
        )
        source = joinpath(pkg, "src", "LoadedDuringTest.jl")
        write(source, "module LoadedDuringTest\nvalue() = 1\nend\n")
        write(
            joinpath(pkg, "test", "runtests.jl"),
            "using LoadedDuringTest\nLoadedDuringTest.value() == 3 || error(\"wrong source\")\n",
        )

        env, depots = dev_fixture(dir, pkg)
        old_project = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = env.project_file
        try
            loaded = Base.require(Base.PkgId(LW_UUID, "LoadedDuringTest"))
            @test Base.invokelatest(loaded.value) == 1

            # Prove the fixture exercises Base's loaded-package warning: the
            # ordinary precompile path emits it after the loaded source changes.
            write(source, "module LoadedDuringTest\nvalue() = 2\nend\n")
            control_io = IOBuffer()
            Base.Precompilation.precompilepkgs(; warn_loaded = true, io = control_io)
            @test occursin("currently loaded", String(take!(control_io)))
        finally
            Base.ACTIVE_PROJECT[] = old_project
        end

        # Make the cache stale again. TestOps precompiles this source with the
        # loaded v1 module still in Base.loaded_modules, then a fresh subprocess
        # loads v3 and runs the package's tests.
        write(source, "module LoadedDuringTest\nvalue() = 3\nend\n")
        test_io = IOBuffer()
        result = TestOps.test!(
            env, RegistryInstance[], Config(depots), LW_UUID;
            autoprecompile = true, io = test_io,
        )
        output = String(take!(test_io))
        @test result === nothing
        @test !occursin("currently loaded", output)
        @test !occursin("Restart julia", output)
    end
end
