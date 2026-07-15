# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using LibGit2
using UUIDs: UUID
using SHA: sha256
using Base: SHA1
using Base.BinaryPlatforms: HostPlatform, Platform, platforms_match
using VibePkg
using VibePkg: API
using VibePkg.Stdlibs
using VibePkg.Errors: PkgError
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries, RegistryInstance
using VibePkg.Environments: load_environment
using VibePkg.Planning: plan_add, plan_resolve, PackageRequest
using VibePkg.EnvFiles: entry_version, entry_tree_hash
using VibePkg.Resolve: ResolverError
using VibePkg.TreeHash: tree_hash
using VibePkg.Versions: VersionSpec
import TOML
import Tar
import p7zip_jll

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

# Hermetic ports of the first three scenarios in Pkg.jl's
# "Elliot and Mosè's mini Pkg test suite".  The upstream tests use General
# and JuliaBinaryWrappers repositories; this fixture uses the same public add
# shapes against a generated local registry and local Git repositories.
const _MINI_HELLO_UUID = UUID("dca1746e-5efc-54fc-8249-22745bc95a49")
const _MINI_LIBCXX_UUID = UUID("3eaa8342-bff7-56a5-9981-c04077f7cee7")
const _MINI_PKG_UUID = UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")

function _mini_make_package_repo(root, name, uuid, versions)
    dir = mkpath(joinpath(root, "$name.jl"))
    repo = LibGit2.init(dir)
    signature = LibGit2.Signature("historical fixture", "fixture@localhost")
    hashes = Dict{VersionNumber, String}()
    commits = Dict{VersionNumber, String}()
    try
        for version in versions
            mkpath(joinpath(dir, "src"))
            write(
                joinpath(dir, "Project.toml"),
                "name = $(repr(name))\nuuid = $(repr(string(uuid)))\nversion = $(repr(string(version)))\n",
            )
            write(
                joinpath(dir, "src", "$name.jl"),
                "module $name\nconst FIXTURE_VERSION = $(repr(version))\nend\n",
            )
            LibGit2.add!(repo, "Project.toml", joinpath("src", "$name.jl"))
            commit = LibGit2.commit(
                repo, "$name $version"; author = signature, committer = signature,
            )
            hashes[version] = LibGit2.with(LibGit2.GitCommit(repo, commit)) do commit_obj
                LibGit2.with(LibGit2.peel(LibGit2.GitTree, commit_obj)) do tree
                    string(LibGit2.GitHash(tree))
                end
            end
            commits[version] = string(commit)
        end
    finally
        close(repo)
    end
    return (; dir, hashes, commits)
end

function _mini_write_registry_package(reg, name, uuid, repo, versions; compat = nothing)
    pkg = mkpath(joinpath(reg, string(first(name)), name))
    open(joinpath(pkg, "Package.toml"), "w") do io
        TOML.print(
            io,
            Dict("name" => name, "uuid" => string(uuid), "repo" => repo.dir),
        )
    end
    open(joinpath(pkg, "Versions.toml"), "w") do io
        TOML.print(
            io,
            Dict(string(version) => Dict("git-tree-sha1" => repo.hashes[version]) for version in versions),
        )
    end
    if compat !== nothing
        open(joinpath(pkg, "Compat.toml"), "w") do io
            TOML.print(io, compat)
        end
    end
    return pkg
end

function _mini_make_registry(root, depot)
    hello_versions = [v"1.0.9+0", v"1.0.10+1"]
    libcxx_versions = [v"0.8.8+1", v"0.9.4+0", v"0.14.0+0"]
    hello = _mini_make_package_repo(root, "HelloWorldC_jll", _MINI_HELLO_UUID, hello_versions)
    libcxx = _mini_make_package_repo(root, "libcxxwrap_julia_jll", _MINI_LIBCXX_UUID, libcxx_versions)

    reg = mkpath(joinpath(depot, "registries", "HistoricalMiniRegistry"))
    write(
        joinpath(reg, "Registry.toml"),
        """
        name = "HistoricalMiniRegistry"
        uuid = "77d95d72-ab4f-4b27-a867-6f57c012b648"
        repo = "https://invalid.local/HistoricalMiniRegistry.git"

        [packages]
        $_MINI_HELLO_UUID = { name = "HelloWorldC_jll", path = "H/HelloWorldC_jll" }
        $_MINI_LIBCXX_UUID = { name = "libcxxwrap_julia_jll", path = "l/libcxxwrap_julia_jll" }
        """,
    )
    _mini_write_registry_package(
        reg, "HelloWorldC_jll", _MINI_HELLO_UUID, hello, hello_versions,
    )
    _mini_write_registry_package(
        reg, "libcxxwrap_julia_jll", _MINI_LIBCXX_UUID, libcxx, libcxx_versions;
        compat = Dict(
            "0.8.8" => Dict("julia" => "1.9"),
            "0.9.4" => Dict("julia" => "1.7"),
            "0.14.0" => Dict("julia" => "1.7"),
        ),
    )
    return (; hello, libcxx)
