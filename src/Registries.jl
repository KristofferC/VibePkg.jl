# Registries: on-disk formats, lazy in-memory instances, and pure query
# functions over the Compress format.
#
# Ported from Pkg's Registry/registry_instance.jl with two structural
# changes: lazy state is `Union{Nothing, ...}` fields instead of #undef
# fields behind inner constructors, and access goes through functions
# instead of a getproperty overload.
#
# The content of a registry is assumed constant for the lifetime of a
# `RegistryInstance`; instances are cached process-wide keyed by content
# hash (a sanctioned cache: registry parsing is the dominant cost of many
# operations).
#
# Everything here is read-side. Registry add/update/rm need the network and
# live in a later layer.

module Registries

using Base: UUID, SHA1
using TOML: TOML
using Dates: Dates
using Tar: Tar
using FileWatching: mkpidlock

using ..Errors: pkgerror
using ..Utils: stderr_f, create_cachedir_tag
using ..Timing: @timeit, TIMER
using ..Versions: VersionSpec, VersionRange
using ..Depots: DepotStack, depots, depots1, registries_dir, scratchspaces_dir, atomic_toml_write
using ..Fetch: uncompress_registry, get_extract_cmd, read_tarball_simple
import ..Fetch
import ..Git
import LibGit2

export RegistryInstance, PkgEntry, PkgInfo, VersionInfo,
    reachable_registries, registry_info, uuids_from_name,
    isyanked, treehash, isdeprecated, registry_name, registry_uuid,
    registry_repo, registry_pkgs,
    query_compat_for_version, query_compat_for_version!, is_version_yanked,
    deprecation_info,
    query_compat_for_version_multi_registry!, query_deps_for_version,
    is_weak_dep, JULIA_UUID

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")

"whether `uuid@v` is yanked in any of the given registries"
function is_version_yanked end   # defined after RegistryInstance below

function to_tar_path_format(file::AbstractString)
    @static if Sys.iswindows()
        file = replace(file, "\\" => "/")
    end
    return file
end

# Shared mtime-keyed TOML cache (same mechanism as Base loading uses).
const TOML_CACHE = Base.TOMLCache(Base.TOML.Parser{Dates}())
const TOML_LOCK = ReentrantLock()
_parsefile(toml_file::AbstractString) = Base.parsed_toml(toml_file, TOML_CACHE, TOML_LOCK)

tryparse_sha1(s::AbstractString) = try
    SHA1(s)
catch err
    err isa InterruptException && rethrow()
    nothing
end

function parsefile(in_memory_registry::Union{Dict, Nothing}, folder::AbstractString, file::AbstractString)
    if in_memory_registry === nothing
        return _parsefile(joinpath(folder, file))
    else
        content = get(in_memory_registry, to_tar_path_format(file), nothing)
        content === nothing && pkgerror(
            "registry is missing `$file`; try removing and re-adding the registry"
        )
        parser = Base.TOML.Parser{Dates}(content; filepath = file)
        return Base.TOML.parse(parser)
    end
end

custom_isfile(in_memory_registry::Union{Dict, Nothing}, folder::AbstractString, file::AbstractString) =
    in_memory_registry === nothing ? isfile(joinpath(folder, file)) : haskey(in_memory_registry, to_tar_path_format(file))

#####################
# Package-level data #
#####################

struct VersionInfo
    git_tree_sha1::SHA1
    yanked::Bool
end

# The information in a registry's per-package directory (e.g. General/A/ACME).
# Deps/Compat stay range-compressed in memory; the resolver consumes them
# compressed (uncompressing the whole registry would be prohibitively slow).
struct PkgInfo
    # Package.toml:
    repo::Union{String, Nothing}
    subdir::Union{String, Nothing}
    # Package.toml [metadata.deprecated]:
    deprecated::Union{Dict{String, Any}, Nothing}
    # Versions.toml:
    version_info::Dict{VersionNumber, VersionInfo}
    # Deps.toml — which dependencies exist, keyed by dash version-ranges
    deps::Dict{VersionRange, Set{UUID}}
    # Compat.toml — version constraints on deps
    compat::Dict{VersionRange, Dict{UUID, VersionSpec}}
    # WeakDeps.toml / WeakCompat.toml:
    weak_deps::Dict{VersionRange, Set{UUID}}
    weak_compat::Dict{VersionRange, Dict{UUID, VersionSpec}}
end

isyanked(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].yanked
treehash(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].git_tree_sha1
isdeprecated(pkg::PkgInfo) = pkg.deprecated !== nothing

mutable struct PkgEntry
    const path::String
    const registry_path::String
    const name::String
    const uuid::UUID
    # Lazily parsed on first `registry_info` call (guarded by the registry's
    # load lock); `nothing` until then.
    info::Union{Nothing, PkgInfo}
end

##################
# Compress query #
##################

# All deps (strong + weak) of `version` from compressed data.
function query_deps_for_version(
        deps_compressed::Dict{VersionRange, Set{UUID}},
        weak_deps_compressed::Dict{VersionRange, Set{UUID}},
        version::VersionNumber,
    )::Set{UUID}
    result = Set{UUID}()
    for compressed in (deps_compressed, weak_deps_compressed)
        for (vrange, deps_set) in compressed
            if version in vrange
                union!(result, deps_set)
            end
        end
    end
    return result
end

# Multi-registry variant: each registry contributes only if it knows the uuid.
function query_deps_for_version(
        deps_map::Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}},
        weak_deps_map::Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}},
        uuid::UUID,
        version::VersionNumber,
    )::Set{UUID}
    result = Set{UUID}()
    deps_list = get(Vector{Dict{VersionRange, Set{UUID}}}, deps_map, uuid)
    weak_deps_list = get(Vector{Dict{VersionRange, Set{UUID}}}, weak_deps_map, uuid)
    for i in eachindex(deps_list)
        union!(result, query_deps_for_version(deps_list[i], weak_deps_list[i], version))
    end
    return result
