# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using LibGit2
using Base: UUID
using VibePkg.Depots: depot_stack
using VibePkg.Configs: Config
using VibePkg.Registries: RegistryInstance, reachable_registries
using VibePkg.Planning: PackageRequest
using VibePkg.AppsOps
using VibePkg.EnvFiles: read_manifest, entry_version, entry_path, is_path_tracked
using VibePkg.Errors: PkgError
import TOML

const APP_UUID = UUID("abcdabcd-abcd-abcd-abcd-abcdabcdabcd")
const SUBAPP_UUID = UUID("aaaabbbb-cccc-dddd-eeee-ffffaaaabbbb")
const DEP_UUID = UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")

# The first run of a shim precompiles its app environment, printing progress
# to the subprocess' stderr; capture both streams so the noise stays out of
# the test log, surfacing them only when the shim fails. Shims are `.bat`
# scripts on Windows (run through `cmd /c`) and `sh` scripts elsewhere.
function run_shim(shim::String, args::String...)
    cmd = Sys.iswindows() ? `cmd /c $shim $args` : `sh $shim $args`
    buf = IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = buf, stderr = buf))
    output = String(take!(buf))
    success(p) || error("shim run failed ($cmd):\n$output")
    return output
end

# The registry fixture must record the hash of the tree git committed, as a
# real registry does. Re-hashing the worktree is not equivalent on Windows,
# where the ACL-derived executable bits can differ from the modes in the
# committed tree (same reasoning as `git_tree_hash` in test/git.jl).
function commit_tree_hash(repo::LibGit2.GitRepo, commit::LibGit2.GitHash)
    return LibGit2.with(LibGit2.GitCommit(repo, commit)) do c
        LibGit2.with(LibGit2.peel(LibGit2.GitTree, c)) do tree
            string(LibGit2.GitHash(tree))
        end
    end
end

function write_app_package_toml(path::String, name::String, uuid::UUID, repo::String)
    return open(path, "w") do io
        TOML.print(
            io, Dict(
                "name" => name,
                "uuid" => string(uuid),
                "repo" => repo,
            )
        )
    end
end

@testset "apps" begin
    mktempdir() do dir
        pkg = joinpath(dir, "AppPkg")
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "AppPkg"
            uuid = "$APP_UUID"
            version = "0.1.0"

            [apps]
            hello = {}
            """
        )
        write(
            joinpath(pkg, "src", "AppPkg.jl"), """
            module AppPkg
            function (@main)(args)
                println("app says: ", join(args, "+"))
                return 0
            end
            end
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])

        AppsOps.app_develop(Config(depots), RegistryInstance[], pkg; io = devnull)
        shim = AppsOps.shim_path(depots, "hello")
        @test isfile(shim)
        # executable (meaningless on Windows, where the .bat extension decides)
        Sys.iswindows() || @test !iszero(filemode(shim) & 0o100)

        manifest = read_manifest(AppsOps.app_manifest_file(depots))
        entry = manifest[APP_UUID]
        @test haskey(entry.apps, "hello")
        @test entry.apps["hello"].submodule == "AppPkg"

        # the shim actually runs the app entry point
        out = run_shim(shim, "a", "b")
        @test occursin("app says: a+b", out)

        # `--` splits julia args from app args; `--` itself never reaches the app
        out = run_shim(shim, "--threads=2", "--", "a", "b")
        @test occursin("app says: a+b", out)

        # the windows flavor renders a .bat with the same protocol
        bat = AppsOps.shim_contents(
            entry.apps["hello"], depot, "environments/apps/AppPkg";
            relative_load_path = true, windows = true,
        )
        @test startswith(bat, "@echo off")
        @test occursin("set \"JULIA_LOAD_PATH=%depot%\\environments\\apps\\AppPkg\"", bat)
        @test occursin("-m \"AppPkg\"", bat)
        @test occursin(":__next", bat) && occursin(":__done", bat)

        # status lists it; rm removes shim + entry
        @test occursin("hello", sprint(io -> AppsOps.app_status(depots; io)))
        # a filtered status matches package names and app names, and hides
        # everything else
        @test occursin("hello", sprint(io -> AppsOps.app_status(depots, ["AppPkg"]; io)))
        @test occursin("hello", sprint(io -> AppsOps.app_status(depots, ["hello"]; io)))
        @test !occursin("hello", sprint(io -> AppsOps.app_status(depots, ["NoSuchApp"]; io)))

        # `app update` of a path-tracked app re-resolves in place and
        # rewrites the shim
        Base.rm(shim)
        AppsOps.app_update(Config(depots), RegistryInstance[]; io = devnull)
        @test isfile(shim)
        @test occursin("app says: a+b", run_shim(shim, "a", "b"))

        AppsOps.app_rm(depots, "AppPkg"; io = devnull)
        @test !isfile(shim)
        @test isempty(read_manifest(AppsOps.app_manifest_file(depots)))
        @test_throws PkgError AppsOps.app_rm(depots, "AppPkg"; io = devnull)
    end