end

function _mini_fresh_env(f, root)
    old_active = Base.ACTIVE_PROJECT[]
    return mktempdir(root) do env
        try
            Base.ACTIVE_PROJECT[] = joinpath(env, "Project.toml")
            f()
        finally
            Base.ACTIVE_PROJECT[] = old_active
        end
    end
end

@testset "Elliot and Mosè's mini Pkg test suite: standard and historical add" begin
    old_depots = copy(Base.DEPOT_PATH)
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    hist_register!()
    try
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            fixture = _mini_make_registry(root, depot)
            copy!(Base.DEPOT_PATH, [depot])

            withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_OFFLINE" => "false") do
                @testset "Standard add" begin
                    _mini_fresh_env(root) do
                        VibePkg.add(; name = "HelloWorldC_jll", io = devnull)
                        @test haskey(VibePkg.dependencies(), _MINI_HELLO_UUID)
                    end

                    _mini_fresh_env(root) do
                        revision = fixture.hello.commits[v"1.0.10+1"]
                        VibePkg.add(
                            ; name = "HelloWorldC_jll", url = fixture.hello.dir,
                            rev = revision, io = devnull,
                        )
                        @test VibePkg.dependencies()[_MINI_HELLO_UUID].git_revision == revision
                    end

                    _mini_fresh_env(root) do
                        VibePkg.add(; name = "HelloWorldC_jll", version = v"1.0.10+1", io = devnull)
                        @test VibePkg.dependencies()[_MINI_HELLO_UUID].version === v"1.0.10+1"
                    end

                    _mini_fresh_env(root) do
                        VibePkg.add(
                            ; name = "HelloWorldC_jll", version = VersionSpec("1.0.10"),
                            io = devnull,
                        )
                        @test VibePkg.dependencies()[_MINI_HELLO_UUID].version === v"1.0.10+1"
                    end
                end

                @testset "Julia-version-dependent add" begin
                    _mini_fresh_env(root) do
                        VibePkg.add(
                            ; name = "libcxxwrap_julia_jll", julia_version = v"1.7",
                            io = devnull,
                        )
                        @test VibePkg.dependencies()[_MINI_LIBCXX_UUID].version === v"0.14.0+0"
                    end

                    _mini_fresh_env(root) do
                        VibePkg.add(
                            ; name = "libcxxwrap_julia_jll", version = v"0.9.4+0",
                            julia_version = v"1.7", io = devnull,
                        )
                        @test VibePkg.dependencies()[_MINI_LIBCXX_UUID].version === v"0.9.4+0"
                    end

                    _mini_fresh_env(root) do
                        VibePkg.add(
                            ; name = "libcxxwrap_julia_jll", version = v"0.8.8+1",
                            julia_version = v"1.9", io = devnull,
                        )
                        @test VibePkg.dependencies()[_MINI_LIBCXX_UUID].version === v"0.8.8+1"
                    end
                end

                @testset "Old Pkg add regression" begin
                    _mini_fresh_env(root) do
                        @test VibePkg.add(; name = "Pkg", julia_version = v"1.11", io = devnull) === nothing
                        @test haskey(VibePkg.dependencies(), _MINI_PKG_UUID)
                    end
                end
            end
        end
    finally
        copy!(Base.DEPOT_PATH, old_depots)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        hist_unregister!()
    end
end

# Hermetic fixtures for the nested historical-stdlib add scenarios in Pkg.jl's
# "Elliot and Mosè's mini Pkg test suite". General and wrapper downloads are
# replaced by a generated registry whose source trees are preinstalled in a
# temporary depot.
const HN_GMP_UUID = UUID("781609d7-10c4-51f6-84f2-b8444358ff6d")
const HN_OPENBLAS_UUID = UUID("4536629a-c528-5b80-bd46-f80d51c5b363")
const HN_LBT_UUID = UUID("8e850b90-86db-534c-a0d3-1478176c7d93")