end

# Deps of `version` merged with their compat constraints: declared deps
# default to VersionSpec() (any version), Compat/WeakCompat overlay explicit
# constraints. `target_uuid` restricts the query to one dependency.
function query_compat_for_version!(
        result::Dict{UUID, VersionSpec},
        deps_compressed::Dict{VersionRange, Set{UUID}},
        compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        weak_deps_compressed::Dict{VersionRange, Set{UUID}},
        weak_compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        version::VersionNumber,
        target_uuid::Union{UUID, Nothing} = nothing,
    )
    empty!(result)
    for deps_dict in (deps_compressed, weak_deps_compressed)
        for (vrange, deps_set) in deps_dict
            if version in vrange
                for dep_uuid in deps_set
                    if target_uuid === nothing || dep_uuid == target_uuid
                        result[dep_uuid] = VersionSpec()
                    end
                end
            end
        end
    end
    for compat_dict in (compat_compressed, weak_compat_compressed)
        for (vrange, compat_entries) in compat_dict
            if version in vrange
                for (dep_uuid, vspec) in compat_entries
                    if target_uuid === nothing || dep_uuid == target_uuid
                        result[dep_uuid] = vspec
                    end
                end
            end
        end
    end
    return nothing
end

function query_compat_for_version(
        deps_compressed::Dict{VersionRange, Set{UUID}},
        compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        weak_deps_compressed::Dict{VersionRange, Set{UUID}},
        weak_compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        version::VersionNumber,
        target_uuid::Union{UUID, Nothing} = nothing,
    )
    result = Dict{UUID, VersionSpec}()
    query_compat_for_version!(result, deps_compressed, compat_compressed, weak_deps_compressed, weak_compat_compressed, version, target_uuid)
    if target_uuid !== nothing
        return get(result, target_uuid, nothing)
    end
    return result
end

query_compat_for_version(pkg_info::PkgInfo, version::VersionNumber, target_uuid::Union{UUID, Nothing} = nothing) =
    query_compat_for_version(pkg_info.deps, pkg_info.compat, pkg_info.weak_deps, pkg_info.weak_compat, version, target_uuid)

function is_weak_dep(
        weak_compressed::Dict{VersionRange, Set{UUID}},
        version::VersionNumber,
        dep_uuid::UUID,
    )::Bool
    for (vrange, weak_set) in weak_compressed
        if version in vrange && (dep_uuid in weak_set)
            return true
        end
    end
    return false
end

# Query compat across multiple registries; a registry is consulted only if
# the version exists in it, first registry wins per dependency.
function query_compat_for_version_multi_registry!(
        result::Dict{UUID, VersionSpec},
        reg_result::Dict{UUID, VersionSpec},
        deps_list::Vector{Dict{VersionRange, Set{UUID}}},
        compat_list::Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}},
        weak_deps_list::Vector{Dict{VersionRange, Set{UUID}}},
        weak_compat_list::Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}},
        versions_per_registry::Vector{Set{VersionNumber}},
        version::VersionNumber,
    )
    empty!(result)
    for i in eachindex(deps_list)
        # only query this registry if the version exists in it
        if !(version in versions_per_registry[i])
            continue
        end
        query_compat_for_version!(reg_result, deps_list[i], compat_list[i], weak_deps_list[i], weak_compat_list[i], version)
        for (uuid, vspec) in reg_result
            if !haskey(result, uuid)
                result[uuid] = vspec
            end
        end
    end
    return nothing
end

####################
# RegistryInstance #
####################

# The eagerly-parsed header of a registry (Registry.toml) plus its package
# index. `in_memory_registry` and `name_to_uuids` are caches whose contents
# mutate (per-package file eviction / lazy name map); everything else is
# frozen after load.
struct LoadedRegistry
    name::String
    uuid::UUID
    repo::Union{String, Nothing}
    description::Union{String, Nothing}
    pkgs::Dict{UUID, PkgEntry}
    in_memory_registry::Union{Nothing, Dict{String, String}}
    name_to_uuids::Dict{String, Vector{UUID}}
end

mutable struct RegistryInstance
    const path::String
    const tree_info::Union{SHA1, Nothing}
    const compressed_file::Union{String, Nothing}
    const load_lock::ReentrantLock
    # `nothing` until the registry index is parsed (lazily, under load_lock)
    loaded::Union{Nothing, LoadedRegistry}
end

@timeit TIMER "parse registry" function _load_registry(r::RegistryInstance)::LoadedRegistry
    in_memory_registry = if r.compressed_file !== nothing
        uncompress_registry(joinpath(dirname(r.path), r.compressed_file))
    else
        nothing
    end
    d = parsefile(in_memory_registry, r.path, "Registry.toml")
    pkgs = Dict{UUID, PkgEntry}()
    for (uuid, info) in d["packages"]::Dict{String, Any}
        uuid = UUID(uuid::String)
        info::Dict{String, Any}
        pkgs[uuid] = PkgEntry(info["path"]::String, r.path, info["name"]::String, uuid, nothing)
    end
    return LoadedRegistry(
        d["name"]::String,
        UUID(d["uuid"]::String),
        get(d, "repo", nothing)::Union{String, Nothing},
        get(d, "description", nothing)::Union{String, Nothing},
        pkgs,
        in_memory_registry,
        Dict{String, Vector{UUID}}(),
    )
end

function loaded(r::RegistryInstance)::LoadedRegistry
    l = r.loaded
    l !== nothing && return l
    return @lock r.load_lock begin
        # double-check under the lock
        l = r.loaded
        l !== nothing ? l : (r.loaded = _load_registry(r))
    end
