# Git operations: clone/fetch/checkout via LibGit2
# (or the CLI with JULIA_PKG_USE_CLI_GIT), the bare clone caches in the
# depot, tree installation from git as the archive fallback, and repo
# materialization — the effectful pre-phase of add-by-url.
#
# Ported from Pkg's GitTools + Operations.install_git + Types repo handling.
# Clone caches are keyed by a sha1 of the URL — a deliberate fix: Pkg keys
# them by `Base.hash(url)`, which changes between julia versions.

module Git

using Base: UUID, SHA1
import LibGit2
using SHA: sha1

using ..Errors: PkgError, pkgerror
using ..Utils: stderr_f, can_fancyprint, mv_temp_dir_retries,
    create_cachedir_tag
using ..Timing: @timeit, TIMER
using ..MiniProgressBars
using ..TreeHash
using ..EnvFiles: read_project, projectfile_path, RepoPackage
using ..Depots: DepotStack, depots1, clones_dir, find_installed

export ensure_clone, install_tree_from_git!, materialize_repo_package!,
    source_fetcher, RepoPackage

use_cli_git() = Base.get_bool_env("JULIA_PKG_USE_CLI_GIT", false) === true

const RESOLVING_DELTAS_HEADER = "Resolving Deltas:"

function transfer_progress(progress::Ptr{LibGit2.TransferProgress}, p::Any)
    progress = unsafe_load(progress)
    io, bar = p[:transfer_progress]::Tuple{IO, MiniProgressBar}
    if progress.total_deltas != 0
        # show_progress redraws on header change and on backwards progress,
        # so the phase switch needs no further bookkeeping
        bar.header = RESOLVING_DELTAS_HEADER
        bar.max = progress.total_deltas
        bar.current = progress.indexed_deltas
    else
        bar.max = progress.total_objects
        bar.current = progress.received_objects
    end
    show_progress(io, bar)
    return Cint(0)
end

