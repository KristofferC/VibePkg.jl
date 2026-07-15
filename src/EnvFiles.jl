# Project.toml and Manifest.toml as immutable values.
#
# Pure core: `parse_project`/`parse_manifest` take parsed TOML dicts,
# `render_project`/`render_manifest` produce the canonical file text. The
# only filesystem entry points are the thin `read_project`/`read_manifest`/
# `write_project`/`write_manifest` wrappers.
#
# Round-trip model: every value keeps the raw TOML dict it was parsed from
# (`raw` fields, treated as frozen). Rendering overlays the typed fields onto
# a deep copy of `raw`, so unknown keys survive and recognized keys are
# canonical. Values are never mutated — use the `with_*` functional-update
# helpers.
#
# Deliberate fixes vs Pkg, same on-disk language:
#   - manifest `project_hash` is a single typed field (Pkg kept a second,
#     authoritative copy in the raw dict)
#   - manifest entry `entryfile` round-trips (Pkg wrote but never parsed it)
#   - a project read from a legacy `path` key writes only `entryfile`
#     (Pkg could emit both keys)
#   - project `[extensions]` is a typed field that persists (Pkg only
#     round-tripped the raw table)
#   - stale `extensions`/`apps` keys are removed from manifest entries when
#     the typed field is empty
#   - `path` + `git-tree-sha1` / `repo-url` conflicts are repaired at parse
#     into path-tracking (Pkg stored both and crashed an @assert at write)
#   - rendering never mutates the parsed value (Pkg's destructure aliased
#     and mutated entry dicts and the manifest format field)

module EnvFiles

using Base: UUID, SHA1
using TOML: TOML

using ..Errors: pkgerror
using ..Versions: VersionSpec, semver_spec
using ..Utils: isurl, normalize_path_for_toml, denormalize_path_from_toml, atomic_write

export Compat, AppInfo, SourceSpec, RepoPackage, Project,
    Tracking, PathTracked, RepoTracked, RegistryTracked,
    ManifestEntry, RegistryRef, Manifest,
    projectfile_path, manifestfile_path,
    parse_project, read_project, render_project, write_project,
    parse_manifest, read_manifest, render_manifest, write_manifest,
    entry_version, entry_tree_hash, entry_path, entry_repo_url,
    entry_repo_rev, entry_repo_subdir, entry_registries,
    is_path_tracked, is_repo_tracked, is_registry_tracked,
    with_project, with_manifest, with_entry,
    manifest_dependents_map,
    check_manifest_julia_version_compat

###########
# Values  #
###########

"A `[compat]` entry: the parsed spec plus the user's original string."
struct Compat
    val::VersionSpec
    str::String
end
Compat(str::String) = Compat(semver_spec(str), str)

"An entry of a project `[apps]` or manifest `apps` table."
struct AppInfo
    name::String
    julia_command::Union{Nothing, String}
    submodule::Union{Nothing, String}
    julia_flags::Vector{String}
    raw::Dict{String, Any}
end

"Validate an app name before it can become a filesystem path component."
function validate_app_name(name::String)
    occursin(r"^[A-Za-z][A-Za-z0-9_-]*$", name) || pkgerror(
        "Invalid app name $(repr(name)): app names must start with a letter and " *
            "contain only letters, numbers, underscores, and hyphens"
    )
    return name
end

function validate_app_submodule(submodule, app_name::String; qualified::Bool = false)
    submodule === nothing && return nothing
    submodule isa String || pkgerror("App $(repr(app_name)) field submodule must be a string; got $(repr(submodule))")
    valid = qualified ?
        all(Base.isidentifier, split(submodule, '.'; keepempty = true)) :
        Base.isidentifier(submodule)
    valid || pkgerror("Invalid submodule $(repr(submodule)) for app $(repr(app_name))")
    return submodule
end

"A `[sources]` entry. `path` and `url` are mutually exclusive."
struct SourceSpec
    path::Union{Nothing, String}
    url::Union{Nothing, String}
    rev::Union{Nothing, String}
    subdir::Union{Nothing, String}
end

# A materialized git source: the fact the effectful pre-phase (Git) produces
# and planning consumes. Becomes a
# `RepoTracked` manifest entry.
struct RepoPackage
    name::String
    uuid::UUID
    url::String
    rev::Union{Nothing, String}     # nothing = default branch, recorded as its name
    subdir::Union{Nothing, String}
    tree_hash::SHA1
    path::String                    # installed source tree
end

struct Project
    name::Union{Nothing, String}
    uuid::Union{Nothing, UUID}
    version::Union{Nothing, VersionNumber}
    deps::Dict{String, UUID}
    weakdeps::Dict{String, UUID}
    # names listed in both [deps] and [weakdeps]: treated weak-only in
    # memory, merged back into [deps] on write
    deps_weak::Dict{String, UUID}
    extras::Dict{String, UUID}
    sources::Dict{String, SourceSpec}
    compat::Dict{String, Compat}
    exts::Dict{String, Union{String, Vector{String}}}
    targets::Dict{String, Vector{String}}
    workspace::Dict{String, Any}
    manifest_path::Union{Nothing, String}   # the `manifest = "..."` key
    entryfile::Union{Nothing, String}
    readonly::Bool
    julia_syntax_version::Union{Nothing, VersionNumber}
    apps::Dict{String, AppInfo}
    raw::Dict{String, Any}
end

function Project()
    return Project(
        nothing, nothing, nothing,
        Dict{String, UUID}(), Dict{String, UUID}(), Dict{String, UUID}(),
        Dict{String, UUID}(), Dict{String, SourceSpec}(), Dict{String, Compat}(),
        Dict{String, Union{String, Vector{String}}}(), Dict{String, Vector{String}}(),
        Dict{String, Any}(), nothing, nothing, false, nothing,
        Dict{String, AppInfo}(), Dict{String, Any}(),
    )
end

"How a manifest entry tracks its content. Exactly one applies."
abstract type Tracking end

"Tracking a local path (`develop` / `[sources]` path)."
struct PathTracked <: Tracking
    path::String                            # native separators in memory
    version::Union{Nothing, VersionNumber}
end

"Tracking a git source (`add url#rev`)."
struct RepoTracked <: Tracking
    url::String                             # may be a local path for local repos
    rev::Union{Nothing, String}
    subdir::Union{Nothing, String}
    tree_hash::Union{Nothing, SHA1}         # tolerated missing on read; required to render
    version::Union{Nothing, VersionNumber}
end

"Tracking the registry ecosystem — registered packages, stdlibs, bare entries."
struct RegistryTracked <: Tracking
    version::Union{Nothing, VersionNumber}
    tree_hash::Union{Nothing, SHA1}
    registries::Vector{String}
end

