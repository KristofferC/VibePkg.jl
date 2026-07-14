# Execution: carry out planned environments.
#
# No decisions here — Planning computed the target environment; this layer
# makes the world match it: install missing package trees, correct manifest
# entries against the installed Project.tomls (registries can disagree with
# a package's actual metadata), and write the environment diff-aware.

module Execution

using Base: UUID, SHA1

using ..Errors: pkgerror
using ..Utils: can_fancyprint
using ..Timing: @timeit, TIMER
using ..MiniProgressBars
using ..EnvFiles
using ..EnvFiles: ManifestEntry, PathTracked, RepoTracked, RegistryTracked,
    entry_tree_hash, entry_path, entry_version, with_entry, with_manifest
using ..Depots: DepotStack, find_installed
using ..Configs: Config
using ..Registries
using ..Registries: RegistryInstance
using ..Fetch
using ..ArtifactOps: collect_artifact_installs, ensure_artifact_installed!
using ..Environments
using ..Environments: Environment, projectfile_path
using TOML: TOML

export apply!, instantiate!, ensure_sources_installed!, sandbox_manifest,
    sandbox_preferences, write_sandbox_preferences

"Registry repo URLs for a package (used for GitHub tarball synthesis)."
function repo_urls_for(registries::Vector{RegistryInstance}, uuid::UUID)
    urls = String[]
    for reg in registries
        pkg = get(reg, uuid, nothing)
        pkg === nothing && continue
        info = Registries.registry_info(reg, pkg)
        # tarballs of subdir packages can't be verified against the subdir
        # tree hash — those go through the pkg server or (later) git
        if info.repo !== nothing && info.subdir === nothing
            push!(urls, info.repo)
        end
    end
    return unique!(urls)
end

"Absolute source directory of a manifest entry, or nothing (e.g. stdlib)."
function entry_source_path(manifest_file::String, entry::ManifestEntry, depots::DepotStack)
    path = entry_path(entry)
    if path !== nothing
        return isabspath(path) ? path : normpath(joinpath(dirname(manifest_file), path))
    end
    hash = entry_tree_hash(entry)
    hash === nothing && return nothing
    return first(find_installed(depots, entry.name, entry.uuid, hash))
end

# Shared scaffolding for the parallel download loops: semaphore-bounded
# @async workers (task-level IO concurrency; installs are pidlocked) and,
# when several items download on a terminal, one aggregate N/M bar — per-item
# bars would interleave — showing the in-flight names. Worker log records
# (e.g. hash-mismatch warnings) are routed above the bar.
function parallel_foreach_progress(
        f, work::Vector, names::Vector{String};
        io::IO, header::String, concurrency::Int,
    )
    sem = Base.Semaphore(concurrency)
    aggregate = can_fancyprint(io) && length(work) > 1
    bar = MiniProgressBar(; header, color = Base.info_color(), mode = :int, always_reprint = true)
    bar.max = length(work)
    inner_io = aggregate ? devnull : io
    inflight = String[]
    set_below!() = bar.below = isempty(inflight) ? String[] : [join(inflight, ", ")]
    logger = Base.CoreLogging.current_logger()
    aggregate && (logger = ProgressLogger(logger, io, bar))
    aggregate && start_progress(io, bar)
    return try
        Base.CoreLogging.with_logger(logger) do
            @sync for (i, item) in enumerate(work)
                @async Base.acquire(sem) do
                    @lock io begin
                        push!(inflight, names[i])
                        set_below!()
                        aggregate && show_progress(io, bar)
                    end
                    try
                        f(item, inner_io)
                    finally
                        @lock io begin
                            j = findfirst(==(names[i]), inflight)
                            j === nothing || deleteat!(inflight, j)
                            bar.current += 1
                            set_below!()
                            aggregate && show_progress(io, bar)
                        end
                    end
                end
            end
        end
    catch err
        # surface the first real failure instead of a CompositeException
        while err isa CompositeException || err isa TaskFailedException
            err = err isa CompositeException ? first(err.exceptions) : err.task.exception
        end
        rethrow(err)
    finally
        aggregate && end_progress(io, bar)
    end
end

