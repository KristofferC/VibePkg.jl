# Pkg.Registry-compatible namespace
module Registry
using Base: UUID

using ..Depots: depot_stack
using ..Utils: stderr_f
using ..Errors: pkgerror
using ..Display: printpkgstyle
using ..Configs: pkg_server
import ..Registries
import ..API

"""
    add(; io)                # install the default registries
    add(spec...; io)         # install by name ("General"), url, or path

Install registries. The no-argument form installs everything the package
server advertises (or git clones of the known default registries when no
package server is configured).
"""
add(; io::IO = stderr_f()) = (Registries.add_default_registries!(depot_stack(); io); nothing)
function add(specs::String...; io::IO = stderr_f())
    for spec in specs
        Registries.add_registry!(depot_stack(), spec; io)
    end
    return nothing
end

# `"Name"`, `"Name=uuid"`, or a bare uuid → (name, uuid)
function parse_registry_spec(spec::String)
    uuid_re = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    occursin(uuid_re, spec) && return nothing, UUID(spec)
    i = findfirst('=', spec)
    i === nothing && return spec, nothing
    name = String(strip(spec[1:prevind(spec, i)]))
    uuid_str = String(strip(spec[nextind(spec, i):end]))
    occursin(uuid_re, uuid_str) || pkgerror("`$spec` is not a valid registry specification")
    return name, UUID(uuid_str)
end

"""
    rm(spec...; io)
    rm(; name, uuid, io)

Remove registries from the depot. `spec` is a name, `name=uuid`, or a
bare uuid; a name shared by several registries requires the uuid form.
"""
function rm(specs::AbstractString...; io::IO = stderr_f())
    isempty(specs) && pkgerror("`registry rm` requires at least one registry")
    for spec in specs
        name, uuid = parse_registry_spec(String(spec))
        Registries.remove_registry!(depot_stack(), name, uuid; io)
    end
    return nothing
end
function rm(; name = nothing, uuid = nothing, io::IO = stderr_f())
    uuid isa AbstractString && (uuid = UUID(uuid))
    Registries.remove_registry!(depot_stack(), name, uuid; io)
    return nothing
end

"""
    update(names...; io)

Update installed registries (all of them, or only the named ones).
"""
function update(names::String...; io::IO = stderr_f())
    Registries.update_registries!(
        depot_stack(); names = isempty(names) ? nothing : collect(String, names), io,
    )
    return nothing
end

# git clone / packed tarball / unpacked-from-tarball / bare directory
function registry_form(reg::Registries.RegistryInstance)
    reg.compressed_file === nothing || return "packed registry with hash $(reg.tree_info)"
    ispath(joinpath(reg.path, ".git")) && return "git registry"
    reg.tree_info === nothing || return "unpacked registry with hash $(reg.tree_info)"
    return "bare registry"
end

"""
    status(; io)

Show the installed registries: short uuid, name, source url, the on-disk
form (packed/unpacked/git/bare), and — for registries the package server
tracks — the serving url, the selected flavor
(`JULIA_PKG_SERVER_REGISTRY_PREFERENCE`), and whether an update is
available. The server query is skipped in offline mode.
"""
function status(; io::IO = stderr_f())
    regs = Registries.reachable_registries(depot_stack())
    printpkgstyle(io, Symbol("Registry Status"), "")
    isempty(regs) && (println(io, "  (no registries found)"); return nothing)
    server = API.is_offline() ? nothing : pkg_server()
    server_hashes = server === nothing ? nothing : try
            Registries.server_registry_hashes(server; depots = depot_stack())
    catch err
            err isa InterruptException && rethrow()
            nothing
    end
    flavor = get(ENV, "JULIA_PKG_SERVER_REGISTRY_PREFERENCE", "")
    for reg in regs
        uuid = Registries.registry_uuid(reg)
        printstyled(io, " [$(string(uuid)[1:8])]"; color = :light_black)
        print(io, " ", Registries.registry_name(reg))
        repo = Registries.registry_repo(reg)
        repo === nothing || print(io, " ($repo)")
        println(io)
        println(io, "    ", registry_form(reg))
        if server_hashes !== nothing && haskey(server_hashes, uuid) &&
                !ispath(joinpath(reg.path, ".git"))
            print(io, "    served by $server")
            flavor == "" || print(io, " ($flavor flavor)")
            server_hashes[uuid] == reg.tree_info || print(io, " - update available")
            println(io)
        end
    end
    return nothing
end
end