# Concrete union over the `Tracking` subtypes. Used as the field type wherever a
# tracking value is stored so the field stays type-stable via union splitting,
# rather than being boxed behind the abstract `Tracking`.
const AnyTracking = Union{PathTracked, RepoTracked, RegistryTracked}

struct ManifestEntry
    name::String
    uuid::UUID
    tracking::AnyTracking
    pinned::Bool
    deps::Dict{String, UUID}
    weakdeps::Dict{String, UUID}
    exts::Dict{String, Union{String, Vector{String}}}
    apps::Dict{String, AppInfo}
    entryfile::Union{Nothing, String}
    julia_syntax_version::Union{Nothing, VersionNumber}
    raw::Dict{String, Any}
end

"A `[registries]` provenance entry of a manifest (format 2.1+)."
struct RegistryRef
    id::String
    uuid::UUID
    url::Union{Nothing, String}
end

struct Manifest
    julia_version::Union{Nothing, VersionNumber}
    manifest_format::VersionNumber
    project_hash::Union{Nothing, SHA1}
    deps::Dict{UUID, ManifestEntry}
    registries::Dict{String, RegistryRef}
    raw::Dict{String, Any}                  # unrecognized toplevel keys
end

function Manifest()
    return Manifest(
        nothing, v"2.0.0", nothing,
        Dict{UUID, ManifestEntry}(), Dict{String, RegistryRef}(), Dict{String, Any}(),
    )
end

# Semantic field-wise equality and hashing for all value types (the default
# struct == is === for mutable fields like Dicts). The `raw` round-trip dicts
# are NOT part of semantic identity: a freshly computed value must compare
# equal to the same value re-parsed from disk, or diff-aware writes would
# always fire.
function _fields_equal(a::T, b::T) where {T}
    for i in 1:nfields(a)
        fieldname(T, i) === :raw && continue
        isequal(getfield(a, i), getfield(b, i)) || return false
    end
    return true
end
function _fields_hash(x::T, h::UInt) where {T}
    h = hash(T, h)
    for i in 1:nfields(x)
        fieldname(T, i) === :raw && continue
        h = hash(getfield(x, i), h)
    end
    return h
end
for T in (
        :Compat, :AppInfo, :SourceSpec, :Project,
        :PathTracked, :RepoTracked, :RegistryTracked,
        :ManifestEntry, :RegistryRef, :Manifest,
    )
    @eval begin
        Base.:(==)(a::$T, b::$T) = _fields_equal(a, b)
        Base.hash(x::$T, h::UInt) = _fields_hash(x, h)
    end
end
Base.:(==)(::Tracking, ::Tracking) = false      # different tracking kinds differ

# Tracking accessors, also lifted to entries.
entry_version(t::PathTracked) = t.version
entry_version(t::RepoTracked) = t.version
entry_version(t::RegistryTracked) = t.version
entry_tree_hash(t::PathTracked) = nothing
entry_tree_hash(t::RepoTracked) = t.tree_hash
entry_tree_hash(t::RegistryTracked) = t.tree_hash
entry_path(t::Tracking) = nothing
entry_path(t::PathTracked) = t.path
entry_repo_url(t::Tracking) = nothing
entry_repo_url(t::RepoTracked) = t.url
entry_repo_rev(t::Tracking) = nothing
entry_repo_rev(t::RepoTracked) = t.rev
entry_repo_subdir(t::Tracking) = nothing
entry_repo_subdir(t::RepoTracked) = t.subdir
entry_registries(t::Tracking) = String[]
entry_registries(t::RegistryTracked) = t.registries
for f in (
        :entry_version, :entry_tree_hash, :entry_path, :entry_repo_url,
        :entry_repo_rev, :entry_repo_subdir, :entry_registries,
    )
    @eval $f(e::ManifestEntry) = $f(e.tracking)
end
is_path_tracked(e::ManifestEntry) = e.tracking isa PathTracked
is_repo_tracked(e::ManifestEntry) = e.tracking isa RepoTracked
is_registry_tracked(e::ManifestEntry) = e.tracking isa RegistryTracked

# Manifest behaves as a Dict{UUID,ManifestEntry} for reading.
Base.iterate(m::Manifest, args...) = iterate(m.deps, args...)
Base.length(m::Manifest) = length(m.deps)
Base.isempty(m::Manifest) = isempty(m.deps)
Base.getindex(m::Manifest, uuid::UUID) = m.deps[uuid]
Base.get(m::Manifest, uuid::UUID, default) = get(m.deps, uuid, default)
Base.haskey(m::Manifest, uuid::UUID) = haskey(m.deps, uuid)
Base.keys(m::Manifest) = keys(m.deps)
Base.values(m::Manifest) = values(m.deps)
Base.pairs(m::Manifest) = pairs(m.deps)

"""
    manifest_dependents_map(m::Manifest) -> Dict{UUID, Vector{UUID}}

Reverse dependency edges: for each uuid, the uuids of the manifest entries
that list it as a dependency. Built in one pass so callers that need
dependents of many packages avoid rescanning the manifest per package.
"""
function manifest_dependents_map(m::Manifest)
    dependents = Dict{UUID, Vector{UUID}}()
    for (uuid, entry) in m
        for dep in values(entry.deps)
            push!(get!(() -> UUID[], dependents, dep), uuid)
        end
    end
    return dependents
end

######################
# Functional updates #
######################

function with_project(
        p::Project;
        name = p.name, uuid = p.uuid, version = p.version,
        deps = p.deps, weakdeps = p.weakdeps, deps_weak = p.deps_weak,
        extras = p.extras, sources = p.sources, compat = p.compat,
        exts = p.exts, targets = p.targets, workspace = p.workspace,
        manifest_path = p.manifest_path, entryfile = p.entryfile,
        readonly = p.readonly, julia_syntax_version = p.julia_syntax_version,
        apps = p.apps, raw = p.raw,
    )
    return Project(
        name, uuid, version, deps, weakdeps, deps_weak, extras, sources,
        compat, exts, targets, workspace, manifest_path, entryfile, readonly,
        julia_syntax_version, apps, raw,
    )
end

function with_manifest(
        m::Manifest;
        julia_version = m.julia_version, manifest_format = m.manifest_format,
        project_hash = m.project_hash, deps = m.deps,
        registries = m.registries, raw = m.raw,
    )
    return Manifest(julia_version, manifest_format, project_hash, deps, registries, raw)
end

function with_entry(
        e::ManifestEntry;
        name = e.name, uuid = e.uuid, tracking = e.tracking, pinned = e.pinned,
        deps = e.deps, weakdeps = e.weakdeps, exts = e.exts, apps = e.apps,
        entryfile = e.entryfile, julia_syntax_version = e.julia_syntax_version,
        raw = e.raw,
    )
    return ManifestEntry(
        name, uuid, tracking, pinned, deps, weakdeps, exts, apps, entryfile,
        julia_syntax_version, raw,
    )
