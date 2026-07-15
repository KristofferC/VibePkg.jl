# Environment snapshots.
#
# An `Environment` is an immutable snapshot of a project/manifest pair.
# Operations compute a NEW Environment and hand both to `write_environment`,
# which is diff-aware: only files whose value changed are written. There is
# no EnvCache-style "original copy" bookkeeping — an immutable snapshot is
# its own original.
#
# `[sources]` consistency is achieved by construction: at write time the
# project's sources section is re-derived from the manifest for every direct
# dependency (Pkg asserted consistency instead and crashed on mismatch).

module Environments

using Base: UUID, SHA1
using SHA: sha1

using ..Errors: pkgerror
using ..Timing: @timeit, TIMER
using ..EnvFiles
using ..EnvFiles: SourceSpec, entry_path, entry_repo_url, entry_repo_rev,
    entry_repo_subdir, with_project,
    projectfile_path, manifestfile_path
using ..Depots: DepotStack, log_usage
using ..Versions: VersionSpec

export Environment, load_environment, write_environment, find_project_file,
    projectfile_path, manifestfile_path, resolve_hash, is_manifest_current,
    get_compat, source_location

struct Environment
    project_file::String
    manifest_file::String
    project::Project
    manifest::Manifest
    # other workspace members as project_file => Project (empty when the
    # environment is standalone or on julia < 1.13); ops resolve over the
    # union of the active project and these
    workspace::Vector{Pair{String, Project}}
end
Environment(project_file::String, manifest_file::String, project::Project, manifest::Manifest) =
    Environment(project_file, manifest_file, project, manifest, Pair{String, Project}[])

#############
# Discovery #
#############

# try to call realpath on as much of the path as possible
function safe_realpath(path)
    if ispath(path)
        try
            return realpath(path)
        catch
            return path
        end
    end
    a, b = splitdir(path)
    isempty(b) && return path
    return joinpath(safe_realpath(a), b)
end

"""
    find_project_file(env = nothing) -> String

Resolve what project file an operation targets: `nothing` = the active
project, `"@name"` = a shared environment, otherwise a path (directory or
toml file).
"""
function find_project_file(env::Union{Nothing, String} = nothing)
    project_file = nothing
    if env isa Nothing
        project_file = Base.active_project()
        project_file === nothing && pkgerror("No active project was found in the current load path")
    elseif startswith(env, '@')
        project_file = Base.load_path_expand(env)
        project_file === nothing && pkgerror(
            "Package environment $(repr(env)) does not exist; expected Project.toml or JuliaProject.toml in a matching shared environment"
        )
    elseif env isa String
        if isdir(env)
            # activate semantics: a directory with a project file targets that
            # project; a nonempty directory without one is refused
            existing = projectfile_path(env; strict = true)
            if existing !== nothing
                project_file = existing
            else
                isempty(readdir(env)) || pkgerror(
                    "Environment directory $(repr(abspath(env))) is non-empty but contains neither Project.toml nor JuliaProject.toml"
                )
                project_file = joinpath(env, Base.project_names[end])
            end
        else
            project_file = endswith(env, ".toml") ? abspath(env) :
                abspath(env, Base.project_names[end])
        end
    end
    if isfile(project_file) && !contains(basename(project_file), "Project")
        pkgerror("Active project path $(repr(project_file)) is not Project.toml or JuliaProject.toml; select a project file or directory")
    end
    # canonicalize the parent directory but keep a symlinked project file
    # itself: resolving it would move the environment's identity to the link
    # target and place the manifest beside the wrong directory
    if islink(project_file)
        dir, base = splitdir(abspath(project_file))
        return joinpath(safe_realpath(dir), base)
    end
    return safe_realpath(project_file)
end

###########
# Loading #
###########

"""
    load_environment(env = nothing; depots) -> Environment

Load the environment `env` targets (see [`find_project_file`](@ref)).
Logs manifest usage (the GC liveness contract).
"""
function load_environment(env::Union{Nothing, String} = nothing; depots::DepotStack)
    project_file = find_project_file(env)
    return load_environment_from(project_file; depots)
end

# Workspace discovery (julia ≥ 1.13, matching Base code loading): walk up
# through `Base.base_project` to the root, then collect every member the
# root lists. Members share the root's manifest.
function find_workspace_root(project_file::String)
    root = project_file
    while true
        next = Base.base_project(root)
        next === nothing && break
        next == root && break
        root = next
    end
    return root
end