# Write registry metadata and an already-installed source tree for every
# offered version.  Public `add` therefore exercises resolution, execution,
# manifest writing, and introspection without a network request.
function hn_add_registry_package!(
        reg::String, depot::String, fixture_root::String,
        name::String, uuid::UUID, versions::Vector{VersionNumber};
        julia_compat::Dict{VersionNumber, String} = Dict{VersionNumber, String}(),
        artifact = nothing,
    )
    hashes = Dict{VersionNumber, SHA1}()
    for version in versions
        source = mkpath(joinpath(fixture_root, "$name-$version"))
        mkpath(joinpath(source, "src"))
        write(
            joinpath(source, "Project.toml"),
            "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"$version\"\n",
        )
        write(joinpath(source, "src", "$name.jl"), "module $name\nend\n")
        if artifact !== nothing
            write(
                joinpath(source, "Artifacts.toml"),
                """
                [historical_gmp]
                git-tree-sha1 = "$(artifact.hash)"

                    [[historical_gmp.download]]
                    url = "$(artifact.url)"
                    sha256 = "$(artifact.sha)"
                """,
            )
        end
        hash = SHA1(tree_hash(source))
        hashes[version] = hash
        installed = joinpath(depot, "packages", name, Base.version_slug(uuid, hash))
        mkpath(dirname(installed))
        cp(source, installed)
    end

    pkg = mkpath(joinpath(reg, string(first(name)), name))
    write(
        joinpath(pkg, "Package.toml"),
        "name = \"$name\"\nuuid = \"$uuid\"\nrepo = \"https://network.invalid/$name.jl.git\"\n",
    )
    open(joinpath(pkg, "Versions.toml"), "w") do io
        TOML.print(
            io,
            Dict(string(version) => Dict("git-tree-sha1" => string(hashes[version])) for version in versions),
        )
    end
    if !isempty(julia_compat)
        open(joinpath(pkg, "Compat.toml"), "w") do io
            TOML.print(
                io,
                Dict(
                    "$(version.major).$(version.minor).$(version.patch)" =>
                        Dict("julia" => compat)
                        for (version, compat) in julia_compat
                ),
            )
        end
    end
    return hashes
end

function hn_make_gmp_artifact(fixture_root::String)
    payload = mkpath(joinpath(fixture_root, "gmp-artifact-payload"))
    write(joinpath(payload, "libgmp-fixture.txt"), "historical GMP artifact\n")
    hash = SHA1(tree_hash(payload))
    archive = LocalPkgServer.gzip_tarball(
        payload, joinpath(fixture_root, "gmp-artifact.tar.gz"),
    )
    path = replace(abspath(archive), '\\' => '/')
    startswith(path, '/') || (path = "/$path")
    return (; hash, url = "file://$path", sha = bytes2hex(open(sha256, archive)))
end

function hn_make_registry(depot::String, fixture_root::String)
    reg = mkpath(joinpath(depot, "registries", "HistoricalNested"))
    write(
        joinpath(reg, "Registry.toml"),
        """
        name = "HistoricalNested"
        uuid = "b3338594-aafe-5451-b93e-139f81909106"

        [packages]
        $HN_GMP_UUID = { name = "GMP_jll", path = "G/GMP_jll" }
        $HN_OPENBLAS_UUID = { name = "OpenBLAS_jll", path = "O/OpenBLAS_jll" }
        $HN_LBT_UUID = { name = "libblastrampoline_jll", path = "l/libblastrampoline_jll" }
        """,
    )
    artifact = hn_make_gmp_artifact(fixture_root)
    hn_add_registry_package!(
        reg, depot, fixture_root, "GMP_jll", HN_GMP_UUID,
        [v"6.1.2+0", v"6.2.0+5", v"6.2.1+1"];
        julia_compat = Dict(
            v"6.1.2+0" => "1.5", v"6.2.0+5" => "1.6", v"6.2.1+1" => "1.7",
        ),
        artifact,
    )
    hn_add_registry_package!(
        reg, depot, fixture_root, "OpenBLAS_jll", HN_OPENBLAS_UUID,
        [v"0.3.13"];
        julia_compat = Dict(v"0.3.13" => "1.6"),
    )
    hn_add_registry_package!(
        reg, depot, fixture_root, "libblastrampoline_jll", HN_LBT_UUID,
        [v"5.1.1"];
        julia_compat = Dict(v"5.1.1" => "1.8"),
    )
    return (; reg, artifact)
