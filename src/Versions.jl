# Version bounds, ranges, specs, and the two version-string grammars.
# Algorithms ported from Pkg's Versions.jl (hot code —
# measure before changing); construction restructured so values are
# normalized at creation and never mutated afterwards.
#
# Deliberate fixes vs Pkg:
#   - constructing a spec from a vector never mutates the argument
#   - `semver_spec("<0")` errors cleanly instead of InexactError
#   - `semver_spec(s; throw=false)` returns `nothing` for *all* invalid
#     inputs (Pkg still threw on e.g. "0.0.0")
#   - range printing is symmetric: "0 - 1.2.0" (Pkg printed "0 -1.2.0")

module Versions

export VersionBound, VersionRange, VersionSpec, semver_spec, isjoinable

################
# VersionBound #
################

# `t` always carries zeros past the significant components, so bounds with
# equal significance compare correctly by field equality. Construct through
# the factories below, which enforce that.
struct VersionBound
    t::NTuple{3, UInt32}
    n::Int
end

function VersionBound(tin::NTuple{n, Integer}) where {n}
    n <= 3 || throw(ArgumentError("VersionBound: you can only specify major, minor and patch versions"))
    n == 0 && return VersionBound((0, 0, 0), 0)
    n == 1 && return VersionBound((tin[1], 0, 0), 1)
    n == 2 && return VersionBound((tin[1], tin[2], 0), 2)
    return VersionBound((tin[1], tin[2], tin[3]), 3)
end
VersionBound(t::Integer...) = VersionBound(t)
VersionBound(v::VersionNumber) = VersionBound(v.major, v.minor, v.patch)

Base.getindex(b::VersionBound, i::Int) = b.t[i]
Base.:(==)(a::VersionBound, b::VersionBound) = a.t == b.t && a.n == b.n
Base.hash(r::VersionBound, h::UInt) = hash(r.t, hash(r.n, h))

# Membership comparisons deliberately look only at major/minor/patch:
# prereleases and build numbers of a version are inside the bound
# (`v"1.3.0-rc1" ∈ "1.2 - 1.3"`).
function ≲(v::VersionNumber, b::VersionBound)
    b.n == 0 && return true
    b.n == 1 && return v.major <= b[1]
    b.n == 2 && return (v.major, v.minor) <= (b[1], b[2])
    return (v.major, v.minor, v.patch) <= (b[1], b[2], b[3])
end

function ≲(b::VersionBound, v::VersionNumber)
    b.n == 0 && return true
    b.n == 1 && return v.major >= b[1]
    b.n == 2 && return (v.major, v.minor) >= (b[1], b[2])
    return (v.major, v.minor, v.patch) >= (b[1], b[2], b[3])
end

# Comparison between two lower bounds
function isless_ll(a::VersionBound, b::VersionBound)
    m, n = a.n, b.n
    for i in 1:min(m, n)
        a[i] < b[i] && return true
        a[i] > b[i] && return false
    end
    return m < n
end

stricterlower(a::VersionBound, b::VersionBound) = isless_ll(a, b) ? b : a

# Comparison between two upper bounds
function isless_uu(a::VersionBound, b::VersionBound)
    m, n = a.n, b.n
    for i in 1:min(m, n)
        a[i] < b[i] && return true
        a[i] > b[i] && return false
    end
    return m > n
end

stricterupper(a::VersionBound, b::VersionBound) = isless_uu(a, b) ? a : b

# `isjoinable` compares an upper bound of a range with the lower bound of the
# next range to determine if they can be joined, as in
# [1.5-2.8, 2.5-3] -> [1.5-3]. The equal-length-bounds case is special since
# e.g. `1.5` can be joined with `1.6`, `2.3.4` with `2.3.5`, etc.
function isjoinable(up::VersionBound, lo::VersionBound)
    up.n == 0 && lo.n == 0 && return true
    if up.n == lo.n
        n = up.n
        for i in 1:(n - 1)
            up[i] > lo[i] && return true
            up[i] < lo[i] && return false
        end
        up[n] < lo[n] - 1 && return false
        return true
    else
        l = min(up.n, lo.n)
        for i in 1:l
            up[i] > lo[i] && return true
            up[i] < lo[i] && return false
        end
    end
    return true
