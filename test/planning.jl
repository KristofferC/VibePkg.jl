# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries
using VibePkg.Environments
using VibePkg.Environments: Environment
using VibePkg.Planning
using VibePkg.Planning: PackageRequest
using VibePkg.Registries: RegistryInstance
using VibePkg.Stdlibs: stdlib_infos, stdlib_version
using VibePkg.EnvFiles: entry_version, entry_tree_hash, entry_path, is_registry_tracked
using VibePkg.Errors: PkgError

# reuses the synthetic registry fixture from registries.jl (already included)

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

@testset "Planning" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            env = load_environment(dir; depots)
            @test isempty(env.manifest)

            # plan add Example: yanked 1.0.0 is skipped, julia-compat holds
            env2_plan = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            entry = env2_plan.manifest[EXAMPLE_UUID]
            @test entry.name == "Example"
            @test is_registry_tracked(entry)
            @test entry_version(entry) == v"0.5.1"
            @test entry_tree_hash(entry) == Base.SHA1("2222222222222222222222222222222222222222")
            @test entry.tracking.registries == ["TestRegistry"]
            @test haskey(entry.deps, "Test")               # stdlib dep recorded
            @test env2_plan.project.deps["Example"] == EXAMPLE_UUID
            # the manifest records VERSION without nightly build detail
            # (`1.14.0-DEV`, not `1.14.0-DEV.2638`) — Pkg's `dropbuild`
            @test env2_plan.manifest.julia_version == Planning.dropbuild(VERSION)

            # the plan is pure: nothing on disk yet
            @test !isfile(joinpath(dir, "Project.toml"))

            # writing is diff-aware and round-trips
            @test write_environment(env, env2_plan)
            env2 = load_environment(dir; depots)
            @test env2.project == env2_plan.project
            @test env2.manifest == env2_plan.manifest
            @test is_manifest_current(env2) == true
            @test !write_environment(env2, env2)           # no-op writes nothing

            # unknown package
            @test_throws PkgError plan_add(env2, regs, Config(depots), [PackageRequest("NoSuchPackage")])

            # remove and prune
            env3 = plan_rm(env2, [PackageRequest("Example")])
            @test isempty(env3.manifest)
            @test !haskey(env3.project.deps, "Example")
            @test write_environment(env2, env3)
            @test isempty(load_environment(dir; depots).manifest)
        end

        # version-constrained add: 0.5.0 has no julia compat entry
        mktempdir() do dir
            env = load_environment(dir; depots)
            env2 = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            @test entry_version(env2.manifest[EXAMPLE_UUID]) == v"0.5.0"

            # partial version (VersionSpec prefix): `Example@0.5` takes the
            # LATEST registered 0.5.x (0.5.1; 1.0.0 is outside the prefix and
            # yanked anyway)
            env3 = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5")])
            @test entry_version(env3.manifest[EXAMPLE_UUID]) == v"0.5.1"

            # a malformed `@version` micro-syntax specifier (semver operator,
            # garbage, or empty `pkg@`) is a clean PkgError, not a raw
            # ArgumentError/BoundsError out of the VersionSpec parser — both on
            # the add and the pin request path (request_version_spec).
            for bad in ("=0.5.3", "~0.5", "^0.5", "notaversion", "")
                @test_throws PkgError plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, bad)])
            end
        end

        @testset "plan_promote: already-present fast path" begin
            mktempdir() do dir
                env = load_environment(dir; depots)
                # nothing in the manifest yet: every request needs resolution
                @test plan_promote(env, regs, [PackageRequest("Example")]) === nothing

                # resolve Example (its stdlib dep Test lands in the manifest)
                env2 = plan_add(env, regs, Config(depots), [PackageRequest("Example")])

                # re-adding Example (already direct + compatible): promote, no resolve
                res = plan_promote(env2, regs, [PackageRequest("Example")])
                @test res !== nothing
                penv, names = res
                @test names == ["Example"]
                @test penv.project.deps["Example"] == EXAMPLE_UUID
                @test penv.manifest == env2.manifest        # manifest untouched

                # a bare / compatible / exact request all take the fast path
                @test plan_promote(env2, regs, [PackageRequest("Example", nothing, "0.5")]) !== nothing
                @test plan_promote(env2, regs, [PackageRequest("Example", nothing, v"0.5.1")]) !== nothing
                # incompatible version falls back to a resolve
                @test plan_promote(env2, regs, [PackageRequest("Example", nothing, v"0.5.0")]) === nothing
                @test plan_promote(env2, regs, [PackageRequest("Example", nothing, "0.4")]) === nothing

                # an indirect manifest dep (the Test stdlib) is promoted to direct
                @test haskey(env2.manifest, TEST_UUID)
                @test !haskey(env2.project.deps, "Test")
                res2 = plan_promote(env2, regs, [PackageRequest("Test")])
                @test res2 !== nothing
                @test res2[1].project.deps["Test"] == TEST_UUID
                @test res2[1].manifest == env2.manifest
            end
        end

        @testset "[sources] overrides the registry for a direct dep" begin
            # sources > manifest > registry for direct deps
            # of the active project (src/Planning.jl load_direct_deps)
            mktempdir() do dir
                dir = realpath(dir)
                devdir = joinpath(dir, "ExampleDev")
                mkpath(devdir)
                write(
                    joinpath(devdir, "Project.toml"), """
                    name = "Example"
                    uuid = "$EXAMPLE_UUID"
                    version = "0.7.0"
                    """
                )
                projdir = joinpath(dir, "proj")
                mkpath(projdir)
                write(
                    joinpath(projdir, "Project.toml"), """
                    [deps]
                    Example = "$EXAMPLE_UUID"

                    [sources]
                    Example = {path = "../ExampleDev"}
                    """
                )
                env = load_environment(projdir; depots)
                plan = plan_resolve(env, regs, Config(depots))
                entry = plan.manifest[EXAMPLE_UUID]
                @test !is_registry_tracked(entry)
                # version comes from the path's own project file, not 0.5.1
                @test entry_version(entry) == v"0.7.0"
                p = entry_path(entry)
                @test p !== nothing
                @test realpath(normpath(joinpath(dirname(plan.manifest_file), p))) == devdir
            end
        end

        @testset "[sources] collected recursively for path-tracked deps" begin
            # sources apply recursively inside path/url-tracked
            # packages (src/Planning.jl collect_project) — a
            # path-tracked package's own [sources] entry redirects its dep
            # away from the registry
            mktempdir() do dir
                dir = realpath(dir)
                devdir = joinpath(dir, "ExampleDev")
                mkpath(devdir)
                write(
                    joinpath(devdir, "Project.toml"), """
                    name = "Example"
                    uuid = "$EXAMPLE_UUID"
                    version = "0.9.0"
                    """
                )
                wrapper_uuid = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
                wrapdir = joinpath(dir, "Wrapper")
                mkpath(wrapdir)
                write(
                    joinpath(wrapdir, "Project.toml"), """
                    name = "Wrapper"
                    uuid = "$wrapper_uuid"
                    version = "0.1.0"

                    [deps]
                    Example = "$EXAMPLE_UUID"

                    [sources]
                    Example = {path = "../ExampleDev"}
                    """
                )
                projdir = joinpath(dir, "proj")
                mkpath(projdir)
                write(
                    joinpath(projdir, "Project.toml"), """
                    [deps]
                    Wrapper = "$wrapper_uuid"

                    [sources]
                    Wrapper = {path = "../Wrapper"}
                    """
                )
                env = load_environment(projdir; depots)
                plan = plan_resolve(env, regs, Config(depots))
                wentry = plan.manifest[wrapper_uuid]
                @test !is_registry_tracked(wentry)
                @test haskey(wentry.deps, "Example")
                eentry = plan.manifest[EXAMPLE_UUID]
                @test !is_registry_tracked(eentry)         # not registry 0.5.1
                @test entry_version(eentry) == v"0.9.0"
                p = entry_path(eentry)
                @test p !== nothing
                @test realpath(normpath(joinpath(dirname(plan.manifest_file), p))) == devdir
            end
        end
    end

    # planning against a server-bootstrapped packed registry
    if !@isdefined(LocalPkgServer)
        include("local_pkg_server.jl")
    end
    LocalPkgServer.ensure!()
    mktempdir() do depot
        local_depots = depot_stack([depot])
        VibePkg.Registries.add_default_registries!(local_depots; io = devnull)
        local_regs = reachable_registries(local_depots; read_from_tarball = true)
        @test any(r -> VibePkg.Registries.registry_name(r) == "General", local_regs)
        mktempdir() do dir
            env = load_environment(dir; depots = local_depots)
            env2 = plan_add(env, local_regs, Config(local_depots), [PackageRequest("Example")])
            entry = env2.manifest[UUID("7876af07-990d-54b4-ab0e-23690620f79a")]
            @test entry_version(entry) >= v"0.5.5"
            @test entry_tree_hash(entry) !== nothing
        end
    end