end

registry_name(r::RegistryInstance) = loaded(r).name
registry_uuid(r::RegistryInstance) = loaded(r).uuid
registry_repo(r::RegistryInstance) = loaded(r).repo
registry_description(r::RegistryInstance) = loaded(r).description
registry_pkgs(r::RegistryInstance) = loaded(r).pkgs

# Dict-like read interface
Base.haskey(r::RegistryInstance, uuid::UUID) = haskey(registry_pkgs(r), uuid)
Base.keys(r::RegistryInstance) = keys(registry_pkgs(r))
Base.getindex(r::RegistryInstance, uuid::UUID) = registry_pkgs(r)[uuid]
Base.get(r::RegistryInstance, uuid::UUID, default) = get(registry_pkgs(r), uuid, default)
Base.iterate(r::RegistryInstance, args...) = iterate(registry_pkgs(r), args...)

"Parse (once) and return the per-package registry data for `pkg`."
function registry_info(r::RegistryInstance, pkg::PkgEntry)
    info = pkg.info
    info !== nothing && return info
    return @lock r.load_lock begin
        info = pkg.info
        info !== nothing && return info

        reg = loaded(r)
        in_memory_registry = reg.in_memory_registry

        d_p = parsefile(in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Package.toml"))
        name = d_p["name"]::String
        name != pkg.name && error("inconsistent name in Registry.toml ($(name)) and Package.toml ($(pkg.name)) for pkg at $(pkg.path)")
        repo = get(d_p, "repo", nothing)::Union{Nothing, String}
        subdir = get(d_p, "subdir", nothing)::Union{Nothing, String}
        metadata = get(d_p, "metadata", nothing)::Union{Nothing, Dict{String, Any}}
        deprecated = metadata !== nothing ? get(metadata, "deprecated", nothing)::Union{Nothing, Dict{String, Any}} : nothing

        d_v = custom_isfile(in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) ?
            parsefile(in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) : Dict{String, Any}()
        version_info = Dict{VersionNumber, VersionInfo}()
        for (k, v) in d_v
            v isa Dict{String, Any} && haskey(v, "git-tree-sha1") || pkgerror(
                "malformed entry for version `$k` in Versions.toml for package `$(pkg.name)` at `$(pkg.path)`"
            )
            version_info[VersionNumber(k)] =
                VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool)
        end

        # Deps.toml first: it builds the name → UUID mapping Compat needs
        name_to_uuid = Dict{String, UUID}()
        deps = load_deps_data(in_memory_registry, pkg.registry_path, pkg.path, "Deps.toml", name_to_uuid)
        # all packages implicitly depend on julia
        deps[VersionRange()] = Set([JULIA_UUID])
        name_to_uuid["julia"] = JULIA_UUID

        weak_deps = load_deps_data(in_memory_registry, pkg.registry_path, pkg.path, "WeakDeps.toml", name_to_uuid)
        compat = load_compat_data(in_memory_registry, pkg.registry_path, pkg.path, "Compat.toml", name_to_uuid)
        weak_compat = load_compat_data(in_memory_registry, pkg.registry_path, pkg.path, "WeakCompat.toml", name_to_uuid)

        pkg.info = PkgInfo(repo, subdir, deprecated, version_info, deps, compat, weak_deps, weak_compat)

        # free memory: evict this package's files from the in-memory tarball
        if in_memory_registry !== nothing
            for filename in ("Package.toml", "Versions.toml", "Deps.toml", "WeakDeps.toml", "Compat.toml", "WeakCompat.toml")
                delete!(in_memory_registry, to_tar_path_format(joinpath(pkg.path, filename)))
            end
        end

        return pkg.info::PkgInfo
    end
end

function load_deps_data(in_memory_registry, registry_path, pkg_path, filename, name_to_uuid)
    deps_data_toml = custom_isfile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) ?
        parsefile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) : Dict{String, Any}()
    deps = Dict{VersionRange, Set{UUID}}()
    for (v, data) in deps_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Set{UUID}()
        for (dep, uuid_str) in data
            uuid_val = UUID(uuid_str::String)
            push!(d, uuid_val)
            name_to_uuid[dep] = uuid_val
        end
        deps[vr] = d
    end
    return deps
end

function load_compat_data(in_memory_registry, registry_path, pkg_path, filename, name_to_uuid)
    compat_data_toml = custom_isfile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) ?
        parsefile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) : Dict{String, Any}()
    compat = Dict{VersionRange, Dict{UUID, VersionSpec}}()
    for (v, data) in compat_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{UUID, VersionSpec}()
        for (dep, vr_dep::Union{String, Vector{String}}) in data
            uuid = get(name_to_uuid, dep, nothing)
            uuid === nothing && pkgerror(
                "`$filename` for package at `$pkg_path` refers to `$dep` which has no entry in the corresponding deps file"
            )
            d[uuid] = VersionSpec(vr_dep)
        end
        compat[vr] = d
    end
    return compat
end

function is_version_yanked(registries::Vector{RegistryInstance}, uuid::UUID, v::VersionNumber)
    for reg in registries
        pkg = get(reg, uuid, nothing)
        pkg === nothing && continue
        info = registry_info(reg, pkg)
        vinfo = get(info.version_info, v, nothing)
        vinfo !== nothing && vinfo.yanked && return true
    end
    return false
end

"the `[metadata.deprecated]` table for `uuid` from the first registry declaring one, or `nothing`"
function deprecation_info(registries::Vector{RegistryInstance}, uuid::UUID)
    for reg in registries
        pkg = get(reg, uuid, nothing)
        pkg === nothing && continue
        info = registry_info(reg, pkg)
        isdeprecated(info) && return info.deprecated
    end
    return nothing
