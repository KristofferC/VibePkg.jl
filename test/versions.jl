# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using VibePkg.Versions
using VibePkg.Versions: range_of, make_spec, empty_versionspec, matches_spec_range!

@testset "Versions" begin

    @testset "VersionBound" begin
        @test VersionBound("*").n == 0
        @test VersionBound("1").n == 1
        @test VersionBound("1.2").n == 2
        @test VersionBound("v1.2.3").n == 3
        @test VersionBound("1.2.3").t == (1, 2, 3)
        # trailing components are zeroed so field equality is semantic
        @test VersionBound("1.2").t == (1, 2, 0)
        @test_throws ArgumentError VersionBound(1, 2, 3, 4)
        # malformed input is an ArgumentError, never a BoundsError
        @test_throws ArgumentError VersionBound("")
        @test_throws ArgumentError VersionBound("   ")
        @test VersionBound(v"1.2.3") == VersionBound(1, 2, 3)
        # prerelease/build invisible to bounds
        @test VersionBound(v"1.2.3-rc1") == VersionBound(1, 2, 3)
    end

    @testset "VersionRange grammar" begin
        @test VersionRange("1.2.3") == VersionRange(v"1.2.3")
        @test string(VersionRange("1-2")) == "1 - 2"
        @test string(VersionRange("*")) == "*"
        @test string(VersionRange("1.2")) == "1.2"
        # "1.2" = [1.2.0, 1.3.0)
        @test v"1.2.0" in VersionRange("1.2")
        @test v"1.2.99" in VersionRange("1.2")
        @test !(v"1.3.0" in VersionRange("1.2"))
        # upper bound completes upward: "1.2-3.4" = [1.2.0, 3.5.0)
        r = VersionRange("1.2-3.4")
        @test v"1.2.0" in r
        @test v"3.4.99" in r
        @test !(v"3.5.0" in r)
        @test !(v"1.1.99" in r)
        # prereleases are inside their base version's range
        @test v"1.3.0-rc1" in VersionRange("1.2-1.3")
        @test v"3.4.1+0" in VersionRange("1.2-3.4")
        # spaced form parses the same way
        @test VersionRange("1.2 - 3.4") == VersionRange("1.2-3.4")
        @test_throws ArgumentError VersionRange("1-2-3")
        # empty strings and empty range components are ArgumentErrors,
        # never BoundsErrors from indexing into an empty component
        @test_throws ArgumentError VersionRange("")
        @test_throws ArgumentError VersionRange("  ")
        @test_throws ArgumentError VersionRange("-")
        @test_throws ArgumentError VersionRange("1-")
        @test_throws ArgumentError VersionRange("-1")
        @test_throws ArgumentError VersionRange("1 - ")
        # lower == upper collapses to the more significant bound
        @test VersionRange("1.2-1.2.0") == VersionRange("1.2.0")
        @test string(VersionRange("1.2-1.2.0")) == "1.2.0"
        # print symmetry (fixed vs Pkg's "0 -1.2.0")
        @test string(range_of(VersionBound(), VersionBound(1, 2, 0))) == "0 - 1.2.0"
        @test string(range_of(VersionBound(1, 2), VersionBound())) == "1.2 - *"
    end

    @testset "VersionSpec normalization & equality" begin
        # union at construction: sorted, adjacent joined
        @test VersionSpec(["1.3-1.5", "1.6-2"]) == VersionSpec("1.3-2")
        @test VersionSpec(["1.5-2.8", "2.5-3"]) == VersionSpec("1.5-3")
        # non-adjacent stay separate but sort deterministically
        s = VersionSpec(["3", "1"])
        @test s == VersionSpec(["1", "3"])
        @test string(s) == "[1, 3]"
        # empties dropped
        @test isempty(VersionSpec(range_of(VersionBound(2), VersionBound(1))))
        @test isempty(empty_versionspec)
        @test !isempty(VersionSpec())
        # semantic hash
        @test hash(VersionSpec(["1.3-1.5", "1.6-2"])) == hash(VersionSpec("1.3-2"))
        # construction does not mutate the caller's vector (fixed vs Pkg)
        ranges = [VersionRange("1.6-2"), VersionRange("1.3-1.5")]
        VersionSpec(ranges)
        @test ranges == [VersionRange("1.6-2"), VersionRange("1.3-1.5")]
        # compat operators are not part of this grammar
        @test_throws ArgumentError VersionSpec("^1.2")
        @test_throws ArgumentError VersionSpec("~1.2")
    end

    @testset "VersionSpec membership & set ops" begin
        @test v"1.5.2" in VersionSpec("1.2-1.7")
        @test !(v"2.0.0" in VersionSpec("1.2-1.7"))
        @test v"0.0.1" in VersionSpec()
        @test v"999.0.0" in VersionSpec()

        a = VersionSpec("1.2-1.7")
        b = VersionSpec("1.5-2.0")
        @test intersect(a, b) == VersionSpec("1.5-1.7")
        @test union(a, b) == VersionSpec("1.2-2.0")
        @test intersect(a, VersionSpec("2.5")) == empty_versionspec
        @test intersect(v"1.3.0", a) == VersionSpec(v"1.3.0")
        @test intersect(v"2.3.0", a) == empty_versionspec
        # copy is identity on frozen specs
        @test copy(a) === a
        @test VersionSpec(a) === a
        @test string(VersionSpec()) == "*"
        @test string(empty_versionspec) == "∅"
    end

    @testset "matches_spec_range!" begin
        versions = [v"1.0.0", v"1.1.0", v"1.5.0", v"2.0.0", v"3.1.0"]
        dest = falses(length(versions))
        matches_spec_range!(dest, versions, VersionSpec("1.1-2"), length(versions))
        @test dest == [false, true, true, true, false]
        matches_spec_range!(dest, versions, empty_versionspec, length(versions))
        @test dest == falses(5)
        matches_spec_range!(dest, versions, VersionSpec(["1.0", "3"]), length(versions))
        @test dest == [true, false, false, false, true]
    end

    @testset "semver_spec caret" begin
        # bare = caret
        @test semver_spec("1.2.3") == semver_spec("^1.2.3")
        @test v"1.2.3" in semver_spec("1.2.3")
        @test v"1.9.9" in semver_spec("1.2.3")
        @test !(v"2.0.0" in semver_spec("1.2.3"))
        @test !(v"1.2.2" in semver_spec("1.2.3"))
        @test v"1.0.0" in semver_spec("1")
        @test v"1.99.0" in semver_spec("1")
        # ^major.minor still spans to the next major
        @test v"1.2.0" in semver_spec("^1.2")
        @test v"1.99.0" in semver_spec("^1.2")
        @test !(v"2.0.0" in semver_spec("^1.2"))
        @test !(v"1.1.9" in semver_spec("^1.2"))
        # pre-1.0: leftmost nonzero component is breaking
        @test v"0.2.3" in semver_spec("0.2.3")
        @test v"0.2.9" in semver_spec("0.2.3")
        @test !(v"0.3.0" in semver_spec("0.2.3"))
        @test v"0.0.3" in semver_spec("0.0.3")
        @test !(v"0.0.4" in semver_spec("0.0.3"))
        # ^0 and ^0.0 span their zero prefix
        @test v"0.9.9" in semver_spec("0")
        @test !(v"1.0.0" in semver_spec("0"))
        @test v"0.0.9" in semver_spec("0.0")
        @test !(v"0.1.0" in semver_spec("0.0"))
    end

    @testset "semver_spec tilde" begin
        @test v"1.2.3" in semver_spec("~1.2.3")
        @test v"1.2.9" in semver_spec("~1.2.3")
        @test !(v"1.3.0" in semver_spec("~1.2.3"))
        @test !(v"1.2.2" in semver_spec("~1.2.3"))
        @test v"1.2.0" in semver_spec("~1.2")
        @test !(v"1.3.0" in semver_spec("~1.2"))
        # ~1 ≡ ^1
        @test semver_spec("~1") == semver_spec("^1")
        # pre-1.0 tilde always bumps the minor, even at 0.0.x (unlike caret)
        @test v"0.2.3" in semver_spec("~0.2.3")
        @test v"0.2.9" in semver_spec("~0.2.3")
        @test !(v"0.3.0" in semver_spec("~0.2.3"))
        @test v"0.0.3" in semver_spec("~0.0.3")
        @test v"0.0.9" in semver_spec("~0.0.3")
        @test !(v"0.1.0" in semver_spec("~0.0.3"))
        @test v"0.0.0" in semver_spec("~0.0")
        @test !(v"0.1.0" in semver_spec("~0.0"))
        @test v"0.9.9" in semver_spec("~0")
        @test !(v"1.0.0" in semver_spec("~0"))
    end

    @testset "semver_spec equality and inequalities" begin
        @test v"1.2.0" in semver_spec("=1.2")
        @test !(v"1.2.1" in semver_spec("=1.2"))
        @test semver_spec("=1.2.3") == VersionSpec(v"1.2.3")

        s = semver_spec(">= 1.2.3")
        @test v"1.2.3" in s && v"99.0.0" in s && !(v"1.2.2" in s)
        @test semver_spec("≥1.2.3") == semver_spec(">=1.2.3")

        # union of exact versions
        s = semver_spec("=0.10.1, =0.10.3")
        @test v"0.10.1" in s && v"0.10.3" in s && !(v"0.10.2" in s)

        s = semver_spec("< 1.2.3")
        @test v"1.2.2" in s && v"0.0.1" in s && !(v"1.2.3" in s)
        @test semver_spec("<1.2") == semver_spec("< 1.2.0")
        @test !(v"1.2.0" in semver_spec("<1.2"))
        @test v"1.1.99" in semver_spec("<1.2")

        # not part of the grammar
        @test_throws ErrorException semver_spec("> 1.2.3")
        @test_throws ErrorException semver_spec("<= 1.2.3")
        @test semver_spec("> 1.2.3", throw = false) === nothing
    end

    @testset "semver_spec hyphen and unions" begin
        s = semver_spec("1.2 - 3.4")
        @test v"1.2.0" in s && v"3.4.9" in s && !(v"3.5.0" in s) && !(v"1.1.9" in s)
        # fully-specified endpoints are an inclusive range
        s = semver_spec("1.2.3 - 4.5.6")
        @test v"1.2.3" in s && v"4.5.6" in s && !(v"4.5.7" in s) && !(v"1.2.2" in s)
        # unspaced hyphen is NOT the compat grammar
        @test semver_spec("1.2-3.4", throw = false) === nothing
        @test_throws ErrorException semver_spec("1.2-3.4")

        s = semver_spec("1.2.3, 2")
        @test v"1.5.0" in s && v"2.9.0" in s && !(v"3.0.0" in s)
        s = semver_spec("0.1, 0.3 - 0.5")
        @test v"0.1.9" in s && v"0.4.0" in s && !(v"0.2.0" in s)
    end

    @testset "semver_spec invalid inputs" begin
        @test_throws ErrorException semver_spec("0.0.0")
        @test_throws ErrorException semver_spec("^0.0.0")
        @test_throws ErrorException semver_spec("junk")
        @test_throws ErrorException semver_spec("")
        # clean error instead of Pkg's InexactError; respects throw=false
        @test_throws ErrorException semver_spec("<0")
        @test_throws ErrorException semver_spec("<0.0")
        @test semver_spec("<0", throw = false) === nothing
        @test semver_spec("0.0.0", throw = false) === nothing
        @test semver_spec("junk", throw = false) === nothing
    end
end
