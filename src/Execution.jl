# Execution: carry out planned environments.
#
# No decisions here — Planning computed the target environment; this layer
# makes the world match it: install missing package trees, correct manifest
# entries against the installed Project.tomls (registries can disagree with
# a package's actual metadata), and write the environment diff-aware.

module Execution

using Base: UUID, SHA1

using ..Errors: pkgerror
using ..Utils: can_fancyprint, printpkgstyle
using ..Timing: @timeit, TIMER
using ..MiniProgressBars
using ..EnvFiles
using ..EnvFiles: ManifestEntry, PathTracked, RepoTracked, RegistryTracked,
    entry_tree_hash, entry_path, entry_version, with_entry, with_manifest
using ..Depots: DepotStack, find_installed, log_usage
using ..Configs: Config
using ..Registries
using ..Registries: RegistryInstance
using ..Fetch
using ..ArtifactOps: collect_artifact_installs, ensure_artifact_installed!, artifact_tree_path
using ..Environments
using ..Environments: Environment, projectfile_path
using TOML: TOML

export apply!, instantiate!, ensure_sources_installed!, sandbox_manifest,
    sandbox_preferences, write_sandbox_preferences

"""
    repo_urls_for(registries, uuid) -> (; archive, git)

Registry repo URLs for a package. `archive` feeds GitHub tarball synthesis —
subdir packages are excluded there because a repo-root tarball cannot be
verified against the subdir tree hash. `git` feeds the git fallback, where
subdir packages work: the registry's subdir tree hash is itself a git tree
object in the repository.
"""
function repo_urls_for(registries::Vector{RegistryInstance}, uuid::UUID)
    archive, git = String[], String[]
    for reg in registries
        pkg = get(reg, uuid, nothing)
        pkg === nothing && continue
        info = Registries.registry_info(reg, pkg)
        info.repo === nothing && continue
        push!(git, info.repo)
        info.subdir === nothing && push!(archive, info.repo)
    end
    return (archive = unique!(archive), git = unique!(git))
end

# Whether a package may provide extensions at `version`: only a registry
# recording no weakdeps for that concrete version can rule it out. Sources
# of such packages must be fetched even when not loadable — a package's
# true weakdeps/exts come from its Project.toml (fixups_from_projectfile),
# which needs the source on disk.
function pkg_may_have_extensions(registries::Vector{RegistryInstance}, uuid::UUID, version)
    version isa VersionNumber || return true
    attested_no_weakdeps = false
    for reg in registries
        pkg = get(reg, uuid, nothing)
        pkg === nothing && continue
        info = Registries.registry_info(reg, pkg)
        for (vr, weak) in info.weak_deps
            version in vr && !isempty(weak) && return true
        end
        # only a registry that actually knows this exact version can
        # affirmatively rule weakdeps out for it
        haskey(info.version_info, version) && (attested_no_weakdeps = true)
    end
    # no registry covers this package at this exact version — be
    # conservative and assume it may provide extensions
    return !attested_no_weakdeps
end

"UUIDs loadable from the active project: its direct deps and their recursive strong deps."
function loadable_uuids(env::Environment)
    keep = Set{UUID}()
    foreach(u -> sandbox_visit!(keep, env.manifest, u), values(env.project.deps))
    return keep
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
    # every item is enqueued up front, so without this flag workers would
    # keep starting downloads long after the first failure doomed the batch
    failed = Ref(false)
    return try
        Base.CoreLogging.with_logger(logger) do
            @sync for (i, item) in enumerate(work)
                @async Base.acquire(sem) do
                    if failed[]
                        @lock io begin
                            bar.current += 1
                            set_below!()
                            aggregate && show_progress(io, bar)
                        end
                        return
                    end
                    @lock io begin
                        push!(inflight, names[i])
                        set_below!()
                        aggregate && show_progress(io, bar)
                    end
                    try
                        f(item, inner_io)
                    catch
                        failed[] = true
                        rethrow()
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
    ensure_sources_installed!(env, registries, config; loadable, io) -> Vector{NamedTuple}