end

function uuids_from_name(r::RegistryInstance, name::String)
    reg = loaded(r)
    if isempty(reg.name_to_uuids)
        for (uuid, pkg) in reg.pkgs
            uuids = get!(Vector{UUID}, reg.name_to_uuids, pkg.name)
            push!(uuids, pkg.uuid)
        end
    end
    return get(Vector{UUID}, reg.name_to_uuids, name)
end

function Base.show(io::IO, ::MIME"text/plain", r::RegistryInstance)
    println(io, "Registry: $(repr(registry_name(r))) at $(repr(r.path)):")
    println(io, "  uuid: ", registry_uuid(r))
    println(io, "  repo: ", registry_repo(r))
    if r.tree_info !== nothing
        println(io, "  git-tree-sha1: ", r.tree_info)
    end
    return println(io, "  packages: ", length(registry_pkgs(r)))
end
Base.show(io::IO, r::RegistryInstance) = Base.show(io, MIME"text/plain"(), r)

#############
# Discovery #
#############

# Process-wide instance cache keyed by path, validated by content identity
# (tree hash + packed/unpacked form). Content-addressed registry forms are
# immutable on disk, so reuse across operations is safe.
const REGISTRY_CACHE = Dict{String, Tuple{SHA1, Bool, RegistryInstance}}()
const REGISTRY_CACHE_LOCK = ReentrantLock()

function get_cached_registry(path, tree_info::SHA1, compressed::Bool)
    if !ispath(path)
        delete!(REGISTRY_CACHE, path)
        return nothing
    end
    v = get(REGISTRY_CACHE, path, nothing)
    if v !== nothing
        cached_tree_info, cached_compressed, reg = v
        if cached_tree_info == tree_info && cached_compressed == compressed
            return reg
        end
    end
    # prevent hogging memory indefinitely
    length(REGISTRY_CACHE) > 20 && empty!(REGISTRY_CACHE)
    return nothing
end

function RegistryInstance(path::AbstractString)
    return @lock REGISTRY_CACHE_LOCK begin
        compressed_file = nothing
        tree_info = nothing
        if isfile(path)
            @assert splitext(path)[2] == ".toml"
            d_reg_info = parsefile(nothing, dirname(path), basename(path))
            compressed_file = d_reg_info["path"]::String
            tree_info = SHA1(d_reg_info["git-tree-sha1"]::String)
        else
            tree_info_file = joinpath(path, ".tree_info.toml")
            if isfile(tree_info_file)
                # a corrupt .tree_info.toml only disables caching; the
                # registry itself may still load fine
                tree_info = try
                    h = parsefile(nothing, path, ".tree_info.toml")["git-tree-sha1"]
                    h isa String ? SHA1(h) : nothing
                catch err
                    err isa InterruptException && rethrow()
                    nothing
                end
                tree_info === nothing &&
                    @warn "ignoring corrupt `.tree_info.toml`" file = tree_info_file maxlog = 1
            end
        end
        if tree_info !== nothing
            reg = get_cached_registry(path, tree_info, compressed_file !== nothing)
            reg isa RegistryInstance && return reg
        end
        reg = RegistryInstance(String(path), tree_info, compressed_file, ReentrantLock(), nothing)
        if tree_info !== nothing
            REGISTRY_CACHE[path] = (tree_info, compressed_file !== nothing, reg)
        end
        reg
    end
end

function verify_compressed_registry_toml(path::String)
    d = TOML.tryparsefile(path)
    if d isa TOML.ParserError
        @warn "Failed to parse registry TOML file at $(repr(path))" exception = d
        return false
    end
    for key in ("git-tree-sha1", "uuid", "path")
        val = get(d, key, nothing)
        if val === nothing
            @warn "Expected key $(repr(key)) to exist in registry TOML file at $(repr(path))"
            return false
        elseif !(val isa String)
            @warn "Expected key $(repr(key)) in registry TOML file at $(repr(path)) to be a string"
            return false
        end
    end
    compressed_file = joinpath(dirname(path), d["path"]::String)
    if !isfile(compressed_file)
        @warn "Expected the compressed registry for $(repr(path)) to exist at $(repr(compressed_file))"
        return false
    end
    return true
end

"""
    reachable_registries(depots; read_from_tarball::Bool) -> Vector{RegistryInstance}

Discover registries across the depot stack, in depot order (order matters:
the first registry wins conflicting metadata). `read_from_tarball` controls
whether packed `Name.toml` + tarball registries are visible (the Config
layer derives it from `JULIA_PKG_SERVER`/`JULIA_PKG_UNPACK_REGISTRY`); a
packed registry shadows an unpacked directory of the same name.
"""
@timeit TIMER "reachable registries" function reachable_registries(d::DepotStack; read_from_tarball::Bool = true)
    registries = RegistryInstance[]
    for depot in depots(d)
        isdir(depot) || continue
        reg_dir = registries_dir(depot)
        isdir(reg_dir) || continue
        reg_paths = readdir(reg_dir; join = true)
        candidate_registries = String[]
        append!(candidate_registries, filter(isdir, reg_paths))
        if read_from_tarball
            compressed_registries = filter(endswith(".toml"), reg_paths)
            # a packed registry shadows an unpacked dir of the same name
            compressed_registry_names = Set([splitext(basename(file))[1] for file in compressed_registries])
            filter!(x -> !(basename(x) in compressed_registry_names), candidate_registries)
            for compressed_registry in compressed_registries
                if verify_compressed_registry_toml(compressed_registry)
                    push!(candidate_registries, compressed_registry)
                end
            end
        end
        for candidate in candidate_registries
            # candidate is either a folder or a packed-stub TOML file
            if isfile(joinpath(candidate, "Registry.toml")) || isfile(candidate)
                push!(registries, RegistryInstance(candidate))
            end
        end
    end
    return registries
