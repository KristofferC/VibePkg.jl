# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg
using VibePkg: PackageSpec
using VibePkg.API: split_specs, to_request
using VibePkg.Planning: PackageRequest
using VibePkg.Errors: PkgError

@testset "PackageSpec shapes" begin
    # constructor forms and normalization
    @test PackageSpec("Example").name == "Example"
    @test PackageSpec("Example", v"1.2.3").version == v"1.2.3"
    @test PackageSpec(; uuid = "7876af07-990d-54b4-ab0e-23690620f79a").uuid ==
        UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    @test PackageSpec(; name = "Foo", version = "0.5").version == "0.5"

    # Pkg.jl#2587: uuid accepts a UUID, a String, or any AbstractString
    # (SubString), and defaults to nothing.
    let u = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        @test PackageSpec(; uuid = u).uuid === u
        @test PackageSpec(; uuid = "7876af07-990d-54b4-ab0e-23690620f79a").uuid == u
        @test PackageSpec(; uuid = SubString("x7876af07-990d-54b4-ab0e-23690620f79a", 2)).uuid == u
        @test PackageSpec(; uuid = UUID(0)).uuid == UUID(0)
    end
    @test PackageSpec().uuid === nothing
    @test PackageSpec(; uuid = nothing).uuid === nothing

    # Pkg.jl#4211: hash agrees with ==, so `unique` collapses equal specs
    let a = PackageSpec(; path = "foo"), b = PackageSpec(; path = "foo")
        @test a == b && hash(a) == hash(b)
        @test unique([a, b]) == [a]
    end

    # splitting registry vs repo-like specs, with input validation
    reqs, repo_like, name_rev = split_specs(
        [
            PackageSpec("Example"),
            PackageSpec(; url = "https://x.com/Foo.jl", rev = "main"),
            PackageSpec(; path = "../Bar"),
            PackageSpec(; name = "Bar", rev = "main"),
        ]
    )
    @test reqs == [PackageRequest("Example", nothing, nothing)]
    @test length(repo_like) == 2
    @test length(name_rev) == 1 && name_rev[1].rev == "main"
    @test_throws PkgError split_specs([PackageSpec(; url = "x", path = "y")])
    @test_throws PkgError split_specs([PackageSpec(; rev = "main")])
    @test_throws PkgError split_specs([PackageSpec(; version = "1")])

    # undo/redo stack mechanics on environment values
    let E = VibePkg.Environments.Environment,
            P = VibePkg.EnvFiles.Project, M = VibePkg.EnvFiles.Manifest
        pf = joinpath(mktempdir(), "Project.toml")
        mk(name) = E(
            pf, "M.toml",
            VibePkg.EnvFiles.with_project(P(); name), M(),
        )
        a, b = mk("A"), mk("B")
        VibePkg.API.record_undo!(a, b)
        VibePkg.API.snapshot_undo!(b)               # dedup: no new entry
        @test VibePkg.API.undo_redo_step!(b, -1).project.name == "A"
        @test VibePkg.API.undo_redo_step!(b, +1).project.name == "B"
        @test_throws PkgError VibePkg.API.undo_redo_step!(b, +1)
        c = mk("C")
        VibePkg.API.undo_redo_step!(b, -1)          # back to A...
        VibePkg.API.snapshot_undo!(c)               # ...new timeline drops redo
        @test_throws PkgError VibePkg.API.undo_redo_step!(c, +1)
        @test VibePkg.API.undo_redo_step!(c, -1).project.name == "A"
    end

    # every op accepts all six shapes (dispatch check only — no execution)
    for f in (
            VibePkg.add, VibePkg.develop, VibePkg.rm, VibePkg.up, VibePkg.pin,
            VibePkg.free, VibePkg.test, VibePkg.build,
        )
        @test hasmethod(f, Tuple{String})
        @test hasmethod(f, Tuple{Vector{String}})
        @test hasmethod(f, Tuple{PackageSpec})
        @test hasmethod(f, Tuple{Vector{PackageSpec}})
        @test hasmethod(f, Tuple{}) || f in (VibePkg.add,)   # kwarg form exists
        @test hasmethod(f, Tuple{Vector{NamedTuple{(:name,), Tuple{String}}}})
    end

    # Name-vector normalization is as generic as the scalar AbstractString
    # forms: SubString vectors and non-Vector views should not MethodError.
    substrings = split("Example Test")
    names_view = @view ["Example", "Test"][1:1]
    for f in (
            VibePkg.add, VibePkg.develop, VibePkg.rm, VibePkg.up, VibePkg.pin,
            VibePkg.free, VibePkg.test, VibePkg.build, VibePkg.precompile,
            VibePkg.status, VibePkg.why,
        )
        @test applicable(f, substrings)
        @test applicable(f, names_view)
    end
