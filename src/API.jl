# The public façade: Pkg-compatible entry points.
#
# Each operation is the same short story: assemble a Config (all ENV reads,
# once) + registry snapshot → load the environment snapshot → plan (pure) →
# execute → display. Session state lives here and only here.
#
# TODO(parity): Context kwargs (Pkg's leading-Context argument shapes)
# are not implemented.

module API

using Base: UUID
import UUIDs
using Dates: Dates

using ..Errors: PkgError, pkgerror
using ..Utils: stderr_f, stdout_f, precompile_io, precompile_detach_kwargs
using ..Timing: @operation, @timeit, TIMER
import ..Depots
import ..Stdlibs
using ..Depots: DepotStack, depot_stack, depots, depots1
using ..Configs
using ..Configs: Config
import ..Registries
import ..Git
import ..GCOps
import ..BuildOps
import ..TestOps
using ..Registries: reachable_registries, RegistryInstance
using ..Environments
using ..Environments: Environment
using ..Planning
using ..Planning: PackageRequest, AddTarget
using ..Execution
using ..Display: print_env_diff, print_status, print_compat, printpkgstyle, pathrepr
import ..Display
import ..EnvFiles
import ..Resolve
using ..Versions: VersionSpec

export add, develop, rm, up, update, pin, free, resolve, instantiate, status,
    compat, activate, generate, why, offline, respect_sysimage_versions,
    precompile, readonly

##################
# Session state  #
##################
# The only mutable state of the whole package manager outside caches and the
# filesystem.

const OFFLINE_MODE = Ref(false)
const UPDATED_REGISTRY_THIS_SESSION = Ref(false)
const AUTO_PRECOMPILE_ENABLED = Ref(true)
const AUTO_GC_ENABLED = Ref(true)
# resolution skips versions differing from sysimage-baked packages; folded
# into every op's Config
const RESPECT_SYSIMAGE_VERSIONS = Ref(true)

# `pkg>` dispatch runs under this scope; `add` prefers already-loaded package
# versions in the REPL but not in API calls (Pkg parity)
const IN_REPL_MODE = Base.ScopedValues.ScopedValue(false)
in_repl_mode() = IN_REPL_MODE[]

# the previously active project file, for `activate(prev = true)` / `activate -`
const PREV_ENV_PATH = Ref{String}("")

# Undo/redo: per-project stacks of environment snapshots. Environments are
# immutable values, so a "snapshot" is just a reference — no copying.
mutable struct UndoState
    idx::Int
    entries::Vector{Environment}
end
const UNDO_STACKS = Dict{String, UndoState}()
const MAX_UNDO = 50

function snapshot_undo!(env::Environment)
    state = get!(() -> UndoState(0, Environment[]), UNDO_STACKS, env.project_file)
    if state.idx >= 1
        prev = state.entries[state.idx]
        prev.project == env.project && prev.manifest == env.manifest && return
    end
    resize!(state.entries, state.idx)          # entering a new timeline drops the redo tail
    push!(state.entries, env)
    if length(state.entries) > MAX_UNDO
        popfirst!(state.entries)
    end
    state.idx = length(state.entries)
    return
end

record_undo!(old_env::Environment, new_env::Environment) =
    (snapshot_undo!(old_env); snapshot_undo!(new_env))

function undo_redo_target(env::Environment, direction::Int)
    state = get(UNDO_STACKS, env.project_file, nothing)
    state === nothing && pkgerror("No undo information is available for project $(repr(env.project_file))")
    target_idx = state.idx + direction
    1 <= target_idx <= length(state.entries) ||
        pkgerror(
            direction < 0 ?
                "No more undo information is available for project $(repr(env.project_file))" :
                "No more redo information is available for project $(repr(env.project_file))"
        )
    return state, target_idx, state.entries[target_idx]
end

function undo_redo_step!(env::Environment, direction::Int)
    state, target_idx, target = undo_redo_target(env, direction)
    state.idx = target_idx
    return target
end

"`offline(b = true)`: no registry updates, resolve against installed versions only."
function offline(b::Bool = true)
    OFFLINE_MODE[] = b
    return nothing
end

"""
    respect_sysimage_versions(b::Bool = true)

Enable or disable respecting package versions baked into the sysimage. When
enabled, resolution keeps such packages at their sysimage versions and rejects
repository adds or develops of them.
"""
function respect_sysimage_versions(b::Bool = true)
    RESPECT_SYSIMAGE_VERSIONS[] = b
    return nothing
end

is_offline() = OFFLINE_MODE[] || Base.get_bool_env("JULIA_PKG_OFFLINE", false) == true

should_autoprecompile() =
    AUTO_PRECOMPILE_ENABLED[] && Base.JLOptions().use_compiled_modules == 1 &&
    Base.get_bool_env("JULIA_PKG_PRECOMPILE_AUTO", true) != false

"`auto_gc(on)`: toggle the periodic automatic `gc()` after `up`/`pin`/`free`/`rm`."
auto_gc(on::Bool) = (AUTO_GC_ENABLED[] = on; nothing)

should_auto_gc() =
    AUTO_GC_ENABLED[] && Base.get_bool_env("JULIA_PKG_GC_AUTO", true) != false

# One consistent view of the world per operation: the ambient settings
# (Config, ENV read once) plus the registry snapshot.
struct OpContext
    config::Config
    registries::Vector{RegistryInstance}
end

# `update_registry`: :none, :auto (once per session, and per registry at
# most once per day via Pkg's persisted update log; skipped offline), or
# :force (`up` semantics — no cooldown; still skipped offline).
function op_context(; io::IO = stderr_f(), update_registry::Symbol = :none)
    config = Config(;
        io, offline = OFFLINE_MODE[],
        respect_sysimage_versions = RESPECT_SYSIMAGE_VERSIONS[],
    )
    depots, server = config.depots, config.server
    registries = reachable_registries(depots; read_from_tarball = server !== nothing)
    # fresh-depot bootstrap: every operation installs the default registries
    # when none are reachable
    if isempty(registries) && !config.offline
        # with no server add_default_registries! bootstraps over git instead
        Registries.add_default_registries!(depots; io)
        registries = reachable_registries(depots; read_from_tarball = server !== nothing)
    end
    if update_registry !== :none && !config.offline &&
            (update_registry === :force || !UPDATED_REGISTRY_THIS_SESSION[])
        updated = Registries.update_registries!(
            depots; io,
            update_cooldown = update_registry === :force ? Dates.Second(1) : Dates.Day(1),
        )
        UPDATED_REGISTRY_THIS_SESSION[] = true
        if !isempty(updated)
            registries = reachable_registries(depots; read_from_tarball = server !== nothing)
        end
    end
    return OpContext(config, registries)
end

# Best-effort installation of custom registries recorded by Manifest.toml.
# A manifest can remain usable when one provenance URL is stale (for example,
# because the package source is already installed), so match Pkg's behavior:
# warn on installation failure and let the operation itself decide whether the
# available registry set is sufficient.
function ensure_manifest_registries!(ctx::OpContext, env::Environment; io::IO = ctx.config.io)
    isempty(env.manifest.registries) && return nothing
    installed = Set(Registries.registry_uuid(reg) for reg in ctx.registries)
    missing = sort!(
        [
            ref for ref in values(env.manifest.registries) if
                !(ref.uuid in installed) && ref.url !== nothing
        ];
        by = ref -> ref.id,
    )
    isempty(missing) && return nothing

    try
        for ref in missing
            Registries.add_registry_from_source!(ctx.config.depots, ref.url::String; io)
            refreshed = reachable_registries(
                ctx.config.depots; read_from_tarball = ctx.config.server !== nothing,
            )
            any(reg -> Registries.registry_uuid(reg) == ref.uuid, refreshed) || pkgerror(
                "registry source `$(ref.url)` did not provide the registry `$(ref.id)` ",
                "with uuid `$(ref.uuid)` recorded in the manifest",
            )
            append!(empty!(ctx.registries), refreshed)
            push!(installed, ref.uuid)
        end
    catch err
        err isa InterruptException && rethrow()
        @warn "Failed to install some registries from manifest" exception = (err, catch_backtrace())
    end
    return nothing
end

requests(pkgs::AbstractVector{<:AbstractString}) = [PackageRequest(String(pkg)) for pkg in pkgs]

# The repo-source fetch capability handed to planning (offline plans get
# none and error on a missing repo tree instead of touching the network).
source_fetcher(config::Config) =
    config.offline ? nothing : Git.source_fetcher(config.depots; io = config.io)

# `pkgs` narrows the precompile to those packages and their dependency
# closure (Pkg parity: `add` passes the added names, everything else the
# whole environment)
function _auto_precompile(ctx::OpContext, pkgs::Vector{String} = String[])
    should_autoprecompile() || return
    try
        @timeit TIMER "auto precompile" Base.Precompilation.precompilepkgs(
            pkgs; io = precompile_io(ctx.config.io), precompile_detach_kwargs()...
        )
    catch err
        err isa InterruptException && rethrow()
        @warn "auto-precompilation failed" exception = err
    end
    return
