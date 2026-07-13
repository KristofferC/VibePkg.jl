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
pkgerror(msg...) = throw(PkgError(join(msg)))

Base.showerror(io::IO, err::PkgError) = print(io, err.msg)

end # module
