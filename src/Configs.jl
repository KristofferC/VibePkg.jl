# Configuration is data: everything an operation needs
# from the process environment is read once at the operation boundary into
# an immutable `Config` and threaded as an argument. Planning and Execution
# never read `ENV`; the effectful store modules (Git, Registries) keep at
# most one named single-read-point function each.
#
# Also home of the operation option vocabulary (preserve/upgrade/mode enums)
# shared by every frontend, so REPLMode and friends need not import Planning.

module Configs

using ..Errors: pkgerror
using ..Utils: stderr_f
using ..Depots: DepotStack, depot_stack, depots1

export Config, default_preserve, pkg_server,
    PreserveLevel, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT,
    PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_TIERED_INSTALLED, PRESERVE_NONE,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PackageMode, PKGMODE_PROJECT, PKGMODE_MANIFEST

@enum PreserveLevel begin
    PRESERVE_ALL_INSTALLED
    PRESERVE_ALL
    PRESERVE_DIRECT
    PRESERVE_SEMVER
    PRESERVE_TIERED
    PRESERVE_TIERED_INSTALLED
    PRESERVE_NONE
end

@enum UpgradeLevel begin
    UPLEVEL_FIXED
    UPLEVEL_PATCH
    UPLEVEL_MINOR
    UPLEVEL_MAJOR
end

@enum PackageMode begin
    PKGMODE_PROJECT
    PKGMODE_MANIFEST
end

# ops take `mode` as a Symbol internally; the exported PackageMode values are
# the Pkg-compatible spelling of the same choice
mode_symbol(mode::Symbol) =
    mode in (:project, :manifest) ? mode :
    pkgerror("`mode` must be `:project` or `:manifest`")
mode_symbol(mode::PackageMode) = mode == PKGMODE_PROJECT ? :project : :manifest

"the default preserve strategy: tiered, or tiered-installed via env var"
default_preserve() =
    Base.get_bool_env("JULIA_PKG_PRESERVE_TIERED_INSTALLED", false) === true ?
    PRESERVE_TIERED_INSTALLED : PRESERVE_TIERED

"The package server url (`JULIA_PKG_SERVER`), or nothing when disabled."
function pkg_server()
    server = get(ENV, "JULIA_PKG_SERVER", "https://pkg.julialang.org")
    isempty(server) && return nothing
    startswith(server, r"\w+://") || (server = "https://$server")
    return String(rstrip(server, '/'))
end

"""
    Config(depots = depot_stack(); io, offline, respect_sysimage_versions)

One immutable view of the ambient operation settings. Session flags
(offline mode, sysimage-version respect) are folded in by the caller; the
environment variables are read here, once.
"""
struct Config
    depots::DepotStack
    io::IO
    server::Union{Nothing, String}
    offline::Bool
    devdir::String
    concurrency::Int
    respect_sysimage_versions::Bool
end

function Config(
        depots::DepotStack = depot_stack();
        io::IO = stderr_f(),
        offline::Bool = false,
        respect_sysimage_versions::Bool = true,
    )
    return Config(
        depots, io, pkg_server(),
        offline || Base.get_bool_env("JULIA_PKG_OFFLINE", false) == true,
        get(ENV, "JULIA_PKG_DEVDIR", joinpath(depots1(depots), "dev")),
        max(1, something(tryparse(Int, get(ENV, "JULIA_PKG_CONCURRENT_DOWNLOADS", "8")), 8)),
        respect_sysimage_versions,
    )
end

end # module