end

# After state-changing ops (`up`/`pin`/`free`/`rm`): collect garbage when
# the first depot has not been swept for a week — mtime of the gc stamp,
# where a missing stamp (mtime 0) means never collected.
const AUTO_GC_PERIOD_SECS = 7 * 24 * 60 * 60
function _auto_gc(ctx::OpContext)
    should_auto_gc() || return
    time() - mtime(GCOps.gc_stamp(depots1(ctx.config.depots))) > AUTO_GC_PERIOD_SECS || return
    io = ctx.config.io
    printpkgstyle(io, :Info, "This depot has not been cleaned recently; running VibePkg.gc()...", color = Base.info_color())
    try
        GCOps.gc(ctx.config.depots; io)
    catch err
        err isa InterruptException && rethrow()
        @error "GC failed" exception = err
    end
    return
end

function run_plan(
        ctx::OpContext, env::Environment, planned::Environment;
        autoprecompile::Bool = true, precompile_pkgs::Vector{String} = String[],
        build_uuids::Vector{UUID} = UUID[],
        skip_writing_project::Bool = false,
        download_loadable_only::Bool = false,
    )
    io = ctx.config.io
    result = Execution.apply!(env, planned, ctx.registries, ctx.config; io, skip_writing_project, download_loadable_only)
    print_env_diff(io, env, result.env; registries = ctx.registries, depots = ctx.config.depots)
    record_undo!(env, result.env)
    # newly installed packages with a deps/build.jl get built; repo packages
    # (materialized on disk before resolve, so never counted as newly
    # installed) are built too when the caller passes their uuids
    to_build = union(UUID[i.uuid for i in result.installed], build_uuids)
    if !isempty(to_build)
        BuildOps.build!(result.env, ctx.config.depots, to_build; io)
    end
    autoprecompile && _auto_precompile(ctx, precompile_pkgs)
    return nothing
end

################
# Operations   #
################

# String arguments are names, never REPL micro-syntax (Pkg parity: the
# name-check rejects `Example@0.5` and friends with the pinned diagnostics)
add(pkg::AbstractString; kwargs...) = add([String(pkg)]; kwargs...)
add(pkgs::AbstractVector{<:AbstractString}; kwargs...) = add([PackageSpec(; name) for name in pkgs]; kwargs...)

##########################
# PackageSpec arg shapes #
##########################

"""
    PackageSpec(; name, uuid, version, url, rev, path, subdir)
    PackageSpec(name)

The public package-descriptor record accepted by every operation. Unlike
Pkg's, it is an immutable *input* value: it never flows past normalization.
"""
struct PackageSpec
    name::Union{Nothing, String}
    uuid::Union{Nothing, UUID}
    version::Union{Nothing, VersionNumber, VersionSpec, String}
    url::Union{Nothing, String}
    rev::Union{Nothing, String}
    path::Union{Nothing, String}
    subdir::Union{Nothing, String}
end
function PackageSpec(;
        name = nothing, uuid = nothing, version = nothing,
        url = nothing, rev = nothing, path = nothing, subdir = nothing,
        repo = nothing,
    )
    repo === nothing ||
        pkgerror("PackageSpec(repo=...) is unsupported; specify url, rev, and subdir instead")
    uuid isa AbstractString && (uuid = UUID(uuid))
    version isa VersionNumber || version isa VersionSpec || version isa AbstractString || version === nothing ||
        pkgerror("Invalid version $(repr(version)); expected a VersionNumber, version string, VersionSpec, or nothing")
    return PackageSpec(
        name === nothing ? nothing : String(name), uuid,
        version isa AbstractString ? String(version) : version,
        url, rev, path, subdir,
    )
end
PackageSpec(name::AbstractString) = PackageSpec(; name)
PackageSpec(name::AbstractString, uuid::UUID) = PackageSpec(; name, uuid)
PackageSpec(name::AbstractString, version::Union{VersionNumber, VersionSpec, AbstractString}) = PackageSpec(; name, version)

Base.:(==)(a::PackageSpec, b::PackageSpec) =
    all(isequal(getfield(a, i), getfield(b, i)) for i in 1:nfields(a))
Base.hash(s::PackageSpec, h::UInt) =
    foldl((h, i) -> hash(getfield(s, i), h), 1:nfields(s); init = hash(PackageSpec, h))

to_request(s::PackageSpec) = PackageRequest(s.name, s.uuid, s.version)

# Package-name validation with Pkg's pinned diagnostics: the
# base message plus composable hints for `.jl` suffixes and URL/path-looking
# arguments.
function check_package_name(x::AbstractString, mode::Union{Nothing, String, Symbol} = nothing)
    if !Base.isidentifier(x)
        message = sprint() do iostr
            print(iostr, "Invalid package name $(repr(x))")
            if endswith(lowercase(x), ".jl")
                print(iostr, ". Perhaps you meant `$(chop(x; tail = 3))`")
            end
            if mode !== nothing && any(occursin.(['\\', '/'], x)) # maybe a url or a path
                print(
                    iostr, "\nThe argument appears to be a URL or path, perhaps you meant ",
                    "`VibePkg.$mode(url=\"...\")` or `VibePkg.$mode(path=\"...\")`."
                )
            end
        end
        pkgerror(message)
    end
    return
end
check_package_name(::Nothing, ::Any) = nothing

err_rep(s::PackageSpec) =
    "`" * (
    s.name !== nothing && s.uuid !== nothing ? "$(s.name) [$(string(s.uuid)[1:8])]" :
        s.name !== nothing ? s.name :
        s.uuid !== nothing ? string(s.uuid)[1:8] : string(something(s.url, s.path, "unknown"))
) * "`"

# The entry validation Pkg runs at the top of `add`/`develop` before any
# planning; every message here is pinned.
function validate_specs(specs::Vector{PackageSpec}, mode::String)
    isempty(specs) && pkgerror("$mode requires at least one package")
    for s in specs
        check_package_name(s.name, mode)
        # if julia is passed as a package the solver gets tricked
        s.name == "julia" && pkgerror("Package name \"julia\" is reserved for the Julia runtime")
        if s.name === nothing && s.uuid === nothing && s.url === nothing && s.path === nothing
            pkgerror("Package specification must include a name, UUID, URL, or filesystem path")
        end
        if s.name !== nothing && count(x -> x.name == s.name, specs) > 1
            matches = [x for x in specs if x.name == s.name]
            pkgerror("Duplicate package name $(repr(s.name)) in specifications $(err_rep(matches[1])) and $(err_rep(matches[2]))")
        end
        if s.uuid !== nothing && count(x -> x.uuid == s.uuid, specs) > 1
            matches = [x for x in specs if x.uuid == s.uuid]
            pkgerror("Duplicate package UUID $(s.uuid) in specifications $(err_rep(matches[1])) and $(err_rep(matches[2]))")
        end
        if mode == "develop"
            s.rev === nothing || pkgerror("develop does not accept rev; use add to track a repository revision")
            s.version === nothing || pkgerror(
                "develop does not accept version $(repr(s.version)) for package $(err_rep(s))"
            )
        elseif (s.url !== nothing || s.path !== nothing || s.rev !== nothing) && s.version !== nothing
            pkgerror(
                "Cannot specify version $(repr(s.version)) for repository-tracked package $(err_rep(s))"
            )
        end
    end
    return
end

# Split specs into registry requests, repo-like (url/path) ones, and
# name#rev ones (registry url lookup + repo tracking), validating the
# combinations `handle_package_input!` rejects.
function split_specs(specs::Vector{PackageSpec})
    reqs = PackageRequest[]
    repo_like = PackageSpec[]
    name_rev = PackageSpec[]
    for s in specs
        s.url !== nothing && s.path !== nothing &&
            pkgerror("Cannot specify both path and URL")
        if s.url !== nothing || s.path !== nothing
            push!(repo_like, s)
        elseif s.rev !== nothing
            s.name === nothing && s.uuid === nothing && pkgerror("rev $(repr(s.rev)) requires a package name, UUID, URL, or path")
            push!(name_rev, s)
        else
            s.name === nothing && s.uuid === nothing && pkgerror("Package specification must include a name or UUID")
            push!(reqs, to_request(s))
        end
    end
    return reqs, repo_like, name_rev
end

"The registry-declared repository url and optional subdirectory of a package."
function registry_repo_source(registries::Vector{RegistryInstance}, uuid::UUID)
    for reg in registries
        p = get(reg, uuid, nothing)
        p === nothing && continue
        info = Registries.registry_info(reg, p)
        info.repo !== nothing && return (url = info.repo, subdir = info.subdir)
    end
    return nothing
end

function registry_repo_url(registries::Vector{RegistryInstance}, uuid::UUID)
    source = registry_repo_source(registries, uuid)
    return source === nothing ? nothing : source.url
end

