# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg.Resolve
using VibePkg.Resolve: Fixed, Requires, ResolverError, ResolverTimeoutError, VersionWeight
using VibePkg.Versions: VersionSpec, VersionRange
import VibePkg.Fetch

# graph_from_data / sanity_tst / resolve_tst, ported from Pkg.jl
if !@isdefined(ResolveUtils)
    include("resolve_utils.jl")
end
using .ResolveUtils

# Pkg.jl resolve.jl "realistic" (timeout half) — the resolver's wall-clock
# budget is configurable through JULIA_PKG_RESOLVE_MAX_TIME, and a blown budget
# is a distinct ResolverTimeoutError (a subtype of the resolver's error).
@testset "resolver time-limit config" begin
    @test withenv(() -> Resolve.MaxSumParams().max_time, "JULIA_PKG_RESOLVE_MAX_TIME" => "0.5") == 0.5
    @test withenv(() -> Resolve.MaxSumParams().max_time, "JULIA_PKG_RESOLVE_MAX_TIME" => nothing) == 300.0
    @test ResolverTimeoutError <: Exception
    @test ResolverTimeoutError("slow") isa Exception
end

# ResolverTimeoutError must share ResolverError's user-facing formatting:
# print `msg` (stripping baked-in ANSI color when the IO has no color) plus
# any nested exception — not the default struct dump.
@testset "resolver error formatting" begin
    for E in (ResolverError, ResolverTimeoutError)
        te = E("\e[31mthe resolver failed\e[39m")
        @test sprint(showerror, te) == "the resolver failed"
        @test occursin("\e[31m", sprint(showerror, te; context = :color => true))
        @test !occursin(string(nameof(E)), sprint(showerror, te))
        te2 = E("outer", ErrorException("inner"))
        @test sprint(showerror, te2) == "outer\ninner"
    end
end

const uA = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
const uB = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
const uC = UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")

# The resolver's internal weight type must be order-isomorphic to
# VersionNumber (the maxsum solver relies on VersionWeight comparisons
# reproducing the version ordering exactly).
@testset "VersionWeight ordering matches VersionNumber" begin
    vs = [
        v"0.0.0", v"0.0.1", v"0.0.2", v"0.1.0", v"0.1.1", v"0.2.0",
        v"1.0.0", v"1.0.1", v"1.1.0", v"1.1.1", v"2.0.0", v"10.0.0",
    ]
    for a in vs, b in vs
        @test isless(VersionWeight(a), VersionWeight(b)) == isless(a, b)
        @test (VersionWeight(a) == VersionWeight(b)) == (a == b)
    end
end

# The major/minor/patch triple discards prerelease and build metadata, so
# distinct JLL builds would collapse to the same weight; the rank argument
# (the version's index in the package's sorted version list, as used by
# maxsum's Messages) must break those ties in version order.
@testset "VersionWeight rank distinguishes prerelease/build metadata" begin
    vs = [v"1.17.9", v"1.18.0-rc1", v"1.18.0", v"1.18.0+0", v"1.18.0+1", v"1.18.0+2", v"1.18.1"]
    @test issorted(vs)
    ws = [VersionWeight(v, i) for (i, v) in enumerate(vs)]
    for i in eachindex(vs), j in eachindex(vs)
        @test isless(ws[i], ws[j]) == isless(vs[i], vs[j])
        @test (ws[i] == ws[j]) == (vs[i] == vs[j])
    end
end

# secondmax must not overflow when fewer than two states are selected:
# without the guard it returns typemin - max, which wraps around to a huge
# positive value and corrupts the decimation order.
@testset "secondmax with fewer than two selected states" begin
    FV = Resolve.FieldValue
    f = FV[FV(1)]
    @test Resolve.secondmax(f) == typemin(FV)
    @test Resolve.secondmax(f) < zero(FV)              # i.e. no wrap-around
    f2 = FV[FV(1), FV(2)]
    @test Resolve.secondmax(f2, BitVector([false, true])) == typemin(FV)
    @test Resolve.secondmax(f2, BitVector([false, false])) == typemin(FV)
    @test Resolve.secondmax(f2) == FV(-1)              # normal two-state case
