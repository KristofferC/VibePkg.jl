# The depot stack and its on-disk layout.
# All depots are searched for reads; only the first depot is written.
# A DepotStack is snapshotted from Base.DEPOT_PATH when an operation starts,
# so one operation sees one consistent stack.

module Depots

using Base: SHA1, UUID
using Dates: Dates, now
using TOML: TOML
using FileWatching: mkpidlock

using ..Errors: pkgerror
using ..Utils: atomic_toml_write

export DepotStack, depot_stack, depots, depots1, logdir,
    packages_dir, clones_dir, registries_dir, artifacts_dir,
    scratchspaces_dir, environments_dir, servers_dir, bin_dir,
    find_installed, log_usage, log_scratch_usage, atomic_toml_write

struct DepotStack
    paths::Vector{String}
end

depot_stack(paths::Vector{String} = Base.DEPOT_PATH) = DepotStack(copy(paths))

depots(d::DepotStack) = d.paths
function depots1(d::DepotStack)
    isempty(d.paths) && pkgerror("no depots found in DEPOT_PATH!")
    return d.paths[1]
end

# per-depot layout
packages_dir(depot::String) = joinpath(depot, "packages")
clones_dir(depot::String) = joinpath(depot, "clones")
registries_dir(depot::String) = joinpath(depot, "registries")
artifacts_dir(depot::String) = joinpath(depot, "artifacts")
scratchspaces_dir(depot::String) = joinpath(depot, "scratchspaces")
environments_dir(depot::String) = joinpath(depot, "environments")
servers_dir(depot::String) = joinpath(depot, "servers")
bin_dir(depot::String) = joinpath(depot, "bin")
logdir(depot::String) = joinpath(depot, "logs")

logdir(d::DepotStack) = logdir(depots1(d))

"""
    find_installed(d, name, uuid, tree_hash) -> (path, installed::Bool)

Locate an installed package tree across the depot stack, probing the current
5-character slug and the legacy 4-character slug (shared contract with
`Base.version_slug`). If not found anywhere, returns the canonical install
path in the first depot with `installed = false`.
"""
function find_installed(d::DepotStack, name::String, uuid::UUID, tree_hash::SHA1)
    slug_default = Base.version_slug(uuid, tree_hash)
    for depot in depots(d)
        for slug in (slug_default, Base.version_slug(uuid, tree_hash, 4))
            path = abspath(packages_dir(depot), name, slug)
            isdir(path) && return path, true
        end
    end
    return abspath(packages_dir(depots1(d)), name, slug_default), false
end

"""
    log_usage(d, source_files, usage_filename)

Append usage entries (`[["/abs/path"]] time = <now>`) to
`logs/<usage_filename>` in the first depot, compacting to one max-time entry
per key, under a pidlock. GC's liveness marking depends on these logs:
every environment load and artifact install must log usage.
"""
log_usage(d::DepotStack, source_file::AbstractString, usage_filename::AbstractString) =
    log_usage(d, [source_file], usage_filename)

function log_usage(d::DepotStack, source_files, usage_filename::AbstractString)
    # Don't record ghost usage
    source_files = filter(isfile, source_files)
    isempty(source_files) && return

    dir = logdir(d)
    !ispath(dir) && mkpath(dir)

    usage_file = joinpath(dir, usage_filename)
    timestamp = now()

    mkpidlock(usage_file * ".pid", stale_age = 3) do
        usage = if isfile(usage_file)
            try
                TOML.parsefile(usage_file)
            catch err
                @warn "Failed to parse usage file `$usage_file`, ignoring." err
                Dict{String, Any}()
            end
        else
            Dict{String, Any}()
        end

        # record new usage
        for source_file in source_files
            usage[source_file] = [Dict("time" => timestamp)]
        end

        # keep only latest usage info per key; a pre-existing key may have any
        # shape (foreign writers, torn writes) — treat malformed as used now
        for k in keys(usage)
            entries = usage[k]
            times = Dates.DateTime[]
            if entries isa Vector
                for e in entries
                    e isa AbstractDict || continue
                    t = get(e, "time", nothing)
                    t isa Union{Dates.Date, Dates.DateTime} && push!(times, Dates.DateTime(t))
                end
            end
            usage[k] = [Dict("time" => isempty(times) ? timestamp : maximum(times))]
        end

        try
            atomic_toml_write(usage_file, usage, sorted = true)
        catch err
            @error "Failed to write valid usage file `$usage_file`" exception = err
        end
    end
    return
end

"""
    log_scratch_usage(d, scratch_dir, parent_project)

Record that the scratchspace at `scratch_dir` is used by `parent_project`,
in `logs/scratch_usage.toml` of the first depot. GC keeps a scratchspace
only while one of its recorded `parent_projects` files still exists, so —
unlike [`log_usage`](@ref) — entries are keyed by the scratchspace path and
`parent_projects` must be carried (and preserved for co-resident entries)
through compaction.
"""
function log_scratch_usage(d::DepotStack, scratch_dir::AbstractString, parent_project::AbstractString)
    dir = logdir(d)
    !ispath(dir) && mkpath(dir)

    usage_file = joinpath(dir, "scratch_usage.toml")
    timestamp = now()

    mkpidlock(usage_file * ".pid", stale_age = 3) do
        usage = if isfile(usage_file)
            try
                TOML.parsefile(usage_file)
            catch err
                @warn "Failed to parse usage file `$usage_file`, ignoring." err
                Dict{String, Any}()
            end
        else
            Dict{String, Any}()
        end

        # record new usage (append; compaction below merges)
        prev = get(usage, scratch_dir, nothing)
        entries = prev isa Vector ? prev : Any[]
        push!(entries, Dict{String, Any}("time" => timestamp, "parent_projects" => [String(parent_project)]))
        usage[String(scratch_dir)] = entries

        # keep one entry per key: the latest time and the union of
        # parent_projects — GC's liveness key, which must never be dropped
        for k in keys(usage)
            entries = usage[k]
            times = Dates.DateTime[]
            parents = String[]
            if entries isa Vector
                for e in entries
                    e isa AbstractDict || continue
                    t = get(e, "time", nothing)
                    t isa Union{Dates.Date, Dates.DateTime} && push!(times, Dates.DateTime(t))
                    pps = get(e, "parent_projects", nothing)
                    if pps isa Vector
                        for p in pps
                            p isa String && push!(parents, p)
                        end
                    end
                end
            end
            keep = Dict{String, Any}("time" => isempty(times) ? timestamp : maximum(times))
            isempty(parents) || (keep["parent_projects"] = unique!(parents))
            usage[k] = [keep]
        end

        try
            atomic_toml_write(usage_file, usage, sorted = true)
        catch err
            @error "Failed to write valid usage file `$usage_file`" exception = err
        end
    end
    return
end

end # module