@operation function add(
        specs::Vector{PackageSpec};
        preserve::PreserveLevel = default_preserve(), target::Symbol = :deps,
        prefer_loaded_versions::Bool = in_repl_mode(), io::IO = stderr_f(),
    )
    validate_specs(specs, "add")
    target === :deps || return _add_to_target(specs, target; io)
    reqs, repo_like, name_rev = split_specs(specs)
    # input validation must not have side effects: bad paths error before
    # any registry update runs (Pkg checks paths before touching the world)
    for s in repo_like
        s.path === nothing && continue
        path = abspath(s.path)
        isdir(path) || pkgerror("Package path $(repr(path)) does not exist")
        if !ispath(joinpath(path, ".git")) &&
                (isfile(joinpath(path, "Project.toml")) || isfile(joinpath(path, "JuliaProject.toml")))
            pkgerror("Did not find a git repository at `$path`, perhaps you meant `VibePkg.develop`?")
        end
    end
    ctx = op_context(; io, update_registry = :auto)
    env = load_environment(; depots = ctx.config.depots)
    repos = EnvFiles.RepoPackage[
        Git.materialize_repo_package!(
                ctx.config.depots, something(s.url, s.path === nothing ? nothing : abspath(s.path));
                rev = s.rev, subdir = s.subdir, io
            ) for s in repo_like
    ]
    for s in name_rev
        # `add Name#rev`: both the repository url and its package subdir come
        # from the registry (an explicit PackageSpec subdir still wins).
        name, uuid = Planning.resolve_request(env, ctx.registries, to_request(s))
        source = registry_repo_source(ctx.registries, uuid)
        source === nothing && pkgerror("No repository URL is recorded for package $name [$uuid] in the configured registries")
        subdir = s.subdir === nothing ? source.subdir : s.subdir
        push!(repos, Git.materialize_repo_package!(ctx.config.depots, source.url; rev = s.rev, subdir, io))
    end
    # already-present fast path: when every requested package is already a
    # compatible registry-tracked manifest entry (and nothing is repo-tracked),
    # just promote it to [deps] and write it out — no resolve, install, or
    # precompile (Pkg's `can_skip_resolve_for_add`).
    if isempty(repos)
        promoted = Planning.plan_promote(
            env, ctx.registries, reqs;
            respect_sysimage_versions = ctx.config.respect_sysimage_versions,
        )
        if promoted !== nothing
            planned, names = promoted
            planned, compat_added = compat_on_add(planned, names)
            if planned.manifest.project_hash !== nothing
                # promoting a dep changed [deps]; keep the recorded hash current
                manifest = EnvFiles.with_manifest(planned.manifest; project_hash = resolve_hash(planned))
                planned = Environment(planned.project_file, planned.manifest_file, planned.project, manifest, planned.workspace)
            end
            write_environment(env, planned)
            print_env_diff(io, env, planned; registries = ctx.registries, depots = ctx.config.depots)
            record_undo!(env, planned)
            isempty(compat_added) ||
                printpkgstyle(io, :Compat, "entries added for $(join(compat_added, ", "))")
            return nothing
        end
    end
    printpkgstyle(io, :Resolving, "package versions...")
    preferred_versions = prefer_loaded_versions ?
        collect_preferred_loaded_versions(env) : Dict{UUID, VersionNumber}()
    targets = AddTarget[reqs; repos]
    planned = plan_add(env, ctx.registries, ctx.config, targets; preserve, preferred_versions, fetcher = source_fetcher(ctx.config))
    print_preferred_loaded_note(io, env, planned, preferred_versions)
    added_names = String[r.name for r in repos]
    for r in reqs
        name = r.name !== nothing ? r.name :
            (r.uuid !== nothing && haskey(planned.manifest, r.uuid)) ? planned.manifest[r.uuid].name : nothing
        name === nothing || push!(added_names, name)
    end
    planned, compat_added = compat_on_add(planned, added_names)
    run_plan(ctx, env, planned; precompile_pkgs = added_names, build_uuids = UUID[r.uuid for r in repos])
    isempty(compat_added) ||
        printpkgstyle(io, :Compat, "entries added for $(join(compat_added, ", "))")
    return nothing
end

# If the active project is a package (name + uuid), `add` records a compat
# entry lower-bounded at the resolved version for every added direct
# dependency that has none (Pkg parity).
function compat_on_add(planned::Environment, added::Vector{String})
    (planned.project.name === nothing || planned.project.uuid === nothing) &&
        return planned, String[]
    compat_added = String[]
    new_env = planned
    for name in added
        haskey(new_env.project.compat, name) && continue
        uuid = get(new_env.project.deps, name, nothing)
        uuid === nothing && continue
        entry = get(new_env.manifest, uuid, nothing)
        entry === nothing && continue
        v = EnvFiles.entry_version(entry)
        v isa VersionNumber || continue
        new_env = Planning.plan_compat_entry(new_env, name, string(Base.thispatch(v)))
        push!(compat_added, name)
    end
    if !isempty(compat_added)
        # compat entries feed the resolve hash; keep the recorded one current
        manifest = EnvFiles.with_manifest(new_env.manifest; project_hash = resolve_hash(new_env))
        new_env = Environment(new_env.project_file, new_env.manifest_file, new_env.project, manifest, new_env.workspace)
    end
    return new_env, compat_added
end

# The versions of packages already loaded in the session that resolution
# should prefer (`add(prefer_loaded_versions = true)`, the REPL default):
# anything loaded, not a stdlib, not already in the manifest.
function collect_preferred_loaded_versions(env::Environment)
    preferred = Dict{UUID, VersionNumber}()
    for (pkgid, mod) in Base.loaded_modules
        uuid = pkgid.uuid
        uuid isa UUID || continue
        Stdlibs.is_stdlib(uuid) && continue
        haskey(env.manifest.deps, uuid) && continue
        uuid == env.project.uuid && continue
        version = Base.pkgversion(mod)
        version isa VersionNumber || continue
        preferred[uuid] = version
    end
    return preferred
end

# The pinned `Resolve` note naming which loaded versions the resolver reused
# (direct deps by name, the rest as a count).
function print_preferred_loaded_note(io::IO, env::Environment, planned::Environment, preferred::Dict{UUID, VersionNumber})
    isempty(preferred) && return
    direct = Set{UUID}(values(planned.project.deps))
    direct_names = String[]
    indirect_count = 0
    for (uuid, entry) in planned.manifest.deps
        haskey(env.manifest.deps, uuid) && continue
        EnvFiles.entry_version(entry) == get(preferred, uuid, nothing) || continue
        if uuid in direct
            push!(direct_names, entry.name)
        else
            indirect_count += 1
        end
    end
    sort!(direct_names)
    isempty(direct_names) && indirect_count == 0 && return
    parts = String[]
    isempty(direct_names) || push!(parts, join(direct_names, ", "))
    if indirect_count > 0
        push!(parts, "$(indirect_count) $(indirect_count == 1 ? "dependency" : "dependencies")")
    end
    joined = length(parts) == 2 ? string(parts[1], " and ", parts[2]) : parts[1]
    msg = if length(direct_names) + indirect_count > 1
        "was able to add the versions of $(joined) that are already loaded"
    else
        "was able to add the version of $(joined) that is already loaded"
    end
    printpkgstyle(io, :Resolve, msg; color = Base.info_color())
    return
end

# `add(target = :weakdeps/:extras)` (`add --weak`/`--extra`): record the
# packages under `[weakdeps]`/`[extras]` — nothing is resolved or installed.
function _add_to_target(specs::Vector{PackageSpec}, target::Symbol; io::IO)
    target in (:weakdeps, :extras) || pkgerror("Unsupported target $(repr(target)); expected :deps, :weakdeps, or :extras")
    for s in specs
        (s.url === nothing && s.path === nothing && s.rev === nothing) ||
            pkgerror("Target $(repr(target)) supports only registered packages; $(err_rep(s)) specifies a repository or path")
    end
    ctx = op_context(; io, update_registry = :auto)
    env = load_environment(; depots = ctx.config.depots)
    new_field = Dict{String, UUID}(target === :weakdeps ? env.project.weakdeps : env.project.extras)
    names = String[]
    for s in specs
        name, uuid = Planning.resolve_request(env, ctx.registries, to_request(s))
        Planning.check_registered(env, ctx.registries, name, uuid)
        new_field[name] = uuid
        push!(names, name)
    end
    project = target === :weakdeps ?
        EnvFiles.with_project(env.project; weakdeps = new_field) :
        EnvFiles.with_project(env.project; extras = new_field)
    new_env = Environment(env.project_file, env.manifest_file, project, env.manifest, env.workspace)
    if new_env.manifest.project_hash !== nothing
        # weakdeps feed the resolve hash; keep the recorded one current
        manifest = EnvFiles.with_manifest(new_env.manifest; project_hash = resolve_hash(new_env))
        new_env = Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
    end
    write_environment(env, new_env)
    record_undo!(env, new_env)
    printpkgstyle(io, :Added, "$(join(names, ", ")) to [$(target)]")
    return nothing
end