end

########################
# Registry maintenance #
########################
# Registry add/update/remove: package-server
# packed tarballs (unpacked directories under JULIA_PKG_UNPACK_REGISTRY),
# git clones (fetch + ff-merge on update), and plain directory copies.

# Callbacks run after any registry mutation (add / remove / update).
# Higher layers (e.g. REPLMode's completion-name caches) register
# invalidation hooks here; Registries cannot call them directly without
# inverting the module layer order.
const REGISTRY_CHANGE_HOOKS = Function[]

function notify_registry_change!()
    for hook in REGISTRY_CHANGE_HOOKS
        hook()
    end
    return
end

function validate_registry_name(name::String)
    if isempty(name) || name in (".", "..") || occursin(r"[\\/:*?\"<>|]", name)
        pkgerror(
            "invalid registry name $(repr(name)): registry names must be portable " *
                "single path components"
        )
    end
    return name
end

# Nudge to reinstall a git/unpacked General registry in the faster packed
# form; `JULIA_PKG_GEN_REG_FMT_CHECK=false` silences it.
function warn_general_registry_format(form::String)
    # get_bool_env returns nothing for an unparseable value; treat as default
    something(Base.get_bool_env("JULIA_PKG_GEN_REG_FMT_CHECK", true), true) || return
    @info """
    The General registry is installed via $form. Consider reinstalling it via
    the newer faster direct from tarball format by running:
      vpkg> registry rm General; registry add General

    """ maxlog = 1
    return
end

"Registries the package server advertises: uuid => current tree hash."
function server_registry_hashes(server::String; depots::Union{Nothing, DepotStack} = nothing)
    tmp = tempname()
    try
        Fetch.download("$server/registries", tmp; depots)
        hashes = Dict{UUID, SHA1}()
        for line in eachline(tmp)
            m = match(r"^/registry/([^/]+)/([^/]+)$", strip(line))
            m === nothing && continue
            hashes[UUID(m.captures[1])] = SHA1(m.captures[2])
        end
        return hashes
    finally
        Base.rm(tmp; force = true)
    end
end

# Read a single file's content out of a compressed tarball without
# unpacking everything to disk. read_tarball_simple drains entries its
# predicate rejects, but the callback must consume the data of every
# entry it accepts — the accept-all predicate here means non-matches
# are drained to devnull.
function read_file_from_tarball(tarball::String, wanted::String)
    content = Ref{Union{Nothing, String}}(nothing)      # Ref: mutated in the callback, not reassigned
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    io = IOBuffer()
    open(get_extract_cmd(tarball)) do tar
        read_tarball_simple(x -> true, tar; buf) do hdr
            if hdr.path == wanted && content[] === nothing
                Tar.read_data(tar, io; size = hdr.size, buf)
                content[] = String(take!(io))
            else
                Tar.read_data(tar, devnull; size = hdr.size, buf)
            end
        end
    end
    return content[]
end

# Download registry `uuid` at `hash` from the server, verify the tree hash
# of the decompressed tarball, and install it packed (Name.toml stub +
# Name.tar.gz) into `depot`.
@timeit TIMER "install registry" function install_server_registry!(depot::String, server::String, uuid::UUID, hash::SHA1; io::IO = stderr_f())
    tmp = tempname()
    try
        Fetch.download("$server/registry/$uuid/$hash", tmp; depots = DepotStack([depot]))
        computed = open(tar -> Tar.tree_hash(tar), get_extract_cmd(tmp))
        SHA1(computed) == hash ||
            pkgerror("downloaded registry $uuid does not match the expected tree hash $hash")
        reg_toml = read_file_from_tarball(tmp, "Registry.toml")
        reg_toml === nothing && pkgerror("registry tarball for $uuid is missing Registry.toml")
        reg_data = TOML.tryparse(reg_toml)
        reg_data isa TOML.ParserError &&
            pkgerror("registry tarball for $uuid has a malformed Registry.toml")
        # the embedded uuid must be the one the server was asked for: a
        # mismatched tarball must not be installed under the requested uuid
        embedded = get(reg_data, "uuid", nothing)
        embedded_uuid = embedded isa String ? tryparse(UUID, embedded) : nothing
        embedded_uuid == uuid || pkgerror(
            "Registry.toml in the registry downloaded for $uuid declares uuid " *
                "`$(embedded_uuid === nothing ? "<missing or invalid>" : embedded_uuid)`"
        )
        reg_name = get(reg_data, "name", nothing)
        reg_name isa String ||
            pkgerror("registry tarball for $uuid has no `name` in Registry.toml")
        name = validate_registry_name(reg_name)

        reg_dir = mkpath(registries_dir(depot))
        create_cachedir_tag(reg_dir)
        # same-name directory registry with a different uuid is a conflict
        existing_dir = joinpath(reg_dir, name)
        if isdir(existing_dir) && isfile(joinpath(existing_dir, "Registry.toml"))
            existing_uuid = directory_registry_uuid(existing_dir)
            existing_uuid === nothing && pkgerror(
                "cannot determine the uuid of the existing registry at `$existing_dir` (corrupt Registry.toml); remove it to reinstall"
            )
            existing_uuid == uuid || pkgerror(
                "registry `$name=\"$uuid\"` conflicts with existing registry `$name=\"$existing_uuid\"`"
            )
        end
        if unpack_registries()
            # JULIA_PKG_UNPACK_REGISTRY=true: extract the tarball into a plain
            # directory registry (with a `.tree_info.toml` recording the hash)
            tmp_dir = tempname(reg_dir)
            try
                open(get_extract_cmd(tmp)) do tar
                    Tar.extract(tar, tmp_dir)
                end
                open(joinpath(tmp_dir, ".tree_info.toml"), "w") do f
                    TOML.print(f, Dict{String, Any}("git-tree-sha1" => string(hash)))
                end
                Base.rm(existing_dir; force = true, recursive = true)
                mv(tmp_dir, existing_dir)
            finally
                Base.rm(tmp_dir; force = true, recursive = true)
            end
            # a leftover packed form would shadow the unpacked directory
            Base.rm(joinpath(reg_dir, "$name.toml"); force = true)
            Base.rm(joinpath(reg_dir, "$name.tar.gz"); force = true)
            return name
        end
        mv(tmp, joinpath(reg_dir, "$name.tar.gz"); force = true)
        stub = Dict{String, Any}(
            "git-tree-sha1" => string(hash),
            "uuid" => string(uuid),
            "path" => "$name.tar.gz",
        )
        open(joinpath(reg_dir, "$name.toml"), "w") do f
            TOML.print(f, stub)
        end
        return name
    finally
        Base.rm(tmp; force = true)
    end