end

##################
# File discovery #
##################

function projectfile_path(env_path::String; strict = false)
    for name in Base.project_names
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    return strict ? nothing : joinpath(env_path, "Project.toml")
end

function manifestfile_path(env_path::String; strict = false)
    for name in Base.manifest_names
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    if strict
        return nothing
    else
        # no matching manifest exists: JuliaProject.toml pairs with
        # JuliaManifest.toml, everything else with Manifest.toml
        project, _ = splitext(basename(projectfile_path(env_path)::String))
        if project == "JuliaProject"
            return joinpath(env_path, "JuliaManifest.toml")
        else
            return joinpath(env_path, "Manifest.toml")
        end
    end
end

###################
# Project reading #
###################

listed_deps(project::Project; include_weak::Bool) = vcat(
    collect(keys(project.deps)), collect(keys(project.extras)),
    include_weak ? vcat(collect(keys(project.weakdeps)), collect(keys(project.deps_weak))) : String[],
)

project_location(file) = file === nothing ? "streamed project" : repr(file)

read_project_uuid(::Nothing; file = nothing) = nothing
function read_project_uuid(uuid::String; file = nothing)
    return try
        UUID(uuid)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Invalid project UUID $(repr(uuid)) in $(project_location(file)); expected a UUID string")
    end
end
read_project_uuid(uuid; file = nothing) =
    pkgerror("Invalid project UUID $(repr(uuid)) in $(project_location(file)); expected a UUID string")

read_project_version(::Nothing; file = nothing) = nothing
function read_project_version(version::String; file = nothing)
    return try
        VersionNumber(version)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Invalid project version $(repr(version)) in $(project_location(file))")
    end
end
read_project_version(version; file = nothing) =
    pkgerror("Invalid project version $(repr(version)) in $(project_location(file)); expected a version string")

read_project_deps(::Nothing, section::String; file = nothing) = Dict{String, UUID}()
function read_project_deps(raw::Dict{String, Any}, section_name::String; file = nothing)
    deps = Dict{String, UUID}()
    for (name, uuid) in raw
        # guard: UUID(x) accepts any Integer, silently making a bogus UUID
        uuid isa String || pkgerror(
            "Dependency $(repr(name)) in [$section_name] of $(project_location(file)) must be a UUID string; got $(repr(uuid))"
        )
        deps[name] = try
            UUID(uuid)
        catch err
            err isa ArgumentError || rethrow()
            pkgerror("Invalid UUID $(repr(uuid)) for dependency $(repr(name)) in [$section_name] of $(project_location(file))")
        end
    end
    return deps
end
function read_project_deps(raw, section_name::String; file = nothing)
    pkgerror("Expected [$section_name] to be a TOML table in $(project_location(file)); got $(repr(raw))")
end

read_project_targets(::Nothing; file = nothing) = Dict{String, Vector{String}}()
function read_project_targets(raw::Dict{String, Any}; file = nothing)
    targets = Dict{String, Vector{String}}()
    for (target, deps) in raw
        # an empty or heterogeneous TOML array parses as Vector{Any}
        deps isa Vector && all(x -> x isa String, deps) || pkgerror(
            "Target $(repr(target)) must be an array of dependency-name strings in $(project_location(file)); got $(repr(deps))"
        )
        targets[target] = String[x for x in deps]
    end
    return targets
end
read_project_targets(raw; file = nothing) =
    pkgerror("Expected [targets] to be a TOML table in $(project_location(file)); got $(repr(raw))")

read_project_apps(::Nothing; file = nothing) = Dict{String, AppInfo}()
function read_project_apps(raw::Dict{String, Any}; file = nothing)
    appinfos = Dict{String, AppInfo}()
    for (name, info) in raw
        validate_app_name(name)
        info isa Dict{String, Any} || pkgerror("App $(repr(name)) in [apps] of $(project_location(file)) must be a TOML table; got $(repr(info))")
        submodule = validate_app_submodule(get(info, "submodule", nothing), name)
        julia_flags_raw = get(info, "julia_flags", nothing)
        julia_flags = if julia_flags_raw === nothing
            String[]
        elseif julia_flags_raw isa Vector
            all(flag -> flag isa String, julia_flags_raw) ||
                pkgerror("App $(repr(name)) field julia_flags must be an array of strings; got $(repr(julia_flags_raw))")
            String[String(flag) for flag in julia_flags_raw]
        else
            pkgerror("App $(repr(name)) field julia_flags must be an array of strings; got $(repr(julia_flags_raw))")
        end
        appinfos[name] = AppInfo(name, nothing, submodule, julia_flags, info)
    end
    return appinfos
end
read_project_apps(raw; file = nothing) =
    pkgerror("Expected [apps] to be a TOML table in $(project_location(file)); got $(repr(raw))")

read_project_compat(::Nothing; file = nothing) = Dict{String, Compat}()
function read_project_compat(raw::Dict{String, Any}; file = nothing)
    compat = Dict{String, Compat}()
    location_string = file === nothing ? "" : " in $(repr(file))"
    for (name, version) in raw
        version isa String || pkgerror(
            "Invalid [compat] entry $name = $(repr(version)) in $(project_location(file)); expected a string"
        )
        compat[name] = try
            Compat(semver_spec(version), version)
        catch err
            err isa InterruptException && rethrow()
            pkgerror("Invalid [compat] entry $name = $(repr(version)) in $(project_location(file)): $(sprint(showerror, err))")
        end
    end
    return compat
end
read_project_compat(raw; file = nothing) =
    pkgerror("Expected [compat] to be a TOML table in $(project_location(file)); got $(repr(raw))")

read_project_sources(::Nothing; file = nothing) = Dict{String, SourceSpec}()
function read_project_sources(raw::Dict{String, Any}; file = nothing)
    valid_keys = ("path", "url", "rev", "subdir")
    sources = Dict{String, SourceSpec}()
    for (name, source) in raw
        if !(source isa AbstractDict)
            pkgerror("Expected [sources].$name to be a TOML table in $(project_location(file)); got $(repr(source))")
        end
        for key in keys(source)
            key isa String && key in valid_keys ||
                pkgerror("Unknown key $(repr(key)) in [sources].$name; expected path, url, rev, or subdir")
        end
        if haskey(source, "path") && (haskey(source, "url") || haskey(source, "rev"))
            pkgerror("[sources].$name cannot specify path together with url or rev")
        end
        for key in valid_keys
            value = get(source, key, nothing)
            value === nothing || value isa String || pkgerror(
                "[sources].$name.$key must be a string in $(project_location(file)); got $(repr(value))"
            )
        end
        sources[name] = SourceSpec(
            get(source, "path", nothing), get(source, "url", nothing),
            get(source, "rev", nothing), get(source, "subdir", nothing),
        )
    end
    return sources