end

function hn_fresh_env(f::Function, root::String)
    old_active = Base.ACTIVE_PROJECT[]
    return mktempdir(root) do envdir
        try
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            f(envdir)
        finally
            Base.ACTIVE_PROJECT[] = old_active
        end
    end
end

@testset "Elliot and Mosè's mini Pkg test suite: nested historical stdlib add" begin
    old_depots = copy(Base.DEPOT_PATH)
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
    hist_register!()
    try
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            fixture = hn_make_registry(depot, mkpath(joinpath(root, "fixtures")))
            copy!(Base.DEPOT_PATH, [depot])
            # The generated unpacked registry is immutable and has no remote.
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false

            withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_OFFLINE" => "false") do
                @testset "Stdlib add" begin
                    # Before GMP_jll became a stdlib, a historical public add
                    # resolves the registry build and installs its artifact.
                    hn_fresh_env(root) do _
                        VibePkg.add("GMP_jll"; julia_version = v"1.5", io = devnull)
                        info = VibePkg.dependencies()[HN_GMP_UUID]
                        @test info.version === v"6.1.2+0"
                        @test info.tree_hash !== nothing
                        artifact_path = joinpath(depot, "artifacts", string(fixture.artifact.hash))
                        @test read(joinpath(artifact_path, "libgmp-fixture.txt"), String) ==
                            "historical GMP artifact\n"
                    end

                    # Default resolution uses the running Julia's versioned
                    # GMP stdlib, not either decoy registry version.
                    hn_fresh_env(root) do _
                        VibePkg.add("GMP_jll"; io = devnull)
                        @test VibePkg.dependencies()[HN_GMP_UUID].version ==
                            S.stdlib_version(HN_GMP_UUID, VERSION)
                        @test VibePkg.dependencies()[HN_GMP_UUID].tree_hash === nothing
                    end

                    # Historical resolution fixes the version to Julia 1.7's
                    # stdlib build and likewise keeps it registry-hash-free.
                    hn_fresh_env(root) do _
                        VibePkg.add("GMP_jll"; julia_version = v"1.7", io = devnull)
                        info = VibePkg.dependencies()[HN_GMP_UUID]
                        @test info.version === v"6.2.1+1"
                        @test info.tree_hash === nothing
                    end

                    # Julia 1.7 fixes GMP at 6.2.1+1, so an exact request for
                    # the Julia-1.6 build is unsatisfiable.
                    hn_fresh_env(root) do _
                        @test_throws ResolverError VibePkg.add(
                            VibePkg.PackageSpec("GMP_jll", v"6.2.0+5");
                            julia_version = v"1.7", io = devnull,
                        )
                    end

                    # With no Julia constraint, registered stdlibs become
                    # ordinary registry packages.  The exact build is both
                    # resolved and materialized from the local fixture.
                    hn_fresh_env(root) do _
                        VibePkg.add(
                            VibePkg.PackageSpec("GMP_jll", v"6.2.1+1");
                            julia_version = nothing, io = devnull,
                        )
                        info = VibePkg.dependencies()[HN_GMP_UUID]
                        @test info.version === v"6.2.1+1"
                        @test info.tree_hash !== nothing
                        @test info.source !== nothing && isfile(joinpath(info.source, "Project.toml"))
                    end
                end

                @testset "julia_version = nothing" begin
                    @testset "stdlib add (nested)" begin
                        hn_fresh_env(root) do _
                            VibePkg.add(
                                [
                                    VibePkg.PackageSpec("OpenBLAS_jll", v"0.3.13"),
                                    VibePkg.PackageSpec("libblastrampoline_jll", v"5.1.1"),
                                ];
                                julia_version = nothing, io = devnull,
                            )
                            deps = VibePkg.dependencies()
                            @test v"0.3.14" > deps[HN_OPENBLAS_UUID].version >= v"0.3.13"
                            @test v"5.1.2" > deps[HN_LBT_UUID].version >= v"5.1.1"
                            @test deps[HN_OPENBLAS_UUID].tree_hash !== nothing
                            @test deps[HN_LBT_UUID].tree_hash !== nothing
                        end
                    end
                end
            end
        end
    finally
        copy!(Base.DEPOT_PATH, old_depots)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        hist_unregister!()
    end
end

