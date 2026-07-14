# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using VibePkg.FuzzySorting: weighted_edit_distance, fuzzyscore, fuzzysort

@testset "weighted_edit_distance" begin
    # identity and plain unit-cost operations
    @test weighted_edit_distance("abc", "abc") == 0.0
    @test weighted_edit_distance("abc", "abd") == 1.0     # substitution
    @test weighted_edit_distance("abc", "abcd") == 1.0    # insertion
    @test weighted_edit_distance("abcd", "abc") == 1.0    # deletion
    @test weighted_edit_distance("ab", "ba") == 1.0       # transposition

    # confusable-character substitutions are discounted
    @test weighted_edit_distance("kat", "cat") ≈ 0.3
    @test weighted_edit_distance("casa", "case") ≈ 0.5    # ('a','e') weight
    @test weighted_edit_distance("teat", "test") ≈ 0.4    # ('a','s') keyboard pair

    # regression: the repeated-character discounts used to be nested inside
    # the branch requiring the compared characters to differ, which made
    # them unreachable — a doubled-letter typo cost a full unit
    @test weighted_edit_distance("abb", "ab") ≈ 0.3       # delete repeated char
    @test weighted_edit_distance("ab", "abb") ≈ 0.3       # insert repeated char
    @test weighted_edit_distance("jsonn", "json") ≈ 0.3
    @test weighted_edit_distance("exammple", "example") ≈ 0.3
    # the discount only applies to an actual repeat
    @test weighted_edit_distance("acb", "ab") == 1.0
    # symmetric pair of typos, each discounted independently
    @test weighted_edit_distance("aabc", "abcc") ≈ 0.6
    # the discount requires the doubled character to align with the target:
    # deleting or inserting a double unrelated to the other string is not a
    # doubled-letter typo and costs full units
    @test weighted_edit_distance("xaay", "xy") == 2.0
    @test weighted_edit_distance("xy", "xaay") == 2.0
    @test weighted_edit_distance("aa", "b") == 2.0
end

@testset "fuzzyscore ranks doubled-letter typos highly" begin
    # a doubled-character typo now beats a same-length unrelated candidate
    @test fuzzyscore("Exampple", "Example") > fuzzyscore("Exampple", "Grample")
    sorted, has_good = fuzzysort("Exampple", ["Nothing", "Example", "Grample"])
    @test first(sorted) == "Example"
    @test has_good
end