end

# Hot code: called for every section key of every Compress-format registry
# file that gets parsed.
function VersionBound(s::AbstractString)
    s = strip(s)
    s == "*" && return VersionBound()
    isempty(s) && throw(ArgumentError("invalid VersionBound string $(repr(s))"))
    first(s) == 'v' && (s = SubString(s, 2))
    l = lastindex(s)

    p = findnext('.', s, 1)
    b = p === nothing ? l : (p - 1)
    i = parse(Int64, SubString(s, 1, b))
    p === nothing && return VersionBound(i)

    a = p + 1
    p = findnext('.', s, a)
    b = p === nothing ? l : (p - 1)
    j = parse(Int64, SubString(s, a, b))
    p === nothing && return VersionBound(i, j)

    a = p + 1
    p = findnext('.', s, a)
    b = p === nothing ? l : (p - 1)
    k = parse(Int64, SubString(s, a, b))
    p === nothing && return VersionBound(i, j, k)

    throw(ArgumentError("invalid VersionBound string $(repr(s))"))
end

################
# VersionRange #
################

# Ranges are allowed to be empty (lower > upper); VersionSpec normalization
# drops them. Construct through `range_of` / the factories so that
# lower.t == upper.t collapses to equal significance (e.g. `1.2-1.2.0` means
# exactly `1.2.0`, and equality/printing agree with that).
struct VersionRange
    lower::VersionBound
    upper::VersionBound
end

function range_of(lo::VersionBound, hi::VersionBound)
    # An unbounded lower (n == 0) with a finite upper is semantically "≥ 0" and
    # is *printed* as `0` (e.g. `*-1` prints `0 - 1`). Store it as that `0`
    # bound so the representation matches the printing — otherwise two equal
    # ranges (`*-1` and `0-1`) would compare unequal and `*-1` wouldn't survive
    # a print/parse round-trip.
    lo.n == 0 && hi.n > 0 && (lo = VersionBound(0))
    lo.t == hi.t && (lo = hi)
    return VersionRange(lo, hi)
end

VersionRange(b::VersionBound = VersionBound()) = VersionRange(b, b)
VersionRange(t::Integer...) = VersionRange(VersionBound(t...))
VersionRange(v::VersionNumber) = VersionRange(VersionBound(v))
VersionRange(lo::VersionNumber, hi::VersionNumber) = range_of(VersionBound(lo), VersionBound(hi))
VersionRange(r::VersionRange) = r

# The vast majority of VersionRanges are in practice equal to "1"
const VersionRange_1 = VersionRange(VersionBound("1"), VersionBound("1"))

function VersionRange(s::AbstractString)
    s == "1" && return VersionRange_1
    p = split(s, "-")
    if (length(p) != 1 && length(p) != 2) || any(x -> isempty(strip(x)), p)
        throw(ArgumentError("invalid version range: $(repr(s))"))
    end
    lower = VersionBound(p[1])
    upper = length(p) == 1 ? lower : VersionBound(p[2])
    return range_of(lower, upper)
end

function Base.isempty(r::VersionRange)
    for i in 1:min(r.lower.n, r.upper.n)
        r.lower[i] > r.upper[i] && return true
        r.lower[i] < r.upper[i] && return false
    end
    return false
end

function Base.print(io::IO, r::VersionRange)
    m, n = r.lower.n, r.upper.n
    return if (m, n) == (0, 0)
        print(io, '*')
    elseif m == 0
        print(io, "0 - ")
        join(io, r.upper.t[1:n], '.')
    elseif n == 0
        join(io, r.lower.t[1:m], '.')
        print(io, " - *")
    else
        join(io, r.lower.t[1:m], '.')
        if r.lower != r.upper
            print(io, " - ")
            join(io, r.upper.t[1:n], '.')
        end
    end
end
Base.show(io::IO, r::VersionRange) = print(io, "VersionRange(\"", r, "\")")

Base.in(v::VersionNumber, r::VersionRange) = r.lower ≲ v ≲ r.upper

Base.intersect(a::VersionRange, b::VersionRange) =
    range_of(stricterlower(a.lower, b.lower), stricterupper(a.upper, b.upper))

