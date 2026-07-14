# Parity-gap tests: converting 🟡 PARTIAL audit entries (see TEST_PARITY_TODO.md)
# into ✅ COVERED. Each testset names the Pkg.jl reference testset + line it
# closes. Standalone-runnable and parallel-safe like every other test file.
#
# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
using VibePkg
using VibePkg: PackageSpec
using VibePkg.Errors: PkgError
using VibePkg.Versions: VersionSpec, VersionRange
using VibePkg.API: to_request
using VibePkg.Planning: request_version_spec, plan_add, plan_rm, plan_up,
    plan_develop, plan_pin, plan_free, PackageRequest
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries, RegistryInstance
using VibePkg: Git
using VibePkg.Environments: load_environment, write_environment, is_manifest_current
using VibePkg.Execution: manifest_matches_project
using VibePkg.Display: print_status
using VibePkg.Configs: Config, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR
using VibePkg.TestOps
using VibePkg.EnvFiles: Project, Compat, with_project, stdlib_uuid_for_name,
    entry_version, is_registry_tracked, is_path_tracked, is_repo_tracked,
    entry_repo_rev, entry_tree_hash
using VibePkg.Stdlibs: stdlib_infos
import TOML

const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

# make_test_registry / EXAMPLE_UUID / TEST_UUID / SHA_UUID fixtures (guarded so
# the file stays standalone-runnable and parallel-safe, like planning.jl/ops.jl)
if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

# ===========================================================================
# Wave 1 — pure unit-test gaps (no fixture server needed)
# ===========================================================================

# Pkg.jl pkg.jl "range_compressed_versionspec" (line 1044) — compress a version
# pool (with/without a subset) into a minimal VersionSpec of ranges.
@testset "range_compressed_versionspec" begin
    pool = [v"1.0.0", v"1.1.0", v"1.2.0", v"1.2.1", v"2.0.0", v"2.0.1", v"3.0.0", v"3.1.0"]
    @test (
        VibePkg.Resolve.range_compressed_versionspec(pool)
            == VibePkg.Resolve.range_compressed_versionspec(pool, pool)
            == VersionSpec("1.0.0-3.1.0")
    )
    @test isequal(
        VibePkg.Resolve.range_compressed_versionspec(pool, [v"1.2.0", v"1.2.1", v"2.0.0", v"2.0.1", v"3.0.0"]),
        VersionSpec("1.2.0-3.0.0")
    )
    @test isequal(  # subset has 1.x and 3.x, but not 2.x
        VibePkg.Resolve.range_compressed_versionspec(
            pool, [v"1.0.0", v"1.1.0", v"1.2.0", v"1.2.1", v"3.0.0", v"3.1.0"]
        ),
        VersionSpec([VersionRange(v"1.0.0", v"1.2.1"), VersionRange(v"3.0.0", v"3.1.0")])
    )
    @test VibePkg.Resolve.range_compressed_versionspec(pool, [v"1.1.0"]) == VersionSpec("1.1.0")
end

# Pkg.jl pkg.jl "versionspec with v" (line 1067) — VersionSpec("v1.2.3") strips
# the `v` prefix and gives correct membership.
@testset "versionspec with v" begin
    v = VersionSpec("v1.2.3")
    @test !(v"1.2.2" in v)
    @test   v"1.2.3" in v
    @test !(v"1.2.4" in v)
end

# Pkg.jl misc.jl "PackageSpec version default" (line 50) — a name-only spec
# means "any version". Pkg defaults `.version` to VersionSpec("*"); VibePkg
# keeps PackageSpec a bare input value (.version stays nothing) and applies the
# all-versions default downstream at request_version_spec. Assert the behavior.
@testset "PackageSpec version default" begin
    all_versions = VersionSpec("*")
    @test all_versions == VersionSpec()   # `*` is the all-versions spec

    ps = PackageSpec(name = "Example")
    @test ps.version === nothing
    @test request_version_spec(to_request(ps)) == all_versions

    ps_uuid = PackageSpec(name = "Example", uuid = EXAMPLE_UUID)
    @test request_version_spec(to_request(ps_uuid)) == all_versions

    ps_versioned = PackageSpec(name = "Example", version = v"1.0.0")
    @test ps_versioned.version == v"1.0.0"
    @test request_version_spec(to_request(ps_versioned)) == v"1.0.0"

    ps_str = PackageSpec(name = "Example", version = "1.0.0")
    @test ps_str.version == "1.0.0"
    @test request_version_spec(to_request(ps_str)) == VersionSpec("1.0.0")
    @test request_version_spec(to_request(ps_str)) != all_versions
end

# Pkg.jl api.jl "issue #2587" (line 349) — PackageSpec(uuid=…) normalizes a
# UUID object, a UUID string, a SubString, and UUID(0) to the same Base.UUID;
# defaults leave uuid === nothing.
@testset "PackageSpec uuid normalization" begin
    let u = UUID("00000000-0000-0000-0000-000000000000")
        for x in (
                PackageSpec(; uuid = UUID(0)),
                PackageSpec(; uuid = u),
                PackageSpec(; uuid = "00000000-0000-0000-0000-000000000000"),
                PackageSpec(; uuid = strip("00000000-0000-0000-0000-000000000000")),
            )
            @test x isa PackageSpec
            @test x.uuid isa UUID
            @test x.uuid == u
        end
    end
    for x in (PackageSpec(), PackageSpec(; uuid = nothing))
        @test x isa PackageSpec
        @test x.uuid === nothing
    end
end

# Pkg.jl misc.jl "hashing" (line 12) — core immutable value types hash
# consistently (same object → same hash; ==-equal → equal hash). VersionSpec /
# ManifestEntry hashes are documented as unstable, so only assert they run.
@testset "hashing" begin
    @test hash(VibePkg.EnvFiles.Project()) == hash(VibePkg.EnvFiles.Project())
    @test hash(VibePkg.Versions.VersionBound()) == hash(VibePkg.Versions.VersionBound())
    @test hash(VibePkg.Versions.VersionBound(1, 2, 3)) == hash(VibePkg.Versions.VersionBound(1, 2, 3))

    let a = VibePkg.Resolve.Fixed(v"0.1.0"), b = VibePkg.Resolve.Fixed(v"0.1.0")
        @test a == b
        @test hash(a) == hash(b)
    end

    hash(VersionSpec())
    hash(
        VibePkg.EnvFiles.ManifestEntry(
            "Example", UUID(0),
            VibePkg.EnvFiles.RegistryTracked(v"1.0.0", nothing, String[]),
            false,
            Dict{String, UUID}(), Dict{String, UUID}(),
            Dict{String, Union{String, Vector{String}}}(),
            Dict{String, VibePkg.EnvFiles.AppInfo}(),
            nothing, nothing, Dict{String, Any}(),
        )
    )
    @test true
end

# Pkg.jl manifests.jl "dropbuild" (line 202) — strips the DEV build number
# (1.2.3-DEV.2134 → 1.2.3-DEV) while leaving plain/rc versions intact.
@testset "dropbuild" begin
    @test VibePkg.Planning.dropbuild(v"1.2.3-DEV.2134") == v"1.2.3-DEV"
    @test VibePkg.Planning.dropbuild(v"1.2.3-DEV") == v"1.2.3-DEV"
    @test VibePkg.Planning.dropbuild(v"1.2.3") == v"1.2.3"
    @test VibePkg.Planning.dropbuild(v"1.2.3-rc1") == v"1.2.3-rc1"