end

# Pkg.jl apps.jl "relocated depot keeps working" — the shim derives its depot
# from its own location (`$DEPOT` = SCRIPT_DIR/..), so moving the whole depot
# to a new path and running the relocated shim still works.
@testset "apps: relocated depot keeps working" begin
    Sys.iswindows() && return @test_skip "app shim end-to-end run not exercised on Windows"
    mktempdir() do dir
        pkg = joinpath(dir, "RelocPkg")
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "RelocPkg"
            uuid = "$APP_UUID"
            version = "0.1.0"

            [apps]
            reloc = {}
            """
        )
        write(
            joinpath(pkg, "src", "RelocPkg.jl"), """
            module RelocPkg
            function (@main)(args)
                println("reloc says: ", join(args, "+"))
                return 0
            end
            end
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        AppsOps.app_develop(Config(depots), RegistryInstance[], pkg; io = devnull)
        shim = joinpath(depot, "bin", "reloc")
        @test occursin("reloc says: x+y", run_shim(shim, "x", "y"))

        # move the entire depot elsewhere and run the relocated shim
        newdepot = joinpath(dir, "moved-depot")
        mv(depot, newdepot)
        newshim = joinpath(newdepot, "bin", "reloc")
        @test isfile(newshim)
        @test occursin("reloc says: x+y", run_shim(newshim, "x", "y"))
    end
end

