# Content acquisition.
#
# Owns: pkg-server client, downloads, tarball decompression/extraction, and
# the atomic content-addressed package install pipeline. Effectful by
# nature, stateless between calls — all state lives on disk.
#
# Covers the tarball path (pkg server → GitHub archive synthesis) with
# git-exact tree-hash verification, falling back to installing the tree
# from git when no archive source works.

module Fetch

using Base: UUID, SHA1
using Downloads: Downloads
using TOML: TOML
using Tar: Tar
using Random: randstring
import p7zip_jll
import Zstd_jll

using ..Errors: pkgerror
using ..Utils: stderr_f, can_fancyprint, set_readonly, create_cachedir_tag,
    mv_temp_dir_retries, sanitize_url, sanitize_external_error
using ..MiniProgressBars
using ..TreeHash
using ..Depots: DepotStack, depots1, find_installed
using ..Configs: pkg_server
import ..Git
using FileWatching: mkpidlock

export pkg_server, package_archive_urls, ensure_package_installed!, unpack,
    get_extract_cmd, read_tarball_simple, uncompress_registry

##############
# Pkg server #
##############

pkg_server_url(server::String, uuid::UUID, tree_hash::SHA1) =
    "$server/package/$uuid/$tree_hash"

########################
# Auth + telemetry set #
########################
# The full header set goes only to the package server; authentication
# comes from `servers/<host>/auth.toml` in the first depot.

function server_host(server::String)
    m = match(r"^\w+://([^/]+)", server)
    return m === nothing ? server : String(m[1]::SubString{String})
end

"""
    url_is_pkg_server(url, server) -> Bool

Whether `url` addresses the package server `server` and so may carry its
Authorization header. The prefix must end at a path boundary: a raw
`startswith` would also match sibling hosts (`https://pkg.server.evil.tld/…`
for server `https://pkg.server`), sending the bearer token to a host the
package — not the user — chose. `server` comes slash-stripped from
`pkg_server()`.
"""
url_is_pkg_server(url::String, server::String) =
    url == server || startswith(url, server * "/")

# The per-server directory name: characters that are invalid in filenames on
# some platform (':' on Windows, notably from `host:port`) map to '_', e.g.
# "localhost:8888" → "localhost_8888".
server_dirname(server::String) = replace(server_host(server), r"[\\/:*?\"<>|]" => "_")

auth_file_path(depots::DepotStack, server::String) =
    joinpath(depots1(depots), "servers", server_dirname(server), "auth.toml")

# Client-side handlers for authentication failures, tried topmost-first for
# urls matching their scheme (Pkg's AUTH_ERROR_HANDLERS).
const AUTH_ERROR_HANDLERS = Pair{Union{String, Regex}, Any}[]

"""
    register_auth_error_handler(urlscheme, f) -> deregister::Function

Register `f` as the topmost handler for package-server authentication
failures on urls matching `occursin(urlscheme, url)`. `f(url, pkgserver,
err)` must return `(handled::Bool, should_retry::Bool)`; `err` is one of
`"no-auth-file"`, `"malformed-file"`, `"no-access-token"`,
`"no-refresh-key"`, `"insecure-refresh-url"`. When a handler reports
`handled` no further handlers run, and `should_retry` re-runs the token
lookup (once). Returns a zero-argument function that deregisters `f`.
"""
function register_auth_error_handler(urlscheme::Union{AbstractString, Regex}, @nospecialize(f))
    unique!(pushfirst!(AUTH_ERROR_HANDLERS, urlscheme => f))
    return () -> deregister_auth_error_handler(urlscheme, f)
end

"""
    deregister_auth_error_handler(urlscheme, f)

Remove `f` from the stack of authentication error handlers.
"""
function deregister_auth_error_handler(urlscheme::Union{String, Regex}, @nospecialize(f))
    filter!(handler -> !(handler.first == urlscheme && handler.second === f), AUTH_ERROR_HANDLERS)
    return nothing
end