function transfer_callbacks(fancyprint::Bool, io::IO, bar::MiniProgressBar)
    return if fancyprint
        LibGit2.Callbacks(
            :transfer_progress => (
                @cfunction(transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
                (io, bar),
            )
        )
    else
        LibGit2.Callbacks()
    end
end

function supports_shallow_clone()
    Sys.iswindows() && return false     # buggy on Windows
    has_version = @static if isdefined(LibGit2, :VERSION)
        LibGit2.VERSION >= v"1.7.0"
    else
        false
    end
    return has_version && isdefined(LibGit2, :isshallow)
end

is_local_repo(url::AbstractString) = ispath(url) || startswith(url, "file://")

const GIT_REGEX =
    r"^(?:(?<proto>git|ssh|https)://)?(?:[\w\.\+\-:]+@)?(?<hostname>.+?)(?(<proto>)/|:(?:(?<port>\d+)/)?)(?<path>.+?)(?:\.git)?$"
const GIT_PROTOCOLS = Dict{String, Union{Nothing, String}}()
const GIT_USERS = Dict{String, Union{Nothing, String}}()

function setprotocol!(;
        domain::AbstractString = "github.com",
        protocol::Union{Nothing, AbstractString} = nothing,
        user::Union{Nothing, AbstractString} = (protocol == "ssh" ? "git" : nothing),
    )
    domain = lowercase(domain)
    GIT_PROTOCOLS[domain] = protocol
    return GIT_USERS[domain] = user
end

function normalize_url(url::AbstractString)
    url = rstrip(url, '/')              # LibGit2 is fussy about trailing slash
    m = match(GIT_REGEX, url)
    m === nothing && return String(url)
    host = m[:hostname]
    host === nothing && return String(url)
    path = "$(m[:path]).git"
    proto = get(GIT_PROTOCOLS, lowercase(host), nothing)
    return if proto === nothing
        String(url)
    else
        user = get(GIT_USERS, lowercase(host), nothing)
        user = user === nothing ? "" : "$user@"
        port = m[:port] === nothing ? "" : ":$(m[:port])"
        "$proto://$user$host$port/$path"
    end
end

function clone(io::IO, url, source_path; header = nothing, credentials = nothing, isbare::Bool = false, depth::Integer = 0)
    url = String(url)::String
    source_path = String(source_path)::String
    @assert !isdir(source_path) || isempty(readdir(source_path))
    url = normalize_url(url)
    if depth > 0 && (is_local_repo(url) || !supports_shallow_clone())
        depth = 0
    end
    printstyled(io, lpad("Cloning", 12); color = :green, bold = true)
    println(io, " ", header === nothing ? "git-repo `$url`" : header)
    bar = MiniProgressBar(header = "Cloning:", color = Base.info_color())
    fancyprint = can_fancyprint(io)
    fancyprint && start_progress(io, bar)
    if credentials === nothing
        credentials = LibGit2.CachedCredentials()
    end
    return try
        if use_cli_git()
            args = ["--quiet"]
            depth > 0 && push!(args, "--depth=$depth")
            isbare && push!(args, "--bare")
            push!(args, url, source_path)
            cmd = `git clone $args`
            try
                run(pipeline(cmd; stdout = devnull))
            catch err
                pkgerror("The command $(cmd) failed, error: $err")
            end
            LibGit2.GitRepo(source_path)
        else
            callbacks = transfer_callbacks(fancyprint, io, bar)
            mkpath(source_path)
            if depth > 0
                LibGit2.clone(url, source_path; callbacks, credentials, isbare, depth)
            else
                LibGit2.clone(url, source_path; callbacks, credentials, isbare)
            end
        end
    catch err
        Base.rm(source_path; force = true, recursive = true)
        err isa LibGit2.GitError || err isa InterruptException || rethrow()
        if err isa InterruptException
            pkgerror("git clone of `$url` interrupted")
        elseif (err.class == LibGit2.Error.Net && err.code == LibGit2.Error.EINVALIDSPEC) ||
                (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ENOTFOUND)
            pkgerror("git repository not found at `$(url)`: ($(err.msg))")
        else
            pkgerror("failed to clone from $(url): ($(err.msg))")
        end
    finally
        Base.shred!(credentials)
        fancyprint && end_progress(io, bar)
    end
end

function ensure_clone(io::IO, target_path, url; kwargs...)
    if ispath(target_path)
        return LibGit2.GitRepo(target_path)
    else
        return clone(io, url, target_path; kwargs...)
    end
end

function geturl(repo)
    return LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo, "origin")) do remote
        LibGit2.url(remote)
    end
end

function fetch(io::IO, repo::LibGit2.GitRepo, remoteurl = nothing; header = nothing, credentials = nothing, refspecs::Vector{String} = [""], depth::Integer = 0)
    if remoteurl === nothing
        remoteurl = geturl(repo)
    end
    if depth > 0 && (is_local_repo(remoteurl) || !supports_shallow_clone())
        depth = 0
    end
    remoteurl = normalize_url(remoteurl)
    printstyled(io, lpad("Updating", 12); color = :green, bold = true)
    println(io, " ", header === nothing ? "git-repo `$remoteurl`" : header)
    bar = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    fancyprint = can_fancyprint(io)
    fancyprint && start_progress(io, bar)
    if credentials === nothing
        credentials = LibGit2.CachedCredentials()
    end
    return try
        if use_cli_git()
            args = ["-C", LibGit2.path(repo), "fetch", "-q"]
            depth > 0 && push!(args, "--depth=$depth")
            push!(args, remoteurl, only(refspecs))
            cmd = `git $args`
            try
                run(pipeline(cmd; stdout = devnull))
            catch err
                pkgerror("The command $(cmd) failed, error: $err")
            end
        else
            callbacks = transfer_callbacks(fancyprint, io, bar)
            if depth > 0
                LibGit2.fetch(repo; remoteurl, callbacks, credentials, refspecs, depth)
            else
                LibGit2.fetch(repo; remoteurl, callbacks, credentials, refspecs)
            end
        end
    catch err
        err isa LibGit2.GitError || rethrow()
        if (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ERROR)
            pkgerror("Git repository not found at '$(remoteurl)': ($(err.msg))")
        else
            pkgerror("failed to fetch from $(remoteurl): ($(err.msg))")
        end
    finally
        Base.shred!(credentials)
        fancyprint && end_progress(io, bar)
    end
end

