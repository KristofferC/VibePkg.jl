# Rendering: every user-visible output format lives here so
# byte-compat with Pkg's pinned strings is auditable in one place.
#
# Shared output primitives live in Utils; this module owns semantic rendering
# of package-manager values.

module Display

using Base: UUID

using ..Errors: pkgerror
using ..Utils: printpkgstyle, pathrepr
using ..Stdlibs: is_stdlib
using ..Depots: DepotStack, find_installed
using ..EnvFiles
using ..EnvFiles: ManifestEntry, entry_version, entry_path, entry_repo_url,
    entry_repo_rev, is_path_tracked, is_repo_tracked, is_registry_tracked
using ..Registries
using ..Registries: RegistryInstance
using ..Environments: Environment, get_compat

export printpkgstyle, pathrepr, print_env_diff, print_status, print_compat

uuid_prefix(uuid::UUID) = string("[", string(uuid)[1:8], "] ")

function describe(entry::ManifestEntry)
    v = entry_version(entry)
    desc = v === nothing ? "" : "v$v"
    if is_path_tracked(entry)
        desc *= " `$(entry_path(entry))`"
    elseif is_repo_tracked(entry)
        rev = entry_repo_rev(entry)
        desc *= " `$(entry_repo_url(entry))$(rev === nothing ? "" : "#" * rev)`"
    end
    entry.pinned && (desc *= " ⚲")
    return String(strip(desc))
end

# One diff body in Pkg's format: `+ Name v1.2.3`. The caller prints the
# gutter and gray uuid prefix; only the change body carries the diff color.
function print_diff_body(io::IO, old::Union{Nothing, ManifestEntry}, new::Union{Nothing, ManifestEntry})
    if old === nothing && new !== nothing
        glyph, color, body = "+", :light_green, string(new.name, " ", describe(new))
    elseif old !== nothing && new === nothing
        glyph, color, body = "-", :light_red, string(old.name, " ", describe(old))
    elseif old !== nothing && new !== nothing && (old.tracking != new.tracking || old.pinned != new.pinned)
        vold, vnew = entry_version(old), entry_version(new)
        glyph, color = if vold !== nothing && vnew !== nothing && vnew > vold
            "↑", :light_yellow
        elseif vold !== nothing && vnew !== nothing && vnew < vold
            "↓", :light_magenta
        else
            "~", :light_yellow
        end
        body = string(new.name, " ", describe(old), " ⇒ ", describe(new))
    else
        return
    end
    printstyled(io, glyph, " ", body; color)
    return
end

changed(old, new) = old === nothing || new === nothing ||
    old.tracking != new.tracking || old.pinned != new.pinned

# Pkg parity (`Operations.print_status`): regular packages sort first, then
# _jlls, then stdlibs, alphabetically within each group.
function change_order(x::Tuple)
    uuid, old, new = x
    entry = new !== nothing ? new : old
    name = entry === nothing ? "" : entry.name
    return (is_stdlib(uuid), endswith(name, "_jll"), name, uuid)
end

# The Info/Warning footer block Pkg prints under status and diff output.
function print_gutter_footers(
        io::IO; not_downloaded::Bool = false, upgradable::Bool = false,
        blocked::Bool = false, yanked::Bool = false, deprecated_seen::Bool = false,
        manifest_mode::Bool = false, glyph_footers::Bool = true, deprecated_mode::Bool = false,
    )
    not_downloaded && printpkgstyle(
        io, :Info, "Packages marked with → are not downloaded, use `instantiate` to download";
        color = Base.info_color()
    )
    tipend = manifest_mode ? " -m" : ""
    if glyph_footers
        tip = " To see why use `status --outdated$tipend`"
        if upgradable && !blocked
            printpkgstyle(
                io, :Info, "Packages marked with ⌃ have new versions available and may be upgradable.";
                color = Base.info_color()
            )
        elseif blocked && !upgradable
            printpkgstyle(
                io, :Info, "Packages marked with ⌅ have new versions available but compatibility constraints restrict them from upgrading.$tip";
                color = Base.info_color()
            )
        elseif upgradable && blocked
            printpkgstyle(
                io, :Info, "Packages marked with ⌃ and ⌅ have new versions available. Those with ⌃ may be upgradable, but those with ⌅ are restricted by compatibility constraints from upgrading.$tip";
                color = Base.info_color()
            )
        end
    end
    yanked && printpkgstyle(
        io, :Warning, "Package versions marked with [yanked] have been pulled from their registry. It is recommended to update them to resolve a valid version.";
        color = Base.warn_color()
    )
    deprecated_seen && !deprecated_mode && printpkgstyle(
        io, :Info, "Packages marked with [deprecated] are no longer maintained. Use `status --deprecated$tipend` to see more information.";
        color = Base.info_color()
    )
    return