# Whether a handler asked for the token lookup to be retried.
function handle_auth_error(url::String, err::String)
    handled, should_retry = false, false
    for (scheme, handler) in AUTH_ERROR_HANDLERS
        occursin(scheme, url) || continue
        handled, should_retry = handler(url, pkg_server(), err)::Tuple{Bool, Bool}
        handled && break
    end
    return handled && should_retry
end

# The token, refreshed through `refresh_url` when it is (nearly) expired or
# when `force_refresh` is set (the 401 retry path). Failures run the
# registered auth-error handlers, then degrade to anonymous access.
function get_auth_token(
        depots::DepotStack, server::String;
        force_refresh::Bool = false, retried::Bool = false,
    )
    retry_or_nothing(err) = !retried && handle_auth_error(server, err) ?
        get_auth_token(depots, server; force_refresh, retried = true) : nothing
    path = auth_file_path(depots, server)
    isfile(path) || return retry_or_nothing("no-auth-file")
    auth = TOML.tryparsefile(path)
    auth isa TOML.ParserError && return retry_or_nothing("malformed-file")
    token = get(auth, "access_token", nothing)
    token isa String || return retry_or_nothing("no-access-token")

    as_time(x) = x isa Real ? Float64(x) : Inf
    expires_at = min(
        as_time(get(auth, "expires_at", Inf)),
        mtime(path) + as_time(get(auth, "expires_in", Inf)),
    )
    # refresh 10 minutes early when possible
    if force_refresh || time() > expires_at - 600
        refresh_url = get(auth, "refresh_url", nothing)
        refresh_token = get(auth, "refresh_token", nothing)
        if !(refresh_url isa String && refresh_token isa String)
            time() > expires_at && return retry_or_nothing("no-refresh-key")
        elseif !(startswith(refresh_url, "https://") || startswith(refresh_url, "http://localhost"))
            time() > expires_at && return retry_or_nothing("insecure-refresh-url")
        else
            try
                tmp = tempname()
                Downloads.download(
                    refresh_url, tmp;
                    headers = ["Authorization" => "Bearer $refresh_token"],
                )
                new_auth = TOML.parsefile(tmp)
                if haskey(new_auth, "access_token")
                    expires_in = get(new_auth, "expires_in", nothing)
                    if expires_in isa Real
                        new_auth["expires_at"] = floor(Int, time() + expires_in)
                    end
                    mkpath(dirname(path))
                    temp_path, io = mktemp(dirname(path))
                    TOML.print(io, new_auth)
                    close(io)
                    chmod(temp_path, 0o600)
                    mv(temp_path, path; force = true)
                    token = new_auth["access_token"]::String
                    # the freshly issued token is judged by its own expiry,
                    # not the stale one that triggered the refresh
                    expires_at = as_time(get(new_auth, "expires_at", Inf))
                end
                Base.rm(tmp; force = true)
            catch err
                err isa InterruptException && rethrow()
                @warn "Could not refresh credentials for package server $(repr(sanitize_url(server))); continuing without refreshed credentials" cause = sanitize_external_error(err) maxlog = 1
            end
        end
        # an expired token that could not be refreshed is not sent
        if time() > expires_at
            return nothing
        end
    end
    return token
end

const CI_VARIABLES = [
    "APPVEYOR", "CI", "CIRCLECI", "CONTINUOUS_INTEGRATION", "GITHUB_ACTIONS",
    "GITLAB_CI", "JULIA_CI", "JULIA_PKGEVAL", "JULIA_REGISTRYCI_AUTOMERGE",
    "TF_BUILD", "TRAVIS",
]

ci_var_value(v::Union{Nothing, AbstractString}) =
    v === nothing ? "n" : lowercase(v) in ("true", "t", "1", "yes", "y") ? "t" :
    lowercase(v) in ("false", "f", "0", "no", "n") ? "f" : "o"

