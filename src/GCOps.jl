# Garbage collection.
#
# Modern Pkg semantics: no orphan grace period — mark everything reachable
# from the usage logs (manifests and Artifacts.toml files that still exist),
# sweep the rest immediately. Usage logs are filtered to existing files and
# rewritten compacted as part of the run.
#
# Scratchspaces are kept when a usage entry names them and at least one of
# its recorded parent projects still exists (the Scratch.jl protocol).

module GCOps

import Dates
import TOML

using ..Utils: stderr_f
using ..EnvFiles
using ..EnvFiles: entry_tree_hash, entry_repo_url
using ..Depots: DepotStack, depots, depots1, logdir, packages_dir, clones_dir,
    artifacts_dir, scratchspaces_dir, atomic_toml_write
using ..Utils: printpkgstyle, pathrepr
import ..Git

export gc

# The stamp's mtime records the last completed `gc` of a depot; the auto-gc
# throttle (API._auto_gc) runs a collection when it is over a week old.
gc_stamp(depot::String) = joinpath(mkpath(logdir(depot)), "gc.stamp")

# Read a usage log, keep only entries whose key file still exists, rewrite
# it compacted, and return the live keys.
function condense_usage!(usage_file::String)
    isfile(usage_file) || return String[]
    usage = try
        TOML.parsefile(usage_file)
    catch err
        @warn "Failed to parse usage file `$usage_file`, ignoring." err
        return String[]
    end
    # entries may have any shape (foreign writers, torn writes): salvage what
    # matches the schema, treat the rest as freshly used so nothing is swept
    filter!(p -> isfile(p.first) && p.second isa Vector && !isempty(p.second), usage)
    for (k, entries) in usage
        times = Dates.DateTime[]
        parents = String[]
        for e in entries
            e isa AbstractDict || continue
            t = get(e, "time", nothing)
            t isa Union{Dates.Date, Dates.DateTime} && push!(times, Dates.DateTime(t))
            for p in get(e, "parent_projects", String[])
                p isa String && push!(parents, p)
            end
        end
        keep = Dict{String, Any}("time" => isempty(times) ? Dates.now() : maximum(times))
        isempty(parents) || (keep["parent_projects"] = unique!(parents))
        usage[k] = [keep]
    end
    try
        atomic_toml_write(usage_file, usage, sorted = true)
    catch err
        @error "Failed to write valid usage file `$usage_file`" exception = err
    end
    return collect(keys(usage))
end

# Every git-tree-sha1 mentioned in an Artifacts.toml (all platforms).
function artifact_hashes(artifacts_toml::String)
    hashes = String[]
    raw = try
        TOML.parsefile(artifacts_toml)
    catch
        return hashes
    end
    walk(x) = nothing
    function walk(d::Dict)
        h = get(d, "git-tree-sha1", nothing)
        h isa String && push!(hashes, h)
        foreach(walk, values(d))
        return
    end
    walk(v::Vector) = foreach(walk, v)
    walk(raw)
    return hashes
end

function dir_size(path::String)
    size = 0
    for (root, dirs, files) in walkdir(path; onerror = x -> nothing)
        for file in files
            size += try
                lstat(joinpath(root, file)).size
            catch
                0
            end
        end
    end
    return size
end

format_mib(bytes) = string(round(bytes / (1024 * 1024), digits = 3), " MiB")

function sweep!(dir::String, keep::Set{String}; verbose::Bool, io::IO, label::String)
    isdir(dir) || return 0, 0
    deleted = 0
    freed = 0
    for name in readdir(dir)
        name in ("CACHEDIR.TAG", "temp") && continue
        endswith(name, ".pid") && continue
        path = joinpath(dir, name)
        path in keep && continue
        verbose && printpkgstyle(io, :Deleting, pathrepr(path))
        freed += dir_size(path)
        Base.rm(path; force = true, recursive = true)
        deleted += 1
    end
    return deleted, freed
end

