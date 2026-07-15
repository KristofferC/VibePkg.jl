# Small foundational helpers shared across layers.
module Utils

using TOML: TOML

export isurl, normalize_path_for_toml, denormalize_path_from_toml, stdout_f, stderr_f,
    unstableio, can_fancyprint, precompile_io, precompile_detach_kwargs,
    printpkgstyle, pkgstyle_indent, pathrepr, sanitize_url, sanitize_external_error,
    set_readonly, create_cachedir_tag, mv_temp_dir_retries, atomic_write, atomic_toml_write,
    expanduser_path

# IO indirection points. Lower layers must go through these so that
# redirecting output stays a one-place change. The stream is wrapped in
# `IOContext{IO}` so downstream io-taking code compiles a single
# specialization no matter the concrete stream (TTY, pipe, buffer) — and the
# precompile workload can cover real sessions by using the same wrapper
# (https://github.com/JuliaLang/julia/pull/52249).
function unstableio(@nospecialize(io::IO))
    _io = Base.inferencebarrier(io)
    return IOContext{IO}(
        _io,
        get(_io, :color, false) ? Base.ImmutableDict{Symbol, Any}(:color, true) :
            Base.ImmutableDict{Symbol, Any}(),
    )
end
# Scoped override for all default output (tests, the precompile workload).
const DEFAULT_IO = Base.ScopedValues.ScopedValue{IO}()

stdout_f() = something(Base.ScopedValues.get(DEFAULT_IO), unstableio(stdout))
stderr_f() = something(Base.ScopedValues.get(DEFAULT_IO), unstableio(stderr))

# `Base.expanduser` does not consistently consult an overridden HOME on
# Windows. Pkg commands use HOME as an explicit, process-local override (and
# tests rely on that), so handle the current-user forms before delegating the
# unsupported `~user` forms to Base for their usual error.
function expanduser_path(path::AbstractString)
    value = String(path)
    if value == "~"
        return get(ENV, "HOME", homedir())
    elseif startswith(value, "~/") || startswith(value, "~\\")
        home = get(ENV, "HOME", homedir())
        return ncodeunits(value) == 2 ? home : joinpath(home, value[3:end])
    end
    return expanduser(value)
end

"Fancy terminal output (progress bars, ANSI updates): TTY and not CI."
is_tty(io::IO) = io isa Base.TTY || (io isa IOContext{IO} && io.io isa Base.TTY)
can_fancyprint(io::IO) = is_tty(io) && (get(ENV, "CI", nothing) != "true")

# `Base.Precompilation` decides fancy output with a literal `io isa Base.TTY`
# check and prints a lot, where the `unstableio` wrapper also costs — so hand
# it the raw stream. Keep the wrapper around a `PipeEndpoint`, which would
# otherwise lose color.
function precompile_io(io::IO)
    return if io isa IOContext{IO} && !(io.io isa Base.PipeEndpoint)
        io.io
    else
        io
    end
end

# `detachable` (press 'd' to move a running precompilation to the background)
# is newer than the 1.12 lower bound (julia#60943), so detect support instead
# of hard-coding a version.
const PRECOMPILE_SUPPORTS_DETACHABLE = any(
    m -> :detachable in Base.kwarg_decl(m),
    methods(Base.Precompilation.precompilepkgs),
)
precompile_detach_kwargs() =
    PRECOMPILE_SUPPORTS_DETACHABLE ? (; detachable = isinteractive()) : (;)

# Low-level output primitives live below Display so planning and execution do
# not depend on the high-level rendering layer.
const pkgstyle_indent = textwidth(string(:Precompiling))

function printpkgstyle(io::IO, cmd::Symbol, text::String, ignore_indent::Bool = false; color = :green)
    indent = ignore_indent ? 0 : pkgstyle_indent
    return @lock io begin
        printstyled(io, lpad(string(cmd), indent), color = color, bold = true)
        println(io, " ", text)
    end
end

function pathrepr(path::String)
    if startswith(path, Sys.STDLIB)
        path = "@stdlib/" * basename(path)
    end
    return "`" * Base.contractuser(path) * "`"
end

# URL detection is anchored: a string is a URL when it *starts* with a scheme
# the Git layer understands (`http(s)://`, `git://`, `ssh://`, `file://`) or
# is SCP-like (`user@host:path`). An unanchored match would accept URL-looking
# substrings inside plain paths (e.g. `some/dir/ssh:copy`), and a character
# whitelist after the scheme would reject valid URL characters (`%`, `?`, …).
const URL_SCHEME_RE = r"^(?:https?|git|ssh|file)://"i
const SCP_LIKE_RE = r"^[\w\-\.]+@[\w\-\.]+:.+"s
isurl(r::String) = occursin(URL_SCHEME_RE, r) || occursin(SCP_LIKE_RE, r)