Make every manifest entry's source tree present on disk. Returns the newly
installed packages as `(uuid, name, path)`. With a `loadable` set, only
those registry-tracked entries (plus possible extension providers) are
fetched; path/repo-tracked entries are always materialized.
"""
@timeit TIMER "install packages" function ensure_sources_installed!(
        env::Environment, registries::Vector{RegistryInstance}, config::Config;
        loadable::Union{Nothing, Set{UUID}} = nothing,
        io::IO = config.io,
    )
    depots = config.depots
    new_installs = NamedTuple{(:uuid, :name, :path), Tuple{UUID, String, String}}[]
    # collect the download work; path entries are only checked
    work = NamedTuple{
        (:uuid, :name, :hash, :archive_urls, :git_urls, :version),
        Tuple{UUID, String, SHA1, Vector{String}, Vector{String}, Union{Nothing, VersionNumber}},
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
            # tarballs of a subdir package's repo can't verify against the
            # subdir tree hash; the git fallback handles those
            archive_urls = tracking.subdir === nothing ? String[tracking.url] : String[]
            installed || push!(work, (; uuid, name = entry.name, hash, archive_urls, git_urls = String[tracking.url], version = entry_version(entry)))
        elseif tracking isa RegistryTracked
            hash = tracking.tree_hash
            hash === nothing && continue           # stdlib or hash-less entry
            if loadable !== nothing && !(uuid in loadable) &&
                    !pkg_may_have_extensions(registries, uuid, entry_version(entry))
                continue
            end
            _, installed = find_installed(depots, entry.name, uuid, hash)
            urls = repo_urls_for(registries, uuid)
            installed || push!(work, (; uuid, name = entry.name, hash, archive_urls = urls.archive, git_urls = urls.git, version = entry_version(entry)))
        end
    end
    if config.offline && !isempty(work)
        # offline mode must never reach for the network (Pkg.jl#4580 family);
        # sources are not skippable like artifacts — the environment cannot
        # load without them, so this is an error
        names = join(sort!(String[w.name for w in work]), ", ")
        pkgerror(
            "cannot download missing package sources in offline mode: $names. " *
                "Unset `JULIA_PKG_OFFLINE` (or `Pkg.offline(false)`) to allow downloads."
        )
    end
    parallel_foreach_progress(
        work, [w.name for w in work];
        io, header = "Downloading packages", concurrency = config.concurrency,
    ) do item, inner_io
        path, new = Fetch.ensure_package_installed!(depots, item.name, item.uuid, item.hash, item.git_urls; archive_urls = item.archive_urls, io = inner_io, server = config.server)
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
    ensure_artifacts!(env, config; only, io) -> Vector{String}

Install the artifacts selected by every package in the environment
(including the project itself) for the host platform. With an `only` set,
manifest packages outside it are skipped.
"""
@timeit TIMER "install artifacts" function ensure_artifacts!(
        env::Environment, config::Config;
        only::Union{Nothing, Set{UUID}} = nothing, io::IO = config.io,
    )
    depots = config.depots
    # gather selections serially (cheap TOML reads), install concurrently,
    # deduplicated by tree hash (many packages share artifacts)
    jobs = Tuple{String, Dict}[]
    seen = Set{String}()
    usage = String[]
    function gather(pkg_root, pkg_uuid)
        for (name, meta) in collect_artifact_installs(depots, pkg_root; pkg_uuid, usage_out = usage)
            meta["git-tree-sha1"] in seen && continue
            push!(seen, meta["git-tree-sha1"])
            push!(jobs, (name, meta))
        end
        return
    end
    gather(dirname(env.project_file), env.project.uuid)
    for (uuid, entry) in env.manifest
        only === nothing || uuid in only || continue
        source = entry_source_path(env.manifest_file, entry, depots)
        (source === nothing || !isdir(source)) && continue
        gather(source, uuid)
    end
    # one batched write covers every package's Artifacts.toml — GC liveness
    # for installed artifacts too, so this happens before the early return
    log_usage(depots, usage, "artifact_usage.toml")
    isempty(jobs) && return String[]
    if config.offline
        # offline mode must not attempt artifact downloads (Pkg.jl#4580);
        # unlike package sources a missing artifact is not fatal here, so
        # they are skipped with a note
        missing_names = String[
            name for (name, meta) in jobs
                if !last(artifact_tree_path(depots, SHA1(meta["git-tree-sha1"]::String)))
        ]
        isempty(missing_names) || printpkgstyle(
            io, :Offline,
            "skipping download of missing artifacts: " * join(sort!(missing_names), ", "),
            color = Base.info_color(),
        )
        return String[]
    end

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
    apply!(old_env, planned_env, registries, config;
           skip_writing_project, download_loadable_only, io)
        -> (env, installed, wrote)

Execute a planned environment: install missing sources, apply project-file
fixups, write the environment (diff-aware). Returns the final environment
value, the list of new installs, and whether anything was written.
`skip_writing_project` leaves Project.toml untouched;
`download_loadable_only` fetches only the active project's loadable closure
(plus path/repo-tracked entries and possible extension providers).
"""
function apply!(
        old_env::Environment, planned_env::Environment,
        registries::Vector{RegistryInstance}, config::Config;
        io::IO = config.io,
        skip_writing_project::Bool = false,
        download_loadable_only::Bool = false,
    )
    # selective instantiate (Pkg.jl#4699): the whole workspace resolves, but
    # only the active project's loadable closure is fetched
    loadable = download_loadable_only ? loadable_uuids(planned_env) : nothing
    installed = ensure_sources_installed!(planned_env, registries, config; io, loadable)
    ensure_artifacts!(planned_env, config; io, only = loadable)
    manifest = fixups_from_projectfile(planned_env, config.depots)
    env = Environment(planned_env.project_file, planned_env.manifest_file, planned_env.project, manifest, planned_env.workspace)
    wrote = write_environment(old_env, env; skip_writing_project)
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

Make the active project's loadable dependency closure present on disk:
never rewrites the manifest. Errors when a direct dependency is missing
from the manifest; warns on a stale project hash. `workspace = true` widens
installation to the whole manifest and also requires every workspace member's
direct dependencies to have entries.
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
    loadable = workspace ? nothing : loadable_uuids(env)
    installed = ensure_sources_installed!(env, registries, config; io, loadable)
    ensure_artifacts!(env, config; io, only = loadable)
    return installed
end

end # module
