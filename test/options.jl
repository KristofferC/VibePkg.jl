# Argument-option parity (Pkg REPL options and their API kwargs): up modes,
# preserve threading, all_pkgs scopes, free --all skip semantics, shared
# activate, deprecated status, develop --local clone targets.

if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID
import LibGit2
import TOML
using VibePkg
using VibePkg.Configs: Config, UPLEVEL_FIXED, default_preserve
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries
using VibePkg.Environments
using VibePkg.Planning
using VibePkg.Planning: PackageRequest
using VibePkg.EnvFiles: entry_version
using VibePkg.Errors: PkgError
using VibePkg.Display: print_status

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

const TOP_UUID = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
const DEP_UUID = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
const OLD_UUID = UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")
const LEVEL_UUID = UUID("12121212-3434-5656-7878-909090909090")

# Top → Dep (both with a 1.0.0 and a 1.0.1), plus Oldie which the registry
# marks deprecated: enough structure to tell the up modes apart and to
# exercise `status --deprecated`.
function make_options_registry(depot)
    reg = joinpath(depot, "registries", "OptionsRegistry")
    write_pkg = function (name, uuid, extra_package_toml = "", deps = "")
        dir = joinpath(reg, string(name[1]), name)
        mkpath(dir)
        write(
            joinpath(dir, "Package.toml"), """
            name = "$name"
            uuid = "$uuid"
            repo = "https://example.com/$name.jl.git"
            $extra_package_toml
            """
        )
        write(
            joinpath(dir, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            """
        )
        return isempty(deps) || write(joinpath(dir, "Deps.toml"), deps)
    end
    mkpath(reg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "OptionsRegistry"
        uuid = "23338594-aafe-5451-b93e-139f81909107"
        repo = "https://example.com/OptionsRegistry.git"

        [packages]
        $TOP_UUID = { name = "Top", path = "T/Top" }
        $DEP_UUID = { name = "Dep", path = "D/Dep" }
        $OLD_UUID = { name = "Oldie", path = "O/Oldie" }
        """
    )
    write_pkg(
        "Top", TOP_UUID, "", """
        ["1"]
        Dep = "$DEP_UUID"
        """
    )
    write_pkg("Dep", DEP_UUID)
    write_pkg(
        "Oldie", OLD_UUID, """
        [metadata.deprecated]
        reason = "unmaintained"
        alternative = "Newie"
        """
    )
    return reg
end

# after the initial resolve: Top and Dep both gain a 1.0.1
function add_new_versions!(depot)
    for name in ("Top", "Dep")
        vfile = joinpath(
            depot, "registries", "OptionsRegistry", string(name[1]), name,
            "Versions.toml"
        )
        open(vfile, "a") do io
            print(
                io, """

                ["1.0.1"]
                git-tree-sha1 = "2222222222222222222222222222222222222222"
                """
            )
        end
    end
    return
end

# A real local package repository plus an unpacked registry with one patch and
# one minor release. Public `up` can therefore exercise planning, fetching,
# installation, and manifest writing without contacting the network.
function make_update_level_fixture(dir, depot)
    src = joinpath(dir, "LevelPkg")
    mkpath(joinpath(src, "src"))
    repo = LibGit2.init(src)
    hashes = Dict{VersionNumber, String}()
    sig = LibGit2.Signature("options test", "options@localhost")
    try
        for version in (v"1.0.0", v"1.0.1", v"1.1.0")
            write(
                joinpath(src, "Project.toml"),
                "name = \"LevelPkg\"\nuuid = \"$LEVEL_UUID\"\nversion = \"$version\"\n",
            )
            write(
                joinpath(src, "src", "LevelPkg.jl"),
                "module LevelPkg\nconst FIXTURE_VERSION = v\"$version\"\nend\n",
            )
            LibGit2.add!(repo, ".")
            LibGit2.commit(
                repo, "release $version"; author = sig, committer = sig,
            )
            hashes[version] = bytes2hex(VibePkg.TreeHash.tree_hash(src))
        end
    finally
        close(repo)
    end

    reg = joinpath(depot, "registries", "LevelRegistry")
    pkg = mkpath(joinpath(reg, "L", "LevelPkg"))
    mkpath(reg)
    open(joinpath(reg, "Registry.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "name" => "LevelRegistry",
                "uuid" => "23338594-aafe-5451-b93e-139f81909109",
                "packages" => Dict(
                    string(LEVEL_UUID) => Dict("name" => "LevelPkg", "path" => "L/LevelPkg"),
                ),
            ),
        )
    end
    open(joinpath(pkg, "Package.toml"), "w") do io
        TOML.print(io, Dict("name" => "LevelPkg", "uuid" => string(LEVEL_UUID), "repo" => src))
    end
    open(joinpath(pkg, "Versions.toml"), "w") do io
        TOML.print(
            io,
            Dict(string(version) => Dict("git-tree-sha1" => hash) for (version, hash) in hashes),
        )
    end
    return
end

@testset "argument options" begin
    mktempdir() do depot
        depot = realpath(depot)
        make_options_registry(depot)
        depots = depot_stack([depot])

        mktempdir() do dir
            dir = realpath(dir)
            envdir = joinpath(dir, "env")
            mkpath(envdir)
            env = load_environment(envdir; depots)

            # resolve at Top 1.0.0 / Dep 1.0.0 (the only versions), then the
            # registry gains 1.0.1 of both
            env = plan_add(env, reachable_registries(depots), Config(depots), [PackageRequest("Top")])
            @test entry_version(env.manifest[TOP_UUID]) == v"1.0.0"
            @test entry_version(env.manifest[DEP_UUID]) == v"1.0.0"
            add_new_versions!(depot)
            regs = reachable_registries(depots)

            @testset "up: project vs manifest mode" begin
                # project mode + FIXED level: Top is seeded fixed, Dep is not
                # seeded at all and floats to 1.0.1
                up_project = plan_up(env, regs, Config(depots); level = UPLEVEL_FIXED, mode = :project)
                @test entry_version(up_project.manifest[TOP_UUID]) == v"1.0.0"
                @test entry_version(up_project.manifest[DEP_UUID]) == v"1.0.1"

                # manifest mode + FIXED level: every manifest package is
                # seeded fixed, nothing moves
                up_manifest = plan_up(env, regs, Config(depots); level = UPLEVEL_FIXED, mode = :manifest)
                @test entry_version(up_manifest.manifest[TOP_UUID]) == v"1.0.0"
                @test entry_version(up_manifest.manifest[DEP_UUID]) == v"1.0.0"

                @test_throws PkgError plan_up(env, regs, Config(depots); mode = :bogus)
            end

            @testset "up: named with preserve" begin
                # preserve=ALL (default for named): only Top moves
                up_named = plan_up(env, regs, Config(depots), [PackageRequest("Top")])
                @test entry_version(up_named.manifest[TOP_UUID]) == v"1.0.1"
                @test entry_version(up_named.manifest[DEP_UUID]) == v"1.0.0"
                # preserve=NONE: Dep may move too
                up_none = plan_up(env, regs, Config(depots), [PackageRequest("Top")]; preserve = PRESERVE_NONE)
                @test entry_version(up_none.manifest[TOP_UUID]) == v"1.0.1"
                @test entry_version(up_none.manifest[DEP_UUID]) == v"1.0.1"
            end

            @testset "up: named with preserve=direct" begin
                # Dep as a direct project dep is held even though the named
                # package's deps may otherwise move
                env_direct = plan_add(env, regs, Config(depots), [PackageRequest("Dep", nothing, "1.0.0")])
                @test haskey(env_direct.project.deps, "Dep")
                @test entry_version(env_direct.manifest[DEP_UUID]) == v"1.0.0"
                up_direct = plan_up(env_direct, regs, Config(depots), [PackageRequest("Top")]; preserve = PRESERVE_DIRECT)
                @test entry_version(up_direct.manifest[TOP_UUID]) == v"1.0.1"
                @test entry_version(up_direct.manifest[DEP_UUID]) == v"1.0.0"

                # as a mere indirect dep of the named package it may move
                up_indirect = plan_up(env, regs, Config(depots), [PackageRequest("Top")]; preserve = PRESERVE_DIRECT)
                @test entry_version(up_indirect.manifest[TOP_UUID]) == v"1.0.1"
                @test entry_version(up_indirect.manifest[DEP_UUID]) == v"1.0.1"
            end

            @testset "free: err_if_free" begin
                # Top is registry-tracked and not pinned: freeing errors by
                # default, is skipped under the `--all` semantics
                @test_throws PkgError plan_free(env, regs, Config(depots), [PackageRequest("Top")])
                freed = plan_free(env, regs, Config(depots), [PackageRequest("Top")]; err_if_free = false)
                @test entry_version(freed.manifest[TOP_UUID]) == v"1.0.0"

                # a pinned package still gets unpinned on the same call
                pinned = plan_pin(env, regs, Config(depots), [PackageRequest("Dep")])
                @test pinned.manifest[DEP_UUID].pinned
                freed2 = plan_free(
                    pinned, regs, Config(depots),
                    [PackageRequest("Top"), PackageRequest("Dep")]; err_if_free = false
                )
                @test !freed2.manifest[DEP_UUID].pinned
            end

            @testset "all_pkgs request scopes" begin
                @test sort([r.name for r in VibePkg.API.all_requests(env, :project)]) == ["Top"]
                @test sort([r.name for r in VibePkg.API.all_requests(env, :manifest)]) == ["Dep", "Top"]
            end

            @testset "status --deprecated" begin
                env_dep = plan_add(env, regs, Config(depots), [PackageRequest("Oldie")])
                out = sprint() do io
                    print_status(io, env_dep; registries = regs, deprecated = true)
                end
                @test occursin("Oldie", out)
                @test occursin("[deprecated]", out)
                @test occursin("reason: unmaintained", out)
                @test occursin("alternative: Newie", out)
                @test !occursin("Top", out)   # deprecated mode filters

                # normal status: annotation plus the info line
                out2 = sprint() do io
                    print_status(io, env_dep; registries = regs)
                end
                @test occursin("Top", out2)
                @test occursin("[deprecated]", out2)
                @test occursin("no longer maintained", out2)
                @test !occursin("reason:", out2)
            end

            @testset "manifest_matches_project" begin
                write_environment(load_environment(envdir; depots), env)
                current = load_environment(envdir; depots)
                @test VibePkg.Execution.manifest_matches_project(current)
                # changing project compat invalidates the recorded hash
                open(joinpath(envdir, "Project.toml"), "a") do io
                    println(io, "\n[compat]\nTop = \"1\"")
                end
                stale = load_environment(envdir; depots)
                @test !VibePkg.Execution.manifest_matches_project(stale)
            end

            @testset "offline: installed-only resolution" begin
                old_offline = VibePkg.API.OFFLINE_MODE[]
                try
                    withenv("JULIA_PKG_OFFLINE" => nothing) do
                        VibePkg.API.OFFLINE_MODE[] = false
                        @test !VibePkg.API.is_offline()
                        VibePkg.offline(true)
                        @test VibePkg.API.is_offline()
                        # the session flag lands in the op Config; planning
                        # with an offline config runs installed-only: nothing
                        # in this depot is downloaded, so a fresh add cannot
                        # resolve
                        offline_cfg = Config(depots; offline = VibePkg.API.OFFLINE_MODE[])
                        @test offline_cfg.offline
                        mktempdir() do freshdir
                            env0 = load_environment(freshdir; depots)
                            @test_throws VibePkg.Resolve.ResolverError plan_add(
                                env0, regs, offline_cfg, [PackageRequest("Top")]
                            )
                        end
                        VibePkg.offline(false)
                        @test !VibePkg.API.is_offline()
                        @test !Config(depots; offline = VibePkg.API.OFFLINE_MODE[]).offline
                        # the env var is honored independently of the setter
                        withenv("JULIA_PKG_OFFLINE" => "true") do
                            @test VibePkg.API.is_offline()
                            @test Config(depots).offline
                        end
                    end
                finally
                    VibePkg.API.OFFLINE_MODE[] = old_offline
                end
            end
        end

        @testset "activate --shared" begin
            old_active = Base.ACTIVE_PROJECT[]
            old_depot_path = copy(Base.DEPOT_PATH)
            try
                copy!(Base.DEPOT_PATH, [depot])
                VibePkg.API.activate("optenv"; shared = true, io = devnull)
                @test Base.ACTIVE_PROJECT[] ==
                    joinpath(depot, "environments", "optenv", "Project.toml")
                shared_project = Base.ACTIVE_PROJECT[]
                for bad in ("", ".", "..", "./Foo", "Foo/Bar", "../Bar")
                    @test_throws PkgError VibePkg.API.activate(bad; shared = true, io = devnull)
                    @test Base.ACTIVE_PROJECT[] == shared_project
                end
                # an existing shared env in a later depot wins over creating anew
                mktempdir() do depot2
                    depot2 = realpath(depot2)
                    mkpath(joinpath(depot2, "environments", "optenv2"))
                    copy!(Base.DEPOT_PATH, [depot, depot2])
                    VibePkg.API.activate("optenv2"; shared = true, io = devnull)
                    @test Base.ACTIVE_PROJECT[] ==
                        joinpath(depot2, "environments", "optenv2", "Project.toml")
                end
                @test_throws PkgError VibePkg.API.activate(; shared = true, io = devnull)
                @test_throws PkgError VibePkg.API.activate("x"; shared = true, temp = true, io = devnull)
            finally
                Base.ACTIVE_PROJECT[] = old_active
                copy!(Base.DEPOT_PATH, old_depot_path)
            end
        end

        @testset "shared develop honors JULIA_PKG_DEVDIR; local ignores it" begin
            old_active = Base.ACTIVE_PROJECT[]
            try
                mktempdir() do projdir
                    projdir = realpath(projdir)
                    write(joinpath(projdir, "Project.toml"), "")
                    Base.ACTIVE_PROJECT[] = joinpath(projdir, "Project.toml")
                    custom_devdir = joinpath(projdir, "custom-shared-dev")
                    withenv("JULIA_PKG_DEVDIR" => custom_devdir) do
                        config = Config(depots)

                        clone_shared, track_shared =
                            VibePkg.API.dev_clone_target(config, "Example"; shared = true)
                        @test clone_shared == track_shared == joinpath(custom_devdir, "Example")

                        clone_local, track_local =
                            VibePkg.API.dev_clone_target(config, "Example"; shared = false)
                        @test clone_local == joinpath(projdir, "dev", "Example")
                        @test track_local == joinpath("dev", "Example")
                        @test !startswith(clone_local, custom_devdir)
                    end
                end
            finally
                Base.ACTIVE_PROJECT[] = old_active
            end
        end
    end
end

@testset "public up: patch/minor levels and missing manifest" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depot_path = copy(Base.DEPOT_PATH)
    old_auto_precompile = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
    old_auto_gc = VibePkg.API.AUTO_GC_ENABLED[]
    old_registry_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    try
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        VibePkg.API.AUTO_GC_ENABLED[] = false
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        mktempdir() do dir
            dir = realpath(dir)
            depot = mkpath(joinpath(dir, "depot"))
            make_update_level_fixture(dir, depot)
            copy!(Base.DEPOT_PATH, [depot])
            depots = depot_stack([depot])

            withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_OFFLINE" => nothing) do
                envdir = mkpath(joinpath(dir, "levels"))
                write(joinpath(envdir, "Project.toml"), "")
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")

                VibePkg.add(PackageSpec(name = "LevelPkg", version = v"1.0.0"); io = devnull)
                env = load_environment(envdir; depots)
                @test entry_version(env.manifest[LEVEL_UUID]) == v"1.0.0"

                VibePkg.up(; level = UPLEVEL_PATCH, io = devnull)
                env = load_environment(envdir; depots)
                @test entry_version(env.manifest[LEVEL_UUID]) == v"1.0.1"

                VibePkg.up(; level = UPLEVEL_MINOR, io = devnull)
                env = load_environment(envdir; depots)
                @test entry_version(env.manifest[LEVEL_UUID]) == v"1.1.0"

                # A project-only environment is enough input for public `up`:
                # it resolves, installs, and writes a new manifest.
                fresh = mkpath(joinpath(dir, "no-manifest"))
                write(
                    joinpath(fresh, "Project.toml"),
                    "[deps]\nLevelPkg = \"$LEVEL_UUID\"\n",
                )
                @test !isfile(joinpath(fresh, "Manifest.toml"))
                Base.ACTIVE_PROJECT[] = joinpath(fresh, "Project.toml")
                VibePkg.up(; io = devnull)
                @test isfile(joinpath(fresh, "Manifest.toml"))
                fresh_env = load_environment(fresh; depots)
                @test entry_version(fresh_env.manifest[LEVEL_UUID]) == v"1.1.0"
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depot_path)
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto_precompile
        VibePkg.API.AUTO_GC_ENABLED[] = old_auto_gc
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_registry_gate
    end
