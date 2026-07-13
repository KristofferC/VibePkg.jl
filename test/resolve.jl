# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg.Resolve
using VibePkg.Resolve: Fixed, Requires, ResolverError
using VibePkg.Versions: VersionSpec, VersionRange

const uA = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
const uB = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
const uC = UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")

# Synthetic graph mirroring the shapes deps_graph feeds the resolver:
#   A: 1.0.0/1.1.0 depend on B@1;  2.0.0 depends on B@2 and weak-depends on C@1
#   B: 1.0.0, 2.0.0
#   C: 1.0.0
function solve(reqs::Requires; fixed = Dict{UUID, Fixed}(), b_versions = [v"1.0.0", v"2.0.0"])
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
    graph = Resolve.Graph(
        deps, compat, weak_deps, weak_compat, versions, versions_per_registry,
        names, reqs, fixed, false, VERSION, Dict{UUID, VersionNumber}(),
    )
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
