# Planning: pure operation semantics.
#
# Functions here take an Environment + registry instances + a Config and
# compute a NEW Environment — no network, no file mutation (reading project
# files of path-tracked packages is the one filesystem touch). Downloading
# what a plan needs is Execution's job. The one plan-time effect — fetching
# a repo-tracked package whose tree is not in the store (e.g. a hand-edited
# `[sources]` url/rev) — enters through the injected `fetcher` capability
# (`Git.source_fetcher`); with the default `fetcher = nothing` planning is
# guaranteed network-free and errors instead.
#
# The resolve pipeline is a faithful port of Pkg's Operations functions
# (load_*_deps, collect_fixed!, deps_graph, resolve_versions!,
# tiered_resolve, update_manifest!) with these differences:
#   - the boundary is pure: inputs are immutable Environment/Manifest values,
#     internal mutation happens on private `Node` records
#   - no workspace support yet (requires Julia 1.13 code-loading support)

module Planning

using Base: UUID, SHA1

using ..Errors: pkgerror
using ..Utils: stderr_f, printpkgstyle, pkgstyle_indent
using ..Timing: @timeit, TIMER
import ..FuzzySorting
using ..Versions: VersionSpec, VersionRange, VersionBound, semver_spec
using ..EnvFiles
using ..EnvFiles: SourceSpec, RepoPackage, PathTracked, RepoTracked, RegistryTracked,
    ManifestEntry, RegistryRef, with_manifest, with_project,
    entry_version, entry_tree_hash, entry_path, entry_repo_url,
    entry_repo_rev, entry_repo_subdir
using ..Depots: DepotStack, find_installed
using ..Configs
using ..Configs: Config
using ..Stdlibs
using ..Stdlibs: UPGRADABLE_STDLIBS_UUIDS
using ..Registries
using ..Registries: RegistryInstance, registry_name, registry_uuid, registry_repo
using ..Resolve
using ..Environments
using ..Environments: Environment, projectfile_path, rebase_path, resolve_hash

export PackageRequest, AddTarget, plan_add, plan_promote, plan_rm, plan_resolve,
    plan_develop, plan_up, plan_pin, plan_free, plan_compat, plan_compat_entry

#################
# Working nodes #
#################

# Private working record of the resolve pipeline (the port's PackageSpec
# replacement). Never escapes this module.
Base.@kwdef mutable struct Node
    name::Union{Nothing, String} = nothing
    uuid::Union{Nothing, UUID} = nothing
    version::Union{Nothing, VersionNumber, VersionSpec} = nothing
    path::Union{Nothing, String} = nothing            # manifest-relative or absolute
    repo_url::Union{Nothing, String} = nothing
    repo_rev::Union{Nothing, String} = nothing
    repo_subdir::Union{Nothing, String} = nothing
    tree_hash::Union{Nothing, SHA1} = nothing
    pinned::Bool = false
end

is_tracking_path(n::Node) = n.path !== nothing
is_tracking_repo(n::Node) = n.repo_url !== nothing || n.repo_rev !== nothing
is_tracking_registry(n::Node) = !is_tracking_path(n) && !is_tracking_repo(n)
isfixed(n::Node) = !is_tracking_registry(n) || n.pinned
tracking_registered_version(n::Node, julia_version) =
    !isfixed(n) && !is_stdlib(n.uuid::UUID, julia_version)

err_rep(n::Node) = err_rep(n.name, n.uuid)
function err_rep(name, uuid)
    x = name !== nothing && uuid !== nothing ? "$name [$(string(uuid)[1:8])]" :
        name !== nothing ? name : string(uuid)
    return "`$x`"
end

function entry_to_node(uuid::UUID, entry::ManifestEntry, version)
    return Node(;
        uuid, name = entry.name,
        version,
        path = entry_path(entry),
        repo_url = entry_repo_url(entry),
        repo_rev = entry_repo_rev(entry),
        repo_subdir = entry_repo_subdir(entry),
        tree_hash = entry_tree_hash(entry),
        pinned = entry.pinned,
    )
end

"Absolute source directory of a node, or nothing when not determinable."
function source_path(manifest_file::String, n::Node, depots::DepotStack)
    path = n.path
    tree_hash = n.tree_hash
    return if path !== nothing
        isabspath(path) ? path : normpath(joinpath(dirname(manifest_file), path))
    elseif tree_hash !== nothing
        first(find_installed(depots, n.name::String, n.uuid::UUID, tree_hash))
    else
        nothing
    end
end

function is_package_downloaded(manifest_file::String, n::Node, depots::DepotStack)
    path = source_path(manifest_file, n, depots)
    path === nothing && return false
    return isdir(path)
end

##########
# Compat #
##########

get_compat_spec(p::Project, name::String) =
    haskey(p.compat, name) ? p.compat[name].val : VersionSpec()
get_compat_str(p::Project, name::String) =
    haskey(p.compat, name) ? p.compat[name].str : nothing

# Compat entries that exclude a non-upgradable stdlib's pinned version are
# ignored with a warning (the stdlib cannot move anyway).
function check_stdlib_compat(name::String, uuid::UUID, compat::VersionSpec, project::Project, project_file::String, julia_version)
    is_stdlib(uuid) && !(uuid in UPGRADABLE_STDLIBS_UUIDS) || return compat
    stdlib_ver = stdlib_version(uuid, julia_version)
    stdlib_ver === nothing && return compat
    isempty(compat) && return compat
    stdlib_ver in compat && return compat
    compat_str = get_compat_str(project, name)
    if compat_str !== nothing
        suggested_compat = string(compat_str, ", ", stdlib_ver.major == 0 ? string(stdlib_ver.major, ".", stdlib_ver.minor) : string(stdlib_ver.major))
        @warn """Ignoring incompatible compat entry `$name = $(repr(compat_str))` in $(repr(project_file)).
        $name is a non-upgradable standard library with version $stdlib_ver in the current Julia version.
        Fix by setting compat to $(repr(suggested_compat)) to mark support of the current version $stdlib_ver.""" maxlog = 1
    end
    return VersionSpec("*")
end

function get_compat_with_stdlib_check(project::Project, project_file::String, name::String, uuid::UUID, julia_version)
    return check_stdlib_compat(name, uuid, get_compat_spec(project, name), project, project_file, julia_version)
end

# Workspace-aware compat: intersection over all members, with the stdlib
# check applied for the active project.
function get_compat_env(env::Environment, name::String)
    compat = get_compat_spec(env.project, name)
    for (_, proj) in env.workspace
        compat = intersect(compat, get_compat_spec(proj, name))
    end
    uuid = get(env.project.deps, name, nothing)
    if uuid !== nothing
        compat = check_stdlib_compat(name, uuid, compat, env.project, env.project_file, VERSION)
    end
    return compat
end

################
# Seed loading #
################

function load_version(version, fixed::Bool, preserve::PreserveLevel)
    if version === nothing
        return VersionSpec() # some stdlibs don't have a version
    elseif fixed
        return version # don't change the state of a fixed package
    elseif preserve == PRESERVE_ALL || preserve == PRESERVE_ALL_INSTALLED || preserve == PRESERVE_DIRECT
        return something(version, VersionSpec())
    elseif preserve == PRESERVE_SEMVER && version != VersionSpec()
        return semver_spec("$(version.major).$(version.minor).$(version.patch)")
    elseif preserve == PRESERVE_NONE
        return VersionSpec()
    end
end

entry_isfixed(entry::ManifestEntry) = !(entry.tracking isa RegistryTracked) || entry.pinned

# `[sources]` locations of a project's dep, path rebased to manifest-relative.
function project_source(project::Project, project_file::String, manifest_file::String, name::String)
    source = get(project.sources, name, nothing)
    source === nothing && return nothing
    if source.path !== nothing && (source.url !== nothing || source.rev !== nothing)
        pkgerror("`path` and `url` are conflicting specifications")
    end
    path = source.path === nothing ? nothing : rebase_path(project_file, manifest_file, source.path)
    return SourceSpec(path, source.url, source.rev, source.subdir)
end

function merge_node_source!(n::Node, source::Union{Nothing, SourceSpec})
    source === nothing && return
    if source.path !== nothing
        # path from [sources] takes precedence: clear manifest tracking
        n.tree_hash = nothing
        n.repo_url = nothing
        n.repo_rev = nothing
        n.path = source.path
    end
    if source.url !== nothing
        # a url differing from the recorded one invalidates the manifest tree
        source.url == n.repo_url || (n.tree_hash = nothing)
        n.path = nothing
        n.repo_url = source.url
    end
    if source.rev !== nothing
        # likewise a hand-edited rev: the recorded tree belongs to the old rev
        source.rev == n.repo_rev || (n.tree_hash = nothing)
        n.repo_rev = source.rev
    end
    source.subdir !== nothing && (n.repo_subdir = source.subdir)
    return
end

project_uuid(env::Environment) =
    something(env.project.uuid, Base.dummy_uuid(env.project_file))

# Several workspace projects may declare the same dep in `[sources]`; only
# one entry can win, so the complete specs must agree field for field — a
# rev/subdir present in one project but missing in another is as much a
# conflict as two differing values (paths compared after rebasing to
# manifest-relative).
function assert_no_conflicting_sources(name::String, sources::Vector{SourceSpec})
    length(sources) < 2 && return
    allequal(sources) && return
    conflicts = String[]
    if any(s.path !== nothing for s in sources) &&
            any(s.url !== nothing || s.rev !== nothing for s in sources)
        push!(conflicts, "both a path and a url/rev")
    end
    describe(x) = something(x, "(not specified)")
    for (field, label) in ((:path, "paths"), (:url, "urls"), (:rev, "revs"), (:subdir, "subdirs"))
        vals = unique(getfield(s, field) for s in sources)
        length(vals) > 1 && push!(conflicts, label * ": " * join(sort!(map(describe, vals)), ", "))
    end
    pkgerror(
        "Package $(name) has conflicting sources specified by different projects " *
            "in the workspace: $(join(conflicts, "; ")).\n" *
            "Make the `[sources]` entries for this package agree across the workspace."
    )