end

@testset "activate: path, default, temp" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depot_path = copy(Base.DEPOT_PATH)
    try
        mktempdir() do dir
            dir = realpath(dir)

            # plain path form: the env at that path becomes active
            VibePkg.API.activate(joinpath(dir, "proj"); io = devnull)
            @test Base.ACTIVE_PROJECT[] == joinpath(dir, "proj", "Project.toml")

            # no-arg: back to the default environment
            VibePkg.API.activate(; io = devnull)
            @test Base.ACTIVE_PROJECT[] === nothing

            # temp=true: a real, usable environment directory
            VibePkg.API.activate(; temp = true, io = devnull)
            tmp_proj = Base.ACTIVE_PROJECT[]
            @test tmp_proj !== nothing
            tmpdir = dirname(tmp_proj)
            @test isdir(tmpdir)
            write(joinpath(tmpdir, "probe"), "x")      # writable
            @test isfile(joinpath(tmpdir, "probe"))

            # path + temp is a contradiction
            @test_throws PkgError VibePkg.API.activate("x"; temp = true, io = devnull)

            # activate installs nothing: a project with a dep gains no
            # manifest and the depot stays empty
            mktempdir() do depot2
                depot2 = realpath(depot2)
                copy!(Base.DEPOT_PATH, [depot2])
                envdir = joinpath(dir, "lazy")
                mkpath(envdir)
                write(
                    joinpath(envdir, "Project.toml"), """
                    [deps]
                    Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                    """
                )
                VibePkg.API.activate(envdir; io = devnull)
                @test Base.ACTIVE_PROJECT[] == joinpath(envdir, "Project.toml")
                @test !isfile(joinpath(envdir, "Manifest.toml"))
                @test !isdir(joinpath(depot2, "packages"))
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depot_path)
    end
