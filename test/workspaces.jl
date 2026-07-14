# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

# Exercises workspace member discovery, the shared root manifest,
# union-deps resolution with intersected compat, and member/root hash
# agreement.
using Test
using VibePkg
using VibePkg.Configs: Config
using Base: UUID
using VibePkg.Depots: depot_stack
using VibePkg.Registries: reachable_registries
using VibePkg.Environments
using VibePkg.Planning: plan_resolve, plan_up, UPLEVEL_FIXED
using VibePkg.Display: print_status
using VibePkg.EnvFiles: entry_version, is_path_tracked, entry_path, read_project
using VibePkg.Errors: PkgError
import VibePkg.Execution

const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
const SUB_UUID = UUID("5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5a")
const A_UUID = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
const B_UUID = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
const UNREG_UUID = UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")

function make_test_registry(depot)
    reg = joinpath(depot, "registries", "TestRegistry")
    pkg = joinpath(reg, "E", "Example")
    mkpath(pkg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "TestRegistry"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "https://example.com/TestRegistry.git"

        [packages]
        7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
        """
    )
    write(
        joinpath(pkg, "Package.toml"), """
        name = "Example"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        repo = "https://example.com/Example.jl.git"
        """
    )
    write(
        joinpath(pkg, "Versions.toml"), """
        ["0.5.0"]
        git-tree-sha1 = "1111111111111111111111111111111111111111"

        ["0.5.1"]
        git-tree-sha1 = "2222222222222222222222222222222222222222"
        """
    )
    return reg
end

@testset "workspaces" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["sub"]

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            SubPkg = "$SUB_UUID"

            [compat]
            Example = "=0.5.0"
            """
        )
        sub = mkpath(joinpath(root, "sub"))
        mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"), """
            name = "SubPkg"
            uuid = "$SUB_UUID"
            version = "0.1.0"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"

            [compat]
            Example = "0.5"
            """
        )
        write(joinpath(sub, "src", "SubPkg.jl"), "module SubPkg end\n")

        # loading a member finds the root's manifest and the workspace
        env = load_environment(sub; depots)
        rroot = realpath(root)
        @test env.manifest_file == joinpath(rroot, "Manifest.toml")
        @test length(env.workspace) == 1
        @test env.workspace[1].first == joinpath(rroot, "Project.toml")

        # resolution: union of deps, compat intersected across members
        # (root caps Example at =0.5.0 even though sub allows 0.5.*)
        planned = plan_resolve(env, regs, Config(depots))
        @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.0"
        @test is_path_tracked(planned.manifest[SUB_UUID])   # member is in the manifest

        # writing puts the manifest at the ROOT; the member gets none
        write_environment(env, planned)
        @test isfile(joinpath(root, "Manifest.toml"))
        @test !isfile(joinpath(sub, "Manifest.toml"))

        # the resolve hash agrees from any member
        env_root = load_environment(root; depots)
        @test length(env_root.workspace) == 1
        @test resolve_hash(load_environment(sub; depots)) == resolve_hash(env_root)
        @test is_manifest_current(env_root) == true

        # status --workspace shows the union of every member's deps: from
        # the sub member, SubPkg (a dep of the root) only appears with the flag
        env_sub = load_environment(sub; depots)
        s_plain = sprint(io -> print_status(io, env_sub))
        s_ws = sprint(io -> print_status(io, env_sub; workspace = true))
        @test occursin("Example", s_plain) && !occursin("SubPkg", s_plain)
        @test occursin("Example", s_ws) && occursin("SubPkg", s_ws)

        # why --workspace: from the sub member, the path through SubPkg (a
        # dependency of the root project) only appears with the flag
        old_active = Base.ACTIVE_PROJECT[]
        old_depot_path = copy(Base.DEPOT_PATH)
        try
            copy!(Base.DEPOT_PATH, [depot])
            Base.ACTIVE_PROJECT[] = joinpath(sub, "Project.toml")
            w_plain = sprint(io -> VibePkg.API.why("Example"; io))
            w_ws = sprint(io -> VibePkg.API.why("Example"; workspace = true, io))
            @test occursin("Example", w_plain) && !occursin("SubPkg", w_plain)
            @test occursin("SubPkg\n  └─▶ Example", w_ws)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depot_path)
        end
    end

    # up --workspace: member deps are seeded at the level for whole-env
    # updates. Root has no deps of its own; the member depends on Example.
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        reg = make_test_registry(depot)
        # stage the registry: only 0.5.0 exists at resolve time
        vfile = joinpath(reg, "E", "Example", "Versions.toml")
        versions_toml = read(vfile, String)
        write(vfile, split(versions_toml, "\n[\"0.5.1\"]")[1])
        depots = depot_stack([depot])

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["sub"]
            """
        )
        sub = mkpath(joinpath(root, "sub"))
        mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"), """
            name = "SubPkg"
            uuid = "$SUB_UUID"
            version = "0.1.0"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(sub, "src", "SubPkg.jl"), "module SubPkg end\n")

        env = load_environment(root; depots)
        planned = plan_resolve(env, reachable_registries(depots), Config(depots))
        @test entry_version(planned.manifest[EXAMPLE_UUID]) == v"0.5.0"
        write_environment(env, planned)

        # 0.5.1 appears in the registry
        write(vfile, versions_toml)
        regs = reachable_registries(depots)
        env = load_environment(root; depots)

        # fixed-level whole-env up: without workspace the member's dep is
        # not seeded and floats; with workspace it is seeded and held
        up_plain = plan_up(env, regs, Config(depots); level = UPLEVEL_FIXED)
        @test entry_version(up_plain.manifest[EXAMPLE_UUID]) == v"0.5.1"
        up_ws = plan_up(env, regs, Config(depots); level = UPLEVEL_FIXED, workspace = true)
        @test entry_version(up_ws.manifest[EXAMPLE_UUID]) == v"0.5.0"
    end

    # instantiate --workspace: a member dep missing from the manifest only
    # errors when the workspace is included
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["sub"]
            """
        )
        sub = mkpath(joinpath(root, "sub"))
        mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"), """
            name = "SubPkg"
            uuid = "$SUB_UUID"
            version = "0.1.0"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(sub, "src", "SubPkg.jl"), "module SubPkg end\n")

        env = load_environment(root; depots)   # no manifest written
        @test Execution.instantiate!(env, regs, Config(depots); io = devnull) !== nothing
        @test_throws PkgError Execution.instantiate!(env, regs, Config(depots); workspace = true, io = devnull)
    end