end

# Pkg.jl#3902 — the resolver strips build numbers, so a jll held at 1.0.0+1
# in the manifest must not silently move to 1.0.0+2 on a plain resolve
# (jll_fix in resolve_versions)
@testset "jll build numbers preserved on resolve" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        jll_uuid = UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
        pkg = mkpath(joinpath(depot, "registries", "JllRegistry", "D", "Dummy_jll"))
        write(
            joinpath(depot, "registries", "JllRegistry", "Registry.toml"), """
            name = "JllRegistry"
            uuid = "33338594-aafe-5451-b93e-139f81909106"

            [packages]
            $jll_uuid = { name = "Dummy_jll", path = "D/Dummy_jll" }
            """
        )
        write(
            joinpath(pkg, "Package.toml"), """
            name = "Dummy_jll"
            uuid = "$jll_uuid"
            repo = "https://example.com/Dummy_jll.git"
            """
        )
        write(
            joinpath(pkg, "Versions.toml"), """
            ["1.0.0+1"]
            git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

            ["1.0.0+2"]
            git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            """
        )
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            Dummy_jll = "$jll_uuid"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Dummy_jll]]
            git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            uuid = "$jll_uuid"
            version = "1.0.0+1"
            """
        )
        env = load_environment(envdir; depots)
        plan = plan_resolve(env, regs, Config(depots))
        entry = plan.manifest[jll_uuid]
        @test entry_version(entry) == v"1.0.0+1"
        @test entry_tree_hash(entry) == Base.SHA1("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    end
end

# Pkg.jl#2419 (extras' compat survives rm) + Pkg.jl#1407 (`julia` compat
# survives rm): only the removed dep's compat entry goes
@testset "rm keeps compat of extras and julia" begin
    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"), """
            [deps]
            Example = "$EXAMPLE_UUID"

            [extras]
            Test = "$TEST_UUID"

            [compat]
            julia = "1"
            Example = "0.5"
            Test = "1"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        env = load_environment(dir; depots = depot_stack([depot]))
        env2 = plan_rm(env, [PackageRequest("Example")])
        @test !haskey(env2.project.deps, "Example")
        @test !haskey(env2.project.compat, "Example")
        @test haskey(env2.project.compat, "Test")     # Pkg.jl#2419
        @test haskey(env2.project.compat, "julia")    # Pkg.jl#1407
    end