end

# Diagnostics must keep prerelease/build metadata: VersionSpec/VersionRange
# only track major.minor.patch, so distinct JLL builds would render
# identically through range_compressed_versionspec.
@testset "compressed_versions_string keeps build metadata" begin
    cvs = Resolve.compressed_versions_string
    pool = [v"1.18.0+1", v"1.18.0+2"]
    @test cvs(copy(pool), [v"1.18.0+1"]) == "1.18.0+1"
    @test cvs(copy(pool), [v"1.18.0+2"]) == "1.18.0+2"
    @test cvs([v"1.2.3-rc1", v"1.2.4"], [v"1.2.3-rc1"]) == "1.2.3-rc1"
    # metadata-free output is unchanged relative to range_compressed_versionspec
    pool2 = [v"1.0.0", v"1.0.1", v"1.1.0", v"2.0.0"]
    subset2 = [v"1.0.0", v"1.0.1", v"2.0.0"]
    @test cvs(copy(pool2), copy(subset2)) ==
        string(Resolve.range_compressed_versionspec(copy(pool2), copy(subset2)))
    @test cvs(copy(pool2)) == "1.0.0 - 2.0.0"
end

# Synthetic graph mirroring the shapes deps_graph feeds the resolver:
#   A: 1.0.0/1.1.0 depend on B@1;  2.0.0 depends on B@2 and weak-depends on C@1
#   B: 1.0.0, 2.0.0
#   C: 1.0.0
function mk_graph(reqs::Requires; fixed = Dict{UUID, Fixed}(), b_versions = [v"1.0.0", v"2.0.0"])
    vr(s) = VersionRange(s)
    deps = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
        uA => [Dict(vr("1") => Set([uB]), vr("2") => Set([uB]))],
        uB => [Dict{VersionRange, Set{UUID}}()],
        uC => [Dict{VersionRange, Set{UUID}}()],
    )
    compat = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
        uA => [Dict(vr("1") => Dict(uB => VersionSpec("1")), vr("2") => Dict(uB => VersionSpec("2")))],
        uB => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
        uC => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
    )
    weak_deps = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
        uA => [Dict(vr("2") => Set([uC]))],
        uB => [Dict{VersionRange, Set{UUID}}()],
        uC => [Dict{VersionRange, Set{UUID}}()],
    )
    weak_compat = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
        uA => [Dict(vr("2") => Dict(uC => VersionSpec("1")))],
        uB => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
        uC => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
    )
    versions = Dict{UUID, Vector{VersionNumber}}(
        uA => [v"1.0.0", v"1.1.0", v"2.0.0"],
        uB => b_versions,
        uC => [v"1.0.0"],
    )
    versions_per_registry = Dict{UUID, Vector{Set{VersionNumber}}}(
        u => [Set(vs)] for (u, vs) in versions
    )
    names = Dict{UUID, String}(uA => "A", uB => "B", uC => "C")
    return Resolve.Graph(
        deps, compat, weak_deps, weak_compat, versions, versions_per_registry,
        names, reqs, fixed, false, VERSION, Dict{UUID, VersionNumber}(),
    )
end

function solve(reqs::Requires; kwargs...)
    graph = mk_graph(reqs; kwargs...)
    Resolve.simplify_graph!(graph)
    return Resolve.resolve(graph)
end