@operation function develop(
        specs::Vector{PackageSpec};
        shared::Bool = true, preserve::PreserveLevel = default_preserve(), io::IO = stderr_f(),
    )
    validate_specs(specs, "develop")
    isempty(specs) && return nothing
    # effectful pre-phase (clones, name resolution) collects every track
    # path first, then ONE plan + apply covers all of them: a per-spec
    # mutation loop would leave earlier specs committed when a later one
    # fails
    needs_registry = any(s -> s.path === nothing && s.url === nothing, specs)
    ctx = op_context(; io, update_registry = needs_registry ? :auto : :none)
    env = load_environment(; depots = ctx.config.depots)
    paths = String[]
    for s in specs
        if s.path !== nothing
            # honor `subdir`: the tracked project lives below the given path
            # (`plan_develop` validates the joined path exists and has a
            # project file). Relative API/REPL paths are cwd-relative, while
            # `plan_develop` consumes paths relative to the active project;
            # translate between those two frames without making the recorded
            # source absolute (so moving the project with its package works).
            requested = s.subdir === nothing ? s.path : joinpath(s.path, s.subdir)
            track_path = isabspath(requested) ? requested :
                relpath(abspath(requested), dirname(env.project_file))
            push!(paths, track_path)
        elseif s.url !== nothing
            name = splitext(basename(rstrip(s.url, '/')))[1]
            clone_dir, track_path = dev_clone_target(ctx.config, name; shared)
            isdir(clone_dir) || Git.ensure_clone(io, clone_dir, s.url)
            s.subdir === nothing || (track_path = joinpath(track_path, s.subdir))
            push!(paths, track_path)
        elseif s.name !== nothing
            push!(paths, _develop_name_path(ctx, env, s.name; shared, io))
        else
            pkgerror("Package specification must include a name, UUID, URL, or filesystem path")
        end
    end
    # Pkg validates a package's load entry point at the public develop
    # boundary. Keep the lower-level planner usable with metadata-only
    # synthetic packages while rejecting real API/REPL develops that could
    # never be loaded.
    for path in paths
        dev_dir = isabspath(path) ? path : normpath(joinpath(dirname(env.project_file), path))
        project_file = EnvFiles.projectfile_path(dev_dir; strict = true)
        project_file === nothing && continue # plan_develop emits the structural error
        project = EnvFiles.read_project(project_file)
        project.name === nothing && continue # likewise for missing identity
        entry_point = something(project.entryfile, joinpath("src", "$(project.name).jl"))
        package_source = joinpath(dev_dir, entry_point)
        isfile(package_source) || pkgerror(
            "expected the file `$package_source` to exist for package `$(project.name)` at `$dev_dir`"
        )
    end
    printpkgstyle(io, :Resolving, "package versions...")
    planned = plan_develop(env, ctx.registries, ctx.config, paths; preserve, fetcher = source_fetcher(ctx.config))
    return run_plan(ctx, env, planned; autoprecompile = false)   # develop never auto-precompiles
end

# Where `develop` clones a registered/url package:
# `shared = true` → the dev dir (`Config.devdir`), tracked absolute;
# `shared = false` → the active project's `dev/` folder, tracked relative
# (`plan_develop` interprets relative paths against the project). Returns
# `(clone_dir, track_path)`.
function dev_clone_target(config::Config, name::String; shared::Bool)
    shared && return (joinpath(config.devdir, name), joinpath(config.devdir, name))
    project_dir = dirname(Environments.find_project_file())
    return (joinpath(project_dir, "dev", name), joinpath("dev", name))
end

rm(specs::Vector{PackageSpec}; kwargs...) = _rm_requests(to_request.(specs); kwargs...)
up(specs::Vector{PackageSpec}; kwargs...) = _up_requests(to_request.(specs); kwargs...)
pin(specs::Vector{PackageSpec}; kwargs...) = pin(to_request.(specs); kwargs...)
free(specs::Vector{PackageSpec}; kwargs...) = _free_requests(to_request.(specs); kwargs...)
test(specs::Vector{PackageSpec}; kwargs...) = test(spec_names(specs); kwargs...)
build(specs::Vector{PackageSpec}; kwargs...) = build(spec_names(specs); kwargs...)

# name-keyed operations (build/test/precompile) accept UUID-only specs by
# resolving the name from the active manifest — stringifying the UUID would
# never match a manifest entry
function spec_names(specs::Vector{PackageSpec})
    all(s -> s.name !== nothing, specs) && return String[s.name for s in specs]
    env = load_environment(; depots = depot_stack())
    return String[
        if s.name !== nothing
                s.name
        else
                s.uuid === nothing && pkgerror("Package specification must include a name or UUID")
                entry = get(env.manifest, s.uuid, nothing)
                entry === nothing && pkgerror("Package with UUID $(s.uuid) was not found in manifest $(repr(env.manifest_file))")
                entry.name
        end
            for s in specs
    ]
end

# the six shapes: String and Vector{String} exist above; PackageSpec,
# Vector{PackageSpec}, kwarg-form, and Vector{NamedTuple} are generated
for f in (:add, :develop, :rm, :up, :pin, :free, :test, :build)
    @eval begin
        $f(spec::PackageSpec; kwargs...) = $f([spec]; kwargs...)
        $f(nts::Vector{<:NamedTuple}; kwargs...) = $f([PackageSpec(; nt...) for nt in nts]; kwargs...)
        function $f(;
                name = nothing, uuid = nothing, version = nothing, url = nothing,
                rev = nothing, path = nothing, subdir = nothing, kwargs...,
            )
            return if all(isnothing, (name, uuid, version, url, rev, path, subdir))
                $f(PackageSpec[]; kwargs...)
            else
                $f([PackageSpec(; name, uuid, version, url, rev, path, subdir)]; kwargs...)
            end
        end
    end
end

develop(pkg::AbstractString; kwargs...) = develop([String(pkg)]; kwargs...)
develop(pkgs::AbstractVector{<:AbstractString}; kwargs...) = develop([PackageSpec(; name) for name in pkgs]; kwargs...)

"develop by name: clone the registry repo into the dev dir, return the track path"
function _develop_name_path(ctx::OpContext, env::Environment, pkg::String; shared::Bool, io::IO)
    name, uuid = Planning.resolve_request(env, ctx.registries, PackageRequest(pkg))
    # a manifest entry already tracking a repository knows the url (and
    # subdir) even when the package is unregistered; the registry is the
    # fallback
    entry = get(env.manifest, uuid, nothing)
    url = entry === nothing ? nothing : EnvFiles.entry_repo_url(entry)
    subdir = entry === nothing ? nothing : EnvFiles.entry_repo_subdir(entry)
    if url === nothing
        source = registry_repo_source(ctx.registries, uuid)
        if source !== nothing
            url = source.url
            subdir = source.subdir
        end
    end
    url === nothing && pkgerror("No repository URL is recorded for package $name [$uuid] in the configured registries")
    clone_dir, track_path = dev_clone_target(ctx.config, name; shared)
    if !isdir(clone_dir)
        Git.ensure_clone(io, clone_dir, url)
    end
    subdir === nothing || (track_path = joinpath(track_path, subdir))
    return track_path
end

rm(pkg::AbstractString; kwargs...) = rm([String(pkg)]; kwargs...)
rm(pkgs::AbstractVector{<:AbstractString}; kwargs...) = _rm_requests(requests(pkgs); kwargs...)

# `all_pkgs = true`: every direct dependency (project mode) or every manifest
# package (manifest mode), matching Pkg's `append_all_pkgs!` scopes
function all_requests(env::Environment, mode::Symbol)
    return if mode === :manifest
        [PackageRequest(entry.name, uuid, nothing) for (uuid, entry) in env.manifest]
    else
        [PackageRequest(name, uuid, nothing) for (name, uuid) in env.project.deps]
    end
end

@operation "rm" function _rm_requests(
        reqs::Vector{PackageRequest};
        mode::Union{Symbol, PackageMode} = :project, all_pkgs::Bool = false, io::IO = stderr_f(),
    )
    mode = Configs.mode_symbol(mode)
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    if all_pkgs
        isempty(reqs) || pkgerror("Cannot specify individual packages together with all_pkgs=true")
        reqs = all_requests(env, mode)
        isempty(reqs) && (println(io, "No changes"); return nothing)
    end
    planned = plan_rm(env, reqs; mode)
    # nothing dropped (all requests warned-and-ignored) — plan_rm only ever
    # removes deps, so set equality means the op was a no-op
    if planned.project.deps == env.project.deps && keys(planned.manifest.deps) == keys(env.manifest.deps)
        println(io, "No changes")
        return nothing
    end
    result = Execution.apply!(env, planned, ctx.registries, ctx.config; io)
    print_env_diff(io, env, result.env; registries = ctx.registries, depots = ctx.config.depots)
    record_undo!(env, result.env)
    _auto_gc(ctx)
    return nothing
end