function workspace_members(root_file::String, root_project::Project)
    members = Pair{String, Project}[root_file => root_project]
    seen = Set{String}([safe_realpath(root_file)])
    collect_workspace_members!(members, seen, root_file, root_project)
    return members
end

# Members may themselves declare a [workspace]; the whole nested tree merges
# into the root's single manifest, so collection recurses (cycle-safe).
function collect_workspace_members!(
        members::Vector{Pair{String, Project}}, seen::Set{String},
        file::String, project::Project,
    )
    for rel in get(project.workspace, "projects", String[])
        pf = projectfile_path(joinpath(dirname(file), rel); strict = true)
        if pf === nothing
            member_path = abspath(joinpath(dirname(file), rel))
            @warn "Workspace member $(repr(member_path)) listed by $(repr(file)) contains neither Project.toml nor JuliaProject.toml" maxlog = 1
            continue
        end
        rp = safe_realpath(pf)
        rp in seen && continue
        push!(seen, rp)
        member = read_project(pf)
        push!(members, rp => member)
        collect_workspace_members!(members, seen, rp, member)
    end
    return members
end

@timeit TIMER "load environment" function load_environment_from(project_file::String; depots::DepotStack)
    project = read_project(project_file)
    dir = dirname(project_file)
    workspace = Pair{String, Project}[]
    manifest_file = if project.manifest_path !== nothing
        path = project.manifest_path
        abspath(isabspath(path) ? path : joinpath(dir, path))
    else
        root_file = find_workspace_root(project_file)
        if root_file != project_file || !isempty(project.workspace)
            root_project = root_file == project_file ? project : read_project(root_file)
            members = workspace_members(root_file, root_project)
            workspace = [m for m in members if !samefile_or_equal(m.first, project_file)]
            root_project.manifest_path !== nothing ?
                abspath(joinpath(dirname(root_file), root_project.manifest_path)) :
                manifestfile_path(dirname(root_file))
        else
            manifestfile_path(dir)
        end
    end
    manifest = read_manifest(manifest_file)
    log_usage(depots, manifest_file, "manifest_usage.toml")
    return Environment(project_file, manifest_file, project, manifest, workspace)
end

samefile_or_equal(a::String, b::String) =
    a == b || (ispath(a) && ispath(b) && samefile(a, b))

#####################
# Path rebasement   #
#####################

# Manifest `path` entries are manifest-relative; project `[sources]` paths
# are project-relative. Rebase between the two (identity when the files
# share a directory, which is every non-workspace environment).
function rebase_path(from_file::String, to_file::String, path::String)
    isabspath(path) && return path
    abs = normpath(joinpath(dirname(from_file), path))
    return relpath(abs, dirname(to_file))
end

manifest_path_to_project_path(env::Environment, path::String) =
    rebase_path(env.manifest_file, env.project_file, path)
project_path_to_manifest_path(env::Environment, path::String) =
    rebase_path(env.project_file, env.manifest_file, path)

"""
    source_location(env, name) -> Union{Nothing, SourceSpec}

The `[sources]` entry for direct dep `name`, with a `path` rebased to be
manifest-relative (the form the rest of the machinery uses).
"""
function source_location(env::Environment, name::String)
    source = get(env.project.sources, name, nothing)
    source === nothing && return nothing
    if source.path !== nothing
        return SourceSpec(project_path_to_manifest_path(env, source.path), nothing, source.rev, source.subdir)
    end
    return source
end

##################
# Resolve hash   #
##################

"""
    resolve_hash(env) -> SHA1

Hash of everything that affects a resolve (direct deps, weakdeps, compat) —
stored as the manifest's `project_hash` and used for staleness detection.
Must produce the same value as Pkg's `workspace_resolve_hash` for the same
environment.
"""
function resolve_hash(env::Environment)
    project = env.project
    deps = Dict{String, UUID}(project.deps)
    weakdeps = merge(Dict{String, UUID}(project.weakdeps), project.deps_weak)
    for (_, proj) in env.workspace
        merge!(deps, proj.deps)
        merge!(weakdeps, proj.weakdeps, proj.deps_weak)
    end
    alldeps = merge(deps, weakdeps)
    compats = Dict{String, VersionSpec}()
    for (name, uuid) in alldeps
        compats[name] = get_compat(env, name)
    end
    iob = IOBuffer()
    for (name, uuid) in sort!(collect(deps); by = first)
        println(iob, name, "=", uuid)
    end
    println(iob)
    for (name, uuid) in sort!(collect(weakdeps); by = first)
        println(iob, name, "=", uuid)
    end
    println(iob)
    for (name, compat) in sort!(collect(compats); by = first)
        println(iob, name, "=", compat)
    end
    return SHA1(bytes2hex(sha1(String(take!(iob)))))