end

# Pkg's pinned input diagnostics
@testset "pinned entry diagnostics" begin
    msg(f) = try
        f(); "NO ERROR"
    catch e
        e isa PkgError ? e.msg : rethrow()
    end

    @test msg(() -> VibePkg.add(name = "julia")) == "`julia` is not a valid package name"
    @test msg(() -> VibePkg.add("***")) == "`***` is not a valid package name"
    @test msg(() -> VibePkg.add("https://github.com")) ==
        "`https://github.com` is not a valid package name\nThe argument appears to be a URL or path, perhaps you meant `Pkg.add(url=\"...\")` or `Pkg.add(path=\"...\")`."
    @test msg(() -> VibePkg.API.check_package_name("Example.jl")) ==
        "`Example.jl` is not a valid package name. Perhaps you meant `Example`"
    @test msg(() -> VibePkg.add(PackageSpec())) ==
        "name, UUID, URL, or filesystem path specification required when calling `add`"
    @test msg(() -> VibePkg.add(name = "Example", rev = "master", version = "0.5.0")) ==
        "version specification invalid when tracking a repository: `0.5.0` specified for package `Example`"
    @test msg(() -> VibePkg.add(PackageSpec[])) == "add requires at least one package"
    @test msg(() -> VibePkg.develop(name = "Example", rev = "master")) ==
        "rev argument not supported by `develop`; consider using `add` instead"
    @test msg(() -> VibePkg.develop(name = "Example", version = "0.5.0")) ==
        "version specification invalid when calling `develop`: `0.5.0` specified for package `Example`"
    @test msg(() -> VibePkg.add(["Example", "Example"])) ==
        "it is invalid to specify multiple packages with the same name: `Example`"
    let u = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        @test msg(() -> VibePkg.add([PackageSpec(; name = "A", uuid = u), PackageSpec(; name = "B", uuid = u)])) ==
            "it is invalid to specify multiple packages with the same UUID: `A [7876af07]`"
    end

    # Pkg.jl#901: AbstractString names (e.g. SubString) dispatch like String
    @test msg(() -> VibePkg.add(strip(" *** "))) == "`***` is not a valid package name"
    @test msg(() -> VibePkg.add(split("*** ***"))) == "`***` is not a valid package name"

    # Pkg.jl#1345: a uuid-only spec for an unknown package errors early and clearly
    mktempdir() do dir
        old = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = joinpath(dir, "Project.toml")
        try
            withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_OFFLINE" => "true") do
                u = UUID("deadbeef-dead-beef-dead-beefdeadbeef")
                @test occursin(
                    "cannot find name corresponding to UUID $u",
                    msg(() -> VibePkg.add(VibePkg.PackageSpec(; uuid = u); io = devnull))
                )
            end
        finally
            Base.ACTIVE_PROJECT[] = old
        end
    end

    # `pathrepr` contracts stdlib paths
    @test VibePkg.Display.pathrepr(joinpath(Sys.STDLIB, "Test")) == "`@stdlib/Test`"
end