end

# Pkg.jl pkg.jl "PkgError printing" (line 769) — show renders PkgError("…") and
# showerror prints the bare message.
@testset "PkgError printing" begin
    err = PkgError("some message")
    @test occursin("PkgError(\"some message\")", sprint(show, err))
    @test sprint(showerror, err) == "some message"
end

# ===========================================================================
# Wave 2 — URL/normalization, stdlib completion, and fixture-server gaps
# ===========================================================================

# Pkg.jl pkg.jl "URL with trailing slash" (line 959, PR #1784) — adding by a
# `.git/` URL behaves like the non-slash form; normalize_url strips it.
@testset "URL trailing slash" begin
    base = "https://github.com/JuliaLang/Example.jl.git"
    @test VibePkg.Git.normalize_url(base * "/") == base
    @test VibePkg.Git.normalize_url(base * "/") == VibePkg.Git.normalize_url(base)
    @test VibePkg.Git.normalize_url(base * "///") == base
end

# Pkg.jl pkg.jl "stdlib_resolve!" (line 662) — bidirectional stdlib name<->uuid
# completion. VibePkg's PackageSpec is immutable (no in-place stdlib_resolve!);
# completion goes through EnvFiles.stdlib_uuid_for_name (name->uuid) and
# Stdlibs.stdlib_infos()[uuid].name (uuid->name). A local `complete` helper
# reproduces Pkg's fill-missing-leave-full-alone semantics over those accessors.
@testset "stdlib name<->uuid completion" begin
    infos = stdlib_infos()
    function complete(s::PackageSpec)
        if s.uuid === nothing && s.name !== nothing
            u = stdlib_uuid_for_name(s.name)
            u === nothing && return s
            return PackageSpec(; name = s.name, uuid = u)
        elseif s.name === nothing && s.uuid !== nothing
            haskey(infos, s.uuid) || return s
            return PackageSpec(; name = infos[s.uuid].name, uuid = s.uuid)
        end
        return s
    end

    test_uuid = UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")
    sha_uuid = UUID("ea8e919c-243c-51af-8825-aaa63cd721ce")

    a = complete(PackageSpec(name = "Test"))          # name only -> uuid filled
    @test a.name == "Test"
    @test a.uuid == test_uuid

    b = complete(PackageSpec(uuid = sha_uuid))        # uuid only -> name filled
    @test b.uuid == sha_uuid
    @test b.name == "SHA"

    x = PackageSpec(name = "Test", uuid = test_uuid)  # fully specified -> unchanged
    xr = complete(x)
    @test xr.name == "Test"
    @test xr.uuid == test_uuid
    @test xr == x

    @test stdlib_uuid_for_name("SHA") == sha_uuid
    @test infos[test_uuid].name == "Test"
    @test stdlib_uuid_for_name("NotAStdlibXYZ") === nothing
end

# Pkg.jl force_latest_compatible_version.jl "get_earliest_backwards_compatible_version"
# (line 32) — with allow_earlier_backwards_compatible_versions=true, the forced
# compat floors at the leading non-zero semver component (1.2.3->1.0.0,
# 0.2.3->0.2.0, 0.0.3->0.0.3). buildtest's existing "force_latest_compat" only
# exercises the false branch. The floor logic is inline in force_latest_compat;
# observe it via the returned Project's compat lower bounds.
@testset "test: force_latest_compat backwards-compat floor" begin
    floor_major = UUID("aa000000-0000-0000-0000-000000000001")  # 1.2.3 -> 1.0.0
    floor_minor = UUID("aa000000-0000-0000-0000-000000000002")  # 0.2.3 -> 0.2.0
    floor_patch = UUID("aa000000-0000-0000-0000-000000000003")  # 0.0.3 -> 0.0.3

    make_floor_registry = function (depot)
        reg = joinpath(depot, "registries", "FloorRegistry")
        mkpath(reg)
        write(
            joinpath(reg, "Registry.toml"), """
            name = "FloorRegistry"
            uuid = "23338594-aafe-5451-b93e-139f81909107"
            repo = "https://example.com/FloorRegistry.git"

            [packages]
            $floor_major = { name = "MajorPkg", path = "M/MajorPkg" }
            $floor_minor = { name = "MinorPkg", path = "M/MinorPkg" }
            $floor_patch = { name = "PatchPkg", path = "P/PatchPkg" }
            """
        )
        for (name, path, uuid, ver) in (
                ("MajorPkg", "M/MajorPkg", floor_major, "1.2.3"),
                ("MinorPkg", "M/MinorPkg", floor_minor, "0.2.3"),
                ("PatchPkg", "P/PatchPkg", floor_patch, "0.0.3"),
            )
            pkg = joinpath(reg, path)
            mkpath(pkg)
            write(
                joinpath(pkg, "Package.toml"), """
                name = "$name"
                uuid = "$uuid"
                repo = "https://example.com/$name.jl.git"
                """
            )
            write(
                joinpath(pkg, "Versions.toml"), """
                ["$ver"]
                git-tree-sha1 = "$("1"^40)"
                """
            )
        end
        return reg
    end

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_floor_registry(depot)
        regs = reachable_registries(depot_stack([depot]))
        project = with_project(
            Project();
            deps = Dict(
                "MajorPkg" => floor_major,
                "MinorPkg" => floor_minor,
                "PatchPkg" => floor_patch,
            ),
            # existing compat is bounded above (so the floored spec re-parses)
            # and extends below each floor (so the floor tightening is observable)
            compat = Dict(
                "MajorPkg" => Compat("0.9, 1"),       # latest 1.2.3, floor 1.0.0
                "MinorPkg" => Compat("0.1, 0.2"),     # latest 0.2.3, floor 0.2.0
                "PatchPkg" => Compat("0.0.1, 0.0.3"), # latest 0.0.3, floor 0.0.3
            ),
        )
        tested = UUID("ffffffff-0000-0000-0000-000000000000")  # dummy tested-pkg uuid
        forced = TestOps.force_latest_compat(
            project, tested, regs;
            allow_earlier_backwards_compatible_versions = true,
        )
        major = forced.compat["MajorPkg"].val         # 1.2.3 -> lower bound 1.0.0
        @test v"1.0.0" in major
        @test !(v"0.9.9" in major)
        minor = forced.compat["MinorPkg"].val         # 0.2.3 -> lower bound 0.2.0
        @test v"0.2.0" in minor
        @test !(v"0.1.9" in minor)
        patch = forced.compat["PatchPkg"].val         # 0.0.3 -> lower bound 0.0.3
        @test v"0.0.3" in patch
        @test !(v"0.0.2" in patch)
    end
end

# Pkg.jl pkg.jl "adding nonexisting packages" (line 489) — add/update of a
# syntactically-valid but unregistered name throws PkgError (not a syntax error).
@testset "add nonexistent package throws" begin
    LocalPkgServer.ensure!()
    mktempdir() do tmpdepot
        depots = depot_stack([tmpdepot])
        VibePkg.Registries.add_default_registries!(depots; io = devnull)
        real_regs = reachable_registries(depots; read_from_tarball = true)
        mktempdir() do dir
            env = VibePkg.Environments.load_environment(dir; depots)
            config = VibePkg.Configs.Config(depots)
            @test VibePkg.Planning.plan_add(
                env, real_regs, config, [VibePkg.Planning.PackageRequest("Example")],
            ) isa VibePkg.Environments.Environment
            err = try
                VibePkg.Planning.plan_add(
                    env, real_regs, config,
                    [VibePkg.Planning.PackageRequest("ThisPackageDoesNotExist")],
                )
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("could not be resolved", sprint(showerror, err))
            @test occursin("ThisPackageDoesNotExist", sprint(showerror, err))
            @test_throws PkgError VibePkg.Planning.plan_up(
                env, real_regs, config,
                [VibePkg.Planning.PackageRequest("ThisPackageDoesNotExist")],
            )
        end
    end