end

# Direct dependencies of the environment as nodes — the union over the
# active project and every workspace member, each member included as a
# fixed node of its own when it is a package.
function load_direct_deps(env::Environment, nodes::Vector{Node} = Node[]; preserve::PreserveLevel = PRESERVE_DIRECT)
    out = Node[]
    # membership across `nodes` and everything pushed to `out` so far
    seen = Set{UUID}(n.uuid for n in nodes if n.uuid !== nothing)
    have(uuid) = uuid in seen
    projects = vcat([env.project_file => env.project], env.workspace)
    sources_for = Dict{UUID, Vector{SourceSpec}}()
    name_for = Dict{UUID, String}()
    for (project_file, project) in projects
        for (name, uuid) in project.deps
            source = project_source(project, project_file, env.manifest_file, name)
            source === nothing && continue
            push!(get!(Vector{SourceSpec}, sources_for, uuid), source)
            get!(name_for, uuid, name)
        end
    end
    for (uuid, sources) in sources_for
        assert_no_conflicting_sources(name_for[uuid], sources)
    end
    # every member's self node first, so a member that is also a dep of a
    # sibling project keeps its path tracking instead of a registry seed
    for (project_file, project) in projects
        if project.name !== nothing && project.uuid !== nothing && !have(project.uuid)
            path = relpath(dirname(project_file), dirname(env.manifest_file))
            push!(out, Node(; name = project.name, uuid = project.uuid, version = project.version, path))
            push!(seen, project.uuid)
        end
    end
    for (project_file, project) in projects
        for (name, uuid) in project.deps
            have(uuid) && continue
            source = project_source(project, project_file, env.manifest_file, name)
            entry = get(env.manifest, uuid, nothing)
            n = if entry === nothing
                # not in the manifest yet: unconstrained (PackageSpec's default)
                Node(; uuid, name, version = VersionSpec())
            else
                Node(;
                    uuid, name,
                    path = entry_path(entry),
                    repo_url = entry_repo_url(entry),
                    repo_rev = entry_repo_rev(entry),
                    repo_subdir = entry_repo_subdir(entry),
                    pinned = entry.pinned,
                    tree_hash = entry_tree_hash(entry),
                    version = load_version(entry_version(entry), entry_isfixed(entry), preserve),
                )
            end
            merge_node_source!(n, source)
            push!(out, n)
            push!(seen, uuid)
        end
    end
    return vcat(nodes, out)
end

function load_manifest_deps(manifest::Manifest, nodes::Vector{Node} = Node[]; preserve::PreserveLevel = PRESERVE_ALL)
    nodes = copy(nodes)
    seen = Set{UUID}(n.uuid for n in nodes if n.uuid !== nothing)
    for (uuid, entry) in manifest
        uuid in seen && continue
        push!(nodes, entry_to_node(uuid, entry, load_version(entry_version(entry), entry_isfixed(entry), preserve)))
        push!(seen, uuid)
    end
    return nodes
end

function load_all_deps(env::Environment, nodes::Vector{Node} = Node[]; preserve::PreserveLevel = PRESERVE_ALL)
    nodes = load_manifest_deps(env.manifest, nodes; preserve)
    # [sources] overlay from the active project AND every workspace member —
    # each member's sources apply to (at least) its own direct deps; first
    # source found wins, the active project consulted first (safe: for direct
    # deps load_direct_deps rejects workspace projects whose entries disagree)
    for n in nodes
        name = something(n.name, "")
        for (project_file, project) in vcat([env.project_file => env.project], env.workspace)
            source = project_source(project, project_file, env.manifest_file, name)
            source === nothing && continue
            merge_node_source!(n, source)
            break
        end
    end
    return load_direct_deps(env, nodes; preserve)
end

#############
# Fixed set #
#############

# Read the project file of a materialized package tree: its declared deps
# (with compat) and weakdeps enter the fixed requirements.
function collect_project(node::Union{Node, Nothing}, path::String, manifest_file::String, julia_version)
    deps = Node[]
    weakdeps = Set{UUID}()
    project_file = projectfile_path(path; strict = true)
    project = project_file === nothing ? Project() : read_project(project_file)
    julia_compat = get_compat_spec(project, "julia")
    if !isnothing(julia_compat) && !isnothing(julia_version) && !(julia_version in julia_compat)
        pkgerror("julia version requirement for package at `$path` not satisfied: compat entry \"julia = $(get_compat_str(project, "julia"))\" does not include Julia version $julia_version")
    end
    for (name, uuid) in project.deps
        dep_source = project_file === nothing ? nothing :
            project_source(project, project_file, manifest_file, name)
        vspec = get_compat_with_stdlib_check(project, something(project_file, path), name, uuid, julia_version)
        n = Node(; name, uuid, version = vspec)
        merge_node_source!(n, dep_source)
        push!(deps, n)
    end
    for (name, uuid) in merge(project.weakdeps, project.deps_weak)
        vspec = get_compat_with_stdlib_check(project, something(project_file, path), name, uuid, julia_version)
        push!(deps, Node(; name, uuid, version = vspec))
        push!(weakdeps, uuid)
    end
    if node !== nothing
        node.version = something(project.version, VersionNumber(0))
    end
    return deps, weakdeps
end

# Recursive closure of path-tracked packages: a dev'd package's dev'd deps
# are also fixed.
function collect_developed!(env::Environment, n::Node, developed::Vector{Node}, seen::Set{UUID}, depots::DepotStack)
    source = source_path(env.manifest_file, n, depots)
    source === nothing && return
    source_project_file = projectfile_path(source; strict = true)
    source_project_file === nothing && return
    source_env = Environments.load_environment_from(source_project_file; depots)
    nodes = load_direct_deps(source_env)
    for dep in nodes
        dep.uuid == n.uuid && continue
        dep.uuid in seen && continue
        if is_tracking_path(dep)
            # normalize the path to be relative to *our* manifest
            dep_source = source_path(source_env.manifest_file, dep, depots)
            dep_source === nothing && continue
            # a dev'd dep's own [sources] pointing at an absent path is not a
            # developed dep: skip it here so it resolves from the registry
            # instead of surfacing as an "expected to exist at path" error
            isdir(dep_source) || continue
            dep.path = relpath(dep_source, dirname(env.manifest_file))
            push!(developed, dep)
            push!(seen, dep.uuid)
            collect_developed!(env, dep, developed, seen, depots)
        elseif is_tracking_repo(dep)
            push!(developed, dep)
            push!(seen, dep.uuid)
        end
    end
    return
end

function collect_developed(env::Environment, nodes::Vector{Node}, depots::DepotStack)
    developed = Node[]
    # mirrors `developed` for O(1) dedup across the recursive collection
    seen = Set{UUID}()
    for n in filter(is_tracking_path, nodes)
        collect_developed!(env, n, developed, seen, depots)
    end
    return developed
end

# The registry-declared repository url of a package (nothing if unregistered).
function registered_repo_url(registries::Vector{RegistryInstance}, uuid::UUID)
    for reg in registries
        p = get(reg, uuid, nothing)
        p === nothing && continue
        info = Registries.registry_info(reg, p)
        info.repo !== nothing && return info.repo
    end
    return nothing
end

# The materialize seam (see module header): a repo-tracked node whose tree is
# not in the package store — a hand-edited `[sources]` url/rev, or a rev-only
# entry whose url comes from the registry — is fetched and installed through
# the injected `fetcher` capability. Returns the installed source path.
function materialize_node!(n::Node, registries::Vector{RegistryInstance}, config::Config, fetcher)
    (config.offline || fetcher === nothing) && pkgerror(
        "package $(err_rep(n)) tracks a repository but its source tree is not materialized; " *
            "planning requires repository packages to be installed first"
    )
    if n.repo_url === nothing
        url = registered_repo_url(registries, n.uuid::UUID)
        url === nothing && pkgerror("package $(err_rep(n)) has a `rev` but no url or path")
        n.repo_url = url
    end
    rp = fetcher(n.repo_url; rev = n.repo_rev, subdir = n.repo_subdir)::RepoPackage
    n.repo_rev = rp.rev
    n.tree_hash = rp.tree_hash
    return rp.path
end

