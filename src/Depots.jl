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

export DepotStack, depot_stack, depots, depots1, logdir,
    packages_dir, clones_dir, registries_dir, artifacts_dir,
    scratchspaces_dir, environments_dir, servers_dir, bin_dir,
    find_installed, log_usage, atomic_toml_write

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
            ispath(path) && return path, true
        end
    end
    return abspath(packages_dir(depots1(d)), name, slug_default), false
end

"""
    atomic_toml_write(path, data; kws...)

Write TOML data via a temporary file + rename, preventing torn writes.
"""
function atomic_toml_write(path::String, data; kws...)
    dir = dirname(path)
    isempty(dir) && (dir = pwd())
    temp_path, temp_io = mktemp(dir)
    return try
        TOML.print(temp_io, data; kws...)
        close(temp_io)
        mv(temp_path, path; force = true)
    catch
        close(temp_io)
        rm(temp_path; force = true)
        rethrow()
    end
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

end # module