end

# Pkg.jl pkg.jl "simple add, remove and gc" (line 180) — installed package files
# are read-only after an add (writing to them raises SystemError).
@testset "installed files are read-only" begin
    LocalPkgServer.ensure!()
    mktempdir() do tmpdepot
        depots = depot_stack([tmpdepot])
        VibePkg.Registries.add_default_registries!(depots; io = devnull)
        real_regs = reachable_registries(depots; read_from_tarball = true)
        mktempdir() do dir
            env = VibePkg.Environments.load_environment(dir; depots)
            planned = VibePkg.Planning.plan_add(
                env, real_regs, VibePkg.Configs.Config(depots),
                [VibePkg.Planning.PackageRequest("Example")],
            )
            result = VibePkg.Execution.apply!(
                env, planned, real_regs, VibePkg.Configs.Config(depots); io = devnull,
            )
            @test length(result.installed) == 1
            srcfile = joinpath(result.installed[1].path, "src", "Example.jl")
            @test isfile(srcfile)
            if !Sys.iswindows()
                @test filemode(srcfile) & 0o200 == 0        # user-write cleared
                @test filemode(srcfile) & 0o222 == 0        # no write bit at all
                @test_throws SystemError open(io -> nothing, srcfile, "w")
            end
        end
    end
end

# Pkg.jl sources.jl "path normalization in Project.toml [sources]" (line 56) — a
# [sources] path round-trips through read->write as forward slashes, never
# backslashes (Windows-native separators normalized on write).
@testset "sources path is forward-slash normalized" begin
    mktempdir() do tmp
        cd(tmp) do
            write(
                "Project.toml",
                """
                name = "TestPackage"
                uuid = "12345678-1234-1234-1234-123456789abc"

                [deps]
                LocalPkg = "87654321-4321-4321-4321-cba987654321"

                [sources]
                LocalPkg = { path = "subdir/LocalPkg" }
                """
            )
            project = VibePkg.EnvFiles.read_project("Project.toml")
            @test haskey(project.sources, "LocalPkg")
            @test project.sources["LocalPkg"].path !== nothing
            VibePkg.EnvFiles.write_project(project, "Project.toml")
            text = read("Project.toml", String)
            @test occursin("subdir/LocalPkg", text)
            @test !occursin("subdir\\LocalPkg", text)
        end
    end
end

# ===========================================================================
# Wave 3 — plan-level and end-to-end operation gaps
# ===========================================================================

# Pkg.jl pkg.jl "targets should survive add/rm" (line 724, issue #876) — a
# project's [targets] table is unchanged after an add followed by an rm.
@testset "[targets] survive add/rm" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        write(
            joinpath(dir, "Project.toml"), """
            [deps]
            Example = "$EXAMPLE_UUID"

            [extras]
            Test = "$TEST_UUID"
            SHA = "$SHA_UUID"

            [targets]
            test = ["Example", "Test"]
            docs = ["SHA"]
            """
        )

        env = load_environment(dir; depots)
        original_targets = deepcopy(env.project.targets)
        @test original_targets == Dict("test" => ["Example", "Test"], "docs" => ["SHA"])

        # SHA is a stdlib extra: add promotes it to a direct dep and rm drops it
        # again; neither touches the targets table.
        env2 = plan_add(env, regs, Config(depots), [PackageRequest("SHA")])
        env3 = plan_rm(env2, [PackageRequest("SHA")])
        @test env3.project.targets == original_targets
        @test env3.project.targets["test"] == ["Example", "Test"]
        @test env3.project.targets["docs"] == ["SHA"]
        @test sprint(TOML.print, env3.project.targets) ==
            sprint(TOML.print, original_targets)
    end
end

# Pkg.jl pkg.jl "up in Project without manifest" (line 511) — in a
# Project.toml-only environment, up resolves and installs the dep, creating the
# manifest from scratch.
@testset "up bootstraps a missing manifest" begin
    LocalPkgServer.ensure!()
    mktempdir() do tmpdepot
        depots = depot_stack([tmpdepot])
        VibePkg.Registries.add_default_registries!(depots; io = devnull)
        real_regs = reachable_registries(depots; read_from_tarball = true)
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
            @test !isfile(joinpath(dir, "Manifest.toml"))

            env = load_environment(dir; depots)
            @test !haskey(env.manifest, EXAMPLE_UUID)

            planned = plan_up(env, real_regs, Config(depots))
            @test haskey(planned.manifest, EXAMPLE_UUID)

            result = VibePkg.Execution.apply!(env, planned, real_regs, Config(depots); io = devnull)
            @test result.wrote
            @test haskey(result.env.manifest, EXAMPLE_UUID)

            manifest_file = joinpath(dir, "Manifest.toml")
            @test isfile(manifest_file)
            reloaded = load_environment(dir; depots)
            @test haskey(reloaded.manifest, EXAMPLE_UUID)
            @test reloaded.manifest[EXAMPLE_UUID].name == "Example"
            @test occursin(string(EXAMPLE_UUID), TOML.parsefile(manifest_file)["deps"]["Example"][1]["uuid"])
        end
    end
end

