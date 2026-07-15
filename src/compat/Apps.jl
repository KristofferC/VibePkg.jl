# Pkg.Apps-compatible namespace
module Apps
using ..Utils: stderr_f
using ..Depots: depot_stack
import ..API
import ..AppsOps
using ..Planning: PackageRequest

function add(pkg::String; io::IO = stderr_f())
    ctx = API.op_context(; io, update_registry = :auto)
    return AppsOps.app_add(ctx.config, ctx.registries, PackageRequest(pkg); io)
end
function develop(path::String; io::IO = stderr_f())
    ctx = API.op_context(; io)
    return AppsOps.app_develop(ctx.config, ctx.registries, path; io)
end
develop(; path::String, io::IO = stderr_f()) = develop(path; io)
# rm and status are local-only: no OpContext (which would bootstrap
# registries into a fresh depot), just the ambient depot stack
function rm(name::String; io::IO = stderr_f())
    return AppsOps.app_rm(depot_stack(), name; io)
end
function update(name::Union{Nothing, String} = nothing; io::IO = stderr_f())
    ctx = API.op_context(; io, update_registry = :auto)
    return AppsOps.app_update(ctx.config, ctx.registries, name; io)
end
function status(pkgs::String...; io::IO = stderr_f())
    return AppsOps.app_status(depot_stack(), collect(String, pkgs); io)
end
end