end

# add: preserve semantics against a registry that gained newer versions
@testset "add preserve against newer registry versions" begin
    mktempdir() do depot
        depot = realpath(depot)
        make_options_registry(depot)
        depots = depot_stack([depot])
        mktempdir() do envdir
            env = load_environment(envdir; depots)
            env = plan_add(env, reachable_registries(depots), Config(depots), [PackageRequest("Top")])
            @test entry_version(env.manifest[TOP_UUID]) == v"1.0.0"
            @test entry_version(env.manifest[DEP_UUID]) == v"1.0.0"
            add_new_versions!(depot)
            regs = reachable_registries(depots)

            # Pkg.jl#3398 — `add --preserve=all` keeps the existing version
            # of the added package and makes it a project dep
            added = plan_add(env, regs, Config(depots), [PackageRequest("Dep")]; preserve = PRESERVE_ALL)
            @test entry_version(added.manifest[DEP_UUID]) == v"1.0.0"
            @test added.project.deps["Dep"] == DEP_UUID

            # Pkg.jl#607 — plain `add` of an unrelated package does not move
            # the packages already in the manifest
            added2 = plan_add(env, regs, Config(depots), [PackageRequest("Oldie")])
            @test haskey(added2.manifest, OLD_UUID)
            @test entry_version(added2.manifest[TOP_UUID]) == v"1.0.0"
            @test entry_version(added2.manifest[DEP_UUID]) == v"1.0.0"
        end
    end