end

# Diff row rendering shared by after-op updates and `status --diff`. Pkg
# routes both through `print_status`, so diff lines carry the same `→`/`⌃`/`⌅`
# gutter, `[yanked]`/`[deprecated]`/loaded annotations, and footers as status;
# the `⌃`/`⌅` split follows `status_compat_info` (`⌅` when anything — compat,
# dependents, julia, sysimage — holds the package back).
function print_diff_rows(
        io::IO, env::Environment, changes::Vector{Tuple{UUID, Any, Any}};
        registries::Vector{RegistryInstance} = RegistryInstance[],
        depots::Union{Nothing, DepotStack} = nothing,
        manifest_mode::Bool = false, glyph_footers::Bool = true,
    )
    sort!(changes; by = change_order)
    rows = Tuple{UUID, Any, Any, Union{Nothing, String}, Bool, Union{Nothing, Dict{String, Any}}}[]
    dependents = manifest_dependents_map(env.manifest)
    for (uuid, old, new) in changes
        (old === nothing && new === nothing) && continue
        cinfo = (new === nothing || is_stdlib(uuid) || isempty(registries)) ? nothing :
            status_compat_info(env, uuid, new, registries; dependents)
        glyph = if cinfo === nothing || is_repo_tracked(new) || is_path_tracked(new)
            nothing
        else
            isempty(cinfo[1]) ? "⌃" : "⌅"
        end
        downloaded = new === nothing || depots === nothing || entry_downloaded(env, uuid, new, depots)
        dep_info = (new === nothing || isempty(registries)) ? nothing :
            Registries.deprecation_info(registries, uuid)
        push!(rows, (uuid, old, new, glyph, downloaded, dep_info))
    end
    lpadding = any(r -> !r[5] && r[4] !== nothing, rows) ? 3 : 2
    saw_not_downloaded = saw_upgradable = saw_blocked = saw_yanked = saw_deprecated = false
    for (uuid, old, new, glyph, downloaded, dep_info) in rows
        saw_not_downloaded |= !downloaded
        saw_upgradable |= glyph == "⌃"
        saw_blocked |= glyph == "⌅"
        pad = 0
        if !downloaded
            printstyled(io, "→"; color = Base.error_color()); pad += 1
        elseif lpadding > 2
            print(io, " "); pad += 1
        end
        if glyph == "⌃"
            printstyled(io, "⌃"; color = :green); pad += 1
        elseif glyph == "⌅"
            printstyled(io, "⌅"; color = Base.warn_color()); pad += 1
        end
        print(io, " "^(lpadding - pad))
        printstyled(io, uuid_prefix(uuid); color = :light_black)
        print_diff_body(io, old, new)
        entry = new !== nothing ? new : old
        v = entry_version(entry)
        if !isempty(registries) && v isa VersionNumber && is_registry_tracked(entry) &&
                Registries.is_version_yanked(registries, uuid, v)
            printstyled(io, " [yanked]"; color = :yellow)
            saw_yanked = true
        end
        if dep_info !== nothing
            printstyled(io, " [deprecated]"; color = :yellow)
            saw_deprecated = true
        end
        print_loaded_annotation(io, uuid, entry)
        println(io)
    end
    print_gutter_footers(
        io; not_downloaded = saw_not_downloaded, upgradable = saw_upgradable,
        blocked = saw_blocked, yanked = saw_yanked, deprecated_seen = saw_deprecated,
        manifest_mode, glyph_footers,
    )
    return
