# Public integration coverage for the remaining develop and explicit-depot
# registry partials from Pkg.jl's new.jl / registry.jl tests.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.ensure!()

using Test
using Base: UUID
using Dates: Dates
using VibePkg
using VibePkg.Depots: depot_stack
using VibePkg.EnvFiles: entry_path, read_manifest
using VibePkg.Registries: reachable_registries

const DR_EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
const DR_A_UUID = UUID("0829fd7c-1e7e-4927-9afa-b8c61d5e0e42")
const DR_B_UUID = UUID("dd0d8fba-d7c4-4f8e-a2bb-3a090b3e34f1")
const DR_C_UUID = UUID("4ee78ca3-4e78-462f-a078-747ed543fa85")
const DR_D_UUID = UUID("bf733257-898a-45a0-b2f2-c1c188bdd879")

function with_develop_public_env(f, project_file::String, depot::String)
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
    stack = [depot; Base.append_bundled_depot_path!(String[])]
    sep = Sys.iswindows() ? ';' : ':'
    try
        Base.ACTIVE_PROJECT[] = project_file
        copy!(Base.DEPOT_PATH, stack)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        return withenv(f, "JULIA_DEPOT_PATH" => join(stack, sep))
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depots)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
    end
end

@testset "public develop by registered name, uuid, url, shared and local" begin
    fixture = LocalPkgServer.ensure!()
    cases = [
        ("name-shared", true, () -> VibePkg.develop("Example"; io = devnull)),
        ("name-local", false, () -> VibePkg.develop("Example"; shared = false, io = devnull)),
        ("uuid-shared", true, () -> VibePkg.develop(; uuid = DR_EXAMPLE_UUID, io = devnull)),
        ("url-shared", true, () -> VibePkg.develop(; url = fixture.git_repo, io = devnull)),
    ]

    mktempdir() do dir
        for (label, shared, operation) in cases
            depot = mkpath(joinpath(dir, label, "depot"))
            envdir = mkpath(joinpath(dir, label, "env"))
            project_file = joinpath(envdir, "Project.toml")
            write(project_file, "")
            VibePkg.Registry.add("General"; depots = depot, io = devnull)

            with_develop_public_env(project_file, depot) do
                @test operation() === nothing
                info = VibePkg.dependencies()[DR_EXAMPLE_UUID]
                expected = shared ? joinpath(depot, "dev", "Example") :
                    joinpath(envdir, "dev", "Example")
                @test info.name == "Example"
                @test info.is_tracking_path && !info.is_tracking_registry
                @test samefile(info.source, expected)
                @test VibePkg.project().dependencies["Example"] == DR_EXAMPLE_UUID
            end
        end
    end
end

function write_develop_package(path, name, uuid; deps = Pair{String, UUID}[])
    mkpath(joinpath(path, "src"))
    dep_text = isempty(deps) ? "" :
        "\n[deps]\n" * join(("$name = \"$uuid\"" for (name, uuid) in deps), "\n") * "\n"
    write(
        joinpath(path, "Project.toml"),
        "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n" * dep_text,
    )
    write(joinpath(path, "src", "$name.jl"), "module $name\nend\n")
    return path
end