end
read_project_sources(raw; file = nothing) =
    pkgerror("Expected [sources] to be a TOML table in $(project_location(file)); got $(repr(raw))")

read_project_workspace(::Nothing; file = nothing) = Dict{String, Any}()
function read_project_workspace(raw::Dict; file = nothing)
    workspace_table = Dict{String, Any}()
    for (key, val) in raw
        if key == "projects"
            # an empty or heterogeneous TOML array parses as Vector{Any}
            val isa Vector && all(x -> x isa String, val) ||
                pkgerror("[workspace].projects must be an array of strings in $(project_location(file)); got $(repr(val))")
        else
            pkgerror("Unknown key $(repr(key)) in [workspace]; expected only projects")
        end
        workspace_table[key] = val
    end
    return workspace_table
end
read_project_workspace(raw; file = nothing) =
    pkgerror("Expected [workspace] to be a TOML table in $(project_location(file)); got $(repr(raw))")

read_project_exts(::Nothing; file = nothing) = Dict{String, Union{String, Vector{String}}}()
function read_project_exts(raw::Dict{String, Any}; file = nothing)
    exts = Dict{String, Union{String, Vector{String}}}()
    for (key, val) in raw
        if val isa String
            exts[key] = val
        elseif val isa Vector && all(x -> x isa String, val)
            exts[key] = String[x for x in val]
        else
            pkgerror("Extension $(repr(key)) must name one dependency or an array of dependencies in $(project_location(file)); got $(repr(val))")
        end
    end
    return exts
end
read_project_exts(raw; file = nothing) =
    pkgerror("Expected [extensions] to be a TOML table in $(project_location(file)); got $(repr(raw))")

function validate_project(project::Project; file = nothing)
    location_string = " in $(project_location(file))"
    for (section, entries) in (("deps", project.deps), ("weakdeps", project.weakdeps), ("extras", project.extras))
        by_uuid = Dict{UUID, Vector{String}}()
        for (name, uuid) in entries
            push!(get!(Vector{String}, by_uuid, uuid), name)
        end
        for (uuid, names) in by_uuid
            length(names) > 1 || continue
            pkgerror("Dependencies $(repr(names[1])) and $(repr(names[2])) in [$section] use the same UUID $uuid$location_string")
        end
    end
    listed = listed_deps(project; include_weak = true)
    for (target, deps) in project.targets, dep in deps
        if length(deps) != length(unique(deps))
            duplicate = first(dep for dep in deps if count(==(dep), deps) > 1)
            pkgerror("Target $(repr(target)) contains duplicate dependency $(repr(duplicate))$location_string")
        end
        dep in listed || pkgerror(
            "Dependency $(repr(dep)) in target $(repr(target)) is not listed in [deps], [weakdeps], or [extras]$location_string"
        )
    end
    for name in keys(project.compat)
        name == "julia" && continue
        name in listed ||
            pkgerror("[compat] entry $(repr(name)) is not listed in [deps], [weakdeps], or [extras]$location_string")
    end
    listed_nonweak = listed_deps(project; include_weak = false)
    for name in keys(project.sources)
        name in listed_nonweak ||
            pkgerror("[sources] entry $(repr(name)) is not listed in [deps] or [extras]$location_string")
    end
    return
end

function parse_project(raw::Dict{String, Any}; file = nothing)
    optional_string(key) = begin
        value = get(raw, key, nothing)
        value === nothing || value isa String || pkgerror(
            "Project field $key must be a string in $(project_location(file)); got $(repr(value))"
        )
        value
    end
    name = optional_string("name")
    manifest_path = optional_string("manifest")
    # legacy `path` key is accepted as `entryfile` on read; only `entryfile`
    # is ever written
    entryfile = optional_string("path")
    if entryfile === nothing
        entryfile = optional_string("entryfile")
    end
    uuid = read_project_uuid(get(raw, "uuid", nothing); file)
    version = read_project_version(get(raw, "version", nothing); file)
    deps = read_project_deps(get(raw, "deps", nothing), "deps"; file)
    weakdeps = read_project_deps(get(raw, "weakdeps", nothing), "weakdeps"; file)
    exts = read_project_exts(get(raw, "extensions", nothing); file)
    sources = read_project_sources(get(raw, "sources", nothing); file)
    extras = read_project_deps(get(raw, "extras", nothing), "extras"; file)
    compat = read_project_compat(get(raw, "compat", nothing); file)
    targets = read_project_targets(get(raw, "targets", nothing); file)
    workspace = read_project_workspace(get(raw, "workspace", nothing); file)
    apps = read_project_apps(get(raw, "apps", nothing); file)
    readonly = get(raw, "readonly", false)
    readonly isa Bool || pkgerror("Project field readonly must be a Boolean in $(project_location(file)); got $(repr(readonly))")
    syntax = get(raw, "syntax", nothing)
    syntax === nothing || syntax isa Dict || pkgerror("Project field syntax must be a TOML table in $(project_location(file)); got $(repr(syntax))")
    julia_syntax_version = syntax === nothing ? nothing :
        read_project_version(get(syntax, "julia_version", nothing); file)

    # a name in both [deps] and [weakdeps] is weak-only in memory
    deps_weak = Dict(intersect(deps, weakdeps))
    deps = filter(p -> !haskey(deps_weak, p.first), deps)

    project = Project(
        name, uuid, version, deps, weakdeps, deps_weak, extras, sources,
        compat, exts, targets, workspace, manifest_path, entryfile, readonly,
        julia_syntax_version, apps, raw,
    )
    validate_project(project; file)
    return project
end

function read_project(f_or_io::Union{String, IO})
    raw = try
        if f_or_io isa IO
            TOML.parse(read(f_or_io, String))
        else
            isfile(f_or_io) ? TOML.parsefile(f_or_io) : return Project()
        end
    catch e
        if e isa TOML.ParserError
            subject = f_or_io isa IO ? "streamed project" : "project at $(repr(f_or_io))"
            pkgerror("Could not parse $subject: ", sprint(showerror, e))
        end
        subject = f_or_io isa IO ? "streamed project" : "project at $(repr(f_or_io))"
        pkgerror("Could not read $subject: ", sprint(showerror, e))
    end
    return parse_project(raw; file = f_or_io isa IO ? nothing : f_or_io)
end

###################
# Project writing #
###################

source_to_dict(s::SourceSpec) = Dict{String, String}(
    k => v for (k, v) in (
            "path" => s.path === nothing ? nothing : normalize_path_for_toml(s.path),
            "url" => s.url, "rev" => s.rev, "subdir" => s.subdir,
        ) if v !== nothing
)