@timeit TIMER "collect fixed" function collect_fixed(env::Environment, nodes::Vector{Node}, request_uuids::Set{UUID}, names::Dict{UUID, String}, julia_version, config::Config, registries::Vector{RegistryInstance}, fetcher)
    depots = config.depots
    deps_map = Dict{UUID, Vector{Node}}()
    weak_map = Dict{UUID, Set{UUID}}()

    # the active project and every workspace member are fixed nodes,
    # each keyed by its OWN uuid (Pkg keyed members under the root — a bug)
    proj_uuid = project_uuid(env)
    proj_node = env.project.uuid === nothing ? nothing :
        Node(; name = env.project.name, uuid = env.project.uuid, version = env.project.version)
    deps, weakdeps = collect_project(proj_node, dirname(env.project_file), env.manifest_file, julia_version)
    deps_map[proj_uuid] = deps
    weak_map[proj_uuid] = weakdeps
    names[proj_uuid] = something(env.project.name, "project")
    project_nodes = Dict{UUID, Node}()
    proj_node === nothing || (project_nodes[proj_uuid] = proj_node)
    for (member_file, member) in env.workspace
        member_uuid = something(member.uuid, Base.dummy_uuid(member_file))
        member_node = member.uuid === nothing ? nothing :
            Node(; name = member.name, uuid = member.uuid, version = member.version)
        mdeps, mweak = collect_project(member_node, dirname(member_file), env.manifest_file, julia_version)
        deps_map[member_uuid] = mdeps
        weak_map[member_uuid] = mweak
        names[member_uuid] = something(member.name, "project")
        member_node === nothing || (project_nodes[member_uuid] = member_node)
    end

    pkg_queue = collect(nodes)
    pkg_by_uuid = Dict{UUID, Node}()
    for n in nodes
        n.uuid === nothing && continue
        pkg_by_uuid[n.uuid] = n
    end
    new_fixed = Node[]
    seen = Set(keys(pkg_by_uuid))
    # names governed by the active project or a workspace member's own
    # `[sources]`: those take precedence over any nested source, so they must
    # not be overwritten when refreshing an already-seen dep below
    env_sourced = Set{String}()
    for (_, project) in vcat([env.project_file => env.project], env.workspace)
        union!(env_sourced, keys(project.sources))
    end
    refreshed = Set{UUID}()
    while !isempty(pkg_queue)
        n = popfirst!(pkg_queue)
        n.uuid === nothing && continue
        path = source_path(env.manifest_file, n, depots)
        if (path === nothing || !isdir(path)) && is_tracking_repo(n)
            path = materialize_node!(n, registries, config, fetcher)
        end
        if path === nothing || !isdir(path)
            dependents = String[]
            for (dep_uuid, dep_entry) in env.manifest
                if n.uuid in values(dep_entry.deps) || n.uuid in values(dep_entry.weakdeps)
                    push!(dependents, dep_entry.name)
                end
            end
            error_msg = "expected package $(err_rep(n)) to exist at path `$path`"
            error_msg *= "\n\nThis package is referenced in the manifest file: $(env.manifest_file)"
            if !isempty(dependents)
                if length(dependents) == 1
                    error_msg *= "\nIt is required by: $(dependents[1])"
                else
                    error_msg *= "\nIt is required by:\n$(join(["  - $dep" for dep in dependents], "\n"))"
                end
            end
            pkgerror(error_msg)
        end
        deps, weakdeps = collect_project(n, path, env.manifest_file, julia_version)
        deps_map[n.uuid] = deps
        weak_map[n.uuid] = weakdeps
        for dep in deps
            names[dep.uuid] = dep.name
            dep_uuid = dep.uuid
            if dep_uuid !== nothing && is_tracking_registry(dep) && !(dep_uuid in request_uuids)
                # a dep of a fixed package that the manifest tracks by path or
                # repo (e.g. an unregistered url-add) keeps its manifest
                # tracking instead of being re-resolved from the registry
                entry = get(env.manifest, dep_uuid, nothing)
                if entry !== nothing && !EnvFiles.is_registry_tracked(entry)
                    dep.path = entry_path(entry)
                    dep.repo_url = entry_repo_url(entry)
                    dep.repo_rev = entry_repo_rev(entry)
                    dep.repo_subdir = entry_repo_subdir(entry)
                    dep.tree_hash = entry_tree_hash(entry)
                end
            end
            if !is_tracking_registry(dep) && dep_uuid !== nothing && !(dep_uuid in seen)
                if is_tracking_path(dep)
                    dep_source = source_path(env.manifest_file, dep, depots)
                    if dep_source !== nothing && isdir(dep_source)
                        push!(pkg_queue, dep)
                        push!(new_fixed, dep)
                        pkg_by_uuid[dep_uuid] = dep
                        push!(seen, dep_uuid)
                    end
                else
                    push!(pkg_queue, dep)
                    push!(new_fixed, dep)
                    pkg_by_uuid[dep_uuid] = dep
                    push!(seen, dep_uuid)
                end
            elseif dep_uuid !== nothing && !haskey(pkg_by_uuid, dep_uuid)
                pkg_by_uuid[dep_uuid] = dep
            elseif !is_tracking_registry(dep) && dep_uuid !== nothing &&
                    haskey(pkg_by_uuid, dep_uuid) && !(dep_uuid in refreshed) &&
                    !(something(dep.name, "") in env_sourced)
                # A path-tracked package's own `[sources]` pins this already-seen
                # dep (a nested source). Refresh the recorded tracking so a
                # hand-edited rev/url reaches the manifest, the same way a
                # top-level `[sources]` change does — unless a top-level source
                # (which wins) already governs it.
                existing = pkg_by_uuid[dep_uuid]
                merge_node_source!(existing, SourceSpec(dep.path, dep.repo_url, dep.repo_rev, dep.repo_subdir))
                push!(refreshed, dep_uuid)
                if existing.tree_hash === nothing && is_tracking_repo(existing)
                    # the recorded tree belonged to the old rev; re-materialize
                    push!(pkg_queue, existing)
                end
            end
        end
    end

    fixed = Dict{UUID, Resolve.Fixed}()
    for (uuid, deps) in deps_map
        q = Dict{UUID, VersionSpec}()
        for dep in deps
            names[dep.uuid] = dep.name
            dep_version = dep.version
            dep_version === nothing && continue
            q[dep.uuid] = dep_version isa VersionSpec ? dep_version : VersionSpec(dep_version)
        end
        fix_pkg = haskey(project_nodes, uuid) ? project_nodes[uuid] : get(pkg_by_uuid, uuid, nothing)
        fixversion = fix_pkg === nothing ? nothing : fix_pkg.version
        fixpkgversion = fixversion isa VersionNumber ? fixversion : v"0.0.0"
        fixed[uuid] = Resolve.Fixed(fixpkgversion, q, get(weak_map, uuid, Set{UUID}()))
    end
    return fixed, new_fixed
end

##############
# deps_graph #
##############

function registered_name(registries::Vector{RegistryInstance}, uuid::UUID)
    name = nothing
    for reg in registries
        regpkg = get(reg, uuid, nothing)
        regpkg === nothing && continue
        name′ = regpkg.name
        if name !== nothing
            name′ == name || pkgerror("package `$uuid` has multiple registered name values: $name, $name′")
        end
        name = name′
    end
    return name
end

const PKGORIGIN_HAVE_VERSION = :version in fieldnames(Base.PkgOrigin)

@timeit TIMER "deps graph" function deps_graph(
        env::Environment, registries::Vector{RegistryInstance}, uuid_to_name::Dict{UUID, String},
        reqs::Resolve.Requires, fixed::Dict{UUID, Resolve.Fixed}, julia_version,
        installed_only::Bool, config::Config,
    )
    depots = config.depots
    uuids = Set{UUID}()
    union!(uuids, keys(reqs))
    union!(uuids, keys(fixed))
    for fixed_uuids in map(fx -> keys(fx.requires), values(fixed))
        union!(uuids, fixed_uuids)
    end

    all_weak_uuids = Set{UUID}()
    for fx in values(fixed)
        union!(all_weak_uuids, fx.weak)
    end

    stdlibs_for_julia_version = Stdlibs.get_last_stdlibs(julia_version)
    seen = Set{UUID}()

    # per-package *vectors* of registry data: one element per registry, kept
    # separate so one registry's compat cannot pollute another's versions
    all_deps_compressed = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}()
    all_compat_compressed = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}()
    weak_deps_compressed = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}()
    weak_compat_compressed = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}()
    pkg_versions = Dict{UUID, Vector{VersionNumber}}()
    pkg_versions_per_registry = Dict{UUID, Vector{Set{VersionNumber}}}()

    for (fp, fx) in fixed
        all_deps_compressed[fp] = [Dict{VersionRange, Set{UUID}}()]
        all_compat_compressed[fp] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
        weak_deps_compressed[fp] = [Dict{VersionRange, Set{UUID}}()]
        weak_compat_compressed[fp] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
        pkg_versions[fp] = [fx.version]
        pkg_versions_per_registry[fp] = [Set([fx.version])]
    end

    while true
        unseen = setdiff(uuids, seen)
        isempty(unseen) && break
        for uuid in unseen
            push!(seen, uuid)
            uuid in keys(fixed) && continue
            uuid_is_stdlib = haskey(stdlibs_for_julia_version, uuid)

            # never resolve stdlibs from the registry for the target julia
            if (julia_version != VERSION && is_unregistered_stdlib(uuid)) || uuid_is_stdlib
                stdlib_info = stdlibs_for_julia_version[uuid]
                v = something(stdlib_info.version, VERSION)

                stdlib_deps = Dict{VersionRange, Set{UUID}}()
                stdlib_compat = Dict{VersionRange, Dict{UUID, VersionSpec}}()
                stdlib_weak_deps = Dict{VersionRange, Set{UUID}}()
                stdlib_weak_compat = Dict{VersionRange, Dict{UUID, VersionSpec}}()

                vrange = VersionRange(v, v)
                deps_set = Set{UUID}()
                for other_uuid in stdlib_info.deps
                    push!(uuids, other_uuid)
                    push!(deps_set, other_uuid)
                end
                stdlib_deps[vrange] = deps_set
                stdlib_compat[vrange] = Dict{UUID, VersionSpec}()

                if !isempty(stdlib_info.weakdeps)
                    weak_deps_set = Set{UUID}()
                    for other_uuid in stdlib_info.weakdeps
                        push!(uuids, other_uuid)
                        push!(weak_deps_set, other_uuid)
                    end
                    stdlib_weak_deps[vrange] = weak_deps_set
                    stdlib_weak_compat[vrange] = Dict{UUID, VersionSpec}()
                end

                all_deps_compressed[uuid] = [stdlib_deps]
                all_compat_compressed[uuid] = [stdlib_compat]
                weak_deps_compressed[uuid] = [stdlib_weak_deps]
                weak_compat_compressed[uuid] = [stdlib_weak_compat]
                pkg_versions[uuid] = [v]
                pkg_versions_per_registry[uuid] = [Set([v])]
            else
                valid_versions = VersionNumber[]
                pkg_deps_list = Vector{Dict{VersionRange, Set{UUID}}}()
                pkg_compat_list = Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}()
                pkg_weak_deps_list = Vector{Dict{VersionRange, Set{UUID}}}()
                pkg_weak_compat_list = Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}()
                pkg_versions_per_reg = Vector{Set{VersionNumber}}()

                for reg in registries
                    pkg = get(reg, uuid, nothing)
                    pkg === nothing && continue
                    info = Registries.registry_info(reg, pkg)

                    reg_valid_versions = Set{VersionNumber}()
                    for v in keys(info.version_info)
                        Registries.isyanked(info, v) && continue
                        if installed_only
                            n = Node(; name = pkg.name, uuid = pkg.uuid, version = v, tree_hash = Registries.treehash(info, v))
                            is_package_downloaded(env.manifest_file, n, depots) || continue
                        end
                        # skip versions that differ from packages baked into the sysimage,
                        # but never drop the version already recorded in the manifest: a JLL
                        # whose sysimaged build differs from the registered one would otherwise
                        # be spuriously downgraded on update (#4131).
                        if PKGORIGIN_HAVE_VERSION && config.respect_sysimage_versions && julia_version == VERSION
                            pkgid = Base.PkgId(uuid, pkg.name)
                            if Base.in_sysimage(pkgid)
                                pkgorigin = get(Base.pkgorigins, pkgid, nothing)
                                if pkgorigin !== nothing && pkgorigin.version !== nothing
                                    manifest_entry = get(env.manifest, uuid, nothing)
                                    manifest_version = manifest_entry === nothing ? nothing : entry_version(manifest_entry)
                                    if v != pkgorigin.version && v != manifest_version
                                        continue
                                    end
                                end
                            end
                        end
                        push!(reg_valid_versions, v)
                        push!(valid_versions, v)
                    end

                    if !isempty(reg_valid_versions)
                        push!(pkg_deps_list, info.deps)
                        push!(pkg_compat_list, info.compat)
                        push!(pkg_weak_deps_list, info.weak_deps)
                        push!(pkg_weak_compat_list, info.weak_compat)
                        push!(pkg_versions_per_reg, reg_valid_versions)
                    end

                    for deps_dict in (info.deps, info.weak_deps)
                        for (vrange, deps_set) in deps_dict
                            union!(uuids, deps_set)
                        end
                    end
                end

                pkg_versions[uuid] = sort!(unique!(valid_versions))
                all_deps_compressed[uuid] = pkg_deps_list
                all_compat_compressed[uuid] = pkg_compat_list
                weak_deps_compressed[uuid] = pkg_weak_deps_list
                weak_compat_compressed[uuid] = pkg_weak_compat_list
                pkg_versions_per_registry[uuid] = pkg_versions_per_reg
            end
        end
    end

    # weak dependencies missing from all registries are dropped, everything
    # else must have a resolvable name
    unavailable_weak_uuids = Set{UUID}()
    for uuid in uuids
        uuid == Registries.JULIA_UUID && continue
        if !haskey(uuid_to_name, uuid)
            name = registered_name(registries, uuid)
            if name === nothing
                if uuid in all_weak_uuids
                    push!(unavailable_weak_uuids, uuid)
                    continue
                end
                pkgerror("cannot find name corresponding to UUID $(uuid) in a registry")
            end
            uuid_to_name[uuid] = name
            entry = get(env.manifest, uuid, nothing)
            entry ≡ nothing && continue
            uuid_to_name[uuid] = entry.name
        end
    end

    if !isempty(unavailable_weak_uuids)
        fixed_filtered = Dict{UUID, Resolve.Fixed}()
        for (uuid, fx) in fixed
            filtered_requires = Resolve.Requires()
            for (req_uuid, req_spec) in fx.requires
                if !(req_uuid in unavailable_weak_uuids)
                    filtered_requires[req_uuid] = req_spec
                end
            end
            filtered_weak = setdiff(fx.weak, unavailable_weak_uuids)
            fixed_filtered[uuid] = Resolve.Fixed(fx.version, filtered_requires, filtered_weak)
        end
        fixed = fixed_filtered
    end

    return all_deps_compressed, all_compat_compressed, weak_deps_compressed, weak_compat_compressed, pkg_versions, pkg_versions_per_registry, uuid_to_name, reqs, fixed
