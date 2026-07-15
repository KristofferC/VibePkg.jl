# Pkg.jl pkg.jl "testing" — coverage=true must do more than reach the flag
# builder: the public test operation runs a real test subprocess and leaves
# Julia's line-coverage file next to the tracked package source.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
import VibePkg

const COVERAGE_FIXTURE_UUID = "cacacaca-1111-2222-3333-444444444444"

@testset "Pkg.test coverage=true emits .cov files" begin
    mktempdir() do dir
        pkg = joinpath(dir, "CoverageFixture")
        src = mkpath(joinpath(pkg, "src"))
        tests = mkpath(joinpath(pkg, "test"))
        project_file = joinpath(pkg, "Project.toml")
        source_file = joinpath(src, "CoverageFixture.jl")
        write(
            project_file,
            "name = \"CoverageFixture\"\nuuid = \"$COVERAGE_FIXTURE_UUID\"\nversion = \"0.1.0\"\n",
        )
        write(
            source_file,
            "module CoverageFixture\ncovered_branch(x) = x ? 42 : 0\nend\n",
        )
        write(
            joinpath(tests, "runtests.jl"),
            "using CoverageFixture\nCoverageFixture.covered_branch(true) == 42 || error(\"bad result\")\n",
        )

        old_project = Base.ACTIVE_PROJECT[]
        try
            Base.ACTIVE_PROJECT[] = project_file
            result = withenv(
                "JULIA_PKG_OFFLINE" => "true",
                "JULIA_PKG_PRECOMPILE_AUTO" => "0",
            ) do
                VibePkg.test(; coverage = true, io = devnull)
            end
            @test result === nothing
        finally
            Base.ACTIVE_PROJECT[] = old_project
        end

        coverage_files = String[]
        for (root, _, files) in walkdir(pkg), file in files
            endswith(file, ".cov") && push!(coverage_files, joinpath(root, file))
        end
        @test !isempty(coverage_files)
        @test any(coverage_files) do file
            dirname(file) == src && startswith(basename(file), basename(source_file))
        end
    end
end

# Pkg.jl pkg.jl "coverage specific path" — a String coverage argument must
# drive the public test operation all the way through its subprocess and write
# populated LCOV output at exactly the requested path.
@testset "Pkg.test coverage=tracefile emits populated LCOV" begin
    mktempdir() do dir
        pkg = joinpath(dir, "CoverageTracefileFixture")
        src = mkpath(joinpath(pkg, "src"))
        tests = mkpath(joinpath(pkg, "test"))
        project_file = joinpath(pkg, "Project.toml")
        source_file = joinpath(src, "CoverageTracefileFixture.jl")
        tracefile = joinpath(dir, "requested-tracefile.info")
        write(
            project_file,
            "name = \"CoverageTracefileFixture\"\nuuid = \"$COVERAGE_FIXTURE_UUID\"\nversion = \"0.1.0\"\n",
        )
        write(
            source_file,
            "module CoverageTracefileFixture\ncovered_branch(x) = x ? 42 : 0\nend\n",
        )
        write(
            joinpath(tests, "runtests.jl"),
            "using CoverageTracefileFixture\nCoverageTracefileFixture.covered_branch(true) == 42 || error(\"bad result\")\n",
        )

        old_project = Base.ACTIVE_PROJECT[]
        try
            Base.ACTIVE_PROJECT[] = project_file
            result = withenv(
                "JULIA_PKG_OFFLINE" => "true",
                "JULIA_PKG_PRECOMPILE_AUTO" => "0",
            ) do
                VibePkg.test(; coverage = tracefile, io = devnull)
            end
            @test result === nothing
        finally
            Base.ACTIVE_PROJECT[] = old_project
        end

        @test isfile(tracefile)
        @test filesize(tracefile) > 0
        lcov = read(tracefile, String)
        source_paths = [line[4:end] for line in eachline(IOBuffer(lcov)) if startswith(line, "SF:")]
        @test any(
            path -> isfile(path) && Base.Filesystem.samefile(path, source_file),
            source_paths,
        )
        @test occursin(r"(?m)^DA:\d+,[1-9]\d*", lcov)
        @test occursin(r"(?m)^end_of_record$", lcov)
    end
end