end

"""
    print_env_diff(io, old_env, new_env; registries, depots)

The `Updating`/`No packages added...` blocks shown after mutating
operations: the Project.toml diff covers direct deps, the Manifest.toml diff
everything. With registries/depots available, rows carry Pkg's `→`/`⌃`/`⌅`
gutter; the `⌃`/`⌅` footers follow the manifest section only (Pkg's
combined mode).
"""
function print_env_diff(
        io::IO, old_env::Environment, new_env::Environment;
        registries::Vector{RegistryInstance} = RegistryInstance[],
        depots::Union{Nothing, DepotStack} = nothing,
    )
    # project diff: direct deps only
    old_direct = Set{UUID}(values(old_env.project.deps))
    new_direct = Set{UUID}(values(new_env.project.deps))
    project_changes = Tuple{UUID, Any, Any}[]
    for uuid in union(old_direct, new_direct)
        old = uuid in old_direct ? get(old_env.manifest, uuid, nothing) : nothing
        new = uuid in new_direct ? get(new_env.manifest, uuid, nothing) : nothing
        (uuid in old_direct && uuid in new_direct && !changed(old, new)) && continue
        push!(project_changes, (uuid, old, new))
    end
    if !isempty(project_changes)
        printpkgstyle(io, :Updating, pathrepr(new_env.project_file))
        print_diff_rows(io, new_env, project_changes; registries, depots, glyph_footers = false)
    end

    manifest_changes = Tuple{UUID, Any, Any}[]
    for uuid in union(keys(old_env.manifest.deps), keys(new_env.manifest.deps))
        old = get(old_env.manifest, uuid, nothing)
        new = get(new_env.manifest, uuid, nothing)
        changed(old, new) || continue
        push!(manifest_changes, (uuid, old, new))
    end
    if !isempty(manifest_changes)
        printpkgstyle(io, :Updating, pathrepr(new_env.manifest_file))
        print_diff_rows(io, new_env, manifest_changes; registries, depots, manifest_mode = true)
    end
    if isempty(project_changes) && isempty(manifest_changes)
        printpkgstyle(io, :Updating, pathrepr(new_env.project_file))
        println(io, "  No packages added to or removed from ", pathrepr(new_env.project_file))
        println(io, "  No packages added to or removed from ", pathrepr(new_env.manifest_file))
    end
    return
end

get_compat_str(p::Project, name::String) =
    haskey(p.compat, name) ? p.compat[name].str : nothing

function compat_line(io, pkg, uuid, compat_str, longest_dep_len; indent = "  ")
    iob = IOBuffer()
    ioc = IOContext(iob, :color => get(io, :color, false)::Bool)
    if isnothing(uuid)
        print(ioc, "$indent           ")
    else
        printstyled(ioc, "$indent[", string(uuid)[1:8], "] "; color = :light_black)
    end
    print(ioc, rpad(pkg, longest_dep_len))
    if isnothing(compat_str)
        printstyled(ioc, " none"; color = :light_black)
    else
        print(ioc, " ", compat_str)
    end
    return String(take!(iob))
end

"""
    print_compat(io, env, names = String[])

`Pkg.compat`/`status --compat` view: the `[compat]` entry (or `none`) for
julia and every direct dependency, or just `names` when given.
"""
function print_compat(io::IO, env::Environment, names::Vector{String} = String[])
    printpkgstyle(io, :Compat, pathrepr(env.project_file))
    pkgs = isempty(names) ? env.project.deps : filter(p -> first(p) in names, env.project.deps)
    add_julia = isempty(names) || "julia" in names
    longest_dep_len = isempty(pkgs) ? length("julia") : max(reduce(max, map(length, collect(keys(pkgs)))), length("julia"))
    if add_julia
        println(io, compat_line(io, "julia", nothing, get_compat_str(env.project, "julia"), longest_dep_len))
    end
    for (dep, uuid) in pkgs
        println(io, compat_line(io, dep, uuid, get_compat_str(env.project, dep), longest_dep_len))
    end
    return