"""
    pkg_server_headers(server; depots, env, interactive) -> Vector{Pair}

The header set sent (only) to the package server: protocol/version/system
identification, the CI-variable summary, `JULIA_PKG_SERVER_*` forwarding as
`Julia-*` headers, and a bearer token when `auth.toml` provides one.
"""
function pkg_server_headers(
        server::String;
        depots::Union{Nothing, DepotStack} = nothing,
        env::AbstractDict = ENV,
        interactive::Bool = isinteractive(),
        force_auth_refresh::Bool = false,
    )
    headers = Pair{String, String}[
        "Julia-Pkg-Protocol" => "1.0",
        "Julia-Pkg-Server" => server,
        "Julia-Version" => string(VERSION),
        "Julia-System" => Base.BinaryPlatforms.triplet(Base.BinaryPlatforms.HostPlatform()),
        "Julia-CI-Variables" => join(("$v=$(ci_var_value(get(env, v, nothing)))" for v in CI_VARIABLES), ';'),
        "Julia-Interactive" => string(interactive),
    ]
    prefix = "JULIA_PKG_SERVER_"
    for (k, v) in env
        key = String(k)::String
        startswith(key, prefix) || continue
        words = split(key[(length(prefix) + 1):end], '_'; keepempty = false)
        isempty(words) && continue
        push!(headers, "Julia-" * join(titlecase.(lowercase.(words)), '-') => String(v)::String)
    end
    if depots !== nothing
        token = get_auth_token(depots, server; force_refresh = force_auth_refresh)
        token === nothing || push!(headers, "Authorization" => "Bearer $token")
    end
    return headers
end

function github_archive_url(repo_url::String, ref)
    if (m = match(r"https://github.com/(.*?)/(.*?).git", repo_url)) !== nothing
        return "https://api.github.com/repos/$(m.captures[1])/$(m.captures[2])/tarball/$(ref)"
    end
    return nothing
end

"""
    package_archive_urls(uuid, tree_hash, repo_urls; server) -> Vector{Pair{String, Bool}}

Candidate tarball URLs in priority order. The Bool says whether the archive
content is at the tarball top level (pkg server) or nested one directory
down (GitHub-style archives).
"""
function package_archive_urls(
        uuid::UUID, tree_hash::SHA1, repo_urls::Vector{String};
        server::Union{Nothing, String} = pkg_server(),
    )
    urls = Pair{String, Bool}[]
    if server !== nothing
        push!(urls, pkg_server_url(server, uuid, tree_hash) => true)
    end
    for repo_url in repo_urls
        url = github_archive_url(repo_url, tree_hash)
        url !== nothing && push!(urls, url => false)
    end
    return urls
end

############
# Download #
############

function download(
        url::String, dest::String;
        io::IO = stderr_f(), progress_header::Union{Nothing, String} = nothing,
        depots::Union{Nothing, DepotStack} = nothing,
        show_progress::Bool = true,
    )
    server = pkg_server()
    is_server_url = server !== nothing && url_is_pkg_server(url, server)
    headers = is_server_url ? pkg_server_headers(server::String; depots) : Pair{String, String}[]
    perform_download() = try
        _download(url, dest, headers; io, progress_header, show_progress)
    catch err
        if err isa Downloads.RequestError
            throw(
                Downloads.RequestError(
                    sanitize_url(err.url), err.code, sanitize_url(err.message), err.response,
                )
            )
        end
        rethrow()
    end
    resp = perform_download()
    if is_server_url && resp.status == 401
        # HTTP 401: the token was stale or revoked — refresh it and retry
        # once; a second 401 surfaces the server's response body
        headers = pkg_server_headers(server::String; depots, force_auth_refresh = true)
        resp = perform_download()
        if resp.status == 401
            body = isfile(dest) ? String(read(dest)) : ""
            body = sanitize_url(first(body, min(length(body), 4096)))
            pkgerror(
                "Authentication failure (HTTP 401) downloading $(sanitize_url(url))" *
                    (isempty(strip(body)) ? "" : ":\n" * body)
            )
        end
    end
    # Downloads.download semantics for every other failure status
    if resp.proto in ("http", "https") && !(200 <= resp.status < 300)
        throw(Downloads.RequestError(sanitize_url(url), 0, "", resp))
    end
    return dest
end

