# Pkg.Artifacts-compatible namespace: the query + install surface packages
# need at runtime. Queries re-export the Artifacts stdlib (environment-
# agnostic, override-aware); installs go through ArtifactOps against the
# session depots. Lazy artifacts are skipped at instantiate/add time (like
# Pkg) and installed on demand through `ensure_artifact_installed` — the
# entry point LazyArtifacts-style lazy loading bottoms out in.
module Artifacts
using Artifacts: artifact_meta, artifact_hash, artifact_exists, artifact_path,
    find_artifacts_toml, select_downloadable_artifacts,
    pack_platform!, unpack_platform
using Base: SHA1
using Base.BinaryPlatforms: AbstractPlatform, HostPlatform, platforms_match, triplet
import TOML

using ..Errors: pkgerror
using ..Utils: stderr_f, create_cachedir_tag, mv_temp_dir_retries
using ..Depots: depot_stack, depots1, artifacts_dir, log_usage
import ..ArtifactOps
import ..TreeHash

export artifact_meta, artifact_hash, artifact_exists, artifact_path,
    find_artifacts_toml, select_downloadable_artifacts,
    ensure_artifact_installed, remove_artifact, verify_artifact,
    create_artifact, bind_artifact!, unbind_artifact!

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
    meta === nothing && pkgerror("Cannot locate artifact `$name` in `$artifacts_toml`")
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
    path, installed = ArtifactOps.artifact_tree_path(depot_stack(), hash)
    installed && Base.rm(path; recursive = true, force = true)
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
    store = mkpath(artifacts_dir(depots1(depot_stack())))
    create_cachedir_tag(store)
    temp_dir = mktempdir(store)
    return try
        f(temp_dir)
        hash = SHA1(TreeHash.tree_hash(temp_dir; legacy_symlink_size))
        # duplicate content: the existing tree already is this artifact
        new_path = joinpath(store, string(hash))
        isdir(new_path) || mv_temp_dir_retries(temp_dir, new_path; set_permissions = false)
        hash
    finally
        Base.rm(temp_dir; recursive = true, force = true)
    end
end

# a `[[<name>.download]]` entry from `(url, sha256[, size])` tuples
function download_entry_dict(info::Tuple)
    url = String(info[1])
    sha = info[2] isa AbstractVector{UInt8} ? bytes2hex(info[2]) : String(info[2])
    length(sha) == 64 || pkgerror("invalid sha256 hash `$sha` in download info")
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
    artifact_dict = isfile(artifacts_toml) ? TOML.parsefile(artifacts_toml) : Dict{String, Any}()
    if !force && haskey(artifact_dict, name)
        existing = artifact_dict[name]
        if !isa(existing, Vector) || platform === nothing
            pkgerror("Mapping for '$name' within $(artifacts_toml) already exists!")
        else
            plat = platform
            matches(x) = x isa Dict{String, Any} &&
                (p = unpack_platform(x, name, artifacts_toml); p !== nothing && platforms_match(plat, p))
            any(matches, existing) &&
                pkgerror("Mapping for '$name'/$(triplet(plat)) within $(artifacts_toml) already exists!")
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
        # one entry per platform: an identical platform is replaced
        # (entries with an unrecognized shape are kept as-is)
        filter!(x -> !(x isa Dict{String, Any}) || unpack_platform(x, name, artifacts_toml) != platform, entries)
        push!(entries, meta)
        artifact_dict[name] = entries
    end
    open(artifacts_toml, "w") do io
        TOML.print(io, artifact_dict; sorted = true)
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
            x -> !(x isa Dict{String, Any}) || unpack_platform(x, name, artifacts_toml) != platform,
            entries,
        )
    end
    open(artifacts_toml, "w") do io
        TOML.print(io, artifact_dict; sorted = true)
    end
    return nothing
end
end