up(pkg::AbstractString; kwargs...) = up([String(pkg)]; kwargs...)
up(pkgs::AbstractVector{<:AbstractString}; kwargs...) = _up_requests(requests(pkgs); kwargs...)
@operation "up" function _up_requests(
        reqs::Vector{PackageRequest};
        io::IO = stderr_f(), level::UpgradeLevel = UPLEVEL_MAJOR,
        preserve::Union{Nothing, PreserveLevel} = nothing,
        mode::Union{Symbol, PackageMode} = :project, workspace::Bool = false,
        update_registry::Union{Nothing, Symbol} = nothing,
        skip_writing_project::Bool = false,
        download_loadable_only::Bool = false,
    )
    mode = Configs.mode_symbol(mode)
    # fully-pinned environments short-circuit before any registry work.
    # `update_registry` policy: a caller may force one (e.g. `instantiate`
    # delegates with `:auto` so a session that already updated does not
    # re-fetch — Pkg.jl#3555); otherwise decide from the requests, so `up Foo`
    # on an unregistered path/repo-tracked package forces no fetch (Pkg.jl#3496).
    reg = update_registry
    let env = load_environment(; depots = depot_stack())
        # only the update-everything form may short-circuit: targeted requests
        # must reach plan_up so invalid names error instead of being ignored
        if isempty(reqs) && !isempty(env.manifest.deps) && all(kv -> kv.second.pinned, env.manifest.deps)
            printpkgstyle(io, :Update, "All dependencies are pinned - nothing to update.", color = Base.info_color())
            return nothing
        end
        reg === nothing && (reg = _up_needs_registry(env, reqs) ? :force : :none)
    end
    ctx = op_context(; io, update_registry = reg)
    env = load_environment(; depots = ctx.config.depots)
    repos = refresh_repo_packages(ctx, env, reqs; mode, workspace, io)
    printpkgstyle(io, :Resolving, "package versions...")
    planned = plan_up(env, ctx.registries, ctx.config, reqs; level, preserve, mode, workspace, repos, fetcher = source_fetcher(ctx.config))
    run_plan(ctx, env, planned; skip_writing_project, download_loadable_only)
    _auto_gc(ctx)
    return nothing
end
const update = up

# `up` forces a registry update, but only when it could matter: an empty
# request set (`up` everything) or a target that is registry-tracked — or
# unresolvable without a registry, and thus possibly registered. When every
# requested package resolves to a path/repo-tracked manifest entry the
# registry is irrelevant and must not be fetched (Pkg.jl#3496).
function _up_needs_registry(env::Environment, reqs::Vector{PackageRequest})
    isempty(reqs) && return true
    for r in reqs
        uuid = try
            Planning.resolve_request(env, RegistryInstance[], r)[2]
        catch err
            err isa PkgError || rethrow()
            return true
        end
        entry = get(env.manifest, uuid, nothing)
        (entry === nothing || EnvFiles.is_registry_tracked(entry)) && return true
    end
    return false
end

# Branch-tracked git packages update by pulling their tracked branch: `up`
# re-materializes the recorded repo/rev (fetch-first) so a moved branch
# lands its new tree. A full-SHA rev is immutable and skipped — a commit-id
# add stays effectively pinned — and pinned entries never move. Offline
# mode skips the fetch entirely.
function refresh_repo_packages(
        ctx::OpContext, env::Environment, reqs::Vector{PackageRequest};
        mode::Symbol, workspace::Bool, io::IO,
    )
    repos = EnvFiles.RepoPackage[]
    ctx.config.offline && return repos
    targets = Set{UUID}()
    if isempty(reqs)
        if mode === :manifest
            union!(targets, keys(env.manifest.deps))
        else
            union!(targets, values(env.project.deps))
            if workspace
                for (_, member) in env.workspace
                    union!(targets, values(member.deps))
                end
            end
        end
    else
        for r in reqs
            uuid = try
                Planning.resolve_request(env, ctx.registries, r)[2]
            catch err
                err isa PkgError || rethrow()
                continue    # plan_up owns the canonical unknown-package error
            end
            push!(targets, uuid)
        end
    end
    for uuid in sort!(collect(targets))
        entry = get(env.manifest, uuid, nothing)
        entry === nothing && continue
        entry.pinned && continue
        url = EnvFiles.entry_repo_url(entry)
        url === nothing && continue
        rev = EnvFiles.entry_repo_rev(entry)
        rev !== nothing && occursin(r"^[0-9a-f]{40}$"i, rev) && continue
        push!(
            repos, Git.materialize_repo_package!(
                ctx.config.depots, url;
                rev, subdir = EnvFiles.entry_repo_subdir(entry), refresh = true, io,
            )
        )
    end
    return repos
end

pin(pkg::AbstractString; kwargs...) = pin([String(pkg)]; kwargs...)
pin(pkgs::AbstractVector{<:AbstractString}; kwargs...) = pin(requests(pkgs); kwargs...)
@operation function pin(reqs::Vector{PackageRequest}; all_pkgs::Bool = false, workspace::Bool = false, io::IO = stderr_f())
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    if all_pkgs
        isempty(reqs) || pkgerror("Cannot specify individual packages together with all_pkgs=true")
        # Pkg parity: `all_pkgs` operates on the whole manifest, which spans
        # the workspace already (members share the root manifest)
        reqs = all_requests(env, :manifest)
        isempty(reqs) && (println(io, "No changes"); return nothing)
    end
    planned = plan_pin(env, ctx.registries, ctx.config, reqs; fetcher = source_fetcher(ctx.config))
    run_plan(ctx, env, planned)
    _auto_gc(ctx)
    return nothing
end

free(pkg::AbstractString; kwargs...) = free([String(pkg)]; kwargs...)
free(pkgs::AbstractVector{<:AbstractString}; kwargs...) = _free_requests(requests(pkgs); kwargs...)
@operation "free" function _free_requests(reqs::Vector{PackageRequest}; all_pkgs::Bool = false, workspace::Bool = false, io::IO = stderr_f())
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    if all_pkgs
        isempty(reqs) || pkgerror("Cannot specify individual packages together with all_pkgs=true")
        reqs = all_requests(env, :manifest)
        isempty(reqs) && (println(io, "No changes"); return nothing)
    end
    planned = plan_free(env, ctx.registries, ctx.config, reqs; err_if_free = !all_pkgs, fetcher = source_fetcher(ctx.config))
    run_plan(ctx, env, planned)
    _auto_gc(ctx)
    return nothing
end

"""
    resolve(; skip_writing_project = true, io)

Re-resolve the environment's manifest from its project. `Project.toml` is
authored input: by default it is never rewritten (Pkg.jl#4713); pass
`skip_writing_project = false` to also sync `[sources]` back into it.
"""
@operation function resolve(; skip_writing_project::Bool = true, io::IO = stderr_f())
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    printpkgstyle(io, :Resolving, "package versions...")
    planned = plan_resolve(env, ctx.registries, ctx.config; fetcher = source_fetcher(ctx.config))
    return run_plan(ctx, env, planned; autoprecompile = false, skip_writing_project)
end

"""
    instantiate(; manifest, verbose, workspace, julia_version_strict, update_on_mismatch, io)

Make the environment ready to use. With a
manifest, download everything it records; without one (or with
`manifest = false`) resolve the project from scratch via `up` — the whole
workspace resolves into the shared manifest, but unless `workspace = true`
only the active project's loadable dependencies are downloaded
(Pkg.jl#4699). `update_on_mismatch = true` falls back to `up` when the
manifest does not match the project or was resolved with a different julia
minor version. `verbose` sends build output of newly-installed packages to
`stdout`/`stderr` instead of their log files.
"""
@operation function instantiate(;
        manifest::Union{Nothing, Bool} = nothing, verbose::Bool = false,
        workspace::Bool = false, julia_version_strict::Bool = false,
        update_on_mismatch::Bool = false, io::IO = stderr_f(),
    )
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    ensure_manifest_registries!(ctx, env; io)
    # decision tree: no manifest (or `manifest = false`) ⇒
    # full `up()`; a mismatched manifest under `update_on_mismatch` too.
    # `instantiate` delegates to `up` with `update_registry = :auto` so it
    # respects the once-per-session / daily cooldown instead of forcing a
    # redundant registry re-download (Pkg.jl#3555).
    if manifest === false || (manifest === nothing && isempty(env.manifest.deps) && !isfile(env.manifest_file))
        return up(; io, update_registry = :auto, skip_writing_project = true, download_loadable_only = !workspace)
    end
    if update_on_mismatch && !Execution.manifest_matches_project(env)
        printpkgstyle(io, :Info, "The manifest does not match the project, updating...", color = Base.info_color())
        return up(; io, update_registry = :auto, skip_writing_project = true, download_loadable_only = !workspace)
    end
    installed = Execution.instantiate!(env, ctx.registries, ctx.config; julia_version_strict, workspace, io)
    isempty(installed) || BuildOps.build!(env, ctx.config.depots, [i.uuid for i in installed]; verbose, io)
    _auto_precompile(ctx)
    return nothing
end