end

"Compat spec for `name`, intersected across all workspace members."
function get_compat(env::Environment, name::String)
    compat = get(env.project.compat, name, nothing)
    spec = compat === nothing ? VersionSpec() : compat.val
    for (_, proj) in env.workspace
        c = get(proj.compat, name, nothing)
        c === nothing || (spec = intersect(spec, c.val))
    end
    return spec
end

"`nothing` if the manifest has no recorded hash; otherwise staleness result."
function is_manifest_current(env::Environment)
    recorded = env.manifest.project_hash
    recorded === nothing && return nothing
    recorded == resolve_hash(env) || return false
    # `project_hash` only covers the active/workspace projects, so a change to
    # a path-tracked (deved) package's own Project.toml — e.g. a newly declared
    # dependency — does not move it. Check each such package's declared deps are
    # still recorded in the manifest, or the staleness goes undetected (#4103).
    for (_, entry) in env.manifest.deps
        path = entry_path(entry)
        path === nothing && continue
        dir = isabspath(path) ? path : normpath(joinpath(dirname(env.manifest_file), path))
        project_file = projectfile_path(dir; strict = true)
        project_file === nothing && continue
        project = read_project(project_file)
        # the manifest records exactly the package's declared weak set
        # (fixups_from_projectfile), so the complete maps must match
        declared_weak = merge(project.weakdeps, project.deps_weak)
        declared_weak == entry.weakdeps || return false
        # every declared strong dep must be recorded ...
        for (name, uuid) in project.deps
            get(entry.deps, name, nothing) == uuid || return false
        end
        # ... and every recorded dep must still be declared. An entry's `deps`
        # may legitimately include the weak deps too (they enter the fixed
        # requirements at resolve time), so check against the union.
        declared_all = merge(project.deps, declared_weak)
        for (name, uuid) in entry.deps
            get(declared_all, name, nothing) == uuid || return false
        end
    end
    return true
end

###########
# Writing #
###########

"""
    sync_sources(env, manifest) -> Project

Re-derive the project's `[sources]` section from `manifest`: every direct
dep that is path- or repo-tracked gets an entry; everything else keeps
none. This is how `add url=`/`develop` record entries and how returning a
package to registry tracking drops them.
"""
function sync_sources(env::Environment, project::Project, manifest::Manifest)
    sources = Dict{String, SourceSpec}(project.sources)
    # workspace members (and the project itself) are path-tracked in the
    # shared manifest by virtue of membership, not via `[sources]`
    member_uuids = Set{UUID}()
    project.uuid === nothing || push!(member_uuids, project.uuid)
    for (_, member) in env.workspace
        member.uuid === nothing || push!(member_uuids, member.uuid)
    end
    for (name, uuid) in project.deps
        uuid in member_uuids && continue
        entry = get(manifest, uuid, nothing)
        entry === nothing && continue
        path = entry_path(entry)
        url = entry_repo_url(entry)
        if path !== nothing
            project_rel = rebase_path(env.manifest_file, env.project_file, path)
            sources[name] = SourceSpec(project_rel, nothing, nothing, nothing)
        elseif url !== nothing
            sources[name] = SourceSpec(nothing, url, entry_repo_rev(entry), entry_repo_subdir(entry))
        else
            # registry-tracked again: the entry has served its purpose
            delete!(sources, name)
        end
    end
    return with_project(project; sources)
end

"""
    write_environment(old, new; skip_writing_project, skip_readonly_check) -> Bool

Write `new`'s files where they differ from `old` (value comparison; no-op
changes touch nothing on disk). Returns whether anything was written.
"""
@timeit TIMER "write environment" function write_environment(
        old::Environment, new::Environment;
        skip_writing_project::Bool = false,
        skip_readonly_check::Bool = false,
    )
    project = sync_sources(new, new.project, new.manifest)

    # Readonly is a property of the environment being modified. Checking the
    # target value would let an older undo snapshot with `readonly = false`
    # disable the guard while rewriting the current readonly project.
    if old.project.readonly && !skip_readonly_check
        pkgerror("Cannot modify read-only environment: project $(repr(new.project_file)) sets readonly = true")
    end

    wrote = false
    if project != old.project && !skip_writing_project
        write_project(project, new.project_file)
        wrote = true
    end
    if new.manifest != old.manifest
        write_manifest(new.manifest, new.manifest_file)
        wrote = true
    end
    return wrote
end

end # module