end

# Pkg.jl#3814 — a [weakdeps] entry of the project with a [compat] bound
# constrains the version when something else pulls the package in, and the
# weakdep alone does not put it in the manifest
@testset "project [weakdeps] compat respected" begin
    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        wrapper_uuid = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
        wrapdir = mkpath(joinpath(dir, "Wrapper"))
        write(
            joinpath(wrapdir, "Project.toml"), """
            name = "Wrapper"
            uuid = "$wrapper_uuid"
            version = "0.1.0"

            [deps]
            Example = "$EXAMPLE_UUID"
            """
        )
        projdir = mkpath(joinpath(dir, "proj"))
        write(
            joinpath(projdir, "Project.toml"), """
            [deps]
            Wrapper = "$wrapper_uuid"

            [weakdeps]
            Example = "$EXAMPLE_UUID"

            [compat]
            Example = "=0.5.0"

            [sources]
            Wrapper = {path = "../Wrapper"}
            """
        )
        env = load_environment(projdir; depots)
        plan = plan_resolve(env, regs, Config(depots))
        # without the weakdep compat the resolver would pick 0.5.1
        @test entry_version(plan.manifest[EXAMPLE_UUID]) == v"0.5.0"

        # weakdep alone (no wrapper dep): Example stays out of the manifest
        projdir2 = mkpath(joinpath(dir, "proj2"))
        write(
            joinpath(projdir2, "Project.toml"), """
            [weakdeps]
            Example = "$EXAMPLE_UUID"

            [compat]
            Example = "=0.5.0"
            """
        )
        env2 = load_environment(projdir2; depots)
        plan2 = plan_resolve(env2, regs, Config(depots))
        @test get(plan2.manifest, EXAMPLE_UUID, nothing) === nothing
    end