end

####################
# resolve_versions #
####################

function load_tree_hash!(registries::Vector{RegistryInstance}, n::Node, julia_version)
    if is_stdlib(n.uuid::UUID, julia_version) && n.tree_hash !== nothing && n.repo_url === nothing
        # manifests from newer julia versions may record tree hashes for
        # packages that are non-upgradable stdlibs here; clear them
        n.tree_hash = nothing
        return n
    end
    tracking_registered_version(n, julia_version) || return n
    hash = nothing
    for reg in registries
        reg_pkg = get(reg, n.uuid::UUID, nothing)
        reg_pkg === nothing && continue
        pkg_info = Registries.registry_info(reg, reg_pkg)
        version_info = get(pkg_info.version_info, n.version, nothing)
        version_info === nothing && continue
        hash′ = version_info.git_tree_sha1
        if hash !== nothing
            hash == hash′ || pkgerror("hash mismatch in registries for $(n.name) at version $(n.version)")
        end
        hash = hash′
    end
    n.tree_hash = hash
    return n
end

# drops build detail in version but keeps the main prerelease context
dropbuild(v::VersionNumber) = VersionNumber(v.major, v.minor, v.patch, isempty(v.prerelease) ? () : (v.prerelease[1],))

# The heart: turn seed nodes into concrete versions + a dependency map.
# Returns (nodes, final_deps_map, julia_version_stamp).
@timeit TIMER "resolve versions" function resolve_versions(
        env::Environment, registries::Vector{RegistryInstance}, nodes::Vector{Node}, julia_version,
        installed_only::Bool, config::Config,
        preferred_versions::Dict{UUID, VersionNumber} = Dict{UUID, VersionNumber}();
        fetcher = nothing,
    )
    depots = config.depots
    # julia compat check for the project itself
    if julia_version !== nothing
        v = intersect(julia_version, get_compat_env(env, "julia"))
        if isempty(v)
            @warn "julia version requirement for project not satisfied" _module = nothing _file = nothing
        end
    end

    jll_fix = Dict{UUID, VersionNumber}()
    for n in nodes
        version = n.version
        if !is_stdlib(n.uuid::UUID, julia_version) && endswith(n.name::String, "_jll") && version isa VersionNumber
            jll_fix[n.uuid::UUID] = version
        end
    end

    names = Dict{UUID, String}(uuid => info.name for (uuid, info) in stdlib_infos())
    # recursive search for packages tracking a path
    developed = collect_developed(env, nodes, depots)
    node_uuids = Set{UUID}(n.uuid::UUID for n in nodes)
    for n in developed
        if !(n.uuid in node_uuids)
            push!(nodes, n)
            push!(node_uuids, n.uuid)
        end
    end
    # identical contents by construction; collect_fixed only membership-tests
    # the set during the call, so mutating it afterwards is safe
    request_uuids = node_uuids
    nodes_fixed = filter(!is_tracking_registry, nodes)
    fixed, new_fixed = collect_fixed(env, nodes_fixed, request_uuids, names, julia_version, config, registries, fetcher)
    for new_node in new_fixed
        new_node.uuid in node_uuids && continue
        push!(nodes, new_node)
        push!(node_uuids, new_node.uuid)
    end

    @assert length(node_uuids) == length(nodes)

    # check compat
    for n in nodes
        compat = get_compat_env(env, n.name::String)
        v = intersect(n.version, compat)
        if isempty(v)
            throw(
                Resolve.ResolverError(
                    "empty intersection between $(n.name)@$(n.version) and project compatibility $(compat)"
                )
            )
        end
        if !(n.version isa VersionNumber)
            n.version = v
        end
    end

    for n in nodes
        names[n.uuid] = n.name
    end

    # always allow stdlibs to move when resolving for the running julia
    unbind_stdlibs = julia_version === VERSION
    reqs = Resolve.Requires(n.uuid::UUID => is_stdlib(n.uuid::UUID, julia_version) && unbind_stdlibs ? VersionSpec("*") : VersionSpec(something(n.version)) for n in nodes)
    deps_map_compressed, compat_map_compressed, weak_deps_map_compressed, weak_compat_map_compressed,
        pkg_versions_map, pkg_versions_per_registry, uuid_to_name, reqs, fixed =
        deps_graph(env, registries, names, reqs, fixed, julia_version, installed_only, config)

    graph = Resolve.Graph(
        deps_map_compressed, compat_map_compressed, weak_deps_map_compressed, weak_compat_map_compressed,
        pkg_versions_map, pkg_versions_per_registry, uuid_to_name, reqs, fixed, false, julia_version, preferred_versions
    )
    Resolve.simplify_graph!(graph)
    vers = Resolve.resolve(graph)

    # fix up jlls that had their build numbers stripped by the resolver
    vers_fix = copy(vers)
    # jlls whose build metadata we reverted to the manifest's build: their
    # deps must come from the manifest, not the registry (Pkg.jl#3795). The
    # compressed Deps.toml keys on major.minor.patch, so `version in vrange`
    # can't tell build-metadata variants apart (src/Versions.jl); re-querying
    # would graft the resolver-picked build's deps onto the pinned build.
    jll_build_pinned = Set{UUID}()
    for (uuid, ver) in vers
        old_v = get(jll_fix, uuid, nothing)
        if old_v !== nothing && Base.thispatch(old_v) == Base.thispatch(vers_fix[uuid])
            old_v == vers_fix[uuid] || push!(jll_build_pinned, uuid)
            vers_fix[uuid] = old_v
            versions_for_pkg = get!(pkg_versions_map, uuid, VersionNumber[])
            if !(old_v in versions_for_pkg)
                push!(versions_for_pkg, old_v)
                sort!(versions_for_pkg)
            end
        end
    end
    vers = vers_fix

    # apply the solution to the node set (`vers` is a Dict, so nodes pushed
    # below can never be looked up in the same loop — no index upkeep needed)
    node_index = Dict{UUID, Int}(n.uuid::UUID => i for (i, n) in pairs(nodes))
    for (uuid, ver) in vers
        idx = get(node_index, uuid, nothing)
        if idx !== nothing
            n = nodes[idx]
            # fixed packages are not returned by resolve
            n.version = vers[n.uuid]
        else
            name = is_stdlib(uuid) ? stdlib_infos()[uuid].name : registered_name(registries, uuid)
            push!(nodes, Node(; name, uuid, version = ver))
        end
    end

    pkgs_uuids = Set{UUID}(n.uuid for n in nodes)

    final_deps_map = Dict{UUID, Dict{String, UUID}}()
    for n in nodes
        load_tree_hash!(registries, n, julia_version)
        deps = begin
            if n.uuid in keys(fixed)
                deps_fixed = Dict{String, UUID}()
                for dep in keys(fixed[n.uuid].requires)
                    dep in pkgs_uuids || continue
                    deps_fixed[names[dep]] = dep
                end
                deps_fixed
            elseif n.uuid in jll_build_pinned && haskey(env.manifest, n.uuid::UUID)
                # keep the pinned build's recorded deps (Pkg.jl#3795)
                d = Dict{String, UUID}()
                for (dep_name, dep_uuid) in env.manifest[n.uuid::UUID].deps
                    dep_uuid in pkgs_uuids || continue
                    d[dep_name] = dep_uuid
                end
                d
            else
                d = Dict{String, UUID}()
                available_versions = get(Vector{VersionNumber}, pkg_versions_map, n.uuid)
                if !(n.version in available_versions)
                    pkgerror("version $(n.version) of package $(n.name) is not available. Available versions: $(join(available_versions, ", "))")
                end
                deps_for_version = Registries.query_deps_for_version(
                    deps_map_compressed, weak_deps_map_compressed, n.uuid::UUID, n.version::VersionNumber
                )
                for uuid in deps_for_version
                    uuid in pkgs_uuids || continue
                    d[names[uuid]] = uuid
                end
                d
            end
        end
        # julia is an implicit dependency
        filter!(d -> d.first != "julia", deps)
        final_deps_map[n.uuid] = deps
    end
    return nodes, final_deps_map