function destructure_project(project::Project)::Dict{String, Any}
    raw = deepcopy(project.raw)

    # sanity check for consistency between compat value and string representation
    for (name, compat) in project.compat
        if compat.val != semver_spec(compat.str)
            pkgerror("Internal error while writing [compat]: parsed value and stored text disagree for $(repr(name))")
        end
    end

    # if a field is set to its default value, don't include it in the write
    function entry!(key::String, src)
        should_delete(x::Dict) = isempty(x)
        should_delete(x) = x === nothing
        return should_delete(src) ? delete!(raw, key) : (raw[key] = src)
    end

    entry!("name", project.name)
    entry!("uuid", project.uuid)
    entry!("version", project.version)
    entry!("workspace", project.workspace)
    entry!("manifest", project.manifest_path)
    delete!(raw, "path")                    # consumed into entryfile at read
    entry!("entryfile", project.entryfile)
    entry!("deps", merge(project.deps, project.deps_weak))
    entry!("weakdeps", project.weakdeps)
    entry!("extensions", project.exts)
    entry!("sources", Dict{String, Any}(name => source_to_dict(s) for (name, s) in project.sources))
    entry!("extras", project.extras)
    entry!("compat", Dict(name => x.str for (name, x) in project.compat))
    entry!("targets", project.targets)
    appdict = Dict{String, Any}()
    for (appname, appinfo) in project.apps
        # start from the app's raw table so unrecognized keys survive; the
        # typed fields overwrite (or remove) their raw counterparts
        app_dict = Dict{String, Any}(appinfo.raw)
        appinfo.submodule === nothing ? delete!(app_dict, "submodule") :
            (app_dict["submodule"] = appinfo.submodule)
        isempty(appinfo.julia_flags) ? delete!(app_dict, "julia_flags") :
            (app_dict["julia_flags"] = appinfo.julia_flags)
        appdict[appname] = app_dict
    end
    entry!("apps", appdict)
    entry!(
        "syntax", project.julia_syntax_version === nothing ? nothing :
            Dict("julia_version" => string(project.julia_syntax_version))
    )
    if project.readonly
        raw["readonly"] = true
    else
        delete!(raw, "readonly")
    end

    return raw
end

const _project_key_order = [
    "name", "uuid", "keywords", "license", "desc", "version", "readonly",
    "workspace", "deps", "weakdeps", "sources", "extensions", "compat",
]
project_key_order(key::String) =
    something(findfirst(x -> x == key, _project_key_order), length(_project_key_order) + 1)

function write_project(io::IO, raw::Dict)
    inline_tables = Base.IdSet{Dict}()
    if haskey(raw, "sources")
        for source in values(raw["sources"])
            source isa Dict || pkgerror("Cannot write project: [sources] contains unsupported value $(repr(source)) of type $(typeof(source))")
            push!(inline_tables, source)
        end
    end
    TOML.print(io, raw; inline_tables, sorted = true, by = key -> (project_key_order(key), key)) do x
        x isa UUID || x isa VersionNumber || pkgerror("Cannot write project value $(repr(x)): unsupported type $(typeof(x))")
        return string(x)
    end
    return nothing
end
write_project(io::IO, project::Project) = write_project(io, destructure_project(project))

render_project(project::Project) = sprint(write_project, project)

function write_project(project::Project, project_file::AbstractString)
    str = render_project(project)
    mkpath(dirname(project_file))
    return atomic_write(project_file, str)
end

####################
# Manifest reading #
####################

function read_field(name::String, default, info, map; context::String = "manifest entry")
    x = get(info, name, default)
    if default === nothing
        x === nothing && return nothing
    else
        x == default && return default
    end
    x isa String || pkgerror("Manifest field $name must be a string for $context; got $(repr(x))")
    return map(x)
end

function read_pinned(pinned; context::String = "manifest entry")
    pinned === nothing && return false
    pinned isa Bool && return pinned
    pkgerror("Manifest field pinned must be a Boolean for $context; got $(repr(pinned))")
end

function safe_SHA1(sha::String; context::String = "manifest entry")
    return try
        SHA1(sha)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Invalid Git tree SHA-1 $(repr(sha)) for $context")
    end
end

function safe_uuid(uuid::String; context::String = "manifest entry")::UUID
    return try
        UUID(uuid)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Invalid UUID $(repr(uuid)) for $context")
    end
end

function safe_version(version::String; context::String = "manifest entry")::VersionNumber
    return try
        VersionNumber(version)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Invalid version $(repr(version)) for $context")
    end
end

read_deps(::Nothing; context::String = "manifest entry") = Dict{String, UUID}()
read_deps(deps; context::String = "manifest entry") =
    pkgerror("Manifest deps for $context must be an array of names or a name-to-UUID table; got $(repr(deps))")
function read_deps(deps::AbstractVector; context::String = "manifest entry")
    ret = String[]
    for dep in deps
        dep isa String || pkgerror("Manifest dependency in $context must be a string; got $(repr(dep))")
        push!(ret, dep)
    end
    return ret
end
function read_deps(raw::Dict{String, Any}; context::String = "manifest entry")::Dict{String, UUID}
    deps = Dict{String, UUID}()
    for (name, uuid) in raw
        uuid isa String || pkgerror("Manifest dependency $(repr(name)) in $context must map to a UUID string; got $(repr(uuid))")
        deps[name] = safe_uuid(uuid; context = "dependency $(repr(name)) of $context")
    end
    return deps
end

read_apps(::Nothing; context::String = "manifest entry") = Dict{String, AppInfo}()
read_apps(apps; context::String = "manifest entry") =
    pkgerror("Manifest apps for $context must be a TOML table; got $(repr(apps))")
function read_apps(apps::Dict; context::String = "manifest entry")
    appinfos = Dict{String, AppInfo}()
    for (appname, app) in apps
        appname isa String || pkgerror("Manifest app names for $context must be strings; got $(repr(appname))")
        validate_app_name(appname)
        app isa Dict || pkgerror("Manifest app $(repr(appname)) for $context must be a TOML table; got $(repr(app))")
        submodule = validate_app_submodule(get(app, "submodule", nothing), appname; qualified = true)
        julia_flags_raw = get(app, "julia_flags", nothing)
        julia_flags = if julia_flags_raw === nothing
            String[]
        else
            julia_flags_raw isa Vector && all(flag -> flag isa String, julia_flags_raw) ||
                pkgerror("Manifest app $(repr(appname)) field julia_flags must be an array of strings; got $(repr(julia_flags_raw))")
            String[String(flag) for flag in julia_flags_raw]
        end
        julia_command = get(app, "julia_command", nothing)
        julia_command === nothing && pkgerror("Manifest app $(repr(appname)) for $context is missing string field julia_command")
        julia_command isa String || pkgerror("Manifest app $(repr(appname)) field julia_command must be a string; got $(repr(julia_command))")
        appinfo = AppInfo(appname, julia_command, submodule, julia_flags, app)
        appinfos[appinfo.name] = appinfo
    end
    return appinfos
