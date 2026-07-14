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
using VibePkg.Registries: RegistryInstance, reachable_registries
using VibePkg.Environments: load_environment, write_environment
using VibePkg.Planning: plan_up, plan_resolve
using VibePkg.EnvFiles: entry_version, entry_tree_hash, is_registry_tracked

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

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

        # a stray regular file at the slug path is not an installation
        sha_f = Base.SHA1("ffffffffffffffffffffffffffffffffffffffff")
        stray = joinpath(depot, "packages", "Example", Base.version_slug(uuid, sha_f))
        mkpath(dirname(stray))
        write(stray, "not a package tree")
        path3, installed3 = find_installed(d, "Example", uuid, sha_f)
        @test !installed3
        @test path3 == abspath(stray)

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

# scratch usage log: parent_projects survive compaction; malformed
# pre-existing data from foreign writers is tolerated, well-formed
# parents are kept
@testset "scratch usage log" begin
    mktempdir() do depot
        d = depot_stack([depot])
        log_scratch_usage(d, "/scr/space", "/proj/A/Project.toml")
        log_scratch_usage(d, "/scr/space", "/proj/B/Project.toml")
        usage_file = joinpath(depot, "logs", "scratch_usage.toml")
        usage = TOML.parsefile(usage_file)
        @test length(usage["/scr/space"]) == 1
        @test sort(usage["/scr/space"][1]["parent_projects"]) ==
            ["/proj/A/Project.toml", "/proj/B/Project.toml"]

        # a foreign writer left malformed parent_projects (a scalar, and a
        # vector with non-string members): compaction must not throw and
        # must keep the well-formed parents of co-resident entries
        write(
            usage_file, """
            [["/scr/other"]]
            time = 2020-01-01T00:00:00
            parent_projects = 2020-01-01T00:00:00

            [["/scr/other"]]
            time = 2020-01-02T00:00:00
            parent_projects = ["/proj/C/Project.toml", 42]
            """
        )
        log_scratch_usage(d, "/scr/space", "/proj/A/Project.toml")
        usage2 = TOML.parsefile(usage_file)
        @test usage2["/scr/other"][1]["parent_projects"] == ["/proj/C/Project.toml"]
        @test usage2["/scr/space"][1]["parent_projects"] == ["/proj/A/Project.toml"]
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

# Pkg.jl new.jl "Issue #4345: pidfile in writable location when depot is
# readonly" — with an actually read-only depot behind a writable one, a package
# already present in the readonly depot is served without writing a pidfile
# there, and a new package installs into the writable depot without a
# permission error.
@testset "readonly depot: pidfiles stay writable (#4345)" begin
    fx = LocalPkgServer.ensure!()
    example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    h4 = Base.SHA1(fx.version_hashes["0.5.4"])
    h5 = Base.SHA1(fx.version_hashes["0.5.5"])
    mktempdir() do dir
        ro = mkpath(joinpath(dir, "ro"))
        wr = mkpath(joinpath(dir, "wr"))
        # seed 0.5.4 into the depot that will become read-only
        Fetch.ensure_package_installed!(
            depot_stack([ro]), "Example", example_uuid, h4, String[]; readonly = false, io = devnull,
        )
        chmod(ro, 0o555; recursive = true)
        try
            d = depot_stack([wr, ro])
            # 0.5.4 is already in the readonly depot: served as-is, no pidfile there
            p4, new4 = Fetch.ensure_package_installed!(
                d, "Example", example_uuid, h4, String[]; readonly = false, io = devnull,
            )
            @test !new4
            @test startswith(p4, ro)
            @test !isfile(joinpath(ro, "packages", "Example", Base.version_slug(example_uuid, h4)) * ".pid")
            # 0.5.5 is new: installs into the writable depot without erroring
            p5, new5 = Fetch.ensure_package_installed!(
                d, "Example", example_uuid, h5, String[]; readonly = false, io = devnull,
            )
            @test new5
            @test startswith(p5, wr)
            @test isfile(joinpath(p5, "Project.toml"))
        finally
            chmod(ro, 0o755; recursive = true)      # restore so mktempdir can clean up
        end
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

# UPGRADABLE_STDLIBS_UUIDS carries fixed identities and must hold them
# before any stdlib_infos() call (no call-order dependence): a fresh
# process consults the set first thing, with the lazy cache still empty
@testset "upgradable stdlib uuids are eager" begin
    delim_uuid = UUID("8bb1440f-4735-579b-a4ab-409b98df4dab")   # DelimitedFiles
    stats_uuid = UUID("10745b16-79ce-11e8-11f9-7d13ad32a3b2")   # Statistics
    @test Stdlibs.UPGRADABLE_STDLIBS_UUIDS == Set([delim_uuid, stats_uuid])
    code = """
    using VibePkg
    using Base: UUID
    ok = VibePkg.Stdlibs.STDLIB[] === nothing &&
        UUID("$delim_uuid") in VibePkg.Stdlibs.UPGRADABLE_STDLIBS_UUIDS &&
        UUID("$stats_uuid") in VibePkg.Stdlibs.UPGRADABLE_STDLIBS_UUIDS
    exit(ok ? 0 : 1)
    """
    # boot the worker on the loose stack so VibePkg's dependency sources
    # (user depot) resolve; the set must be populated at load, eagerly
    cmd = addenv(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`,
        "JULIA_DEPOT_PATH" => LocalPkgServer.worker_depot_path(),
    )
    @test success(cmd)
end

# Pkg.jl resolve.jl "Stdlib resolve smoketest" — every standard library must be
# jointly installable: adding all of them and resolving succeeds, populates the
# manifest with all of them, and a second resolve is a no-op (idempotent).
@testset "all stdlibs resolve" begin
    sl = Stdlibs.load_stdlib()
    mktempdir() do depot
        make_test_registry(depot)
        depots = Depots.depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            open(joinpath(envdir, "Project.toml"), "w") do io
                println(io, "[deps]")
                for (u, info) in sl
                    println(io, info.name, " = \"", u, "\"")
                end
            end
            env = load_environment(envdir; depots)
            resolved = plan_resolve(env, regs, Config(depots))
            @test all(haskey(resolved.manifest, u) for u in keys(sl))
            @test length(resolved.manifest.deps) == length(sl)

            # a second resolve over the written manifest changes nothing
            write_environment(env, resolved)
            env2 = load_environment(envdir; depots)
            resolved2 = plan_resolve(env2, regs, Config(depots))
            @test Set(keys(resolved2.manifest.deps)) == Set(keys(sl))
        end
    end
end
