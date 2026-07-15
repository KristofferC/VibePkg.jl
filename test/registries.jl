# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack
using VibePkg.Registries
using VibePkg.Versions: VersionSpec, semver_spec
using VibePkg.Environments: load_environment
using VibePkg.Planning: plan_add, PackageRequest
using VibePkg.EnvFiles: entry_version, entry_tree_hash

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

# a single-package registry variant for the multi-registry tests below:
# `name` and `uuid` distinguish instances, `test_compat` is Example@0.5.0's
# compat on Test (the make_test_registry pattern, reduced)
function make_variant_registry(depot; name, uuid, versions, test_compat = nothing)
    reg = joinpath(depot, "registries", name)
    pkg = joinpath(reg, "E", "Example")
    mkpath(pkg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "$name"
        uuid = "$uuid"

        [packages]
        $EXAMPLE_UUID = { name = "Example", path = "E/Example" }
        """
    )
    write(
        joinpath(pkg, "Package.toml"), """
        name = "Example"
        uuid = "$EXAMPLE_UUID"
        repo = "https://example.com/Example.jl.git"
        """
    )
    write(
        joinpath(pkg, "Versions.toml"),
        join(("[\"$v\"]\ngit-tree-sha1 = \"$h\"\n" for (v, h) in versions), "\n")
    )
    if test_compat !== nothing
        write(
            joinpath(pkg, "Deps.toml"), """
            ["0.5"]
            Test = "$TEST_UUID"
            """
        )
        write(
            joinpath(pkg, "Compat.toml"), """
            ["0.5"]
            Test = "$test_compat"
            """
        )
    end
    return reg
end


@testset "Registries" begin
    mktempdir() do depot
        make_test_registry(depot)
        regs = reachable_registries(depot_stack([depot]))
        @test length(regs) == 1
        r = only(regs)
        @test registry_name(r) == "TestRegistry"
        @test registry_uuid(r) == UUID("23338594-aafe-5451-b93e-139f81909106")
        @test uuids_from_name(r, "Example") == [EXAMPLE_UUID]
        @test isempty(uuids_from_name(r, "Nonexistent"))

        info = registry_info(r, r[EXAMPLE_UUID])
        @test length(info.version_info) == 3
        @test !isyanked(info, v"0.5.1")
        @test isyanked(info, v"1.0.0")
        @test treehash(info, v"0.5.0") == SHA1("1111111111111111111111111111111111111111")
        @test info.repo == "https://example.com/Example.jl.git"
        @test !isdeprecated(info)

        # compat query merges deps + compat overlays for a version
        compat = query_compat_for_version(info, v"0.5.1")
        @test compat[TEST_UUID] == VersionSpec("1")
        @test compat[JULIA_UUID] == VersionSpec("1.6.0-1")  # implicit julia dep, constrained here
        @test !haskey(compat, SHA_UUID)                     # weak dep only exists at 1.x

        compat = query_compat_for_version(info, v"0.5.0")
        @test compat[JULIA_UUID] == VersionSpec()           # unconstrained at 0.5.0

        compat = query_compat_for_version(info, v"1.0.0")
        @test compat[SHA_UUID] == VersionSpec("0.7-1")      # weak dep with weak compat
        @test !haskey(compat, TEST_UUID) == false           # Test still a dep at 1.0
        @test is_weak_dep(info.weak_deps, v"1.0.0", SHA_UUID)
        @test !is_weak_dep(info.weak_deps, v"0.5.1", SHA_UUID)

        # targeted query
        @test query_compat_for_version(info, v"0.5.1", TEST_UUID) == VersionSpec("1")
        @test query_compat_for_version(info, v"0.5.1", SHA_UUID) === nothing

        # all deps (strong + weak) for a version
        @test query_deps_for_version(info.deps, info.weak_deps, v"1.0.0") ==
            Set([TEST_UUID, SHA_UUID, JULIA_UUID])
    end
end

@testset "git-backed registries" begin
    import LibGit2
    mktempdir() do dir
        # a registry living in a git repository
        src_depot = mkpath(joinpath(dir, "src"))
        reg_src = make_test_registry(src_depot)
        repo = LibGit2.init(reg_src)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("tester", "tester@example.com")
        LibGit2.commit(repo, "initial"; author = sig, committer = sig)
        LibGit2.close(repo)

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        name = VibePkg.Registries.add_registry_from_source!(depots, reg_src; io = devnull)
        @test name == "TestRegistry"
        regs = reachable_registries(depots)
        r = only(regs)
        @test registry_name(r) == "TestRegistry"
        info = registry_info(r, r[EXAMPLE_UUID])
        @test haskey(info.version_info, v"0.5.1")
        @test !haskey(info.version_info, v"0.6.0")

        # adding again is a no-op; a same-name different-uuid registry conflicts
        @test VibePkg.Registries.add_registry_from_source!(depots, reg_src; io = devnull) == "TestRegistry"

        # publish a new version upstream, then fast-forward update
        versions_file = joinpath(reg_src, "E", "Example", "Versions.toml")
        write(
            versions_file, read(versions_file, String) * """

                ["0.6.0"]
                git-tree-sha1 = "4444444444444444444444444444444444444444"
                """
        )
        repo = LibGit2.GitRepo(reg_src)
        LibGit2.add!(repo, ".")
        LibGit2.commit(repo, "add 0.6.0"; author = sig, committer = sig)
        LibGit2.close(repo)

        probe_hits = Ref(0)
        probe = () -> (probe_hits[] += 1; nothing)
        push!(VibePkg.Registries.REGISTRY_CHANGE_HOOKS, probe)
        try
            updated = VibePkg.Registries.update_registries!(depots; server = nothing, io = devnull)
            @test updated == ["TestRegistry"]
            @test probe_hits[] == 1    # a real update fires the change hooks
            # fresh instance sees the new version (git dirs are not content-cached)
            r = only(reachable_registries(depots))
            info = registry_info(r, r[EXAMPLE_UUID])
            @test haskey(info.version_info, v"0.6.0")
            # nothing further to do
            @test isempty(VibePkg.Registries.update_registries!(depots; server = nothing, io = devnull))
            @test probe_hits[] == 1    # a no-op update does not
        finally
            filter!(h -> h !== probe, VibePkg.Registries.REGISTRY_CHANGE_HOOKS)
        end
    end
end

# registry mutations (add / remove) invalidate the completion-name caches
# automatically, and callers get a copy they cannot poison the cache through
@testset "registry mutations invalidate completion caches" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        old_depots = copy(Base.DEPOT_PATH)
        try
            append!(empty!(Base.DEPOT_PATH), [depot])
            VibePkg.REPLMode.reset_completion_cache!()
            @test isempty(VibePkg.REPLMode.registered_package_names())
            # registry add is visible without a manual cache reset
            src = make_test_registry(mkpath(joinpath(dir, "src")))
            VibePkg.Registry.add(src; io = devnull)
            @test "Example" in VibePkg.REPLMode.registered_package_names()
            @test !VibePkg.REPLMode.is_deprecated_package_name("Example")
            # the returned vector is a copy: mutating it cannot poison the cache
            names = VibePkg.REPLMode.registered_package_names()
            push!(names, "Bogus")
            @test !("Bogus" in VibePkg.REPLMode.registered_package_names())
            # registry rm is visible too
            VibePkg.Registry.rm("TestRegistry"; io = devnull)
            @test isempty(VibePkg.REPLMode.registered_package_names())
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.REPLMode.reset_completion_cache!()
        end
    end
end

# Pkg.jl#4159 — an exact version that is only registered with a build number
# (jll style): the add must resolve to the +N version at plan time, not fail
# later with a missing-source error
@testset "exact version registered only with a build number" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_variant_registry(
            depot; name = "BuildRegistry", uuid = "53338594-aafe-5451-b93e-139f81909106",
            versions = ["0.5.6+0" => "5555555555555555555555555555555555555555"],
        )
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do envdir
            env = load_environment(envdir; depots)
            # the issue's spelling: an exact VersionNumber without the build
            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, v"0.5.6")])
            entry = planned.manifest[EXAMPLE_UUID]
            @test entry_version(entry) == v"0.5.6+0"
            @test entry_tree_hash(entry) == SHA1("5555555555555555555555555555555555555555")
            # string form takes the same path
            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.6")])
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.6+0"
        end
    end
end

# Pkg.jl#1434 — the same version in multiple registries: compat comes from
# the first consulted registry (per dependency), not a mix; this is the
# query the planner's deps graph runs per version
@testset "same version in multiple registries: first registry's compat wins" begin
    mktempdir() do dir
        depot_a = mkpath(joinpath(dir, "A"))
        depot_b = mkpath(joinpath(dir, "B"))
        make_variant_registry(
            depot_a; name = "RegA", uuid = "63338594-aafe-5451-b93e-139f81909106",
            versions = ["0.5.0" => "1111111111111111111111111111111111111111"],
            test_compat = "1",
        )
        make_variant_registry(
            depot_b; name = "RegB", uuid = "73338594-aafe-5451-b93e-139f81909106",
            versions = ["0.5.0" => "1111111111111111111111111111111111111111"],
            test_compat = "0.7",
        )
        query(regs) = begin
            infos = [registry_info(r, r[EXAMPLE_UUID]) for r in regs]
            result = Dict{UUID, VersionSpec}()
            Registries.query_compat_for_version_multi_registry!(
                result, Dict{UUID, VersionSpec}(),
                [i.deps for i in infos], [i.compat for i in infos],
                [i.weak_deps for i in infos], [i.weak_compat for i in infos],
                [Set(keys(i.version_info)) for i in infos], v"0.5.0",
            )
            result
        end
        regs = reachable_registries(depot_stack([depot_a, depot_b]))
        @test registry_name.(regs) == ["RegA", "RegB"]
        @test query(regs)[TEST_UUID] == VersionSpec("1")
        # reversed consultation order flips the winner
        @test query(reverse(regs))[TEST_UUID] == VersionSpec("0.7")
    end
end

# Pkg.jl#711 — the identical registry reachable through two depots of the
# stack: both instances are discovered, but a name lookup dedups by uuid so
# `add` does not report "multiple registered Example packages"
@testset "identical registry in two depots" begin
    mktempdir() do dir
        depot_a = mkpath(joinpath(dir, "A"))
        depot_b = mkpath(joinpath(dir, "B"))
        make_test_registry(depot_a)
        cp(joinpath(depot_a, "registries"), joinpath(depot_b, "registries"))
        depots = depot_stack([depot_a, depot_b])
        regs = reachable_registries(depots)
        @test length(regs) == 2
        @test all(r -> registry_uuid(r) == UUID("23338594-aafe-5451-b93e-139f81909106"), regs)
        mktempdir() do envdir
            env = load_environment(envdir; depots)
            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            entry = planned.manifest[EXAMPLE_UUID]
            @test entry_version(entry) == v"0.5.1"
            @test "TestRegistry" in entry.tracking.registries
        end
    end
end