function checkout_tree_to_path(repo::LibGit2.GitRepo, tree::LibGit2.GitObject, path::String)
    return GC.@preserve path begin
        opts = LibGit2.CheckoutOptions(
            checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
            # Package trees must contain the canonical blob bytes.  In
            # particular, a user's Windows core.autocrlf setting must not
            # rewrite LF to CRLF and change the computed git-tree-sha1.
            disable_filters = Cint(1),
            target_directory = Base.unsafe_convert(Cstring, path)
        )
        LibGit2.checkout_tree(repo, tree, options = opts)
    end
end

# Stable clone-cache path for a URL (Pkg uses Base.hash(url), which is not
# stable across julia versions — a spec §12 fix).
repo_cache_path(depots::DepotStack, url::String) =
    joinpath(clones_dir(depots1(depots)), bytes2hex(sha1(url))[1:16])

# Heads-only by default: `refs/*` on hosts like GitHub advertises every
# pull-request head ever opened, so a broad fetch drags in all of them. The
# broad spelling stays as the not-found fallback (tags, exotic ref
# namespaces) — Pkg parity: Types.refspecs / refspecs_fallback.
const refspecs = ["+refs/heads/*:refs/cache/heads/*"]
const refspecs_fallback = ["+refs/*:refs/cache/*"]

# Commit hashes are 7-40 hex characters (Pkg parity)
looks_like_commit_hash(rev::AbstractString) = occursin(r"^[0-9a-f]{7,40}$"i, rev)

# Fetched refs land under refs/cache/* (see `refspecs` above) and the
# clone-time refs never move afterwards, so a rev must prefer the cache
# refs or it pins itself to the clone-time tip. The kind says where the
# rev resolved (Pkg's `isbranch`): only branches and pull-request heads
# move, so only they are refetched by `refresh`.
function lookup_rev(repo::LibGit2.GitRepo, rev::String)
    specs = (
        ("cache/heads/" * rev, :branch),
        ("cache/tags/" * rev, :tag),
        ("cache/" * rev, :other),       # pull-request heads land here
        ("heads/" * rev, :branch),      # clone-time local branch
        (rev, :other),                  # clone-time tags, commit hashes
    )
    for (spec, kind) in specs
        obj = try
            LibGit2.GitObject(repo, spec)
        catch err
            err isa LibGit2.GitError &&
                err.code in (LibGit2.Error.ENOTFOUND, LibGit2.Error.EINVALIDSPEC) || rethrow()
            nothing
        end
        obj === nothing || return obj, kind
    end
    return nothing, :other
end

const PULL_REV_RE = r"^pull/(\d+)/head$"
branch_refspec(rev::String) = "+refs/heads/$rev:refs/cache/heads/$rev"
pull_refspec(pr::AbstractString) = "+refs/pull/$pr/head:refs/cache/pull/$pr/head"

# Targeted fetch attempts for a rev missing from the cache, by its shape: a
# single shallow ref fetch when the name can tell us where it lives (a
# pull-request head, a branch, a tag — tried in that order for plain names,
# with a lookup between attempts), or one unshallow branch fetch for commit
# hashes (an arbitrary sha cannot be named in a refspec). Anything still
# missing lands in the caller's broad refs/* fallback. Improves on Pkg,
# which has no tag attempt and fetches every ref for `add url#tag`.
function rev_fetch_attempts(rev::String)
    m = match(PULL_REV_RE, rev)
    return if m !== nothing
        [([pull_refspec(String(m[1]::SubString{String}))], 1)]
    elseif looks_like_commit_hash(rev)
        [(refspecs, Int(LibGit2.Consts.FETCH_DEPTH_UNSHALLOW))]
    else
        [
            ([branch_refspec(rev)], 1),
            (["+refs/tags/$rev:refs/cache/tags/$rev"], 1),
        ]
    end
end

function try_fetch(io::IO, repo::LibGit2.GitRepo, url::String, refspecs::Vector{String}, depth::Integer)
    try
        fetch(io, repo, url; refspecs, depth)
    catch err
        # e.g. no such remote ref: the next attempt or the fallback decides
        err isa PkgError || rethrow()
    end
    return
end