end

# Nested workspaces: the mid project is itself a workspace member of root
# and declares its own [workspace]; everything merges into the ROOT's
# single manifest.
@testset "nested workspaces" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["mid"]
            """
        )
        mid = mkpath(joinpath(root, "mid"))
        mkpath(joinpath(mid, "src"))
        write(
            joinpath(mid, "Project.toml"), """
            name = "MidPkg"
            uuid = "5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5b"
            version = "0.1.0"

            [workspace]
            projects = ["leaf"]
            """
        )
        write(joinpath(mid, "src", "MidPkg.jl"), "module MidPkg end\n")
        leaf = mkpath(joinpath(mid, "leaf"))
        mkpath(joinpath(leaf, "src"))
        write(
            joinpath(leaf, "Project.toml"), """
            name = "LeafPkg"
            uuid = "5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5c"
            version = "0.1.0"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(leaf, "src", "LeafPkg.jl"), "module LeafPkg end\n")

        # loading the leaf walks up through mid to the ROOT, and member
        # collection recurses: from the leaf the workspace holds root + mid,
        # from the root it holds mid + leaf
        env = load_environment(leaf; depots)
        rroot = realpath(root)
        @test env.manifest_file == joinpath(rroot, "Manifest.toml")
        members = Set(first.(env.workspace))
        @test joinpath(rroot, "Project.toml") in members
        @test realpath(joinpath(mid, "Project.toml")) in members
        root_members = Set(first.(load_environment(root; depots).workspace))
        @test realpath(joinpath(mid, "Project.toml")) in root_members
        @test realpath(joinpath(leaf, "Project.toml")) in root_members

        # one resolution covers the whole tree: leaf's dep lands in the
        # ROOT manifest, both member packages are path-tracked, and no
        # member gets its own manifest
        planned = plan_resolve(env, regs, Config(depots))
        @test haskey(planned.manifest, EXAMPLE_UUID)
        @test is_path_tracked(planned.manifest[UUID("5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5b")])
        @test is_path_tracked(planned.manifest[UUID("5ab5ab5a-b5ab-5ab5-ab5a-b5ab5ab5ab5c")])
        write_environment(env, planned)
        @test isfile(joinpath(root, "Manifest.toml"))
        @test !isfile(joinpath(mid, "Manifest.toml"))
        @test !isfile(joinpath(leaf, "Manifest.toml"))

        # the merged view agrees from every level: nested member collection
        # recurses, so root, mid and leaf all hash the same root∪mid∪leaf set
        @test resolve_hash(load_environment(mid; depots)) ==
            resolve_hash(load_environment(root; depots))
        @test resolve_hash(load_environment(leaf; depots)) ==
            resolve_hash(load_environment(root; depots))
        # a root-side resolve sees the leaf's dep (this was the bug: member
        # collection used to stop at the root's own `projects` list)
        planned_root = plan_resolve(load_environment(root; depots), regs, Config(depots))
        @test haskey(planned_root.manifest, EXAMPLE_UUID)
    end
