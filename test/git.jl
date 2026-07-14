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
using VibePkg.Planning: plan_add, plan_up, plan_resolve, plan_rm, PackageRequest
using VibePkg.Execution: instantiate!
using VibePkg.TreeHash: tree_hash
using VibePkg.Utils: DEFAULT_IO
using VibePkg.EnvFiles: entry_version, entry_repo_url, entry_repo_rev,
    entry_repo_subdir, entry_tree_hash, entry_path, is_repo_tracked,
    is_path_tracked, read_manifest

# planning-time materialization prints clone/fetch progress via the default
# IO; tests run it against devnull
quiet(f) = Base.ScopedValues.with(f, DEFAULT_IO => devnull)

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