end

const GENERAL_UUID = UUID("23338594-aafe-5451-b93e-139f81909106")

# The registries known by name: what `registry add General` resolves against
# and what bootstraps over git when no package server is configured
# (`JULIA_PKG_SERVER=""`). Mutable so tests can swap in local fixtures.
const DEFAULT_REGISTRIES = [
    (name = "General", uuid = GENERAL_UUID, url = "https://github.com/JuliaRegistries/General.git"),
]

"`JULIA_PKG_UNPACK_REGISTRY=true`: server registries install unpacked."
unpack_registries() = Base.get_bool_env("JULIA_PKG_UNPACK_REGISTRY", false) == true

# uuid of the directory registry at `dir`, or nothing if its Registry.toml
# is unreadable or malformed
function directory_registry_uuid(dir::String)
    d = TOML.tryparsefile(joinpath(dir, "Registry.toml"))
    d isa TOML.ParserError && return nothing
    u = get(d, "uuid", nothing)
    u isa String || return nothing
    return tryparse(UUID, u)
end

# A same-named registry with a different uuid is a conflict; the same uuid
# means "already installed".
function check_registry_dir!(reg_dir::String, name::String, uuid::UUID)
    existing_dir = joinpath(reg_dir, name)
    if isdir(existing_dir) && isfile(joinpath(existing_dir, "Registry.toml"))
        existing_uuid = directory_registry_uuid(existing_dir)
        existing_uuid === nothing && pkgerror(
            "cannot determine the uuid of the existing registry at `$existing_dir` (corrupt Registry.toml); remove it to reinstall"
        )
        existing_uuid == uuid || pkgerror(
            "registry `$name=\"$uuid\"` conflicts with existing registry `$name=\"$existing_uuid\"`"
        )
        return false     # already present
    end
    return true
end

"""
    add_registry_from_source!(depots, url_or_path; io) -> name

Install a registry from a git url, a local git repository, or a plain
registry directory, as an unpacked directory registry in the first depot.
"""
function add_registry_from_source!(d::DepotStack, source::String; io::IO = stderr_f())
    reg_dir = mkpath(registries_dir(depots1(d)))
    create_cachedir_tag(reg_dir)
    return mkpidlock(joinpath(reg_dir, ".pid"), stale_age = 10) do
        tmp = joinpath(reg_dir, ".adding-" * string(rand(UInt32); base = 16))
        try
            if isdir(source) && !ispath(joinpath(source, ".git"))
                # plain directory registry: copy it
                isfile(joinpath(source, "Registry.toml")) ||
                    pkgerror("no `Registry.toml` found at `$source`")
                cp(source, tmp)
            else
                repo = Git.ensure_clone(io, tmp, source)
                close(repo)
            end
            reg_toml = joinpath(tmp, "Registry.toml")
            isfile(reg_toml) || pkgerror("cloned registry at `$source` is missing Registry.toml")
            data = TOML.parsefile(reg_toml)
            name = validate_registry_name(data["name"]::String)
            uuid = UUID(data["uuid"]::String)
            if !check_registry_dir!(reg_dir, name, uuid)
                Base.rm(tmp; force = true, recursive = true)
                printstyled(io, lpad("Info", 12); color = :cyan, bold = true)
                println(io, " registry `$name` already installed")
                return name
            end
            mv(tmp, joinpath(reg_dir, name))
            notify_registry_change!()
            printstyled(io, lpad("Installed", 12); color = :green, bold = true)
            println(io, " registry `$name` into the depot")
            return name
        finally
            Base.rm(tmp; force = true, recursive = true)
        end
    end
end

# Fast-forward a git-backed registry directory; returns whether it moved.
function update_git_registry!(dir::String; io::IO = stderr_f())
    return LibGit2.with(LibGit2.GitRepo(dir)) do repo
        head_before = LibGit2.head_oid(repo)
        Git.fetch(io, repo; refspecs = ["+refs/heads/*:refs/remotes/origin/*"])
        LibGit2.merge!(repo; fastforward = true)
        return LibGit2.head_oid(repo) != head_before
    end
end