# Pkg.jl pkg.jl "up should prune manifest" (line 857) — update drops
# now-unreachable indirect deps from the manifest (pruning is not rm-only).
@testset "up prunes an unreachable manifest entry" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        orphan_uuid = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        envdir = mkpath(joinpath(dir, "env"))
        write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Example]]
            deps = ["Test"]
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            uuid = "$EXAMPLE_UUID"
            version = "0.5.1"

            [[deps.Test]]
            uuid = "$TEST_UUID"

            [[deps.Orphan]]
            git-tree-sha1 = "4444444444444444444444444444444444444444"
            uuid = "$orphan_uuid"
            version = "1.0.0"
            """
        )
        env = load_environment(envdir; depots)
        @test haskey(env.manifest, orphan_uuid)
        @test haskey(env.manifest, EXAMPLE_UUID)

        plan = plan_up(env, regs, Config(depots))
        @test !haskey(plan.manifest, orphan_uuid)       # orphan pruned
        @test haskey(plan.manifest, EXAMPLE_UUID)
        @test is_registry_tracked(plan.manifest[EXAMPLE_UUID])
        @test haskey(plan.manifest, TEST_UUID)           # reachable indirect dep kept
    end
end

# Pkg.jl pkg.jl "adding and upgrading different versions" (line 221) — up level
# granularity: FIXED holds, PATCH bumps the patch, MINOR bumps the minor. Uses a
# hand-built registry offering one package at 1.0.0/1.0.1/1.1.0.
@testset "up UPLEVEL patch vs minor" begin
    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        reg = joinpath(depot, "registries", "LevelRegistry")
        lpkg = joinpath(reg, "L", "LevelPkg")
        mkpath(lpkg)
        lp_uuid = UUID("12121212-3434-5656-7878-909090909090")
        write(
            joinpath(reg, "Registry.toml"), """
            name = "LevelRegistry"
            uuid = "23338594-aafe-5451-b93e-139f81909109"
            repo = "https://example.com/LevelRegistry.git"

            [packages]
            $lp_uuid = { name = "LevelPkg", path = "L/LevelPkg" }
            """
        )
        write(
            joinpath(lpkg, "Package.toml"), """
            name = "LevelPkg"
            uuid = "$lp_uuid"
            repo = "https://example.com/LevelPkg.jl.git"
            """
        )
        write(
            joinpath(lpkg, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "$("1"^40)"

            ["1.0.1"]
            git-tree-sha1 = "$("1"^40)"

            ["1.1.0"]
            git-tree-sha1 = "$("1"^40)"
            """
        )
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        envdir = mkpath(joinpath(dir, "env"))
        write(joinpath(envdir, "Project.toml"), "[deps]\nLevelPkg = \"$lp_uuid\"\n")
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.LevelPkg]]
            git-tree-sha1 = "$("1"^40)"
            uuid = "$lp_uuid"
            version = "1.0.0"
            """
        )
        env = load_environment(envdir; depots)
        @test entry_version(env.manifest[lp_uuid]) == v"1.0.0"

        fixed = plan_up(env, regs, Config(depots); level = UPLEVEL_FIXED)
        @test entry_version(fixed.manifest[lp_uuid]) == v"1.0.0"
        patch = plan_up(env, regs, Config(depots); level = UPLEVEL_PATCH)
        @test entry_version(patch.manifest[lp_uuid]) == v"1.0.1"
        minor = plan_up(env, regs, Config(depots); level = UPLEVEL_MINOR)
        @test entry_version(minor.manifest[lp_uuid]) == v"1.1.0"
    end
end

# Pkg.jl new.jl "multiple registries overlapping version ranges for different
# versions" (line 3586) — a second registry offering the package only at an
# incompatible extra version must be resolved around, not turned into an error.
@testset "secondary registry incompatible version is skipped" begin
    mktempdir() do depot
        function make_reg(; name, uuid, version, julia_compat)
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
                joinpath(pkg, "Versions.toml"), """
                ["$version"]
                git-tree-sha1 = "$("1"^40)"
                """
            )
            write(
                joinpath(pkg, "Compat.toml"), """
                ["$version"]
                julia = "$julia_compat"
                """
            )
            return reg
        end

        make_reg(;
            name = "General", uuid = "23338594-aafe-5451-b93e-139f81909106",
            version = "1.0.0", julia_compat = "1"
        )
        make_reg(;
            name = "NewReg", uuid = "83338594-aafe-5451-b93e-139f81909106",
            version = "99.99.99", julia_compat = "0.0"
        )

        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        @test length(regs) == 2

        mktempdir() do envdir
            env = load_environment(envdir; depots)
            config = Config(depots)
            planned = @test_nowarn plan_add(env, regs, config, [PackageRequest("Example")])
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"1.0.0"
        end
    end
end

# Pkg.jl new.jl "add: repo handling" (line 1008) — the is_instantiated predicate
# flips true/false as the install tree is present/absent. VibePkg's equivalent is
# the `installed::Bool` second return of Depots.find_installed (the exact disk
# check ensure_sources_installed! uses to decide whether to download).
@testset "is_instantiated toggles with the install tree" begin
    LocalPkgServer.ensure!()
    mktempdir() do tmpdepot
        depots = depot_stack([tmpdepot])
        VibePkg.Registries.add_default_registries!(depots; io = devnull)
        real_regs = reachable_registries(depots; read_from_tarball = true)
        mktempdir() do dir
            env = load_environment(dir; depots)
            planned = plan_add(env, real_regs, Config(depots), [PackageRequest("Example")])
            result = VibePkg.Execution.apply!(env, planned, real_regs, Config(depots); io = devnull)
            @test length(result.installed) == 1
            treepath = result.installed[1].path

            env2 = load_environment(dir; depots)
            hash = VibePkg.EnvFiles.entry_tree_hash(env2.manifest[EXAMPLE_UUID])
            path, installed = VibePkg.Depots.find_installed(depots, "Example", EXAMPLE_UUID, hash)
            @test installed
            @test path == treepath

            Base.rm(treepath; recursive = true, force = true)
            env3 = load_environment(dir; depots)
            hash3 = VibePkg.EnvFiles.entry_tree_hash(env3.manifest[EXAMPLE_UUID])
            _, installed_after = VibePkg.Depots.find_installed(depots, "Example", EXAMPLE_UUID, hash3)
            @test !installed_after
        end
    end
end

# ===========================================================================
# Wave 4 — validation and plan-level diagnostics
# ===========================================================================

# Pkg.jl pkg.jl "package name in resolver errors" (350) / new.jl (3471) —
# requesting a registered package at an unsatisfiable version (Example@99.0.0)
# fails resolution with a message that names the offending package.
@testset "resolver error names the package" begin
    mktempdir() do depot
        make_test_registry(depot)      # Example at 0.5.0 / 0.5.1 / 1.0.0
        regs = reachable_registries(depot_stack([depot]))
        mktempdir() do dir
            env = load_environment(dir; depots = depot_stack([depot]))
            req = [PackageRequest("Example", nothing, "99.0.0")]
            err = try
                plan_add(env, regs, Config(depot_stack([depot])), req)
                nothing
            catch e
                e
            end
            @test err isa VibePkg.Resolve.ResolverError
            m = replace(sprint(showerror, err), r"\e\[[0-9;]*m" => "")
            @test occursin("Unsatisfiable requirements detected for package", m)
            @test occursin("Example", m)
        end
    end
end

# Pkg.jl pkg.jl "invalid repo url" (596) — add("https://github.com") and
# add("./Foobar") throw PkgError at input-validation time (no clone/network): a
# URL/path-looking positional is treated as a package name and fails
# check_package_name, while a path= spec into an absent dir fails the isdir guard.
@testset "invalid repo url / path add errors" begin
    grab(f) = try
        f(); nothing
    catch e
        e isa PkgError ? e : rethrow()
    end

    e_url = grab(() -> VibePkg.add("https://github.com"))
    @test e_url isa PkgError
    @test e_url.msg == "`https://github.com` is not a valid package name\n" *
        "The argument appears to be a URL or path, perhaps you meant " *
        "`Pkg.add(url=\"...\")` or `Pkg.add(path=\"...\")`."

    e_relname = grab(() -> VibePkg.add("./Foobar"))
    @test e_relname isa PkgError
    @test e_relname.msg == "`./Foobar` is not a valid package name\n" *
        "The argument appears to be a URL or path, perhaps you meant " *
        "`Pkg.add(url=\"...\")` or `Pkg.add(path=\"...\")`."

    mktempdir() do dir
        cd(dir) do
            @test !isdir("Foobar")
            e_path = grab(() -> VibePkg.add(PackageSpec(; path = "./Foobar"); io = devnull))
            @test e_path isa PkgError
            @test e_path.msg == "Path `$(abspath("./Foobar"))` does not exist."
        end
    end
end

# Pkg.jl new.jl "API details" (3481) — add(packages) must not mutate the
# caller's PackageSpec vector. VibePkg's PackageSpec is immutable and the vector
# normalizer API.split_specs builds fresh PackageRequests in a new vector.
@testset "add does not mutate the input spec vector" begin
    specs = [PackageSpec(name = "Example"), PackageSpec(name = "Test")]
    before = deepcopy(specs)
    saved = collect(specs)

    reqs, repo_like, name_rev = VibePkg.API.split_specs(specs)

    @test reqs == [to_request(PackageSpec(name = "Example")), to_request(PackageSpec(name = "Test"))]
    @test isempty(repo_like)
    @test isempty(name_rev)
    @test length(specs) == length(before) == 2
    @test specs == before
    @test all(specs[i] === saved[i] for i in eachindex(specs))
    @test specs[1].name == "Example" && specs[2].name == "Test"
end

# Pkg.jl new.jl "develop: input checking" (1516) — develop-specific spec
# validation not already covered on the develop path by argshapes.jl: a spaced
# name, a `./`-path/URL hint that names `Pkg.develop` (mode-specific), and
# resolving an unregistered valid name through develop's registry lookup.
@testset "develop input checking" begin
    msg(f) = try
        f(); "NO ERROR"
    catch e
        e isa PkgError ? e.msg : rethrow()
    end

    @test msg(() -> VibePkg.develop(name = "Foo Bar")) ==
        "`Foo Bar` is not a valid package name"
    @test msg(() -> VibePkg.develop("./Foobar")) ==
        "`./Foobar` is not a valid package name\nThe argument appears to be a URL or path, perhaps you meant `Pkg.develop(url=\"...\")` or `Pkg.develop(path=\"...\")`."
    @test msg(() -> VibePkg.develop("https://github.com")) ==
        "`https://github.com` is not a valid package name\nThe argument appears to be a URL or path, perhaps you meant `Pkg.develop(url=\"...\")` or `Pkg.develop(path=\"...\")`."

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        envdir = mkpath(joinpath(dir, "env"))
        write(joinpath(envdir, "Project.toml"), "")

        old_depots = copy(Base.DEPOT_PATH)
        old_project = Base.ACTIVE_PROJECT[]
        old_offline = VibePkg.API.OFFLINE_MODE[]
        try
            empty!(Base.DEPOT_PATH)
            push!(Base.DEPOT_PATH, depot)
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            VibePkg.offline(true)
            withenv("JULIA_PKG_SERVER" => "") do
                m = msg(
                    () -> VibePkg.develop(
                        "ThisIsHopefullyRandom012856014925701382"; io = devnull,
                    )
                )
                @test occursin("could not be resolved", m)
                @test occursin("ThisIsHopefullyRandom012856014925701382", m)
            end
        finally
            empty!(Base.DEPOT_PATH)
            append!(Base.DEPOT_PATH, old_depots)
            Base.ACTIVE_PROJECT[] = old_project
            VibePkg.offline(old_offline)
        end
    end
end

# Pkg.jl registry.jl "same-name different-uuid add conflicts" (270) — installing
# a registry whose name matches an existing one but with a different uuid throws
# PkgError ("conflicts with existing registry").
@testset "same-name different-uuid registry conflict" begin
    function make_source_registry(dir; name, uuid)
        pkg = joinpath(dir, "E", "Example")
        mkpath(pkg)
        write(
            joinpath(dir, "Registry.toml"), """
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
            joinpath(pkg, "Versions.toml"), """
            ["0.5.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            """
        )
        return dir
    end

    mktempdir() do dir
        src1 = make_source_registry(
            mkpath(joinpath(dir, "src1"));
            name = "RegistryFoo", uuid = "23338594-aafe-5451-b93e-139f81909106",
        )
        src2 = make_source_registry(
            mkpath(joinpath(dir, "src2"));
            name = "RegistryFoo", uuid = "43338594-aafe-5451-b93e-139f81909106",
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        name = VibePkg.Registries.add_registry_from_source!(depots, src1; io = devnull)
        @test name == "RegistryFoo"
        r = only(reachable_registries(depots))
        @test VibePkg.Registries.registry_uuid(r) ==
            UUID("23338594-aafe-5451-b93e-139f81909106")

        err = try
            VibePkg.Registries.add_registry_from_source!(depots, src2; io = devnull)
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("conflicts with existing registry", sprint(showerror, err))
        @test occursin("RegistryFoo", sprint(showerror, err))

        r2 = only(reachable_registries(depots))
        @test VibePkg.Registries.registry_uuid(r2) ==
            UUID("23338594-aafe-5451-b93e-139f81909106")
    end
end

# Pkg.jl registry.jl "yanking" (429) — explicitly requesting a yanked version
# (add Example@1.0.0) is a ResolverError; a bare add resolves around it to the
# newest non-yanked version.
@testset "requesting a yanked version errors" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do envdir
            env = load_environment(envdir; depots)
            config = Config(depots)

            good = plan_add(env, regs, config, [PackageRequest("Example")])
            @test entry_version(good.manifest[EXAMPLE_UUID]) == v"0.5.1"

            @test_throws VibePkg.Resolve.ResolverError plan_add(
                env, regs, config, [PackageRequest("Example", nothing, v"1.0.0")],
            )
            @test_throws VibePkg.Resolve.ResolverError plan_add(
                env, regs, config, [PackageRequest("Example", nothing, "1.0.0")],
            )
        end
    end
end

# Pkg.jl manifests.jl "Default manifest format is v2.1" (37) — a fresh add
# writes a manifest whose manifest_format is exactly v2.1.
@testset "fresh add writes manifest_format v2.1" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        write(joinpath(dir, "Project.toml"), "name = \"Root\"\n")
        env = load_environment(dir; depots)
        @test !isfile(joinpath(dir, "Manifest.toml"))

        planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
        @test haskey(planned.manifest, EXAMPLE_UUID)
        @test planned.manifest.manifest_format == v"2.1.0"

        mfile = joinpath(dir, "written_Manifest.toml")
        VibePkg.EnvFiles.write_manifest(planned.manifest, mfile)
        @test TOML.parsefile(mfile)["manifest_format"] == "2.1"
        @test VibePkg.EnvFiles.read_manifest(mfile).manifest_format == v"2.1.0"
    end
end

# ===========================================================================
# Wave 5 — pin/free/update state and registry/manifest gaps
# ===========================================================================

# Pkg.jl new.jl "pin: input checking" (2313) — a package must be in the dep
# graph to pin; pinning to an unresolvable version raises ResolverError; pinning
# an unregistered (dev'd) package to an arbitrary version is a specific PkgError.
@testset "pin input checking" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            @test haskey(env.manifest, EXAMPLE_UUID)

            @test_throws VibePkg.Resolve.ResolverError plan_pin(
                env, regs, Config(depots), [PackageRequest("Example", nothing, "99.0.0")]
            )
            @test_throws PkgError plan_pin(
                env, regs, Config(depots), [PackageRequest("Nonexistent")]
            )

            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")
            denv = plan_develop(env, regs, Config(depots), devpkg)
            m = try
                plan_pin(denv, regs, Config(depots), [PackageRequest("MyDev", nothing, "0.1.0")])
                "NO ERROR"
            catch e
                e isa PkgError ? e.msg : rethrow()
            end
            @test occursin("unable to pin unregistered package", m)
            @test occursin("MyDev", m) && occursin("to an arbitrary version", m)
        end
    end
end

# Pkg.jl new.jl "update: package state changes" (2116) — up leaves a dev'd
# package untouched: still path-tracked, same source path, no version bump.
@testset "up leaves a dev'd package untouched" begin
    dev_uuid = UUID("dead0000-dead-4ead-8ead-deaddeaddead")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            devpkg = joinpath(dir, "LocalDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "LocalDev"
                uuid = "$dev_uuid"
                version = "0.1.0"
                """
            )
            write(joinpath(devpkg, "src", "LocalDev.jl"), "module LocalDev end\n")

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)

            env2 = plan_develop(env, regs, Config(depots), devpkg)
            entry_before = env2.manifest[dev_uuid]
            @test is_path_tracked(entry_before)
            @test !is_registry_tracked(entry_before)
            @test entry_version(entry_before) == v"0.1.0"
            path_before = VibePkg.EnvFiles.entry_path(entry_before)
            @test path_before !== nothing

            env3 = plan_up(env2, regs, Config(depots))
            entry_after = env3.manifest[dev_uuid]
            @test is_path_tracked(entry_after)
            @test !is_registry_tracked(entry_after)
            @test VibePkg.EnvFiles.entry_path(entry_after) == path_before
            @test entry_version(entry_after) == v"0.1.0"
        end
    end
end

# Pkg.jl pkg.jl "issue #1066: colliding name/uuid in project" (810) — Pkg rejects
# add/develop of a dep colliding by name-or-uuid with an existing dep. VibePkg
# keeps [deps] a name→UUID map (a same-name collision can't be expressed), and
# enforces the same-uuid invariant at project read time (validate_project): the
# reload after any such op throws. (Enforcement point differs; invariant is the
# same — no two direct deps share a uuid.)
@testset "colliding name or uuid in project errors" begin
    mktempdir() do dir
        depots = depot_stack([mktempdir()])

        gooddir = mkpath(joinpath(dir, "good"))
        write(
            joinpath(gooddir, "Project.toml"), """
            name = "A"
            uuid = "a066a066-a066-4066-8066-a066a066a066"

            [deps]
            Example = "$EXAMPLE_UUID"
            Foo = "20662066-2066-4066-8066-206620662066"
            """
        )
        env_good = load_environment(gooddir; depots)
        @test env_good.project.deps["Example"] == EXAMPLE_UUID
        @test env_good.project.deps["Foo"] == UUID("20662066-2066-4066-8066-206620662066")

        baddir = mkpath(joinpath(dir, "bad"))
        write(
            joinpath(baddir, "Project.toml"), """
            name = "A"
            uuid = "a066a066-a066-4066-8066-a066a066a066"

            [deps]
            Example = "$EXAMPLE_UUID"
            Foo = "$EXAMPLE_UUID"
            """
        )
        err = try
            load_environment(baddir; depots)
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("Two different dependencies can not have the same uuid", sprint(showerror, err))

        badwdir = mkpath(joinpath(dir, "badweak"))
        write(
            joinpath(badwdir, "Project.toml"), """
            name = "A"
            uuid = "a066a066-a066-4066-8066-a066a066a066"

            [weakdeps]
            Example = "$EXAMPLE_UUID"
            Foo = "$EXAMPLE_UUID"
            """
        )
        errw = try
            load_environment(badwdir; depots)
            nothing
        catch e
            e
        end
        @test errw isa PkgError
        @test occursin("Two different weak dependencies can not have the same uuid", sprint(showerror, errw))
    end
end

# Pkg.jl manifests.jl "Package in multiple registries records all" (599) — a
# package registered in two registries (same uuid, compatible version) records
# both registry names in its manifest entry's registries field (2-element), and
# both registries appear in the manifest's [registries] section.
@testset "package in two registries records both" begin
    mktempdir() do depot
        function make_reg(; name, uuid)
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
                joinpath(pkg, "Versions.toml"), """
                ["1.0.0"]
                git-tree-sha1 = "$("1"^40)"
                """
            )
            return reg
        end

        make_reg(; name = "RegA", uuid = "23338594-aafe-5451-b93e-139f81909106")
        make_reg(; name = "RegB", uuid = "83338594-aafe-5451-b93e-139f81909106")

        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        @test length(regs) == 2

        mktempdir() do envdir
            env = load_environment(envdir; depots)
            planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
            @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"1.0.0"

            entry = planned.manifest[EXAMPLE_UUID]
            recorded = VibePkg.EnvFiles.entry_registries(entry)
            @test length(recorded) == 2
            @test Set(recorded) == Set(["RegA", "RegB"])
            @test Set(keys(planned.manifest.registries)) == Set(["RegA", "RegB"])
        end
    end
end

# Pkg.jl registry.jl "update/rm cycling by uuid, name=uuid" (172) — targeting a
# registry for rm by uuid and by name=uuid (not just bare name). VibePkg's
# remove_registry! matches by uuid when given; update_registries! targets by name
# only (a documented divergence), so update is by name and rm by both uuid forms.
@testset "registry rm/update by uuid and name=uuid" begin
    reg_uuid = UUID("23338594-aafe-5451-b93e-139f81909177")
    function make_source_registry(dir; name, uuid)
        pkg = joinpath(dir, "E", "Example")
        mkpath(pkg)
        write(
            joinpath(dir, "Registry.toml"), """
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
            joinpath(pkg, "Versions.toml"), """
            ["0.5.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            """
        )
        return dir
    end

    mktempdir() do dir
        src = make_source_registry(
            mkpath(joinpath(dir, "src")); name = "UuidReg", uuid = reg_uuid,
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        name = VibePkg.Registries.add_registry_from_source!(depots, src; io = devnull)
        @test name == "UuidReg"
        @test VibePkg.Registries.registry_uuid(only(reachable_registries(depots))) == reg_uuid

        # update targets by name (uuid targeting is a divergence); no-op returns []
        @test VibePkg.Registries.update_registries!(
            depots; names = ["UuidReg"], server = nothing, io = devnull,
        ) == String[]

        # rm BY UUID (name === nothing)
        VibePkg.Registries.remove_registry!(depots, nothing, reg_uuid; io = devnull)
        @test isempty(reachable_registries(depots))
        # rm again is a no-op report, not an error
        @test VibePkg.Registries.remove_registry!(depots, nothing, reg_uuid; io = devnull) === nothing
    end

    # rm-by-name=uuid (both supplied)
    mktempdir() do dir
        src = make_source_registry(
            mkpath(joinpath(dir, "src")); name = "UuidReg", uuid = reg_uuid,
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        @test VibePkg.Registries.add_registry_from_source!(depots, src; io = devnull) == "UuidReg"
        @test length(reachable_registries(depots)) == 1
        VibePkg.Registries.remove_registry!(depots, "UuidReg", reg_uuid; io = devnull)
        @test isempty(reachable_registries(depots))
    end
end

# Pkg.jl pkg.jl "Issue #3147" (1090) — pin/develop/add/up preserve the pin flag
# and tracking kind across op sequences (a coherent subset of the flag matrix).
@testset "pin/track flag transitions (#3147)" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))

            # add → registry-tracked/unpinned; pin flips only the flag; up holds it
            env = load_environment(envdir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            added = env.manifest[EXAMPLE_UUID]
            @test is_registry_tracked(added)
            @test !added.pinned
            @test entry_version(added) == v"0.5.0"

            env = plan_pin(env, regs, Config(depots), [PackageRequest("Example")])
            pinned = env.manifest[EXAMPLE_UUID]
            @test pinned.pinned
            @test is_registry_tracked(pinned)
            @test entry_version(pinned) == v"0.5.0"

            upped = plan_up(env, regs, Config(depots))
            held = upped.manifest[EXAMPLE_UUID]
            @test held.pinned
            @test entry_version(held) == v"0.5.0"

            # dev a path package → path-tracked/unpinned; an unrelated add doesn't disturb it
            devpkg = joinpath(dir, "MyDev")
            mkpath(joinpath(devpkg, "src"))
            write(
                joinpath(devpkg, "Project.toml"), """
                name = "MyDev"
                uuid = "deadbeef-dead-beef-dead-beefdeadbeef"
                version = "0.1.0"
                """
            )
            write(joinpath(devpkg, "src", "MyDev.jl"), "module MyDev end\n")
            DEV_UUID = UUID("deadbeef-dead-beef-dead-beefdeadbeef")

            env2 = load_environment(mkpath(joinpath(dir, "env2")); depots)
            env2 = plan_develop(env2, regs, Config(depots), devpkg)
            dev0 = env2.manifest[DEV_UUID]
            @test is_path_tracked(dev0)
            @test !dev0.pinned
            @test entry_version(dev0) == v"0.1.0"

            env2 = plan_add(env2, regs, Config(depots), [PackageRequest("Example")])
            dev1 = env2.manifest[DEV_UUID]
            @test is_path_tracked(dev1)
            @test !dev1.pinned
            @test entry_version(dev1) == v"0.1.0"

            # dev Example locally, then versionless pin: dev→pin keeps path tracking
            devex = joinpath(dir, "Example")
            mkpath(joinpath(devex, "src"))
            write(
                joinpath(devex, "Project.toml"), """
                name = "Example"
                uuid = "$(EXAMPLE_UUID)"
                version = "0.5.0"
                """
            )
            write(joinpath(devex, "src", "Example.jl"), "module Example end\n")

            env3 = load_environment(mkpath(joinpath(dir, "env3")); depots)
            env3 = plan_develop(env3, regs, Config(depots), devex)
            @test is_path_tracked(env3.manifest[EXAMPLE_UUID])

            env3 = plan_pin(env3, regs, Config(depots), [PackageRequest("Example")])
            devpin = env3.manifest[EXAMPLE_UUID]
            @test devpin.pinned
            @test is_path_tracked(devpin)
            @test !is_registry_tracked(devpin)
            @test entry_version(devpin) == v"0.5.0"
        end
    end
end

# Pkg.jl new.jl "pin: package state changes" (2332) + "free: package state
# changes" (2387) — pinning a repo-tracked package stays repo-tracked (not
# converted to registry) but becomes pinned; freeing it returns to registry
# tracking, unpinned, with the [sources] entry dropped.
@testset "pin and free a repo-tracked package" begin
    fx = LocalPkgServer.ensure!()
    mktempdir() do dir
        dir = realpath(dir)
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        VibePkg.Registries.add_default_registries!(depots; io = devnull)
        regs = reachable_registries(depots; read_from_tarball = true)
        @test any(reg -> haskey(reg, EXAMPLE_UUID), regs)

        rp = Git.materialize_repo_package!(depots, fx.git_repo; rev = "v0.5.3", io = devnull)
        @test rp.name == "Example"
        @test rp.uuid == EXAMPLE_UUID

        envdir = mkpath(joinpath(dir, "env"))
        env = load_environment(envdir; depots)
        config = Config(depots)
        fetcher = Git.source_fetcher(depots; io = devnull)

        planned = plan_add(env, RegistryInstance[], config, [rp]; julia_version = VERSION)
        VibePkg.Environments.write_environment(env, planned)
        env = load_environment(envdir; depots)
        entry = env.manifest[EXAMPLE_UUID]
        @test is_repo_tracked(entry)
        @test !is_registry_tracked(entry)
        @test entry_repo_rev(entry) == "v0.5.3"
        @test entry.pinned == false
        tree_before = entry_tree_hash(entry)

        pinned = plan_pin(env, regs, config, [PackageRequest("Example")]; fetcher)
        pentry = pinned.manifest[EXAMPLE_UUID]
        @test pentry.pinned == true
        @test is_repo_tracked(pentry)
        @test !is_registry_tracked(pentry)
        @test entry_repo_rev(pentry) == "v0.5.3"
        @test entry_tree_hash(pentry) == tree_before
        VibePkg.Environments.write_environment(env, pinned)

        env2 = load_environment(envdir; depots)
        @test is_repo_tracked(env2.manifest[EXAMPLE_UUID])
        @test env2.manifest[EXAMPLE_UUID].pinned == true
        freed = plan_free(env2, regs, config, [PackageRequest("Example")]; fetcher)
        fentry = freed.manifest[EXAMPLE_UUID]
        @test is_registry_tracked(fentry)
        @test !is_repo_tracked(fentry)
        @test fentry.pinned == false
        @test !haskey(freed.project.sources, "Example")
    end
end

# ===========================================================================
# Wave 6 — develop/instantiate/activate/cycle behavior
# ===========================================================================

# Pkg.jl new.jl "develop: package state changes" (1778) — develop overrides a
# package already tracking the registry (or dev'd elsewhere); the manifest keeps
# exactly one entry for it, now path-tracked.
@testset "develop overrides an existing entry (count stays 1)" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            dir = realpath(dir)
            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)

            env = plan_add(env, regs, Config(depots), [PackageRequest("Example", nothing, "0.5.0")])
            @test count(==(EXAMPLE_UUID), keys(env.manifest)) == 1
            @test is_registry_tracked(env.manifest[EXAMPLE_UUID])
            @test env.project.deps["Example"] == EXAMPLE_UUID

            devex = joinpath(dir, "ExampleDev")
            mkpath(joinpath(devex, "src"))
            write(
                joinpath(devex, "Project.toml"), """
                name = "Example"
                uuid = "$EXAMPLE_UUID"
                version = "0.5.0"
                """
            )
            write(joinpath(devex, "src", "Example.jl"), "module Example end\n")

            planned = plan_develop(env, regs, Config(depots), devex)
            @test count(==(EXAMPLE_UUID), keys(planned.manifest)) == 1
            @test is_path_tracked(planned.manifest[EXAMPLE_UUID])
            @test !is_registry_tracked(planned.manifest[EXAMPLE_UUID])
            @test count(==(EXAMPLE_UUID), values(planned.project.deps)) == 1

            devex2 = joinpath(dir, "ExampleDev2")
            mkpath(joinpath(devex2, "src"))
            write(
                joinpath(devex2, "Project.toml"), """
                name = "Example"
                uuid = "$EXAMPLE_UUID"
                version = "0.5.1"
                """
            )
            write(joinpath(devex2, "src", "Example.jl"), "module Example end\n")

            planned2 = plan_develop(planned, regs, Config(depots), devex2)
            @test count(==(EXAMPLE_UUID), keys(planned2.manifest)) == 1
            @test is_path_tracked(planned2.manifest[EXAMPLE_UUID])
            @test entry_version(planned2.manifest[EXAMPLE_UUID]) == v"0.5.1"
            newpath = VibePkg.EnvFiles.entry_path(planned2.manifest[EXAMPLE_UUID])
            @test normpath(joinpath(dirname(planned2.manifest_file), newpath)) == realpath(devex2)
        end
    end
end

# Pkg.jl new.jl "not collecting multiple package instances #1570" (3631) — dev A
# into B, then dev both A and B in a third env (A already dev'd inside B): must
# not error, and A resolves to a single path-tracked entry.
@testset "nested dev does not collect duplicate instances (#1570)" begin
    a_uuid = UUID("1570aaaa-1570-4aaa-8aaa-aaaa15701570")
    b_uuid = UUID("1570bbbb-1570-4bbb-8bbb-bbbb15701570")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            apkg = joinpath(dir, "PkgA")
            mkpath(joinpath(apkg, "src"))
            write(joinpath(apkg, "Project.toml"), "name = \"PkgA\"\nuuid = \"$a_uuid\"\nversion = \"0.1.0\"\n")
            write(joinpath(apkg, "src", "PkgA.jl"), "module PkgA end\n")

            bpkg = joinpath(dir, "PkgB")
            mkpath(joinpath(bpkg, "src"))
            write(
                joinpath(bpkg, "Project.toml"), """
                name = "PkgB"
                uuid = "$b_uuid"
                version = "0.1.0"

                [deps]
                PkgA = "$a_uuid"

                [sources]
                PkgA = { path = "../PkgA" }
                """
            )
            write(joinpath(bpkg, "src", "PkgB.jl"), "module PkgB end\n")

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            planned_b = plan_develop(env, regs, Config(depots), bpkg)
            @test haskey(planned_b.manifest, a_uuid)
            @test haskey(planned_b.manifest, b_uuid)
            write_environment(env, planned_b)

            env = load_environment(envdir; depots)
            planned = plan_develop(env, regs, Config(depots), apkg)   # must not throw
            @test count(u -> u == a_uuid, collect(keys(planned.manifest))) == 1
            aentry = planned.manifest[a_uuid]
            @test aentry.name == "PkgA"
            @test is_path_tracked(aentry)
            @test planned.manifest[b_uuid].deps["PkgA"] == a_uuid
            @test planned.project.deps["PkgA"] == a_uuid

            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test count(u -> u == a_uuid, collect(keys(env.manifest))) == 1
            @test is_path_tracked(env.manifest[a_uuid])
        end
    end
end

# Pkg.jl new.jl "cycles" (3412) — mutual A<->B dev: the manifest holds both
# entries and the cross-references, and resolving the cycle does not error.
@testset "mutual A<->B dev cycle resolves" begin
    a_uuid = UUID("aaaa3412-aaaa-4aaa-8aaa-aaaaaaaa3412")
    b_uuid = UUID("bbbb3412-bbbb-4bbb-8bbb-bbbbbbbb3412")
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            apath = joinpath(dir, "PkgA")
            bpath = joinpath(dir, "PkgB")
            mkpath(joinpath(apath, "src"))
            mkpath(joinpath(bpath, "src"))
            write(
                joinpath(apath, "Project.toml"), """
                name = "PkgA"
                uuid = "$a_uuid"
                version = "0.1.0"

                [deps]
                PkgB = "$b_uuid"

                [sources]
                PkgB = { path = "../PkgB" }
                """
            )
            write(joinpath(apath, "src", "PkgA.jl"), "module PkgA end\n")
            write(
                joinpath(bpath, "Project.toml"), """
                name = "PkgB"
                uuid = "$b_uuid"
                version = "0.1.0"

                [deps]
                PkgA = "$a_uuid"

                [sources]
                PkgA = { path = "../PkgA" }
                """
            )
            write(joinpath(bpath, "src", "PkgB.jl"), "module PkgB end\n")

            envdir = mkpath(joinpath(dir, "env"))
            env = load_environment(envdir; depots)
            planned = plan_develop(env, regs, Config(depots), apath)   # must not throw
            @test haskey(planned.manifest, a_uuid)
            @test haskey(planned.manifest, b_uuid)
            @test is_path_tracked(planned.manifest[a_uuid])
            @test is_path_tracked(planned.manifest[b_uuid])
            @test planned.manifest[a_uuid].deps["PkgB"] == b_uuid
            @test planned.manifest[b_uuid].deps["PkgA"] == a_uuid

            write_environment(env, planned)
            env = load_environment(envdir; depots)
            @test env.manifest[a_uuid].deps["PkgB"] == b_uuid
            @test env.manifest[b_uuid].deps["PkgA"] == a_uuid
        end
    end
end

# Pkg.jl api.jl "Pkg.activate" (12) — no-arg activate() clears ACTIVE_PROJECT to
# the default LOAD_PATH project (Base.ACTIVE_PROJECT[] === nothing).
@testset "activate() with no args clears ACTIVE_PROJECT" begin
    old = Base.ACTIVE_PROJECT[]
    try
        mktempdir() do dir
            dir = realpath(dir)
            VibePkg.activate(joinpath(dir, "proj"); io = devnull)
            @test Base.ACTIVE_PROJECT[] == joinpath(dir, "proj", "Project.toml")
            @test Base.ACTIVE_PROJECT[] !== nothing

            VibePkg.activate(; io = devnull)
            @test Base.ACTIVE_PROJECT[] === nothing
        end
    finally
        Base.ACTIVE_PROJECT[] = old
    end
end

# Pkg.jl new.jl "instantiate: changes to the active project" (1884) — an
# internally inconsistent manifest (a dep on a name with no manifest entry) is
# refused. Divergence: VibePkg validates the dep graph up front in
# parse_manifest, so such a manifest never loads (never reaches instantiate!) —
# stricter than Pkg, which surfaces it at instantiate.
@testset "instantiate errors on an inconsistent manifest" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])

        function write_env(dir, deps_line)
            envdir = mkpath(joinpath(dir, "env"))
            write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
            write(
                joinpath(envdir, "Manifest.toml"), """
                julia_version = "$VERSION"
                manifest_format = "2.0"

                [[deps.Example]]
                uuid = "$EXAMPLE_UUID"
                version = "0.5.3"
                git-tree-sha1 = "0000000000000000000000000000000000000000"
                $deps_line
                """
            )
            return envdir
        end

        # vector form: deps = ["Missing"]
        mktempdir() do dir
            envdir = write_env(dir, "deps = [\"Missing\"]")
            err = try
                load_environment(envdir; depots)
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("depends on `Missing`", err.msg)
            @test occursin("no such entry exists in the manifest", err.msg)
        end

        # dict form: [deps.Example.deps] Missing = "<unknown-uuid>"
        mktempdir() do dir
            envdir = write_env(
                dir,
                "\n    [deps.Example.deps]\n    Missing = \"99999999-9999-9999-9999-999999999999\"",
            )
            err = try
                load_environment(envdir; depots)
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("no such entry exists in the manifest", err.msg)
        end
    end
end

# Pkg.jl manifests.jl "project_hash for identifying out of sync manifest" (239) —
# a [compat] change since the last resolve flips is_manifest_current /
# manifest_matches_project to false. Divergence: Pkg's `status` then prints an
# out-of-sync warning; VibePkg's print_status stays silent (predicate-only), so
# this asserts the flip end-to-end and pins the absence of the status message.
@testset "stale manifest predicate flips (status stays silent)" begin
    mktempdir() do depot
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            envdir = mkpath(joinpath(dir, "env"))
            write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
            env = load_environment(envdir; depots)
            write_environment(env, plan_add(env, regs, Config(depots), [PackageRequest("Example")]))

            current = load_environment(envdir; depots)
            @test is_manifest_current(current) === true
            @test manifest_matches_project(current)

            open(joinpath(envdir, "Project.toml"), "a") do io
                println(io, "\n[compat]\nExample = \"0.5\"")
            end
            stale = load_environment(envdir; depots)
            @test is_manifest_current(stale) === false
            @test !manifest_matches_project(stale)

            out = sprint() do io
                print_status(io, stale; registries = regs)
            end
            @test occursin("Example", out)              # status still renders
            @test !occursin("last resolved", out)       # no out-of-sync footer (divergence)
        end
    end
end
