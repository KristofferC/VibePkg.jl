# The stdlib model.
#
# Three kinds of standard library:
#   - bundled, unversioned in manifests (most stdlibs)
#   - externally versioned (jlls, Tar, ...) — carry versions
#   - "upgradable" ex-stdlibs (DelimitedFiles, Statistics): ordinary packages
#     to the resolver, special-cased only by `is_or_was_stdlib`
#
# Resolution against a julia_version other than the running one requires the
# historical tables (populated externally by HistoricalStdlibVersions.jl into
# STDLIBS_BY_VERSION, same protocol as Pkg). `julia_version === nothing`
# means: treat registered stdlibs as normal packages.

module Stdlibs

using Base: UUID
using TOML: TOML

using ..Errors: pkgerror

export StdlibInfo, stdlib_infos, stdlibs, is_stdlib, is_or_was_stdlib,
    stdlib_version, is_unregistered_stdlib, get_last_stdlibs

struct StdlibInfo
    name::String
    uuid::UUID
    # `nothing` if the stdlib is unversioned (not installable from a registry)
    version::Union{Nothing, VersionNumber}
    deps::Vector{UUID}
    weakdeps::Vector{UUID}
end

const DictStdLibs = Dict{UUID, StdlibInfo}

# Fixed, well-known identities: populated eagerly so consulting the set never
# depends on `stdlib_infos()` having run first.
const UPGRADABLE_STDLIBS = [
    "DelimitedFiles" => UUID("8bb1440f-4735-579b-a4ab-409b98df4dab"),
    "Statistics" => UUID("10745b16-79ce-11e8-11f9-7d13ad32a3b2"),
]
const UPGRADABLE_STDLIBS_UUIDS = Set{UUID}(last.(UPGRADABLE_STDLIBS))

# the precompile workload scrubs mutable module state out of the image;
# restore the eager set contents on every load
__init__() = union!(UPGRADABLE_STDLIBS_UUIDS, last.(UPGRADABLE_STDLIBS))

# Populated by HistoricalStdlibVersions.jl (same protocol as Pkg):
const STDLIBS_BY_VERSION = Pair{VersionNumber, DictStdLibs}[]
const UNREGISTERED_STDLIBS = DictStdLibs()

const STDLIB = Ref{Union{DictStdLibs, Nothing}}(nothing)

function load_stdlib()
    stdlib = DictStdLibs()
    for name in readdir(Sys.STDLIB)
        projfile = nothing
        for candidate in ("JuliaProject.toml", "Project.toml")
            path = joinpath(Sys.STDLIB, name, candidate)
            if isfile(path)
                projfile = path
                break
            end
        end
        projfile === nothing && continue
        project = TOML.parsefile(projfile)
        uuid = get(project, "uuid", nothing)::Union{String, Nothing}
        nothing === uuid && continue
        v_str = get(project, "version", nothing)::Union{String, Nothing}
        version = isnothing(v_str) ? nothing : VersionNumber(v_str)
        any(p -> first(p) == name, UPGRADABLE_STDLIBS) && continue
        deps = UUID.(values(get(project, "deps", Dict{String, Any}())))
        weakdeps = UUID.(values(get(project, "weakdeps", Dict{String, Any}())))
        stdlib[UUID(uuid)] = StdlibInfo(name, UUID(uuid), version, deps, weakdeps)
    end
    return stdlib
end

"Stdlibs of the running julia, scanned lazily from Sys.STDLIB and cached."
function stdlib_infos()
    if STDLIB[] === nothing
        STDLIB[] = load_stdlib()
    end
    return STDLIB[]::DictStdLibs
end

stdlibs() = Dict(uuid => (info.name, info.version) for (uuid, info) in stdlib_infos())

is_stdlib(uuid::UUID) = uuid in keys(stdlib_infos())

"Also true for ex-stdlibs (DelimitedFiles, Statistics)."
function is_or_was_stdlib(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    return is_stdlib(uuid, julia_version) || uuid in UPGRADABLE_STDLIBS_UUIDS
end

function historical_stdlibs_check()
    return if isempty(STDLIBS_BY_VERSION)
        pkgerror("Historical stdlib metadata is unavailable. Load it with `using HistoricalStdlibVersions` before setting julia_version")
    end
end

# Find the stdlib set of the requested julia version. Falls back to
# UNREGISTERED_STDLIBS when no matching entry exists.
function get_last_stdlibs(julia_version::VersionNumber; use_historical_for_current_version = false)
    if !use_historical_for_current_version && julia_version == VERSION
        return stdlib_infos()
    end
    historical_stdlibs_check()
    last_stdlibs = UNREGISTERED_STDLIBS
    last_version = nothing
    for (version, stdlibs) in STDLIBS_BY_VERSION
        if !isnothing(last_version) && last_version > version
            pkgerror("Historical stdlib metadata is out of order at Julia $version after $last_version; versions must be sorted")
        end
        if VersionNumber(julia_version.major, julia_version.minor, julia_version.patch) < version
            break
        end
        last_stdlibs = stdlibs
        last_version = version
    end
    # Serving different patches is safe-ish; different majors/minors is not.
    if last_version !== nothing && (last_version.major != julia_version.major || last_version.minor != julia_version.minor)
        pkgerror("No historical stdlib data matches Julia $julia_version (major.minor $(julia_version.major).$(julia_version.minor))")
    end
    return last_stdlibs
end
# `julia_version === nothing`: treat all registered stdlibs as normal
# packages (get the latest of everything, ignoring julia compat).
function get_last_stdlibs(::Nothing)
    historical_stdlibs_check()
    return UNREGISTERED_STDLIBS
end

function is_stdlib(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    julia_version == VERSION && return is_stdlib(uuid)
    return uuid in keys(get_last_stdlibs(julia_version))
end

"Version of a stdlib w.r.t. a julia version; `nothing` if unversioned."
function stdlib_version(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    last_stdlibs = get_last_stdlibs(julia_version)
    uuid in keys(last_stdlibs) || return nothing
    return last_stdlibs[uuid].version
end

function is_unregistered_stdlib(uuid::UUID)
    historical_stdlibs_check()
    return haskey(UNREGISTERED_STDLIBS, uuid)
end

end # module