"""
    compat()                     # show the [compat] table
    compat(pkg)                  # remove pkg's entry (prompts when interactive)
    compat(pkg, compat_str)      # set (nothing removes)
    compat(; current = true), compat(pkg; current = true)
    # fill missing entries from current versions

Pkg-compatible compat operation. Setting an entry writes it first and then
checks the environment against the new rules: a conflicting entry stays put
and prints a suggestion to `update` (Pkg semantics), it never downgrades.
"""
function compat(; current::Bool = false, io::IO = stdout_f())
    current && return set_current_compat(nothing; io)
    env = load_environment(; depots = depot_stack())
    print_compat(io, env)
    return nothing
end
compat(pkg::AbstractString; kwargs...) = compat(String(pkg); kwargs...)
compat(pkg::AbstractString, compat_str::Union{Nothing, AbstractString}; kwargs...) =
    compat(String(pkg), compat_str === nothing ? nothing : String(compat_str); kwargs...)
function compat(pkg::String; current::Bool = false, io::IO = stderr_f())
    current && return set_current_compat(pkg; io)
    return compat(pkg, nothing; io)
end
function compat(pkg::String, compat_str::Union{Nothing, String}; io::IO = stderr_f())
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    pkg = pkg == "Julia" ? "julia" : pkg
    compat_str === nothing || (compat_str = String(strip(compat_str, '"')))
    existing = Display.get_compat_str(env.project, pkg)
    # double check before deleting a compat entry (Pkg issue #3567)
    if isinteractive() && (compat_str === nothing || isempty(compat_str)) && existing !== nothing
        ans = Base.prompt(stdin, io, "No compat string was given. Delete existing compat entry `$pkg = $(repr(existing))`? [y]/n", default = "y")
        lowercase(something(ans, "n")) != "y" && return nothing
    end
    entry_env = Planning.plan_compat_entry(env, pkg, compat_str)
    write_environment(env, entry_env)
    record_undo!(env, entry_env)
    if compat_str === nothing || isempty(compat_str)
        printpkgstyle(io, :Compat, "entry removed:\n  $pkg = $(repr(existing))")
    else
        printpkgstyle(io, :Compat, "entry set:\n  $(pkg) = $(repr(compat_str))")
    end
    printpkgstyle(io, :Resolve, "checking for compliance with the new compat rules...")
    try
        planned = plan_resolve(entry_env, ctx.registries, ctx.config; fetcher = source_fetcher(ctx.config))
        run_plan(ctx, entry_env, planned; autoprecompile = false)
    catch e
        if e isa Resolve.ResolverError
            printpkgstyle(io, :Error, string(e.msg), color = Base.warn_color())
            printpkgstyle(io, :Suggestion, "Call `update` to attempt to meet the compatibility requirements.", color = Base.info_color())
            return nothing
        end
        rethrow()
    end
    return nothing
end

"fill in missing [compat] entries from the currently resolved versions"
function set_current_compat(target_pkg::Union{Nothing, String}; io::IO = stderr_f())
    env = load_environment(; depots = depot_stack())
    updated_deps = String[]
    deps_to_process = if target_pkg !== nothing
        haskey(env.project.deps, target_pkg) ||
            pkgerror("Package $(target_pkg) not found in project dependencies")
        [(target_pkg, env.project.deps[target_pkg])]
    else
        collect(env.project.deps)
    end
    new_env = env
    for (dep, uuid) in deps_to_process
        compat_str = Display.get_compat_str(new_env.project, dep)
        if target_pkg !== nothing || compat_str === nothing
            entry = get(new_env.manifest, uuid, nothing)
            entry === nothing && continue
            v = EnvFiles.entry_version(entry)
            v isa VersionNumber || continue
            new_env = Planning.plan_compat_entry(new_env, dep, string(Base.thispatch(v)))
            push!(updated_deps, dep)
        end
    end
    if target_pkg === nothing && Display.get_compat_str(new_env.project, "julia") === nothing
        new_env = Planning.plan_compat_entry(new_env, "julia", string(Base.thispatch(VERSION)))
        push!(updated_deps, "julia")
    end
    if isempty(updated_deps)
        if target_pkg !== nothing
            printpkgstyle(io, :Info, "$(target_pkg) already has a compat entry or is not in manifest. No changes made.", color = Base.info_color())
        else
            printpkgstyle(io, :Info, "no missing compat entries found. No changes made.", color = Base.info_color())
        end
    elseif length(updated_deps) == 1
        printpkgstyle(io, :Info, "new entry set for $(only(updated_deps)) based on its current version", color = Base.info_color())
    else
        printpkgstyle(io, :Info, "new entries set for $(join(updated_deps, ", ", " and ")) based on their current versions", color = Base.info_color())
    end
    if new_env !== env
        write_environment(env, new_env)
        record_undo!(env, new_env)
    end
    print_compat(io, new_env)
    return nothing
end

"""
    precompile(pkgs = String[]; strict = false, timing = false, workspace = false, io)

Instantiate, then precompile the environment (delegates to
`Base.Precompilation`, which owns precompilation on Julia 1.12+). With
`pkgs` only those packages (and their dependencies) precompile. Errors only
throw for explicitly requested `pkgs` (on Julia 1.12 also for any direct
dependency) unless `strict = true`, which makes every failure throw;
`timing = true` reports per-package compile time; `workspace = true`
instantiates and precompiles across all workspace members.
"""
precompile(pkg::AbstractString; kwargs...) = precompile([String(pkg)]; kwargs...)
precompile(pkgs::AbstractVector{<:AbstractString}; kwargs...) = precompile(String.(pkgs); kwargs...)
precompile(spec::PackageSpec; kwargs...) = precompile([spec]; kwargs...)
precompile(specs::Vector{PackageSpec}; kwargs...) = precompile(spec_names(specs); kwargs...)

# do-block form: auto-precompilation is deferred while `f` runs (batching
# several manifest-changing operations), then one precompile happens
function precompile(f::Function; kwargs...)
    old = AUTO_PRECOMPILE_ENABLED[]
    AUTO_PRECOMPILE_ENABLED[] = false
    try
        f()
    finally
        AUTO_PRECOMPILE_ENABLED[] = old
    end
    return precompile(; kwargs...)
end

@operation function precompile(
        pkgs::Vector{String} = String[];
        strict::Bool = false, timing::Bool = false, workspace::Bool = false,
        io::IO = stderr_f(),
    )
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    Execution.instantiate!(env, ctx.registries, ctx.config; workspace, io)
    @timeit TIMER "precompilepkgs" Base.Precompilation.precompilepkgs(
        pkgs; strict, timing, manifest = workspace, io = precompile_io(io),
        precompile_detach_kwargs()...
    )
    return nothing
end

# the environment as of git HEAD (for `status --diff`), or nothing
function git_head_env(env::Environment, repo_dir::String)
    return try
        Git.LibGit2.with(Git.LibGit2.GitRepo(repo_dir)) do repo
            git_path = Git.LibGit2.path(repo)
            project_path = relpath(env.project_file, git_path)
            manifest_path = relpath(env.manifest_file, git_path)
            project = EnvFiles.read_project(Git.git_file_stream(repo, "HEAD:$project_path", fakeit = true))
            manifest = EnvFiles.read_manifest(Git.git_file_stream(repo, "HEAD:$manifest_path", fakeit = true))
            Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
        end
    catch err
        err isa PkgError || rethrow()
        nothing
    end
end

# positional packages filter the listing (`status Example`)
status(pkg::AbstractString; kwargs...) = status([String(pkg)]; kwargs...)
status(pkgs::AbstractVector{<:AbstractString}; kwargs...) = status([PackageSpec(; name) for name in pkgs]; kwargs...)
status(spec::PackageSpec; kwargs...) = status([spec]; kwargs...)
status(reqs::Vector{PackageRequest}; kwargs...) =
    status([PackageSpec(; name = r.name, uuid = r.uuid) for r in reqs]; kwargs...)
@operation function status(specs::Vector{PackageSpec} = PackageSpec[]; io::IO = stdout_f(), mode::Union{Symbol, PackageMode} = :project, outdated::Bool = false, deprecated::Bool = false, workspace::Bool = false, compat::Bool = false, extensions::Bool = false, diff::Bool = false)
    mode = Configs.mode_symbol(mode)
    filter_uuids = UUID[s.uuid for s in specs if s.uuid !== nothing]
    filter_names = String[s.name for s in specs if s.name !== nothing]
    if compat
        unsupported = diff ? "diff" : outdated ? "outdated" : deprecated ? "deprecated" : extensions ? "extensions" : nothing
        unsupported === nothing || pkgerror(
            "Compat status does not support $(repr(unsupported)); supported options are package filters and current compatibility entries"
        )
        env = load_environment(; depots = depot_stack())
        print_compat(io, env, filter_names)
        return nothing
    end
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    diff_env = nothing
    if diff
        repo_dir = Git.discover_repo(dirname(env.project_file))
        if repo_dir === nothing
            @warn "diff option only available for environments in git repositories, ignoring."
        else
            diff_env = git_head_env(env, repo_dir)
            if diff_env === nothing
                @warn "could not read project from HEAD, displaying absolute status instead."
            end
        end
    end
    print_status(io, env; manifest_mode = mode === :manifest, outdated, deprecated, workspace, extensions, registries = ctx.registries, depots = ctx.config.depots, diff_env, filter_uuids, filter_names)
    return nothing
