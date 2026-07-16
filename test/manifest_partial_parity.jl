# Public integration coverage for the remaining Pkg.jl manifests.jl partials:
# activation-style format fixtures, metadata/julia-version transitions, the
# instantiate-time stale warning and update fallback, and syntax-version
# fallback recorded after a real develop operation.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg
using VibePkg.Depots: depot_stack
using VibePkg.Environments: load_environment, is_manifest_current
using VibePkg.EnvFiles: parse_project, read_manifest
using VibePkg.Planning: dropbuild, get_project_syntax_version
import TOML

const MP_DATES_UUID = UUID("ade2ca70-3891-5945-98fb-dc099432e06a")
const MP_PROFILE_UUID = UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79")

function with_manifest_public_env(f, project_file::String, depot::String)
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
    stack = [depot; Base.append_bundled_depot_path!(String[])]
    sep = Sys.iswindows() ? ';' : ':'
    try
        Base.ACTIVE_PROJECT[] = project_file
        copy!(Base.DEPOT_PATH, stack)
        VibePkg.API.OFFLINE_MODE[] = true
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        return withenv(f, "JULIA_DEPOT_PATH" => join(stack, sep), "JULIA_PKG_OFFLINE" => "true")
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
    end
end

@testset "activation-style manifest format and julia_version fixture" begin
    manifests = [
        (
            "v1.0", v"1.0.0", nothing,
            """
            [[Dates]]
            uuid = "$MP_DATES_UUID"
            """,
        ),
        (
            "v2.0", v"2.0.0", v"1.7.0-DEV",
            """
            julia_version = "1.7.0-DEV"
            manifest_format = "2.0"
            some_other_field = "preserved"

            [[deps.Dates]]
            uuid = "$MP_DATES_UUID"
            """,
        ),
        (
            "v2.1", v"2.1.0", v"1.7.0-DEV",
            """
            julia_version = "1.7.0-DEV"
            manifest_format = "2.1"
            some_other_field = "preserved"

            [[deps.Dates]]
            uuid = "$MP_DATES_UUID"
            """,
        ),
    ]

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        for (label, format, old_julia, manifest_text) in manifests
            envdir = mkpath(joinpath(dir, label))
            project_file = joinpath(envdir, "Project.toml")
            manifest_file = joinpath(envdir, "Manifest.toml")
            write(project_file, "[deps]\nDates = \"$MP_DATES_UUID\"\n")
            write(manifest_file, manifest_text)

            with_manifest_public_env(project_file, depot) do
                io = IOBuffer()
                VibePkg.activate(envdir; io)
                @test occursin("Activating", String(take!(io)))
                @test samefile(Base.active_project(), project_file)

                activated = load_environment(; depots = depot_stack())
                @test activated.manifest.manifest_format == format
                @test activated.manifest.julia_version == old_julia
                label == "v1.0" || @test activated.manifest.raw["some_other_field"] == "preserved"

                # A public resolving operation upgrades old formats and stamps
                # the running Julia while retaining arbitrary v2 metadata.
                @test VibePkg.add("Profile"; io = devnull) === nothing
                upgraded = read_manifest(manifest_file)
                @test upgraded.manifest_format == v"2.1.0"
                @test upgraded.julia_version == dropbuild(VERSION)
                @test haskey(upgraded, MP_PROFILE_UUID)
                label == "v1.0" || @test upgraded.raw["some_other_field"] == "preserved"
            end
        end
    end
end

@testset "project syntax version fallback and public develop fixup" begin
    default_project = VibePkg.EnvFiles.Project()
    @test get_project_syntax_version(default_project) == dropbuild(VERSION)

    explicit = parse_project(TOML.parse("[syntax]\njulia_version = \"1.9.2\"\n"))
    @test get_project_syntax_version(explicit) == v"1.9.2"

    compat = parse_project(TOML.parse("[compat]\njulia = \"1.6\"\n"))
    @test get_project_syntax_version(compat) == v"1.6.0"

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        project_file = joinpath(envdir, "Project.toml")
        write(project_file, "")

        packages = [
            ("DefaultSyntax", UUID("56565656-5656-4656-8656-565656565656"), ""),
            (
                "ExplicitSyntax", UUID("78787878-7878-4878-8878-787878787878"),
                "\n[syntax]\njulia_version = \"1.9.2\"\n",
            ),
        ]
        for (name, uuid, extra) in packages
            pkg = mkpath(joinpath(dir, name))
            mkpath(joinpath(pkg, "src"))
            write(
                joinpath(pkg, "Project.toml"),
                "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n" * extra,
            )
            write(joinpath(pkg, "src", "$name.jl"), "module $name end\n")
        end

        with_manifest_public_env(project_file, depot) do
            VibePkg.develop(
                [
                    VibePkg.PackageSpec(path = joinpath(dir, "DefaultSyntax")),
                    VibePkg.PackageSpec(path = joinpath(dir, "ExplicitSyntax")),
                ]; io = devnull,
            )
            manifest_file = joinpath(envdir, "Manifest.toml")
            manifest = read_manifest(manifest_file)
            @test manifest[packages[1][2]].julia_syntax_version == dropbuild(VERSION)
            @test manifest[packages[2][2]].julia_syntax_version == v"1.9.2"

            raw = TOML.parsefile(manifest_file)
            @test raw["deps"]["DefaultSyntax"][1]["syntax"]["julia_version"] ==
                string(dropbuild(VERSION))
            @test raw["deps"]["ExplicitSyntax"][1]["syntax"]["julia_version"] == "1.9.2"
        end
    end
end

@testset "instantiate stale warning and update_on_mismatch fallback" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        project_file = joinpath(envdir, "Project.toml")
        manifest_file = joinpath(envdir, "Manifest.toml")
        write(project_file, "[compat]\njulia = \"1\"\n")
        write(
            manifest_file, """
            julia_version = "$(dropbuild(VERSION))"
            manifest_format = "2.1"
            project_hash = "0000000000000000000000000000000000000000"
            """,
        )
        before = read(manifest_file)
        expected =
            "The project dependencies or compat requirements have changed since the manifest was last resolved.\n" *
            "It is recommended to `VibePkg.resolve()` or consider `VibePkg.update()` if necessary."

        with_manifest_public_env(project_file, depot) do
            @test is_manifest_current(load_environment(; depots = depot_stack())) === false
            status_io = IOBuffer()
            @test VibePkg.status(; io = status_io) === nothing
            @test occursin(
                "project dependencies or compat requirements have changed since the manifest was last resolved",
                String(take!(status_io)),
            )
            @test_logs (:warn, expected) VibePkg.instantiate(; manifest = true, io = devnull)
            @test read(manifest_file) == before

            # The public fallback resolves the stale metadata and records a
            # current hash even for an otherwise empty environment.
            @test VibePkg.instantiate(
                ; manifest = true, update_on_mismatch = true, io = devnull,
            ) === nothing
            @test is_manifest_current(load_environment(; depots = depot_stack())) === true
        end
    end
end