end

# Ops inside a workspace must not write `[sources]` entries for workspace
# members into the active project: members are path-tracked in the shared
# manifest by virtue of membership. Pkg.jl#4356 Pkg.jl#4237
@testset "no [sources] entries for workspace members" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["A", "B"]

            [deps]
            APkg = "$A_UUID"
            """
        )
        a = mkpath(joinpath(root, "A"))
        mkpath(joinpath(a, "src"))
        write(
            joinpath(a, "Project.toml"), """
            name = "APkg"
            uuid = "$A_UUID"
            version = "0.1.0"

            [deps]
            BPkg = "$B_UUID"
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(a, "src", "APkg.jl"), "module APkg end\n")
        b = mkpath(joinpath(root, "B"))
        mkpath(joinpath(b, "src"))
        write(
            joinpath(b, "Project.toml"), """
            name = "BPkg"
            uuid = "$B_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(b, "src", "BPkg.jl"), "module BPkg end\n")

        # establish the shared manifest (members path-tracked in it)
        env_b = load_environment(b; depots)
        write_environment(env_b, plan_resolve(env_b, regs, Config(depots)))

        # resolve with member A active: B is path-tracked in the manifest,
        # but A's Project.toml gains no `[sources]` entry for it (nor for
        # itself, nor for the registry-tracked Example)
        env = load_environment(a; depots)
        planned = plan_resolve(env, regs, Config(depots))
        @test is_path_tracked(planned.manifest[B_UUID])
        write_environment(env, planned)
        @test isempty(VibePkg.EnvFiles.read_project(joinpath(a, "Project.toml")).sources)

        # same with the root active, whose deps include member A — the member
        # keeps its path tracking even though it is a dep of a sibling project
        env_root = load_environment(root; depots)
        @test is_path_tracked(env_root.manifest[A_UUID])
        write_environment(env_root, plan_resolve(env_root, regs, Config(depots)))
        @test isempty(VibePkg.EnvFiles.read_project(joinpath(root, "Project.toml")).sources)
    end
end

# A workspace member's unregistered [sources]-tracked dep must not break
# sibling resolution (path-sourced here; exercises the same claim as the
# git-sourced repro). Pkg.jl#3744
@testset "sibling resolution with unregistered member dep" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        unreg = mkpath(joinpath(dir, "UnregPkg"))
        mkpath(joinpath(unreg, "src"))
        write(
            joinpath(unreg, "Project.toml"), """
            name = "UnregPkg"
            uuid = "$UNREG_UUID"
            version = "0.1.0"
            """
        )
        write(joinpath(unreg, "src", "UnregPkg.jl"), "module UnregPkg end\n")

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["A", "B"]
            """
        )
        a = mkpath(joinpath(root, "A"))
        mkpath(joinpath(a, "src"))
        write(
            joinpath(a, "Project.toml"), """
            name = "APkg"
            uuid = "$A_UUID"
            version = "0.1.0"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(a, "src", "APkg.jl"), "module APkg end\n")
        b = mkpath(joinpath(root, "B"))
        mkpath(joinpath(b, "src"))
        write(
            joinpath(b, "Project.toml"), """
            name = "BPkg"
            uuid = "$B_UUID"
            version = "0.1.0"

            [deps]
            UnregPkg = "$UNREG_UUID"

            [sources]
            UnregPkg = {path = "../../UnregPkg"}
            """
        )
        write(joinpath(b, "src", "BPkg.jl"), "module BPkg end\n")

        # resolving from the sibling A succeeds: A's registered dep resolves
        # normally and B's unregistered dep rides along path-tracked
        env = load_environment(a; depots)
        planned = plan_resolve(env, regs, Config(depots))
        @test entry_version(planned.manifest[EXAMPLE_UUID]) isa VersionNumber
        @test is_path_tracked(planned.manifest[UNREG_UUID])
        write_environment(env, planned)
    end
end

# Pkg.jl workspaces.jl "workspace sources pointing to parent package" (#4539,
# #4575) — a child subproject whose [sources] points at its parent ({path=".."})
# resolves without an AssertionError, path-tracks the parent, and the child's
# project-relative sources path is preserved (never corrupted to ".").
@testset "subproject [sources] pointing at the parent" begin
    ROOT = UUID("aaaa0000-0000-0000-0000-000000000001")
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        root = mkpath(joinpath(dir, "RootPkg"))
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Project.toml"), "name = \"RootPkg\"\nuuid = \"$ROOT\"\nversion = \"0.1.0\"\n")
        write(joinpath(root, "src", "RootPkg.jl"), "module RootPkg end\n")

        docs = mkpath(joinpath(root, "docs"))
        write(joinpath(docs, "Project.toml"), "[deps]\nRootPkg = \"$ROOT\"\n\n[sources]\nRootPkg = {path=\"..\"}\n")

        env = load_environment(docs; depots)
        planned = plan_resolve(env, regs, Config(depots))     # must not AssertionError
        @test is_path_tracked(planned.manifest[ROOT])
        @test entry_path(planned.manifest[ROOT]) == ".."
        write_environment(env, planned)
        # the child's [sources] path stays project-relative, not rewritten to "."
        @test only(values(read_project(joinpath(docs, "Project.toml")).sources)).path == ".."
    end
end

# Two workspace projects pinning the same dep to disagreeing [sources] must
# be rejected at resolve time instead of one variant silently winning.
# Pkg.jl#4709
@testset "workspace projects with conflicting [sources]" begin
    SHARED = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")

    make_shared(dir, sub) = begin
        pkg = mkpath(joinpath(dir, sub, "SharedDep"))
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "SharedDep"
            uuid = "$SHARED"
            version = "0.1.0"
            """
        )
        write(joinpath(pkg, "src", "SharedDep.jl"), "module SharedDep end\n")
        return pkg
    end

    make_workspace(dir, source_a, source_b) = begin
        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["A", "B"]
            """
        )
        for (member, uuid, source) in (("A", A_UUID, source_a), ("B", B_UUID, source_b))
            m = mkpath(joinpath(root, member))
            mkpath(joinpath(m, "src"))
            write(
                joinpath(m, "Project.toml"), """
                name = "$(member)Pkg"
                uuid = "$uuid"
                version = "0.1.0"

                [deps]
                SharedDep = "$SHARED"

                [sources]
                SharedDep = $source
                """
            )
            write(joinpath(m, "src", "$(member)Pkg.jl"), "module $(member)Pkg end\n")
        end
        return root
    end

    # conflicting paths: resolve must throw, not silently pick variant1
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        make_shared(dir, "variant1")
        make_shared(dir, "variant2")
        root = make_workspace(
            dir,
            "{path = \"../../variant1/SharedDep\"}",
            "{path = \"../../variant2/SharedDep\"}",
        )
        env = load_environment(joinpath(root, "A"); depots)
        err = try
            plan_resolve(env, regs, Config(depots))
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("conflicting sources", err.msg)
        @test occursin("SharedDep", err.msg)
    end

    # path vs url is also a conflict
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        make_shared(dir, "variant1")
        root = make_workspace(
            dir,
            "{path = \"../../variant1/SharedDep\"}",
            "{url = \"https://example.com/SharedDep.jl.git\"}",
        )
        env = load_environment(joinpath(root, "A"); depots)
        err = try
            plan_resolve(env, regs, Config(depots))
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("conflicting sources", err.msg)
    end

    # control: agreeing sources (same location, spelled from each member's
    # own project — rebasing makes them comparable) still resolve
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        make_shared(dir, "variant1")
        root = make_workspace(
            dir,
            "{path = \"../../variant1/SharedDep\"}",
            "{path = \"../../variant1/SharedDep\"}",
        )
        env = load_environment(joinpath(root, "A"); depots)
        planned = plan_resolve(env, regs, Config(depots))
        @test is_path_tracked(planned.manifest[SHARED])
    end
end

# dependencies() and project() report only the active project's direct deps
# by default; workspace = true widens directness to every workspace project.
# Pkg.jl#4719
@testset "workspace-aware dependencies() and project()" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        make_test_registry(depot)
        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["A"]

            [deps]
            APkg = "$A_UUID"
            """
        )
        a = mkpath(joinpath(root, "A"))
        mkpath(joinpath(a, "src"))
        write(
            joinpath(a, "Project.toml"), """
            name = "APkg"
            uuid = "$A_UUID"
            version = "0.1.0"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            """
        )
        write(joinpath(a, "src", "APkg.jl"), "module APkg end\n")

        # shared manifest so dependencies() has entries to report
        env = load_environment(root; depots)
        write_environment(env, plan_resolve(env, regs, Config(depots)))

        # activate the root for the public no-arg API
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        try
            Base.ACTIVE_PROJECT[] = joinpath(root, "Project.toml")
            copy!(Base.DEPOT_PATH, [depot; Base.append_bundled_depot_path!(String[])])

            # member-only dep Example: in the shared manifest but not direct
            deps = VibePkg.dependencies()
            @test deps[A_UUID].is_direct_dep
            @test !deps[EXAMPLE_UUID].is_direct_dep
            deps_ws = VibePkg.dependencies(; workspace = true)
            @test deps_ws[A_UUID].is_direct_dep
            @test deps_ws[EXAMPLE_UUID].is_direct_dep

            proj = VibePkg.project()
            @test keys(proj.dependencies) == Set(["APkg"])
            proj_ws = VibePkg.project(; workspace = true)
            @test keys(proj_ws.dependencies) == Set(["APkg", "Example"])
            @test proj_ws.dependencies["Example"] == EXAMPLE_UUID
            # the workspace merge must not leak into a plain project() call
            @test keys(VibePkg.project().dependencies) == Set(["APkg"])
        finally
            Base.ACTIVE_PROJECT[] = old_active
            copy!(Base.DEPOT_PATH, old_depots)
        end
    end
end
