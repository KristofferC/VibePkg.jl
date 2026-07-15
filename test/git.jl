# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
import LibGit2
import TOML
using FileWatching: mkpidlock
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Errors: PkgError
using VibePkg.Depots: depot_stack, find_installed
using VibePkg.Git
using VibePkg.Registries: RegistryInstance, reachable_registries
using VibePkg.Environments
using VibePkg.Planning: plan_add, plan_up, plan_resolve, plan_rm, plan_free,
    plan_develop, PackageRequest
using VibePkg.Execution: instantiate!
using VibePkg.TreeHash: tree_hash
using VibePkg.Utils: DEFAULT_IO
using VibePkg.EnvFiles: entry_version, entry_repo_url, entry_repo_rev,
    entry_repo_subdir, entry_tree_hash, entry_path, is_repo_tracked,
    is_path_tracked, is_registry_tracked, read_manifest

# planning-time materialization prints clone/fetch progress via the default
# IO; tests run it against devnull
quiet(f) = Base.ScopedValues.with(f, DEFAULT_IO => devnull)

# embed a native filesystem path in a hand-written TOML basic string: a Windows
# path's backslash separators (and any quotes) must be escaped so the parsed
# value round-trips to the exact string (`\Users` would otherwise be read as an
# invalid `\U` unicode escape)
toml_str(s::AbstractString) = replace(s, '\\' => "\\\\", '"' => "\\\"")

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

# A repository-tracked manifest records the canonical Git tree object id.
# Re-hashing a Windows worktree is not equivalent because the checkout cannot
# faithfully represent all Unix mode bits stored in the tree.
function git_tree_hash(repo_path::String, rev::String)
    repo = LibGit2.GitRepo(repo_path)
    obj = tree = nothing
    try
        obj = LibGit2.GitObject(repo, rev)
        tree = LibGit2.peel(LibGit2.GitTree, obj)
        return SHA1(string(LibGit2.GitHash(tree)))
    finally
        tree !== nothing && close(tree)
        obj !== nothing && close(obj)
        close(repo)
    end
end

const GITPKG_UUID = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")

function make_git_package(dir)
    src = joinpath(dir, "GitPkg")
    mkpath(joinpath(src, "src"))
    write(
        joinpath(src, "Project.toml"), """
        name = "GitPkg"
        uuid = "$GITPKG_UUID"
        version = "0.1.0"
        """
    )
    write(joinpath(src, "src", "GitPkg.jl"), "module GitPkg end\n")
    repo = LibGit2.init(src)
    LibGit2.add!(repo, ".")
    sig = LibGit2.Signature("tester", "tester@example.com")
    LibGit2.commit(repo, "initial"; author = sig, committer = sig)
    LibGit2.close(repo)
    return src
end