@testset "Resolve" begin
    # unconstrained: pick the highest versions
    sol = solve(Requires(uA => VersionSpec("*")))
    @test sol[uA] == v"2.0.0"
    @test sol[uB] == v"2.0.0"
    @test !haskey(sol, uC)          # weak dep is not forced in

    # constraining B pulls A down
    sol = solve(Requires(uA => VersionSpec("*"), uB => VersionSpec("1")))
    @test sol[uA] == v"1.1.0"
    @test sol[uB] == v"1.0.0"

    # conflicting requirements
    @test_throws ResolverError solve(Requires(uA => VersionSpec("2"), uB => VersionSpec("1")))

    # conflict message shape is user-visible and pinned
    err = try
        solve(Requires(uA => VersionSpec("2"), uB => VersionSpec("1")))
    catch e
        e
    end
    @test occursin("Unsatisfiable requirements detected for package", sprint(showerror, err))

    # conflict log line fragments (graphtype.jl log_event_req!): fixing B at
    # 3.0.0 kills every version of A — whose explicit `*` requirement is then
    # spelled out — and B's own restriction chain terminates empty
    err2 = try
        solve(
            Requires(uA => VersionSpec("*"));
            fixed = Dict(uB => Fixed(v"3.0.0")),
            b_versions = [v"1.0.0", v"2.0.0", v"3.0.0"],
        )
    catch e
        e
    end
    @test err2 isa ResolverError
    # logstr bakes ANSI color codes into the message when stderr has color
    msg = replace(sprint(showerror, err2), r"\e\[[0-9;]*m" => "")
    @test occursin("restricted to versions * by an explicit requirement", msg)
    @test occursin("no versions left", msg)

    # fixed packages constrain like immovable requirements and are not in the output
    sol = solve(
        Requires(uA => VersionSpec("*"));
        fixed = Dict(uB => Fixed(v"1.0.0")),
    )
    @test sol[uA] == v"1.1.0"
    @test !haskey(sol, uB)

    # Pkg.jl#2740: the v2 branch is self-inconsistent (A@2 needs C@2 which
    # needs D@2, but A@2 itself needs D@1); MaxSum must fall back to the
    # consistent all-v1 solution instead of failing verification
    let vr = VersionRange, uD = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
        deps = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
            uA => [Dict(vr("1") => Set([uC]), vr("2") => Set([uC, uD]))],
            uB => [Dict(vr("1") => Set([uD]), vr("2") => Set([uD]))],
            uC => [Dict(vr("1") => Set([uB, uD]), vr("2") => Set([uB, uD]))],
            uD => [Dict{VersionRange, Set{UUID}}()],
        )
        compat = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
            uA => [
                Dict(
                    vr("1") => Dict(uC => VersionSpec("1")),
                    vr("2") => Dict(uC => VersionSpec("2"), uD => VersionSpec("1")),
                ),
            ],
            uB => [
                Dict(
                    vr("1") => Dict(uD => VersionSpec("1")),
                    vr("2") => Dict(uD => VersionSpec("2")),
                ),
            ],
            uC => [
                Dict(
                    vr("1") => Dict(uB => VersionSpec("1"), uD => VersionSpec("1")),
                    vr("2") => Dict(uB => VersionSpec("2"), uD => VersionSpec("2")),
                ),
            ],
            uD => [Dict{VersionRange, Dict{UUID, VersionSpec}}()],
        )
        weak_deps = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
            u => [Dict{VersionRange, Set{UUID}}()] for u in (uA, uB, uC, uD)
        )
        weak_compat = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
            u => [Dict{VersionRange, Dict{UUID, VersionSpec}}()] for u in (uA, uB, uC, uD)
        )
        versions = Dict{UUID, Vector{VersionNumber}}(
            u => [v"1.0.0", v"2.0.0"] for u in (uA, uB, uC, uD)
        )
        versions_per_registry = Dict{UUID, Vector{Set{VersionNumber}}}(
            u => [Set(vs)] for (u, vs) in versions
        )
        names = Dict{UUID, String}(uA => "A", uB => "B", uC => "C", uD => "D")
        graph = Resolve.Graph(
            deps, compat, weak_deps, weak_compat, versions, versions_per_registry,
            names, Requires(uA => VersionSpec("*"), uB => VersionSpec("*")),
            Dict{UUID, Fixed}(), false, VERSION, Dict{UUID, VersionNumber}(),
        )
        Resolve.simplify_graph!(graph)
        sol = Resolve.resolve(graph)
        @test sol == Dict(uA => v"1.0.0", uB => v"1.0.0", uC => v"1.0.0", uD => v"1.0.0")
    end