end

@testset "JULIA_PKG_PRESERVE_TIERED_INSTALLED" begin
    withenv("JULIA_PKG_PRESERVE_TIERED_INSTALLED" => nothing) do
        @test default_preserve() == PRESERVE_TIERED
    end
    withenv("JULIA_PKG_PRESERVE_TIERED_INSTALLED" => "true") do
        @test default_preserve() == PRESERVE_TIERED_INSTALLED
    end
    withenv("JULIA_PKG_PRESERVE_TIERED_INSTALLED" => "false") do
        @test default_preserve() == PRESERVE_TIERED
    end
end

# Config env-var validation: JULIA_PKG_CONCURRENT_DOWNLOADS must be a positive
# integer (Pkg parity: error on zero/negative/garbage instead of clamping),
# JULIA_PKG_DEVDIR overrides the first-depot default
@testset "Config environment variables" begin
    mktempdir() do depot
        depot = realpath(depot)
        depots = depot_stack([depot])
        withenv("JULIA_PKG_CONCURRENT_DOWNLOADS" => nothing) do
            @test Config(depots).concurrency == 8
        end
        withenv("JULIA_PKG_CONCURRENT_DOWNLOADS" => "3") do
            @test Config(depots).concurrency == 3
        end
        for bad in ("0", "-2", "garbage", "")
            withenv("JULIA_PKG_CONCURRENT_DOWNLOADS" => bad) do
                err = try
                    Config(depots)
                catch e
                    e
                end
                @test err isa PkgError
                @test occursin("JULIA_PKG_CONCURRENT_DOWNLOADS", sprint(showerror, err))
            end
        end
        withenv("JULIA_PKG_DEVDIR" => joinpath(depot, "mydev")) do
            @test Config(depots).devdir == joinpath(depot, "mydev")
        end
        withenv("JULIA_PKG_DEVDIR" => nothing) do
            @test Config(depots).devdir == joinpath(depot, "dev")
        end
    end