end

"""
    generate(path; io) -> Dict{String, UUID}

Create a new package skeleton: `Project.toml` (name from the path's
basename, fresh uuid, authors from git config, version 0.1.0) and
`src/<Name>.jl`.
"""
function generate(path::String; io::IO = stderr_f())
    path = normpath(expanduser(path))
    # `abspath(".")` retains a trailing separator, for which `basename`
    # is empty; `splitpath` still ends in the cwd's directory name.
    base = last(splitpath(abspath(path)))
    pkg_name = endswith(lowercase(base), ".jl") ? chop(base, tail = 3) : base
    Base.isidentifier(pkg_name) || pkgerror(
        "Cannot generate a package from path $(repr(path)): derived name $(repr(pkg_name)) is not a valid Julia identifier"
    )
    if ispath(path)
        isdir(path) && isempty(readdir(path)) || pkgerror(
            "Cannot generate a package at $(repr(abspath(path))): the path exists and is not an empty directory"
        )
    end
    printpkgstyle(io, :Generating, " project $pkg_name:")

    uuid = UUIDs.uuid4()
    authors = let
        name = readchomp_or(`git config --get user.name`, get(ENV, "GIT_AUTHOR_NAME", nothing))
        email = readchomp_or(`git config --get user.email`, get(ENV, "GIT_AUTHOR_EMAIL", nothing))
        name === nothing ? String[] :
            [email === nothing ? name : "$name <$email>"]
    end

    mkpath(joinpath(path, "src"))
    open(joinpath(path, "Project.toml"), "w") do f
        println(f, "name = ", repr(pkg_name))
        println(f, "uuid = ", repr(string(uuid)))
        isempty(authors) || println(f, "authors = ", "[", join(repr.(authors), ", "), "]")
        println(f, "version = \"0.1.0\"")
    end
    println(io, "    ", pathrepr(joinpath(path, "Project.toml")))
    open(joinpath(path, "src", "$pkg_name.jl"), "w") do f
        print(
            f, """
            module $pkg_name

            greet() = print("Hello World!")

            end # module $pkg_name
            """
        )
    end
    println(io, "    ", pathrepr(joinpath(path, "src", "$pkg_name.jl")))
    return Dict{String, Base.UUID}(pkg_name => uuid)
end

function readchomp_or(cmd::Cmd, fallback)
    return try
        out = readchomp(cmd)
        isempty(out) ? fallback : out
    catch
        fallback
    end
end

"""
    why(pkg; io)

Print the dependency paths from the project's direct dependencies to
`pkg` as a tree, explaining why it is in the manifest. Branches
terminating in `pkg` are marked with a colored `▶`; a package whose
sub-tree has already been printed is shown as `Name (*)` instead of
being expanded again.
"""
why(pkgs::AbstractVector{<:AbstractString}; kwargs...) =
    (foreach(pkg -> why(String(pkg); kwargs...), pkgs); nothing)
why(spec::PackageSpec; kwargs...) = why([spec]; kwargs...)
function why(specs::Vector{PackageSpec}; kwargs...)
    for s in specs
        if s.name !== nothing
            why(s.name; kwargs...)
        else
            # a UUID names the package exactly — resolving it to a name and
            # re-looking that up could pick a same-named different package
            s.uuid === nothing && pkgerror("why requires a package name or UUID")
            why(s.uuid; kwargs...)
        end
    end
    return nothing
end
why(pkg::AbstractString; kwargs...) = why(String(pkg); kwargs...)
@operation function why(pkg::String; workspace::Bool = false, io::IO = stdout_f())
    # a pure manifest query: no OpContext, so a fresh depot is not
    # bootstrapped with registries just to answer it
    env = load_environment(; depots = depot_stack())
    targets = UUID[uuid for (uuid, entry) in env.manifest if entry.name == pkg]
    isempty(targets) && pkgerror("Package named $(repr(pkg)) was not found in manifest $(repr(env.manifest_file))")
    length(targets) > 1 && pkgerror(
        "multiple packages named `$pkg` in the manifest; disambiguate with " *
            "`why(PackageSpec(uuid = ...))`: " * join(targets, ", ")
    )
    return _why(env, only(targets); workspace, io)
end
@operation function why(uuid::UUID; workspace::Bool = false, io::IO = stdout_f())
    env = load_environment(; depots = depot_stack())
    haskey(env.manifest, uuid) || pkgerror("Package with UUID $uuid was not found in manifest $(repr(env.manifest_file))")
    return _why(env, uuid; workspace, io)
end
function _why(env, target::UUID; workspace::Bool, io::IO)
    # reverse strong-dependency edges
    incoming = Dict{UUID, Set{UUID}}()
    for (uuid, entry) in env.manifest
        for dep_uuid in values(entry.deps)
            push!(get!(Set{UUID}, incoming, dep_uuid), uuid)
        end
    end
    roots = Set{UUID}(values(env.project.deps))
    if workspace
        for (_, member) in env.workspace
            union!(roots, values(member.deps))
        end
    end
    # everything that can reach the target, so the downward walk below only
    # follows edges that end up at it
    relevant = Set{UUID}((target,))
    queue = UUID[target]
    while !isempty(queue)
        for parent in get(Set{UUID}, incoming, pop!(queue))
            parent in relevant && continue
            push!(relevant, parent)
            push!(queue, parent)
        end
    end
    # each package is expanded at most once; later occurrences print as
    # `Name (*)` (this also guards against dependency cycles); branches
    # terminating in the queried package get a colored arrowhead. Rendered by a
    # top-level recursion to avoid a boxed self-referential closure.
    expanded = Set{UUID}()
    for root in sort!(filter(in(relevant), collect(roots)); by = u -> env.manifest[u].name)
        why_print_node(io, env, relevant, target, expanded, root, "  ", "", "  ")
    end
    return nothing
end

function why_print_node(io, env, relevant, target::UUID, expanded, uuid, prefix, branch, childprefix)
    kids = sort!(filter(in(relevant), collect(values(env.manifest[uuid].deps))); by = u -> env.manifest[u].name)
    print(io, prefix, branch)
    if uuid == target
        printstyled(io, "▶ "; color = :green, bold = true)
    elseif !isempty(branch)
        print(io, " ")
    end
    if !isempty(kids) && uuid in expanded
        println(io, env.manifest[uuid].name, " (*)")
        return
    end
    println(io, env.manifest[uuid].name)
    push!(expanded, uuid)
    for (i, kid) in enumerate(kids)
        last = i == length(kids)
        why_print_node(
            io, env, relevant, target, expanded, kid, childprefix,
            last ? "└─" : "├─", childprefix * (last ? "   " : "│  "),
        )
    end
    return
end

"""
    build(pkgs = []; io)

Run `deps/build.jl` of the given packages (default: the project's direct
dependencies that have one), dependencies first.
"""
build(pkg::AbstractString; kwargs...) = build([String(pkg)]; kwargs...)
build(pkgs::AbstractVector{<:AbstractString}; kwargs...) = build(String.(pkgs); kwargs...)
@operation function build(pkgs::Vector{String}; verbose::Bool = false, io::IO = stderr_f())
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    uuids = UUID[]
    for pkg in pkgs
        _, uuid = Planning.resolve_request(env, ctx.registries, PackageRequest(pkg))
        push!(uuids, uuid)
    end
    BuildOps.build!(env, ctx.config.depots, uuids; verbose, io)
    # a rebuild invalidates the built packages' caches (Pkg parity)
    _auto_precompile(ctx)
    return nothing
end

"""
    test(pkgs = []; test_args, julia_args, coverage, allow_reresolve, io)

Test packages in a sandbox (default: the active project itself).
"""
test(pkg::AbstractString; kwargs...) = test([String(pkg)]; kwargs...)
test(pkgs::AbstractVector{<:AbstractString}; kwargs...) = test(String.(pkgs); kwargs...)
@operation function test(
        pkgs::Vector{String};
        test_args::Union{Cmd, AbstractVector{<:AbstractString}} = String[],
        julia_args::Union{Cmd, AbstractVector{<:AbstractString}} = String[],
        coverage::Union{Bool, String} = false,
        allow_reresolve::Bool = true,
        force_latest_compatible_version::Bool = false,
        allow_earlier_backwards_compatible_versions::Bool = true,
        io::IO = stderr_f(),
    )
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    uuids = UUID[]
    if isempty(pkgs)
        env.project.uuid === nothing && pkgerror(
            "Cannot test the active project: Project.toml does not define a uuid"
        )
        push!(uuids, env.project.uuid)
    else
        for pkg in pkgs
            _, uuid = Planning.resolve_request(env, ctx.registries, PackageRequest(pkg))
            push!(uuids, uuid)
        end
    end
    pkgs_errored = Tuple{String, Base.Process}[]
    for uuid in uuids
        failed = TestOps.test!(
            env, ctx.registries, ctx.config, uuid;
            test_args, julia_args, coverage, allow_reresolve,
            force_latest_compatible_version,
            allow_earlier_backwards_compatible_versions,
            autoprecompile = should_autoprecompile(), io,
        )
        failed === nothing || push!(pkgs_errored, failed)
    end
    TestOps.report_test_failures(pkgs_errored)
    return nothing