"""
    sanitize_url(value) -> String

Redact credentials embedded in a URL before including it in a diagnostic.
The host and repository path remain visible so the message is still useful.
"""
function sanitize_url(value::AbstractString)
    redacted = replace(
        String(value),
        r"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@" => s"\1***@",
    )
    return replace(
        redacted,
        r"(?i)([?&](?:access_token|auth|key|password|signature|token)=)[^&#\s]*" => s"\1***",
    )
end

"Render an external failure without disclosing credentials embedded in URLs."
sanitize_external_error(err) = sanitize_url(sprint(showerror, err))

"""
    normalize_path_for_toml(path::String)

Normalize a path for writing to TOML files (Project.toml/Manifest.toml).
On Windows, converts relative paths to use forward slashes for cross-platform
compatibility. Absolute paths are left unchanged as they are platform-specific
by nature.
"""
function normalize_path_for_toml(path::String)
    if Sys.iswindows() && !isabspath(path)
        return join(splitpath(path), "/")
    end
    return path
end

"""
    denormalize_path_from_toml(path::String)

Inverse of [`normalize_path_for_toml`](@ref) applied at read time: on Windows,
turn `/`-separated relative paths into native `\\`-paths.
"""
function denormalize_path_from_toml(path::String)
    if Sys.iswindows() && !isabspath(path)
        return joinpath(split(path, "/")...)
    end
    return path
end

function set_readonly(path)
    for (root, dirs, files) in walkdir(path)
        for file in files
            filepath = joinpath(root, file)
            # chmod on a link would change the permissions of the target
            islink(filepath) && continue
            fmode = filemode(filepath)
            @static if Sys.iswindows()
                if Sys.isexecutable(filepath)
                    fmode |= 0o111
                end
            end
            try
                chmod(filepath, fmode & (typemax(fmode) ⊻ 0o222))
            catch
            end
        end
    end
    return nothing
end
set_readonly(::Nothing) = nothing

function create_cachedir_tag(dir::String)
    tag_file = joinpath(dir, "CACHEDIR.TAG")
    if !isfile(tag_file)
        try
            open(tag_file, "w") do io
                print(
                    io, """
                    Signature: 8a477f597d28d172789f06886806bc55
                    # This file is a cache directory tag.
                    # For information about cache directory tags see https://bford.info/cachedir/
                    """
                )
            end
        catch
        end
    end
    return
end

"""
    mv_temp_dir_retries(temp_dir, new_path; set_permissions = true)

Rename `temp_dir` to `new_path` (never copy — rename is atomic), retrying
with backoff on the error codes anti-virus scanners cause. `new_path`
already existing counts as success (a concurrent installer won). Both paths
must be on the same filesystem.
"""
function mv_temp_dir_retries(temp_dir::String, new_path::String; set_permissions::Bool = true)::Nothing
    retry = 0
    max_num_retries = 20
    sleep_amount = 0.01 # seconds
    max_sleep_amount = 5.0 # seconds
    while true
        isdir(new_path) && return
        # `mv` falls back to `cp` on error; `cp` is not atomic, so use rename directly
        err = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), temp_dir, new_path)
        if err ≥ 0
            if set_permissions
                new_path_mode = filemode(dirname(new_path))
                if Sys.iswindows()
                    new_path_mode |= 0o111
                end
                chmod(new_path, new_path_mode)
                set_readonly(new_path)
            end
            return
        else
            isdir(new_path) && return
            if retry < max_num_retries && err ∈ (Base.UV_EACCES, Base.UV_EPERM, Base.UV_EBUSY)
                sleep(sleep_amount)
                sleep_amount = min(sleep_amount * 2.0, max_sleep_amount)
                retry += 1
            else
                Base.uv_error("rename of $(repr(temp_dir)) to $(repr(new_path))", err)
            end
        end
    end
    return
end

"""
    atomic_write(path, str)

Write `str` to `path` via a temporary file in the same directory + rename,
so an interrupted write can never leave a truncated file behind.
"""
function atomic_write(path::AbstractString, str::AbstractString)
    dir = dirname(path)
    isempty(dir) && (dir = pwd())
    temp_path, temp_io = mktemp(dir)
    try
        n = write(temp_io, str)
        close(temp_io)
        # mktemp creates 0600 files; keep the destination's visibility instead
        chmod(temp_path, isfile(path) ? filemode(path) : 0o644)
        mv(temp_path, path; force = true)
        return n
    catch
        close(temp_io)
        rm(temp_path; force = true)
        rethrow()
    end
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

end # module