"""
    install_tree_from_git!(depots, io, uuid, name, hash, urls, version_path)

The git fallback of package installation: find tree `hash` in a bare clone
cache (fetching from `urls` as needed) and check it out to `version_path`.
"""
function install_tree_from_git!(
        depots::DepotStack, io::IO, uuid::UUID, name::String, hash::SHA1,
        urls::Vector{String}, version_path::String,
    )
    if isempty(urls)
        pkgerror(
            "Package $name [$uuid] has no repository URL available. This could happen if:\n" *
                "  - The package is not registered in any configured registry\n" *
                "  - The package exists in a registry but lacks repository information\n" *
                "  - Registry files are corrupted or incomplete\n" *
                "  - Network issues prevented registry updates\n" *
                "Please check that the package name is correct and that your registries are up to date."
        )
    end
    repo = nothing
    tree = nothing
    return try
        cdir = mkpath(clones_dir(depots1(depots)))
        create_cachedir_tag(cdir)
        repo_path = joinpath(cdir, string(uuid))
        first_url = first(urls)
        repo = ensure_clone(
            io, repo_path, first_url; isbare = true,
            header = "[$uuid] $name from $first_url", depth = 1
        )
        git_hash = LibGit2.GitHash(hash.bytes)
        for url in urls
            try
                LibGit2.with(LibGit2.GitObject, repo, git_hash) do g
                end
                break # object was found, we can stop
            catch err
                err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            end
            # the registry records only a tree hash, so there is nothing to
            # target: deepen and take every ref (a release commit may only be
            # reachable from a tag)
            fetch(io, repo, url; refspecs = refspecs_fallback, depth = LibGit2.Consts.FETCH_DEPTH_UNSHALLOW)
        end
        tree = try
            LibGit2.GitObject(repo, git_hash)
        catch err
            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            error("$name: git object $(string(hash)) could not be found")
        end
        tree isa LibGit2.GitTree ||
            error("$name: git object $(string(hash)) should be a tree, not $(typeof(tree))")
        mkpath(version_path)
        create_cachedir_tag(dirname(dirname(version_path)))
        checkout_tree_to_path(repo, tree, version_path)
        nothing
    finally
        repo !== nothing && close(repo)
        tree !== nothing && close(tree)
    end
end

##############################
# Repo package materializing #
##############################
# The `RepoPackage` value this produces lives in EnvFiles (a materialized
# fact both this module and Planning know without importing each other).

"""
    source_fetcher(depots; io) -> fetcher

The repo-source fetch capability planning receives from the API layer:
`fetcher(url; rev, subdir) -> RepoPackage`. Planning
itself never touches the network — a plan that needs a missing repo tree
calls this injected function.
"""
source_fetcher(depots::DepotStack; io::IO = stderr_f()) =
    (url; rev = nothing, subdir = nothing) ->
materialize_repo_package!(depots, url; rev, subdir, io)

"walk up from `path` to the enclosing git work tree (stopping at home)"
function discover_repo(path::AbstractString, stop_dirs::Vector{String} = String[homedir()])
    dir = abspath(path)
    while true
        dir in stop_dirs && return nothing
        gitdir = joinpath(dir, ".git")
        (isdir(gitdir) || isfile(gitdir)) && return dir
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
    return
end

"an IO over `spec` (e.g. \"HEAD:Project.toml\"); `fakeit` gives an empty stream when absent"
function git_file_stream(repo::LibGit2.GitRepo, spec::String; fakeit::Bool = false)::IO
    blob = try
        LibGit2.GitBlob(repo, spec)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
        fakeit && return devnull
        rethrow()
    end
    iob = IOBuffer(LibGit2.content(blob))
    close(blob)
    return iob
end