# The upstream sibling "with context (using private Pkg.add method)" invokes a
# non-public overload solely to reach the same observable result asserted by
# "with julia_version".  VibePkg deliberately has no Context-shaped public API;
# its public julia_version/platform behavior is covered below for both original
# version argument forms.

# Hermetic parity coverage for the platform-specific tail of Pkg.jl's
# historical stdlib tests.

const HA_CMAKE_UUID = UUID("3f4f2f9c-44e0-5f58-9a0d-79a8e0f3f5ab")
const HA_GMP_UUID = UUID("781609d7-10c4-51f6-84f2-b8444358ff6d")
const HA_ARTIFACTS_UUID = UUID("56f22d72-fd6d-98f1-02f0-08ddc0907c33")

ha_toml_path(path::AbstractString) = replace(path, '\\' => '/')
function ha_file_url(path::AbstractString)
    path = ha_toml_path(path)
    startswith(path, '/') || (path = "/$path")
    return "file://$path"
end

function ha_gz_artifact(dir::String, label::String)
    content = mkpath(joinpath(dir, label))
    write(joinpath(content, "payload.txt"), "$label payload\n")
    hash = SHA1(tree_hash(content))
    tarball = joinpath(dir, "$label.tar")
    Tar.create(content, tarball)
    gz = joinpath(dir, "$label.tar.gz")
    run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $gz $tarball`; stdout = devnull))
    return (; hash, gz, sha = bytes2hex(open(sha256, gz)))
end

"""Create an unpacked registry plus already-installed CMake_jll sources."""
function ha_make_cmake_registry(depot::String, fixture_dir::String)
    target = Platform("x86_64", "linux"; libc = "musl")
    wanted = ha_gz_artifact(fixture_dir, "musl-target")
    bait = ha_gz_artifact(fixture_dir, "host-bait")

    source_template = mkpath(joinpath(fixture_dir, "CMake_jll-template"))
    mkpath(joinpath(source_template, "src"))
    write(joinpath(source_template, "src", "CMake_jll.jl"), "module CMake_jll end\n")
    artifacts_toml = joinpath(source_template, "Artifacts.toml")
    VibePkg.Artifacts.bind_artifact!(
        artifacts_toml, "cmake_payload", wanted.hash;
        platform = target, download_info = [(ha_file_url(wanted.gz), wanted.sha)],
    )
    host = HostPlatform()
    if !platforms_match(host, target)
        VibePkg.Artifacts.bind_artifact!(
            artifacts_toml, "cmake_payload", bait.hash;
            platform = host, download_info = [(ha_file_url(bait.gz), bait.sha)],
        )
    end

    hashes = Dict{VersionNumber, SHA1}()
    for version in (v"3.24.3+0", v"3.24.3+1")
        source = joinpath(fixture_dir, "CMake_jll-$version")
        cp(source_template, source)
        write(
            joinpath(source, "Project.toml"),
            "name = \"CMake_jll\"\nuuid = \"$HA_CMAKE_UUID\"\nversion = \"$version\"\n",
        )
        hash = SHA1(tree_hash(source))
        hashes[version] = hash
        installed = joinpath(depot, "packages", "CMake_jll", Base.version_slug(HA_CMAKE_UUID, hash))
        mkpath(dirname(installed))
        cp(source, installed)
    end

    pkg = mkpath(joinpath(depot, "registries", "HistoricalMini", "C", "CMake_jll"))
    write(
        joinpath(depot, "registries", "HistoricalMini", "Registry.toml"),
        """
        name = "HistoricalMini"
        uuid = "93338594-aafe-5451-b93e-139f81909106"

        [packages]
        $HA_CMAKE_UUID = { name = "CMake_jll", path = "C/CMake_jll" }
        """,
    )
    write(
        joinpath(pkg, "Package.toml"),
        "name = \"CMake_jll\"\nuuid = \"$HA_CMAKE_UUID\"\nrepo = \"https://network.invalid/CMake_jll.git\"\n",
    )
    write(
        joinpath(pkg, "Versions.toml"),
        """
        ["3.24.3+0"]
        git-tree-sha1 = "$(hashes[v"3.24.3+0"])"

        ["3.24.3+1"]
        git-tree-sha1 = "$(hashes[v"3.24.3+1"])"
        """,
    )
    # Deliberately incompatible with the running Julia (1.12+ in CI): the
    # public call succeeds only if `julia_version = nothing` really reaches
    # the resolver and disables Julia compatibility filtering.
    write(
        joinpath(pkg, "Compat.toml"),
        """
        ["3.24.3"]
        julia = "1.6-1.8"
        """,
    )
    return (; target, wanted, bait)
end

function ha_with_cmake_world(f::Function)
    return mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        fixture = ha_make_cmake_registry(depot, mkpath(joinpath(dir, "fixture")))
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = API.AUTO_PRECOMPILE_ENABLED[]
        API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            withenv("JULIA_PKG_SERVER" => "") do
                f(depot, envdir, fixture)
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

"""Registry decoy for the external Artifacts v1.3.0 package."""
function ha_make_artifacts_registry(depot::String)
    pkg = mkpath(joinpath(depot, "registries", "ArtifactsDecoy", "A", "Artifacts"))
    write(
        joinpath(depot, "registries", "ArtifactsDecoy", "Registry.toml"),
        """
        name = "ArtifactsDecoy"
        uuid = "a3338594-aafe-5451-b93e-139f81909106"

        [packages]
        $HA_ARTIFACTS_UUID = { name = "Artifacts", path = "A/Artifacts" }
        """,
    )
    write(
        joinpath(pkg, "Package.toml"),
        "name = \"Artifacts\"\nuuid = \"$HA_ARTIFACTS_UUID\"\nrepo = \"https://network.invalid/Artifacts.jl.git\"\n",
    )
    write(
        joinpath(pkg, "Versions.toml"),
        """
        ["1.3.0"]
        git-tree-sha1 = "1300000000000000000000000000000000000000"
        """,
    )
    return nothing
end

try
    hist_register!()

    # Pkg.jl historical_stdlib_version.jl "non-stdlib JLL add": the private
    # Context overload is an internal Pkg API and intentionally omitted.  The
    # public add is exercised for the original exact VersionNumber and compat
    # string forms, including the requested non-host platform's artifact.
    @testset "non-stdlib JLL add (public, hermetic)" begin
        for (request, expected) in ((v"3.24.3+0", v"3.24.3+0"), ("3.24.3", v"3.24.3+1"))
            @testset "version = $(repr(request))" begin
                ha_with_cmake_world() do depot, envdir, fixture
                    VibePkg.add(
                        [VibePkg.PackageSpec(; name = "CMake_jll", version = request)];
                        platform = fixture.target, julia_version = nothing, io = devnull,
                    )
                    deps = VibePkg.dependencies()
                    @test deps[HA_CMAKE_UUID].version == expected
                    resolved = load_environment(envdir; depots = depot_stack([depot]))
                    @test resolved.manifest.julia_version === nothing
                    wanted_path = joinpath(depot, "artifacts", string(fixture.wanted.hash))
                    @test read(joinpath(wanted_path, "payload.txt"), String) == "musl-target payload\n"
                    if !platforms_match(HostPlatform(), fixture.target)
                        @test !isdir(joinpath(depot, "artifacts", string(fixture.bait.hash)))
                    end
                end
            end
        end
    end

    # Pkg.jl historical_stdlib_version.jl "Artifacts stdlib never falls back
    # to registry": General is replaced by a tiny registry which deliberately
    # offers the same Artifacts UUID at v1.3.0.  GMP_jll's Julia-1.10 stdlib
    # metadata depends on Artifacts; the resulting manifest must keep that dep
    # unversioned and hash-less rather than selecting the registered decoy.
    @testset "Artifacts stdlib never falls back to registry (hermetic)" begin
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            ha_make_artifacts_registry(depot)
            depots = depot_stack([depot])
            regs = reachable_registries(depots)
            @test length(regs) == 1

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            planned = plan_add(
                env, regs, Config(depots),
                [PackageRequest("GMP_jll", HA_GMP_UUID, nothing)];
                julia_version = v"1.10",
            )

            @test is_stdlib(HA_ARTIFACTS_UUID, v"1.10")
            @test stdlib_version(HA_ARTIFACTS_UUID, v"1.10") === nothing
            @test planned.manifest[HA_GMP_UUID].deps["Artifacts"] == HA_ARTIFACTS_UUID
            artifacts = planned.manifest[HA_ARTIFACTS_UUID]
            @test entry_version(artifacts) === nothing
            @test entry_tree_hash(artifacts) === nothing
        end
    end
finally
    # Historical tables are process-global; never leak them into another test.
    hist_unregister!()
end