end

###################
# Manifest update #
###################

function build_manifest(
        env::Environment, nodes::Vector{Node}, deps_map::Dict{UUID, Dict{String, UUID}},
        julia_version, registries::Vector{RegistryInstance},
    )
    # registry provenance: which registries carry each registry-tracked
    # package at its resolved version
    used_registry_uuids = Set{UUID}()
    pkg_to_registries = Dict{UUID, Vector{UUID}}()
    for n in nodes
        if tracking_registered_version(n, julia_version)
            pkg_reg_uuids = UUID[]
            for reg in registries
                reg_pkg = get(reg, n.uuid::UUID, nothing)
                reg_pkg === nothing && continue
                pkg_info = Registries.registry_info(reg, reg_pkg)
                version_info = get(pkg_info.version_info, n.version, nothing)
                version_info === nothing && continue
                push!(pkg_reg_uuids, registry_uuid(reg))
                push!(used_registry_uuids, registry_uuid(reg))
            end
            if !isempty(pkg_reg_uuids)
                pkg_to_registries[n.uuid] = pkg_reg_uuids
            end
        end
    end
    reg_uuid_to_name = Dict{UUID, String}()
    registry_refs = Dict{String, RegistryRef}()
    for reg in registries
        registry_uuid(reg) in used_registry_uuids || continue
        name = registry_name(reg)
        reg_uuid_to_name[registry_uuid(reg)] = name
        registry_refs[name] = RegistryRef(name, registry_uuid(reg), registry_repo(reg))
    end

    old_entries = env.manifest.deps
    entries = Dict{UUID, ManifestEntry}()
    for n in nodes
        uuid = n.uuid::UUID
        nversion = n.version
        version = nversion isa VersionNumber ? nversion : nothing
        if is_stdlib(uuid, julia_version)
            # only external (versioned) stdlibs carry a version in the manifest
            version = stdlib_version(uuid, julia_version)
        end
        reg_names = String[
            reg_uuid_to_name[u] for u in get(Vector{UUID}, pkg_to_registries, uuid)
                if haskey(reg_uuid_to_name, u)
        ]
        path = n.path
        repo_url = n.repo_url
        tracking = if path !== nothing
            PathTracked(path, version)
        elseif repo_url !== nothing || n.repo_rev !== nothing
            repo_url === nothing && pkgerror("package $(err_rep(n)) has a `rev` but no url or path")
            RepoTracked(repo_url, n.repo_rev, n.repo_subdir, n.tree_hash, version)
        else
            RegistryTracked(version, is_stdlib(uuid, julia_version) ? nothing : n.tree_hash, reg_names)
        end
        # weakdeps/exts are carried from the old entries; for newly resolved
        # packages Execution's fixups_from_projectfile corrects them from
        # the installed Project.tomls
        old = get(old_entries, n.uuid, nothing)
        entries[n.uuid] = ManifestEntry(
            n.name, n.uuid, tracking, n.pinned,
            deps_map[n.uuid],
            old === nothing ? Dict{String, UUID}() : old.weakdeps,
            old === nothing ? Dict{String, Union{String, Vector{String}}}() : old.exts,
            old === nothing ? Dict{String, EnvFiles.AppInfo}() : old.apps,
            old === nothing ? nothing : old.entryfile,
            old === nothing ? nothing : old.julia_syntax_version,
            old === nothing ? Dict{String, Any}() : old.raw,
        )
    end

    manifest = with_manifest(
        env.manifest;
        julia_version = julia_version === nothing ? nothing : dropbuild(julia_version),
        manifest_format = v"2.1.0",
        deps = entries,
        registries = registry_refs,
    )
    keep = Set{UUID}(values(env.project.deps))
    env.project.uuid === nothing || push!(keep, env.project.uuid)
    for (_, member) in env.workspace
        union!(keep, values(member.deps))
        member.uuid === nothing || push!(keep, member.uuid)
    end
    manifest = prune_manifest(manifest, keep)
    new_env = Environment(env.project_file, env.manifest_file, env.project, manifest, env.workspace)
    return with_manifest(manifest; project_hash = resolve_hash(new_env))
end

"Keep only entries reachable from `keep` through strong dependency edges."
function prune_manifest(manifest::Manifest, keep::Set{UUID})
    # forward-reachability as a worklist BFS instead of a manifest-rescanning
    # fixpoint (Pkg.jl#4720); uuids without a manifest entry still enter
    # `keep` (harmless — the filter below drops them) exactly as before
    keep = copy(keep)
    worklist = collect(keep)
    while !isempty(worklist)
        uuid = pop!(worklist)
        entry = get(manifest, uuid, nothing)
        entry === nothing && continue
        for dep_uuid in values(entry.deps)
            dep_uuid in keep && continue
            push!(keep, dep_uuid)
            push!(worklist, dep_uuid)
        end
    end
    return with_manifest(manifest; deps = Dict(uuid => entry for (uuid, entry) in manifest.deps if uuid in keep))
end

##################
# Tiered resolve #
##################

function targeted_resolve(
        env::Environment, registries::Vector{RegistryInstance}, nodes::Vector{Node},
        preserve::PreserveLevel, julia_version, config::Config;
        preferred_versions::Dict{UUID, VersionNumber} = Dict{UUID, VersionNumber}(),
        fetcher = nothing,
    )
    if preserve == PRESERVE_ALL || preserve == PRESERVE_ALL_INSTALLED
        nodes = load_all_deps(env, nodes; preserve)
    else
        nodes = load_direct_deps(env, nodes; preserve)
    end
    installed_only = preserve == PRESERVE_ALL_INSTALLED || config.offline
    return resolve_versions(env, registries, nodes, julia_version, installed_only, config, preferred_versions; fetcher)
end

function tiered_resolve(
        env::Environment, registries::Vector{RegistryInstance}, nodes::Vector{Node},
        julia_version, try_all_installed::Bool, config::Config;
        preferred_versions::Dict{UUID, VersionNumber} = Dict{UUID, VersionNumber}(),
        fetcher = nothing,
    )
    if try_all_installed
        try
            @debug "tiered_resolve: trying PRESERVE_ALL_INSTALLED"
            return targeted_resolve(env, registries, copy.(nodes), PRESERVE_ALL_INSTALLED, julia_version, config; preferred_versions, fetcher)
        catch err
            err isa Resolve.ResolverError || rethrow()
        end
    end
    try
        @debug "tiered_resolve: trying PRESERVE_ALL"
        return targeted_resolve(env, registries, copy.(nodes), PRESERVE_ALL, julia_version, config; preferred_versions, fetcher)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try
        @debug "tiered_resolve: trying PRESERVE_DIRECT"
        return targeted_resolve(env, registries, copy.(nodes), PRESERVE_DIRECT, julia_version, config; preferred_versions, fetcher)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try
        @debug "tiered_resolve: trying PRESERVE_SEMVER"
        return targeted_resolve(env, registries, copy.(nodes), PRESERVE_SEMVER, julia_version, config; preferred_versions, fetcher)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    @debug "tiered_resolve: trying PRESERVE_NONE"
    return targeted_resolve(env, registries, nodes, PRESERVE_NONE, julia_version, config; preferred_versions, fetcher)
end

Base.copy(n::Node) = Node(
    n.name, n.uuid, n.version, n.path, n.repo_url, n.repo_rev,
    n.repo_subdir, n.tree_hash, n.pinned
)

function resolve_with_preserve(
        env::Environment, registries::Vector{RegistryInstance}, nodes::Vector{Node},
        preserve::PreserveLevel, julia_version, config::Config;
        preferred_versions::Dict{UUID, VersionNumber} = Dict{UUID, VersionNumber}(),
        fetcher = nothing,
    )
    return try
        if preserve == PRESERVE_TIERED_INSTALLED
            tiered_resolve(env, registries, nodes, julia_version, true, config; preferred_versions, fetcher)
        elseif preserve == PRESERVE_TIERED
            tiered_resolve(env, registries, nodes, julia_version, false, config; preferred_versions, fetcher)
        else
            targeted_resolve(env, registries, nodes, preserve, julia_version, config; preferred_versions, fetcher)
        end
    catch err
        # a failed resolve involving yanked versions gets the pinned warning
        # block explaining why those versions are gone
        if err isa Resolve.ResolverError
            yanked = Tuple{String, UUID, VersionNumber}[]
            for (uuid, entry) in env.manifest
                EnvFiles.is_registry_tracked(entry) || continue
                v = entry_version(entry)
                v isa VersionNumber || continue
                is_version_yanked(registries, uuid, v) && push!(yanked, (entry.name, uuid, v))
            end
            if !isempty(yanked)
                indent = " "^pkgstyle_indent
                yanked_str = join(("$(indent)   - $(name) [$(string(uuid)[1:8])] $(v)" for (name, uuid, v) in yanked), "\n")
                printpkgstyle(
                    stderr_f(), :Warning,
                    "The following package versions were yanked from their registry and are not resolvable:\n" * yanked_str,
                    color = Base.warn_color(),
                )
            end
        end
        rethrow()
    end