# Normalize a scratch vector in place: sort, drop empties, join adjacent.
# Internal — the vector must be freshly owned by the caller.
#
# A single sweep is not always a fixpoint: `range_of(lo, up)` collapses a range
# whose bounds share a `.t` to a lower significance (e.g. `1.0.0 - 1` → `1`),
# and `isjoinable` is significance-sensitive (`isjoinable(0, 1.0.0)` is false
# but `isjoinable(0, 1)` is true). So a range can be flushed early against an
# un-collapsed neighbour and only become joinable after that neighbour
# collapses. We therefore sweep until the length stops shrinking; each merging
# sweep strictly reduces the count, so this terminates (usually after one extra
# length check, since most inputs are already canonical after the first pass).
function union!(ranges::Vector{VersionRange})
    prev = -1
    while length(ranges) != prev
        prev = length(ranges)
        _union_sweep!(ranges)
    end
    return ranges
end

function _union_sweep!(ranges::Vector{VersionRange})
    l = length(ranges)
    l == 0 && return ranges

    sort!(ranges, lt = (a, b) -> (isless_ll(a.lower, b.lower) || (a.lower == b.lower && isless_uu(a.upper, b.upper))))

    k0 = 1
    ks = findfirst(!isempty, ranges)
    ks === nothing && return empty!(ranges)

    lo, up, k0 = ranges[ks].lower, ranges[ks].upper, 1
    for k in (ks + 1):l
        isempty(ranges[k]) && continue
        lo1, up1 = ranges[k].lower, ranges[k].upper
        if isjoinable(up, lo1)
            isless_uu(up, up1) && (up = up1)
            continue
        end
        vr = range_of(lo, up)
        @assert !isempty(vr)
        ranges[k0] = vr
        k0 += 1
        lo, up = lo1, up1
    end
    vr = range_of(lo, up)
    if !isempty(vr)
        ranges[k0] = vr
        k0 += 1
    end
    resize!(ranges, k0 - 1)
    return ranges
end

###############
# VersionSpec #
###############

# The `ranges` field is frozen after construction: normalized (sorted,
# empties dropped, adjacent ranges joined), never mutated. That makes `==`
# and `hash` semantic and lets specs be shared freely (`copy` is identity).
# The field is a Memory so that no public `VersionSpec(...)` method collides
# with the implicit field constructor; everything goes through `make_spec`.
struct VersionSpec
    ranges::Memory{VersionRange}
end

function make_spec(ranges::Vector{VersionRange})
    union!(ranges)
    mem = Memory{VersionRange}(undef, length(ranges))
    copyto!(mem, ranges)
    return VersionSpec(mem)
end

VersionSpec(r::VersionRange) = make_spec(VersionRange[r])
VersionSpec(v::VersionNumber) = VersionSpec(VersionRange(v))
VersionSpec(s::AbstractString) = VersionSpec(VersionRange(s))
VersionSpec(v::AbstractVector) = make_spec(VersionRange[VersionRange(x) for x in v])
VersionSpec(vs::VersionSpec) = vs

const _all_versionspec = VersionSpec(VersionRange())
VersionSpec() = _all_versionspec

const empty_versionspec = make_spec(VersionRange[])
const _empty_symbol = "∅"

# Hot code
function Base.in(v::VersionNumber, s::VersionSpec)
    for r in s.ranges
        v in r && return true
    end
    return false
end

# Optimized batch version check for version lists.
# Fills dest[1:n] indicating which versions are in the VersionSpec.
# REQUIRES `versions[1:n]` to be sorted ascending: each range is matched over a
# single contiguous run, so an unsorted list gives wrong results. (The only
# caller passes the resolver's sorted per-package version list.)
# Note: only fills indices 1:n, leaves the rest of dest unchanged.
function matches_spec_range!(dest::BitVector, versions::AbstractVector{VersionNumber}, spec::VersionSpec, n::Int)
    @assert length(versions) == n
    @assert length(dest) >= n

    dest[1:n] .= false

    isempty(spec.ranges) && return dest

    @inbounds for range in spec.ranges
        # Find first version that could be in range
        i = 1
        while i <= n && !(range.lower ≲ versions[i])
            i += 1
        end

        # Mark all versions in range
        while i <= n && versions[i] ≲ range.upper
            dest[i] = true
            i += 1
        end
    end

    return dest
