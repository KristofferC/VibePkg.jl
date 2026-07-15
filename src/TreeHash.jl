# Git-exact tree hashing. Ported from Pkg's GitTools.
# Pure: path in, digest out. This is how ALL package content is verified —
# there are no other checksums for package tarballs.

module TreeHash

using Base: SHA1
using SHA: SHA

export tree_hash, blob_hash

@enum GitMode begin
    mode_dir = 0o040000
    mode_normal = 0o100644
    mode_executable = 0o100755
    mode_symlink = 0o120000
end
Base.string(mode::GitMode) = string(UInt32(mode); base = 8)
Base.print(io::IO, mode::GitMode) = print(io, string(mode))

function gitmode(path::AbstractString)
    # Windows' `stat()` gives a different answer than we want for the
    # executable bit; `Sys.isexecutable` (uv_fs_access) is reliable there.
    isexec(p) = @static Sys.iswindows() ? Sys.isexecutable(p) :
        !iszero(filemode(p) & 0o100)
    if islink(path)
        return mode_symlink
    elseif isdir(path)
        return mode_dir
    elseif isexec(path)
        return mode_executable
    else
        return mode_normal
    end
end

"""
    blob_hash(HashType, path; legacy_symlink_size = false)

The git blob hash of a file or symlink.

Git records a symlink target's size in bytes. Set `legacy_symlink_size = true`
to reproduce the character-counting behavior used by older Pkg versions.
"""
function blob_hash(
        ::Type{HashType}, path::AbstractString;
        legacy_symlink_size::Bool = false,
    ) where {HashType}
    ctx = HashType()
    link = islink(path) ? readlink(path) : nothing
    if link !== nothing
        datalen = legacy_symlink_size ? length(link) : sizeof(link)
    else
        datalen = filesize(path)
    end

    SHA.update!(ctx, Vector{UInt8}("blob $(datalen)\0"))

    buff = Vector{UInt8}(undef, 4 * 1024)
    try
        if link !== nothing
            SHA.update!(ctx, Vector{UInt8}(link))
        else
            open(path, "r") do io
                while !eof(io)
                    num_read = readbytes!(io, buff)
                    SHA.update!(ctx, buff, num_read)
                end
            end
        end
    catch e
        # Hashing is an integrity boundary: a digest of partial content would
        # silently verify (or mis-verify) corrupt trees, so read failures
        # must propagate rather than degrade to a warning.
        e isa InterruptException && rethrow()
        error("Failed to read $(repr(path)) while computing its Git blob hash: $(sprint(showerror, e))")
    end

    return SHA.digest!(ctx)
end
blob_hash(path::AbstractString; legacy_symlink_size::Bool = false) =
    blob_hash(SHA.SHA1_CTX, path; legacy_symlink_size)

# Whether a directory (transitively) contains any file — git does not track
# empty directories, so they are excluded from hashing.
function contains_files(path::AbstractString)
    st = lstat(path)
    ispath(st) || throw(ArgumentError("Path $(repr(path)) does not exist"))
    isdir(st) || return true
    for p in readdir(path)
        contains_files(joinpath(path, p)) && return true
    end
    return false
end

"""
    tree_hash([HashType,] root; legacy_symlink_size = false) -> Vector{UInt8}

The git tree hash of a directory: `.git` excluded, empty directories
excluded, entries sorted the way git sorts them (directories as `name/`).

`legacy_symlink_size` is forwarded to `blob_hash`.
"""
function tree_hash(
        ::Type{HashType}, root::AbstractString;
        legacy_symlink_size::Bool = false,
    ) where {HashType}
    isdir(root) || throw(ArgumentError("tree_hash requires an existing directory; got $(repr(root))"))
    entries = Tuple{String, Vector{UInt8}, GitMode}[]
    for f in sort(readdir(root; join = true); by = f -> gitmode(f) == mode_dir ? f * "/" : f)
        basename(f) == ".git" && continue

        filepath = abspath(f)
        mode = gitmode(filepath)
        if mode == mode_dir
            contains_files(filepath) || continue
            hash = tree_hash(HashType, filepath; legacy_symlink_size)
        else
            hash = blob_hash(HashType, filepath; legacy_symlink_size)
        end
        push!(entries, (basename(filepath), hash, mode))
    end

    content_size = 0
    for (n, h, m) in entries
        content_size += ndigits(UInt32(m); base = 8) + 1 + sizeof(n) + 1 + sizeof(h)
    end

    ctx = HashType()
    SHA.update!(ctx, Vector{UInt8}("tree $(content_size)\0"))
    for (name, hash, mode) in entries
        SHA.update!(ctx, Vector{UInt8}("$(mode) $(name)\0"))
        SHA.update!(ctx, hash)
    end
    return SHA.digest!(ctx)
end
tree_hash(root::AbstractString; legacy_symlink_size::Bool = false) =
    tree_hash(SHA.SHA1_CTX, root; legacy_symlink_size)

"Whether `path` has either the canonical or legacy-compatible tree hash."
function tree_hash_matches(path::AbstractString, expected::SHA1)
    SHA1(tree_hash(path)) == expected && return true
    return SHA1(tree_hash(path; legacy_symlink_size = true)) == expected
end

end # module