# `app_add` of a registered package: registry + local git repo fixture, no
# pkg server (JULIA_PKG_SERVER="" forces the git-clone install fallback)
@testset "apps: add by registry name" begin
    mktempdir() do dir
        # the app package: two registered versions in a local git repo
        pkg = joinpath(dir, "AppPkg.jl")
        repo = LibGit2.init(mkpath(pkg))
        sig = LibGit2.Signature("fixture", "fixture@localhost")
        hashes = Dict{String, String}()
        for v in ("1.2.3", "2.0.0")
            mkpath(joinpath(pkg, "src"))
            write(
                joinpath(pkg, "Project.toml"), """
                name = "AppPkg"
                uuid = "$APP_UUID"
                version = "$v"

                [apps]
                hello = {}
                """
            )
            write(
                joinpath(pkg, "src", "AppPkg.jl"), """
                module AppPkg
                function (@main)(args)
                    println("app v$v says: ", join(args, "+"))
                    return 0
                end
                end
                """
            )
            LibGit2.add!(repo, "Project.toml", "src/AppPkg.jl")
            commit = LibGit2.commit(repo, "AppPkg v$v"; author = sig, committer = sig)
            hashes[v] = commit_tree_hash(repo, commit)
        end
        close(repo)

        depot = mkpath(joinpath(dir, "depot"))
        reg_pkg = mkpath(joinpath(depot, "registries", "TestRegistry", "A", "AppPkg"))
        write(
            joinpath(depot, "registries", "TestRegistry", "Registry.toml"), """
            name = "TestRegistry"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.invalid/TestRegistry.git"

            [packages]
            $APP_UUID = { name = "AppPkg", path = "A/AppPkg" }
            """
        )
        write_app_package_toml(joinpath(reg_pkg, "Package.toml"), "AppPkg", APP_UUID, pkg)
        write(
            joinpath(reg_pkg, "Versions.toml"), """
            ["1.2.3"]
            git-tree-sha1 = "$(hashes["1.2.3"])"

            ["2.0.0"]
            git-tree-sha1 = "$(hashes["2.0.0"])"
            """
        )

        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        shim = AppsOps.shim_path(depots, "hello")
        installed_version() = entry_version(read_manifest(AppsOps.app_manifest_file(depots))[APP_UUID])

        withenv("JULIA_PKG_SERVER" => "") do
            # by name: resolves to the latest version
            AppsOps.app_add(Config(depots), regs, PackageRequest("AppPkg"); io = devnull)
            @test installed_version() == v"2.0.0"
            @test occursin("app v2.0.0 says: a+b", run_shim(shim, "a", "b"))

            # an explicit version is honored
            AppsOps.app_rm(depots, "AppPkg"; io = devnull)
            AppsOps.app_add(Config(depots), regs, PackageRequest("AppPkg", nothing, "1.2.3"); io = devnull)
            @test installed_version() == v"1.2.3"
            @test occursin("app v1.2.3 says: a+b", run_shim(shim, "a", "b"))

            # `app update` moves a registry-tracked app to the latest version
            AppsOps.app_update(Config(depots), regs; io = devnull)
            @test installed_version() == v"2.0.0"
            @test occursin("app v2.0.0 says: a+b", run_shim(shim, "a", "b"))
            # updating an unknown name errors
            @test_throws PkgError AppsOps.app_update(Config(depots), regs, "NoSuchApp"; io = devnull)

            # a uuid-only request lands in the named environment directory,
            # where the shim load path points
            AppsOps.app_rm(depots, "AppPkg"; io = devnull)
            AppsOps.app_add(Config(depots), regs, PackageRequest(nothing, APP_UUID, nothing); io = devnull)
            @test isdir(joinpath(depot, "environments", "apps", "AppPkg"))
            @test !isdir(joinpath(depot, "environments", "apps", string(APP_UUID)))
            @test occursin("app v2.0.0 says: x", run_shim(shim, "x"))

            # A failed update is prepared in a staging environment and must
            # not delete the last working installation.
            env_dir = joinpath(depot, "environments", "apps", "AppPkg")
            project_before = read(joinpath(env_dir, "Project.toml"), String)
            manifest_before = read(joinpath(env_dir, "Manifest.toml"), String)
            open(joinpath(reg_pkg, "Versions.toml"), "a") do io
                print(
                    io, """

                    ["3.0.0"]
                    git-tree-sha1 = "3333333333333333333333333333333333333333"
                    """
                )
            end
            bad_regs = reachable_registries(depots)
            @test_throws ErrorException AppsOps.app_update(Config(depots), bad_regs; io = devnull)
            @test read(joinpath(env_dir, "Project.toml"), String) == project_before
            @test read(joinpath(env_dir, "Manifest.toml"), String) == manifest_before
            @test occursin("app v2.0.0 says: still-works", run_shim(shim, "still-works"))
            @test !any(startswith(".install-"), readdir(joinpath(depot, "environments", "apps")))
        end
    end
end

@testset "apps: ownership and stale shims" begin
    mktempdir() do dir
        function make_app(path, name, uuid, app_name, message)
            mkpath(joinpath(path, "src"))
            write(
                joinpath(path, "Project.toml"), """
                name = "$name"
                uuid = "$uuid"
                version = "0.1.0"

                [apps]
                $app_name = {}
                """
            )
            write(
                joinpath(path, "src", "$name.jl"), """
                module $name
                function (@main)(args)
                    println("$message")
                    return 0
                end
                end
                """
            )
        end

        first_pkg = joinpath(dir, "FirstApp")
        second_pkg = joinpath(dir, "SecondApp")
        make_app(first_pkg, "FirstApp", APP_UUID, "shared", "first owner")
        make_app(second_pkg, "SecondApp", SUBAPP_UUID, "shared", "second owner")

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        config = Config(depots)
        AppsOps.app_develop(config, RegistryInstance[], first_pkg; io = devnull)
        shim = AppsOps.shim_path(depots, "shared")
        manifest_before = read(AppsOps.app_manifest_file(depots), String)
        shim_before = read(shim, String)

        err = try
            AppsOps.app_develop(config, RegistryInstance[], second_pkg; io = devnull)
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("already installed by package `FirstApp`", err.msg)
        @test read(AppsOps.app_manifest_file(depots), String) == manifest_before
        @test read(shim, String) == shim_before
        @test occursin("first owner", run_shim(shim))

        # Replacing a package's app set removes shims it no longer owns.
        project_file = joinpath(first_pkg, "Project.toml")
        write(project_file, replace(read(project_file, String), "shared = {}" => "renamed = {}"))
        AppsOps.app_develop(config, RegistryInstance[], first_pkg; io = devnull)
        @test !isfile(shim)
        @test isfile(AppsOps.shim_path(depots, "renamed"))
    end