end

####################
# Public planning  #
####################

"A user-level package request: what `add`/`up`/... operate on."
struct PackageRequest
    name::Union{Nothing, String}
    uuid::Union{Nothing, UUID}
    version::Union{Nothing, VersionNumber, VersionSpec, String}
end
PackageRequest(name::String) = PackageRequest(name, nothing, nothing)

function request_version_spec(r::PackageRequest, name = r.name)
    v = r.version
    v === nothing && return VersionSpec()
    v isa VersionNumber && return v
    v isa VersionSpec && return v
    # `v isa String`: the `@version` micro-syntax uses `VersionSpec`'s plain
    # range grammar (deliberately narrower than the `[compat]` semver grammar —
    # no `^`/`~`/`=` operators, matching Pkg). A malformed specifier — a bad
    # operator, garbage, or an empty `pkg@` — must surface as a clean PkgError,
    # not `VersionSpec`'s raw ArgumentError/BoundsError. Mirrors the message the
    # `compat` path gives for the same invalid input (`plan_compat_entry`).
    pkg = name === nothing ? "" : " for package `$name`"
    try
        return VersionSpec(v)
    catch e
        (e isa ArgumentError || e isa BoundsError) || rethrow()
        pkgerror("invalid version specifier \"$v\"$pkg")
    end
end

# name/uuid resolution order: project → manifest → registries → stdlibs
# every name visible to `resolve_request`, for fuzzy suggestions
function available_names(env::Environment, registries::Vector{RegistryInstance})
    names = String[]
    for (_, entry) in env.manifest
        push!(names, entry.name)
    end
    for reg in registries
        for (_, pkg) in Registries.loaded(reg).pkgs
            push!(names, pkg.name)
        end
    end
    return unique!(names)
end

# The pinned "could not be resolved" diagnostic with fuzzy suggestions:
# "Suggestions: Example" appended when something is close.
function unresolved_name_message(name::String, env::Environment, registries::Vector{RegistryInstance})
    return sprint() do io
        print(io, "The following package names could not be resolved:")
        print(io, "\n * $name (not found in project, manifest or registry)")
        all_names_ranked, any_score_gt_thresh = FuzzySorting.fuzzysort(name, available_names(env, registries))
        if any_score_gt_thresh
            println(io)
            prefix = "   Suggestions:"
            printstyled(io, prefix, color = Base.info_color())
            FuzzySorting.printmatches(io, name, all_names_ranked; cols = FuzzySorting._displaysize(stderr)[2] - length(prefix))
        end
    end
end

function resolve_request(env::Environment, registries::Vector{RegistryInstance}, r::PackageRequest)
    name, uuid = r.name, r.uuid
    if uuid === nothing
        name === nothing && pkgerror("package request must have a name or uuid")
        for source in (env.project.deps, env.project.extras, env.project.weakdeps)
            if haskey(source, name)
                uuid = source[name]
                break
            end
        end
        if uuid === nothing
            manifest_matches = UUID[]
            for (u, e) in env.manifest
                e.name == name && push!(manifest_matches, u)
            end
            if length(manifest_matches) == 1
                uuid = manifest_matches[1]
            elseif length(manifest_matches) > 1
                pkgerror("there are multiple packages named `$name` in the manifest, explicitly set the uuid")
            end
        end
        if uuid === nothing
            uuids = UUID[]
            for reg in registries
                append!(uuids, uuids_from_name(reg, name))
            end
            unique!(uuids)
            if length(uuids) == 1
                uuid = uuids[1]
            elseif length(uuids) > 1
                pkgerror("there are multiple registered `$name` packages, explicitly set the uuid")
            end
        end
        if uuid === nothing
            for (u, info) in stdlib_infos()
                if info.name == name
                    uuid = u
                    break
                end
            end
        end
        uuid === nothing && pkgerror(unresolved_name_message(name, env, registries))
    elseif name === nothing
        entry = get(env.manifest, uuid, nothing)
        name = entry !== nothing ? entry.name : registered_name(registries, uuid)
        if name === nothing
            info = get(stdlib_infos(), uuid, nothing)
            name = info === nothing ? nothing : info.name
        end
        name === nothing && pkgerror("cannot find name corresponding to UUID $(uuid) in a registry")
    end
    return name, uuid
end

# A registry-tracked add must name a registered (or stdlib, or already
# path/repo-tracked) package; the wrong-UUID diagnostics are pinned.
function check_registered(env::Environment, registries::Vector{RegistryInstance}, name, uuid::UUID)
    is_stdlib(uuid) && return
    entry = get(env.manifest, uuid, nothing)
    entry !== nothing && !EnvFiles.is_registry_tracked(entry) && return
    any(reg -> haskey(reg, uuid), registries) && return
    msg = "expected package $(err_rep(name, uuid)) to be registered"
    if name !== nothing
        reg_uuid = Pair{String, Vector{UUID}}[]
        for reg in registries
            uuids = uuids_from_name(reg, name)
            isempty(uuids) || push!(reg_uuid, registry_name(reg) => uuids)
        end
        if !isempty(reg_uuid)
            msg *= "\n You may have provided the wrong UUID for package $name.\n Found the following UUIDs for that name:"
            for (reg, uuids) in reg_uuid
                msg *= "\n  - $(join(uuids, ", ")) from registry: $reg"
            end
        end
    end
    pkgerror(msg)
end

# The project [sources] with entries for freshly materialized repos: an
# explicit `add url/rev` must win over a stale hand-written entry during
# planning (the write re-derives [sources] from the manifest anyway).
function add_repo_sources(project::Project, repos::Vector{RepoPackage})
    isempty(repos) && return project.sources
    sources = Dict{String, SourceSpec}(project.sources)
    for r in repos
        sources[r.name] = SourceSpec(nothing, r.url, r.rev, r.subdir)
    end
    return sources
end

# True when `entry`'s manifest version already satisfies the `add` request, so
# the package can be promoted to a direct dep without resolving (Pkg's
# `can_skip_resolve_for_add`): a bare `add` accepts any version, an `@version`
# request must match exactly, a range must contain the current version.
function version_satisfied_by_entry(entry::ManifestEntry, version)
    v = entry_version(entry)
    version isa VersionNumber && return v == version
    version == VersionSpec() && return true
    return v isa VersionNumber && v in version
end

"""
    plan_promote(env, registries, requests; respect_sysimage_versions) ->
        Union{Nothing, Tuple{Environment, Vector{String}}}

Add's already-present fast path. If every request names a package that is
already a registry-tracked, unpinned manifest entry whose version satisfies
the request, return the environment with those packages promoted into direct
`[deps]` (nothing resolved) together with the promoted names. Returns
`nothing` when any request needs resolution — missing from the manifest,
pinned, path/repo-tracked, or a version mismatch — so the caller falls back to
the full resolve.
"""
function plan_promote(
        env::Environment, registries::Vector{RegistryInstance},
        requests::Vector{PackageRequest}; respect_sysimage_versions::Bool = true,
    )
    isempty(requests) && return nothing
    new_deps = Dict{String, UUID}(env.project.deps)
    names = String[]
    for r in requests
        name, uuid = resolve_request(env, registries, r)
        entry = get(env.manifest, uuid, nothing)
        entry === nothing && return nothing
        entry_isfixed(entry) && return nothing          # pinned or path/repo-tracked
        # Turning off sysimage-version respect is an explicit request to
        # return to ordinary resolution. Do not let add's promotion fast path
        # preserve the baked version without consulting the resolver.
        if !respect_sysimage_versions && Base.in_sysimage(Base.PkgId(uuid, name))
            return nothing
        end
        version_satisfied_by_entry(entry, request_version_spec(r, name)) || return nothing
        new_deps[name] = uuid
        push!(names, name)
    end
    # a name promoted to a real dep leaves [weakdeps] (Pkg parity, cf. plan_add)
    added = setdiff(keys(new_deps), keys(env.project.deps))
    weakdeps = Dict{String, UUID}(k => v for (k, v) in env.project.weakdeps if k ∉ added)
    project = with_project(env.project; deps = new_deps, weakdeps)
    promoted = Environment(env.project_file, env.manifest_file, project, env.manifest, env.workspace)
    return promoted, names
end

"What `add` operates on: a registry request or a materialized git source."
const AddTarget = Union{PackageRequest, RepoPackage}

function error_if_in_sysimage(name::String, uuid::UUID, config::Config)
    config.respect_sysimage_versions || return
    pkgid = Base.PkgId(uuid, name)
    Base.in_sysimage(pkgid) || return
    pkgerror(
        "Tried to develop or add by URL package $pkgid which is already in the sysimage, " *
            "use `VibePkg.respect_sysimage_versions(false)` to disable this check."
    )
end

# seed the resolve node (and the new direct dep) for one add target
function add_target_node!(
        nodes::Vector{Node}, new_deps::Dict{String, UUID},
        env::Environment, registries::Vector{RegistryInstance},
        r::PackageRequest, preserve::PreserveLevel,
    )
    name, uuid = resolve_request(env, registries, r)
    if uuid == env.project.uuid
        pkgerror("cannot add package $(err_rep(name, uuid)) to itself")
    end
    check_registered(env, registries, name, uuid)
    version = request_version_spec(r, name)
    # an explicit preserve=all holds an already-resolved package at its
    # manifest version (the request node would otherwise be unconstrained)
    if (preserve == PRESERVE_ALL || preserve == PRESERVE_ALL_INSTALLED) && version == VersionSpec()
        entry = get(env.manifest, uuid, nothing)
        if entry !== nothing && !entry_isfixed(entry) && entry_version(entry) isa VersionNumber
            version = entry_version(entry)
        end
    end
    push!(nodes, Node(; name, uuid, version))
    new_deps[name] = uuid
    return
end