"""
    ensure_sources_installed!(env, registries, config; io) -> Vector{NamedTuple}

Make every manifest entry's source tree present on disk. Returns the newly
installed packages as `(uuid, name, path)`.
"""
@timeit TIMER "install packages" function ensure_sources_installed!(
        env::Environment, registries::Vector{RegistryInstance}, config::Config;
        io::IO = config.io,
    )
    depots = config.depots
    new_installs = NamedTuple{(:uuid, :name, :path), Tuple{UUID, String, String}}[]
    # collect the download work; path entries are only checked
    work = NamedTuple{
        (:uuid, :name, :hash, :urls, :version),
        Tuple{UUID, String, SHA1, Vector{String}, Union{Nothing, VersionNumber}},
    }[]
    for (uuid, entry) in env.manifest
        tracking = entry.tracking
        if tracking isa PathTracked
            path = entry_source_path(env.manifest_file, entry, depots)
            isdir(path) || pkgerror(
                "expected package `$(entry.name) [$(string(uuid)[1:8])]` to exist at path `$path`"
            )
        elseif tracking isa RepoTracked
            hash = tracking.tree_hash
            hash === nothing && pkgerror("manifest entry for `$(entry.name)` tracks a repository without a tree hash")
            _, installed = find_installed(depots, entry.name, uuid, hash)
            installed || push!(work, (; uuid, name = entry.name, hash, urls = String[tracking.url], version = entry_version(entry)))
        elseif tracking isa RegistryTracked
            hash = tracking.tree_hash
            hash === nothing && continue           # stdlib or hash-less entry
            _, installed = find_installed(depots, entry.name, uuid, hash)
            installed || push!(work, (; uuid, name = entry.name, hash, urls = repo_urls_for(registries, uuid), version = entry_version(entry)))
        end
    end
    parallel_foreach_progress(
        work, [w.name for w in work];
        io, header = "Downloading packages", concurrency = config.concurrency,
    ) do item, inner_io
        path, new = Fetch.ensure_package_installed!(depots, item.name, item.uuid, item.hash, item.urls; io = inner_io, server = config.server)
        new && push!(new_installs, (; item.uuid, item.name, path))
    end
    return new_installs
end

"""
    sandbox_manifest(env, depots, roots) -> Manifest

Slice the environment's manifest to the `roots` and their recursive strong
dependencies, absolutizing path entries so the slice works from a sandbox
directory (shared by the build and test sandboxes).
"""
sandbox_manifest(env::Environment, depots::DepotStack, root::UUID) =
    sandbox_manifest(env, depots, [root])
function sandbox_visit!(keep, manifest, uuid)
    uuid in keep && return
    push!(keep, uuid)
    entry = get(manifest, uuid, nothing)
    entry === nothing && return
    foreach(u -> sandbox_visit!(keep, manifest, u), values(entry.deps))
    return
end
function sandbox_manifest(env::Environment, depots::DepotStack, roots::Vector{UUID})
    keep = Set{UUID}()
    foreach(u -> sandbox_visit!(keep, env.manifest, u), roots)
    entries = Dict{UUID, ManifestEntry}()
    for (uuid, entry) in env.manifest
        uuid in keep || continue
        path = entry_path(entry)
        if path !== nothing && !isabspath(path)
            abs = entry_source_path(env.manifest_file, entry, depots)::String
            entry = with_entry(entry; tracking = PathTracked(abs, entry.tracking.version))
        end
        entries[uuid] = entry
    end
    return with_manifest(EnvFiles.Manifest(); deps = entries, julia_version = VERSION)
end

"""
    sandbox_preferences(env, primary) -> Dict{String, Any}

The flattened preference cascade a sandbox must reproduce: everything
`Base.get_preferences` sees with `primary` (a project file or directory,
e.g. `test/` or `deps/Project.toml`) prepended to the load path — its
`[preferences]` table and `(Julia)LocalPreferences.toml`, then the parent
environment's, then the rest of the load path (default environments),
earlier entries winning and `__clear__` markers resolved. The parent
environment is spliced in explicitly because `env` need not be the active
project of this process (Pkg gets it via `@` in the load path).
"""
function sandbox_preferences(env::Environment, primary::String)
    old_load_path = copy(Base.LOAD_PATH)
    return try
        copy!(Base.LOAD_PATH, [primary; env.project_file; old_load_path])
        Base.get_preferences()
    finally
        copy!(Base.LOAD_PATH, old_load_path)
    end
end

# The sandbox subprocess runs with the load path cut down to `@` and the
# sandbox directory, so the flattened preferences are materialized as the
# sandbox's `JuliaLocalPreferences.toml` — the highest-priority preferences
# name, shadowing any plain `LocalPreferences.toml`.
function write_sandbox_preferences(sandbox_dir::String, prefs::Dict{String, Any})
    isempty(prefs) && return
    open(joinpath(sandbox_dir, first(Base.preferences_names)), "w") do io
        TOML.print(io, prefs)
    end
    return
end