end

# Cpt at 0.1.0/0.2.0/0.3.0: enough versions for the docs' compat-conflict
# walkthrough (conflicting entry → error, widened entry → up lands in range)
const CPT_UUID = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")

function make_compat_registry(depot)
    reg = joinpath(depot, "registries", "CompatRegistry")
    pkg = joinpath(reg, "C", "Cpt")
    mkpath(pkg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "CompatRegistry"
        uuid = "23338594-aafe-5451-b93e-139f81909108"
        repo = "https://example.com/CompatRegistry.git"

        [packages]
        $CPT_UUID = { name = "Cpt", path = "C/Cpt" }
        """
    )
    write(
        joinpath(pkg, "Package.toml"), """
        name = "Cpt"
        uuid = "$CPT_UUID"
        repo = "https://example.com/Cpt.jl.git"
        """
    )
    write(
        joinpath(pkg, "Versions.toml"), """
        ["0.1.0"]
        git-tree-sha1 = "1111111111111111111111111111111111111111"

        ["0.2.0"]
        git-tree-sha1 = "2222222222222222222222222222222222222222"

        ["0.3.0"]
        git-tree-sha1 = "3333333333333333333333333333333333333333"
        """
    )
    return reg
end

@testset "compat conflict then up" begin
    mktempdir() do depot
        depot = realpath(depot)
        make_compat_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        mktempdir() do dir
            env = load_environment(dir; depots)
            env = plan_add(env, regs, Config(depots), [PackageRequest("Cpt")])
            @test entry_version(env.manifest[CPT_UUID]) == v"0.3.0"

            # a compat entry excluding the resolved version refuses to apply
            # (Pkg.compat does not downgrade; it tells the user to update)
            err = try
                plan_compat(env, regs, Config(depots), "Cpt", "0.1")
            catch e
                e
            end
            @test err isa PkgError
            @test occursin("update", sprint(showerror, err))

            # widened compat still conflicts with the manifest as-is, but
            # `up` re-resolves and lands on the newest allowed version
            env2 = plan_compat_entry(env, "Cpt", "0.1, 0.2")
            up = plan_up(env2, regs, Config(depots))
            @test entry_version(up.manifest[CPT_UUID]) == v"0.2.0"
        end
    end
end

# docs (managing-packages § Developing packages): `dev` on a package whose
# checkout already exists at the dev dir re-uses that path instead of
# re-cloning. The url is dead on purpose: a re-clone attempt would throw.
@testset "develop reuses an existing dev-dir clone" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depot_path = copy(Base.DEPOT_PATH)
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    try
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        mktempdir() do dir
            dir = realpath(dir)
            depot = mkpath(joinpath(dir, "depot"))
            make_compat_registry(depot)
            devdir = mkpath(joinpath(dir, "devdir"))
            clone = mkpath(joinpath(devdir, "Sentinel"))
            mkpath(joinpath(clone, "src"))
            write(
                joinpath(clone, "Project.toml"), """
                name = "Sentinel"
                uuid = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
                version = "0.1.0"
                """
            )
            write(joinpath(clone, "src", "Sentinel.jl"), "module Sentinel end\n")
            write(joinpath(clone, "SENTINEL"), "local edits live here\n")

            proj = mkpath(joinpath(dir, "proj"))
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")
            withenv("JULIA_PKG_DEVDIR" => devdir) do
                VibePkg.develop(PackageSpec(url = "https://dead.invalid/Sentinel.jl"); io = devnull)
            end
            @test isfile(joinpath(clone, "SENTINEL"))
            env = load_environment(proj; depots = depot_stack([depot]))
            entry = env.manifest[UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")]
            @test VibePkg.EnvFiles.is_path_tracked(entry)
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depot_path)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
    end
end