end

# Versions that differ only in build metadata (as JLLs produce) must flow
# through the resolver: the highest build wins and resolver diagnostics keep
# the build suffix so distinct builds stay distinguishable.
@testset "JLL build metadata in resolution and diagnostics" begin
    sol = solve(Requires(uB => VersionSpec("1")); b_versions = [v"1.0.0+1", v"1.0.0+2"])
    @test sol[uB] == v"1.0.0+2"

    err = try
        solve(Requires(uB => VersionSpec("2")); b_versions = [v"1.0.0+1"])
    catch e
        e
    end
    @test err isa ResolverError
    msg = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
    @test occursin("possible versions are: 1.0.0+1", msg)
end

# maxsum must close its timeout timer and pop its graph snapshot even when
# convergence throws (try/finally): corrupt an ignored package's constraints
# so update_solution! throws inside converge!, then check the solve stack.
@testset "maxsum cleans up on throw" begin
    graph = mk_graph(Requires(uA => VersionSpec("*")))
    Resolve.simplify_graph!(graph)
    depth = length(graph.solve_stack)
    p0 = graph.data.pdict[uA]
    graph.ignored[p0] = true
    fill!(graph.gconstr[p0], false)   # no state left: update_solution! throws
    @test_throws MethodError Resolve.maxsum(graph)
    @test length(graph.solve_stack) == depth
end

# Pkg.jl resolve.jl "realistic" — four large real-world dependency graphs
# (Julia #21485, Pkg #1949/#3232/#3878) exercised through sanity_check +
# resolve; the last is an unsat graph that must hit the wall-clock budget
# (ResolverError with validation, ResolverTimeoutError without it).
@testset "realistic" begin
    tmp = mktempdir()
    Fetch.unpack(joinpath(@__DIR__, "resolvedata.tar.gz"), tmp)

    include(joinpath(tmp, "resolvedata1.jl"))            # Julia #21485
    @test sanity_tst(ResolveData.deps_data, ResolveData.problematic_data)
    @test resolve_tst(ResolveData.deps_data, ResolveData.reqs_data, ResolveData.want_data)

    include(joinpath(tmp, "resolvedata2.jl"))            # Pkg #1949
    @test sanity_tst(ResolveData2.deps_data, ResolveData2.problematic_data)
    @test resolve_tst(ResolveData2.deps_data, ResolveData2.reqs_data, ResolveData2.want_data)

    include(joinpath(tmp, "resolvedata3.jl"))            # Pkg #3232
    @test sanity_tst(ResolveData3.deps_data, ResolveData3.problematic_data)
    @test resolve_tst(ResolveData3.deps_data, ResolveData3.reqs_data, ResolveData3.want_data)

    include(joinpath(tmp, "resolvedata4.jl"))            # Pkg #3878 (unsat, slow)
    @test sanity_tst(ResolveData4.deps_data, ResolveData4.problematic_data)
    withenv("JULIA_PKG_RESOLVE_MAX_TIME" => 10) do
        @test_throws ResolverError resolve_tst(ResolveData4.deps_data, ResolveData4.reqs_data, ResolveData4.want_data)
    end
    withenv("JULIA_PKG_RESOLVE_MAX_TIME" => 1.0e-5) do
        # may fail if graph preprocessing or the greedy solver improve
        @test_throws ResolverTimeoutError resolve_tst(ResolveData4.deps_data, ResolveData4.reqs_data, ResolveData4.want_data; validate_versions = false)
    end
