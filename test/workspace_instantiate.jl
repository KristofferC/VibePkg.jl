# Pkg.jl workspaces.jl "test resolve with tree hash" — a package whose `test`
# project is a workspace member shares the root manifest: Pkg.test resolves and
# runs the test project in place (no `test/Manifest.toml`), and re-running after
# deleting an installed test dependency reinstalls it. Uses the local pkg
# server's installable Example.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using VibePkg
import LibGit2
import TOML
using VibePkg.Depots: depot_stack
using VibePkg.Depots: find_installed
using VibePkg.EnvFiles: entry_tree_hash
using VibePkg.Registries: add_default_registries!

const EX_UUID = "7876af07-990d-54b4-ab0e-23690620f79a"
const TST_UUID = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
const ROOT_DEP_UUID = "77777777-7777-4777-8777-777777777777"

function make_root_dep_registry!(dir, depot)
    repo_dir = mkpath(joinpath(dir, "RootDep.jl"))
    mkpath(joinpath(repo_dir, "src"))
    write(
        joinpath(repo_dir, "Project.toml"), """
        name = "RootDep"
        uuid = "$ROOT_DEP_UUID"
        version = "1.0.0"
        """
    )
    write(joinpath(repo_dir, "src", "RootDep.jl"), "module RootDep end\n")
    repo = LibGit2.init(repo_dir)
    tree_hash = ""
    try
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("fixture", "fixture@localhost")
        LibGit2.commit(repo, "RootDep v1.0.0"; author = sig, committer = sig)
        obj = LibGit2.GitObject(repo, "HEAD")
        tree = LibGit2.peel(LibGit2.GitTree, obj)
        try
            tree_hash = string(LibGit2.GitHash(tree))
        finally
            close(tree)
            close(obj)
        end
    finally
        close(repo)
    end

    registry = joinpath(depot, "registries", "WorkspaceRootRegistry")
    package = mkpath(joinpath(registry, "R", "RootDep"))
    write(
        joinpath(registry, "Registry.toml"), """
        name = "WorkspaceRootRegistry"
        uuid = "55555555-5555-4555-8555-555555555555"
        repo = "https://example.invalid/WorkspaceRootRegistry.git"

        [packages]
        $ROOT_DEP_UUID = { name = "RootDep", path = "R/RootDep" }
        """
    )
    open(joinpath(package, "Package.toml"), "w") do io
        TOML.print(
            io,
            Dict("name" => "RootDep", "uuid" => ROOT_DEP_UUID, "repo" => repo_dir),
        )
    end
    write(
        joinpath(package, "Versions.toml"), """
        ["1.0.0"]
        git-tree-sha1 = "$tree_hash"
        """
    )
    return Base.SHA1(tree_hash)
end

# run `f` with `proj` active and the depot stack (incl. env, for the test
# sandbox subprocess) pointed at `depot` + bundled stdlibs, and precompilation on.
function with_ws_env(f, proj, depot)
    old = Base.ACTIVE_PROJECT[]
    olddp = copy(Base.DEPOT_PATH)
    oldgate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    stack = [depot; Base.append_bundled_depot_path!(String[])]
    sep = Sys.iswindows() ? ';' : ':'
    try
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        Base.ACTIVE_PROJECT[] = joinpath(proj, "Project.toml")
        copy!(Base.DEPOT_PATH, stack)
        return withenv(f, "JULIA_DEPOT_PATH" => join(stack, sep), "JULIA_PKG_PRECOMPILE_AUTO" => "1")
    finally
        Base.ACTIVE_PROJECT[] = old
        copy!(Base.DEPOT_PATH, olddp)
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = oldgate
    end
end

