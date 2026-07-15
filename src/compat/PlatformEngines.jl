# Compatibility surface for the artifact-oriented parts of Pkg.PlatformEngines.
# The implementation delegates acquisition and archive handling to Fetch so
# there remains one download/unpack engine.
module PlatformEngines

using SHA: sha256

import ..Fetch
using ..Utils: stderr_f

export download, download_verify, download_verify_unpack, unpack,
    package, list_tarball_files, verify, get_server_dir

"Download `url` to `dest`, following redirects."
function download(
        url::AbstractString, dest::AbstractString;
        verbose::Bool = false, io::IO = stderr_f(),
    )
    return Fetch.download(
        String(url), String(dest);
        io, show_progress = verbose,
    )
end

package(src::AbstractString, dest::AbstractString; io::IO = stderr_f()) =
    Fetch.package(src, dest; io)
list_tarball_files(path::AbstractString) = Fetch.list_tarball_files(path)
unpack(path::AbstractString, dest::AbstractString; verbose::Bool = false) =
    Fetch.unpack(String(path), String(dest))

"Return the first-depot authentication directory for a URL under `server`."
function get_server_dir(
        url::AbstractString,
        server::Union{AbstractString, Nothing} = Fetch.pkg_server(),
    )
    server === nothing && return nothing
    (url == server || startswith(url, "$server/")) || return nothing
    matched = match(r"^\w+:///?([^\\/]+)(?:$|/)", server)
    if matched === nothing
        @warn "malformed Pkg server value" server
        return nothing
    end
    isempty(Base.DEPOT_PATH) && return nothing
    dirname = replace(String(matched[1]), r"[\\/:*?\"<>|]" => "_")
    return joinpath(first(Base.DEPOT_PATH), "servers", dirname)
end

"""
    verify(path, hash; verbose, report_cache_status, hash_path, details)

Verify a file's SHA-256 and maintain Pkg's `<path>.sha256` sidecar cache.
When `report_cache_status` is true, return `(ok, status)` where `status` is
one of `:hash_cache_missing`, `:hash_cache_consistent`, `:file_modified`,
`:hash_cache_mismatch`, or `:hash_mismatch`.
"""
function verify(
        path::AbstractString, hash::AbstractString;
        verbose::Bool = false, report_cache_status::Bool = false,
        hash_path::AbstractString = "$(path).sha256",
        details::Union{Nothing, Vector{String}} = nothing,
    )
    if !occursin(r"^[0-9a-f]{64}$"i, hash)
        message = "Hash value must be 64 hexadecimal characters (256 bits), "
        if !isascii(hash)
            message *= "given hash value is non-ASCII"
        elseif occursin(r"^[0-9a-f]*$"i, hash)
            message *= "given hash value has the wrong length ($(length(hash)))"
        else
            message *= "given hash value contains non-hexadecimal characters"
        end
        error(message * ": $(repr(hash))")
    end
    expected = lowercase(hash)

    status = if isfile(hash_path)
        if read(hash_path, String) == expected
            if stat(hash_path).mtime >= stat(path).mtime
                verbose && @info "Hash cache is consistent, returning true"
                return report_cache_status ? (true, :hash_cache_consistent) : true
            end
            verbose && @info "File has been modified, hash cache invalidated"
            :file_modified
        else
            verbose && @info "Verification hash mismatch, hash cache invalidated"
            :hash_cache_mismatch
        end
    else
        verbose && @info "No hash cache found"
        :hash_cache_missing
    end

    calculated = bytes2hex(open(sha256, path))
    verbose && @info "Calculated hash $calculated for file $path"
    if calculated != expected
        message = "Hash Mismatch!\n" *
            "  Expected sha256:   $expected\n" *
            "  Calculated sha256: $calculated"
        details === nothing ? (@error message) : push!(details, message)
        return report_cache_status ? (false, :hash_mismatch) : false
    end

    try
        write(hash_path, expected)
    catch err
        err isa InterruptException && rethrow()
        verbose && @warn "Unable to create hash cache file $(hash_path)"
    end
    return report_cache_status ? (true, status) : true
end

"Download a file and verify its SHA-256, optionally replacing a bad cache."
function download_verify(
        url::AbstractString, hash::Union{AbstractString, Nothing},
        dest::AbstractString;
        verbose::Bool = false, force::Bool = false,
        quiet_download::Bool = false, io::IO = stderr_f(),
    )
    existed = isfile(dest)
    if existed
        hash !== nothing && verify(dest, hash; verbose) && return true
        hash === nothing && return true
        force || error("Verification failed, not overwriting $(dest)")
        Base.rm(dest; force = true)
        Base.rm("$(dest).sha256"; force = true)
    end
    mkpath(dirname(dest))
    download(url, dest; verbose = verbose || !quiet_download, io)
    if hash !== nothing && !verify(dest, hash; verbose)
        error("Verification failed for $(dest)")
    end
    return !existed
end

"""
    download_verify_unpack(
            url, hash, dest; tarball_path, ignore_existence,
            force, verbose, quiet_download, io
        ) -> Bool

Download, SHA-256 verify, and unpack an archive.  A cached valid tarball and
existing destination are reused; `force` replaces a corrupt cached tarball.
"""
function download_verify_unpack(
        url::AbstractString, hash::Union{AbstractString, Nothing},
        dest::AbstractString;
        tarball_path::Union{AbstractString, Nothing} = nothing,
        ignore_existence::Bool = false, force::Bool = false,
        verbose::Bool = false, quiet_download::Bool = false,
        io::IO = stderr_f(),
    )
    remove_tarball = tarball_path === nothing
    archive = remove_tarball ? tempname() * "-download.tar.gz" : String(tarball_path)
    changed = !download_verify(
        url, hash, archive;
        force, verbose, quiet_download, io,
    )
    changed && Base.rm(dest; recursive = true, force = true)
    if !ignore_existence && isdir(dest)
        return false
    end
    try
        verbose && @info "Unpacking $(archive) into $(dest)..."
        Fetch.unpack(archive, String(dest))
    finally
        if remove_tarball
            Base.rm(archive; force = true)
            Base.rm("$(archive).sha256"; force = true)
        end
    end
    return true
end

end # module