@testset "Git" begin
    mktempdir() do dir
        src = make_git_package(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # materialize: clone cache + tree checkout into the package store
        rp = Git.materialize_repo_package!(depots, src; io = devnull)
        @test rp.name == "GitPkg"
        @test rp.uuid == GITPKG_UUID
        @test rp.rev !== nothing                       # default branch recorded
        @test isdir(rp.path)
        @test isfile(joinpath(rp.path, "src", "GitPkg.jl"))
        @test startswith(rp.path, joinpath(depot, "packages"))

        # idempotent: same tree comes back from the store
        rp2 = Git.materialize_repo_package!(depots, src; io = devnull)
        @test rp2.tree_hash == rp.tree_hash && rp2.path == rp.path

        # plan an add of the repo package (no registries involved)
        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        planned = plan_add(env, RegistryInstance[], Config(depots), [rp]; julia_version = VERSION)
        entry = planned.manifest[GITPKG_UUID]
        @test is_repo_tracked(entry)
        @test entry_repo_url(entry) == src
        @test entry_repo_rev(entry) == rp.rev
        @test entry_version(entry) == v"0.1.0"
        @test planned.project.deps["GitPkg"] == GITPKG_UUID

        # writing records a [sources] entry with url + rev
        write_environment(env, planned)
        env2 = load_environment(envdir; depots)
        source = env2.project.sources["GitPkg"]
        @test source.url == src && source.rev == rp.rev
        @test env2.manifest == planned.manifest
    end
end

const SUBPKG_UUID = UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")

# a git repo where the package lives under pkgs/SubPkg (no top-level project)
function make_subdir_repo(dir)
    src = joinpath(dir, "MonoRepo")
    pkg = joinpath(src, "pkgs", "SubPkg")
    mkpath(joinpath(pkg, "src"))
    write(joinpath(src, "README.md"), "not a package at the top level\n")
    write(
        joinpath(pkg, "Project.toml"), """
        name = "SubPkg"
        uuid = "$SUBPKG_UUID"
        version = "0.2.0"
        """
    )
    write(joinpath(pkg, "src", "SubPkg.jl"), "module SubPkg end\n")
    repo = LibGit2.init(src)
    LibGit2.add!(repo, ".")
    sig = LibGit2.Signature("tester", "tester@example.com")
    LibGit2.commit(repo, "initial"; author = sig, committer = sig)
    LibGit2.close(repo)
    return src
end

@testset "subdirectory add" begin
    mktempdir() do dir
        src = make_subdir_repo(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        subdir = joinpath("pkgs", "SubPkg")

        # materialized tree is the subdir's tree, not the whole repo
        rp = Git.materialize_repo_package!(depots, src; subdir, io = devnull)
        @test rp.name == "SubPkg"
        @test rp.uuid == SUBPKG_UUID
        @test rp.subdir == subdir
        @test isfile(joinpath(rp.path, "Project.toml"))
        @test isfile(joinpath(rp.path, "src", "SubPkg.jl"))
        @test !ispath(joinpath(rp.path, "pkgs"))            # subtree only
        @test !ispath(joinpath(rp.path, "README.md"))
        @test startswith(rp.path, joinpath(depot, "packages"))

        # a nonexistent subdir is a pinned error
        @test_throws PkgError Git.materialize_repo_package!(
            depots, src; subdir = "pkgs/Nope", io = devnull
        )
        # without a subdir there is no project file at the repo root
        @test_throws PkgError Git.materialize_repo_package!(depots, src; io = devnull)

        # planning records the subdir in the manifest entry and [sources]
        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        planned = plan_add(env, RegistryInstance[], Config(depots), [rp]; julia_version = VERSION)
        entry = planned.manifest[SUBPKG_UUID]
        @test is_repo_tracked(entry)
        @test entry_repo_url(entry) == src
        @test entry_repo_subdir(entry) == subdir
        @test entry_version(entry) == v"0.2.0"

        write_environment(env, planned)
        env2 = load_environment(envdir; depots)
        source = env2.project.sources["SubPkg"]
        @test source.url == src && source.subdir == subdir
        @test entry_repo_subdir(env2.manifest[SUBPKG_UUID]) == subdir
    end
end

const TRACKPKG_UUID = UUID("ffffffff-ffff-ffff-ffff-ffffffffffff")

function make_track_repo(dir)
    src = joinpath(dir, "TrackPkg")
    mkpath(joinpath(src, "src"))
    write(
        joinpath(src, "Project.toml"), """
        name = "TrackPkg"
        uuid = "$TRACKPKG_UUID"
        version = "0.1.0"
        """
    )
    write(joinpath(src, "src", "TrackPkg.jl"), "module TrackPkg end\n")
    repo = LibGit2.init(src)
    LibGit2.add!(repo, ".")
    sig = LibGit2.Signature("tester", "tester@example.com")
    commit = LibGit2.commit(repo, "initial"; author = sig, committer = sig)
    branch = LibGit2.shortname(LibGit2.head(repo))
    LibGit2.close(repo)
    return src, string(commit), branch
end

# branch-vs-commit tracking through `up`, end to end through the API.
# The session runs against a private depot and env with no package server
# (JULIA_PKG_SERVER = ""). The depot gets the offline test registry: a fresh
# registry-less depot would (correctly, Pkg parity) try to bootstrap General
# over git, which the hermetic proxy blocks.
@testset "branch vs commit tracking" begin
    mktempdir() do dir
        src, commit1, branch = make_track_repo(dir)
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        env_branch = mkpath(joinpath(dir, "env_branch"))
        env_commit = mkpath(joinpath(dir, "env_commit"))

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            withenv("JULIA_PKG_SERVER" => "") do
                # one env tracks the branch, one the exact commit SHA
                Base.ACTIVE_PROJECT[] = joinpath(env_branch, "Project.toml")
                VibePkg.add(url = src, rev = branch, io = devnull)
                Base.ACTIVE_PROJECT[] = joinpath(env_commit, "Project.toml")
                VibePkg.add(url = src, rev = commit1, io = devnull)

                entry(envdir) = read_manifest(joinpath(envdir, "Manifest.toml"))[TRACKPKG_UUID]
                b1, c1 = entry(env_branch), entry(env_commit)
                @test entry_repo_rev(b1) == branch
                @test entry_repo_rev(c1) == commit1
                @test entry_tree_hash(b1) == entry_tree_hash(c1)

                # a new commit lands on the branch upstream
                write(joinpath(src, "src", "TrackPkg.jl"), "module TrackPkg\nf() = 2\nend\n")
                repo = LibGit2.GitRepo(src)
                LibGit2.add!(repo, ".")
                sig = LibGit2.Signature("tester", "tester@example.com")
                commit2 = string(LibGit2.commit(repo, "second"; author = sig, committer = sig))
                LibGit2.close(repo)
                @test commit2 != commit1

                # commit-tracked: `up` (targeted and whole-env) never moves it
                VibePkg.up("TrackPkg"; io = devnull)
                VibePkg.up(io = devnull)
                c2 = entry(env_commit)
                @test entry_repo_rev(c2) == commit1
                @test entry_tree_hash(c2) == entry_tree_hash(c1)

                # branch-tracked: `up` re-materializes the recorded repo/rev
                # (fetch-first, so the cached branch ref actually moves) and
                # pulls in the new commit
                Base.ACTIVE_PROJECT[] = joinpath(env_branch, "Project.toml")
                VibePkg.up("TrackPkg"; io = devnull)
                b2 = entry(env_branch)
                @test entry_repo_rev(b2) == branch          # still tracks the branch
                @test entry_tree_hash(b2) != entry_tree_hash(b1)
                # idempotent: a second up with no upstream movement stays put
                VibePkg.up(io = devnull)
                @test entry_tree_hash(entry(env_branch)) == entry_tree_hash(b2)
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end

function commit_all!(src, message)
    repo = LibGit2.GitRepo(src)
    LibGit2.add!(repo, ".")
    sig = LibGit2.Signature("tester", "tester@example.com")
    commit = string(LibGit2.commit(repo, message; author = sig, committer = sig))
    LibGit2.close(repo)
    return commit
end

# Pkg.jl#614: re-materializing an already-installed tree must not rewrite
# the installed files
@testset "re-materialize keeps the installed tree intact" begin
    mktempdir() do dir
        src = make_git_package(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        rp = Git.materialize_repo_package!(depots, src; io = devnull)
        marker = joinpath(rp.path, "marker.txt")
        write(marker, "keep me\n")
        rp2 = Git.materialize_repo_package!(depots, src; io = devnull)
        @test rp2.path == rp.path
        @test isfile(marker) && read(marker, String) == "keep me\n"
    end
end

# The clone cache is shallow (depth = 1 where supported) and fetches are
# targeted by rev shape: a missing branch, tag, or pull-request rev is
# fetched by name, a commit hash through an unshallow branch fetch.
# Creating the refs upstream only after the cache exists forces each
# fetch path.
@testset "targeted rev fetches against an existing clone cache" begin
    mktempdir() do dir
        dir = realpath(dir)
        src, commit1, branch = make_track_repo(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # prime the clone cache at the initial commit
        rp1 = Git.materialize_repo_package!(depots, src; rev = branch, io = devnull)

        # upstream gains a commit plus branch/tag/pull refs pointing at it,
        # none of which exist in the cached clone
        write(joinpath(src, "src", "TrackPkg.jl"), "module TrackPkg\nf() = 2\nend\n")
        commit2 = commit_all!(src, "second")
        repo = LibGit2.GitRepo(src)
        oid = LibGit2.GitHash(commit2)
        for refname in ("refs/heads/feature", "refs/tags/vtag", "refs/pull/7/head")
            LibGit2.close(LibGit2.GitReference(repo, oid, refname))
        end
        LibGit2.close(repo)
        tree2 = git_tree_hash(src, commit2)
        @test tree2 != rp1.tree_hash

        for rev in ("feature", "vtag", "pull/7/head", commit2)
            rp = Git.materialize_repo_package!(depots, src; rev, io = devnull)
            @test rp.rev == rev
            @test rp.tree_hash == tree2
        end

        # a rev that exists nowhere still errors cleanly after the fallback
        @test_throws PkgError Git.materialize_repo_package!(
            depots, src; rev = "nosuchrev", io = devnull
        )

        # pull-request heads move like branches: without `refresh` the
        # cached ref pins the tree, with it the new tip is picked up
        write(joinpath(src, "src", "TrackPkg.jl"), "module TrackPkg\nf() = 3\nend\n")
        commit3 = commit_all!(src, "third")
        repo = LibGit2.GitRepo(src)
        LibGit2.close(LibGit2.GitReference(repo, LibGit2.GitHash(commit3), "refs/pull/7/head"; force = true))
        LibGit2.close(repo)
        tree3 = git_tree_hash(src, commit3)
        rp = Git.materialize_repo_package!(depots, src; rev = "pull/7/head", io = devnull)
        @test rp.tree_hash == tree2
        rp = Git.materialize_repo_package!(depots, src; rev = "pull/7/head", refresh = true, io = devnull)
        @test rp.tree_hash == tree3

        # tags are immutable: `refresh` resolves from the cache, no refetch
        rp = Git.materialize_repo_package!(depots, src; rev = "vtag", refresh = true, io = devnull)
        @test rp.tree_hash == tree2
    end
end

# Pkg.jl#4157: hand-editing the `[sources]` rev must re-resolve the manifest
# to the new rev's tree
@testset "hand-edited [sources] rev" begin
    mktempdir() do dir
        dir = realpath(dir)
        src, commit1, branch = make_track_repo(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))

        rp = Git.materialize_repo_package!(depots, src; rev = commit1, io = devnull)
        env = load_environment(envdir; depots)
        write_environment(env, plan_add(env, RegistryInstance[], Config(depots), [rp]; julia_version = VERSION))

        # a second commit lands upstream; the user edits the rev by hand
        write(joinpath(src, "src", "TrackPkg.jl"), "module TrackPkg\nf() = 2\nend\n")
        commit2 = commit_all!(src, "second")
        project_file = joinpath(envdir, "Project.toml")
        write(project_file, replace(read(project_file, String), commit1 => commit2))

        env = load_environment(envdir; depots)
        planned = quiet(() -> plan_up(env, RegistryInstance[], Config(depots); fetcher = Git.source_fetcher(depots; io = devnull)))
        entry = planned.manifest[TRACKPKG_UUID]
        @test is_repo_tracked(entry)
        @test entry_repo_rev(entry) == commit2
        @test entry_tree_hash(entry) != rp.tree_hash
        @test entry_tree_hash(entry) == git_tree_hash(src, commit2)
        write_environment(env, planned)
    end
end

# Pkg.jl#4337: flipping a `[sources]` entry from path to url+rev on an
# already-resolved environment re-tracks the package by repository
@testset "[sources] path flipped to url+rev" begin
    mktempdir() do dir
        dir = realpath(dir)
        src, commit1, branch = make_track_repo(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))
        project_file = joinpath(envdir, "Project.toml")
        write(
            project_file, """
            [deps]
            TrackPkg = "$TRACKPKG_UUID"

            [sources]
            TrackPkg = {path = "../TrackPkg"}
            """
        )
        env = load_environment(envdir; depots)
        planned = plan_resolve(env, RegistryInstance[], Config(depots))
        @test is_path_tracked(planned.manifest[TRACKPKG_UUID])
        write_environment(env, planned)

        # the user flips the entry from path to url+rev by hand
        open(project_file, "w") do io
            TOML.print(
                io, Dict(
                    "deps" => Dict("TrackPkg" => string(TRACKPKG_UUID)),
                    "sources" => Dict("TrackPkg" => Dict("url" => src, "rev" => commit1)),
                )
            )
        end
        env = load_environment(envdir; depots)
        planned = quiet(() -> plan_up(env, RegistryInstance[], Config(depots); fetcher = Git.source_fetcher(depots; io = devnull)))
        entry = planned.manifest[TRACKPKG_UUID]
        @test is_repo_tracked(entry)
        @test entry_repo_url(entry) == src
        @test entry_repo_rev(entry) == commit1
        @test entry_path(entry) === nothing
        @test entry_tree_hash(entry) !== nothing
        write_environment(env, planned)
        env2 = load_environment(envdir; depots)
        @test env2.manifest == planned.manifest
    end
end

# a minimal local registry declaring TrackPkg and its repository url
function make_track_registry(depot, repo_url, tree1)
    reg = joinpath(depot, "registries", "GitTestRegistry")
    pkg = mkpath(joinpath(reg, "T", "TrackPkg"))
    write(
        joinpath(reg, "Registry.toml"), """
        name = "GitTestRegistry"
        uuid = "99999999-9999-9999-9999-999999999999"
        repo = "https://example.invalid/GitTestRegistry"

        [packages]
        $TRACKPKG_UUID = { name = "TrackPkg", path = "T/TrackPkg" }
        """
    )
    open(joinpath(pkg, "Package.toml"), "w") do io
        TOML.print(
            io, Dict(
                "name" => "TrackPkg",
                "uuid" => string(TRACKPKG_UUID),
                "repo" => repo_url,
            )
        )
    end
    write(
        joinpath(pkg, "Versions.toml"), """
        ["0.1.0"]
        git-tree-sha1 = "$tree1"
        """
    )
    return reg
end

# Pkg.jl#4165: a lone `rev` in `[sources]` is honored, with the url inferred
# from the registry
@testset "lone rev in [sources]" begin
    mktempdir() do dir
        dir = realpath(dir)
        src, commit1, branch = make_track_repo(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        tree1 = string(git_tree_hash(src, commit1))
        make_track_registry(depot, src, tree1)
        regs = reachable_registries(depots)
        @test length(regs) == 1

        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            TrackPkg = "$TRACKPKG_UUID"

            [sources]
            TrackPkg = {rev = "$commit1"}
            """
        )
        env = load_environment(envdir; depots)
        planned = quiet(() -> plan_resolve(env, regs, Config(depots); fetcher = Git.source_fetcher(depots; io = devnull)))
        entry = planned.manifest[TRACKPKG_UUID]
        @test is_repo_tracked(entry)
        @test entry_repo_url(entry) == src          # inferred from the registry
        @test entry_repo_rev(entry) == commit1
        @test entry_tree_hash(entry) == git_tree_hash(src, commit1)
    end
end

# Pkg.jl#1925: `dev Name` of a url-added package uses the manifest entry's
# repository url and subdir instead of requiring a registry entry
@testset "dev by name of a url-added subdir package" begin
    mktempdir() do dir
        dir = realpath(dir)
        src = make_subdir_repo(dir)
        subdir = joinpath("pkgs", "SubPkg")
        depot = mkpath(joinpath(dir, "depot"))
        # a registry-less depot would bootstrap General over git (Pkg parity)
        make_test_registry(depot)
        envdir = mkpath(joinpath(dir, "env"))

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_DEVDIR" => nothing) do
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
                VibePkg.add(url = src, subdir = subdir, io = devnull)
                VibePkg.develop("SubPkg"; io = devnull)
                entry = read_manifest(joinpath(envdir, "Manifest.toml"))[SUBPKG_UUID]
                path = entry_path(entry)
                @test path !== nothing
                devpath = isabspath(path) ? path : normpath(joinpath(envdir, path))
                @test endswith(devpath, joinpath("dev", "SubPkg", "pkgs", "SubPkg"))
                @test isfile(joinpath(devpath, "Project.toml"))
                @test isfile(joinpath(devpath, "src", "SubPkg.jl"))
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end

# Pkg.jl#613: instantiating a repo-tracked manifest entry against a fresh
# depot must clone/fetch to install the recorded tree
@testset "instantiate fetches repo package into a fresh depot" begin
    mktempdir() do dir
        dir = realpath(dir)
        src, commit1, branch = make_track_repo(dir)
        depot1 = mkpath(joinpath(dir, "depot1"))
        depots1 = depot_stack([depot1])
        envdir = mkpath(joinpath(dir, "env"))

        rp1 = Git.materialize_repo_package!(depots1, src; rev = branch, io = devnull)
        env = load_environment(envdir; depots = depots1)
        write_environment(env, plan_add(env, RegistryInstance[], Config(depots1), [rp1]; julia_version = VERSION))

        # a new upstream commit; up records commit2's tree in the manifest
        write(joinpath(src, "src", "TrackPkg.jl"), "module TrackPkg\nf() = 613\nend\n")
        commit_all!(src, "second")
        rp2 = Git.materialize_repo_package!(depots1, src; rev = branch, refresh = true, io = devnull)
        @test rp2.tree_hash != rp1.tree_hash
        env = load_environment(envdir; depots = depots1)
        planned = plan_up(env, RegistryInstance[], Config(depots1); repos = [rp2])
        @test entry_tree_hash(planned.manifest[TRACKPKG_UUID]) == rp2.tree_hash
        write_environment(env, planned)

        # a fresh depot has neither the tree nor a clone cache
        depot2 = mkpath(joinpath(dir, "depot2"))
        depots2 = depot_stack([depot2])
        env2 = load_environment(envdir; depots = depots2)
        withenv("JULIA_PKG_SERVER" => "") do
            instantiate!(env2, RegistryInstance[], Config(depots2); io = devnull)
        end
        path, installed = find_installed(depots2, "TrackPkg", TRACKPKG_UUID, rp2.tree_hash)
        @test installed
        @test occursin("f() = 613", read(joinpath(path, "src", "TrackPkg.jl"), String))
    end
end

# Pkg.jl#1065: a repository without an initial commit errors cleanly, and a
# later add (after the first commit exists) succeeds
@testset "add of a repo without commits" begin
    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        src = joinpath(dir, "EmptyPkg")
        repo = LibGit2.init(src)
        LibGit2.close(repo)
        @test_throws PkgError Git.materialize_repo_package!(depots, src; io = devnull)

        # the package gains an initial commit; the cached clone must not
        # stay poisoned
        mkpath(joinpath(src, "src"))
        write(
            joinpath(src, "Project.toml"), """
            name = "EmptyPkg"
            uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
            version = "0.1.0"
            """
        )
        write(joinpath(src, "src", "EmptyPkg.jl"), "module EmptyPkg end\n")
        commit_all!(src, "initial")
        rp = Git.materialize_repo_package!(depots, src; io = devnull)
        @test rp.name == "EmptyPkg"
        @test isfile(joinpath(rp.path, "src", "EmptyPkg.jl"))
    end
end

const SPECIALSETS_UUID = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1")
const REWRITE_UUID = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2")

# two unregistered packages, Rewrite depending on SpecialSets
function make_unregistered_pair(dir)
    special = joinpath(dir, "SpecialSets")
    mkpath(joinpath(special, "src"))
    write(
        joinpath(special, "Project.toml"), """
        name = "SpecialSets"
        uuid = "$SPECIALSETS_UUID"
        version = "0.1.0"
        """
    )
    write(joinpath(special, "src", "SpecialSets.jl"), "module SpecialSets end\n")
    LibGit2.close(LibGit2.init(special))
    commit_all!(special, "initial")

    rewrite = joinpath(dir, "Rewrite")
    mkpath(joinpath(rewrite, "src"))
    write(
        joinpath(rewrite, "Project.toml"), """
        name = "Rewrite"
        uuid = "$REWRITE_UUID"
        version = "0.1.0"

        [deps]
        SpecialSets = "$SPECIALSETS_UUID"
        """
    )
    write(joinpath(rewrite, "src", "Rewrite.jl"), "module Rewrite end\n")
    LibGit2.close(LibGit2.init(rewrite))
    commit_all!(rewrite, "initial")
    return special, rewrite
end

# Pkg.jl#966: up with an unregistered url-added package as an indirect
# dependency must not fail with "no known versions"
@testset "up with unregistered url-added deps" begin
    mktempdir() do dir
        dir = realpath(dir)
        special, rewrite = make_unregistered_pair(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        envdir = mkpath(joinpath(dir, "env"))

        rp_special = Git.materialize_repo_package!(depots, special; io = devnull)
        rp_rewrite = Git.materialize_repo_package!(depots, rewrite; io = devnull)
        env = load_environment(envdir; depots)
        write_environment(env, plan_add(env, RegistryInstance[], Config(depots), [rp_special, rp_rewrite]; julia_version = VERSION))

        # SpecialSets stops being a direct dependency but stays Rewrite's dep
        env = load_environment(envdir; depots)
        write_environment(env, plan_rm(env, [PackageRequest("SpecialSets")]))
        env = load_environment(envdir; depots)
        @test !haskey(env.project.deps, "SpecialSets")
        @test haskey(env.manifest, SPECIALSETS_UUID)

        planned = quiet(() -> plan_up(env, RegistryInstance[], Config(depots)))
        entry = planned.manifest[SPECIALSETS_UUID]
        @test is_repo_tracked(entry)
        @test entry_repo_url(entry) == special
        @test SPECIALSETS_UUID in values(planned.manifest[REWRITE_UUID].deps)
    end
end

# Pkg.jl new.jl "downloads with JULIA_PKG_USE_CLI_GIT" — with the env var set,
# repo materialization goes through the command-line git instead of libgit2 and
# still installs a working, read-only source tree. (VibePkg gates only on
# JULIA_PKG_USE_CLI_GIT; it has no use_git_for_all_downloads/only-tarballs kwargs.)
@testset "materialize via CLI git" begin
    if Sys.which("git") === nothing
        @test_skip "git CLI not available"
    else
        @test Git.use_cli_git() == false                    # default is libgit2
        withenv("JULIA_PKG_USE_CLI_GIT" => "true") do
            @test Git.use_cli_git() == true
            mktempdir() do dir
                src = make_git_package(dir)                  # a local git repo package
                depot = mkpath(joinpath(dir, "depot"))
                depots = depot_stack([depot])
                rp = quiet(() -> Git.materialize_repo_package!(depots, src; io = devnull))
                @test rp !== nothing
                envdir = mkpath(joinpath(dir, "env"))
                env = load_environment(envdir; depots)
                planned = quiet(() -> plan_add(env, RegistryInstance[], Config(depots), [rp]; julia_version = VERSION))
                @test is_repo_tracked(planned.manifest[GITPKG_UUID])
            end
        end
    end
end

# the bare clone caches are shared across environments and processes, so
# clone/fetch/lookup must run under a per-cache pidlock: with the lock held
# elsewhere the operation blocks instead of racing the cache
@testset "clone caches are pidlocked" begin
    mktempdir() do dir
        dir = realpath(dir)
        src = make_git_package(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # materialize_repo_package!: url-keyed cache
        cache = Git.repo_cache_path(depots, src)
        mkpath(dirname(cache))
        lock = mkpidlock(cache * ".pid", stale_age = 10)
        done = Ref(false)
        t = @async begin
            rp = Git.materialize_repo_package!(depots, src; io = devnull)
            done[] = true
            rp
        end
        sleep(2)                     # plenty for the tiny local clone if unlocked
        @test !done[]                # blocked on the held per-cache lock
        close(lock)
        rp = fetch(t)
        @test done[]
        @test rp.name == "GitPkg" && isdir(rp.path)

        # install_tree_from_git!: uuid-keyed cache, fresh depot
        depot2 = mkpath(joinpath(dir, "depot2"))
        depots2 = depot_stack([depot2])
        path, installed = find_installed(depots2, "GitPkg", GITPKG_UUID, rp.tree_hash)
        @test !installed
        clone_pidfile = joinpath(mkpath(VibePkg.Depots.clones_dir(depot2)), string(GITPKG_UUID)) * ".pid"
        lock2 = mkpidlock(clone_pidfile, stale_age = 10)
        done2 = Ref(false)
        t2 = @async begin
            Git.install_tree_from_git!(depots2, devnull, GITPKG_UUID, "GitPkg", rp.tree_hash, [src], path)
            done2[] = true
        end
        sleep(2)
        @test !done2[]
        close(lock2)
        fetch(t2)
        @test done2[]
        @test isfile(joinpath(path, "src", "GitPkg.jl"))
    end
end

const SUBMODPKG_UUID = UUID("70808080-0708-0708-0708-070870870870")

# Pkg.jl#708: adding a git repo that carries a submodule must succeed —
# libgit2 cannot check a gitlink out of the bare clone cache, so the tree is
# extracted by hand; the gitlink becomes an empty directory (what a plain
# `git checkout` leaves for an uninitialized submodule). The same manual path
# must preserve symlinks and executable bits.
@testset "add of a git repo containing a submodule" begin
    if Sys.which("git") === nothing
        @test_skip "git CLI not available"
    else
        mktempdir() do dir
            dir = realpath(dir)
            depot = mkpath(joinpath(dir, "depot"))
            depots = depot_stack([depot])

            # a second local git repo, to be embedded as a submodule
            subrepo = joinpath(dir, "SubDep")
            mkpath(subrepo)
            write(joinpath(subrepo, "README.md"), "submodule content\n")
            LibGit2.close(LibGit2.init(subrepo))
            commit_all!(subrepo, "sub initial")

            # a valid package repo carrying a genuine submodule (.gitmodules +
            # gitlink tree entry); LibGit2's Julia API cannot add submodules,
            # so the CLI git does the setup
            src = joinpath(dir, "SubModPkg")
            mkpath(joinpath(src, "src"))
            write(
                joinpath(src, "Project.toml"), """
                name = "SubModPkg"
                uuid = "$SUBMODPKG_UUID"
                version = "0.1.0"
                """
            )
            write(joinpath(src, "src", "SubModPkg.jl"), "module SubModPkg end\n")
            if !Sys.iswindows()
                # exercise the manual extractor's symlink and exec-bit handling
                mkpath(joinpath(src, "bin"))
                write(joinpath(src, "bin", "tool.sh"), "#!/bin/sh\n")
                chmod(joinpath(src, "bin", "tool.sh"), 0o755)
                symlink("src/SubModPkg.jl", joinpath(src, "srclink"))
            end
            run(pipeline(`git -C $src init -q`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $src -c protocol.file.allow=always submodule add $subrepo vendor/sub`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $src -c user.name=tester -c user.email=t@e.com add -A`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $src -c user.name=tester -c user.email=t@e.com commit -q -m initial`; stdout = devnull, stderr = devnull))
            @test isfile(joinpath(src, ".gitmodules"))

            rp = Git.materialize_repo_package!(depots, src; io = devnull)
            @test rp.name == "SubModPkg"
            @test rp.uuid == SUBMODPKG_UUID
            @test isdir(rp.path)
            @test isfile(joinpath(rp.path, "src", "SubModPkg.jl"))
            @test isfile(joinpath(rp.path, ".gitmodules"))
            # the gitlink materializes as an empty directory
            @test isdir(joinpath(rp.path, "vendor", "sub"))
            @test isempty(readdir(joinpath(rp.path, "vendor", "sub")))
            # canonical tree id (covers the gitlink entry) is recorded
            @test rp.tree_hash == git_tree_hash(src, "HEAD")
            if !Sys.iswindows()
                @test filemode(joinpath(rp.path, "bin", "tool.sh")) & 0o100 != 0
                @test islink(joinpath(rp.path, "srclink"))
                @test readlink(joinpath(rp.path, "srclink")) == "src/SubModPkg.jl"
            end

            # the git install fallback checks the same tree out of the
            # uuid-keyed cache into a fresh depot
            depot2 = mkpath(joinpath(dir, "depot2"))
            depots2 = depot_stack([depot2])
            path, installed = find_installed(depots2, "SubModPkg", SUBMODPKG_UUID, rp.tree_hash)
            @test !installed
            Git.install_tree_from_git!(depots2, devnull, SUBMODPKG_UUID, "SubModPkg", rp.tree_hash, [src], path)
            @test isfile(joinpath(path, "src", "SubModPkg.jl"))
            @test isdir(joinpath(path, "vendor", "sub"))
        end
    end
end

@testset "transfer_progress callback" begin
    # locks the payload contract with transfer_callbacks: (io, bar), delivered
    # in LibGit2's Dict keyed by callback name
    bar = VibePkg.MiniProgressBars.MiniProgressBar(header = "Cloning:", color = :cyan)
    buf = IOBuffer()
    io = IOContext(buf, :displaysize => (24, 80))
    payload = Dict{Symbol, Any}(:transfer_progress => (io, bar))
    tp = Ref(LibGit2.TransferProgress(total_objects = 100, received_objects = 42))
    ret = GC.@preserve tp Git.transfer_progress(
        Base.unsafe_convert(Ptr{LibGit2.TransferProgress}, tp), payload
    )
    @test ret == Cint(0)
    @test bar.max == 100 && bar.current == 42
    @test occursin("42.0 %", String(take!(buf)))
    # delta phase: header switches and the (lower) percentage still redraws
    tp = Ref(
        LibGit2.TransferProgress(
            total_objects = 100, received_objects = 100,
            total_deltas = 50, indexed_deltas = 10,
        )
    )
    bar.time_shown = 0.0
    ret = GC.@preserve tp Git.transfer_progress(
        Base.unsafe_convert(Ptr{LibGit2.TransferProgress}, tp), payload
    )
    @test ret == Cint(0)
    @test bar.header == "Resolving Deltas:"
    @test bar.max == 50 && bar.current == 10
    @test occursin("20.0 %", String(take!(buf)))
end

# init a git repo at `src`, commit everything, return (commit, branch).
function commit_repo!(src)
    repo = LibGit2.init(src)
    LibGit2.add!(repo, ".")
    sig = LibGit2.Signature("tester", "tester@example.com")
    commit = LibGit2.commit(repo, "initial"; author = sig, committer = sig)
    branch = LibGit2.shortname(LibGit2.head(repo))
    LibGit2.close(repo)
    return string(commit), branch
end

# ============================================================================
# Item 1 — Pkg.jl test/sources.jl "test Project.toml [sources]" (line 9)
#   missing pieces: free("Example") drops a [sources] entry, and resolve over a
#   BAD manifest recovers the correct sources (url+rev for one dep, path for
#   another).
# ============================================================================

const EX_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
const LOCAL_UUID = UUID("87654321-4321-4321-4321-cba987654321")

# a git repo package "Example"
function make_example_repo(dir)
    src = joinpath(dir, "Example")
    mkpath(joinpath(src, "src"))
    write(
        joinpath(src, "Project.toml"), """
        name = "Example"
        uuid = "$EX_UUID"
        version = "0.5.0"
        """
    )
    write(joinpath(src, "src", "Example.jl"), "module Example end\n")
    commit, branch = commit_repo!(src)
    return src, commit, branch
end

# a registry declaring Example -> repo_url at version 0.5.0 with tree
function make_example_registry(depot, repo_url, tree)
    reg = joinpath(depot, "registries", "SrcTestRegistry")
    pkg = mkpath(joinpath(reg, "E", "Example"))
    write(
        joinpath(reg, "Registry.toml"), """
        name = "SrcTestRegistry"
        uuid = "11111111-2222-3333-4444-555555555555"
        repo = "https://example.invalid/SrcTestRegistry"

        [packages]
        $EX_UUID = { name = "Example", path = "E/Example" }
        """
    )
    open(joinpath(pkg, "Package.toml"), "w") do io
        TOML.print(io, Dict("name" => "Example", "uuid" => string(EX_UUID), "repo" => repo_url))
    end
    write(
        joinpath(pkg, "Versions.toml"), """
        ["0.5.0"]
        git-tree-sha1 = "$tree"
        """
    )
    return reg
end

@testset "sources: free drops [sources]; resolve recovers over a bad manifest" begin
    mktempdir() do dir
        dir = realpath(dir)
        src, commit, branch = make_example_repo(dir)
        tree = string(git_tree_hash(src, commit))
        depot = mkpath(joinpath(dir, "depot"))
        make_example_registry(depot, src, tree)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        @test length(regs) == 1

        # --- sources.jl 15-21: add(url=..) records a url+rev [sources]; free
        #     removes it and returns the package to registry tracking ---
        rp = Git.materialize_repo_package!(depots, src; io = devnull)
        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        added = plan_add(env, regs, Config(depots), [rp]; julia_version = VERSION)
        aentry = added.manifest[EX_UUID]
        @test is_repo_tracked(aentry)                       # tracked by repo
        @test added.project.sources["Example"].url == src   # url+rev source recorded
        @test added.project.sources["Example"].rev == rp.rev
        write_environment(env, added)

        env = load_environment(envdir; depots)
        freed = plan_free(env, regs, Config(depots), [PackageRequest("Example")])
        fentry = freed.manifest[EX_UUID]
        @test is_registry_tracked(fentry)                   # back to the registry
        @test !is_repo_tracked(fentry)
        @test entry_version(fentry) == v"0.5.0"
        @test !haskey(freed.project.sources, "Example")     # [sources] entry gone
        write_environment(env, freed)
        env = load_environment(envdir; depots)
        @test !haskey(env.project.sources, "Example")
        @test is_registry_tracked(env.manifest[EX_UUID])

        # --- sources.jl 22-26: resolving over a BAD/incorrect manifest recovers
        #     the correct sources: url+rev for Example, path for LocalPkg ---
        local_dir = mkpath(joinpath(dir, "proj", "LocalPkg"))
        mkpath(joinpath(local_dir, "src"))
        write(
            joinpath(local_dir, "Project.toml"), """
            name = "LocalPkg"
            uuid = "$LOCAL_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(local_dir, "src", "LocalPkg.jl"), "module LocalPkg end\n")

        projdir = joinpath(dir, "proj")
        write(
            joinpath(projdir, "Project.toml"), """
            [deps]
            Example = "$EX_UUID"
            LocalPkg = "$LOCAL_UUID"

            [sources]
            Example = {url = "$(toml_str(src))", rev = "$commit"}
            LocalPkg = {path = "LocalPkg"}
            """
        )
        # a deliberately wrong manifest: Example pinned registry-tracked at the
        # wrong shape, LocalPkg missing entirely
        write(
            joinpath(projdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Example]]
            deps = []
            uuid = "$EX_UUID"
            version = "0.5.0"
            git-tree-sha1 = "0000000000000000000000000000000000000000"
            """
        )

        env = load_environment(projdir; depots)
        planned = quiet(() -> plan_resolve(env, regs, Config(depots); fetcher = Git.source_fetcher(depots; io = devnull)))

        # [sources] in the project are authoritative and survive intact
        @test planned.project.sources["Example"].url == src
        @test planned.project.sources["Example"].rev == commit
        @test planned.project.sources["Example"].path === nothing
        @test planned.project.sources["LocalPkg"].path == "LocalPkg"
        @test planned.project.sources["LocalPkg"].url === nothing

        # the recovered manifest tracks Example by its repo (not the bad
        # registry entry) and LocalPkg by path
        eentry = planned.manifest[EX_UUID]
        @test is_repo_tracked(eentry)
        @test entry_repo_url(eentry) == src
        @test entry_repo_rev(eentry) == commit
        @test entry_tree_hash(eentry) == git_tree_hash(src, commit)
        @test is_path_tracked(planned.manifest[LOCAL_UUID])
    end
end

# ============================================================================
# Item 2 — Pkg.jl test/sources.jl "recursive [sources] via repo URLs" (line 93)
#   a Parent -> Child -> Grandchild chain wired through repo urls, plus a
#   path-sourced Sibling living inside Child. add(url=parent) pulls the whole
#   chain with the correct per-level repo url (git_source) and a path-tracked
#   Sibling.
# ============================================================================

const PARENT_UUID = UUID("aa111111-1111-1111-1111-111111111111")
const CHILD_UUID = UUID("aa222222-2222-2222-2222-222222222222")
const GRAND_UUID = UUID("aa333333-3333-3333-3333-333333333333")
const SIB_UUID = UUID("aa444444-4444-4444-4444-444444444444")

@testset "recursive [sources] via repo URLs" begin
    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        # GrandchildPkg — a leaf git repo
        grand = joinpath(dir, "GrandchildPkg")
        mkpath(joinpath(grand, "src"))
        write(
            joinpath(grand, "Project.toml"), """
            name = "GrandchildPkg"
            uuid = "$GRAND_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(grand, "src", "GrandchildPkg.jl"), "module GrandchildPkg\nconst VALUE = 42\nend\n")
        commit_repo!(grand)

        # ChildPkg — depends on GrandchildPkg (url source) and SiblingPkg
        # (path source, committed as a subdirectory of ChildPkg)
        child = joinpath(dir, "ChildPkg")
        mkpath(joinpath(child, "src"))
        sib = joinpath(child, "SiblingPkg")
        mkpath(joinpath(sib, "src"))
        write(
            joinpath(sib, "Project.toml"), """
            name = "SiblingPkg"
            uuid = "$SIB_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(sib, "src", "SiblingPkg.jl"), "module SiblingPkg\noffset() = 5\nend\n")
        write(
            joinpath(child, "Project.toml"), """
            name = "ChildPkg"
            uuid = "$CHILD_UUID"
            version = "0.1.0"

            [deps]
            GrandchildPkg = "$GRAND_UUID"
            SiblingPkg = "$SIB_UUID"

            [sources]
            GrandchildPkg = {url = "$(toml_str(grand))"}
            SiblingPkg = {path = "SiblingPkg"}
            """
        )
        write(joinpath(child, "src", "ChildPkg.jl"), "module ChildPkg\nusing GrandchildPkg, SiblingPkg\nend\n")
        commit_repo!(child)

        # ParentPkg — depends on ChildPkg (url source)
        parent = joinpath(dir, "ParentPkg")
        mkpath(joinpath(parent, "src"))
        write(
            joinpath(parent, "Project.toml"), """
            name = "ParentPkg"
            uuid = "$PARENT_UUID"
            version = "0.1.0"

            [deps]
            ChildPkg = "$CHILD_UUID"

            [sources]
            ChildPkg = {url = "$(toml_str(child))"}
            """
        )
        write(joinpath(parent, "src", "ParentPkg.jl"), "module ParentPkg\nusing ChildPkg\nend\n")
        commit_repo!(parent)

        # add(url=parent): with no registries, the entire chain must come in
        # through the recursively-collected [sources]
        rp = Git.materialize_repo_package!(depots, parent; io = devnull)
        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        planned = quiet(
            () -> plan_add(
                env, RegistryInstance[], Config(depots), [rp];
                julia_version = VERSION, fetcher = Git.source_fetcher(depots; io = devnull),
            )
        )
        m = planned.manifest
        for u in (PARENT_UUID, CHILD_UUID, GRAND_UUID, SIB_UUID)
            @test haskey(m, u)
        end
        # per-level git_source (repo url) is recorded exactly
        @test is_repo_tracked(m[PARENT_UUID]) && entry_repo_url(m[PARENT_UUID]) == parent
        @test is_repo_tracked(m[CHILD_UUID]) && entry_repo_url(m[CHILD_UUID]) == child
        @test is_repo_tracked(m[GRAND_UUID]) && entry_repo_url(m[GRAND_UUID]) == grand
        @test entry_version(m[GRAND_UUID]) == v"0.1.0"
        # the Sibling is path-tracked at Child's committed subdirectory
        sentry = m[SIB_UUID]
        @test is_path_tracked(sentry)
        sp = entry_path(sentry)
        @test sp !== nothing
        @test endswith(sp, "SiblingPkg")
        # survives a write/reload round trip
        write_environment(env, planned)
        env2 = load_environment(envdir; depots)
        @test env2.manifest == planned.manifest
    end
end

# ============================================================================
# Item 3 — Pkg.jl test/subdir.jl (line 237) — path/url subdir add & develop via
#   PackageSpec. Missing pieces: the plain PATH develop of a subdir package,
#   the Package-vs-Dep install-isolation assertions, and the rev-pinned git
#   path add.
#
#   DIVERGENCE: VibePkg's `add(path=...)` always materializes through git, so a
#   plain NON-git path add is not supported (it is a repo-tracked op). That
#   clear error is pinned; develop is what covers the plain-path case.
# ============================================================================

const PACKAGE_UUID = UUID("408b23ff-74ea-48c4-abc7-a671b41e2073")
const DEP_UUID = UUID("d43cb7ef-9818-40d3-bb27-28fb4aa46cc5")

# a monorepo with two packages in subdirectories: Package (in julia/) depends
# on Dep (in dependencies/Dep/)
function make_monorepo(dir)
    repo = joinpath(dir, "Mono")
    pkgdir = joinpath(repo, "julia")
    mkpath(joinpath(pkgdir, "src"))
    write(
        joinpath(pkgdir, "Project.toml"), """
        name = "Package"
        uuid = "$PACKAGE_UUID"
        version = "1.0.0"

        [deps]
        Dep = "$DEP_UUID"
        """
    )
    write(joinpath(pkgdir, "src", "Package.jl"), "module Package end\n")
    depdir = joinpath(repo, "dependencies", "Dep")
    mkpath(joinpath(depdir, "src"))
    write(
        joinpath(depdir, "Project.toml"), """
        name = "Dep"
        uuid = "$DEP_UUID"
        version = "1.0.0"
        """
    )
    write(joinpath(depdir, "src", "Dep.jl"), "module Dep end\n")
    write(joinpath(repo, "README.md"), "top-level\n")
    return repo
end

# a registry declaring Dep (so Package's dep resolves) at 1.0.0
function make_dep_registry(depot)
    reg = joinpath(depot, "registries", "SubdirRegistry")
    pkg = mkpath(joinpath(reg, "D", "Dep"))
    write(
        joinpath(reg, "Registry.toml"), """
        name = "SubdirRegistry"
        uuid = "22222222-3333-4444-5555-666666666666"
        repo = "https://example.invalid/SubdirRegistry"

        [packages]
        $DEP_UUID = { name = "Dep", path = "D/Dep" }
        """
    )
    write(
        joinpath(pkg, "Package.toml"), """
        name = "Dep"
        uuid = "$DEP_UUID"
        repo = "https://example.invalid/Dep.jl"
        """
    )
    write(
        joinpath(pkg, "Versions.toml"), """
        ["1.0.0"]
        git-tree-sha1 = "4444444444444444444444444444444444444444"
        """
    )
    return reg
end

@testset "subdir add/develop via PackageSpec (path + rev) with isolation" begin
    mktempdir() do dir
        dir = realpath(dir)
        repo = make_monorepo(dir)
        depot = mkpath(joinpath(dir, "depot"))
        make_dep_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # --- DIVERGENCE: add of a plain (non-git) path is unsupported; the
        #     materialize seam errors cleanly (VibePkg add-path is git-only) ---
        @test_throws PkgError Git.materialize_repo_package!(depots, repo; subdir = "julia", io = devnull)

        # --- develop from a plain PATH + subdir (non-git); Package installs,
        #     Dep comes along only as Package's (indirect) dependency ---
        envdir = mkpath(joinpath(dir, "env_pkg"))
        env = load_environment(envdir; depots)
        planned = plan_develop(env, regs, Config(depots), [joinpath(repo, "julia")])
        @test haskey(planned.project.deps, "Package")       # named subdir pkg is direct
        @test !haskey(planned.project.deps, "Dep")          # sibling is NOT direct
        @test is_path_tracked(planned.manifest[PACKAGE_UUID])
        @test entry_version(planned.manifest[PACKAGE_UUID]) == v"1.0.0"
        @test haskey(planned.manifest, DEP_UUID)            # Dep present as indirect
        @test is_registry_tracked(planned.manifest[DEP_UUID])

        # --- develop the Dep subdir instead: only Dep installs, no Package ---
        envdir2 = mkpath(joinpath(dir, "env_dep"))
        env2 = load_environment(envdir2; depots)
        planned2 = plan_develop(env2, regs, Config(depots), [joinpath(repo, "dependencies", "Dep")])
        @test haskey(planned2.project.deps, "Dep")
        @test is_path_tracked(planned2.manifest[DEP_UUID])
        @test !haskey(planned2.manifest, PACKAGE_UUID)      # Package NOT dragged in

        # git-init the monorepo so the repo-tracked add path works
        commit, branch = commit_repo!(repo)

        # --- add from a git PATH + subdir (plain, and pinned at rev=branch);
        #     Package installs repo-tracked with the subdir, Dep as indirect ---
        for rev in (nothing, branch)
            rp = Git.materialize_repo_package!(depots, repo; subdir = "julia", rev, io = devnull)
            e = mkpath(joinpath(dir, "env_add_$(rev === nothing ? "plain" : "rev")"))
            env3 = load_environment(e; depots)
            planned3 = plan_add(env3, regs, Config(depots), [rp]; julia_version = VERSION)
            @test haskey(planned3.project.deps, "Package")
            @test !haskey(planned3.project.deps, "Dep")
            pe = planned3.manifest[PACKAGE_UUID]
            @test is_repo_tracked(pe)
            @test entry_repo_subdir(pe) == "julia"
            rev === nothing || @test entry_repo_rev(pe) == branch
            @test haskey(planned3.manifest, DEP_UUID)       # Dep pulled as indirect
            @test is_registry_tracked(planned3.manifest[DEP_UUID])
        end

        # --- add the Dep subdir instead: only Dep, no Package ---
        rpdep = Git.materialize_repo_package!(depots, repo; subdir = joinpath("dependencies", "Dep"), io = devnull)
        envdir4 = mkpath(joinpath(dir, "env_add_dep"))
        env4 = load_environment(envdir4; depots)
        planned4 = plan_add(env4, regs, Config(depots), [rpdep]; julia_version = VERSION)
        @test haskey(planned4.project.deps, "Dep")
        @test is_repo_tracked(planned4.manifest[DEP_UUID])
        @test entry_repo_subdir(planned4.manifest[DEP_UUID]) == joinpath("dependencies", "Dep")
        @test !haskey(planned4.manifest, PACKAGE_UUID)      # Package NOT dragged in
    end
end