end

# Sound because specs are frozen after construction.
Base.copy(vs::VersionSpec) = vs

Base.isempty(s::VersionSpec) = all(isempty, s.ranges)
@assert isempty(empty_versionspec)

# Hot code, measure performance before changing
function Base.intersect(A::VersionSpec, B::VersionSpec)
    (isempty(A) || isempty(B)) && return empty_versionspec
    ranges = Vector{VersionRange}(undef, length(A.ranges) * length(B.ranges))
    i = 1
    @inbounds for a in A.ranges, b in B.ranges
        ranges[i] = intersect(a, b)
        i += 1
    end
    return make_spec(ranges)
end
Base.intersect(a::VersionNumber, B::VersionSpec) = a in B ? VersionSpec(a) : empty_versionspec
Base.intersect(A::VersionSpec, b::VersionNumber) = intersect(b, A)

function Base.union(A::VersionSpec, B::VersionSpec)
    A == B && return A
    ranges = Vector{VersionRange}(undef, length(A.ranges) + length(B.ranges))
    copyto!(ranges, A.ranges)
    copyto!(ranges, length(A.ranges) + 1, B.ranges, 1, length(B.ranges))
    return make_spec(ranges)
end

Base.:(==)(A::VersionSpec, B::VersionSpec) = A.ranges == B.ranges
Base.hash(s::VersionSpec, h::UInt) = hash(s.ranges, h + (0x2fd2ca6efa023f44 % UInt))

function Base.print(io::IO, s::VersionSpec)
    isempty(s) && return print(io, _empty_symbol)
    length(s.ranges) == 1 && return print(io, s.ranges[1])
    print(io, '[')
    for i in 1:length(s.ranges)
        1 < i && print(io, ", ")
        print(io, s.ranges[i])
    end
    return print(io, ']')
end

function Base.show(io::IO, s::VersionSpec)
    print(io, "VersionSpec(")
    if length(s.ranges) == 1
        print(io, '"', s.ranges[1], '"')
    else
        print(io, "[")
        for i in 1:length(s.ranges)
            1 < i && print(io, ", ")
            print(io, '"', s.ranges[i], '"')
        end
        print(io, ']')
    end
    return print(io, ")")
end

###################
# Semver notation #
###################

# The `[compat]` grammar. Disjoint from the range grammar
# above: bare versions mean caret here, and `^`/`~` are not accepted there.

"""
    semver_spec(s::String; throw::Bool = true) -> Union{VersionSpec, Nothing}

Parse a `[compat]`-style version specifier into a `VersionSpec`:
caret (default), tilde, `=`, `<`, `>=`/`≥`, spaced hyphen ranges, and
comma-separated unions. With `throw = false`, returns `nothing` on any
invalid input instead of throwing.
"""
function semver_spec(s::String; throw::Bool = true)
    ranges = VersionRange[]
    for ver in strip.(split(strip(s), ','))
        found_match = false
        for (ver_reg, f) in ver_regs
            m = match(ver_reg, ver)
            if m !== nothing
                range = try
                    f(m)
                catch err
                    # ArgumentError: semantic reject (e.g. "0.0.0"); Inexact/Overflow:
                    # version number too large to fit a VersionBound component.
                    if err isa ArgumentError
                        throw ? error(err.msg) : return nothing
                    elseif err isa InexactError || err isa OverflowError
                        throw ? error("invalid version specifier: \"$s\"") : return nothing
                    else
                        rethrow()
                    end
                end
                push!(ranges, range)
                found_match = true
                break
            end
        end
        if !found_match
            throw ? error("invalid version specifier: \"$s\"") : return nothing
        end
    end
    return make_spec(ranges)
end