"""
    add_default_registries!(depots; io) -> Vector{String}

Install the default registries into the first depot, skipping ones already
present: every registry the package server advertises (at minimum General),
or — without a package server (`JULIA_PKG_SERVER=""`) — git clones of
`DEFAULT_REGISTRIES`. This is the fresh-depot bootstrap every operation
runs when no registries are reachable.
"""
function add_default_registries!(
        depots::DepotStack; io::IO = stderr_f(),
        server::Union{Nothing, String} = Fetch.pkg_server(),
    )
    installed_uuids = Set{UUID}()
    for reg in reachable_registries(depots)
        push!(installed_uuids, registry_uuid(reg))
    end
    added = String[]
    if server === nothing
        # no package server: bootstrap the known registries over git
        for reg in DEFAULT_REGISTRIES
            reg.uuid in installed_uuids && continue
            push!(added, add_registry_from_source!(depots, reg.url; io))
        end
        return added
    end
    depot = depots1(depots)
    mkpath(registries_dir(depot))
    mkpidlock(joinpath(registries_dir(depot), ".pid"), stale_age = 10) do
        for (uuid, hash) in server_registry_hashes(server; depots)
            uuid in installed_uuids && continue
            name = install_server_registry!(depot, server, uuid, hash; io)
            push!(added, name)
        end
    end
    for name in added
        printstyled(io, lpad("Installed", 12); color = :green, bold = true)
        println(io, " registry `$name` into the depot")
    end
    isempty(added) || notify_registry_change!()
    return added
end

"""
    add_registry!(depots, spec; io) -> name

Install one registry: `spec` is a git url, a local path, or a registry
name known via `DEFAULT_REGISTRIES` (name adds prefer the package server
when it advertises that registry, and fall back to a git clone).
"""
function add_registry!(depots::DepotStack, spec::String; io::IO = stderr_f())
    if occursin(r"^\w+://", spec) || occursin('@', spec) || ispath(spec)
        return add_registry_from_source!(depots, spec; io)
    end
    idx = findfirst(reg -> reg.name == spec, DEFAULT_REGISTRIES)
    idx === nothing && pkgerror(
        "registry `$spec` is not known by name; use a url or path to add a custom registry"
    )
    known = DEFAULT_REGISTRIES[idx]
    server = Fetch.pkg_server()
    if server !== nothing
        hashes = server_registry_hashes(server; depots)
        hash = get(hashes, known.uuid, nothing)
        if hash !== nothing
            depot = depots1(depots)
            mkpath(registries_dir(depot))
            name = mkpidlock(joinpath(registries_dir(depot), ".pid"), stale_age = 10) do
                install_server_registry!(depot, server, known.uuid, hash; io)
            end
            notify_registry_change!()
            printstyled(io, lpad("Installed", 12); color = :green, bold = true)
            println(io, " registry `$name` into the depot")
            return name
        end
    end
    return add_registry_from_source!(depots, known.url; io)
end

# The removable on-disk forms of installed registries in the first depot.
function installed_registry_forms(depot::String)
    forms = NamedTuple{(:name, :uuid, :paths), Tuple{String, UUID, Vector{String}}}[]
    reg_dir = registries_dir(depot)
    isdir(reg_dir) || return forms
    for path in readdir(reg_dir; join = true)
        if isdir(path) && isfile(joinpath(path, "Registry.toml"))
            data = TOML.tryparsefile(joinpath(path, "Registry.toml"))
            data isa TOML.ParserError && continue
            haskey(data, "name") && haskey(data, "uuid") || continue
            push!(forms, (name = data["name"]::String, uuid = UUID(data["uuid"]::String), paths = [path]))
        elseif isfile(path) && endswith(path, ".toml")
            stub = TOML.tryparsefile(path)
            stub isa TOML.ParserError && continue
            haskey(stub, "uuid") && haskey(stub, "path") || continue
            tarball = joinpath(reg_dir, stub["path"]::String)
            push!(
                forms, (
                    name = splitext(basename(path))[1],
                    uuid = UUID(stub["uuid"]::String), paths = [path, tarball],
                )
            )
        end
    end
    return forms
end

"""
    remove_registry!(depots, name, uuid; io)

Remove a registry from the first depot, matched by uuid when given,
otherwise by name. A name shared by registries with different uuids
requires the uuid (`name=uuid`) to disambiguate.
"""
function remove_registry!(
        depots::DepotStack, name::Union{Nothing, String}, uuid::Union{Nothing, UUID};
        io::IO = stderr_f(),
    )
    name === nothing && uuid === nothing && pkgerror("no name or uuid specified for registry")
    forms = installed_registry_forms(depots1(depots))
    matches = if uuid !== nothing
        filter(f -> f.uuid == uuid, forms)
    else
        named = filter(f -> f.name == name, forms)
        length(unique!([f.uuid for f in named])) > 1 && pkgerror(
            "multiple registries with name `$name`, please specify with uuid `$name=uuid`"
        )
        named
    end
    if isempty(matches)
        spec = name === nothing ? string(uuid) : uuid === nothing ? name : "$name=$uuid"
        println(io, "registry `$spec` not found.")
        return nothing
    end
    reg_dir = registries_dir(depots1(depots))
    mkpidlock(joinpath(reg_dir, ".pid"), stale_age = 10) do
        for f in matches
            printpkgstyle_removing(io, f.name, f.paths[1])
            for path in f.paths
                Base.rm(path; force = true, recursive = true)
            end
        end
    end
    notify_registry_change!()
    return nothing
end

function printpkgstyle_removing(io::IO, name::String, path::String)
    printstyled(io, lpad("Removing", 12); color = :green, bold = true)
    println(io, " registry `$name` from $(Base.contractuser(path))")
    return
end

# Pkg's persisted registry-update log (`registry_updates.toml` in Pkg's
# scratchspace, keyed by registry uuid → last successful update time): lets
# the auto-update cooldown span sessions, and is shared with Pkg itself.
const PKG_SCRATCH_UUID = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
registry_update_log_file(depot::String) =
    joinpath(scratchspaces_dir(depot), PKG_SCRATCH_UUID, "registry_updates.toml")