end

read_exts(::Nothing; context::String = "manifest entry") = Dict{String, Union{String, Vector{String}}}()
read_exts(raw; context::String = "manifest entry") =
    pkgerror("Manifest extensions for $context must be a TOML table; got $(repr(raw))")
function read_exts(raw::Dict{String, Any}; context::String = "manifest entry")
    exts = Dict{String, Union{String, Vector{String}}}()
    for (key, val) in raw
        if val isa String
            exts[key] = val
        elseif val isa Vector && all(x -> x isa String, val)
            # an empty list round-trips through the manifest as Vector{Any}
            exts[key] = String[x for x in val]
        else
            pkgerror("Manifest extension $(repr(key)) for $context must be a string or array of strings; got $(repr(val))")
        end
    end
    return exts
end

# Parsed entry before dep-graph normalization: deps may still be name lists.
struct EntryStage
    name::String
    uuid::UUID
    pinned::Bool
    version::Union{Nothing, VersionNumber}
    path::Union{Nothing, String}
    repo_url::Union{Nothing, String}
    repo_rev::Union{Nothing, String}
    repo_subdir::Union{Nothing, String}
    tree_hash::Union{Nothing, SHA1}
    registries::Vector{String}
    deps::Union{Vector{String}, Dict{String, UUID}}
    weakdeps::Union{Vector{String}, Dict{String, UUID}}
    exts::Dict{String, Union{String, Vector{String}}}
    apps::Dict{String, AppInfo}
    entryfile::Union{Nothing, String}
    julia_syntax_version::Union{Nothing, VersionNumber}
    raw::Dict{String, Any}
end

manifest_path_str(f_or_io::IO) = "streamed manifest"
manifest_path_str(path::String) = path

# Stdlibs is included after EnvFiles, so the sibling module is looked up
# lazily (same pattern as REPLMode's Registry lookup).
function stdlib_uuid_for_name(name::String)
    Stdlibs = getfield(parentmodule(@__MODULE__), :Stdlibs)
    for (uuid, info) in Stdlibs.stdlib_infos()
        info.name == name && return uuid
    end
    return nothing
end

normalize_entry_deps(name, uuid, deps::Dict{String, UUID}, stage1, manifest_path; isext = false) = deps
function normalize_entry_deps(name, uuid, deps::Vector{String}, stage1::Dict{String, Vector{EntryStage}}, manifest_path; isext = false)
    if length(deps) != length(unique(deps))
        duplicate = first(dep for dep in deps if count(==(dep), deps) > 1)
        pkgerror("Manifest entry $name=$uuid contains duplicate dependency $(repr(duplicate)) in $(repr(manifest_path))")
    end
    final = Dict{String, UUID}()
    for dep in deps
        infos = get(stage1, dep, nothing)
        if infos === nothing
            # stdlibs may be listed by name without a manifest entry of their own
            stdlib = stdlib_uuid_for_name(dep)
            if stdlib !== nothing
                final[dep] = stdlib
                continue
            end
        end
        if !isext
            if infos === nothing
                pkgerror(
                    "Manifest entry $name=$uuid depends on $(repr(dep)), but no matching entry exists in $(repr(manifest_path))"
                )
            end
        end
        # should have used dict format instead of vector format
        if isnothing(infos) || length(infos) != 1
            pkgerror(
                "Manifest entry $name=$uuid has an ambiguous dependency $(repr(dep)) in $(repr(manifest_path)); use the name-to-UUID table form"
            )
        end
        final[dep] = infos[1].uuid
    end
    return final
end

function build_tracking(s::EntryStage)
    # Repair-at-parse: `path` wins over conflicting tree-hash/repo fields
    # (Pkg stored the conflict and crashed an @assert when writing).
    if s.path !== nothing
        return PathTracked(s.path, s.version)
    elseif s.repo_url !== nothing
        return RepoTracked(s.repo_url, s.repo_rev, s.repo_subdir, s.tree_hash, s.version)
    else
        return RegistryTracked(s.version, s.tree_hash, s.registries)
    end
end

function read_registry_ref(id::String, info::Dict{String, Any}; manifest_path::String = "manifest")
    uuid_val = get(info, "uuid", nothing)
    uuid_val isa String || pkgerror("Manifest registry $(repr(id)) in $(repr(manifest_path)) requires a string UUID; got $(repr(uuid_val))")
    uuid = safe_uuid(uuid_val; context = "registry $(repr(id)) in $(repr(manifest_path))")
    url_val = get(info, "url", nothing)
    url_val === nothing || url_val isa String || pkgerror("Manifest registry $(repr(id)) field url must be a string; got $(repr(url_val))")
    return RegistryRef(id, uuid, url_val === nothing ? nothing : String(url_val))
end