@testset "workspace test project shares the root manifest" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        add_default_registries!(depot_stack([depot]); io = devnull)   # installable Example
        ws = joinpath(dir, "WS")
        mkpath(joinpath(ws, "src"))
        mkpath(joinpath(ws, "test"))
        write(joinpath(ws, "Project.toml"), "name = \"WS\"\nuuid = \"96f64aaf-235f-491a-a76e-24269ac5efad\"\nversion = \"0.1.0\"\n\n[workspace]\nprojects = [\"test\"]\n")
        write(joinpath(ws, "src", "WS.jl"), "module WS end\n")
        write(joinpath(ws, "test", "Project.toml"), "[deps]\nExample = \"$EX_UUID\"\nTest = \"$TST_UUID\"\n")
        # Example is a test-only dep and must load from the shared workspace
        # manifest. Pkg intentionally suppresses the precompile hook when the
        # parent process uses a non-default compiled-module mode, so only pin
        # the cache assertion when that hook is available.
        precompile_assertion = Base.JLOptions().use_compiled_modules == 1 ?
            "@test Base.isprecompiled(Base.identify_package(\"Example\"))\n" : ""
        write(
            joinpath(ws, "test", "runtests.jl"),
            "using Test\n$(precompile_assertion)using Example\n@test Example.hello(\"CI\") == \"Hello, CI\"\n",
        )

        @test !isfile(joinpath(ws, "Manifest.toml"))
        @test !isfile(joinpath(ws, "test", "Manifest.toml"))

        with_ws_env(ws, depot) do
            # Pkg.test auto-resolves the shared workspace manifest — no explicit resolve
            @test VibePkg.test(io = devnull) === nothing
        end
        @test isfile(joinpath(ws, "Manifest.toml"))   # shared root manifest written
        @test !isfile(joinpath(ws, "test", "Manifest.toml"))   # members share it

        # deleting the installed test dep forces a reinstall on the next test run
        Base.rm(joinpath(depot, "packages", "Example"); recursive = true, force = true)
        with_ws_env(ws, depot) do
            @test VibePkg.test(io = devnull) === nothing
        end
        @test isdir(joinpath(depot, "packages", "Example"))   # reinstalled
    end
end