# One GET of `url` into `dest`. Unlike `Downloads.download` this returns the
# response for any HTTP status — error bodies land in `dest` so the 401
# handling above can surface them. Transport failures still throw.
function _download(
        url::String, dest::String, headers::Vector{Pair{String, String}};
        io::IO, progress_header::Union{Nothing, String}, show_progress::Bool,
    )::Downloads.Response
    return if show_progress && can_fancyprint(io)
        bar = MiniProgressBar(;
            header = something(progress_header, "Downloading"),
            color = Base.info_color(), mode = :data,
        )
        start_progress(io, bar)
        try
            Downloads.request(
                url; output = dest, headers,
                progress = (total, now, _, _) -> begin
                    if total > 0
                        bar.max = total
                        bar.current = now
                        bar.status = ""
                        MiniProgressBars.show_progress(io, bar)
                    elseif now > 0
                        # no Content-Length (e.g. chunked GitHub archives):
                        # show the bytes received instead of nothing at all
                        bar.status = MiniProgressBars.pkg_format_bytes(now; digits = 1)
                        MiniProgressBars.show_progress(io, bar)
                    end
                end,
            )::Downloads.Response
        finally
            end_progress(io, bar)
        end
    else
        Downloads.request(url; output = dest, headers)::Downloads.Response
    end
end

###############
# Tar/unpack  #
###############

function get_extract_cmd(file::AbstractString)
    # p7zip normalizes `..` path segments internally, mis-resolving them when
    # symlinks are present, so pass it a fully resolved path.
    file = realpath(file)
    magic = open(io -> read(io, 4), file)
    if length(magic) == 4 && magic == UInt8[0x28, 0xb5, 0x2f, 0xfd]
        return `$(Zstd_jll.zstd()) -d -q -c $file`
    else
        return `$(p7zip_jll.p7zip()) x -so $file`
    end
end

"Extract a (compressed) tarball into directory `dest`."
function unpack(tarball::String, dest::String)
    return open(get_extract_cmd(tarball)) do io
        Tar.extract(io, dest)
    end
end

# Simplified tarball reader without path tracking overhead. Entries the
# predicate rejects have their data drained so the stream stays aligned on
# the next header; the callback must itself consume every accepted entry's
# data (e.g. via `Tar.read_data`).
function read_tarball_simple(
        callback::Function,
        predicate::Function,
        tar::IO;
        buf::Vector{UInt8} = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE),
    )
    globals = Dict{String, String}()
    while !eof(tar)
        hdr = Tar.read_header(tar, globals = globals, buf = buf)
        hdr === nothing && break
        if !(predicate(hdr)::Bool)
            Tar.skip_data(tar, hdr.size)
            continue
        end
        Tar.check_header(hdr)
        before = applicable(position, tar) ? position(tar) : 0
        callback(hdr)
        applicable(position, tar) || continue
        advanced = position(tar) - before
        expected = Tar.round_up(hdr.size)
        advanced == expected ||
            error("Internal archive-reader error: callback read $advanced bytes; expected $expected")
    end
    return
end

"Read a packed registry tarball fully into memory as path => content."
function uncompress_registry(compressed_tar::AbstractString)
    if !isfile(compressed_tar)
        error("Registry or package archive $(repr(compressed_tar)) does not exist")
    end
    data = Dict{String, String}()
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    io = IOBuffer()
    open(get_extract_cmd(compressed_tar)) do tar
        read_tarball_simple(x -> true, tar; buf = buf) do hdr
            Tar.read_data(tar, io; size = hdr.size, buf = buf)
            data[hdr.path] = String(take!(io))
        end
    end
    return data
end

#######################
# Atomic installation #
#######################

