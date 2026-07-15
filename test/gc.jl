# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
import LibGit2
using TOML
using VibePkg.Depots: depot_stack, log_usage, log_scratch_usage
using VibePkg.GCOps
using VibePkg.EnvFiles
import VibePkg.Git
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

@testset "gc reaps unreachable repo clone caches" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # Materialize a real bare clone cache from a completely local package
        # repository. This exercises the cache shape created by add-by-URL,
        # rather than standing in for it with an arbitrary directory.
        src = joinpath(dir, "Foo")
        mkpath(joinpath(src, "src"))
        write(
            joinpath(src, "Project.toml"),
            "name = \"Foo\"\nuuid = \"$FOO_UUID\"\nversion = \"1.0.0\"\n",
        )
        write(joinpath(src, "src", "Foo.jl"), "module Foo end\n")
        repo = LibGit2.init(src)
        try
            LibGit2.add!(repo, ".")
            sig = LibGit2.Signature("tester", "tester@example.com")
            LibGit2.commit(repo, "initial"; author = sig, committer = sig)
        finally
            close(repo)
        end

        package = Git.materialize_repo_package!(depots, src; io = devnull)
        cache = Git.repo_cache_path(depots, src)
        @test isdir(cache)
        @test isfile(joinpath(cache, "HEAD")) # an actual bare Git repository

        # A live manifest usage root must mark the URL-keyed clone cache.
        envdir = mkpath(joinpath(dir, "env"))
        manifest_file = joinpath(envdir, "Manifest.toml")
        manifest = Dict(
            "julia_version" => string(VERSION),
            "manifest_format" => "2.1",
            "deps" => Dict(
                "Foo" => [
                    Dict(
                        "git-tree-sha1" => string(package.tree_hash),
                        "repo-rev" => package.rev,
                        "repo-url" => src,
                        "uuid" => string(FOO_UUID),
                        "version" => "1.0.0",
                    ),
                ],
            ),
        )
        open(manifest_file, "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        log_usage(depots, manifest_file, "manifest_usage.toml")
        GCOps.gc(depots; io = devnull)
        @test isdir(cache)

        # Once that usage root is gone, the same real cache is unreachable and
        # must be reaped (the clone-specific half of Pkg's add/rm/gc test).
        Base.rm(manifest_file)
        GCOps.gc(depots; io = devnull)
        @test !ispath(cache)
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

# Pkg.jl#2633 — a corrupt manifest_usage.toml doesn't stop gc; and gc fails
# closed: with the record of live manifests unreadable, packages and clones
# (marked from manifests) are preserved rather than mass-collected, while
# classes with healthy logs still sweep
@testset "gc fails closed on corrupt manifest usage log" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        usage_file = joinpath(mkpath(joinpath(depot, "logs")), "manifest_usage.toml")
        write(usage_file, "this is }{ not toml")
        pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        clone = mkpath(joinpath(depot, "clones", "some-clone"))
        dead_art = mkpath(joinpath(depot, "artifacts", "feedfacefeedfacefeedfacefeedfacefeedface"))
        @test_logs (:warn, r"Could not parse usage log") match_mode = :any GCOps.gc(depots; io = devnull)
        @test isdir(pkg)                                    # liveness unknown -> kept
        @test isdir(clone)                                  # clones come from manifests too
        @test !isdir(dead_art)                              # artifact log fine -> still swept
        @test read(usage_file, String) == "this is }{ not toml"  # left for log_usage to heal
        # once the log is healthy again the next gc collects as usual
        Base.rm(usage_file)
        GCOps.gc(depots; io = devnull)
        @test !isdir(pkg)
        @test !isdir(clone)
    end
end

# fail-closed is per sweep class: a corrupt artifact_usage.toml preserves
# artifacts but packages still sweep, and a corrupt scratch_usage.toml
# preserves scratchspaces
@testset "gc fails closed per class on corrupt usage logs" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        logs = mkpath(joinpath(depot, "logs"))
        write(joinpath(logs, "artifact_usage.toml"), "also }{ not toml")
        write(joinpath(logs, "scratch_usage.toml"), "even more }{ not toml")
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))
        art = mkpath(joinpath(depot, "artifacts", "feedfacefeedfacefeedfacefeedfacefeedface"))
        space = mkpath(joinpath(depot, "scratchspaces", string(FOO_UUID), "space1"))
        @test_logs (:warn, r"Could not parse (scratch )?usage log") match_mode = :any GCOps.gc(depots; io = devnull)
        @test isdir(art)        # liveness unknown -> kept
        @test isdir(space)      # liveness unknown -> kept
        @test !isdir(dead_pkg)  # manifest log fine -> still swept
    end
end

