# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using UUIDs: UUID
using TOML
using VibePkg.Depots
using VibePkg.Configs: Config
using VibePkg.Stdlibs
using VibePkg.Errors: PkgError
using VibePkg.ArtifactOps: artifact_tree_path
import VibePkg.Fetch
using VibePkg.Registries: RegistryInstance
using VibePkg.Environments: load_environment
using VibePkg.Planning: plan_up
using VibePkg.EnvFiles: entry_version, entry_tree_hash, is_registry_tracked

@testset "Depots" begin
    mktempdir() do depot
        d = depot_stack([depot, "/some/readonly/depot"])
        @test depots1(d) == depot
        @test depots(d) == [depot, "/some/readonly/depot"]
        @test_throws PkgError depots1(depot_stack(String[]))

        # slug agrees with Base's loading contract
        uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        sha = Base.SHA1("8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8")
        path, installed = find_installed(d, "Example", uuid, sha)
        @test !installed
        @test path == abspath(joinpath(depot, "packages", "Example", Base.version_slug(uuid, sha)))
        # legacy 4-char slugs are probed
        legacy = joinpath(depot, "packages", "Example", Base.version_slug(uuid, sha, 4))
        mkpath(legacy)
        path2, installed2 = find_installed(d, "Example", uuid, sha)
        @test installed2 && path2 == abspath(legacy)

        # usage log: append + compaction to one entry per key
        f = joinpath(depot, "something", "Manifest.toml")
        mkpath(dirname(f)); write(f, "")
        log_usage(d, f, "manifest_usage.toml")
        log_usage(d, f, "manifest_usage.toml")
        usage = TOML.parsefile(joinpath(depot, "logs", "manifest_usage.toml"))
        @test length(usage[f]) == 1
        @test haskey(usage[f][1], "time")
    end
end

# the same content in two depots of a stack: the earlier depot wins lookups
@testset "Depot shadowing" begin
    mktempdir() do dir
        depot_a = mkpath(joinpath(dir, "A"))
        depot_b = mkpath(joinpath(dir, "B"))
        d = depot_stack([depot_a, depot_b])

        # package tree present in both depots → earlier depot's path returned
        uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        sha = Base.SHA1("8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8")
        slug = Base.version_slug(uuid, sha)
        path_a = mkpath(joinpath(depot_a, "packages", "Example", slug))
        path_b = mkpath(joinpath(depot_b, "packages", "Example", slug))
        path, installed = find_installed(d, "Example", uuid, sha)
        @test installed
        @test path == abspath(path_a)
        # reversing the stack flips the winner
        path_rev, _ = find_installed(depot_stack([depot_b, depot_a]), "Example", uuid, sha)
        @test path_rev == abspath(path_b)
        # gone from the first depot → the later depot still serves it
        Base.rm(path_a; recursive = true)
        path_later, installed_later = find_installed(d, "Example", uuid, sha)
        @test installed_later
        @test path_later == abspath(path_b)

        # same for an artifact hash present in both depots
        hash = Base.SHA1("5555555555555555555555555555555555555555")
        art_a = mkpath(joinpath(depot_a, "artifacts", string(hash)))
        art_b = mkpath(joinpath(depot_b, "artifacts", string(hash)))
        apath, ainstalled = artifact_tree_path(d, hash)
        @test ainstalled
        @test apath == art_a
        apath_rev, _ = artifact_tree_path(depot_stack([depot_b, depot_a]), hash)
        @test apath_rev == art_b
        Base.rm(art_a; recursive = true)
        apath_later, ainstalled_later = artifact_tree_path(d, hash)
        @test ainstalled_later
        @test apath_later == art_b
    end
end

# Pkg.jl#4352 — a manifest carries a versioned stdlib at another julia
# version's tree hash: `up` normalizes the entry to the running julia's
# stdlib instead of erroring with "cannot add stdlib"
@testset "stale versioned-stdlib manifest entry" begin
    tar_uuid = UUID("a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e")
    @test stdlib_version(tar_uuid, VERSION) isa VersionNumber   # Tar is versioned
    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"), """
            [deps]
            Tar = "$tar_uuid"
            """
        )
        write(
            joinpath(dir, "Manifest.toml"), """
            julia_version = "1.8.0"
            manifest_format = "2.0"

            [[deps.Tar]]
            git-tree-sha1 = "8888888888888888888888888888888888888888"
            uuid = "$tar_uuid"
            version = "1.9.5"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        env = load_environment(dir; depots = d)
        plan = plan_up(env, RegistryInstance[], Config(d))
        entry = plan.manifest[tar_uuid]
        @test is_registry_tracked(entry)
        @test entry_tree_hash(entry) === nothing       # stale hash dropped
        @test entry_version(entry) == stdlib_version(tar_uuid, VERSION)
    end
end

# Pkg.jl#4345 — new package trees always land in the FIRST depot of the
# stack, even when a later (read-only) depot already holds other versions
@testset "installs land in the first depot" begin
    fx = LocalPkgServer.ensure!()
    example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    h4 = Base.SHA1(fx.version_hashes["0.5.4"])
    h5 = Base.SHA1(fx.version_hashes["0.5.5"])
    mktempdir() do dir
        depot1 = mkpath(joinpath(dir, "depot1"))
        depot2 = mkpath(joinpath(dir, "depot2"))
        # the second depot already holds 0.5.4
        path4, _ = Fetch.ensure_package_installed!(
            depot_stack([depot2]), "Example", example_uuid, h4, String[];
            readonly = false, io = devnull,
        )
        @test startswith(path4, depot2)

        d = depot_stack([depot1, depot2])
        path5, new5 = Fetch.ensure_package_installed!(
            d, "Example", example_uuid, h5, String[]; readonly = false, io = devnull,
        )
        @test new5
        @test startswith(path5, depot1)                # not next to 0.5.4 in depot2
        @test isfile(joinpath(path5, "Project.toml"))
        # the existing tree keeps being served from depot 2, no copy is made
        path4′, new4 = Fetch.ensure_package_installed!(
            d, "Example", example_uuid, h4, String[]; readonly = false, io = devnull,
        )
        @test !new4
        @test path4′ == path4
        @test !isdir(joinpath(depot1, "packages", "Example", Base.version_slug(example_uuid, h4)))
    end
end

@testset "Stdlibs" begin
    infos = stdlib_infos()
    dates_uuid = UUID("ade2ca70-3891-5945-98fb-dc099432e06a")
    @test is_stdlib(dates_uuid)
    @test infos[dates_uuid].name == "Dates"
    @test !is_stdlib(UUID("7876af07-990d-54b4-ab0e-23690620f79a")) # Example.jl
    # current version fast path needs no historical data
    @test is_stdlib(dates_uuid, VERSION)
    # other versions require HistoricalStdlibVersions
    @test_throws PkgError is_stdlib(dates_uuid, v"1.8.0")
    @test_throws PkgError get_last_stdlibs(nothing)
    # jll-ish stdlibs are versioned, plain ones are not
    @test stdlib_version(dates_uuid, VERSION) isa Union{Nothing, VersionNumber}
end