# With a resolved workspace manifest, the default instantiate scope downloads
# only the active root project's loadable closure. `workspace = true` widens
# that scope to member-only dependencies too. This is the on-disk half of
# Pkg.jl's `is_instantiated(env, false/true)` distinction.
@testset "selective workspace package installation" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        add_default_registries!(depots; io = devnull)
        root_hash = make_root_dep_registry!(dir, depot)

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["member"]

            [deps]
            RootDep = "$ROOT_DEP_UUID"
            """
        )
        member = mkpath(joinpath(root, "member"))
        write(joinpath(member, "Project.toml"), "[deps]\nExample = \"$EX_UUID\"\n")

        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            # Resolve the union first, then remove both installed trees so
            # instantiate's download scope is observable from an empty depot.
            with_ws_env(root, depot) do
                VibePkg.resolve(; io = devnull)
            end
            manifest = VibePkg.EnvFiles.read_manifest(joinpath(root, "Manifest.toml"))
            root_uuid = Base.UUID(ROOT_DEP_UUID)
            example_uuid = Base.UUID(EX_UUID)
            @test haskey(manifest, root_uuid)
            @test haskey(manifest, example_uuid)
            @test entry_tree_hash(manifest[root_uuid]) == root_hash

            Base.rm(joinpath(depot, "packages", "RootDep"); recursive = true, force = true)
            Base.rm(joinpath(depot, "packages", "Example"); recursive = true, force = true)

            with_ws_env(root, depot) do
                VibePkg.instantiate(; workspace = false, io = devnull)
            end
            _, root_installed = find_installed(
                depots, "RootDep", root_uuid, entry_tree_hash(manifest[root_uuid])
            )
            _, example_installed = find_installed(
                depots, "Example", example_uuid, entry_tree_hash(manifest[example_uuid])
            )
            @test root_installed       # active project is complete
            @test !example_installed   # workspace union is not complete

            with_ws_env(root, depot) do
                VibePkg.instantiate(; workspace = true, io = devnull)
            end
            _, root_installed = find_installed(
                depots, "RootDep", root_uuid, entry_tree_hash(manifest[root_uuid])
            )
            _, example_installed = find_installed(
                depots, "Example", example_uuid, entry_tree_hash(manifest[example_uuid])
            )
            @test root_installed
            @test example_installed
        finally
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

# Project.toml is authored input: resolve and every instantiate path must
# leave it byte-for-byte untouched — comments, formatting and non-canonical
# [sources] paths included. Pkg.jl#4713
@testset "resolve/instantiate never rewrite Project.toml" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))

        root = mkpath(joinpath(dir, "root"))
        leaf = mkpath(joinpath(root, "Leaf"))
        mkpath(joinpath(leaf, "src"))
        write(
            joinpath(leaf, "Project.toml"), """
            name = "Leaf"
            uuid = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
            version = "0.1.0"
            """
        )
        write(joinpath(leaf, "src", "Leaf.jl"), "module Leaf end\n")
        sub = mkpath(joinpath(root, "sub"))
        mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"), """
            name = "Sub"
            uuid = "ffffffff-ffff-ffff-ffff-ffffffffffff"
            version = "0.1.0"
            """
        )
        write(joinpath(sub, "src", "Sub.jl"), "module Sub end\n")

        project_file = joinpath(root, "Project.toml")
        # tripwire: a comment the lossy serializer would drop and a
        # non-canonical sources path sync_sources would rebase to "Leaf"
        authored = """
        # DO-NOT-DROP this comment
        [workspace]
        projects = ["sub"]

        [deps]
        Leaf = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        [sources]
        Leaf = {path = "./Leaf"}
        """
        write(project_file, authored)
        manifest_file = joinpath(root, "Manifest.toml")

        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            with_ws_env(root, depot) do
                VibePkg.resolve(; io = devnull)
                @test isfile(manifest_file)
                @test read(project_file, String) == authored

                VibePkg.instantiate(; io = devnull)              # manifest present
                @test read(project_file, String) == authored

                Base.rm(manifest_file)                           # no-manifest ⇒ up fallback
                VibePkg.instantiate(; io = devnull)
                @test isfile(manifest_file)
                @test read(project_file, String) == authored

                # doctor the manifest's julia_version to another minor so the
                # update_on_mismatch fallback (also via up) triggers
                doctored = replace(
                    read(manifest_file, String),
                    r"julia_version = \"[^\"]+\"" => "julia_version = \"1.0.0\"",
                )
                write(manifest_file, doctored)
                VibePkg.instantiate(; update_on_mismatch = true, io = devnull)
                @test read(project_file, String) == authored

                # the opt-out still syncs [sources] (guards the plumbing):
                # the manifest-relative rebase canonicalizes "./Leaf" to "Leaf"
                VibePkg.resolve(; skip_writing_project = false, io = devnull)
                @test read(project_file, String) != authored
                synced = VibePkg.EnvFiles.read_project(project_file)
                @test synced.sources["Leaf"].path == "Leaf"
            end
        finally
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

# Instantiating a workspace member with no manifest resolves the WHOLE
# workspace into the shared manifest, but with `workspace = false` downloads
# only the active project's loadable deps. Pkg.jl#4699
@testset "selective workspace instantiate without a manifest" begin
    LocalPkgServer.ensure!()
    PHANTOM_UUID = "99999999-9999-4999-9999-999999999999"
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        add_default_registries!(depot_stack([depot]); io = devnull)   # installable Example
        # extra local registry with a root-only package that CANNOT be
        # downloaded (bogus tree hash): if the selective filter is broken,
        # instantiate fails loudly trying to fetch it
        reg = joinpath(depot, "registries", "PhantomReg")
        pkg = joinpath(reg, "P", "Phantom")
        mkpath(pkg)
        write(
            joinpath(reg, "Registry.toml"), """
            name = "PhantomReg"
            uuid = "44449594-aafe-5451-b93e-139f81909106"
            repo = "https://example.com/PhantomReg.git"

            [packages]
            $PHANTOM_UUID = { name = "Phantom", path = "P/Phantom" }
            """
        )
        write(
            joinpath(pkg, "Package.toml"), """
            name = "Phantom"
            uuid = "$PHANTOM_UUID"
            repo = "https://example.com/Phantom.jl.git"
            """
        )
        write(
            joinpath(pkg, "Versions.toml"), """
            ["0.1.0"]
            git-tree-sha1 = "9999999999999999999999999999999999999999"
            """
        )

        root = mkpath(joinpath(dir, "root"))
        write(
            joinpath(root, "Project.toml"), """
            [workspace]
            projects = ["sub"]

            [deps]
            Phantom = "$PHANTOM_UUID"
            """
        )
        sub = mkpath(joinpath(root, "sub"))
        write(joinpath(sub, "Project.toml"), "[deps]\nExample = \"$EX_UUID\"\n")

        @test !isfile(joinpath(root, "Manifest.toml"))
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            with_ws_env(sub, depot) do            # activate the MEMBER
                VibePkg.instantiate(; workspace = false, io = devnull)
            end
        finally
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end

        # member's loadable dep installed; root-only dep NOT downloaded
        @test isdir(joinpath(depot, "packages", "Example"))
        @test !isdir(joinpath(depot, "packages", "Phantom"))
        # but the shared manifest is fully resolved for the whole workspace
        m = VibePkg.EnvFiles.read_manifest(joinpath(root, "Manifest.toml"))
        @test haskey(m, Base.UUID(EX_UUID))
        @test haskey(m, Base.UUID(PHANTOM_UUID))
    end
end
