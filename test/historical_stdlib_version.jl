# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using UUIDs: UUID
using VibePkg
using VibePkg.Stdlibs
using VibePkg.Errors: PkgError
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries, RegistryInstance
using VibePkg.Environments: load_environment
using VibePkg.Planning: plan_add, plan_resolve, PackageRequest
using VibePkg.EnvFiles: entry_version, entry_tree_hash
using VibePkg.Resolve: ResolverError

# HistoricalStdlibVersions.jl hardcodes `Pkg.Types`, so it cannot populate
# VibePkg's tables directly. But VibePkg.Stdlibs exposes the same protocol as
# Pkg (STDLIBS_BY_VERSION / UNREGISTERED_STDLIBS constants — see the module
# docstring), so we bridge HSV's data into it, converting HSV's StdlibInfo into
# VibePkg's identically-shaped one. Auto-register into Pkg.Types is off.
ENV["HISTORICAL_STDLIB_VERSIONS_AUTO_REGISTER"] = "false"
using HistoricalStdlibVersions
const HSV = HistoricalStdlibVersions

const S = VibePkg.Stdlibs
_conv(info) = S.StdlibInfo(info.name, info.uuid, info.version, info.deps, info.weakdeps)

function hist_unregister!()
    empty!(S.STDLIBS_BY_VERSION)
    empty!(S.UNREGISTERED_STDLIBS)
    return nothing
end

function hist_register!()
    hist_unregister!()
    for (ver, dict) in HSV.STDLIBS_BY_VERSION
        push!(S.STDLIBS_BY_VERSION, ver => S.DictStdLibs(u => _conv(i) for (u, i) in dict))
    end
    for (u, i) in HSV.UNREGISTERED_STDLIBS
        S.UNREGISTERED_STDLIBS[u] = _conv(i)
    end
    return nothing
end

networkoptions_uuid = UUID("ca575930-c2e3-43a9-ace4-1e988b2c1908")
pkg_uuid = UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
mbedtls_jll_uuid = UUID("c8ffd9c3-330d-5841-b78e-0817d7145fa1")
gmp_jll_uuid = UUID("781609d7-10c4-51f6-84f2-b8444358ff6d")
mpfr_jll_uuid = UUID("3a97d323-0669-5f0c-9066-3539efd106a3")
linalg_uuid = UUID("37e2e46d-f89d-539d-b4ee-838fcccc9c8e")