# Try each archive URL in order: download → unpack (into a temp dir on the
# same filesystem as the destination) → verify the git tree hash → atomic
# rename. Returns whether one of the sources succeeded.
function install_archive(
        urls::Vector{Pair{String, Bool}},
        hash::SHA1,
        version_path::String;
        name::Union{String, Nothing} = nothing,
        depots::Union{Nothing, DepotStack} = nothing,
        io::IO = stderr_f(),
    )::Bool
    depot_temp = mkpath(joinpath(dirname(dirname(version_path)), "temp")) # packages/temp
    create_cachedir_tag(dirname(dirname(version_path)))

    tmp_objects = String[]
    url_success = false
    try
        for (url, top) in urls
            path = tempname() * randstring(6)
            push!(tmp_objects, path)
            url_success = true
            try
                download(url, path; io, depots, progress_header = name === nothing ? "Downloading" : "Downloading $(name)")
            catch e
                e isa InterruptException && rethrow()
                url_success = false
            end
            url_success || continue
            dir = tempname(depot_temp) * randstring(6)
            push!(tmp_objects, dir)
            # a corrupt or malformed archive disqualifies this source only:
            # the next url may still deliver good content
            try
                unpack(path, dir)
            catch e
                e isa InterruptException && rethrow()
                @warn "Failed to extract archive downloaded from $(sanitize_url(url)); skipping this source" package = name exception = e
                url_success = false
            end
            url_success || continue
            if top
                unpacked = dir
            else
                dirs = readdir(dir)
                # 7z on Windows might create this spurious file
                filter!(x -> x != "pax_global_header", dirs)
                if length(dirs) != 1
                    @warn "Archive downloaded from $(sanitize_url(url)) must contain one top-level directory; skipping this source" package = name entries_found = length(dirs)
                    url_success = false
                    continue
                end
                unpacked = joinpath(dir, dirs[1])
            end
            computed_hash = try
                SHA1(TreeHash.tree_hash(unpacked))
            catch e
                e isa InterruptException && rethrow()
                @warn "Failed to compute the Git tree SHA-1 of content downloaded from $(sanitize_url(url)); skipping this source" package = name exception = e
                url_success = false
                continue
            end
            if computed_hash != hash
                @warn "Downloaded package content does not match the expected Git tree SHA-1; skipping this source" package = name url = sanitize_url(url) expected = hash computed = computed_hash
                url_success = false
            end
            url_success || continue

            !isdir(dirname(version_path)) && mkpath(dirname(version_path))
            mv_temp_dir_retries(unpacked, version_path; set_permissions = false)
            break
        end
    finally
        foreach(x -> Base.rm(x; force = true, recursive = true), tmp_objects)
    end
    return url_success
end

"""
    ensure_package_installed!(depots, name, uuid, tree_hash, repo_urls; archive_urls, readonly, io)
        -> (path, new::Bool)

Idempotent content-addressed install: returns the existing tree if any depot
has it, otherwise downloads/verifies/installs into the first depot under a
pidlock. Throws when every source fails. `repo_urls` feeds the git fallback;
`archive_urls` (default: the same list) feeds GitHub tarball synthesis —
callers exclude subdir-package repos there, since a repo-root tarball cannot
verify against the subdir tree hash while the git fallback finds the subdir
tree object directly.
"""
function ensure_package_installed!(
        depots::DepotStack, name::String, uuid::UUID, tree_hash::SHA1,
        repo_urls::Vector{String};
        archive_urls::Vector{String} = repo_urls,
        readonly::Bool = true, io::IO = stderr_f(),
        server::Union{Nothing, String} = pkg_server(),
    )
    path, installed = find_installed(depots, name, uuid, tree_hash)
    installed && return path, false

    urls = package_archive_urls(uuid, tree_hash, archive_urls; server)
    mkpath(dirname(path))
    # `already` distinguishes "another process installed the tree while we
    # blocked on the pidlock" from "we installed it": only the latter is `new`.
    already = Ref(false)
    success = mkpidlock(path * ".pid", stale_age = 10) do
        isdir(path) && (already[] = true; return true)
        isempty(urls) ? false : install_archive(urls, tree_hash, path; name, depots, io)
    end
    if !success
        # archives failed (or none available): fall back to git
        mkpidlock(path * ".pid", stale_age = 10) do
            isdir(path) && (already[] = true; return)
            Git.install_tree_from_git!(depots, io, uuid, name, tree_hash, repo_urls, path)
        end
    end
    new = !already[]
    new && @debug "Installed $name"
    readonly && new && set_readonly(path)
    return path, new
end

end # module
