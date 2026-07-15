# Pkg.Apps-compatible namespace
module Apps
using ..Errors: pkgerror
using ..Utils: stderr_f
using ..Depots: depot_stack
using ..Environments: load_environment_from
import ..API
import ..AppsOps
import ..Git
using ..Planning: PackageRequest, resolve_request

function add(pkg::String; io::IO = stderr_f())
    ctx = API.op_context(; io, update_registry = :auto)
    return AppsOps.app_add(ctx.config, ctx.registries, PackageRequest(pkg); io)
end

# Pkg-compatible repository-shaped app add. The repo is materialized before
# entering AppsOps so its verified package identity and tree hash are what the
# app manifest records; a later `update` can then refresh the same revision.
function add(;
        name = nothing, uuid = nothing, version = nothing,
        url = nothing, rev = nothing, path = nothing, subdir = nothing,
        io::IO = stderr_f(),
    )
    spec = API.PackageSpec(; name, uuid, version, url, rev, path, subdir)
    API.validate_specs([spec], "add")
    reqs, repo_like, name_rev = API.split_specs([spec])
    ctx = API.op_context(; io, update_registry = :auto)
    if !isempty(repo_like)
        source = something(spec.url, spec.path === nothing ? nothing : abspath(spec.path))
        repo = Git.materialize_repo_package!(
            ctx.config.depots, source; rev = spec.rev, subdir = spec.subdir, io,
        )
        return AppsOps.app_add(ctx.config, ctx.registries, repo; io)
    elseif !isempty(name_rev)
        env = load_environment_from(
            joinpath(AppsOps.apps_dir(ctx.config.depots), "Project.toml");
            depots = ctx.config.depots,
        )
        resolved_name, resolved_uuid = resolve_request(
            env, ctx.registries, PackageRequest(spec.name, spec.uuid, nothing),
        )
        source = API.registry_repo_url(ctx.registries, resolved_uuid)
        source === nothing && pkgerror(
            "could not find a repository url for package `$resolved_name` in any registry"
        )
        repo = Git.materialize_repo_package!(
            ctx.config.depots, source; rev = spec.rev, subdir = spec.subdir, io,
        )
        return AppsOps.app_add(ctx.config, ctx.registries, repo; io)
    end
    return AppsOps.app_add(ctx.config, ctx.registries, only(reqs); io)
end
function develop(path::String; io::IO = stderr_f())
    ctx = API.op_context(; io)
    return AppsOps.app_develop(ctx.config, ctx.registries, path; io)
end
function develop(; path::Union{Nothing, String} = nothing, io::IO = stderr_f())
    path === nothing && pkgerror("app develop requires at least one package")
    return develop(path; io)
end
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