function read_registry_update_log(depot::String)
    file = registry_update_log_file(depot)
    isfile(file) || return Dict{String, Any}()
    log = TOML.tryparsefile(file)
    return log isa TOML.ParserError ? Dict{String, Any}() : log
end

function save_registry_update_log(depot::String, log::Dict{String, Any})
    create_cachedir_tag(scratchspaces_dir(depot))
    file = registry_update_log_file(depot)
    mkpath(dirname(file))
    return atomic_toml_write(file, log)
end

"""
    update_registries!(depots; names, io, update_cooldown) -> Vector{String}

Update registries in place: packed server-backed ones by tree-hash
comparison, unpacked server-installed directories likewise, git-backed
directories by fetch + fast-forward. `names` restricts the update to the
named registries (`nothing` updates all). Registries whose entry in the
persisted update log is more recent than `update_cooldown` are skipped
(Pkg parity: `add` passes one day, explicit updates the ~zero default).
"""
@timeit TIMER "update registries" function update_registries!(
        depots_arg::DepotStack; io::IO = stderr_f(),
        names::Union{Nothing, Vector{String}} = nothing,
        server::Union{Nothing, String} = Fetch.pkg_server(),
        update_cooldown::Dates.Period = Dates.Second(1),
    )
    depot = depots1(depots_arg)
    reg_dir = registries_dir(depot)
    isdir(reg_dir) || return String[]
    wanted(name) = names === nothing || name in names
    updated = String[]
    update_log = read_registry_update_log(depot)
    log_dirty = Ref(false)
    function stamp!(uuid::UUID)
        update_log[string(uuid)] = Dates.now()
        log_dirty[] = true
        return
    end
    function on_cooldown(uuid::UUID)
        prev = get(update_log, string(uuid), nothing)
        return prev isa Dates.DateTime && Dates.now() - prev < update_cooldown
    end
    # server hashes are fetched lazily so an everything-on-cooldown call
    # makes no network requests at all
    server_hashes = Ref{Union{Nothing, Dict{UUID, SHA1}}}(nothing)
    function latest_hash(uuid::UUID)
        if server_hashes[] === nothing
            server_hashes[] = if server === nothing
                Dict{UUID, SHA1}()
            else
                try
                    server_registry_hashes(server; depots = depots_arg)
                catch err
                    err isa InterruptException && rethrow()
                    @error "Some registries failed to update:" exception = err
                    Dict{UUID, SHA1}()
                end
            end
        end
        return get(server_hashes[]::Dict{UUID, SHA1}, uuid, nothing)
    end
    mkpidlock(joinpath(reg_dir, ".pid"), stale_age = 10) do
        # packed server-backed registries
        for stub_file in filter(endswith(".toml"), readdir(reg_dir; join = true))
            wanted(splitext(basename(stub_file))[1]) || continue
            stub = TOML.tryparsefile(stub_file)
            stub isa TOML.ParserError && continue
            uuid_str = get(stub, "uuid", nothing)
            hash_str = get(stub, "git-tree-sha1", nothing)
            uuid_str isa String && hash_str isa String || continue
            uuid = tryparse(UUID, uuid_str)
            current = tryparse_sha1(hash_str)
            (uuid === nothing || current === nothing) && continue
            on_cooldown(uuid) && continue
            latest = latest_hash(uuid)
            latest === nothing && continue
            if latest == current
                # a successful server check that found the registry already
                # current still refreshes the cooldown for later sessions
                stamp!(uuid)
                continue
            end
            try
                name = install_server_registry!(depot, server, uuid, latest; io)
                push!(updated, name)
                stamp!(uuid)
            catch err
                err isa InterruptException && rethrow()
                @error "Some registries failed to update:" exception = err
            end
        end
        for dir in filter(isdir, readdir(reg_dir; join = true))
            wanted(basename(dir)) || continue
            if ispath(joinpath(dir, ".git"))
                # git-backed registry directories
                uuid = directory_registry_uuid(dir)
                uuid !== nothing && on_cooldown(uuid) && continue
                server !== nothing && basename(dir) == "General" &&
                    warn_general_registry_format("git")
                try
                    update_git_registry!(dir; io) && push!(updated, basename(dir))
                    # Pkg parity: a successful fetch + merge stamps the log
                    # even when it was already current
                    uuid === nothing || stamp!(uuid)
                catch err
                    err isa InterruptException && rethrow()
                    @error "Some registries failed to update:" exception = err
                end
            elseif isfile(joinpath(dir, ".tree_info.toml")) && isfile(joinpath(dir, "Registry.toml"))
                # unpacked server-installed registries (JULIA_PKG_UNPACK_REGISTRY)
                ti = TOML.tryparsefile(joinpath(dir, ".tree_info.toml"))
                hash_str = ti isa TOML.ParserError ? nothing : get(ti, "git-tree-sha1", nothing)
                current = hash_str isa String ? tryparse_sha1(hash_str) : nothing
                uuid = directory_registry_uuid(dir)
                if current === nothing || uuid === nothing
                    @error "Skipping registry at `$dir` during update: corrupt `.tree_info.toml` or `Registry.toml`"
                    continue
                end
                on_cooldown(uuid) && continue
                latest = latest_hash(uuid)
                latest === nothing && continue
                if latest == current
                    # already current: stamp the successful check (see above)
                    stamp!(uuid)
                    continue
                end
                basename(dir) == "General" && warn_general_registry_format("unpacked tarball")
                try
                    name = install_server_registry!(depot, server, uuid, latest; io)
                    push!(updated, name)
                    stamp!(uuid)
                catch err
                    err isa InterruptException && rethrow()
                    @error "Some registries failed to update:" exception = err
                end
            end
        end
    end
    log_dirty[] && save_registry_update_log(depot, update_log)
    isempty(updated) || notify_registry_change!()
    return updated
end

end # module
