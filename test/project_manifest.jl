# Pkg.jl project_manifest.jl — a "project-as-manifest" monorepo (no [workspace];
# each subpackage points `manifest = "../../Manifest.toml"` at the shared root
# manifest). Resolving/dev'ing inside a subpackage accumulates entries in the
# root manifest. Fully hermetic: only local subpackages + the Test stdlib.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg
using VibePkg.EnvFiles: read_manifest

const B_UUID = UUID("dd0d8fba-d7c4-4f8e-a2bb-3a090b3e34f2")
const C_UUID = UUID("4ee78ca3-4e78-462f-a078-747ed543fa86")
const D_UUID = UUID("bf733257-898a-45a0-b2f2-c1c188bdd870")
const TEST_UUID = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

function make_monorepo(root)
    mkpath(joinpath(root, "src"))
    mkpath(joinpath(root, "test"))
    write(joinpath(root, "Project.toml"), "name = \"A\"\nuuid = \"0829fd7c-1e7e-4927-9afa-b8c61d5e0e42\"\nversion = \"0.0.0\"\n\n[deps]\n")
    write(joinpath(root, "src", "A.jl"), "module A\nusing B, C\ntest() = true\ntestC() = C.test()\nend\n")
    write(joinpath(root, "test", "runtests.jl"), "using Test, A\n@test A.test()\n@test A.testC()\n")
    sub(name, uuid, body) = begin
        p = mkpath(joinpath(root, "packages", name))
        mkpath(joinpath(p, "src"))
        write(joinpath(p, "Project.toml"), body)
        write(joinpath(p, "src", "$name.jl"), "module $name\ntest() = true\nend\n")
        p
    end
    sub("B", B_UUID, "name = \"B\"\nuuid = \"$B_UUID\"\nversion = \"0.0.0\"\nmanifest = \"../../Manifest.toml\"\n")
    c = sub("C", C_UUID, "name = \"C\"\nuuid = \"$C_UUID\"\nversion = \"0.0.0\"\nmanifest = \"../../Manifest.toml\"\n\n[deps]\nTest = \"$TEST_UUID\"\n")
    mkpath(joinpath(c, "test"))
    write(joinpath(c, "test", "runtests.jl"), "using Test, C\n@test C.test()\n")
    sub("D", D_UUID, "name = \"D\"\nuuid = \"$D_UUID\"\nversion = \"0.0.0\"\nmanifest = \"../../Manifest.toml\"\n")
    return root
end

# run `f` with `proj` active and the depot stack (incl. env, for the test
# sandbox subprocess) pointed at `depot` plus the bundled stdlibs.
function with_env(f, proj, depot)
    old = Base.ACTIVE_PROJECT[]
    olddp = copy(Base.DEPOT_PATH)
    oldgate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    stack = [depot; Base.append_bundled_depot_path!(String[])]
    sep = Sys.iswindows() ? ';' : ':'
    try
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true   # no network registry update
        Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")
        copy!(Base.DEPOT_PATH, stack)
        # only local + stdlib deps, so stay offline (no registry/server needed)
        return withenv(f, "JULIA_DEPOT_PATH" => join(stack, sep), "JULIA_PKG_OFFLINE" => "true")
    finally
        Base.ACTIVE_PROJECT[] = old
        copy!(Base.DEPOT_PATH, olddp)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldgate
    end
end

@testset "project-as-manifest monorepo" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        root = make_monorepo(joinpath(dir, "monorepo"))
        rootmanifest = joinpath(root, "Manifest.toml")
        c = joinpath(root, "packages", "C")

        # Establish B as a root dependency first. The later subpackage-C
        # operation must accumulate into this same manifest without pruning B.
        with_env(root, depot) do
            VibePkg.develop(; path = joinpath(root, "packages", "B"), io = devnull)
        end

        # develop the local D from inside subpackage C, then run C's tests.
        # Resolution/dev inside a subpackage writes to the SHARED root manifest
        # (the `manifest = "../../Manifest.toml"` key), and the subpackage never
        # gets a manifest of its own.
        with_env(c, depot) do
            VibePkg.develop(; path = joinpath(root, "packages", "D"), io = devnull)
            developed_manifest = read_manifest(rootmanifest)
            @test haskey(developed_manifest[C_UUID].deps, "D")
            @test VibePkg.test(io = devnull) === nothing        # C's tests run + pass
        end

        @test isfile(rootmanifest)                              # shared root manifest
        @test !isfile(joinpath(c, "Manifest.toml"))             # not a per-subpackage one
        m = read_manifest(rootmanifest)
        @test haskey(m, B_UUID)                                 # pre-existing root dep retained
        @test haskey(m, C_UUID)                                 # the tested subpackage
        @test haskey(m, D_UUID)                                 # its freshly dev'd local dep
        @test haskey(m[C_UUID].deps, "D")                       # C → D recorded
        @test haskey(m[C_UUID].deps, "Test")                    # C's own declared dep tracked

        # Make C a root dependency before adding Test, matching the upstream
        # order that makes C/D's accumulated shared-manifest state sticky;
        # then run the root package's real public test subprocess.
        with_env(root, depot) do
            VibePkg.develop(; path = c, io = devnull)
            VibePkg.add("Test"; io = devnull)
            @test VibePkg.test(io = devnull) === nothing
        end
        m = read_manifest(rootmanifest)
        @test all(haskey(m, uuid) for uuid in (B_UUID, C_UUID, D_UUID))

        # Upstream documents its stale D entry as #3590 with @test_broken.
        # VibePkg resolves the shared root after removal, so pin the desired
        # public behavior: C loses its edge and the now-unreachable D entry is
        # actually pruned from the shared manifest.
        with_env(c, depot) do
            VibePkg.rm("D"; io = devnull)
            @test VibePkg.test(io = devnull) === nothing
        end
        m = read_manifest(rootmanifest)
        @test !haskey(m, D_UUID)
        @test !haskey(m, C_UUID) || !haskey(m[C_UUID].deps, "D")
    end
end

# is_manifest_current must compare a deved package's declared strong and weak
# dependency maps against its manifest entry in BOTH directions: a dep removed
# from (or moved to [weakdeps] in) the deved package's Project.toml makes the
# manifest as stale as a newly added one does.
@testset "is_manifest_current compares deved dep maps bidirectionally" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        e = joinpath(dir, "E")
        mkpath(joinpath(e, "src"))
        euuid = "9e2ebf1a-4d2e-4d54-96f6-9d6ee1a1a4d4"
        eproj(body) = write(
            joinpath(e, "Project.toml"),
            "name = \"E\"\nuuid = \"$euuid\"\nversion = \"0.1.0\"\n" * body,
        )
        eproj("\n[deps]\nTest = \"$TEST_UUID\"\n")
        write(joinpath(e, "src", "E.jl"), "module E\nend\n")

        proj = mkpath(joinpath(dir, "proj"))
        with_env(proj, depot) do
            VibePkg.develop(; path = e, io = devnull)
            depots = VibePkg.Depots.depot_stack()
            env = VibePkg.Environments.load_environment(proj; depots)
            current() = VibePkg.Environments.is_manifest_current(env)
            @test current() === true

            # a dep removed from the deved package's Project.toml: stale
            eproj("")
            @test current() === false

            # the dep moved from [deps] to [weakdeps]: stale
            eproj("\n[weakdeps]\nTest = \"$TEST_UUID\"\n")
            @test current() === false

            # restored to the resolved state: current again
            eproj("\n[deps]\nTest = \"$TEST_UUID\"\n")
            @test current() === true
        end
    end
end