"""
    gc(depots; verbose = false, force = false, io)

Mark from the usage logs, sweep unreachable package installs, clones,
artifacts, and scratchspaces of the first depot (`force = true`: all
depots).
"""
function gc(
        d::DepotStack;
        collect_delay = nothing, verbose::Bool = false, force::Bool = false,
        io::IO = stderr_f(),
    )
    collect_delay === nothing ||
        @warn "the `collect_delay` keyword is deprecated and ignored: `gc` deletes unreachable content immediately" maxlog = 1
    gc_depots = force ? depots(d) : [depots1(d)]

    # ——— mark ————————————————————————————————————————————————————————————
    live_manifests = String[]
    live_artifact_tomls = String[]
    scratch_usage = Dict{String, Vector{String}}()   # space path => parent projects
    for depot in gc_depots
        ldir = logdir(depot)
        append!(live_manifests, condense_usage!(joinpath(ldir, "manifest_usage.toml")))
        append!(live_artifact_tomls, condense_usage!(joinpath(ldir, "artifact_usage.toml")))
        scratch_file = joinpath(ldir, "scratch_usage.toml")
        if isfile(scratch_file)
            raw = try
                TOML.parsefile(scratch_file)
            catch
                Dict{String, Any}()
            end
            for (space, entries) in raw
                entries isa Vector || continue
                parents = String[]
                for e in entries
                    e isa AbstractDict || continue
                    for p in get(e, "parent_projects", String[])
                        p isa String && push!(parents, p)
                    end
                end
                scratch_usage[space] = parents
            end
        end
    end

    keep_packages = Set{String}()   # packages/<Name>/<slug> paths
    keep_clones = Set{String}()     # clones/<key> paths
    keep_artifacts = Set{String}()  # artifacts/<hex> paths
    for manifest_file in live_manifests
        manifest = try
            read_manifest(manifest_file)
        catch err
            @warn "Reading manifest file at $manifest_file failed with error" err
            continue
        end
        for (uuid, entry) in manifest
            hash = entry_tree_hash(entry)
            if hash !== nothing
                for depot in depots(d)
                    for slug in (Base.version_slug(uuid, hash), Base.version_slug(uuid, hash, 4))
                        push!(keep_packages, joinpath(packages_dir(depot), entry.name, slug))
                    end
                end
            end
            url = entry_repo_url(entry)
            if url !== nothing
                for depot in depots(d)
                    push!(keep_clones, joinpath(clones_dir(depot), string(uuid)))
                end
                push!(keep_clones, Git.repo_cache_path(d, url))
            end
        end
    end
    for artifacts_toml in live_artifact_tomls
        for hex in artifact_hashes(artifacts_toml)
            for depot in depots(d)
                push!(keep_artifacts, joinpath(artifacts_dir(depot), hex))
            end
        end
    end
    keep_scratch = Set{String}(
        space for (space, parents) in scratch_usage if any(isfile, parents)
    )

    printpkgstyle(io, :Active, "manifest files: $(length(live_manifests)) found")
    if verbose
        for m in live_manifests
            println(io, "        $(pathrepr(m))")
        end
    end
    printpkgstyle(io, :Active, "artifact files: $(length(live_artifact_tomls)) found")
    printpkgstyle(io, :Active, "scratchspaces: $(length(keep_scratch)) found")

    # ——— sweep ———————————————————————————————————————————————————————————
    packages_deleted = artifacts_deleted = repos_deleted = scratch_deleted = 0
    freed = 0
    for depot in gc_depots
        # packages/<Name>/<slug>
        pdir = packages_dir(depot)
        if isdir(pdir)
            for name in readdir(pdir)
                name == "CACHEDIR.TAG" && continue
                name_dir = joinpath(pdir, name)
                isdir(name_dir) || continue
                del, fr = sweep!(name_dir, keep_packages; verbose, io, label = "package")
                packages_deleted += del
                freed += fr
                isdir(name_dir) && isempty(readdir(name_dir)) && Base.rm(name_dir)
            end
        end
        del, fr = sweep!(clones_dir(depot), keep_clones; verbose, io, label = "repo")
        repos_deleted += del
        freed += fr
        del, fr = sweep!(artifacts_dir(depot), keep_artifacts; verbose, io, label = "artifact")
        artifacts_deleted += del
        freed += fr
        sdir = scratchspaces_dir(depot)
        if isdir(sdir)
            for uuid_dir in readdir(sdir; join = true)
                basename(uuid_dir) == "CACHEDIR.TAG" && continue
                isdir(uuid_dir) || continue
                del, fr = sweep!(uuid_dir, keep_scratch; verbose, io, label = "scratchspace")
                scratch_deleted += del
                freed += fr
                isdir(uuid_dir) && isempty(readdir(uuid_dir)) && Base.rm(uuid_dir)
            end
        end
    end

    parts = String[]
    packages_deleted > 0 && push!(parts, "$packages_deleted package installation$(packages_deleted == 1 ? "" : "s")")
    repos_deleted > 0 && push!(parts, "$repos_deleted repo$(repos_deleted == 1 ? "" : "s")")
    artifacts_deleted > 0 && push!(parts, "$artifacts_deleted artifact installation$(artifacts_deleted == 1 ? "" : "s")")
    scratch_deleted > 0 && push!(parts, "$scratch_deleted scratchspace$(scratch_deleted == 1 ? "" : "s")")
    if isempty(parts)
        printpkgstyle(io, :Deleted, "no artifacts, repos, packages or scratchspaces")
    else
        printpkgstyle(io, :Deleted, join(parts, ", ") * " ($(format_mib(freed)))")
    end
    touch(gc_stamp(depots1(d)))
    return nothing
end

end # module