end

# Pkg.jl#2698 — a stdlib's manifest deps come from the local stdlib
# Project.toml, never from (possibly wrong) registry data
@testset "stdlib deps come from the local stdlib, not the registry" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)   # registers Example (the bogus dep below)
        dates_uuid = UUID("ade2ca70-3891-5945-98fb-dc099432e06a")
        pkg = mkpath(joinpath(depot, "registries", "StdlibRegistry", "D", "Dates"))
        write(
            joinpath(depot, "registries", "StdlibRegistry", "Registry.toml"), """
            name = "StdlibRegistry"
            uuid = "43338594-aafe-5451-b93e-139f81909106"

            [packages]
            $dates_uuid = { name = "Dates", path = "D/Dates" }
            """
        )
        write(
            joinpath(pkg, "Package.toml"), """
            name = "Dates"
            uuid = "$dates_uuid"
            repo = "https://example.com/Dates.jl.git"
            """
        )
        write(
            joinpath(pkg, "Versions.toml"), """
            ["1.99.0"]
            git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"
            """
        )
        write(
            joinpath(pkg, "Deps.toml"), """
            ["1"]
            Example = "$EXAMPLE_UUID"
            """
        )
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do envdir
            env = load_environment(envdir; depots)
            plan = plan_add(env, regs, Config(depots), [PackageRequest("Dates")])
            entry = plan.manifest[dates_uuid]
            expected = Dict(stdlib_infos()[u].name => u for u in stdlib_infos()[dates_uuid].deps)
            @test entry.deps == expected                # the real local deps
            @test !haskey(entry.deps, "Example")        # not the registry's bogus dep
            @test entry_tree_hash(entry) === nothing
            @test entry_version(entry) == stdlib_version(dates_uuid, VERSION)
        end
    end
end

