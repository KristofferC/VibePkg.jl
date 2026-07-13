# Read-only data queries shared by frontends. Frontends consume
# these values instead of reaching into environment, registry, and stdlib
# internals directly.
module Queries

using ..Depots: depot_stack
import ..Environments
import ..Fetch
import ..Registries
import ..Stdlibs

export registered_package_names, is_deprecated_package_name,
    environment_dependency_names, stdlib_names, reset_completion_cache!

const REGISTERED_PACKAGE_NAMES = Ref{Union{Nothing, Vector{String}}}(nothing)

function reset_completion_cache!()
    REGISTERED_PACKAGE_NAMES[] = nothing
    return
end

function reachable_registries()
    depots = depot_stack()
    return Registries.reachable_registries(
        depots; read_from_tarball = Fetch.pkg_server() !== nothing
    )
end

function registered_package_names()
    cached = REGISTERED_PACKAGE_NAMES[]
    cached === nothing || return cached
    names = String[]
    for registry in reachable_registries(), (_, package) in Registries.registry_pkgs(registry)
        push!(names, package.name)
    end
    sort!(unique!(names))
    REGISTERED_PACKAGE_NAMES[] = names
    return names
end

function is_deprecated_package_name(name::String)
    found = false
    for registry in reachable_registries()
        for uuid in Registries.uuids_from_name(registry, name)
            package = get(registry, uuid, nothing)
            package === nothing && continue
            found = true
            Registries.isdeprecated(Registries.registry_info(registry, package)) || return false
        end
    end
    return found
end

function environment_dependency_names()
    env = Environments.load_environment(; depots = depot_stack())
    return sort!(collect(keys(env.project.deps)))
end

stdlib_names() = sort!([info.name for info in values(Stdlibs.stdlib_infos())])

end # module