# A synthetic registry modeling the real GMP_jll/MPFR_jll graph across julia
# versions: 6.1.2/4.0.2 for julia 1.5, 6.2.0/4.1.1 for julia 1.6, with the
# JLLs gated by `[compat] julia`. MPFR_jll pulls GMP_jll transitively. Only
# registry metadata is written — the resolver reads it without downloading.
function make_jll_registry(depot)
    reg = joinpath(depot, "registries", "JllReg")
    mkpath(reg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "JllReg"
        uuid = "53338594-aafe-5451-b93e-139f81909106"

        [packages]
        $gmp_jll_uuid = { name = "GMP_jll", path = "G/GMP_jll" }
        $mpfr_jll_uuid = { name = "MPFR_jll", path = "M/MPFR_jll" }
        """
    )
    g = mkpath(joinpath(reg, "G", "GMP_jll"))
    write(joinpath(g, "Package.toml"), "name = \"GMP_jll\"\nuuid = \"$gmp_jll_uuid\"\nrepo = \"https://x.invalid/GMP_jll.git\"\n")
    write(
        joinpath(g, "Versions.toml"), """
        ["6.1.2"]
        git-tree-sha1 = "1111111111111111111111111111111111111111"

        ["6.2.0"]
        git-tree-sha1 = "2222222222222222222222222222222222222222"
        """
    )
    write(
        joinpath(g, "Compat.toml"), """
        ["6.1.2"]
        julia = "1.5"

        ["6.2.0"]
        julia = "1.6"
        """
    )
    m = mkpath(joinpath(reg, "M", "MPFR_jll"))
    write(joinpath(m, "Package.toml"), "name = \"MPFR_jll\"\nuuid = \"$mpfr_jll_uuid\"\nrepo = \"https://x.invalid/MPFR_jll.git\"\n")
    write(
        joinpath(m, "Versions.toml"), """
        ["4.0.2"]
        git-tree-sha1 = "3333333333333333333333333333333333333333"

        ["4.1.1"]
        git-tree-sha1 = "4444444444444444444444444444444444444444"
        """
    )
    write(
        joinpath(m, "Deps.toml"), """
        ["4.0.2"]
        GMP_jll = "$gmp_jll_uuid"

        ["4.1.1"]
        GMP_jll = "$gmp_jll_uuid"
        """
    )
    write(
        joinpath(m, "Compat.toml"), """
        ["4.0.2"]
        julia = "1.5"
        GMP_jll = "6"

        ["4.1.1"]
        julia = "1.6"
        GMP_jll = "6.2"
        """
    )
    return reg
end

try
    # Pkg.jl historical_stdlib_version.jl "is_stdlib() across versions" — with
    # the historical tables loaded, is_stdlib(uuid, julia_version) is correct
    # across julia versions for a became-stdlib package (NetworkOptions), an
    # always-unregistered stdlib (Pkg), and a stopped-being-stdlib jll
    # (MbedTLS_jll); an unknown major.minor throws; after unregister only the
    # current version resolves.
    @testset "is_stdlib() across versions" begin
        hist_register!()

        # NetworkOptions became an stdlib in v1.6 (and is registered)
        @test is_stdlib(networkoptions_uuid)
        @test is_stdlib(networkoptions_uuid, v"1.6")
        @test !is_stdlib(networkoptions_uuid, v"1.5")
        @test !is_stdlib(networkoptions_uuid, v"1.0.0")
        @test !is_stdlib(networkoptions_uuid, v"0.7")
        # julia_version === nothing treats registered stdlibs as normal packages
        @test !is_stdlib(networkoptions_uuid, nothing)

        # Pkg is an unregistered stdlib and has always been an stdlib
        @test is_stdlib(pkg_uuid)
        @test is_stdlib(pkg_uuid, v"1.0")
        @test is_stdlib(pkg_uuid, v"1.6")
        @test is_stdlib(pkg_uuid, v"0.7")
        @test is_stdlib(pkg_uuid, nothing)

        # We can't serve unknown major.minor versions (patches can still match)
        @test_throws PkgError is_stdlib(pkg_uuid, v"999.999.999")
        @test is_stdlib(pkg_uuid, v"1.10.999")

        # MbedTLS_jll stopped being an stdlib in 1.12
        @test !is_stdlib(mbedtls_jll_uuid)
        @test !is_stdlib(mbedtls_jll_uuid, v"1.12")
        @test is_stdlib(mbedtls_jll_uuid, v"1.11")
        @test is_stdlib(mbedtls_jll_uuid, v"1.10")

        hist_unregister!()
        # Without the tables we can still probe the current version, but asking
        # for a particular julia version throws.
        @test is_stdlib(networkoptions_uuid)
        @test_throws PkgError is_stdlib(networkoptions_uuid, v"1.6")
    end

    # Pkg.jl historical_stdlib_version.jl "Pkg.add()/resolve with julia_version"
    # — the reference resolves against the General registry and asserts the
    # installed JLL version per julia version (GMP_jll 6.2.0 for v1.6, 6.2.1 for
    # v1.7, ...). Those versions come straight from the historical stdlib tables,
    # so we assert them hermetically via `stdlib_version` — no registry/network.
    @testset "stdlib versions across julia versions" begin
        hist_register!()

        # A jll that went from normal package -> stdlib in v1.6: it carries no
        # stdlib version before v1.6, then version-appropriate builds after.
        @test !is_stdlib(gmp_jll_uuid, v"1.5")
        @test stdlib_version(gmp_jll_uuid, v"1.5") === nothing
        @test is_stdlib(gmp_jll_uuid, v"1.6")
        @test stdlib_version(gmp_jll_uuid, v"1.6") == v"6.2.0+5"
        @test stdlib_version(gmp_jll_uuid, v"1.7") == v"6.2.1+1"

        # MPFR_jll tracks the same transition, at its own versions.
        @test !is_stdlib(mpfr_jll_uuid, v"1.5")
        @test is_stdlib(mpfr_jll_uuid, v"1.6")
        let v16 = stdlib_version(mpfr_jll_uuid, v"1.6")
            @test v16 !== nothing && v16.major == 4 && v16.minor == 1
        end

        # An always-stdlib, unversioned library (LinearAlgebra) never carries a
        # version, on any julia.
        @test is_stdlib(linalg_uuid, v"1.6")
        @test stdlib_version(linalg_uuid, v"1.6") === nothing
        @test stdlib_version(linalg_uuid, v"1.7") === nothing

        # julia_version === nothing: registered stdlibs resolve as normal
        # packages, so they report no fixed stdlib version and NetworkOptions is
        # not treated as an stdlib; unregistered stdlibs (Pkg) still are.
        @test !is_stdlib(gmp_jll_uuid, nothing)
        @test stdlib_version(gmp_jll_uuid, nothing) === nothing
        @test haskey(S.get_last_stdlibs(nothing), pkg_uuid)
        @test !haskey(S.get_last_stdlibs(nothing), networkoptions_uuid)

        hist_unregister!()
    end

    # Pkg.jl historical_stdlib_version.jl "Resolving for another version of
    # Julia" — end-to-end resolver checks (no download; planning is pure). Two
    # mechanisms feed version selection: registry `[compat] julia` gating for
    # not-yet-stdlib versions, and the historical tables fixing a package once
    # it has become a versioned stdlib.
    @testset "resolve: stdlib version per julia_version" begin
        hist_register!()
        # GMP_jll became a versioned stdlib in v1.6. Resolving it for a historical
        # julia version returns that julia's stdlib build straight from the tables
        # (no registry needed, no tree hash), and differs across julia versions.
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "[deps]\nGMP_jll = \"$gmp_jll_uuid\"\n")
            depots = depot_stack([mkpath(joinpath(dir, "depot"))])
            env = load_environment(dir; depots)
            for (jv, want) in ((v"1.6", v"6.2.0+5"), (v"1.7", v"6.2.1+1"))
                plan = plan_resolve(env, RegistryInstance[], Config(depots); julia_version = jv)
                e = plan.manifest[gmp_jll_uuid]
                @test entry_version(e) == want
                @test entry_tree_hash(e) === nothing   # stdlib: not registry-tracked
            end
        end
        hist_unregister!()
    end

    @testset "resolve: transitive JLL per julia_version" begin
        hist_register!()
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            make_jll_registry(depot)
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            envdir = mkpath(joinpath(dir, "env"))
            write(joinpath(envdir, "Project.toml"), "[deps]\nMPFR_jll = \"$mpfr_jll_uuid\"\n")
            env = load_environment(envdir; depots)

            # v1.5: neither jll is a stdlib yet → both come from the registry,
            # gated by julia compat; MPFR 4.0.2 transitively pulls GMP 6.1.2.
            p15 = plan_resolve(env, regs, Config(depots); julia_version = v"1.5")
            @test entry_version(p15.manifest[mpfr_jll_uuid]) == v"4.0.2"
            @test entry_version(p15.manifest[gmp_jll_uuid]) == v"6.1.2"

            # v1.6: both are versioned stdlibs → the resolver takes the historical
            # stdlib builds and ignores the registry (which offers 4.1.1/6.2.0).
            p16 = plan_resolve(env, regs, Config(depots); julia_version = v"1.6")
            @test entry_version(p16.manifest[gmp_jll_uuid]) == v"6.2.0+5"
            @test entry_tree_hash(p16.manifest[gmp_jll_uuid]) === nothing
            let mv = entry_version(p16.manifest[mpfr_jll_uuid])
                @test mv.major == 4 && mv.minor == 1
            end
        end
        hist_unregister!()
    end

    @testset "resolve: julia_version = nothing coexistence" begin
        hist_register!()
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            make_jll_registry(depot)
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            envdir = mkpath(joinpath(dir, "env"))
            write(joinpath(envdir, "Project.toml"), "[deps]\n")
            env = load_environment(envdir; depots)
            # GMP 6.2.0 needs julia 1.6, MPFR 4.0.2 needs julia 1.5 — impossible
            # under any single julia, but julia_version === nothing drops the
            # julia constraint so both requested versions coexist.
            reqs = [PackageRequest("GMP_jll", gmp_jll_uuid, "6.2.0"), PackageRequest("MPFR_jll", mpfr_jll_uuid, "4.0.2")]
            pn = plan_add(env, regs, Config(depots), reqs; julia_version = nothing)
            @test entry_version(pn.manifest[gmp_jll_uuid]) == v"6.2.0"
            @test entry_version(pn.manifest[mpfr_jll_uuid]) == v"4.0.2"
            # the same request under v1.5 is unsatisfiable (GMP 6.2.0 needs 1.6)
            @test_throws Union{ResolverError, PkgError} plan_add(env, regs, Config(depots), reqs; julia_version = v"1.5")
        end
        hist_unregister!()
    end
finally
    # These tables are process-global; leave them empty so a later test file in
    # the same worker (e.g. depots_stdlibs.jl, which asserts historical lookups
    # throw) is not poisoned.
    hist_unregister!()
end
