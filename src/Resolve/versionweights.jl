# This file is a part of Julia. License is MIT: https://julialang.org/license

# The numeric type used to determine how the different
# versions of a package should be weighed.
# The major/minor/patch fields discard prerelease and build metadata, so two
# versions that differ only in those components (e.g. distinct JLL builds
# 1.2.3+0 and 1.2.3+1) would collapse to the same weight. The `rank` field
# breaks such ties: it holds the index of the version within the package's
# sorted version list (see `Messages` in maxsum.jl), so the weight ordering
# is order-isomorphic to the VersionNumber ordering within a package.
struct VersionWeight
    major::Int64
    minor::Int64
    patch::Int64
    rank::Int64
end
VersionWeight(major::Integer, minor::Integer, patch::Integer) = VersionWeight(major, minor, patch, 0)
VersionWeight(major::Integer, minor::Integer) = VersionWeight(major, minor, 0)
VersionWeight(major::Integer) = VersionWeight(major, 0)
VersionWeight() = VersionWeight(0)
VersionWeight(vn::VersionNumber, rank::Integer = 0) = VersionWeight(vn.major, vn.minor, vn.patch, rank)

Base.zero(::Type{VersionWeight}) = VersionWeight()

Base.typemin(::Type{VersionWeight}) = (x = typemin(Int64); VersionWeight(x, x, x, x))

Base.:(-)(a::VersionWeight, b::VersionWeight) =
    VersionWeight(a.major - b.major, a.minor - b.minor, a.patch - b.patch, a.rank - b.rank)

Base.:(+)(a::VersionWeight, b::VersionWeight) =
    VersionWeight(a.major + b.major, a.minor + b.minor, a.patch + b.patch, a.rank + b.rank)

Base.:(-)(a::VersionWeight) =
    VersionWeight(-a.major, -a.minor, -a.patch, -a.rank)

function Base.isless(a::VersionWeight, b::VersionWeight)
    return (a.major, a.minor, a.patch, a.rank) < (b.major, b.minor, b.patch, b.rank)
end

Base.abs(a::VersionWeight) =
    VersionWeight(abs(a.major), abs(a.minor), abs(a.patch), abs(a.rank))

# This isn't nice, but it's for debugging only anyway
function Base.show(io::IO, a::VersionWeight)
    print(io, "(", a.major)
    a == VersionWeight(a.major) && @goto done
    print(io, ".", a.minor)
    a == VersionWeight(a.major, a.minor) && @goto done
    print(io, ".", a.patch)
    a == VersionWeight(a.major, a.minor, a.patch) && @goto done
    print(io, "+", a.rank)
    @label done
    return print(io, ")")
end