@testset "public recursive develop follows nested dev manifests" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        VibePkg.Registry.add("General"; depots = depot, io = devnull)
        envdir = mkpath(joinpath(dir, "env"))
        project_file = joinpath(envdir, "Project.toml")
        write(project_file, "")

        a = write_develop_package(
            joinpath(dir, "A"), "A", DR_A_UUID;
            deps = ["B" => DR_B_UUID, "C" => DR_C_UUID],
        )
        b = write_develop_package(joinpath(a, "dev", "B"), "B", DR_B_UUID)
        c = write_develop_package(
            joinpath(a, "dev", "C"), "C", DR_C_UUID;
            deps = ["D" => DR_D_UUID],
        )
        d = write_develop_package(joinpath(a, "dev", "D"), "D", DR_D_UUID)
        write(
            joinpath(a, "Manifest.toml"), """
            manifest_format = "2.1"

            [[deps.B]]
            path = "dev/B"
            uuid = "$DR_B_UUID"
            version = "0.1.0"

            [[deps.C]]
            deps = ["D"]
            path = "dev/C"
            uuid = "$DR_C_UUID"
            version = "0.1.0"

            [[deps.D]]
            path = "dev/D"
            uuid = "$DR_D_UUID"
            version = "0.1.0"
            """,
        )
        write(
            joinpath(c, "Manifest.toml"), """
            manifest_format = "2.1"

            [[deps.D]]
            path = "../D"
            uuid = "$DR_D_UUID"
            version = "0.1.0"
            """,
        )

        with_develop_public_env(project_file, depot) do
            @test VibePkg.develop(; path = a, io = devnull) === nothing
            infos = VibePkg.dependencies()
            @test Set(keys(infos)) == Set([DR_A_UUID, DR_B_UUID, DR_C_UUID, DR_D_UUID])
            @test haskey(infos[DR_A_UUID].dependencies, "B")
            @test haskey(infos[DR_A_UUID].dependencies, "C")
            @test haskey(infos[DR_C_UUID].dependencies, "D")
            @test samefile(infos[DR_A_UUID].source, a)
            @test samefile(infos[DR_B_UUID].source, b)
            @test samefile(infos[DR_C_UUID].source, c)
            @test samefile(infos[DR_D_UUID].source, d)
        end
    end
end

@testset "public develop with a relative primary depot" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_depot_env = get(ENV, "JULIA_DEPOT_PATH", nothing)
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
    try
        mktempdir() do dir
            cd(dir) do
                ENV["JULIA_DEPOT_PATH"] = "relative-depot"
                Base.init_depot_path()
                @test Base.DEPOT_PATH == ["relative-depot"]
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
                VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
                envdir = mkpath(joinpath(dir, "env"))
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")

                @test VibePkg.develop("Example"; io = devnull) === nothing
                expected = abspath("relative-depot", "dev", "Example")
                info = VibePkg.dependencies()[DR_EXAMPLE_UUID]
                @test samefile(info.source, expected)
                @test isabspath(entry_path(read_manifest(joinpath(envdir, "Manifest.toml"))[DR_EXAMPLE_UUID]))
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depots)
        old_depot_env === nothing ? delete!(ENV, "JULIA_DEPOT_PATH") :
            (ENV["JULIA_DEPOT_PATH"] = old_depot_env)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
    end
end

@testset "public Registry explicit off-path depots and cooldown" begin
    mktempdir() do dir
        on_path = mkpath(joinpath(dir, "on-path"))
        off_path = mkpath(joinpath(dir, "off-path"))
        @test isempty(reachable_registries(depot_stack([on_path])))
        @test isempty(reachable_registries(depot_stack([off_path])))

        @test VibePkg.Registry.add("General"; depots = off_path, io = devnull) === nothing
        @test isempty(reachable_registries(depot_stack([on_path])))
        @test length(reachable_registries(depot_stack([off_path]))) == 1

        uuid = UUID(LocalPkgServer.GENERAL_UUID)
        old_stamp = Dates.now() - Dates.Hour(1)
        VibePkg.Registries.save_registry_update_log(
            off_path, Dict{String, Any}(string(uuid) => old_stamp),
        )
        VibePkg.Registry.update(
            ; depots = [off_path], update_cooldown = Dates.Day(1), io = devnull,
        )
        @test VibePkg.Registries.read_registry_update_log(off_path)[string(uuid)] == old_stamp

        io = IOBuffer()
        @test VibePkg.Registry.update(
            ; depots = [off_path], update_cooldown = Dates.Second(0), io,
        ) === nothing
        output = String(take!(io))
        @test occursin("registry at `$(Base.contractuser(off_path))", output)
        @test VibePkg.Registries.read_registry_update_log(off_path)[string(uuid)] > old_stamp

        envdir = mkpath(joinpath(dir, "env"))
        project_file = joinpath(envdir, "Project.toml")
        write(project_file, "")
        with_develop_public_env(project_file, off_path) do
            @test VibePkg.add("Example"; io = devnull) === nothing
            @test haskey(VibePkg.dependencies(), DR_EXAMPLE_UUID)
        end
    end
end