function add_target_node!(
        nodes::Vector{Node}, new_deps::Dict{String, UUID},
        env::Environment, ::Vector{RegistryInstance},
        r::RepoPackage, ::PreserveLevel,
    )
    if r.uuid == env.project.uuid
        pkgerror("cannot add package $(err_rep(r.name, r.uuid)) to itself")
    end
    push!(
        nodes, Node(;
            name = r.name, uuid = r.uuid, version = VersionSpec(),
            repo_url = r.url, repo_rev = r.rev, repo_subdir = r.subdir,
            tree_hash = r.tree_hash,
        )
    )
    new_deps[r.name] = r.uuid
    return
end

"""
    plan_add(env, registries, config, targets; preserve, julia_version) -> Environment

Compute the environment resulting from adding `targets::Vector{<:AddTarget}`
as direct dependencies: a `PackageRequest` becomes registry-tracked, a
materialized `RepoPackage` repo-tracked (`Git.materialize_repo_package!`
runs first). Pure: nothing is written or downloaded.
"""
function plan_add(
        env::Environment, registries::Vector{RegistryInstance}, config::Config,
        targets::Vector{<:AddTarget};
        preserve::PreserveLevel = default_preserve(), julia_version = VERSION,
        preferred_versions::Dict{UUID, VersionNumber} = Dict{UUID, VersionNumber}(),
        fetcher = nothing,
    )
    isempty(targets) && pkgerror("no packages specified")
    nodes = Node[]
    new_deps = Dict{String, UUID}(env.project.deps)
    for t in targets
        t isa RepoPackage && error_if_in_sysimage(t.name, t.uuid, config)
        add_target_node!(nodes, new_deps, env, registries, t, preserve)
    end
    repos = RepoPackage[t for t in targets if t isa RepoPackage]
    # a name added as a real dep is promoted out of [weakdeps] (Pkg parity)
    added = setdiff(keys(new_deps), keys(env.project.deps))
    weakdeps = Dict{String, UUID}(k => v for (k, v) in env.project.weakdeps if k ∉ added)
    project = with_project(env.project; deps = new_deps, weakdeps, sources = add_repo_sources(env.project, repos))
    env′ = Environment(env.project_file, env.manifest_file, project, env.manifest, env.workspace)

    resolved, deps_map = resolve_with_preserve(env′, registries, nodes, preserve, julia_version, config; preferred_versions, fetcher)
    manifest = build_manifest(env′, resolved, deps_map, julia_version, registries)
    return Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
end

"""
    plan_rm(env, names; mode = :project) -> Environment

Remove dependencies. `:project` mode removes direct dependencies and prunes
the now-unreachable manifest closure; `:manifest` mode removes the packages
and every package that (transitively) depends on them.
"""
# manifest-mode rm: drop the requested packages plus their reverse-dependency
# closure from `new_deps` and the manifest. A standalone function so `targets`
# is an unconditional local (a conditionally-assigned capture would box).
function rm_manifest!(manifest, new_deps, requests)
    targets = Set{UUID}()
    for r in requests
        found = false
        for (uuid, entry) in manifest
            if (r.uuid !== nothing && uuid == r.uuid) || (r.name !== nothing && entry.name == r.name)
                push!(targets, uuid)
                found = true
            end
        end
        found || @warn("`$(something(r.name, r.uuid))` not in manifest, ignoring")
    end
    # reverse-dependency closure as a worklist BFS over a dependents map
    # built once — a manifest-rescanning fixpoint is quadratic (Pkg.jl#4720)
    dependents = manifest_dependents_map(manifest)
    worklist = collect(targets)
    while !isempty(worklist)
        uuid = pop!(worklist)
        for dependent in get(dependents, uuid, UUID[])
            dependent in targets && continue
            push!(targets, dependent)
            push!(worklist, dependent)
        end
    end
    filter!(p -> !(p.second in targets), new_deps)
    return with_manifest(
        manifest;
        deps = Dict(uuid => e for (uuid, e) in manifest.deps if !(uuid in targets)),
    )
end

function plan_rm(env::Environment, requests::Vector{PackageRequest}; mode::Symbol = :project)
    isempty(requests) && pkgerror("rm requires at least one package")
    new_deps = Dict{String, UUID}(env.project.deps)
    manifest = env.manifest
    if mode === :project
        for r in requests
            name = r.name
            if name === nothing && r.uuid !== nothing
                idx = findfirst(p -> p.second == r.uuid, collect(new_deps))
                name = idx === nothing ? nothing : collect(new_deps)[idx].first
            end
            if name === nothing || !haskey(new_deps, name)
                # Pkg parity: unknown packages are skipped with a warning
                @warn("`$(something(r.name, r.uuid))` not in project, ignoring")
                continue
            end
            delete!(new_deps, name)
        end
        manifest = prune_manifest(manifest, Set{UUID}(values(new_deps)))
    elseif mode === :manifest
        manifest = rm_manifest!(manifest, new_deps, requests)
    else
        pkgerror("unknown rm mode `$mode`")
    end
    # Pkg parity: compat/sources/targets entries only survive for remaining
    # direct deps (or extras/weakdeps); `julia` is an implicit direct dep
    compat = Dict{String, EnvFiles.Compat}(
        name => c for (name, c) in env.project.compat if
            name == "julia" || haskey(new_deps, name) ||
            haskey(env.project.extras, name) || haskey(env.project.weakdeps, name)
    )
    sources = Dict{String, SourceSpec}(
        name => src for (name, src) in env.project.sources if
            haskey(new_deps, name) || haskey(env.project.extras, name) ||
            haskey(env.project.weakdeps, name)
    )
    targets = Dict{String, Vector{String}}()
    for (target, target_deps) in env.project.targets
        remaining = filter(d -> haskey(new_deps, d) || haskey(env.project.extras, d), target_deps)
        isempty(remaining) || (targets[target] = remaining)
    end
    project = with_project(env.project; deps = new_deps, compat, sources, targets)
    new_env = Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
    manifest = with_manifest(manifest; project_hash = resolve_hash(new_env))
    return Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
end

"""
    plan_resolve(env, registries, config; julia_version) -> Environment

Reconcile the manifest with the project without moving anything movable
(`Pkg.resolve` semantics: everything currently in the manifest is preserved
at its version; missing things are filled in).
"""
function plan_resolve(
        env::Environment, registries::Vector{RegistryInstance}, config::Config;
        julia_version = VERSION, fetcher = nothing,
    )
    resolved, deps_map = resolve_with_preserve(env, registries, Node[], PRESERVE_ALL, julia_version, config; fetcher)
    manifest = build_manifest(env, resolved, deps_map, julia_version, registries)
    return Environment(env.project_file, env.manifest_file, env.project, manifest, env.workspace)
end

"""
    plan_develop(env, registries, config, path; julia_version) -> Environment

Track the package at a local `path` (explicit-path form; by-name cloning
needs git support). The path is stored as given:
absolute stays absolute, relative is interpreted against the project.
"""
plan_develop(
    env::Environment, registries::Vector{RegistryInstance}, config::Config,
    path::String; kwargs...,
) = plan_develop(env, registries, config, [path]; kwargs...)

function plan_develop(
        env::Environment, registries::Vector{RegistryInstance}, config::Config,
        paths::Vector{String}; preserve::PreserveLevel = default_preserve(), julia_version = VERSION,
        fetcher = nothing,
    )
    isempty(paths) && pkgerror("no packages specified")
    nodes = Node[]
    new_deps = Dict{String, UUID}(env.project.deps)
    # the develop request must win over a stale [sources] url/rev entry
    # during planning (the write re-derives [sources] from the manifest)
    sources = Dict{String, SourceSpec}(env.project.sources)
    # a name developed as a real dep is promoted out of [weakdeps] (Pkg
    # parity); left in both sections the reader would demote it to weak-only
    # and then reject its [sources] entry
    weakdeps = Dict{String, UUID}(env.project.weakdeps)
    deps_weak = Dict{String, UUID}(env.project.deps_weak)
    for path in paths
        dev_dir = isabspath(path) ? path : normpath(joinpath(dirname(env.project_file), path))
        if !isdir(dev_dir)
            if isfile(dev_dir)
                pkgerror("Dev path `$(dev_dir)` is a file, but a directory is required.")
            else
                pkgerror("Dev path `$(dev_dir)` does not exist.")
            end
        end
        project_file = projectfile_path(dev_dir; strict = true)
        project_file === nothing && pkgerror(
            "could not find project file (Project.toml or JuliaProject.toml) in package at `$path` maybe `subdir` needs to be specified"
        )
        dev_project = read_project(project_file)
        (dev_project.name === nothing || dev_project.uuid === nothing) && pkgerror(
            "expected a `name` and `uuid` entry in project file at `$project_file`"
        )
        name, uuid = dev_project.name, dev_project.uuid
        if uuid == env.project.uuid
            pkgerror("cannot develop package $(err_rep(name, uuid)) into itself")
        end
        error_if_in_sysimage(name, uuid, config)

        # store manifest-relative (or absolute) like the manifest wants it
        node_path = isabspath(path) ? path : relpath(dev_dir, dirname(env.manifest_file))
        push!(nodes, Node(; name, uuid, path = node_path, version = VersionSpec()))

        new_deps[name] = uuid
        sources[name] = SourceSpec(path, nothing, nothing, nothing)
        delete!(weakdeps, name)
        delete!(deps_weak, name)
    end
    project = with_project(env.project; deps = new_deps, weakdeps, deps_weak, sources)
    env′ = Environment(env.project_file, env.manifest_file, project, env.manifest, env.workspace)

    resolved, deps_map = resolve_with_preserve(env′, registries, nodes, preserve, julia_version, config; fetcher)
    manifest = build_manifest(env′, resolved, deps_map, julia_version, registries)
    return Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
end

# UpgradeLevel → resolver seed for a currently-resolved version
function level_spec(version, level::UpgradeLevel)
    version isa VersionNumber || return VersionSpec()
    return if level == UPLEVEL_FIXED
        version
    elseif level == UPLEVEL_PATCH
        VersionSpec(VersionRange(VersionBound(version.major, version.minor), VersionBound(version.major, version.minor)))
    elseif level == UPLEVEL_MINOR
        VersionSpec(VersionRange(VersionBound(version.major), VersionBound(version.major)))
    else
        VersionSpec()
    end