function semver_interval(m::RegexMatch)
    @assert length(m.captures) == 4
    n_significant = count(x -> x !== nothing, m.captures) - 1
    typ, _major, _minor, _patch = m.captures
    major = parse(Int, _major)
    minor = (n_significant < 2) ? 0 : parse(Int, _minor)
    patch = (n_significant < 3) ? 0 : parse(Int, _patch)
    if n_significant == 3 && major == 0 && minor == 0 && patch == 0
        throw(ArgumentError("invalid version: \"0.0.0\""))
    end
    # Default type is :caret
    vertyp = (typ == "" || typ == "^") ? :caret : :tilde
    v0 = VersionBound((major, minor, patch))
    return if vertyp === :caret
        if major != 0
            range_of(v0, VersionBound((v0[1],)))
        elseif minor != 0
            range_of(v0, VersionBound((v0[1], v0[2])))
        else
            if n_significant == 1
                range_of(v0, VersionBound((0,)))
            elseif n_significant == 2
                range_of(v0, VersionBound((0, 0)))
            else
                range_of(v0, VersionBound((0, 0, v0[3])))
            end
        end
    else
        if n_significant == 3 || n_significant == 2
            range_of(v0, VersionBound((v0[1], v0[2])))
        else
            range_of(v0, VersionBound((v0[1],)))
        end
    end
end

const _inf = VersionBound("*")

function inequality_interval(m::RegexMatch)
    @assert length(m.captures) == 4
    typ, _major, _minor, _patch = m.captures
    n_significant = count(x -> x !== nothing, m.captures) - 1
    major = parse(Int, _major)
    minor = (n_significant < 2) ? 0 : parse(Int, _minor)
    patch = (n_significant < 3) ? 0 : parse(Int, _patch)
    if n_significant == 3 && major == 0 && minor == 0 && patch == 0
        throw(ArgumentError("invalid version: \"0.0.0\""))
    end
    v = VersionBound(major, minor, patch)
    if occursin(r"^<\s*$", typ)
        # `< v` = everything strictly below v at three-component precision
        if major == 0 && minor == 0 && patch == 0
            throw(ArgumentError("invalid version specifier: there are no versions below \"0\""))
        end
        nil = VersionBound(0, 0, 0)
        if v[3] == 0
            if v[2] == 0
                v1 = VersionBound(v[1] - 1)
            else
                v1 = VersionBound(v[1], v[2] - 1)
            end
        else
            v1 = VersionBound(v[1], v[2], v[3] - 1)
        end
        return range_of(nil, v1)
    elseif occursin(r"^=\s*$", typ)
        return VersionRange(v)
    elseif occursin(r"^>=\s*$", typ) || occursin(r"^≥\s*$", typ)
        return range_of(v, _inf)
    else
        throw(ArgumentError("invalid prefix $typ"))
    end
end

function hyphen_interval(m::RegexMatch)
    @assert length(m.captures) == 6
    _lower_major, _lower_minor, _lower_patch, _upper_major, _upper_minor, _upper_patch = m.captures
    lower_bound = if isnothing(_lower_minor)
        VersionBound(parse(Int, _lower_major))
    elseif isnothing(_lower_patch)
        VersionBound(parse(Int, _lower_major), parse(Int, _lower_minor))
    else
        VersionBound(parse(Int, _lower_major), parse(Int, _lower_minor), parse(Int, _lower_patch))
    end
    upper_bound = if isnothing(_upper_minor)
        VersionBound(parse(Int, _upper_major))
    elseif isnothing(_upper_patch)
        VersionBound(parse(Int, _upper_major), parse(Int, _upper_minor))
    else
        VersionBound(parse(Int, _upper_major), parse(Int, _upper_minor), parse(Int, _upper_patch))
    end
    return range_of(lower_bound, upper_bound)
end

const version = "v?([0-9]+?)(?:\\.([0-9]+?))?(?:\\.([0-9]+?))?"
const ver_regs = Pair{Regex, Any}[
    Regex("^([~^]?)?$version\$") => semver_interval,                                    # 0.5 ^0.4 ~0.3.2
    Regex("^((?:≥\\s*)|(?:>=\\s*)|(?:=\\s*)|(?:<\\s*))v?$version\$") => inequality_interval, # < 0.2, >= 0.5, = 1.2
    Regex("^[\\s]*$version[\\s]*?\\s-\\s[\\s]*?$version[\\s]*\$") => hyphen_interval,   # 0.7 - 1.3
]

end # module
