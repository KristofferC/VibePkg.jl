module Errors

export PkgError, pkgerror

"""
User-facing error. Rendered as its bare message (no type prefix, no
backtrace in the REPL). Every pinned error string is constructed at
exactly one site.
"""
struct PkgError <: Exception
    msg::String
end

pkgerror(msg::String) = throw(PkgError(msg))

"""
    pkgerror(parts::AbstractString...)

Throw a [`PkgError`](@ref) whose message is the concatenation of `parts`
(a convenience for splitting long messages over several literals). Only
strings are accepted — interpolate other values into the message instead
of passing them as separate arguments.
"""
pkgerror(parts::AbstractString...) = throw(PkgError(join(parts)))

Base.showerror(io::IO, err::PkgError) = print(io, err.msg)

end # module