end

"""
    plan_up(env, registries, config, requests; level, preserve, mode, workspace, julia_version) -> Environment

Upgrade: with no requests, every direct dependency may move within `level`
(indirect deps float freely); with requests, only the named packages move at
`level` while everything else holds at `preserve` (default: everything else
stays put). Pinned and path/repo-tracked packages never move.

`mode = :manifest` seeds every manifest package (not just direct
dependencies) at `level` for the whole-environment update. `workspace = true`
includes every workspace member's direct dependencies in the
whole-environment update.
"""
function plan_up(
        env::Environment, registries::Vector{RegistryInstance}, config::Config,
        requests::Vector{PackageRequest} = PackageRequest[];
        level::UpgradeLevel = UPLEVEL_MAJOR,
        preserve::Union{Nothing, PreserveLevel} = nothing,
        mode::Symbol = :project, workspace::Bool = false,
        repos::Vector{RepoPackage} = RepoPackage[],
        julia_version = VERSION, fetcher = nothing,
    )
    mode in (:project, :manifest) || pkgerror("unknown up mode `$mode`")
    nodes = Node[]
    if isempty(requests)
        # whole-environment update: direct deps (project mode) or every
        # manifest package (manifest mode) seed at `level`, nothing else is
        # preserved (indirect deps float)
        targets = Dict{String, UUID}()
        if mode === :manifest
            for (uuid, entry) in env.manifest
                targets[entry.name] = uuid
            end
        else
            merge!(targets, env.project.deps)
            if workspace
                for (_, member) in env.workspace
                    merge!(targets, member.deps)
                end
            end
        end
        for (name, uuid) in targets
            entry = get(env.manifest, uuid, nothing)
            (entry === nothing || entry_isfixed(entry)) && continue
            push!(nodes, Node(; name, uuid, version = level_spec(entry_version(entry), level)))
        end
        effective_preserve = something(preserve, PRESERVE_NONE)
    else
        for r in requests
            name, uuid = resolve_request(env, registries, r)
            entry = get(env.manifest, uuid, nothing)
            entry === nothing && pkgerror("package $(err_rep(name, uuid)) not in the manifest, run `Pkg.add` first")
            entry_isfixed(entry) && continue    # pinned/dev'd never move
            push!(nodes, Node(; name, uuid, version = level_spec(entry_version(entry), level)))
        end
        effective_preserve = something(preserve, PRESERVE_ALL)
    end
    # re-materialized branch-tracked packages ride along at their fresh tree
    # (the effectful fetch happened in the API layer; commit-rev entries are
    # never re-materialized, so they stay put)
    seen = Set{UUID}(n.uuid for n in nodes)
    for r in repos
        r.uuid in seen && continue
        push!(
            nodes, Node(;
                name = r.name, uuid = r.uuid, version = VersionSpec(),
                repo_url = r.url, repo_rev = r.rev, repo_subdir = r.subdir,
                tree_hash = r.tree_hash,
            )
        )
    end
    resolved, deps_map = resolve_with_preserve(env, registries, nodes, effective_preserve, julia_version, config; fetcher)
    manifest = build_manifest(env, resolved, deps_map, julia_version, registries)
    return Environment(env.project_file, env.manifest_file, env.project, manifest, env.workspace)
end

"""
    plan_pin(env, registries, config, requests; julia_version) -> Environment

Pin packages: without a version, at their current state (a dev'd package
stays dev'd and becomes pinned); with a version, the package first returns
to registry tracking at that version, then pins.
"""
function plan_pin(
        env::Environment, registries::Vector{RegistryInstance}, config::Config,
        requests::Vector{PackageRequest}; julia_version = VERSION, fetcher = nothing,
    )
    isempty(requests) && pkgerror("pin requires at least one package")
    nodes = Node[]
    retracked_names = String[]
    for r in requests
        name, uuid = resolve_request(env, registries, r)
        entry = get(env.manifest, uuid, nothing)
        entry === nothing && pkgerror("package $(err_rep(name, uuid)) not found in the manifest, run `Pkg.resolve()` and retry")
        if r.version === nothing
            n = entry_to_node(uuid, entry, entry_version(entry))
            n.pinned = true
        else
            # pin@version implies returning to registry tracking, so the
            # package must be registered somewhere
            if !EnvFiles.is_registry_tracked(entry) && !any(reg -> haskey(reg, uuid), registries)
                pkgerror("unable to pin unregistered package $(err_rep(name, uuid)) to an arbitrary version")
            end
            EnvFiles.is_registry_tracked(entry) || push!(retracked_names, name)
            n = Node(; name, uuid, version = request_version_spec(r, name), pinned = true)
        end
        push!(nodes, n)
    end
    project = drop_sources(env.project, retracked_names)
    env′ = Environment(env.project_file, env.manifest_file, project, env.manifest, env.workspace)
    resolved, deps_map = resolve_with_preserve(env′, registries, nodes, PRESERVE_TIERED, julia_version, config; fetcher)
    manifest = build_manifest(env′, resolved, deps_map, julia_version, registries)
    return Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
end

"remove [sources] entries for the given names (returning to registry tracking)"
function drop_sources(project::Project, names::Vector{String})
    isempty(names) && return project
    any(n -> haskey(project.sources, n), names) || return project
    sources = Dict{String, SourceSpec}(project.sources)
    for n in names
        delete!(sources, n)
    end
    return with_project(project; sources)
end

"""
    plan_free(env, registries, config, requests; julia_version) -> Environment

Free packages: a pinned package is un-pinned in place with
NO resolve; a path/repo-tracked package returns to registry tracking via a
full tiered resolve (erroring if it is not registered). With
`err_if_free = false` (the `free(all_pkgs = true)` path), packages that are
already free are skipped instead of erroring.
"""
function plan_free(
        env::Environment, registries::Vector{RegistryInstance}, config::Config,
        requests::Vector{PackageRequest}; err_if_free::Bool = true, julia_version = VERSION,
        fetcher = nothing,
    )
    isempty(requests) && pkgerror("free requires at least one package")
    unpin_only = UUID[]
    to_resolve = Node[]
    freed_names = String[]
    for r in requests
        name, uuid = resolve_request(env, registries, r)
        entry = get(env.manifest, uuid, nothing)
        entry === nothing && pkgerror("package $(err_rep(name, uuid)) not found in the manifest")
        if entry.tracking isa RegistryTracked
            if !entry.pinned
                err_if_free && pkgerror(
                    "expected package $(err_rep(name, uuid)) to be pinned, tracking a path, or tracking a repository"
                )
                continue
            end
            push!(unpin_only, uuid)
        else
            registered = any(reg -> haskey(reg, uuid), registries)
            registered || pkgerror(
                "unable to free unregistered package $(err_rep(name, uuid))"
            )
            push!(to_resolve, Node(; name, uuid, version = VersionSpec()))
            push!(freed_names, name)
        end
    end

    # the freed packages' [sources] entries must go BEFORE resolving:
    # load_all_deps merges sources onto request nodes, so a stale url/rev
    # would re-track the repository we are freeing from
    project = drop_sources(env.project, freed_names)
    manifest = env.manifest
    if !isempty(unpin_only)
        # un-pin in place, nothing else changes
        entries = Dict{UUID, ManifestEntry}(manifest.deps)
        for uuid in unpin_only
            entries[uuid] = EnvFiles.with_entry(entries[uuid]; pinned = false)
        end
        manifest = with_manifest(manifest; deps = entries)
    end
    if !isempty(to_resolve)
        env′ = Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
        resolved, deps_map = resolve_with_preserve(env′, registries, to_resolve, PRESERVE_TIERED, julia_version, config; fetcher)
        manifest = build_manifest(env′, resolved, deps_map, julia_version, registries)
    end
    return Environment(env.project_file, env.manifest_file, project, manifest, env.workspace)
end

"the entry-edit half of `plan_compat`: validate and set/remove, no resolve"
function plan_compat_entry(env::Environment, name::String, compat_str::Union{Nothing, String})
    if name != "julia" && !haskey(env.project.deps, name) && !haskey(env.project.weakdeps, name) &&
            !haskey(env.project.extras, name) && !haskey(env.project.deps_weak, name)
        pkgerror("package `$name` is not a dependency of the project and cannot have a compat entry")
    end
    compat = Dict{String, EnvFiles.Compat}(env.project.compat)
    if compat_str === nothing || isempty(strip(compat_str))
        delete!(compat, name)
    else
        spec = semver_spec(compat_str, throw = false)
        spec === nothing && pkgerror("invalid version specifier \"$compat_str\" for package `$name`")
        compat[name] = EnvFiles.Compat(spec, compat_str)
    end
    project = with_project(env.project; compat)
    return Environment(env.project_file, env.manifest_file, project, env.manifest, env.workspace)
end

"""
    plan_compat(env, registries, config, name, compat; julia_version) -> Environment

Set (or with `nothing`, remove) the `[compat]` entry for `name`, then
reconcile the manifest (`Pkg.compat` runs an immediate resolve).
"""
function plan_compat(
        env::Environment, registries::Vector{RegistryInstance}, config::Config,
        name::String, compat_str::Union{Nothing, String}; julia_version = VERSION,
        fetcher = nothing,
    )
    env′ = plan_compat_entry(env, name, compat_str)
    # Pkg.compat semantics: a compat entry conflicting with the current
    # resolution does NOT downgrade automatically — the user is told to
    # update. The plan being pure means nothing was changed on failure.
    return try
        plan_resolve(env′, registries, config; julia_version, fetcher)
    catch err
        err isa Resolve.ResolverError || rethrow()
        pkgerror(
            "Could not resolve the environment with the new compat entry `$name = $(repr(compat_str))`:\n" *
                sprint(showerror, err) *
                "\nSuggestion: Call `update` to resolve to the latest compatible versions, or relax the compat entry."
        )
    end
end

end # module
