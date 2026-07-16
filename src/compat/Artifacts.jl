# Pkg.Artifacts-compatible namespace: the query + install surface packages
# need at runtime. Queries re-export the Artifacts stdlib (environment-
# agnostic, override-aware); installs go through ArtifactOps against the
# session depots. Lazy artifacts are skipped at instantiate/add time (like
# Pkg) and installed on demand through `ensure_artifact_installed` — the
# entry point LazyArtifacts-style lazy loading bottoms out in.
module Artifacts
using Artifacts: artifact_meta, artifact_hash, artifact_exists, artifact_path,
    find_artifacts_toml, select_downloadable_artifacts,
    pack_platform!, unpack_platform, with_artifacts_directory,
    artifacts_dirs, query_override
using Base: SHA1
using Base.BinaryPlatforms: AbstractPlatform, HostPlatform, platforms_match, triplet
using SHA: sha256
import TOML

using ..Errors: pkgerror
using ..Utils: stderr_f, create_cachedir_tag, mv_temp_dir_retries, atomic_toml_write
using ..Depots: depot_stack, log_usage
using FileWatching: mkpidlock
import ..ArtifactOps
import ..Fetch
import ..TreeHash

export artifact_meta, artifact_hash, artifact_exists, artifact_path,
    find_artifacts_toml, select_downloadable_artifacts,
    ensure_artifact_installed, remove_artifact, verify_artifact,
    create_artifact, archive_artifact, with_artifacts_directory,
    bind_artifact!, unbind_artifact!

"""
    ensure_artifact_installed(name, artifacts_toml; platform, io) -> path

Install the artifact `name` from `artifacts_toml` (lazy or not) if it is
not already present, returning its installed path.
"""
function ensure_artifact_installed(
        name::String, artifacts_toml::String;
        platform::AbstractPlatform = HostPlatform(), io::IO = stderr_f(),
    )
    meta = artifact_meta(name, artifacts_toml; platform)
    meta === nothing && pkgerror("Artifact $(repr(name)) has no entry matching platform $(triplet(platform)) in $(repr(artifacts_toml))")
    return ensure_artifact_installed(name, meta, artifacts_toml; platform, io)
end
function ensure_artifact_installed(
        name::String, meta::Dict, artifacts_toml::String;
        platform::AbstractPlatform = HostPlatform(), io::IO = stderr_f(),
    )
    depots = depot_stack()
    log_usage(depots, artifacts_toml, "artifact_usage.toml")
    hash = SHA1(meta["git-tree-sha1"]::String)
    # artifact_exists honors Overrides.toml — overridden artifacts are
    # never downloaded
    artifact_exists(hash) && return artifact_path(hash)
    path, _ = ArtifactOps.ensure_artifact_installed!(depots, name, meta; io)
    return path
end

"Delete the artifact tree for `hash` (no-op when absent)."
function remove_artifact(hash::SHA1)
    # Never delete an override target: it is user-owned, not an artifact-store
    # installation.  `artifacts_dirs` also observes with_artifacts_directory().
    query_override(hash) === nothing || return nothing
    for path in artifacts_dirs(string(hash))
        isdir(path) && Base.rm(path; recursive = true, force = true)
    end
    return nothing
end

"Whether the artifact tree for `hash` exists and matches its hash."
function verify_artifact(hash::SHA1)
    path, installed = ArtifactOps.artifact_tree_path(depot_stack(), hash)
    installed || return false
    return tree_hash_matches(path, hash)
end

tree_hash_matches(path::AbstractString, expected::SHA1) =
    TreeHash.tree_hash_matches(path, expected)

"""
    create_artifact(f::Function; legacy_symlink_size = false) -> SHA1

Create a new artifact by running `f(dir)` in a fresh directory, hashing
the result, and moving it into the artifact store of the first depot.
Returns the content tree hash identifying the artifact.

By default symlink target sizes are hashed by byte count, matching git.
Set `legacy_symlink_size = true` only when compatibility with hashes made by
older Pkg versions is required.
"""
function create_artifact(f::Function; legacy_symlink_size::Bool = false)
    # Artifacts.artifacts_dirs() incorporates with_artifacts_directory(); using
    # it here makes the compatibility surface and our mutating implementation
    # agree on both the creation and lookup location.
    store = mkpath(first(artifacts_dirs()))
    create_cachedir_tag(store)
    temp_dir = mktempdir(store)
    return try
        f(temp_dir)
        hash = SHA1(TreeHash.tree_hash(temp_dir; legacy_symlink_size))
        # duplicate content: the existing tree already is this artifact
        new_path = joinpath(store, string(hash))
        isdir(new_path) || mv_temp_dir_retries(temp_dir, new_path)
        hash
    finally
        Base.rm(temp_dir; recursive = true, force = true)
    end
end