function parse_manifest(raw::Dict{String, Any}, f_or_io::Union{String, IO})::Manifest
    manifest_path = manifest_path_str(f_or_io)
    julia_version = haskey(raw, "julia_version") ?
        read_field("julia_version", nothing, raw, x -> safe_version(x; context = repr(manifest_path)); context = repr(manifest_path)) : nothing
    project_hash = haskey(raw, "project_hash") ?
        read_field("project_hash", nothing, raw, x -> safe_SHA1(x; context = repr(manifest_path)); context = repr(manifest_path)) : nothing

    format_raw = get(raw, "manifest_format", nothing)
    format_raw isa String || pkgerror("Manifest field manifest_format must be a string in $(repr(manifest_path)); got $(repr(format_raw))")
    manifest_format = safe_version(format_raw; context = "manifest_format in $(repr(manifest_path))")
    if !in(manifest_format.major, 1:2)
        if f_or_io isa IO
            @warn "Unknown Manifest.toml format version detected in streamed manifest. Unexpected behavior may occur" manifest_format
        else
            @warn "Unknown Manifest.toml format version detected in file `$(f_or_io)`. Unexpected behavior may occur" manifest_format maxlog = 1 _id = Symbol(f_or_io)
        end
    end

    stage1 = Dict{String, Vector{EntryStage}}()
    if haskey(raw, "deps") # deps field doesn't exist if there are no deps
        deps_raw = raw["deps"]
        deps_raw isa Dict{String, Any} || pkgerror("Manifest field deps must be a TOML table in $(repr(manifest_path)); got $(repr(deps_raw))")
        for (name, infos) in deps_raw
            infos isa Vector || pkgerror("Manifest entry $(repr(name)) in $(repr(manifest_path)) must be an array of tables; got $(repr(infos))")
            for info in infos
                info isa Dict{String, Any} || pkgerror("Manifest entry $(repr(name)) in $(repr(manifest_path)) must be a TOML table; got $(repr(info))")
                context = "entry $(repr(name)) in $(repr(manifest_path))"
                pinned = read_pinned(get(info, "pinned", nothing); context)
                uuid_raw = read_field("uuid", nothing, info, identity; context)
                uuid_raw === nothing && pkgerror("Manifest $context is missing required string field uuid")
                uuid = safe_uuid(uuid_raw; context)
                version = read_field("version", nothing, info, x -> safe_version(x; context); context)
                path = read_field("path", nothing, info, denormalize_path_from_toml; context)
                repo_url = read_field("repo-url", nothing, info, identity; context)
                repo_rev = read_field("repo-rev", nothing, info, identity; context)
                repo_subdir = read_field("repo-subdir", nothing, info, identity; context)
                tree_hash = read_field("git-tree-sha1", nothing, info, x -> safe_SHA1(x; context); context)
                entryfile = read_field("entryfile", nothing, info, identity; context)
                reg_field = get(info, "registries", nothing)
                registries = if reg_field isa String
                    [reg_field]
                elseif reg_field isa Vector && all(r -> r isa String, reg_field)
                    String[r for r in reg_field]
                elseif reg_field === nothing
                    String[]
                else
                    pkgerror("Manifest field registries for $context must be a string or array of strings; got $(repr(reg_field))")
                end
                deps = read_deps(get(info, "deps", nothing); context)
                weakdeps = read_deps(get(info, "weakdeps", nothing); context)
                apps = read_apps(get(info, "apps", nothing); context)
                exts = read_exts(get(info, "extensions", nothing); context)
                syntax = get(info, "syntax", nothing)
                syntax === nothing || syntax isa Dict{String, Any} || pkgerror("Manifest field syntax for $context must be a TOML table; got $(repr(syntax))")
                julia_syntax_version = syntax === nothing ? nothing :
                    read_field("julia_version", nothing, syntax, x -> safe_version(x; context); context)
                stage = EntryStage(
                    name, uuid, pinned, version, path, repo_url, repo_rev,
                    repo_subdir, tree_hash, registries, deps, weakdeps, exts,
                    apps, entryfile, julia_syntax_version, info,
                )
                stage1[name] = push!(get(stage1, name, EntryStage[]), stage)
            end
        end
    end

    registries = Dict{String, RegistryRef}()
    if haskey(raw, "registries")
        regs_raw = raw["registries"]
        regs_raw isa Dict{String, Any} || pkgerror("Manifest field registries must be a TOML table in $(repr(manifest_path)); got $(repr(regs_raw))")
        for (reg_id, info_any) in regs_raw
            info_any isa Dict{String, Any} || pkgerror("Manifest registry $(repr(reg_id)) in $(repr(manifest_path)) must be a TOML table; got $(repr(info_any))")
            registries[reg_id] = read_registry_ref(reg_id, info_any; manifest_path)
        end
    end

    other = Dict{String, Any}()
    for (k, v) in raw
        if k in ("julia_version", "deps", "manifest_format", "registries", "project_hash")
            continue
        end
        other[k] = v
    end

    # expand vector-format deps now that all entries are known
    deps = Dict{UUID, ManifestEntry}()
    for (name, stages) in stage1, s in stages
        entry_deps = normalize_entry_deps(name, s.uuid, s.deps, stage1, manifest_path)
        entry_weakdeps = normalize_entry_deps(name, s.uuid, s.weakdeps, stage1, manifest_path; isext = true)
        deps[s.uuid] = ManifestEntry(
            name, s.uuid, build_tracking(s), s.pinned, entry_deps,
            entry_weakdeps, s.exts, s.apps, s.entryfile,
            s.julia_syntax_version, s.raw,
        )
    end

    # verify the graph structure (strong deps must exist under the same name)
    for (entry_uuid, entry) in deps
        for (name, uuid) in entry.deps
            dep_entry = get(deps, uuid, nothing)
            if dep_entry === nothing
                # stdlibs may be depended on without an entry of their own
                stdlib_uuid_for_name(name) == uuid && continue
                pkgerror(
                    "Manifest entry $(entry.name)=$entry_uuid depends on $name=$uuid, but no matching entry exists in $(repr(manifest_path))"
                )
            end
            if dep_entry.name != name
                pkgerror(
                    "Manifest entry $(entry.name)=$entry_uuid depends on $name=$uuid, but that UUID belongs to $(dep_entry.name) in $(repr(manifest_path))"
                )
            end
        end
    end

    return Manifest(julia_version, manifest_format, project_hash, deps, registries, other)
end

function convert_v1_format_manifest(old_raw_manifest::Dict)
    new_raw_manifest = Dict{String, Any}()
    new_raw_manifest["deps"] = old_raw_manifest
    new_raw_manifest["manifest_format"] = "1.0.0" # must be a string here to match raw dict
    # don't set julia_version as it is unknown in old manifests
    return new_raw_manifest
end

function read_manifest(f_or_io::Union{String, IO})
    raw = try
        if f_or_io isa IO
            TOML.parse(read(f_or_io, String))
        else
            isfile(f_or_io) ? TOML.parsefile(f_or_io) : return Manifest()
        end
    catch e
        if e isa TOML.ParserError
            subject = f_or_io isa IO ? "streamed manifest" : "manifest at $(repr(f_or_io))"
            pkgerror("Could not parse $subject: ", sprint(showerror, e))
        end
        rethrow()
    end
    if Base.is_v1_format_manifest(raw)
        if isempty(raw) # treat an empty Manifest file as v2 format for convenience
            raw["manifest_format"] = "2.0.0"
        else
            raw = convert_v1_format_manifest(raw)
        end
    end
    return parse_manifest(raw, f_or_io)
end

####################
# Manifest writing #
####################

function registry_ref_toml(entry::RegistryRef)
    d = Dict{String, Any}()
    d["uuid"] = string(entry.uuid)
    entry.url === nothing || (d["url"] = entry.url)
    return d
end