end

# extension display data: (name, loaded) for the extension and each trigger
struct ExtInfo
    ext::Tuple{String, Bool}
    weakdeps::Vector{Tuple{String, Bool}}
end

function status_ext_info(uuid::UUID, entry::ManifestEntry)
    isempty(entry.exts) && return nothing
    v = ExtInfo[]
    for (ext, extdeps) in entry.exts
        extdeps isa String && (extdeps = String[extdeps])
        # `get_extension` returns nothing for stdlibs loaded via `require_stdlib`
        ext_loaded = Base.get_extension(Base.PkgId(uuid, entry.name), Symbol(ext)) !== nothing
        extdeps_info = Tuple{String, Bool}[]
        for extdep in extdeps
            if !(haskey(entry.weakdeps, extdep) || haskey(entry.deps, extdep))
                pkgerror(
                    "$(entry.name) has a malformed Project.toml, ",
                    "the extension package $extdep is not listed in [weakdeps] or [deps]"
                )
            end
            dep_uuid = get(entry.weakdeps, extdep, nothing)
            dep_uuid === nothing && (dep_uuid = entry.deps[extdep])
            loaded = haskey(Base.loaded_modules, Base.PkgId(dep_uuid, extdep))
            push!(extdeps_info, (extdep, loaded))
        end
        push!(v, ExtInfo((ext, ext_loaded), extdeps_info))
    end
    return isempty(v) ? nothing : v
end

const PKGORIGIN_HAVE_VERSION = :version in fieldnames(Base.PkgOrigin)

# `--outdated` detail: (packages_holding_back, max_version, max_version_in_compat)
# or nothing when the package is current (Pkg's status_compat_info).
# Callers looping over many packages should build `manifest_dependents_map`
# once and pass it as `dependents` — the fallback rebuild here is per-call.
function status_compat_info(
        env::Environment, uuid::UUID, entry::ManifestEntry,
        registries::Vector{RegistryInstance};
        dependents::Union{Nothing, Dict{UUID, Vector{UUID}}} = nothing,
    )
    current = entry_version(entry)
    current isa VersionNumber || return nothing
    packages_holding_back = String[]
    max_version, max_version_in_compat = v"0", v"0"
    compat_spec = get_compat(env, entry.name)
    for reg in registries
        reg_pkg = get(reg, uuid, nothing)
        reg_pkg === nothing && continue
        info = Registries.registry_info(reg, reg_pkg)
        versions = filter(v -> !info.version_info[v].yanked, collect(keys(info.version_info)))
        max_version = max(max_version, maximum(versions; init = v"0"))
        versions_in_compat = filter(in(compat_spec), versions)
        max_version_in_compat = max(max_version_in_compat, maximum(versions_in_compat; init = v"0"))
    end
    max_version == v"0" && return nothing
    current >= max_version && return nothing

    pkgid = Base.PkgId(uuid, entry.name)
    if PKGORIGIN_HAVE_VERSION && Base.in_sysimage(pkgid)
        pkgorigin = get(Base.pkgorigins, pkgid, nothing)
        if pkgorigin !== nothing && current == pkgorigin.version
            return ["sysimage"], max_version, max_version_in_compat
        end
    end

    # held back by the project's own compat
    if current == max_version_in_compat && max_version_in_compat != max_version
        return ["compat"], max_version, max_version_in_compat
    end

    # held back by dependents' compat on us
    dependents === nothing && (dependents = manifest_dependents_map(env.manifest))
    for dep_uuid in get(dependents, uuid, UUID[])
        is_stdlib(dep_uuid) && continue
        dep_entry = get(env.manifest, dep_uuid, nothing)
        dep_entry === nothing && continue
        dv = entry_version(dep_entry)
        dv isa VersionNumber || continue
        for reg in registries
            reg_pkg = get(reg, dep_uuid, nothing)
            reg_pkg === nothing && continue
            info = Registries.registry_info(reg, reg_pkg)
            haskey(info.version_info, dv) || continue   # same precedence rule
            spec = Registries.query_compat_for_version(info, dv, uuid)
            spec === nothing && continue
            if !(max_version in spec)
                push!(packages_holding_back, dep_entry.name)
            end
        end
    end

    # held back by julia compat: only registries that actually ship
    # `max_version` get a vote — compat queries work on compressed version
    # ranges, so a registry lacking the version would otherwise answer for
    # it (typically with `nothing`, i.e. "compatible") using metadata that
    # belongs to a different registry's version
    julia_compatible = false
    for reg in registries
        reg_pkg = get(reg, uuid, nothing)
        reg_pkg === nothing && continue
        info = Registries.registry_info(reg, reg_pkg)
        haskey(info.version_info, max_version) || continue
        spec = Registries.query_compat_for_version(info, max_version, Registries.JULIA_UUID)
        if spec === nothing || VERSION in spec
            julia_compatible = true
        end
    end
    julia_compatible || push!(packages_holding_back, "julia")

    return sort!(unique!(packages_holding_back)), max_version, max_version_in_compat
