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
using VibePkg.Environments
using VibePkg.Planning
using VibePkg.Planning: PackageRequest
using VibePkg.EnvFiles: entry_version, is_path_tracked, is_registry_tracked
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
            @test_logs (:warn, "`Bogus` not in project, ignoring") VibePkg.rm("Bogus"; io = buf)
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
            @test occursin("julia version requirement", err.msg)
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
            @test occursin("yanked", out) && occursin("Example", out)
        end
    end
end

# Pkg.jl pkg.jl "Suggest `Pkg.develop` instead of `Pkg.add`" — adding a bare
# local path (a directory that is not an installable registered package) errors
# rather than silently doing the wrong thing.
@testset "add of a bare local path errors" begin
    mktempdir() do dir
        touch(joinpath(dir, "Project.toml"))
        @test_throws PkgError VibePkg.add(; path = dir, io = devnull)
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
            @test_throws PkgError plan_resolve(env, regs, Config(depots))
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