end

# per-app `submodule` and `julia_flags` entries, plus the
# `JULIA_APPS_JULIA_CMD` executable override honored by the shims
@testset "apps: submodule, julia_flags, julia cmd override" begin
    mktempdir() do dir
        pkg = joinpath(dir, "SubApp")
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "SubApp"
            uuid = "$SUBAPP_UUID"
            version = "0.1.0"

            [apps]
            subcli = { submodule = "CLI" }
            nthr = { julia_flags = ["--threads=2"] }
            """
        )
        write(
            joinpath(pkg, "src", "SubApp.jl"), """
            module SubApp
            module CLI
            function (@main)(args)
                println("cli submodule says: ", join(args, ","))
                return 0
            end
            end
            function (@main)(args)
                println("nthreads: ", Threads.nthreads())
                return 0
            end
            end
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        AppsOps.app_develop(Config(depots), RegistryInstance[], pkg; io = devnull)

        # `submodule = "CLI"` resolves to the dotted entry module: the shim
        # runs `julia -m SubApp.CLI` and the submodule's `@main` answers
        entry = read_manifest(AppsOps.app_manifest_file(depots))[SUBAPP_UUID]
        @test entry.apps["subcli"].submodule == "SubApp.CLI"
        shim_sub = AppsOps.shim_path(depots, "subcli")
        @test occursin("SubApp.CLI", read(shim_sub, String))
        @test occursin("cli submodule says: x,y", run_shim(shim_sub, "x", "y"))

        # baked `julia_flags` reach the app process ...
        @test entry.apps["nthr"].julia_flags == ["--threads=2"]
        shim_thr = AppsOps.shim_path(depots, "nthr")
        @test occursin("nthreads: 2", run_shim(shim_thr))
        # ... and runtime julia args (before `--`) land after the baked
        # flags on the command line, so a repeated flag is overridden
        # (cmd.exe splits `--threads=3` at the `=`; julia accepts the
        # resulting space-separated form too)
        @test occursin("nthreads: 3", run_shim(shim_thr, "--threads=3", "--"))

        # JULIA_APPS_JULIA_CMD replaces the recorded julia executable
        julia_exe = joinpath(Sys.BINDIR, Sys.iswindows() ? "julia.exe" : "julia")
        if Sys.iswindows()
            wrapper = joinpath(dir, "juliawrap.bat")
            write(wrapper, "@echo off\r\necho WRAPPER-MARKER\r\n\"$julia_exe\" %*\r\n")
        else
            wrapper = joinpath(dir, "juliawrap")
            write(
                wrapper, """
                #!/bin/sh
                echo "WRAPPER-MARKER"
                exec $(Base.shell_escape(julia_exe)) "\$@"
                """
            )
            chmod(wrapper, 0o755)
        end
        out = withenv("JULIA_APPS_JULIA_CMD" => wrapper) do
            run_shim(shim_sub, "a")
        end
        @test occursin("WRAPPER-MARKER", out)
        @test occursin("cli submodule says: a", out)
        # without the override the recorded executable runs, no wrapper
        @test !occursin("WRAPPER-MARKER", run_shim(shim_sub, "a"))
    end
end

