# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using VibePkg

@testset "why" begin
    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"), """
            [deps]
            A = "aaaaaaa1-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            """
        )
        write(
            joinpath(dir, "Manifest.toml"), """
            julia_version = "1.12.0"
            manifest_format = "2.1"

            [[deps.A]]
            deps = ["B", "D"]
            uuid = "aaaaaaa1-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            version = "1.0.0"

            [[deps.B]]
            deps = ["C"]
            uuid = "bbbbbbb1-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            version = "1.0.0"

            [[deps.C]]
            uuid = "ccccccc1-cccc-cccc-cccc-cccccccccccc"
            version = "1.0.0"

            [[deps.D]]
            deps = ["B"]
            uuid = "ddddddd1-dddd-dddd-dddd-dddddddddddd"
            version = "1.0.0"
            """
        )
        old = Base.ACTIVE_PROJECT[]
        try
            Base.ACTIVE_PROJECT[] = joinpath(dir, "Project.toml")
            # B's sub-tree is expanded under the first branch only; the
            # second occurrence collapses to `B (*)`
            @test sprint(io -> VibePkg.why("C"; io)) == """
                  A
                  ├─ B
                  │  └─▶ C
                  └─ D
                     └─ B (*)
                """
            # a repeated leaf elides nothing, so no `(*)`, and every
            # occurrence of the queried package gets the arrowhead
            @test sprint(io -> VibePkg.why("B"; io)) == """
                  A
                  ├─▶ B
                  └─ D
                     └─▶ B
                """
            @test_throws VibePkg.PkgError VibePkg.why("Nope"; io = devnull)
        finally
            Base.ACTIVE_PROJECT[] = old
        end
    end
end
