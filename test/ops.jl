# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg
using VibePkg: API
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries
using VibePkg.Environments
using VibePkg.Planning
using VibePkg.Planning: PackageRequest, dropbuild
using VibePkg.EnvFiles: entry_version, is_path_tracked, is_registry_tracked
import TOML
using VibePkg.Errors: PkgError
using VibePkg.Display: print_env_diff, print_status
using VibePkg.Execution: instantiate!, manifest_matches_project

# reuses make_test_registry from registries.jl (Example: 0.5.0, 0.5.1, 1.0.0-yanked)

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

@testset "ops" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            # a local package to develop
            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

                [compat]
                Example = "0.5"
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")

            envdir = joinpath(dir, "env")
            mkpath(envdir)
            env = load_environment(envdir; depots)

            # develop: path-tracked, its deps resolved through its compat
            planned = plan_develop(env, regs, Config(depots), devpkg)
            entry = planned.manifest[UUID("deadbeef-dead-beef-dead-beefdeadbeef")]
            @test is_path_tracked(entry)
            @test entry_version(entry) == v"0.1.0"
            @test haskey(planned.manifest, EXAMPLE_UUID)   # dev'd package's dep came along
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1"
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test env.project.sources["MyDev"].path !== nothing  # [sources] recorded

            # pin Example at 0.5.0, then verify up cannot move it
            env2 = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            env2 = plan_pin(env2, regs, Config(depots), [PackageRequest("Example")])
            @test env2.manifest[EXAMPLE_UUID].pinned
            @test entry_version(env2.manifest[EXAMPLE_UUID]) == v"0.5.0"
            env3 = plan_up(env2, regs, Config(depots))
            @test entry_version(env3.manifest[EXAMPLE_UUID]) == v"0.5.0"  # pinned holds

            # free (pinned): unpin in place, no version movement
            env4 = plan_free(env3, regs, Config(depots), [PackageRequest("Example")])
            @test !env4.manifest[EXAMPLE_UUID].pinned
            @test entry_version(env4.manifest[EXAMPLE_UUID]) == v"0.5.0"

            # up after free moves within compat (MyDev caps Example at 0.5)
            env5 = plan_up(env4, regs, Config(depots))
            @test entry_version(env5.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # free of a registry-tracked, unpinned package errors
            @test_throws PkgError plan_free(env5, regs, Config(depots), [PackageRequest("Example")])

            # free of the dev'd package returns it to the registry — but
            # MyDev is unregistered, so it errors
            @test_throws PkgError plan_free(env5, regs, Config(depots), [PackageRequest("MyDev")])

            # compat set while compatible: recorded, and caps future ups
            env6 = plan_compat(env4, regs, Config(depots), "Example", "=0.5.0")
            @test env6.project.compat["Example"].str == "=0.5.0"
            @test entry_version(env6.manifest[EXAMPLE_UUID]) == v"0.5.0"
            env6up = plan_up(env6, regs, Config(depots))
            @test entry_version(env6up.manifest[EXAMPLE_UUID]) == v"0.5.0"  # compat caps

            # compat conflicting with the current resolution errors with a
            # suggestion instead of silently downgrading (Pkg semantics)
            @test_throws PkgError plan_compat(env5, regs, Config(depots), "Example", "=0.5.0")
            @test_throws PkgError plan_compat(env6, regs, Config(depots), "NotADep", "1")

            # display smoke: diff and status render without erroring
            @test sprint(io -> print_env_diff(io, env, env6)) isa String
            @test occursin("Example", sprint(io -> print_status(io, env6)))

            # outdated analysis: newer compatible ⇒ ⌃, blocked by compat ⇒ ⌅
            s = sprint(io -> print_status(io, env4; registries = regs))
            @test occursin("⌃", s) && occursin("marked with ⌃", s)
            s = sprint(io -> print_status(io, env6; registries = regs))
            @test occursin("⌅", s) && occursin("compatibility constraints", s)
            s = sprint(io -> print_status(io, env5; registries = regs))   # at latest
            @test !occursin("⌃", s) && !occursin("⌅", s)
            # outdated mode filters to flagged entries only
            s = sprint(io -> print_status(io, env6; registries = regs, outdated = true))
            @test occursin("Example", s) && !occursin("MyDev", s)

            # rm --manifest removes the reverse-dependency closure
            envm = plan_rm(env5, [PackageRequest("Example")]; mode = :manifest)
            @test !haskey(envm.manifest, EXAMPLE_UUID)
            @test !any(e -> e.name == "MyDev", values(envm.manifest.deps))  # dependent removed
            @test !haskey(envm.project.deps, "MyDev")

            # offline: resolution restricted to installed versions
            @test_throws VibePkg.Resolve.ResolverError plan_add(
                load_environment(mktempdir(); depots), regs, Config(depots; offline = true),
                [PackageRequest("Example")]
            )

            # generate a package skeleton
            gen = joinpath(dir, "NewPkg")
            result = VibePkg.generate(gen; io = devnull)
            @test haskey(result, "NewPkg")
            @test isfile(joinpath(gen, "Project.toml"))
            @test isfile(joinpath(gen, "src", "NewPkg.jl"))
            p = VibePkg.EnvFiles.read_project(joinpath(gen, "Project.toml"))
            @test p.name == "NewPkg" && p.version == v"0.1.0" && p.uuid !== nothing
            @test_throws PkgError VibePkg.generate(gen; io = devnull)      # exists
            @test_throws PkgError VibePkg.generate(joinpath(dir, "not valid"); io = devnull)

            # Pkg.jl#2821: an existing but empty cwd is a valid generation
            # target; its directory name supplies the package name.
            cwdpkg = mkpath(joinpath(dir, "CwdPkg"))
            cd(cwdpkg) do
                cwdresult = VibePkg.generate("."; io = devnull)
                @test haskey(cwdresult, "CwdPkg")
                @test VibePkg.EnvFiles.read_project("Project.toml").name == "CwdPkg"
                @test isfile(joinpath("src", "CwdPkg.jl"))
            end

            # Pkg.jl#1435: user-home expansion works through the API too.
            withenv("HOME" => dir) do
                homeresult = VibePkg.generate("~/HomePkg"; io = devnull)
                @test haskey(homeresult, "HomePkg")
                @test isfile(joinpath(dir, "HomePkg", "src", "HomePkg.jl"))
            end
        end
    end
end

# free on a dev'd REGISTERED package returns it to registry tracking
@testset "free dev'd registered package" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            # a local checkout that declares the registered Example name/uuid
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

            envdir = joinpath(dir, "env")
            mkpath(envdir)
            env = load_environment(envdir; depots)
            planned = plan_develop(env, regs, Config(depots), devex)
            @test is_path_tracked(planned.manifest[EXAMPLE_UUID])
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test env.project.sources["Example"].path !== nothing

            # free: back to registry tracking at the latest non-yanked version
            freed = plan_free(env, regs, Config(depots), [PackageRequest("Example")])
            entry = freed.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(entry)
            @test !is_path_tracked(entry)
            @test entry_version(entry) == v"0.5.1"
            @test VibePkg.EnvFiles.entry_tree_hash(entry) ==
                Base.SHA1("2222222222222222222222222222222222222222")

            # the write drops the [sources] entry from the project file
            write_environment(env, freed)
            env = load_environment(envdir; depots)
            @test !haskey(env.project.sources, "Example")
            @test is_registry_tracked(env.manifest[EXAMPLE_UUID])
            @test haskey(env.project.deps, "Example")   # still a direct dep
        end
    end
end

# after editing a dev'd package's own Project.toml on disk, `resolve`
# reconciles the outer manifest without moving anything movable
@testset "dev then resolve picks up new deps" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

                [compat]
                Example = "0.5"
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")

            envdir = joinpath(dir, "env")
            mkpath(envdir)
            env = load_environment(envdir; depots)
            write_environment(env, plan_develop(env, regs, Config(depots), devpkg))

            # the dev'd package gains a dep (TOML, a stdlib outside the
            # current transitive closure) behind Pkg's back
            toml_uuid = UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76")
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"

                [compat]
                Example = "0.5"
                """
            )
            env = load_environment(envdir; depots)
            @test !haskey(env.manifest, toml_uuid)          # manifest out of sync

            planned = plan_resolve(env, regs, Config(depots))
            @test haskey(planned.manifest, toml_uuid)       # new dep filled in
            mydev = planned.manifest[UUID("deadbeef-dead-beef-dead-beefdeadbeef")]
            @test mydev.deps["TOML"] == toml_uuid
            @test is_path_tracked(mydev)                                    # still dev'd
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1" # preserved
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test haskey(env.manifest, toml_uuid)
        end
    end
end

# Pkg never touches files at a dev'd path, whatever ops run in the env
@testset "dev'd path is never written to" begin
    snapshot_tree(root) = Dict(
        relpath(joinpath(r, f), root) => (mtime(joinpath(r, f)), read(joinpath(r, f)))
            for (r, _, files) in walkdir(root) for f in files
    )
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

                [compat]
                Example = "0.5"
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")

            envdir = joinpath(dir, "env")
            mkpath(envdir)
            env = load_environment(envdir; depots)
            write_environment(env, plan_develop(env, regs, Config(depots), devpkg))

            before = snapshot_tree(devpkg)

            env = load_environment(envdir; depots)
            write_environment(env, plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")]))
            env = load_environment(envdir; depots)
            write_environment(env, plan_pin(env, regs, Config(depots), [PackageRequest("Example")]))
            env = load_environment(envdir; depots)
            write_environment(env, plan_free(env, regs, Config(depots), [PackageRequest("Example")]))
            env = load_environment(envdir; depots)
            write_environment(env, plan_up(env, regs, Config(depots)))
            env = load_environment(envdir; depots)
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"  # ops did run

            @test snapshot_tree(devpkg) == before   # same files, mtimes, bytes
        end
    end
end

# recursive [sources]: a dev'd package's own `[sources]` path entry is
# honored transitively when the outer env resolves (Planning.collect_project)
@testset "recursive sources collection" begin
    inner_uuid = UUID("11111111-aaaa-bbbb-cccc-222222222222")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            inner = joinpath(dir, "MyInner")
            mkpath(joinpath(inner, "src"))
            write(
                joinpath(inner, "Project.toml"), """
                name = "MyInner"
                uuid = "$inner_uuid"
                version = "0.2.0"
                """
            )
            write(joinpath(inner, "src", "MyInner.jl"), "module MyInner end\n")

            outer = joinpath(dir, "MyOuter")
            mkpath(joinpath(outer, "src"))
            write(
                joinpath(outer, "Project.toml"), """
                name = "MyOuter"
                uuid = "33333333-aaaa-bbbb-cccc-444444444444"
                version = "0.1.0"

                [deps]
                MyInner = "$inner_uuid"

                [sources]
                MyInner = { path = "../MyInner" }
                """
            )
            write(joinpath(outer, "src", "MyOuter.jl"), "module MyOuter end\n")

            envdir = joinpath(dir, "env")
            mkpath(envdir)
            env = load_environment(envdir; depots)
            planned = plan_develop(env, regs, Config(depots), outer)

            # MyInner came in path-tracked, pointing at the actual checkout
            ientry = planned.manifest[inner_uuid]
            @test is_path_tracked(ientry)
            @test entry_version(ientry) == v"0.2.0"
            ipath = VibePkg.EnvFiles.entry_path(ientry)
            @test normpath(joinpath(dirname(env.manifest_file), ipath)) == inner

            # and it survives a write/reload round trip
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            ientry = env.manifest[inner_uuid]
            @test is_path_tracked(ientry)
            @test normpath(joinpath(dirname(env.manifest_file), VibePkg.EnvFiles.entry_path(ientry))) == inner
            # MyInner is not a direct dep of the env, so no outer [sources]
            @test !haskey(env.project.sources, "MyInner")
        end
    end
end

# readonly = true: modifying writes throw, read-only status still works
@testset "readonly environment" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do envdir
            write(
                joinpath(envdir, "Project.toml"), """
                readonly = true

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            env = load_environment(envdir; depots)
            @test env.project.readonly

            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            err = try
                write_environment(env, planned)
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("readonly", err.msg)
            @test !isfile(joinpath(envdir, "Manifest.toml"))   # nothing was written

            # read-only operations still work
            s = sprint(io -> print_status(io, env))
            @test occursin("(readonly)", s)
            @test occursin("Example", s)
        end
    end
end

# status annotations + rm-ignore pins
@testset "status pins" begin
    depots = VibePkg.Depots.depot_stack()
    mktempdir() do dir
        pf = joinpath(dir, "Project.toml"); write(pf, "")
        env = VibePkg.Environments.load_environment_from(pf; depots)
        @test occursin("(empty project)", sprint(io -> print_status(io, env)))
        @test occursin("(empty manifest)", sprint(io -> print_status(io, env; manifest_mode = true)))
        s = sprint(io -> VibePkg.Display.print_env_diff(io, env, env))
        @test occursin("No packages added to or removed from", s)

        # unknown rm warns and reports "No changes" without touching files
        old_active = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = pf
        try
            buf = IOBuffer()
            @test_logs (:warn, r"Package .*Bogus.* is not in project .*Project\.toml.*ignoring") VibePkg.rm("Bogus"; io = buf)
            @test occursin("No changes", String(take!(buf)))
        finally
            Base.ACTIVE_PROJECT[] = old_active
        end
    end
    mktempdir() do dir
        pf = joinpath(dir, "Project.toml")
        write(pf, "[deps]\nFake = \"11111111-2222-3333-4444-555555555555\"\n")
        write(
            joinpath(dir, "Manifest.toml"), """
            julia_version = "1.12.6"
            manifest_format = "2.0"
            project_hash = "1111111111111111111111111111111111111111"

            [[deps.Fake]]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            uuid = "11111111-2222-3333-4444-555555555555"
            version = "1.0.0"
            """
        )
        env = VibePkg.Environments.load_environment_from(pf; depots)
        s = sprint(io -> print_status(io, env; depots))
        @test occursin("→", s)
        @test occursin("Packages marked with → are not downloaded, use `instantiate` to download", s)
    end
end

# Pkg.jl#1231 — a registry renaming a package must leave the Project.toml
# deps key and the manifest entry name mutually consistent
@testset "registry renames a package" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do envdir
            env = load_environment(envdir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            # the registry renames Example → Example2 (same uuid, same path)
            reg = joinpath(depot, "registries", "TestRegistry")
            for f in (joinpath(reg, "Registry.toml"), joinpath(reg, "E", "Example", "Package.toml"))
                write(f, replace(read(f, String), "\"Example\"" => "\"Example2\""))
            end
            planned = plan_up(env, reachable_registries(depots), Config(depots))
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.1"  # still resolves
            for (name, uuid) in planned.project.deps                          # self-consistent
                @test planned.manifest[uuid].name == name
            end
        end
    end
end

# Pkg.jl#4023 — a relative [sources] path is kept literally across
# unrelated operations
@testset "relative sources path survives unrelated ops" begin
    foo_uuid = UUID("f00f00f0-f00f-4f00-8f00-f00f00f00f00")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            foodev = joinpath(dir, "FooDev")
            mkpath(joinpath(foodev, "src"))
            write(
                joinpath(foodev, "Project.toml"), """
                name = "FooDev"
                uuid = "$foo_uuid"
                version = "0.1.0"
                """
            )
            write(joinpath(foodev, "src", "FooDev.jl"), "module FooDev end\n")
            envdir = mkpath(joinpath(dir, "env"))
            write(
                joinpath(envdir, "Project.toml"), """
                [deps]
                FooDev = "$foo_uuid"

                [sources]
                FooDev = { path = "../FooDev" }
                """
            )
            env = load_environment(envdir; depots)
            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            @test haskey(planned.manifest, foo_uuid)
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test env.project.sources["FooDev"].path == "../FooDev"
            @test occursin("../FooDev", read(joinpath(envdir, "Project.toml"), String))
        end
    end
end

# Pkg.jl#4018 — status with extensions must handle a trigger that is a
# strong dep (listed in [deps], not [weakdeps]) without throwing
@testset "extension status with strong-dep trigger" begin
    host_uuid = UUID("ee44ee44-ee44-4e44-8e44-ee44ee44ee44")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            host = joinpath(dir, "ExtHost")
            mkpath(joinpath(host, "src"))
            write(
                joinpath(host, "Project.toml"), """
                name = "ExtHost"
                uuid = "$host_uuid"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

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
            # the post-install fixup records the extension (dev'd: readable)
            manifest = VibePkg.Execution.fixups_from_projectfile(env, depots)
            env = VibePkg.Environments.Environment(
                env.project_file, env.manifest_file, env.project, manifest, env.workspace
            )
            entry = env.manifest[host_uuid]
            @test entry.exts == Dict("ExampleExt" => "Example")
            @test isempty(entry.weakdeps)
            s = sprint(io -> print_status(io, env; extensions = true))  # no throw
            @test s isa String
            # a strong-dep-only extension (empty [weakdeps]) is still listed
            @test VibePkg.Display.status_ext_info(host_uuid, entry) !== nothing
            @test occursin("ExampleExt", s)
        end
    end
end

# assorted status/pin regressions sharing the MyDev + Example fixture
@testset "status and pin regressions" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

                [compat]
                Example = "0.5"
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            write_environment(env, plan_develop(env, regs, Config(depots), devpkg))
            env = load_environment(envdir; depots)

            # Pkg.jl#1737 — pin to a specific version (not the current one)
            @test entry_version(env.manifest[EXAMPLE_UUID]) == v"0.5.1"
            pinned = plan_pin(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            @test entry_version(pinned.manifest[EXAMPLE_UUID]) == v"0.5.0"
            @test pinned.manifest[EXAMPLE_UUID].pinned

            # Pkg.jl#1077 — adding a stdlib twice neither throws nor
            # duplicates the manifest entry
            e1 = plan_add(env, regs, Config(depots), [PackageRequest("Test")])
            e2 = plan_add(e1, regs, Config(depots), [PackageRequest("Test")])
            @test haskey(e2.project.deps, "Test")
            @test count(e -> e.name == "Test", collect(values(e2.manifest.deps))) == 1

            # Pkg.jl#1989 — stdlibs are listed in `st -m`
            s = sprint(io -> print_status(io, e2; manifest_mode = true))
            @test occursin("[8dfed614] Test", s)

            # mixed status fixture: Example at 0.5.0 gets ⌃, dev'd MyDev is unmarked
            env050 = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])

            # Pkg.jl#3564 — no ANSI escapes unless the io has :color
            plain = sprint(io -> print_status(io, env050; registries = regs))
            @test !occursin("\e[", plain)
            colored = sprint(io -> print_status(io, env050; registries = regs); context = :color => true)
            @test occursin("\e[", colored)

            # Pkg.jl#3449 — ⌃-marked and unmarked entries align on the uuid bracket
            @test occursin("⌃", plain)
            lines = [l for l in split(plain, '\n') if occursin(r"\[[0-9a-f]{8}\]", l)]
            @test length(lines) >= 2
            @test length(unique(textwidth(first(split(l, '['))) for l in lines)) == 1
        end
    end
end

# Pkg.jl#1778 — a path package depending back on the active project (which
# is itself a package with a registered name/uuid) plans without a KeyError
@testset "cyclic dep back onto the active project" begin
    x_uuid = UUID("cafe0000-cafe-4afe-8afe-cafe0000cafe")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "Example"))
            mkpath(joinpath(envdir, "src"))
            write(
                joinpath(envdir, "Project.toml"), """
                name = "Example"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.0"
                """
            )
            write(joinpath(envdir, "src", "Example.jl"), "module Example end\n")
            xpkg = joinpath(dir, "XDep")
            mkpath(joinpath(xpkg, "src"))
            write(
                joinpath(xpkg, "Project.toml"), """
                name = "XDep"
                uuid = "$x_uuid"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            write(joinpath(xpkg, "src", "XDep.jl"), "module XDep end\n")
            env = load_environment(envdir; depots)
            planned = plan_develop(env, regs, Config(depots), xpkg)   # no KeyError
            @test haskey(planned.manifest, x_uuid)
            @test planned.manifest[x_uuid].deps["Example"] == EXAMPLE_UUID
        end
    end
end

# Pkg.jl#1755 — a dev entry recorded with an absolute path stays absolute
# through later operations
@testset "absolute dev path stays absolute" begin
    a_uuid = UUID("aaaa1755-aaaa-4aaa-8aaa-aaaaaaaa1755")
    b_uuid = UUID("bbbb1755-bbbb-4bbb-8bbb-bbbbbbbb1755")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            for (name, uuid) in (("DevA", a_uuid), ("DevB", b_uuid))
                pkg = joinpath(dir, name)
                mkpath(joinpath(pkg, "src"))
                write(
                    joinpath(pkg, "Project.toml"), """
                    name = "$name"
                    uuid = "$uuid"
                    version = "0.1.0"
                    """
                )
                write(joinpath(pkg, "src", "$name.jl"), "module $name end\n")
            end
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            write_environment(env, plan_develop(env, regs, Config(depots), joinpath(dir, "DevA")))
            env = load_environment(envdir; depots)
            @test isabspath(VibePkg.EnvFiles.entry_path(env.manifest[a_uuid]))
            planned = plan_develop(env, regs, Config(depots), joinpath(dir, "DevB"))
            @test isabspath(VibePkg.EnvFiles.entry_path(planned.manifest[a_uuid]))
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test isabspath(VibePkg.EnvFiles.entry_path(env.manifest[a_uuid]))
        end
    end
end

# Pkg.jl#1738 — `status --diff` works for a project in a SUBDIRECTORY of a
# git repository (no "only available for git repositories" warning)
@testset "status --diff from a git subdirectory" begin
    LibGit2 = VibePkg.Git.LibGit2
    old_active = Base.ACTIVE_PROJECT[]
    try
        mktempdir() do dir
            dir = realpath(dir)
            sub = mkpath(joinpath(dir, "sub"))
            project = """
            [deps]
            A = "aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            """
            manifest = """
            julia_version = "1.12.0"
            manifest_format = "2.1"

            [[deps.A]]
            uuid = "aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            version = "1.0.0"
            """
            write(joinpath(sub, "Project.toml"), project)
            write(joinpath(sub, "Manifest.toml"), manifest)
            repo = LibGit2.init(dir)
            try
                LibGit2.add!(repo, joinpath("sub", "Project.toml"), joinpath("sub", "Manifest.toml"))
                sig = LibGit2.Signature("vibepkg-test", "test@example.com")
                LibGit2.commit(repo, "init"; author = sig, committer = sig)
            finally
                close(repo)
            end
            # mutate the environment after the commit
            write(joinpath(sub, "Project.toml"), project * "B = \"bbbbbbb1-bbbb-4bbb-8bbb-bbbbbbbbbbbb\"\n")
            write(
                joinpath(sub, "Manifest.toml"), manifest * """

                    [[deps.B]]
                    uuid = "bbbbbbb1-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                    version = "1.0.0"
                    """
            )
            Base.ACTIVE_PROJECT[] = joinpath(sub, "Project.toml")
            buf = IOBuffer()
            @test_logs VibePkg.status(diff = true, io = buf)   # no warnings
            s = String(take!(buf))
            @test occursin("Diff", s)
            @test occursin("+ B", s)
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
    end
end

# Pkg.jl#1217 — pin@version on a non-registry-tracked entry returns it to
# registry tracking at the requested version
@testset "pin@version re-tracks the registry" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
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
            write_environment(env, plan_develop(env, regs, Config(depots), devex))
            env = load_environment(envdir; depots)
            @test is_path_tracked(env.manifest[EXAMPLE_UUID])

            pinned = plan_pin(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            entry = pinned.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(entry)
            @test !is_path_tracked(entry)
            @test entry_version(entry) == v"0.5.0"
            @test entry.pinned
            # the [sources] entry is gone after the write
            write_environment(env, pinned)
            env = load_environment(envdir; depots)
            @test !haskey(env.project.sources, "Example")
        end
    end
end

# Pkg.jl#528 — a path-tracked package's [extras] must not leak into
# resolution (its extras may name packages absent from every registry)
@testset "dev'd [extras] don't leak into resolution" begin
    bogus_uuid = UUID("b0b0b0b0-b0b0-4b0b-8b0b-b0b0b0b0b0b0")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

                [compat]
                Example = "0.5"

                [extras]
                Bogus = "$bogus_uuid"

                [targets]
                test = ["Bogus"]
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            planned = plan_develop(env, regs, Config(depots), devpkg)   # resolves fine
            @test !haskey(planned.manifest, bogus_uuid)
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            resolved = plan_resolve(env, regs, Config(depots))          # so does resolve
            @test !haskey(resolved.manifest, bogus_uuid)
        end
    end
end

# Pkg.jl#1066 — two packages with the same name but different uuids coexist
# in one manifest
@testset "same-name different-uuid packages coexist" begin
    b1_uuid = UUID("10661066-1066-4066-8066-106610661066")
    b2_uuid = UUID("20662066-2066-4066-8066-206620662066")
    a_uuid = UUID("a066a066-a066-4066-8066-a066a066a066")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            for (path, name, uuid) in (("B1", "B", b1_uuid), ("B2", "B", b2_uuid))
                pkg = joinpath(dir, path)
                mkpath(joinpath(pkg, "src"))
                write(
                    joinpath(pkg, "Project.toml"), """
                    name = "$name"
                    uuid = "$uuid"
                    version = "0.1.0"
                    """
                )
                write(joinpath(pkg, "src", "$name.jl"), "module $name end\n")
            end
            apkg = joinpath(dir, "A")
            mkpath(joinpath(apkg, "src"))
            write(
                joinpath(apkg, "Project.toml"), """
                name = "A"
                uuid = "$a_uuid"
                version = "0.1.0"

                [deps]
                B = "$b1_uuid"

                [sources]
                B = { path = "../B1" }
                """
            )
            write(joinpath(apkg, "src", "A.jl"), "module A end\n")
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            write_environment(env, plan_develop(env, regs, Config(depots), apkg))
            env = load_environment(envdir; depots)
            @test haskey(env.manifest, b1_uuid)

            planned = plan_develop(env, regs, Config(depots), joinpath(dir, "B2"))
            @test haskey(planned.manifest, b1_uuid)
            @test haskey(planned.manifest, b2_uuid)
            @test planned.manifest[b1_uuid].name == planned.manifest[b2_uuid].name == "B"
            @test planned.project.deps["B"] == b2_uuid
            @test planned.manifest[a_uuid].deps["B"] == b1_uuid
            # survives a write/reload round trip
            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test haskey(env.manifest, b1_uuid) && haskey(env.manifest, b2_uuid)
        end
    end
end

# Pkg.jl new.jl "update: input checking" — updating a named package that is
# not present in the manifest is an error.
@testset "up of a package not in the manifest errors" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        env = load_environment(mktempdir(); depots)
        @test_throws PkgError plan_up(env, regs, Config(depots), [PackageRequest("Example")])
    end
end

# Pkg.jl new.jl "update/instantiate: input checking" — a manifest that
# references a package with no registry entry cannot be resolved (up) or
# materialized (instantiate).
@testset "up/instantiate reject an unregistered manifest UUID" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            ghost = "12345678-1234-1234-1234-123456789abc"
            write(
                joinpath(envdir, "Project.toml"), """
                [deps]
                Ghost = "$ghost"
                """
            )
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "$VERSION"
                manifest_format = "2.0"

                [[deps.Ghost]]
                uuid = "$ghost"
                version = "1.0.0"
                git-tree-sha1 = "0000000000000000000000000000000000000000"
                """
            )
            env = load_environment(envdir; depots)
            # up can't resolve a package the registry has never heard of...
            @test_throws VibePkg.Resolve.ResolverError plan_up(env, regs, Config(depots))
            # ...and instantiate refuses to materialize it.
            @test_throws PkgError instantiate!(env, regs, Config(depots); io = devnull)
        end
    end
end

# Pkg.jl api.jl "`[compat]` entries for `julia`" — developing/adding a path
# package whose `[compat] julia` excludes the running Julia is rejected.
@testset "path package with incompatible [compat] julia errors" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            badpkg = joinpath(dir, "FarPast")
            mkpath(joinpath(badpkg, "src"))
            write(
                joinpath(badpkg, "Project.toml"), """
                name = "FarPast"
                uuid = "aaaaaaaa-0000-0000-0000-000000000001"
                version = "0.1.0"

                [compat]
                julia = "1.0 - 1.5"
                """
            )
            write(joinpath(badpkg, "src", "FarPast.jl"), "module FarPast end\n")
            env = load_environment(mkpath(joinpath(dir, "env")); depots)
            err = try
                plan_develop(env, regs, Config(depots), badpkg)
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("requires Julia", err.msg)
            @test occursin("selected Julia version", err.msg)
        end
    end
end

# Pkg.jl api.jl "resolve error shows yanked packages warning" — when a resolve
# fails and the manifest still references registry versions that were yanked,
# the error is accompanied by a warning naming those yanked versions.
@testset "yanked versions named in a failed resolve" begin
    mktempdir() do depot
        make_test_registry(depot)               # Example 1.0.0 is yanked
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "$VERSION"
                manifest_format = "2.0"

                [[deps.Example]]
                uuid = "$EXAMPLE_UUID"
                version = "1.0.0"
                git-tree-sha1 = "3333333333333333333333333333333333333333"
                """
            )
            env = load_environment(envdir; depots)
            buf = IOBuffer()
            err = Base.ScopedValues.with(VibePkg.Utils.DEFAULT_IO => buf) do
                try
                    # 0.9.0 doesn't exist, so the resolve is unsatisfiable
                    plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.9.0")])
                    nothing
                catch e
                    e
                end
            end
            @test err isa VibePkg.Resolve.ResolverError
            out = String(take!(buf))
            @test occursin(
                "The following package versions were yanked from their registry and are not resolvable:",
                out,
            )
            @test occursin("- Example [7876af07] 1.0.0", out)
        end
    end
end

# Pkg.jl pkg.jl "Suggest `Pkg.develop` instead of `Pkg.add`" — adding a bare
# local path (a directory that is not an installable registered package) errors
# rather than silently doing the wrong thing.
@testset "add of a bare local path errors" begin
    mktempdir() do dir
        touch(joinpath(dir, "Project.toml"))
        err = try
            VibePkg.add(; path = dir, io = devnull)
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("perhaps you meant `VibePkg.develop`?", err.msg)
    end
end

# Pkg.jl pkg.jl "issue #2191: better diagnostic for missing package" — a
# developed path dependency whose directory has been deleted makes resolve
# fail with a PkgError instead of some opaque internal error.
@testset "resolve errors when a dev'd path is gone" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            B = joinpath(dir, "B")
            mkpath(joinpath(B, "src"))
            write(
                joinpath(B, "Project.toml"), """
                name = "B"
                uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
                version = "0.1.0"
                """
            )
            write(joinpath(B, "src", "B.jl"), "module B end\n")
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            write_environment(env, plan_develop(env, regs, Config(depots), B))
            env = load_environment(envdir; depots)
            Base.rm(B; recursive = true)                    # the source disappears
            err = try
                plan_resolve(env, regs, Config(depots))
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("expected at path", err.msg)
            @test occursin("referenced by manifest", err.msg)
            @test occursin(repr(env.manifest_file), err.msg)
        end
    end
end

# Pkg.jl manifests.jl "no mismatch: update_on_mismatch=true is a no-op" —
# manifest_matches_project (the predicate instantiate(update_on_mismatch)
# consults) is true for a freshly resolved env and false once the manifest
# records a different julia minor version.
@testset "manifest_matches_project predicate" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
            env = load_environment(envdir; depots)
            write_environment(env, plan_add(env, regs, Config(depots), [PackageRequest("Example")]))
            env = load_environment(envdir; depots)
            @test manifest_matches_project(env)             # fresh resolve: matches

            # rewrite the manifest with a stale julia version → no longer matches
            # (the stamped version is dropbuild(VERSION), not VERSION, so use
            # what the manifest actually records)
            man = read(env.manifest_file, String)
            stamped = env.manifest.julia_version
            other = VersionNumber(VERSION.major, VERSION.minor == 0 ? 99 : VERSION.minor - 1, 0)
            newman = replace(man, "julia_version = \"$stamped\"" => "julia_version = \"$other\"")
            @assert newman != man
            write(env.manifest_file, newman)
            env = load_environment(envdir; depots)
            @test !manifest_matches_project(env)
        end
    end
end

# Pkg.jl new.jl "relative depot path" — a relative entry in the depot stack is
# usable: registries under it are reachable and resolution works from that cwd.
@testset "relative depot path" begin
    mktempdir() do dir
        cd(dir) do
            mkpath("reldepot")
            make_test_registry("reldepot")          # registry lives under the relative depot
            depots = depot_stack(["reldepot"])       # a RELATIVE depot entry
            regs = reachable_registries(depots)
            @test !isempty(regs)
            envdir = mkpath("env")
            env = load_environment(envdir; depots)
            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.0"
        end
    end
end

# Pkg.jl#4459 / issue #3766 — developing a package whose `[weakdeps]` references
# an unregistered / non-existent UUID must succeed (the weak dependency is not
# resolved against a registry).
@testset "develop with an unregistered weakdep uuid" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            wd_uuid = UUID("aaaa1111-0000-0000-0000-000000000001")
            p = joinpath(dir, "WD")
            mkpath(joinpath(p, "src"))
            write(
                joinpath(p, "Project.toml"), """
                name = "WD"
                uuid = "$wd_uuid"
                version = "0.1.0"

                [weakdeps]
                Ghost = "deadbeef-0000-0000-0000-00000000dead"
                """
            )
            write(joinpath(p, "src", "WD.jl"), "module WD end\n")
            env = load_environment(mkpath(joinpath(dir, "env")); depots)
            planned = plan_develop(env, regs, Config(depots), p)
            @test is_path_tracked(planned.manifest[wd_uuid])
        end
    end
end

# Pkg.jl#1989 / #4435 — status in manifest mode filtered by a package name shows
# that package together with its dependencies.
@testset "status manifest filter shows a package's deps" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            p = joinpath(dir, "MyDev")
            mkpath(joinpath(p, "src"))
            write(
                joinpath(p, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"

                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"

                [compat]
                Example = "0.5"
                """
            )
            write(joinpath(p, "src", "MyDev.jl"), "module MyDev end\n")
            env = load_environment(mkpath(joinpath(dir, "env")); depots)
            write_environment(env, plan_develop(env, regs, Config(depots), p))
            env = load_environment(joinpath(dir, "env"); depots)
            s = sprint(io -> print_status(io, env; manifest_mode = true, filter_names = ["MyDev"]))
            @test occursin("MyDev", s)
            @test occursin("Example", s)          # the filtered package's dependency
        end
    end
end

# Pkg.jl#4686 — `free`ing a develop'd package must succeed and re-track the
# registry version. (Pkg 1.13-rc1 regressed: `free` (and `add`) of a dev'd
# package errored "could not find source path for package ... based on manifest".)
@testset "free re-tracks a develop'd package (#4686)" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
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

            freed = plan_free(env, regs, Config(depots), [PackageRequest("Example")])
            entry = freed.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(entry)
            @test !is_path_tracked(entry)
            @test entry_version(entry) == v"0.5.1"
        end
    end
end

# Pkg.jl#4691 — unknown/custom top-level tables in Project.toml (written by
# external tooling, e.g. `[reuse_licensing]`) must survive Pkg operations; they
# are ignored semantically but preserved verbatim (via `project.raw`).
@testset "operations preserve custom Project.toml tables (#4691)" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            proj = joinpath(envdir, "Project.toml")
            write(
                proj, """
                name = "MyEnv"
                uuid = "00000000-0000-0000-0000-0000000000aa"

                [reuse_licensing]
                reuse_specification_version = "3.3"
                package_license_expression = "EUPL-1.2+"

                [tool.mytool]
                foo = 42
                """
            )
            env = load_environment(envdir; depots)
            @test haskey(env.project.raw, "reuse_licensing")

            # add: custom tables (and their values) survive
            write_environment(env, plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1")]))
            txt = read(proj, String)
            @test occursin("[reuse_licensing]", txt)
            @test occursin("EUPL-1.2+", txt)
            @test occursin("[tool.mytool]", txt)

            # rm: still survive
            env = load_environment(envdir; depots)
            write_environment(env, plan_rm(env, [PackageRequest("Example")]))
            txt2 = read(proj, String)
            @test occursin("[reuse_licensing]", txt2)
            @test occursin("EUPL-1.2+", txt2)
            @test occursin("[tool.mytool]", txt2)
        end
    end
end

# developing a package listed in [weakdeps] must promote it to a real dep in
# both representations — left in weakdeps the reader demotes it to weak-only
# and then rejects its [sources] entry, making the environment unloadable
@testset "develop of a weakdep promotes it out of [weakdeps]" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            devuuid = "deadbeef-dead-beef-dead-beefdeadbeef"
            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "$devuuid"
                version = "0.1.0"
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")

            envdir = mkpath(joinpath(dir, "env"))
            write(
                joinpath(envdir, "Project.toml"), """
                [weakdeps]
                MyDev = "$devuuid"
                """
            )
            env = load_environment(envdir; depots)
            planned = plan_develop(env, regs, Config(depots), devpkg)
            @test haskey(planned.project.deps, "MyDev")
            @test !haskey(planned.project.weakdeps, "MyDev")
            @test !haskey(planned.project.deps_weak, "MyDev")

            # the round-trip through disk must load (and stay a real dep)
            write_environment(env, planned)
            env2 = load_environment(envdir; depots)
            @test haskey(env2.project.deps, "MyDev")
            @test !haskey(env2.project.deps_weak, "MyDev")
            @test is_path_tracked(env2.manifest[UUID(devuuid)])
        end
    end
end

# targeted `up` on a fully-pinned environment must validate the request
# instead of silently returning through the all-pinned shortcut
@testset "targeted up validates names on a fully-pinned env" begin
    mktempdir() do depot
        make_test_registry(depot)
        mktempdir() do dir
            # a hand-written fully-pinned environment: every manifest entry is
            # pinned (a resolved fixture env would drag in unpinned stdlibs)
            envdir = mkpath(joinpath(dir, "env"))
            write(
                joinpath(envdir, "Project.toml"),
                "[deps]\nExample = \"7876af07-990d-54b4-ab0e-23690620f79a\"\n"
            )
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "1.12.6"
                manifest_format = "2.0"
                project_hash = "1111111111111111111111111111111111111111"

                [[deps.Example]]
                git-tree-sha1 = "2222222222222222222222222222222222222222"
                pinned = true
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.1"
                """
            )

            old_active = Base.ACTIVE_PROJECT[]
            old_depot_path = copy(Base.DEPOT_PATH)
            old_offline = VibePkg.API.OFFLINE_MODE[]
            try
                copy!(Base.DEPOT_PATH, [depot])
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
                VibePkg.API.OFFLINE_MODE[] = true   # hermetic: no registry fetch
                # the update-everything form still short-circuits
                buf = IOBuffer()
                VibePkg.up(; io = buf)
                @test occursin("All dependencies are pinned", String(take!(buf)))
                # an unknown target errors instead of hitting the shortcut
                @test_throws PkgError VibePkg.up("Nonexistent"; io = devnull)
            finally
                Base.ACTIVE_PROJECT[] = old_active
                copy!(Base.DEPOT_PATH, old_depot_path)
                VibePkg.API.OFFLINE_MODE[] = old_offline
            end
        end
    end
end

# develop of a vector applies as ONE transaction: a failing item must leave
# the environment untouched (per-item mutation loops commit earlier items)
@testset "vector develop is atomic" begin
    mktempdir() do depot
        make_test_registry(depot)
        mktempdir() do dir
            good = joinpath(dir, "GoodPkg")
            mkpath(joinpath(good, "src"))
            write(
                joinpath(good, "Project.toml"), """
                name = "GoodPkg"
                uuid = "aaaabbbb-cccc-dddd-eeee-ffff00001111"
                version = "0.1.0"
                """
            )
            write(joinpath(good, "src", "GoodPkg.jl"), "module GoodPkg end\n")
            envdir = mkpath(joinpath(dir, "env"))

            old_active = Base.ACTIVE_PROJECT[]
            old_depot_path = copy(Base.DEPOT_PATH)
            old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            try
                copy!(Base.DEPOT_PATH, [depot])
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
                @test_throws PkgError VibePkg.develop(
                    [
                        VibePkg.PackageSpec(path = good),
                        VibePkg.PackageSpec(path = joinpath(dir, "NoSuchPkg")),
                    ]; io = devnull
                )
                # the failing second item rolled the whole call back
                @test !isfile(joinpath(envdir, "Manifest.toml"))
                proj = joinpath(envdir, "Project.toml")
                @test !isfile(proj) || !occursin("GoodPkg", read(proj, String))
            finally
                Base.ACTIVE_PROJECT[] = old_active
                copy!(Base.DEPOT_PATH, old_depot_path)
                VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            end
        end
    end
end

# name-keyed wrappers accept UUID-only PackageSpecs (previously the UUID was
# stringified into a "name" no manifest entry could match)
@testset "UUID-only PackageSpec for build" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            write_environment(env, plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.1")]))

            old_active = Base.ACTIVE_PROJECT[]
            old_depot_path = copy(Base.DEPOT_PATH)
            old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            try
                copy!(Base.DEPOT_PATH, [depot])
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
                # not installed -> build has nothing to run, but the UUID must
                # resolve to `Example` instead of erroring on a uuid-string name
                VibePkg.build(VibePkg.PackageSpec(uuid = EXAMPLE_UUID); io = devnull)
                @test true
                # an unknown uuid errors clearly
                @test_throws PkgError VibePkg.build(
                    VibePkg.PackageSpec(uuid = Base.UUID("99999999-9999-9999-9999-999999999999"));
                    io = devnull
                )
            finally
                Base.ACTIVE_PROJECT[] = old_active
                copy!(Base.DEPOT_PATH, old_depot_path)
                VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            end
        end
    end
end

# why: a UUID names the package exactly; a duplicated name errors instead of
# silently explaining whichever entry the manifest iteration hit last
@testset "why disambiguates duplicate manifest names" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        u1 = "11111111-1111-1111-1111-111111111111"
        u2 = "22222222-2222-2222-2222-222222222222"
        root = "33333333-3333-3333-3333-333333333333"
        other = "44444444-4444-4444-4444-444444444444"
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            Root = "$root"
            Other = "$other"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "1.12.6"
            manifest_format = "2.0"
            project_hash = "1111111111111111111111111111111111111111"

            [[deps.Root]]
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            uuid = "$root"
            version = "1.0.0"

                [deps.Root.deps]
                Dup = "$u1"

            [[deps.Other]]
            git-tree-sha1 = "3333333333333333333333333333333333333333"
            uuid = "$other"
            version = "1.0.0"

                [deps.Other.deps]
                Dup = "$u2"

            [[deps.Dup]]
            git-tree-sha1 = "4444444444444444444444444444444444444444"
            uuid = "$u1"
            version = "1.0.0"

            [[deps.Dup]]
            git-tree-sha1 = "5555555555555555555555555555555555555555"
            uuid = "$u2"
            version = "2.0.0"
            """
        )

        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        try
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            # by uuid: each Dup is explained through its own dependent
            buf = IOBuffer()
            VibePkg.why(VibePkg.PackageSpec(uuid = Base.UUID(u1)); io = buf)
            out1 = String(take!(buf))
            @test occursin("Root", out1) && !occursin("Other", out1)
            VibePkg.why(VibePkg.PackageSpec(uuid = Base.UUID(u2)); io = buf)
            out2 = String(take!(buf))
            @test occursin("Other", out2) && !occursin("Root", out2)
            # by name: ambiguous -> error, never a silent last-wins pick
            @test_throws PkgError VibePkg.why("Dup"; io = devnull)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
        end
    end
end

# develop must honor PackageSpec.subdir for path and url requests: the
# tracked project is the one under `subdir`, not the repository root
@testset "develop honors subdir" begin
    LibGit2 = VibePkg.Git.LibGit2
    sub_uuid = Base.UUID("5abd1e00-1111-4111-8111-111111111111")
    root_uuid = Base.UUID("400f0000-2222-4222-8222-222222222222")
    mktempdir() do depot
        make_test_registry(depot)
        mktempdir() do dir
            # a monorepo: a decoy package at the root and the real one below
            repo_dir = joinpath(dir, "Mono")
            mkpath(joinpath(repo_dir, "src"))
            write(
                joinpath(repo_dir, "Project.toml"), """
                name = "RootPkg"
                uuid = "$root_uuid"
                version = "0.1.0"
                """
            )
            write(joinpath(repo_dir, "src", "RootPkg.jl"), "module RootPkg end\n")
            subpkg = joinpath(repo_dir, "SubPkg")
            mkpath(joinpath(subpkg, "src"))
            write(
                joinpath(subpkg, "Project.toml"), """
                name = "SubPkg"
                uuid = "$sub_uuid"
                version = "0.1.0"
                """
            )
            write(joinpath(subpkg, "src", "SubPkg.jl"), "module SubPkg end\n")

            old_active = Base.ACTIVE_PROJECT[]
            old_depot_path = copy(Base.DEPOT_PATH)
            old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
            old_devdir = get(ENV, "JULIA_PKG_DEVDIR", nothing)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            try
                copy!(Base.DEPOT_PATH, [depot])
                ENV["JULIA_PKG_DEVDIR"] = joinpath(dir, "devdir")

                # path + subdir tracks the subproject, not the root project
                envdir = mkpath(joinpath(dir, "env-path"))
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
                VibePkg.develop(VibePkg.PackageSpec(path = repo_dir, subdir = "SubPkg"); io = devnull)
                env = load_environment(envdir; depots = depot_stack([depot]))
                @test haskey(env.manifest, sub_uuid)
                @test !haskey(env.manifest, root_uuid)
                @test VibePkg.EnvFiles.entry_path(env.manifest[sub_uuid]) == subpkg

                # a nonexistent subdir errors before anything is written
                envdir2 = mkpath(joinpath(dir, "env-bad"))
                Base.ACTIVE_PROJECT[] = joinpath(envdir2, "Project.toml")
                @test_throws PkgError VibePkg.develop(
                    VibePkg.PackageSpec(path = repo_dir, subdir = "NoSuchDir"); io = devnull
                )
                @test !isfile(joinpath(envdir2, "Manifest.toml"))

                # url + subdir: the clone is tracked at its subdirectory
                gitrepo = LibGit2.init(repo_dir)
                try
                    # git pathspecs are /-separated on every platform — joinpath
                    # would produce backslashes on Windows and silently match nothing
                    LibGit2.add!(gitrepo, "Project.toml", "src/RootPkg.jl")
                    LibGit2.add!(gitrepo, "SubPkg/Project.toml", "SubPkg/src/SubPkg.jl")
                    sig = LibGit2.Signature("vibepkg-test", "test@example.com")
                    LibGit2.commit(gitrepo, "init"; author = sig, committer = sig)
                finally
                    close(gitrepo)
                end
                envdir3 = mkpath(joinpath(dir, "env-url"))
                Base.ACTIVE_PROJECT[] = joinpath(envdir3, "Project.toml")
                VibePkg.develop(VibePkg.PackageSpec(url = repo_dir, subdir = "SubPkg"); io = devnull)
                env3 = load_environment(envdir3; depots = depot_stack([depot]))
                @test haskey(env3.manifest, sub_uuid)
                @test !haskey(env3.manifest, root_uuid)
                @test VibePkg.EnvFiles.entry_path(env3.manifest[sub_uuid]) ==
                    joinpath(dir, "devdir", "Mono", "SubPkg")
            finally
                Base.ACTIVE_PROJECT[] = old_active
                copy!(Base.DEPOT_PATH, old_depot_path)
                VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
                old_devdir === nothing ? delete!(ENV, "JULIA_PKG_DEVDIR") : (ENV["JULIA_PKG_DEVDIR"] = old_devdir)
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl manifests.jl "v1.0: activate and read, upgrade on write" (line 79) and
# "v2.0: … upgrade on write" (line 99) — activating a v1.0 / v2.0 reference
# manifest and then running an op rewrites it upgraded to manifest_format 2.1.
# Divergence: `add`/resolve re-stamp the format to 2.1, but `rm` prunes the
# manifest in place and preserves whatever format it already had (so it keeps
# 2.1 after an add, but would NOT by itself upgrade a bare v1 manifest).
@testset "op-driven manifest upgrade to format 2.1" begin
    v1_manifest = """
    [[Example]]
    deps = ["Test"]
    git-tree-sha1 = "2222222222222222222222222222222222222222"
    uuid = "$EXAMPLE_UUID"
    version = "0.5.1"

    [[Test]]
    uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    """
    v2_manifest = """
    julia_version = "1.7.0-DEV"
    manifest_format = "2.0"

    [[deps.Example]]
    deps = ["Test"]
    git-tree-sha1 = "2222222222222222222222222222222222222222"
    uuid = "$EXAMPLE_UUID"
    version = "0.5.1"

    [[deps.Test]]
    uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    """
    for (label, manifest_text, loaded_format) in (
            ("v1.0", v1_manifest, v"1.0.0"),
            ("v2.0", v2_manifest, v"2.0.0"),
        )
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            make_test_registry(depot)
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            envdir = mkpath(joinpath(dir, "env"))
            write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
            write(joinpath(envdir, "Manifest.toml"), manifest_text)

            env = load_environment(envdir; depots)
            @test env.manifest.manifest_format == loaded_format   # reads the old format

            # add upgrades the on-disk manifest to 2.1
            added = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            @test added.manifest.manifest_format == v"2.1.0"
            write_environment(env, added)
            raw = TOML.parsefile(joinpath(envdir, "Manifest.toml"))
            @test raw["manifest_format"] == "2.1"
            reloaded = load_environment(envdir; depots)
            @test reloaded.manifest.manifest_format == v"2.1.0"

            # a following rm keeps the manifest at 2.1
            removed = plan_rm(reloaded, [PackageRequest("Example")])
            @test removed.manifest.manifest_format == v"2.1.0"
            @test isempty(removed.manifest.deps)
        end
    end
end

# Pkg.jl manifests.jl "activating old environment: maintains old version, then
# ~`VERSION` after resolve" (line 216) — activating a v2.0 reference env keeps
# its recorded julia_version (1.7.0-DEV); a subsequent add flips it to
# dropbuild(VERSION).
@testset "activating old env keeps julia_version, add flips it" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        envdir = mkpath(joinpath(dir, "env"))
        write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "1.7.0-DEV"
            manifest_format = "2.0"

            [[deps.Example]]
            deps = ["Test"]
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            uuid = "$EXAMPLE_UUID"
            version = "0.5.1"

            [[deps.Test]]
            uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            """
        )

        env = load_environment(envdir; depots)
        @test env.manifest.julia_version == v"1.7.0-DEV"    # old version preserved on read

        added = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
        @test added.manifest.julia_version == dropbuild(VERSION)
    end
end

# ---------------------------------------------------------------------------
# API-level update_on_mismatch flows need the fixture pkg server + an active
# project (real install of Example), driven through ACTIVE_PROJECT/DEPOT_PATH.
function with_update_on_mismatch_world(f)
    LocalPkgServer.ensure!()
    return mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = API.AUTO_PRECOMPILE_ENABLED[]
        API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            f(dir, envdir)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

reloadenv(envdir) = load_environment(envdir; depots = depot_stack())

# Pkg.jl manifests.jl "manifest from a different julia minor version" (line 280)
# — without the flag `instantiate` warns and keeps the stale manifest; with
# `update_on_mismatch = true` it falls back to `up` and regenerates for the
# current julia version.
@testset "update_on_mismatch: julia minor version mismatch" begin
    with_update_on_mismatch_world() do dir, envdir
        VibePkg.add("Example"; io = devnull)
        mf = joinpath(envdir, "Manifest.toml")
        stamped = reloadenv(envdir).manifest.julia_version
        @test stamped == dropbuild(VERSION)

        # rewrite the manifest's julia_version to a different minor
        other = VersionNumber(VERSION.major, VERSION.minor == 0 ? 99 : VERSION.minor - 1, 0)
        write(mf, replace(read(mf, String), "julia_version = \"$stamped\"" => "julia_version = \"$other\""))
        @test reloadenv(envdir).manifest.julia_version == other
        @test !manifest_matches_project(reloadenv(envdir))

        # default: warns, stays stale
        @test_logs (:warn, r"was resolved with Julia .* running version is Julia") match_mode = :any VibePkg.instantiate(; io = devnull)
        @test reloadenv(envdir).manifest.julia_version == other

        # update_on_mismatch=true: falls back to update, becomes current
        VibePkg.instantiate(; update_on_mismatch = true, io = devnull)
        env = reloadenv(envdir)
        @test env.manifest.julia_version == dropbuild(VERSION)
        @test manifest_matches_project(env)
    end
end

# Pkg.jl manifests.jl "manifest stale due to compat change" (line 298) — after a
# conflicting compat change the default `instantiate` just warns and stays
# stale; `update_on_mismatch = true` falls back to update so the manifest
# becomes current (re-resolving Example down to the only compatible version).
@testset "update_on_mismatch: stale due to compat change" begin
    EX = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    with_update_on_mismatch_world() do dir, envdir
        VibePkg.add("Example"; io = devnull)
        @test entry_version(reloadenv(envdir).manifest[EX]) == v"0.5.5"

        # a compat entry that excludes the resolved version leaves the manifest
        # in place (conflict → not downgraded) but stale
        VibePkg.compat("Example", "=0.5.0"; io = devnull)
        @test entry_version(reloadenv(envdir).manifest[EX]) == v"0.5.5"
        @test !manifest_matches_project(reloadenv(envdir))

        # default: warns, stays stale
        @test_logs (:warn, r"does not match") match_mode = :any VibePkg.instantiate(; io = devnull)
        env = reloadenv(envdir)
        @test entry_version(env.manifest[EX]) == v"0.5.5"
        @test !manifest_matches_project(env)

        # update_on_mismatch=true: falls back to update, becomes current
        VibePkg.instantiate(; update_on_mismatch = true, io = devnull)
        env = reloadenv(envdir)
        @test entry_version(env.manifest[EX]) == v"0.5.0"
        @test manifest_matches_project(env)
    end
end

# Pkg.jl manifests.jl "no mismatch: update_on_mismatch=true is a no-op" (line
# 322) — when the manifest already matches, `instantiate(update_on_mismatch =
# true)` changes nothing and keeps installed versions.
@testset "update_on_mismatch: no-op when already current" begin
    EX = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    with_update_on_mismatch_world() do dir, envdir
        VibePkg.add("Example"; io = devnull)
        before = entry_version(reloadenv(envdir).manifest[EX])
        @test manifest_matches_project(reloadenv(envdir))
        VibePkg.instantiate(; update_on_mismatch = true, io = devnull)
        env = reloadenv(envdir)
        @test manifest_matches_project(env)
        @test entry_version(env.manifest[EX]) == before
    end
end

# Pkg.jl manifests.jl "undo reverts the fallback even as first op" (line 334) —
# if instantiate(update_on_mismatch=true) is the first op in a fresh session and
# triggers the fallback, the pre-update snapshot is saved so `undo` restores the
# earlier version.
@testset "undo reverts the update_on_mismatch fallback as first op" begin
    EX = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    with_update_on_mismatch_world() do dir, envdir
        VibePkg.add("Example"; io = devnull)
        VibePkg.compat("Example", "=0.5.0"; io = devnull)
        # simulate a fresh session: clear the per-project undo stacks
        empty!(API.UNDO_STACKS)
        version_pre = entry_version(reloadenv(envdir).manifest[EX])
        @test version_pre == v"0.5.5"

        VibePkg.instantiate(; update_on_mismatch = true, io = devnull)
        version_post = entry_version(reloadenv(envdir).manifest[EX])
        @test version_post == v"0.5.0"
        @test version_post != version_pre

        VibePkg.undo(; io = devnull)
        @test entry_version(reloadenv(envdir).manifest[EX]) == version_pre
    end
end

# Pkg.jl new.jl "relative depot path" — Base deliberately retains a relative
# JULIA_DEPOT_PATH entry. A cwd-relative repository add must therefore resolve
# both the package path and every depot write against the operation cwd.
@testset "relative JULIA_DEPOT_PATH supports a repository add" begin
    LibGit2 = VibePkg.Git.LibGit2
    pkg_uuid = UUID("de901234-5678-49ab-8cde-f0123456789a")
    mktempdir() do dir
        pkg = joinpath(dir, "BasicSandbox")
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "BasicSandbox"
            uuid = "$pkg_uuid"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "BasicSandbox.jl"), "module BasicSandbox\nend\n")
        repo = LibGit2.init(pkg)
        try
            LibGit2.add!(repo, ".")
            sig = LibGit2.Signature("fixture", "fixture@localhost")
            LibGit2.commit(repo, "initial"; author = sig, committer = sig)
        finally
            close(repo)
        end

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_depot_env = get(ENV, "JULIA_DEPOT_PATH", nothing)
        old_offline = API.OFFLINE_MODE[]
        try
            cd(dir) do
                ENV["JULIA_DEPOT_PATH"] = "relative-depot"
                Base.init_depot_path()
                @test Base.DEPOT_PATH == ["relative-depot"]
                API.OFFLINE_MODE[] = true
                envdir = mkpath(joinpath(dir, "env"))
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")

                VibePkg.add(VibePkg.PackageSpec(path = "BasicSandbox"); io = devnull)

                relative_depot = joinpath(dir, "relative-depot")
                @test isdir(joinpath(relative_depot, "clones"))
                @test isdir(joinpath(relative_depot, "packages", "BasicSandbox"))
                info = VibePkg.dependencies()[pkg_uuid]
                @test info.is_tracking_repo
                @test startswith(realpath(info.source), realpath(relative_depot))
                @test isfile(joinpath(envdir, "Manifest.toml"))
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            empty!(Base.DEPOT_PATH)
            append!(Base.DEPOT_PATH, old_depots)
            old_depot_env === nothing ? delete!(ENV, "JULIA_DEPOT_PATH") :
                (ENV["JULIA_DEPOT_PATH"] = old_depot_env)
            API.OFFLINE_MODE[] = old_offline
        end
    end
end