"""
    ensure_artifacts!(env, config; io) -> Vector{String}

Install the artifacts selected by every package in the environment
(including the project itself) for the host platform.
"""
@timeit TIMER "install artifacts" function ensure_artifacts!(env::Environment, config::Config; io::IO = config.io)
    depots = config.depots
    # gather selections serially (cheap TOML reads), install concurrently,
    # deduplicated by tree hash (many packages share artifacts)
    jobs = Tuple{String, Dict}[]
    seen = Set{String}()
    function gather(pkg_root, pkg_uuid)
        for (name, meta) in collect_artifact_installs(depots, pkg_root; pkg_uuid)
            meta["git-tree-sha1"] in seen && continue
            push!(seen, meta["git-tree-sha1"])
            push!(jobs, (name, meta))
        end
        return
    end
    gather(dirname(env.project_file), env.project.uuid)
    for (uuid, entry) in env.manifest
        source = entry_source_path(env.manifest_file, entry, depots)
        (source === nothing || !isdir(source)) && continue
        gather(source, uuid)
    end
    isempty(jobs) && return String[]

    new_names = String[]
    parallel_foreach_progress(
        jobs, first.(jobs);
        io, header = "Downloading artifacts", concurrency = config.concurrency,
    ) do (name, meta), inner_io
        _, new = ensure_artifact_installed!(depots, name, meta; io = inner_io, server = config.server)
        new && push!(new_names, name)
    end
    return new_names
end

"""
    fixups_from_projectfile(env, depots) -> Manifest

Correct manifest entries against the installed packages' actual
Project.tomls: registries and resolution cannot know a package's weakdeps/
extensions, so they are read from the source of truth after installation.
"""
function fixups_from_projectfile(env::Environment, depots::DepotStack)
    entries = Dict{UUID, ManifestEntry}()
    for (uuid, entry) in env.manifest
        source = entry_source_path(env.manifest_file, entry, depots)
        new_entry = entry
        if source !== nothing && isdir(source)
            project_file = projectfile_path(source; strict = true)
            if project_file !== nothing
                project = try
                    read_project(project_file)
                catch
                    nothing
                end
                if project !== nothing
                    new_entry = with_entry(
                        entry;
                        weakdeps = merge(project.weakdeps, project.deps_weak),
                        exts = project.exts,
                        entryfile = project.entryfile,
                        julia_syntax_version = project.julia_syntax_version,
                    )
                end
            end
        end
        entries[uuid] = new_entry
    end
    return with_manifest(env.manifest; deps = entries)
end

"""
    apply!(old_env, planned_env, registries, config; io)
        -> (env, installed, wrote)

Execute a planned environment: install missing sources, apply project-file
fixups, write the environment (diff-aware). Returns the final environment
value, the list of new installs, and whether anything was written.
"""
function apply!(
        old_env::Environment, planned_env::Environment,
        registries::Vector{RegistryInstance}, config::Config;
        io::IO = config.io,
    )
    installed = ensure_sources_installed!(planned_env, registries, config; io)
    ensure_artifacts!(planned_env, config; io)
    manifest = fixups_from_projectfile(planned_env, config.depots)
    env = Environment(planned_env.project_file, planned_env.manifest_file, planned_env.project, manifest, planned_env.workspace)
    wrote = write_environment(old_env, env)
    return (; env, installed, wrote)
end

"""
    manifest_matches_project(env) -> Bool

Whether the manifest can be used as-is: it was resolved from the current
project file and with the same julia minor version (the
`instantiate(update_on_mismatch = true)` predicate).
"""
function manifest_matches_project(env::Environment)
    Environments.is_manifest_current(env) === false && return false
    v = env.manifest.julia_version
    (!isempty(env.manifest.deps) && (v === nothing || Base.thisminor(v) != Base.thisminor(VERSION))) && return false
    return true
end

"""
    instantiate!(env, registries, config; julia_version_strict, workspace, io) -> installed

Make everything the manifest records present on disk:
never rewrites the manifest. Errors when a direct dependency is missing
from the manifest; warns on a stale project hash. `workspace = true` also
requires every workspace member's direct dependencies to have entries.
"""
function instantiate!(
        env::Environment, registries::Vector{RegistryInstance}, config::Config;
        julia_version_strict::Bool = false, workspace::Bool = false, io::IO = config.io,
    )
    # all direct deps must have manifest entries
    direct = Dict{String, UUID}(env.project.deps)
    workspace && for (_, member) in env.workspace
        merge!(direct, member.deps)
    end
    for (name, uuid) in direct
        if !haskey(env.manifest, uuid)
            pkgerror(
                "`$name` is a direct dependency, but does not appear in the manifest. " *
                    "If you intend `$name` to be a direct dependency, run `Pkg.resolve()` to populate the manifest."
            )
        end
    end
    current = is_manifest_current(env)
    if current === false
        @warn """The project environment's manifest does not match its Project.toml.
        It is advised to run `Pkg.resolve()` (or `Pkg.update()`) to synchronize them.""" maxlog = 1
    end
    check_manifest_julia_version_compat(env.manifest, env.manifest_file; julia_version_strict)
    installed = ensure_sources_installed!(env, registries, config; io)
    ensure_artifacts!(env, config; io)
    return installed
end

end # module