end

# ` [loaded: …]` when the loaded module differs from the manifest entry
function print_loaded_annotation(io::IO, uuid::UUID, entry::ManifestEntry)
    v = entry_version(entry)
    v === nothing && return
    pkgid = Base.PkgId(uuid, entry.name)
    m = get(Base.loaded_modules, pkgid, nothing)
    m isa Module || return
    loaded_path = pathof(m)
    env_path = Base.locate_package(pkgid)
    (loaded_path === nothing || env_path === nothing || samefile(loaded_path, env_path)) && return
    loaded_version = pkgversion(m)
    if loaded_version !== v
        printstyled(io, " [loaded: v$loaded_version]"; color = :light_yellow)
    else
        loaded_version_str = loaded_version === nothing ? "" : " (v$loaded_version)"
        env_version_str = v === nothing ? "" : " (v$v)"
        printstyled(io, " [loaded: `$loaded_path`$loaded_version_str expected `$env_path`$env_version_str]"; color = :light_yellow)
    end
    return
end

"a package's source tree is present on disk (`→` status marker when not)"
function entry_downloaded(env::Environment, uuid::UUID, entry::ManifestEntry, depots::DepotStack)
    path = entry_path(entry)
    if path !== nothing
        abs = isabspath(path) ? path : normpath(joinpath(dirname(env.manifest_file), path))
        return isdir(abs)
    end
    hash = EnvFiles.entry_tree_hash(entry)
    hash === nothing && return true             # stdlib / hash-less entries
    return find_installed(depots, entry.name, uuid, hash)[2]
end