# a `[sources]` entry in the app package must not confuse app installation:
# its relative path is only valid next to the original checkout, not next
# to the installed tree or the app environment  # Pkg.jl#4714
@testset "apps: add with [sources] in the app package" begin
    mktempdir() do dir
        sig = LibGit2.Signature("fixture", "fixture@localhost")
        # the dependency: registered, and a repository sibling of the app
        # package (the shape of the AutoMerge/RegistryCI setup)
        dep = joinpath(dir, "DepPkg")
        mkpath(joinpath(dep, "src"))
        write(
            joinpath(dep, "Project.toml"), """
            name = "DepPkg"
            uuid = "$DEP_UUID"
            version = "1.0.0"
            """
        )
        write(
            joinpath(dep, "src", "DepPkg.jl"), """
            module DepPkg
            greet() = "hello from dep"
            end
            """
        )
        repo = LibGit2.init(dep)
        LibGit2.add!(repo, "Project.toml", "src/DepPkg.jl")
        commit = LibGit2.commit(repo, "DepPkg v1.0.0"; author = sig, committer = sig)
        dep_hash = commit_tree_hash(repo, commit)
        close(repo)

        # the app package: depends on DepPkg with a [sources] path that only
        # resolves relative to this checkout
        pkg = joinpath(dir, "AppPkg")
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "AppPkg"
            uuid = "$APP_UUID"
            version = "1.0.0"

            [deps]
            DepPkg = "$DEP_UUID"

            [sources]
            DepPkg = {path = "../DepPkg"}

            [apps]
            hello = {}
            """
        )
        write(
            joinpath(pkg, "src", "AppPkg.jl"), """
            module AppPkg
            using DepPkg
            function (@main)(args)
                println("app says: ", DepPkg.greet())
                return 0
            end
            end
            """
        )
        repo = LibGit2.init(pkg)
        LibGit2.add!(repo, "Project.toml", "src/AppPkg.jl")
        commit = LibGit2.commit(repo, "AppPkg v1.0.0"; author = sig, committer = sig)
        pkg_hash = commit_tree_hash(repo, commit)
        close(repo)

        depot = mkpath(joinpath(dir, "depot"))
        reg = joinpath(depot, "registries", "TestRegistry")
        write(
            joinpath(mkpath(reg), "Registry.toml"), """
            name = "TestRegistry"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.invalid/TestRegistry.git"

            [packages]
            $APP_UUID = { name = "AppPkg", path = "A/AppPkg" }
            $DEP_UUID = { name = "DepPkg", path = "D/DepPkg" }
            """
        )
        reg_app = mkpath(joinpath(reg, "A", "AppPkg"))
        write_app_package_toml(joinpath(reg_app, "Package.toml"), "AppPkg", APP_UUID, pkg)
        write(
            joinpath(reg_app, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "$pkg_hash"
            """
        )
        write(
            joinpath(reg_app, "Deps.toml"), """
            ["1"]
            DepPkg = "$DEP_UUID"
            """
        )
        reg_dep = mkpath(joinpath(reg, "D", "DepPkg"))
        write_app_package_toml(joinpath(reg_dep, "Package.toml"), "DepPkg", DEP_UUID, dep)
        write(
            joinpath(reg_dep, "Versions.toml"), """
            ["1.0.0"]
            git-tree-sha1 = "$dep_hash"
            """
        )

        depots = depot_stack([depot])
        regs = reachable_registries(depots)
        withenv("JULIA_PKG_SERVER" => "") do
            AppsOps.app_add(Config(depots), regs, PackageRequest("AppPkg"); io = devnull)
        end
        shim = AppsOps.shim_path(depots, "hello")
        @test isfile(shim)
        # the dep resolved from the registry, not the dangling path
        env_manifest = read_manifest(joinpath(depot, "environments", "apps", "AppPkg", "Manifest.toml"))
        @test !is_path_tracked(env_manifest[DEP_UUID])
        @test occursin("app says: hello from dep", run_shim(shim))
    end
end

# `app dev .` from inside the package directory  # Pkg.jl#4480
@testset "apps: develop pwd" begin
    mktempdir() do dir
        pkg = joinpath(dir, "AppPkg")
        mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "AppPkg"
            uuid = "$APP_UUID"
            version = "0.1.0"

            [apps]
            hello = {}
            """
        )
        write(
            joinpath(pkg, "src", "AppPkg.jl"), """
            module AppPkg
            function (@main)(args)
                println("app says: hi")
                return 0
            end
            end
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        cd(pkg) do
            AppsOps.app_develop(Config(depots), RegistryInstance[], "."; io = devnull)
        end
        @test isfile(AppsOps.shim_path(depots, "hello"))
        entry = read_manifest(AppsOps.app_manifest_file(depots))[APP_UUID]
        recorded = entry_path(entry)
        @test isabspath(recorded)
        @test realpath(recorded) == realpath(pkg)
    end
end