# a usage log that parses but whose value for an existing file is malformed
# must treat that file as freshly used (fail closed), not drop it and sweep
# the packages/scratchspaces it vouches for
@testset "gc preserves roots behind schema-corrupt usage entries" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        logs = mkpath(joinpath(depot, "logs"))

        # manifest referenced by a malformed (non-array) usage value
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
        write(joinpath(logs, "manifest_usage.toml"), "'$(manifest_file)' = 3\n")
        live_pkg = mkpath(joinpath(depot, "packages", "Foo", Base.version_slug(FOO_UUID, FOO_HASH)))
        dead_pkg = mkpath(joinpath(depot, "packages", "Foo", "dead1"))

        # a scratchspace with malformed entries is kept, a well-formed one
        # whose parents are gone is still collected in the same run
        odd_space = mkpath(joinpath(depot, "scratchspaces", string(FOO_UUID), "odd"))
        dead_space = mkpath(joinpath(depot, "scratchspaces", string(FOO_UUID), "dead"))
        write(
            joinpath(logs, "scratch_usage.toml"), """
            '$(odd_space)' = [3]
            '$(dead_space)' = [{ time = 2024-01-01T00:00:00, parent_projects = ['$(joinpath(dir, "gone-project"))'] }]
            """
        )

        GCOps.gc(depots; io = devnull)
        @test isdir(live_pkg)        # its manifest was salvaged as live
        @test !isdir(dead_pkg)       # unreferenced content still sweeps
        @test isdir(odd_space)       # malformed entries -> kept
        @test !isdir(dead_space)     # parents gone -> collected
        # the salvaged manifest key survives the compaction rewrite
        @test haskey(TOML.parsefile(joinpath(logs, "manifest_usage.toml")), manifest_file)
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
        @test_logs (:warn, r"Could not parse usage log") log_usage(depots, manifest_file, "manifest_usage.toml")
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

# Pkg.jl registry.jl "gc runs git gc on registries". Unlike the upstream test,
# this also proves the command ran: a freshly committed registry starts with
# loose objects, while `git gc` packs those reachable objects.
@testset "gc runs git gc on registries" begin
    if Sys.which("git") === nothing
        @test_skip "git CLI not available"
    else
        if !@isdefined(make_test_registry)
            include("testhelpers.jl")
        end
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            reg = make_test_registry(depot)
            repo = LibGit2.init(reg)
            try
                LibGit2.add!(repo, ".")
                sig = LibGit2.Signature("tester", "tester@example.com")
                LibGit2.commit(repo, "initial registry"; author = sig, committer = sig)
            finally
                close(repo)
            end

            git_objects = joinpath(reg, ".git", "objects")
            loose_objects() = sum(
                length(readdir(joinpath(git_objects, fanout))) for fanout in readdir(git_objects)
                    if occursin(r"^[0-9a-f]{2}$", fanout);
                init = 0,
            )
            loose_before = loose_objects()
            @test loose_before > 0
            @test isempty(filter(f -> endswith(f, ".pack"), readdir(joinpath(git_objects, "pack"))))

            old_depots = copy(Base.DEPOT_PATH)
            output = IOBuffer()
            try
                empty!(Base.DEPOT_PATH)
                push!(Base.DEPOT_PATH, depot)
                @test_nowarn API.gc(; verbose = true, io = output)
            finally
                empty!(Base.DEPOT_PATH)
                append!(Base.DEPOT_PATH, old_depots)
            end

            @test occursin("running git gc on registry TestRegistry", String(take!(output)))
            @test isfile(joinpath(reg, "Registry.toml"))
            @test isfile(joinpath(reg, "E", "Example", "Package.toml"))
            @test isdir(joinpath(reg, ".git"))
            @test loose_objects() < loose_before
            pack_files = readdir(joinpath(git_objects, "pack"))
            @test any(endswith(".pack"), pack_files)
            @test any(endswith(".idx"), pack_files)
            @test LibGit2.with(LibGit2.GitRepo(reg)) do packed_repo
                LibGit2.head_oid(packed_repo) isa LibGit2.GitHash
            end
        end
    end
end

# builds record scratch usage keyed by the scratchspace path with a
# parent_projects list — the liveness key gc uses; a time-only entry (or one
# keyed by the manifest file) would let gc sweep live scratchspaces
@testset "scratch usage from builds survives gc" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        proj = joinpath(mkpath(joinpath(dir, "proj")), "Project.toml")
        write(proj, "")
        space = mkpath(joinpath(depot, "scratchspaces", string(FOO_UUID), string(FOO_HASH)))
        write(joinpath(space, "build.log"), "built")
        log_scratch_usage(depots, space, proj)

        # the entry is keyed by the scratchspace and carries parent_projects
        usage = TOML.parsefile(joinpath(depot, "logs", "scratch_usage.toml"))
        @test haskey(usage, space)
        @test usage[space][1]["parent_projects"] == [proj]

        # a second parent merges into the list — never replaces it
        proj2 = joinpath(mkpath(joinpath(dir, "proj2")), "Project.toml")
        write(proj2, "")
        log_scratch_usage(depots, space, proj2)
        usage = TOML.parsefile(joinpath(depot, "logs", "scratch_usage.toml"))
        @test sort(usage[space][1]["parent_projects"]) == sort([proj, proj2])

        # a live parent project keeps the scratchspace through gc
        GCOps.gc(depots; io = devnull)
        @test isfile(joinpath(space, "build.log"))

        # both parents gone -> the scratchspace is collected
        Base.rm(proj)
        Base.rm(proj2)
        GCOps.gc(depots; io = devnull)
        @test !isdir(space)
    end
end