function destructure_manifest(manifest::Manifest)::Dict
    function entry!(entry, key, value; default = nothing)
        return if value == default
            delete!(entry, key)
        else
            entry[key] = value
        end
    end

    # registries provenance requires format 2.1 (no mutation of the value —
    # the effective format is computed here)
    manifest_format = manifest.manifest_format
    if !isempty(manifest.registries) && manifest_format < v"2.1.0"
        manifest_format = v"2.1.0"
    end

    unique_name = Dict{String, Bool}()
    name_uuid = Dict{String, UUID}()
    for (uuid, entry) in manifest
        unique_name[entry.name] = !haskey(unique_name, entry.name)
        name_uuid[entry.name] = uuid
    end

    # maintain the format of the manifest when writing
    local raw
    if manifest_format.major == 1
        raw = Dict{String, Vector{Dict{String, Any}}}()
    elseif manifest_format.major == 2
        raw = Dict{String, Any}()
        if !isnothing(manifest.julia_version)
            raw["julia_version"] = manifest.julia_version
        end
        if !isnothing(manifest.project_hash)
            raw["project_hash"] = manifest.project_hash
        end
        raw["manifest_format"] = string(manifest_format.major, ".", manifest_format.minor)
        raw["deps"] = Dict{String, Vector{Dict{String, Any}}}()
        for (k, v) in manifest.raw
            raw[k] = v
        end
        if !isempty(manifest.registries)
            regs = Dict{String, Any}()
            for (id, entry) in manifest.registries
                regs[id] = registry_ref_toml(entry)
            end
            raw["registries"] = regs
        end
    else
        # unknown major format: best effort, same shape as v2
        raw = Dict{String, Any}()
        raw["manifest_format"] = string(manifest_format.major, ".", manifest_format.minor)
        raw["deps"] = Dict{String, Vector{Dict{String, Any}}}()
    end

    for (uuid, entry) in manifest
        tracking = entry.tracking
        if tracking isa RepoTracked && tracking.tree_hash === nothing
            pkgerror(
                "Cannot write manifest entry $(entry.name) [$uuid]: repository-tracked entries require git-tree-sha1"
            )
        end

        new_entry = deepcopy(entry.raw)
        new_entry["uuid"] = string(uuid)
        entry!(new_entry, "version", entry_version(entry))
        entry!(new_entry, "git-tree-sha1", entry_tree_hash(entry))
        entry!(new_entry, "pinned", entry.pinned; default = false)
        path = entry_path(entry)
        if path !== nothing
            path = normalize_path_for_toml(path)
        end
        entry!(new_entry, "path", path)
        entry!(new_entry, "entryfile", entry.entryfile)
        repo_source = entry_repo_url(entry)
        if repo_source !== nothing && !isurl(repo_source)
            repo_source = normalize_path_for_toml(repo_source)
        end
        entry!(new_entry, "repo-url", repo_source)
        entry!(new_entry, "repo-rev", entry_repo_rev(entry))
        entry!(new_entry, "repo-subdir", entry_repo_subdir(entry))
        syntax_ver = entry.julia_syntax_version
        if syntax_ver === nothing
            delete!(new_entry, "syntax")
        else
            new_entry["syntax"] = Dict("julia_version" => string(syntax_ver))
        end

        registries = entry_registries(entry)
        if !isempty(registries)
            if length(registries) == 1
                # For backwards compatibility, write a single registry as a string
                entry!(new_entry, "registries", registries[1])
            else
                entry!(new_entry, "registries", registries)
            end
        else
            delete!(new_entry, "registries")
            delete!(new_entry, "registry") # Remove old field if present
        end

        for (deptype, depname) in [(entry.deps, "deps"), (entry.weakdeps, "weakdeps")]
            if isempty(deptype)
                delete!(new_entry, depname)
            else
                # the short name-array form is only unambiguous when the name is
                # unique in the manifest AND maps to the recorded dep uuid
                if all(dep -> get(unique_name, first(dep), false) && name_uuid[first(dep)] == last(dep), deptype)
                    new_entry[depname] = sort(collect(keys(deptype)))
                else
                    depdict = Dict{String, String}()
                    for (name, dep_uuid) in deptype
                        depdict[name] = string(dep_uuid)
                    end
                    new_entry[depname] = depdict
                end
            end
        end

        if isempty(entry.exts)
            delete!(new_entry, "extensions")
        else
            new_entry["extensions"] = entry.exts
        end

        if isempty(entry.apps)
            delete!(new_entry, "apps")
        else
            appdict = Dict{String, Any}()
            for (appname, appinfo) in entry.apps
                julia_command = @something appinfo.julia_command joinpath(Sys.BINDIR, "julia" * (Sys.iswindows() ? ".exe" : ""))
                app_dict = Dict{String, Any}("julia_command" => julia_command)
                if appinfo.submodule !== nothing
                    app_dict["submodule"] = appinfo.submodule
                end
                if !isempty(appinfo.julia_flags)
                    app_dict["julia_flags"] = appinfo.julia_flags
                end
                appdict[appname] = app_dict
            end
            new_entry["apps"] = appdict
        end

        if manifest_format.major == 1
            push!(get!(raw, entry.name, Dict{String, Any}[]), new_entry)
        else
            push!(get!(raw["deps"], entry.name, Dict{String, Any}[]), new_entry)
        end
    end
    return raw
end

function write_manifest(io::IO, raw_manifest::Dict)
    print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
    TOML.print(io, raw_manifest, sorted = true) do x
        (typeof(x) in [String, Nothing, UUID, SHA1, VersionNumber]) && return string(x)
        error("Internal error while writing manifest: unsupported value type $(typeof(x))")
    end
    return nothing
end
write_manifest(io::IO, manifest::Manifest) = write_manifest(io, destructure_manifest(manifest))

render_manifest(manifest::Manifest) = sprint(write_manifest, manifest)

function write_manifest(manifest::Manifest, manifest_file::AbstractString)
    if manifest.manifest_format.major == 1
        @warn """Manifest $(repr(manifest_file)) uses an old format.
        The next VibePkg operation that writes it will upgrade it to format v2.1.""" maxlog = 1 _id = Symbol(manifest_file)
    end
    str = render_manifest(manifest)
    mkpath(dirname(manifest_file))
    return atomic_write(manifest_file, str)
end

############
# METADATA #
############

function check_manifest_julia_version_compat(manifest::Manifest, manifest_file::String; julia_version_strict::Bool = false)
    isempty(manifest.deps) && return
    if manifest.manifest_format < v"2"
        msg = """Manifest $(repr(manifest_file)) uses an old format with no Julia version entry. Dependencies may have
        been resolved with a different Julia version. Run VibePkg.resolve() to refresh the manifest."""
        if julia_version_strict
            pkgerror(msg)
        else
            @warn msg maxlog = 1 _file = manifest_file _line = 0 _module = nothing
            return
        end
    end
    v = manifest.julia_version
    if v === nothing
        msg = """Manifest $(repr(manifest_file)) is missing a Julia version entry. Dependencies may have
        been resolved with a different Julia version. Run VibePkg.resolve() to refresh the manifest."""
        if julia_version_strict
            pkgerror(msg)
        else
            @warn msg maxlog = 1 _file = manifest_file _line = 0 _module = nothing
            return
        end
    end
    return if Base.thisminor(v) != Base.thisminor(VERSION)
        msg = """Manifest $(repr(manifest_file)) was resolved with Julia $(manifest.julia_version), but the running version is Julia $VERSION.
        Run VibePkg.resolve() to refresh it for this Julia version."""
        if julia_version_strict
            pkgerror(msg)
        else
            @warn msg maxlog = 1 _file = manifest_file _line = 0 _module = nothing
        end
    end
end

end # module