"""
    materialize_repo_package!(depots, url; rev, subdir, io) -> RepoPackage

The effectful pre-phase of add-by-url: clone/update the repo cache, resolve
`rev` (default branch when not given), check the tree out into the package
store, and read the package's Project.toml for its identity.
"""
@timeit TIMER "materialize repo" function materialize_repo_package!(
        depots::DepotStack, url::String;
        rev::Union{Nothing, String} = nothing,
        subdir::Union{Nothing, String} = nothing,
        refresh::Bool = false,
        io::IO = stderr_f(),
    )
    cache = repo_cache_path(depots, url)
    mkpath(dirname(cache))
    create_cachedir_tag(dirname(cache))
    repo = ensure_clone(io, cache, url; isbare = true, depth = 1)
    obj = nothing
    return try
        actual_rev = rev
        if rev === nothing
            head = try
                LibGit2.head(repo)
            catch err
                err isa LibGit2.GitError || rethrow()
                # a repository without commits clones fine but has no HEAD;
                # drop the cached clone so commits made upstream later are
                # picked up by a re-add
                close(repo)
                Base.rm(cache; force = true, recursive = true)
                pkgerror("invalid git HEAD in $url ($(err.msg))")
            end
            actual_rev = LibGit2.shortname(head)
            obj = LibGit2.peel(LibGit2.GitCommit, LibGit2.GitObject(repo, LibGit2.GitHash(head)))
        else
            obj, kind = lookup_rev(repo, rev)
            # `refresh` (the up flow): a branch or pull-request head only
            # moves if we fetch first — a cached rev would otherwise resolve
            # to its stale tip. Tags and commit hashes are immutable; a rev
            # not in the cache at all is fetched fresh below either way.
            pull = match(PULL_REV_RE, rev)
            if refresh && obj !== nothing && (kind === :branch || pull !== nothing)
                close(obj)
                refspec = pull === nothing ? branch_refspec(rev) :
                    pull_refspec(String(pull[1]::SubString{String}))
                try_fetch(io, repo, url, [refspec], 1)
                obj, kind = lookup_rev(repo, rev)
            end
            if obj === nothing
                for (refspecs, depth) in rev_fetch_attempts(rev)
                    try_fetch(io, repo, url, refspecs, depth)
                    obj, kind = lookup_rev(repo, rev)
                    obj === nothing || break
                end
            end
            if obj === nothing
                # ref namespaces the targeted attempts cannot name
                fetch(io, repo, url; refspecs = refspecs_fallback)
                obj, kind = lookup_rev(repo, rev)
            end
            obj === nothing && pkgerror("git object $(repr(rev)) could not be found in `$url`")
        end

        # Check the (sub)tree out to a scoped temp dir and move it into the
        # store.  Use the Git object's canonical id: re-hashing a Windows
        # checkout can lose Unix mode information and produce an id that does
        # not exist in the repository (and therefore cannot be re-fetched).
        # snapshot the resolved object/rev into single-assignment locals so the
        # closure below captures them without boxing (`obj`/`actual_rev` are
        # reassigned across the resolution branches above)
        checkout_obj = obj
        checkout_rev = actual_rev
        mktempdir() do temp
            tree = LibGit2.peel(LibGit2.GitTree, checkout_obj)
            package_tree = nothing
            try
                checkout_tree_to_path(repo, tree, temp)
                pkg_root = subdir === nothing ? temp : joinpath(temp, subdir)
                isdir(pkg_root) || pkgerror("path `$subdir` does not exist in the repository at `$url`")
                git_subdir = subdir === nothing ? "." : replace(normpath(subdir), '\\' => '/')
                package_tree = git_subdir == "." ? tree : tree[git_subdir]
                package_tree isa LibGit2.GitTree || pkgerror(
                    "path `$subdir` is not a directory in the repository at `$url`"
                )
                tree_hash = SHA1(string(LibGit2.GitHash(package_tree)))

                project_file = projectfile_path(pkg_root; strict = true)
                project_file === nothing && pkgerror(
                    "could not find project file (Project.toml or JuliaProject.toml) in package at `$url` maybe `subdir` needs to be specified"
                )
                project = read_project(project_file)
                (project.name === nothing || project.uuid === nothing) && pkgerror(
                    "expected a `name` and `uuid` entry in project file at `$project_file`"
                )

                path, installed = find_installed(depots, project.name, project.uuid, tree_hash)
                if !installed
                    mkpath(dirname(path))
                    mv_temp_dir_retries(pkg_root, path; set_permissions = false)
                end
                RepoPackage(project.name, project.uuid, url, checkout_rev, subdir, tree_hash, path)
            finally
                package_tree !== nothing && package_tree !== tree && close(package_tree)
                close(tree)
            end
        end
    finally
        obj !== nothing && close(obj)
        close(repo)
    end
end

end # module