# Pkg.jl#2051 — a manifest written by an older julia where a now-stdlib was
# an ordinary registry package: `up` normalizes it to stdlib tracking
# instead of erroring
@testset "package→stdlib transition on up" begin
    mktempdir() do dir
        dates_uuid = UUID("ade2ca70-3891-5945-98fb-dc099432e06a")
        write(
            joinpath(dir, "Project.toml"), """
            [deps]
            Dates = "$dates_uuid"
            """
        )
        write(
            joinpath(dir, "Manifest.toml"), """
            julia_version = "1.5.0"
            manifest_format = "2.0"

            [[deps.Dates]]
            git-tree-sha1 = "9999999999999999999999999999999999999999"
            uuid = "$dates_uuid"
            version = "0.6.3"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        env = load_environment(dir; depots)
        plan = plan_up(env, RegistryInstance[], Config(depots))
        entry = plan.manifest[dates_uuid]
        @test is_registry_tracked(entry)
        @test entry_tree_hash(entry) === nothing       # old version/tree-hash gone
        @test entry_version(entry) == stdlib_version(dates_uuid, VERSION)
    end
end

# Pkg.jl#4720: the linear-time rewrites (dependents map + worklist BFS in
# rm_manifest!/prune_manifest, seen-set in load_manifest_deps) must agree
# with naive fixpoint/rescanning references on a large synthetic manifest.
# Pure in-memory: no registry, no downloads, no timing assertions.
@testset "linear-scan equivalence at scale (Pkg.jl#4720)" begin
    N = 300
    uu(i) = UUID(UInt128(i))
    mkentry(name, uuid, deps) = VibePkg.EnvFiles.ManifestEntry(
        name, uuid,
        VibePkg.EnvFiles.RegistryTracked(v"1.0.0", nothing, String[]), false,
        deps, Dict{String, UUID}(),
        Dict{String, Union{String, Vector{String}}}(), Dict{String, VibePkg.EnvFiles.AppInfo}(),
        nothing, nothing, Dict{String, Any}(),
    )
    # chain + diamond: Pi -> {P(i+1), P(i+2)}; plus a detached 2-cycle
    CYCA, CYCB = uu(1001), uu(1002)
    entries = Dict{UUID, VibePkg.EnvFiles.ManifestEntry}()
    for i in 1:N
        deps = Dict{String, UUID}()
        i + 1 <= N && (deps["P$(i + 1)"] = uu(i + 1))
        i + 2 <= N && (deps["P$(i + 2)"] = uu(i + 2))
        entries[uu(i)] = mkentry("P$i", uu(i), deps)
    end
    entries[CYCA] = mkentry("CycA", CYCA, Dict("CycB" => CYCB))
    entries[CYCB] = mkentry("CycB", CYCB, Dict("CycA" => CYCA))
    manifest = VibePkg.EnvFiles.with_manifest(VibePkg.EnvFiles.Manifest(); deps = entries)

    # naive references (the pre-#4720 shapes)
    function naive_dependents(m)
        d = Dict{UUID, Vector{UUID}}()
        for uuid in keys(m.deps), (u2, e2) in m
            uuid in values(e2.deps) && push!(get!(() -> UUID[], d, uuid), u2)
        end
        return d
    end
    function naive_rm_targets(m, seeds)
        targets = Set{UUID}(seeds)
        while true
            grew = false
            for (uuid, entry) in m
                uuid in targets && continue
                if any(in(targets), values(entry.deps))
                    push!(targets, uuid)
                    grew = true
                end
            end
            grew || break
        end
        return targets
    end

    # dependents map == naive double loop
    dependents = VibePkg.EnvFiles.manifest_dependents_map(manifest)
    naive = naive_dependents(manifest)
    @test keys(dependents) == keys(naive)
    @test all(sort(dependents[k]) == sort(naive[k]) for k in keys(naive))

    # rm_manifest! removes exactly the reverse closure: P150 takes P1..P150
    # with it (every Pi with i <= 149 transitively depends on it)
    new_deps = Dict{String, UUID}("P1" => uu(1), "P200" => uu(200))
    pruned = VibePkg.Planning.rm_manifest!(manifest, new_deps, [PackageRequest("P150")])
    expected_keep = union(Set(uu.(151:N)), Set([CYCA, CYCB]))
    @test Set(keys(pruned.deps)) == expected_keep
    @test Set(keys(pruned.deps)) ==
        setdiff(Set(keys(manifest.deps)), naive_rm_targets(manifest, [uu(150)]))
    @test new_deps == Dict("P200" => uu(200))   # dropped request pruned from deps

    # removing one member of the detached cycle removes exactly the pair
    pruned_cyc = VibePkg.Planning.rm_manifest!(manifest, Dict{String, UUID}(), [PackageRequest("CycA")])
    @test Set(keys(pruned_cyc.deps)) == Set(uu.(1:N))

    # prune_manifest keeps exactly the forward closure of the root
    kept = VibePkg.Planning.prune_manifest(manifest, Set([uu(1)]))
    @test Set(keys(kept.deps)) == Set(uu.(1:N))
    # a keep uuid without a manifest entry is harmless (dropped by the filter)
    kept_cyc = VibePkg.Planning.prune_manifest(manifest, Set([CYCA, uu(9999)]))
    @test Set(keys(kept_cyc.deps)) == Set([CYCA, CYCB])

    # load_manifest_deps: complete, deduplicated, prefix-order stable
    nodes = VibePkg.Planning.load_manifest_deps(manifest)
    @test length(nodes) == N + 2
    @test allunique(n.uuid for n in nodes)
    pre = [VibePkg.Planning.Node(; name = "P5", uuid = uu(5))]
    nodes_pre = VibePkg.Planning.load_manifest_deps(manifest, pre)
    @test nodes_pre[1] === pre[1]                  # preloaded node kept first
    @test length(nodes_pre) == N + 2               # and not duplicated
    @test allunique(n.uuid for n in nodes_pre)
end
