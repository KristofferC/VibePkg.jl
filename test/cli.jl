# depot isolation + hermeticity guard for the whole process
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using TOML
using VibePkg
using VibePkg.REPLMode
using VibePkg.Utils: DEFAULT_IO

@testset "vpkg app CLI" begin
    project = TOML.parsefile(joinpath(pkgdir(VibePkg), "Project.toml"))
    @test haskey(project, "apps")
    @test haskey(project["apps"], "vpkg")

    # The app load path must not make VibePkg's own project the target. With
    # no explicit project, use the nearest project from the caller's cwd.
    old_active = Base.ACTIVE_PROJECT[]
    try
        mktempdir() do dir
            project_file = joinpath(dir, "Project.toml")
            write(project_file, "name = \"CallerProject\"\n")
            nested = mkpath(joinpath(dir, "src", "nested"))
            Base.set_active_project(nothing)
            cd(nested) do
                VibePkg.select_cli_project!()
                # macOS may canonicalize /var to /private/var here
                @test samefile(Base.active_project(), project_file)
            end

            # An explicit --project/JULIA_PROJECT selection stays selected.
            explicit = joinpath(mkpath(joinpath(dir, "explicit")), "Project.toml")
            write(explicit, "name = \"ExplicitProject\"\n")
            Base.set_active_project(explicit)
            cd(nested) do
                VibePkg.select_cli_project!()
                @test Base.active_project() == explicit
            end
        end

        mktempdir() do empty_dir
            Base.set_active_project(nothing)
            cd(empty_dir) do
                VibePkg.select_cli_project!()
                @test Base.ACTIVE_PROJECT[] == "@v#.#"
                @test occursin("environments", Base.active_project())
            end
        end
    finally
        Base.set_active_project(old_active)
    end

    # A shell has already separated arguments. Keep each one intact rather
    # than joining and reparsing it as a REPL command string.
    REPLMode.TEST_MODE[] = true
    try
        calls = REPLMode.do_cmd(["dev", "./Package With Spaces;StillOne"])
        api, args, opts = only(calls)
        @test api === VibePkg.API.develop
        @test args == Any[[VibePkg.PackageSpec(; path = "./Package With Spaces;StillOne")]]
        @test isempty(opts)
    finally
        REPLMode.TEST_MODE[] = false
    end

    output = IOBuffer()
    code = Base.ScopedValues.with(DEFAULT_IO => output) do
        VibePkg.main(["--help"])
    end
    @test code == 0
    @test occursin("VibePkg commands", String(take!(output)))

    output = IOBuffer()
    code = withenv("JULIA_PKG_OFFLINE" => "true") do
        Base.ScopedValues.with(DEFAULT_IO => output) do
            VibePkg.main(["status"])
        end
    end
    @test code == 0
    @test occursin("Status", String(take!(output)))

    output = IOBuffer()
    code = Base.ScopedValues.with(DEFAULT_IO => output) do
        VibePkg.main(["not-a-command"])
    end
    @test code == 1
    @test occursin("ERROR: Unknown command \"not-a-command\". Type ? to list available commands", String(take!(output)))
end