"""
    archive_artifact(hash, tarball_path; honor_overrides = false) -> String

Archive an installed artifact and return the tarball's SHA-256 as lowercase
hex.  Override targets are rejected by default because they are user-owned.
"""
function archive_artifact(
        hash::SHA1, tarball_path::String;
        honor_overrides::Bool = false,
    )
    override = query_override(hash)
    override === nothing || honor_overrides ||
        error("Will not archive an overridden artifact unless `honor_overrides` is set!")
    artifact_exists(hash; honor_overrides) ||
        error("Unable to archive artifact $(string(hash)): does not exist!")
    Fetch.package(artifact_path(hash; honor_overrides), tarball_path)
    return bytes2hex(open(sha256, tarball_path))
end

# whether a `[[<name>]]` entry binds a platform semantically equivalent to
# `platform` (per `platforms_match`); entries with an unrecognized shape or
# no recoverable platform never match and are kept as-is
function entry_platform_matches(x, name::String, artifacts_toml::String, platform::AbstractPlatform)
    x isa Dict{String, Any} || return false
    p = unpack_platform(x, name, artifacts_toml)
    return p !== nothing && platforms_match(platform, p)
end

# bind/unbind are parse-modify-write transactions on a shared file: serialize
# them with a pidlock and replace the file atomically
transact_artifacts_toml(f::Function, artifacts_toml::String) =
    mkpidlock(f, artifacts_toml * ".pid", stale_age = 20)

# a `[[<name>.download]]` entry from `(url, sha256[, size])` tuples
function download_entry_dict(info::Tuple)
    url = String(info[1])
    sha = info[2] isa AbstractVector{UInt8} ? bytes2hex(info[2]) : String(info[2])
    (length(sha) == 64 && all(isxdigit, sha)) || pkgerror(
        "Invalid SHA-256 digest $(repr(sha)); expected exactly 64 hexadecimal characters"
    )
    entry = Dict{String, Any}("url" => url, "sha256" => lowercase(sha))
    length(info) >= 3 && Int64(info[3]) > 0 && (entry["size"] = Int64(info[3]))
    return entry
end

"""
    bind_artifact!(
        artifacts_toml, name, hash::SHA1;
        platform = nothing, download_info = nothing,
        lazy = false, force = false
    )

Write a `name => hash` mapping into `artifacts_toml`. A `platform` makes
the binding platform-specific (multiple platforms may bind the same
name); `download_info` is a vector of `(url, sha256[, size])` tuples;
`lazy` defers the download to first use. Rebinding an existing mapping
requires `force = true`.
"""
function bind_artifact!(
        artifacts_toml::String, name::String, hash::SHA1;
        platform::Union{AbstractPlatform, Nothing} = nothing,
        download_info::Union{Vector{<:Tuple}, Nothing} = nothing,
        lazy::Bool = false, force::Bool = false,
    )
    transact_artifacts_toml(artifacts_toml) do
        artifact_dict = isfile(artifacts_toml) ? TOML.parsefile(artifacts_toml) : Dict{String, Any}()
        if !force && haskey(artifact_dict, name)
            existing = artifact_dict[name]
            if !isa(existing, Vector) || platform === nothing
                pkgerror("Artifact $(repr(name)) already has a mapping in $(repr(artifacts_toml)); pass force=true to replace it")
            else
                plat = platform
                any(x -> entry_platform_matches(x, name, artifacts_toml, plat), existing) &&
                    pkgerror("Artifact $(repr(name)) already has a mapping for platform $(triplet(plat)) in $(repr(artifacts_toml)); pass force=true to replace it")
            end
        end
        meta = Dict{String, Any}("git-tree-sha1" => string(hash))
        lazy && (meta["lazy"] = true)
        download_info === nothing || (meta["download"] = download_entry_dict.(download_info))
        if platform === nothing
            artifact_dict[name] = meta
        else
            pack_platform!(meta, platform)
            entries = get(artifact_dict, name, nothing)
            entries = entries isa Vector ? entries : Any[]
            # one entry per platform: a semantically equivalent platform is
            # replaced (entries with an unrecognized shape are kept as-is)
            filter!(x -> !entry_platform_matches(x, name, artifacts_toml, platform), entries)
            push!(entries, meta)
            artifact_dict[name] = entries
        end
        atomic_toml_write(artifacts_toml, artifact_dict; sorted = true)
    end
    log_usage(depot_stack(), artifacts_toml, "artifact_usage.toml")
    return nothing
end

"""
    unbind_artifact!(artifacts_toml, name; platform = nothing)

Remove the binding for `name` (or only its `platform`-specific entry)
from `artifacts_toml`. Silently does nothing when no binding exists.
"""
function unbind_artifact!(
        artifacts_toml::String, name::String;
        platform::Union{AbstractPlatform, Nothing} = nothing,
    )
    isfile(artifacts_toml) || return nothing
    transact_artifacts_toml(artifacts_toml) do
        artifact_dict = TOML.parsefile(artifacts_toml)
        haskey(artifact_dict, name) || return nothing
        if platform === nothing
            delete!(artifact_dict, name)
        else
            entries = artifact_dict[name]
            # a platform-agnostic binding (single table) has no per-platform
            # entry to remove
            entries isa Vector || return nothing
            artifact_dict[name] = filter(
                x -> !entry_platform_matches(x, name, artifacts_toml, platform),
                entries,
            )
        end
        atomic_toml_write(artifacts_toml, artifact_dict; sorted = true)
    end
    return nothing
end
end
