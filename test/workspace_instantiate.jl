# Pkg.jl workspaces.jl "test resolve with tree hash" — a package whose `test`
# project is a workspace member shares the root manifest: Pkg.test resolves and
# runs the test project in place (no `test/Manifest.toml`), and re-running after
# deleting an installed test dependency reinstalls it. Uses the local pkg
# server's installable Example.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using VibePkg
using VibePkg.Depots: depot_stack
using VibePkg.Registries: add_default_registries!

const EX_UUID = "7876af07-990d-54b4-ab0e-23690620f79a"
const TST_UUID = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

# run `f` with `proj` active and the depot stack (incl. env, for the test
# sandbox subprocess) pointed at `depot` + bundled stdlibs, and precompilation on.
function with_ws_env(f, proj, depot)
    old = Base.ACTIVE_PROJECT[]
    olddp = copy(Base.DEPOT_PATH)
    oldgate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    stack = [depot; Base.append_bundled_depot_path!(String[])]
    sep = Sys.iswindows() ? ';' : ':'
    try
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")
        copy!(Base.DEPOT_PATH, stack)
        return withenv(f, "JULIA_DEPOT_PATH" => join(stack, sep), "JULIA_PKG_PRECOMPILE_AUTO" => "1")
    finally
        Base.ACTIVE_PROJECT[] = old
        copy!(Base.DEPOT_PATH, olddp)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldgate
    end
end

@testset "workspace test project shares the root manifest" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        add_default_registries!(depot_stack([depot]); io = devnull)   # installable Example
        ws = joinpath(dir, "WS")
        mkpath(joinpath(ws, "src"))
        mkpath(joinpath(ws, "test"))
        write(joinpath(ws, "Project.toml"), "name = \"WS\"\nuuid = \"96f64aaf-235f-491a-a76e-24269ac5efad\"\nversion = \"0.1.0\"\n\n[workspace]\nprojects = [\"test\"]\n")
        write(joinpath(ws, "src", "WS.jl"), "module WS end\n")
        write(joinpath(ws, "test", "Project.toml"), "[deps]\nExample = \"$EX_UUID\"\nTest = \"$TST_UUID\"\n")
        # Example is a test-only dep — verify it precompiled against the test
        # project (not the parent) and loads.
        write(joinpath(ws, "test", "runtests.jl"), "using Test\n@test Base.isprecompiled(Base.identify_package(\"Example\"))\nusing Example\n")

        @test !isfile(joinpath(ws, "Manifest.toml"))
        @test !isfile(joinpath(ws, "test", "Manifest.toml"))

        with_ws_env(ws, depot) do
            # Pkg.test auto-resolves the shared workspace manifest — no explicit resolve
            @test VibePkg.test(io = devnull) === nothing
        end
        @test isfile(joinpath(ws, "Manifest.toml"))   # shared root manifest written
        @test !isfile(joinpath(ws, "test", "Manifest.toml"))   # members share it

        # deleting the installed test dep forces a reinstall on the next test run
        Base.rm(joinpath(depot, "packages", "Example"); recursive = true, force = true)
        with_ws_env(ws, depot) do
            @test VibePkg.test(io = devnull) === nothing
        end
        @test isdir(joinpath(depot, "packages", "Example"))   # reinstalled
    end
end