end

# Pkg.jl resolve.jl "nasty" — a randomly generated adversarial graph with two
# planted cyclic solutions; the resolver must find the better one (sat) and
# error on the unsatisfiable variant.
@testset "nasty" begin
    include("NastyGenerator.jl")
    deps_data, reqs_data, want_data, problematic_data = NastyGenerator.generate_nasty(5, 20, q = 20, d = 4, sat = true)
    @test sanity_tst(deps_data, problematic_data)
    @test resolve_tst(deps_data, reqs_data, want_data)

    deps_data, reqs_data, want_data, problematic_data = NastyGenerator.generate_nasty(5, 20, q = 20, d = 4, sat = false)
    @test sanity_tst(deps_data, problematic_data)
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)
end

# Pkg.jl resolve.jl "schemes" — 15 hand-built dependency graphs covering
# DAGs, cycles, mutually-exclusive solutions, (in)consistency, weak deps,
# unconnected components, and the #3232/#4030 regressions. Each runs
# sanity_check + resolve and asserts the exact chosen version set.
@testset "schemes" begin
    VERBOSE && @info("SCHEME 1")
    ## DEPENDENCY SCHEME 1: TWO PACKAGES, DAG
    deps_data = Any[
        ["A", v"1", "B", "1-*"],
        ["A", v"2", "B", "2-*"],
        ["B", v"1"],
        ["B", v"2"],
    ]

    @test sanity_tst(deps_data)
    @test sanity_tst(deps_data, pkgs = ["A", "B"])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["A"])

    # require just B
    reqs_data = Any[
        ["B", "*"],
    ]

    want_data = Dict("B" => v"2")
    resolve_tst(deps_data, reqs_data, want_data)
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A: must bring in B
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 2")
    ## DEPENDENCY SCHEME 2: TWO PACKAGES, CYCLIC
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"2", "B", "1-*"],
        ["B", v"1", "A", "2-*"],
        ["B", v"2", "A", "1-*"],
    ]

    @test sanity_tst(deps_data)

    # require just A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just B, force lower version
    reqs_data = Any[
        ["B", "1"],
    ]
    want_data = Dict("A" => v"2", "B" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A, force lower version
    reqs_data = Any[
        ["A", "1"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 3")
    ## DEPENDENCY SCHEME 3: THREE PACKAGES, CYCLIC, TWO MUTUALLY EXCLUSIVE SOLUTIONS
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"2", "B", "1"],
        ["B", v"1", "C", "2-*"],
        ["B", v"2", "C", "1"],
        ["C", v"1", "A", "1"],
        ["C", v"2", "A", "2-*"],
    ]

    @test sanity_tst(deps_data)

    # require just A (must choose solution which has the highest version for A)
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"1", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just B (must choose solution which has the highest version for B)
    reqs_data = Any[
        ["B", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A, force lower version
    reqs_data = Any[
        ["A", "1"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A and C, incompatible versions
    reqs_data = Any[
        ["A", "1"],
        ["C", "2-*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 4")
    ## DEPENDENCY SCHEME 4: TWO PACKAGES, DAG, WITH TRIVIAL INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["B", v"1"],
    ]

    @test sanity_tst(deps_data, [("A", v"1")])
    @test sanity_tst(deps_data, pkgs = ["B"])

    # require B (must not give errors)
    reqs_data = Any[
        ["B", "*"],
    ]
    want_data = Dict("B" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A (must give an error)
    reqs_data = Any[
        ["A", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 5")
    ## DEPENDENCY SCHEME 5: THREE PACKAGES, DAG, WITH IMPLICIT INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"1", "C", "2-*"],
        ["A", v"2", "B", "1"],
        ["A", v"2", "C", "1"],
        ["B", v"1", "C", "2-*"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1"],
        ["C", v"2"],
    ]

    @test sanity_tst(deps_data, [("A", v"2")])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["C"])

    # require A, any version (must use the highest non-inconsistent)
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A, force highest version (impossible)
    reqs_data = Any[
        ["A", "2-*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 6")
    ## DEPENDENCY SCHEME 6: TWO PACKAGES, CYCLIC, TOTALLY INCONSISTENT
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"2", "B", "1"],
        ["B", v"1", "A", "1"],
        ["B", v"2", "A", "2-*"],
    ]

    @test sanity_tst(
        deps_data, [
            ("A", v"1"), ("A", v"2"),
            ("B", v"1"), ("B", v"2"),
        ]
    )

    # require A (impossible)
    reqs_data = Any[
        ["A", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require B (impossible)
    reqs_data = Any[
        ["B", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 7")
    ## DEPENDENCY SCHEME 7: THREE PACKAGES, CYCLIC, WITH INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "1"],
        ["A", v"2", "B", "2-*"],
        ["B", v"1", "C", "1"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1", "A", "2-*"],
        ["C", v"2", "A", "2-*"],
    ]

    @test sanity_tst(
        deps_data, [
            ("A", v"1"), ("B", v"1"),
            ("C", v"1"),
        ]
    )

    # require A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require C
    reqs_data = Any[
        ["C", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require C, lowest version (impossible)
    reqs_data = Any[
        ["C", "1"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 8")
    ## DEPENDENCY SCHEME 8: THREE PACKAGES, CYCLIC, TOTALLY INCONSISTENT
    deps_data = Any[
        ["A", v"1", "B", "1"],
        ["A", v"2", "B", "2-*"],
        ["B", v"1", "C", "1"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1", "A", "2-*"],
        ["C", v"2", "A", "1"],
    ]

    @test sanity_tst(
        deps_data, [
            ("A", v"1"), ("A", v"2"),
            ("B", v"1"), ("B", v"2"),
            ("C", v"1"), ("C", v"2"),
        ]
    )

    # require A (impossible)
    reqs_data = Any[
        ["A", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require B (impossible)
    reqs_data = Any[
        ["B", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require C (impossible)
    reqs_data = Any[
        ["C", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    VERBOSE && @info("SCHEME 9")
    ## DEPENDENCY SCHEME 9: SIX PACKAGES, DAG
    deps_data = Any[
        ["A", v"1"],
        ["A", v"2"],
        ["A", v"3"],
        ["B", v"1", "A", "1"],
        ["B", v"2", "A", "*"],
        ["C", v"1", "A", "2"],
        ["C", v"2", "A", "2-*"],
        ["D", v"1", "B", "1-*"],
        ["D", v"2", "B", "2-*"],
        ["E", v"1", "D", "*"],
        ["F", v"1", "A", "1-2"],
        ["F", v"1", "E", "*"],
        ["F", v"2", "C", "2-*"],
        ["F", v"2", "E", "*"],
    ]

    @test sanity_tst(deps_data)

    # require just F
    reqs_data = Any[
        ["F", "*"],
    ]
    want_data = Dict(
        "A" => v"3", "B" => v"2", "C" => v"2",
        "D" => v"2", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just F, lower version
    reqs_data = Any[
        ["F", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "B" => v"2", "D" => v"2",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and B; force lower B version -> must bring down F, A, and D versions too
    reqs_data = Any[
        ["F", "*"],
        ["B", "1"],
    ]
    want_data = Dict(
        "A" => v"1", "B" => v"1", "D" => v"1",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and D; force lower D version -> must not bring down F version
    reqs_data = Any[
        ["F", "*"],
        ["D", "1"],
    ]
    want_data = Dict(
        "A" => v"3", "B" => v"2", "C" => v"2",
        "D" => v"1", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and C; force lower C version -> must bring down F and A versions
    reqs_data = Any[
        ["F", "*"],
        ["C", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "B" => v"2", "C" => v"1",
        "D" => v"2", "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    VERBOSE && @info("SCHEME 10")
    ## DEPENDENCY SCHEME 10: FIVE PACKAGES, SAME AS SCHEMES 5 + 1, UNCONNECTED
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"1", "C", "2-*"],
        ["A", v"2", "B", "1"],
        ["A", v"2", "C", "1"],
        ["B", v"1", "C", "2-*"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1"],
        ["C", v"2"],
        ["D", v"1", "E", "1-*"],
        ["D", v"2", "E", "2-*"],
        ["E", v"1"],
        ["E", v"2"],
    ]

    @test sanity_tst(deps_data, [("A", v"2")])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["D"])
    @test sanity_tst(deps_data, pkgs = ["E"])
    @test sanity_tst(deps_data, pkgs = ["B", "D"])

    # require A, any version (must use the highest non-inconsistent)
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just D: must bring in E
    reqs_data = Any[
        ["D", "*"],
    ]
    want_data = Dict("D" => v"2", "E" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    # require A and D, must be the merge of the previous two cases
    reqs_data = Any[
        ["A", "*"],
        ["D", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"2", "D" => v"2", "E" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 11")
    ## DEPENDENCY SCHEME 11: FOUR PACKAGES, WITH AN INCONSISTENCY
    ## ref Pkg.jl issue #2740
    deps_data = Any[
        ["A", v"1", "C", "1"],
        ["A", v"2", "C", "2"],
        ["A", v"2", "D", "1"],
        ["B", v"1", "D", "1"],
        ["B", v"2", "D", "2"],
        ["C", v"1", "D", "1"],
        ["C", v"1", "B", "1"],
        ["C", v"2", "D", "2"],
        ["C", v"2", "B", "2"],
        ["D", v"1"],
        ["D", v"2"],
    ]

    @test sanity_tst(deps_data, [("A", v"2")])

    # require A & B, any version (must use the highest non-inconsistent)
    reqs_data = Any[
        ["A", "*"],
        ["B", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"1", "C" => v"1", "D" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 12")
    ## DEPENDENCY SCHEME 12: TWO PACKAGES, DAG, WEAK DEPENDENCY
    deps_data = Any[
        ["A", v"1", "B", "1-*", :weak],
        ["A", v"2", "B", "2-*", :weak],
        ["B", v"1"],
        ["B", v"2"],
    ]

    @test sanity_tst(deps_data)
    @test sanity_tst(deps_data, pkgs = ["A", "B"])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["A"])

    # require just B
    reqs_data = Any[
        ["B", "*"],
    ]
    want_data = Dict("B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A and B
    reqs_data = Any[
        ["A", "*"],
        ["B", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A and B, invompatible versions
    reqs_data = Any[
        ["A", "2-*"],
        ["B", "1"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 13")
    ## DEPENDENCY SCHEME 13: LIKE 9 (SIX PACKAGES, DAG), WITH SOME WEAK DEPENDENCIES
    deps_data = Any[
        ["A", v"1"],
        ["A", v"2"],
        ["A", v"3"],
        ["B", v"1", "A", "1"],
        ["B", v"2", "A", "*"],
        ["C", v"1", "A", "2", :weak],
        ["C", v"2", "A", "2-*"],
        ["D", v"1", "B", "1-*"],
        ["D", v"2", "B", "2-*", :weak],
        ["E", v"1", "D", "*"],
        ["F", v"1", "A", "1-2"],
        ["F", v"1", "E", "*"],
        ["F", v"2", "C", "2-*"],
        ["F", v"2", "E", "*"],
    ]

    @test sanity_tst(deps_data)

    # require just F
    reqs_data = Any[
        ["F", "*"],
    ]
    want_data = Dict(
        "A" => v"3", "C" => v"2",
        "D" => v"2", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just F, lower version
    reqs_data = Any[
        ["F", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "D" => v"2",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and B; force lower B version -> must bring down F, A, and D versions too
    reqs_data = Any[
        ["F", "*"],
        ["B", "1"],
    ]
    want_data = Dict(
        "A" => v"1", "B" => v"1", "D" => v"1",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and D; force lower D version -> must not bring down F version, and bring in B
    reqs_data = Any[
        ["F", "*"],
        ["D", "1"],
    ]
    want_data = Dict(
        "A" => v"3", "B" => v"2", "C" => v"2",
        "D" => v"1", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and C; force lower C version -> must bring down F and A versions
    reqs_data = Any[
        ["F", "*"],
        ["C", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "C" => v"1",
        "D" => v"2", "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 14")
    ## DEPENDENCY SCHEME 14: A NASTY GRAPH WITH A LOCAL OPTIMUM
    ## (REDUCED VERSION OF REALISTIC SCHEME 17 BELOW, ref Pkg.jl issue #3232)
    deps_data = Any[
        ["A", v"1", "X", "*"],
        ["B", v"1"],
        ["B", v"2"],
        ["C", v"1"],
        ["C", v"2", "G", "2"],
        ["C", v"2", "H", "*"],
        ["D", v"1"],
        ["D", v"2", "C", "*"],
        ["Y", v"0.1"],
        ["Y", v"0.2.1", "B", "1"],
        ["Y", v"0.2.2"],
        ["X", v"0.1", "Y", "0.1"],
        ["X", v"0.2", "Y", "0.2"],
        ["E", v"1", "X", "0.1"],
        ["F", v"1", "I", "1"],
        ["G", v"1", "E", "*"],
        ["G", v"2"],
        ["H", v"1", "B", "*"],
        ["H", v"1", "F", "*"],
        ["H", v"1", "I", "*"],
        ["I", v"1"],
        ["I", v"2"],
    ]

    @test sanity_tst(deps_data)

    # require A and D
    reqs_data = Any[
        ["A", "*"],
        ["D", "*"],
    ]
    want_data = Dict(
        "A" => v"1",
        "B" => v"2",
        "C" => v"2",
        "D" => v"2",
        "Y" => v"0.2.2",
        "X" => v"0.2",
        "F" => v"1",
        "G" => v"2",
        "H" => v"1",
        "I" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just D
    reqs_data = Any[
        ["D", "*"],
    ]
    want_data = Dict(
        "B" => v"2",
        "C" => v"2",
        "D" => v"2",
        "F" => v"1",
        "G" => v"2",
        "H" => v"1",
        "I" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict(
        "A" => v"1",
        "Y" => v"0.2.2",
        "X" => v"0.2",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A, D, and lower version of Y
    reqs_data = Any[
        ["A", "*"],
        ["D", "*"],
        ["Y", "0.2.1"],
    ]
    want_data = Dict(
        "A" => v"1",
        "B" => v"1",
        "C" => v"2",
        "D" => v"2",
        "Y" => v"0.2.1",
        "X" => v"0.2",
        "F" => v"1",
        "G" => v"2",
        "H" => v"1",
        "I" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 15")
    ## DEPENDENCY SCHEME 15: A GRAPH WITH A WEAK DEPENDENCE
    ## (REDUCED VERSION OF A REALISTIC SCHEME, ref Pkg.jl issue #4030)
    deps_data = Any[
        ["A", v"1"],
        ["A", v"2", "C", "*"],
        ["B", v"1", "D", "1", :weak],
        ["C", v"1", "E", "*"],
        ["C", v"2", "E", "*"],
        ["C", v"2", "B", "1"],
        ["E", v"1", "D", "1"],
        ["E", v"2", "F", "1"],
        ["F", v"1", "D", "*"],
        ["D", v"1"],
        ["D", v"2"],
    ]

    @test sanity_tst(deps_data)

    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict(
        "A" => v"2",
        "B" => v"1",
        "C" => v"2",
        "D" => v"1",
        "E" => v"2",
        "F" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

end
