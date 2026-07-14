# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg
using VibePkg.Stdlibs: stdlib_version
using VibePkg.Planning: check_stdlib_compat
using VibePkg.EnvFiles: read_project
using VibePkg.Versions: semver_spec, VersionSpec

# Pkg.jl stdlib_compat.jl "Non-upgradable stdlib compat handling" — a project
# whose `[compat]` pins a non-upgradable standard library to a range that
# excludes the version shipped with the running Julia does not error; instead
# the entry is ignored (relaxed to "*") with a loud warning telling the user
# how to fix it.
@testset "Non-upgradable stdlib compat handling" begin
    libcurl = UUID("b27032c2-a3e7-50c8-80cd-2d36dbcbfd21")
    ver = stdlib_version(libcurl, VERSION)
    @test ver !== nothing                                   # LibCURL is versioned
    # a compat one minor above the shipped version always excludes it
    higher = "$(ver.major).$(ver.minor + 1)"
    @test !(ver in semver_spec(higher))

    mktempdir() do dir
        pf = joinpath(dir, "Project.toml")
        write(
            pf, """
            name = "TestProject"
            uuid = "12345678-1234-1234-1234-123456789012"

            [deps]
            LibCURL = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"

            [compat]
            LibCURL = "$higher"
            """
        )
        proj = read_project(pf)
        local relaxed
        @test_logs (:warn, r"Ignoring incompatible compat entry") match_mode = :any begin
            relaxed = check_stdlib_compat("LibCURL", libcurl, semver_spec(higher), proj, pf, VERSION)
        end
        @test relaxed == VersionSpec("*")   # relaxed, not errored

        # a compat that *does* include the shipped version is left untouched
        ok = "$(ver.major).$(ver.minor)"
        @test check_stdlib_compat("LibCURL", libcurl, semver_spec(ok), proj, pf, VERSION) ==
            semver_spec(ok)
    end
end