"""
    print_status(io, env; manifest_mode = false, outdated = false, workspace = false, extensions = false, registries = [], depots = nothing)

`Pkg.status`: direct dependencies (or with `manifest_mode`, every manifest
entry; with `workspace`, the union of every workspace member's direct
dependencies), sorted by name. With registries available, entries with newer
versions get the `⌃`/`⌅` gutter; `outdated` restricts output to those;
`extensions` restricts output to packages with extensions and shows their
tree. With depots available, not-yet-downloaded packages get the `→` gutter.
"""
function print_status(
        io::IO, env::Environment;
        manifest_mode::Bool = false, outdated::Bool = false,
        workspace::Bool = false, extensions::Bool = false, deprecated::Bool = false,
        registries::Vector{RegistryInstance} = RegistryInstance[],
        depots::Union{Nothing, DepotStack} = nothing,
        diff_env::Union{Nothing, Environment} = nothing,
        filter_uuids::Vector{UUID} = UUID[], filter_names::Vector{String} = String[],
    )
    direct = Dict{String, UUID}(env.project.deps)
    if workspace
        for (_, member) in env.workspace
            merge!(direct, member.deps)
        end
    end
    # `status Example`: only matching packages show; in manifest mode a
    # match also brings its direct dependencies along (Pkg parity)
    filtering = !(isempty(filter_uuids) && isempty(filter_names))
    matches(uuid, name) = uuid in filter_uuids || name in filter_names
    function expand_and_filter(pairs, name_of)
        keep = Set{UUID}(first(x) for x in pairs if matches(first(x), name_of(x)))
        if manifest_mode
            for uuid in copy(keep)
                entry = get(env.manifest, uuid, nothing)
                entry === nothing || union!(keep, values(entry.deps))
            end
        end
        return [x for x in pairs if first(x) in keep]
    end
    header_path = pathrepr(manifest_mode ? env.manifest_file : env.project_file)
    if diff_env !== nothing
        # `status --diff`: what changed relative to the git HEAD environment
        changes = Tuple{UUID, Any, Any}[]
        if manifest_mode
            for uuid in union(keys(diff_env.manifest.deps), keys(env.manifest.deps))
                old = get(diff_env.manifest, uuid, nothing)
                new = get(env.manifest, uuid, nothing)
                changed(old, new) || continue
                push!(changes, (uuid, old, new))
            end
        else
            old_direct = Set{UUID}(values(diff_env.project.deps))
            new_direct = Set{UUID}(values(direct))
            for uuid in union(old_direct, new_direct)
                old = uuid in old_direct ? get(diff_env.manifest, uuid, nothing) : nothing
                new = uuid in new_direct ? get(env.manifest, uuid, nothing) : nothing
                (uuid in old_direct && uuid in new_direct && !changed(old, new)) && continue
                push!(changes, (uuid, old, new))
            end
        end
        if filtering
            changes = expand_and_filter(changes, x -> something(x[3], x[2]).name)
        end
        if isempty(changes)
            printpkgstyle(io, Symbol("No Matches"), "in diff for " * header_path)
            return
        end
        printpkgstyle(io, :Diff, header_path)
        print_diff_rows(io, env, changes; registries, depots, manifest_mode, glyph_footers = !outdated)
        return
    end
    if manifest_mode ? isempty(env.manifest.deps) : isempty(direct)
        printpkgstyle(io, :Status, header_path * " (empty " * (manifest_mode ? "manifest" : "project") * ")")
        return
    end
    entries = Tuple{UUID, ManifestEntry}[]
    missing_entries = Tuple{UUID, String}[]   # direct deps absent from the manifest
    if manifest_mode
        append!(entries, (uuid, e) for (uuid, e) in env.manifest)
    else
        for (name, uuid) in direct
            e = get(env.manifest, uuid, nothing)
            e === nothing ? push!(missing_entries, (uuid, name)) : push!(entries, (uuid, e))
        end
    end
    if filtering
        entries = expand_and_filter(entries, x -> x[2].name)
        missing_entries = [x for x in missing_entries if matches(x[1], x[2])]
        if isempty(entries) && isempty(missing_entries)
            printpkgstyle(io, Symbol("No Matches"), "in " * header_path)
            return
        end
    end
    readonly_suffix = env.project.readonly ? " (readonly)" : ""
    printpkgstyle(io, :Status, header_path * readonly_suffix)
    for (uuid, name) in missing_entries
        printstyled(io, "  ", uuid_prefix(uuid), name, "\n"; color = :light_black)
    end
    sort!(entries; by = x -> (is_stdlib(x[1]), endswith(x[2].name, "_jll"), x[2].name, x[1]))
    rows = Tuple{
        UUID, ManifestEntry, Union{Nothing, String}, Bool, Union{Nothing, Dict{String, Any}},
        Union{Nothing, Tuple{Vector{String}, VersionNumber, VersionNumber}},
    }[]
    dependents = manifest_dependents_map(env.manifest)
    for (uuid, e) in entries
        cinfo = (isempty(registries) || is_stdlib(uuid)) ? nothing :
            status_compat_info(env, uuid, e, registries; dependents)
        outdated && cinfo === nothing && continue
        glyph = if cinfo === nothing || is_repo_tracked(e) || is_path_tracked(e) || e.pinned
            nothing
        else
            isempty(cinfo[1]) ? "⌃" : "⌅"
        end
        extensions && status_ext_info(uuid, e) === nothing && continue
        dep_info = isempty(registries) ? nothing : Registries.deprecation_info(registries, uuid)
        deprecated && dep_info === nothing && continue
        downloaded = depots === nothing || entry_downloaded(env, uuid, e, depots)
        push!(rows, (uuid, e, glyph, downloaded, dep_info, cinfo))
    end
    # gutter layout as in Pkg: slot for `→`, slot for `⌃`/`⌅`, space-padded;
    # three columns only when some line needs both icons
    lpadding = any(r -> !r[4] && r[3] !== nothing, rows) ? 3 : 2
    saw_not_downloaded = false
    saw_upgradable = false
    saw_blocked = false
    saw_yanked = false
    saw_deprecated = false
    for (uuid, e, glyph, downloaded, dep_info, cinfo) in rows
        saw_not_downloaded |= !downloaded
        saw_upgradable |= glyph == "⌃"
        saw_blocked |= glyph == "⌅"
        pad = 0
        if !downloaded
            printstyled(io, "→"; color = Base.error_color()); pad += 1
        elseif lpadding > 2
            print(io, " "); pad += 1
        end
        if glyph == "⌃"
            printstyled(io, "⌃"; color = :green); pad += 1
        elseif glyph == "⌅"
            printstyled(io, "⌅"; color = Base.warn_color()); pad += 1
        end
        print(io, " "^(lpadding - pad))
        printstyled(io, uuid_prefix(uuid); color = :light_black)
        print(io, e.name, " ", describe(e))
        v = entry_version(e)
        if !isempty(registries) && v isa VersionNumber && is_registry_tracked(e) &&
                Registries.is_version_yanked(registries, uuid, v)
            printstyled(io, " [yanked]"; color = :yellow)
            saw_yanked = true
        end
        if dep_info !== nothing
            printstyled(io, " [deprecated]"; color = :yellow)
            saw_deprecated = true
            if deprecated
                reason = get(dep_info, "reason", nothing)
                alternative = get(dep_info, "alternative", nothing)
                reason === nothing || printstyled(io, " (reason: ", reason, ")"; color = :yellow)
                alternative === nothing || printstyled(io, " (alternative: ", alternative, ")"; color = :yellow)
            end
        end
        if outdated && cinfo !== nothing
            packages_holding_back, max_version, max_version_compat = cinfo
            if entry_version(e) !== max_version_compat && max_version_compat != max_version
                printstyled(io, " [<v", max_version_compat, "]", color = :light_magenta)
                printstyled(io, ",")
            end
            printstyled(io, " (<v", max_version, ")"; color = Base.warn_color())
            if packages_holding_back == ["compat"]
                printstyled(io, " [compat]"; color = :light_magenta)
            elseif packages_holding_back == ["sysimage"]
                printstyled(io, " [sysimage]"; color = :light_magenta)
            else
                pkg_str = isempty(packages_holding_back) ? "" : string(": ", join(packages_holding_back, ", "))
                printstyled(io, pkg_str; color = Base.warn_color())
            end
        end
        print_loaded_annotation(io, uuid, e)
        if extensions
            extinfo = status_ext_info(uuid, e)
            if extinfo !== nothing
                println(io)
                print_ext_entry(eio, (name, loaded)) =
                    printstyled(eio, name; color = loaded ? :light_green : :light_black)
                for (i, ext) in enumerate(extinfo)
                    sym = i == length(extinfo) ? '└' : '├'
                    print(io, "              ", sym, "─ ")
                    print_ext_entry(io, ext.ext)
                    print(io, " [")
                    join(io, [sprint(print_ext_entry, d; context = io) for d in ext.weakdeps], ", ")
                    print(io, "]")
                    i != length(extinfo) && println(io)
                end
            end
        end
        println(io)
    end
    print_gutter_footers(
        io; not_downloaded = saw_not_downloaded, upgradable = saw_upgradable,
        blocked = saw_blocked, yanked = saw_yanked, deprecated_seen = saw_deprecated,
        manifest_mode, glyph_footers = !outdated, deprecated_mode = deprecated,
    )
    return
end

end # module
