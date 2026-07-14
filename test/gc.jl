# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
using TOML
using VibePkg.Depots: depot_stack, log_usage
using VibePkg.GCOps
using VibePkg.EnvFiles
using VibePkg.Configs: Config
using VibePkg.Registries: RegistryInstance
import VibePkg.API

const FOO_UUID = UUID("22222222-2222-2222-2222-222222222222")
const FOO_HASH = SHA1("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

@testset "gc" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # a live environment whose manifest references Foo@FOO_HASH
        envdir = mkpath(joinpath(dir, "env"))
        manifest_file = joinpath(envdir, "Manifest.toml")
        write(
            manifest_file, """
            julia_version = "1.12.0"
            manifest_format = "2.1"

            [[deps.Foo]]
            git-tree-sha1 = "$FOO_HASH"
            uuid = "$FOO_UUID"
            version = "1.0.0"
            """
        )
        log_usage(depots, manifest_file, "manifest_usage.toml")
        # plus a stale entry for a manifest that no longer exists
        gone = joinpath(dir, "gone", "Manifest.toml")
        mkpath(dirname(gone)); write(gone, ""); log_usage(depots, gone, "manifest_usage.toml")
        Base.rm(gone)

        # package store: one live slug, one garbage slug
        live_slug = Base.version_slug(FOO_UUID, FOO_HASH)
        live_pkg = mkpath(joinpath(depot, "packages", "Foo", live_slug))
        write(joinpath(live_pkg, "f.jl"), "x")
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        write(joinpath(dead_pkg, "f.jl"), "x")
        orphan_pkg = mkpath(joinpath(depot, "packages", "Gone", "dead2"))

        # artifacts: one referenced by a live Artifacts.toml, one garbage
        live_art = "1234567812345678123456781234567812345678"
        mkpath(joinpath(depot, "artifacts", live_art))
        mkpath(joinpath(depot, "artifacts", "feedfacefeedfacefeedfacefeedfacefeedface"))
        artifacts_toml = joinpath(envdir, "Artifacts.toml")
        write(
            artifacts_toml, """
            [thing]
            git-tree-sha1 = "$live_art"
            """
        )
        log_usage(depots, artifacts_toml, "artifact_usage.toml")

        GCOps.gc(depots; io = devnull)

        @test isdir(live_pkg)
        @test !isdir(dead_pkg)
        @test !isdir(joinpath(depot, "packages", "Gone"))   # empty parent pruned
        @test isdir(joinpath(depot, "artifacts", live_art))
        @test !isdir(joinpath(depot, "artifacts", "feedfacefeedfacefeedfacefeedfacefeedface"))

        # usage log was condensed: the vanished manifest is gone from it
        usage = TOML.parsefile(joinpath(depot, "logs", "manifest_usage.toml"))
        @test haskey(usage, manifest_file) && !haskey(usage, gone)

        # deprecated kwarg warns but works
        @test_logs (:warn, r"collect_delay") GCOps.gc(depots; collect_delay = 7, io = devnull)
    end
end

@testset "auto-gc (JULIA_PKG_GC_AUTO)" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # every completed gc stamps the depot for the auto-gc throttle
        GCOps.gc(depots; io = devnull)
        stamp = GCOps.gc_stamp(depot)
        @test isfile(stamp)

        # the gate: env var (default on) and session toggle
        withenv("JULIA_PKG_GC_AUTO" => nothing) do
            @test API.should_auto_gc()
            API.auto_gc(false)
            try
                @test !API.should_auto_gc()
            finally
                API.auto_gc(true)
            end
        end
        withenv("JULIA_PKG_GC_AUTO" => "false") do
            @test !API.should_auto_gc()
        end

        ctx = API.OpContext(Config(depots; io = devnull), RegistryInstance[])
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        withenv("JULIA_PKG_GC_AUTO" => nothing) do
            # a fresh stamp suppresses the collection
            API._auto_gc(ctx)
            @test isdir(dead_pkg)

            # a missing (or week-old) stamp triggers one, which re-stamps
            Base.rm(stamp)
            API._auto_gc(ctx)
            @test !isdir(dead_pkg)
            @test isfile(stamp)

            # and the env var vetoes it entirely
            Base.rm(stamp)
            dead_pkg2 = mkpath(joinpath(depot, "packages", "Foo", "dead2"))
            withenv("JULIA_PKG_GC_AUTO" => "false") do
                API._auto_gc(ctx)
            end
            @test isdir(dead_pkg2)
        end
    end
end

# Pkg.jl#2633 — a corrupt manifest_usage.toml doesn't stop gc
@testset "gc tolerates corrupt usage log" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        write(joinpath(mkpath(joinpath(depot, "logs")), "manifest_usage.toml"), "this is }{ not toml")
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        @test_logs (:warn, r"Failed to parse usage file") match_mode = :any GCOps.gc(depots; io = devnull)
        @test !isdir(dead_pkg)
    end
end

# Pkg.jl#3698 — log_usage self-heals a corrupt usage log
@testset "log_usage self-heals corrupt usage log" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        usage_file = joinpath(mkpath(joinpath(depot, "logs")), "manifest_usage.toml")
        write(usage_file, "]]] this is not toml [==")
        manifest_file = joinpath(dir, "Manifest.toml")
        write(manifest_file, "")
        @test_logs (:warn, r"Failed to parse usage file") log_usage(depots, manifest_file, "manifest_usage.toml")
        @test haskey(TOML.parsefile(usage_file), manifest_file)   # valid again + new entry
    end
end

# usage logs that are valid TOML but the wrong shape (foreign writers, torn
# writes) and third-party Artifacts.toml content must not abort gc
@testset "gc tolerates schema-corrupt usage logs" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        logs = mkpath(joinpath(depot, "logs"))
        f1 = joinpath(dir, "a.toml")
        f2 = joinpath(dir, "b.toml")
        write(f1, "")
        write(f2, "")
        artifacts_toml = joinpath(dir, "Artifacts.toml")
        write(artifacts_toml, "[foo]\ngit-tree-sha1 = 3\n")
        write(
            joinpath(logs, "manifest_usage.toml"), """
            '$(f1)' = 3
            '$(f2)' = [{ time = "garbage", parent_projects = [1] }]
            """
        )
        write(joinpath(logs, "artifact_usage.toml"), "'$(artifacts_toml)' = [{}]\n")
        write(joinpath(logs, "scratch_usage.toml"), "'space' = \"not-a-vector\"\n")
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        GCOps.gc(depots; io = devnull)
        @test !isdir(dead_pkg)
    end
end

# Pkg.jl#1250 — a symlink loop inside a dead package dir doesn't stop gc
@testset "gc sweeps a dir containing a symlink loop" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        symlink(dead_pkg, joinpath(dead_pkg, "loop"))
        GCOps.gc(depots; io = devnull)
        @test !isdir(joinpath(depot, "packages", "Foo"))
    end
end

# Pkg.jl#1228 Pkg.jl#601 — stray files (.DS_Store) at every packages/ level
@testset "gc tolerates stray files in packages/" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))
        manifest_file = joinpath(envdir, "Manifest.toml")
        write(
            manifest_file, """
            julia_version = "1.12.0"
            manifest_format = "2.1"

            [[deps.Foo]]
            git-tree-sha1 = "$FOO_HASH"
            uuid = "$FOO_UUID"
            version = "1.0.0"
            """
        )
        log_usage(depots, manifest_file, "manifest_usage.toml")
        live_pkg = mkpath(joinpath(depot, "packages", "Foo", Base.version_slug(FOO_UUID, FOO_HASH)))
        write(joinpath(live_pkg, "f.jl"), "x")
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        write(joinpath(depot, "packages", ".DS_Store"), "junk")
        write(joinpath(depot, "packages", "Foo", ".DS_Store"), "junk")
        write(joinpath(dead_pkg, ".DS_Store"), "junk")
        GCOps.gc(depots; io = devnull)
        @test isdir(live_pkg)
        @test !isdir(dead_pkg)
        @test isfile(joinpath(depot, "packages", ".DS_Store"))   # ignored, not fatal
    end
end

# Pkg.jl registry.jl "gc runs git gc on registries" — VibePkg's gc does not run
# git gc on registries, but (the important half) it must never remove or corrupt
# an installed registry while collecting unused packages/artifacts.
@testset "gc leaves registries intact" begin
    if !@isdefined(make_test_registry)
        include("testhelpers.jl")
    end
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        reg = make_test_registry(depot)
        depots = depot_stack([depot])
        @test isfile(joinpath(reg, "Registry.toml"))
        GCOps.gc(depots; io = devnull)              # must not error or delete it
        @test isfile(joinpath(reg, "Registry.toml"))
        @test isfile(joinpath(reg, "E", "Example", "Package.toml"))
    end
end