end

"""
    undo(; io) / redo(; io)

Step the active environment backwards/forwards through the per-project
snapshot stack fed by every mutating operation.
"""
function undo(; io::IO = stderr_f())
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    state, target_idx, target = undo_redo_target(env, -1)
    write_environment(env, target)
    state.idx = target_idx
    print_env_diff(io, env, target; registries = ctx.registries, depots = ctx.config.depots)
    return nothing
end

function redo(; io::IO = stderr_f())
    ctx = op_context(; io)
    env = load_environment(; depots = ctx.config.depots)
    state, target_idx, target = undo_redo_target(env, +1)
    write_environment(env, target)
    state.idx = target_idx
    print_env_diff(io, env, target; registries = ctx.registries, depots = ctx.config.depots)
    return nothing
end

"""
    gc(; verbose = false, force = false, io)

Collect unreachable packages, repo caches, artifacts, and scratchspaces
(see `GCOps.gc`).

A collection also runs automatically after `up`/`pin`/`free`/`rm` when the
first depot has not been swept for a week; set `JULIA_PKG_GC_AUTO=false` (or
call `API.auto_gc(false)`) to disable that.
"""
@operation function gc(; collect_delay = nothing, verbose::Bool = false, force::Bool = false, io::IO = stderr_f())
    return GCOps.gc(depot_stack(); collect_delay, verbose, force, io)
end

#################
# Introspection #
#################

"""
    PackageInfo

Metadata about one package of the active environment, as returned by
[`dependencies`](@ref).
"""
Base.@kwdef struct PackageInfo
    name::String
    version::Union{Nothing, VersionNumber}
    tree_hash::Union{Nothing, String}
    is_direct_dep::Bool
    is_pinned::Bool
    is_tracking_path::Bool
    is_tracking_repo::Bool
    is_tracking_registry::Bool
    git_revision::Union{Nothing, String}
    git_source::Union{Nothing, String}
    source::Union{Nothing, String}
    dependencies::Dict{String, UUID}
end

"""
    dependencies(; workspace::Bool = false) -> Dict{UUID, PackageInfo}

The full dependency graph of the active environment: every manifest package
(direct and indirect), keyed by uuid. With `workspace = true` the direct
dependencies of every workspace project count as direct, not only the
active project's.
"""
function dependencies(; workspace::Bool = false)
    depots = depot_stack()
    env = load_environment(; depots)
    direct = Set{UUID}(values(env.project.deps))
    if workspace
        for (_, wproj) in env.workspace
            union!(direct, values(wproj.deps))
        end
    end
    info = Dict{UUID, PackageInfo}()
    for (uuid, entry) in env.manifest
        tree = EnvFiles.entry_tree_hash(entry)
        info[uuid] = PackageInfo(;
            name = entry.name,
            version = EnvFiles.entry_version(entry),
            tree_hash = tree === nothing ? nothing : string(tree),
            is_direct_dep = uuid in direct,
            is_pinned = entry.pinned,
            is_tracking_path = EnvFiles.is_path_tracked(entry),
            is_tracking_repo = EnvFiles.is_repo_tracked(entry),
            is_tracking_registry = EnvFiles.is_registry_tracked(entry),
            git_revision = EnvFiles.entry_repo_rev(entry),
            git_source = EnvFiles.entry_repo_url(entry),
            source = Execution.entry_source_path(env.manifest_file, entry, depots),
            dependencies = Dict{String, UUID}(entry.deps),
        )
    end
    return info
end

"""
    ProjectInfo

Metadata about the active project, as returned by [`project`](@ref).
"""
Base.@kwdef struct ProjectInfo
    name::Union{Nothing, String}
    uuid::Union{Nothing, UUID}
    version::Union{Nothing, VersionNumber}
    ispackage::Bool
    dependencies::Dict{String, UUID}
    path::String
end

"""
    project(; workspace::Bool = false) -> ProjectInfo

Information about the active project: name, uuid, version, whether it is a
package, its direct dependencies, and the project file path. With
`workspace = true` the direct dependencies of every workspace project are
merged into `dependencies`.
"""
function project(; workspace::Bool = false)
    env = load_environment(; depots = depot_stack())
    p = env.project
    deps = Dict{String, UUID}(p.deps)
    if workspace
        for (_, wproj) in env.workspace
            merge!(deps, wproj.deps)
        end
    end
    return ProjectInfo(;
        name = p.name, uuid = p.uuid, version = p.version,
        ispackage = p.name !== nothing && p.uuid !== nothing,
        dependencies = deps,
        path = env.project_file,
    )
end

"""
    readonly() -> Bool
    readonly(on::Bool; io) -> Bool

Query the `readonly` state of the active environment, or set it (writing
the project file) and return the previous state. A readonly environment
rejects every operation that would modify it.
"""
function readonly()
    env = load_environment(; depots = depot_stack())
    return env.project.readonly
end
function readonly(on::Bool; io::IO = stderr_f())
    env = load_environment(; depots = depot_stack())
    prev = env.project.readonly
    if prev != on
        project = EnvFiles.with_project(env.project; readonly = on)
        new_env = Environment(env.project_file, env.manifest_file, project, env.manifest, env.workspace)
        write_environment(env, new_env; skip_readonly_check = true)
    end
    printpkgstyle(io, :Updated, "Readonly mode $(on ? "enabled" : "disabled") for project at $(pathrepr(env.project_file))")
    return prev
end

"""
    activate(path; temp = false, shared = false, io)

Set the active project (`Base.ACTIVE_PROJECT`). `activate()` returns to the
default environment; `activate("-")` to the previously active one.
`activate(; temp = true)` activates a temporary project that is deleted
when the Julia process exits. `activate(name; shared = true)` activates the
shared environment `environments/<name>` from the first depot that has it
(created in the first depot when none does). `activate(s)` where `s` names
a project dependency tracking a local path activates that path. Never
installs anything.
"""
function activate(path::Union{Nothing, String} = nothing; temp::Bool = false, shared::Bool = false, prev::Bool = false, io::IO = stderr_f())
    if temp
        path === nothing || pkgerror("Cannot specify both a path and temp=true")
        shared && pkgerror("Cannot combine temp=true with shared=true")
        path = mktempdir()
    end
    if prev
        (path === nothing && !temp && !shared) ||
            pkgerror("`prev` cannot be combined with a path, `temp`, or `shared`")
        path = "-"
    end
    if path == "-" && !shared
        isempty(PREV_ENV_PATH[]) && pkgerror("No previously active environment found")
        path = PREV_ENV_PATH[]
    end
    if shared
        path === nothing && pkgerror("A shared environment requires a name")
        (isempty(path) || path in (".", "..") || occursin(r"[/\\]", path)) &&
            pkgerror("Invalid shared environment name $(repr(path)); expected a single path component")
        # first existing shared environment in the depot stack, else the
        # first depot
        stack = depot_stack()
        path = something(
            findfirst_shared_env(stack, path),
            Some(joinpath(Depots.environments_dir(depots1(stack)), path))
        )
    end
    if path !== nothing && !temp && !shared && !isdir(path)
        # `activate(s)` where `s` names a dep tracking a path (dev'd)
        tracked = tracked_dep_path(path)
        tracked === nothing || (path = tracked)
    end
    previous = Base.active_project()
    if path === nothing
        Base.ACTIVE_PROJECT[] = nothing
    else
        project_file = Environments.find_project_file(path)
        Base.ACTIVE_PROJECT[] = project_file
        fresh = isfile(project_file) ? "" : "new "
        printpkgstyle(io, :Activating, "$(fresh)project at $(pathrepr(dirname(project_file)))")
    end
    previous === nothing || (PREV_ENV_PATH[] = previous)
    return nothing
end

# The tracked path of a direct dependency named `name`, or nothing.
function tracked_dep_path(name::String)
    Base.active_project() === nothing && return nothing
    env = try
        load_environment(; depots = depot_stack())
    catch err
        err isa PkgError || rethrow()
        return nothing
    end
    uuid = get(env.project.deps, name, nothing)
    uuid === nothing && return nothing
    entry = get(env.manifest, uuid, nothing)
    entry === nothing && return nothing
    path = EnvFiles.entry_path(entry)
    path === nothing && return nothing
    return isabspath(path) ? path : normpath(joinpath(dirname(env.manifest_file), path))
end

function findfirst_shared_env(stack::DepotStack, name::String)
    for depot in depots(stack)
        dir = joinpath(Depots.environments_dir(depot), name)
        isdir(dir) && return dir
    end
    return nothing
end

end # module
