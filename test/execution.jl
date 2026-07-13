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
using VibePkg.Registries: reachable_registries, registry_name
using VibePkg.Environments
using VibePkg.Planning
using VibePkg.Planning: PackageRequest
using VibePkg.Execution
using VibePkg.TreeHash
using VibePkg.EnvFiles: entry_tree_hash
import TOML

const EXAMPLE = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

@testset "TreeHash" begin
    mktempdir() do dir
        write(joinpath(dir, "b.txt"), "hello\n")
        mkpath(joinpath(dir, "sub"))
        write(joinpath(dir, "sub", "a.txt"), "world\n")
        mkpath(joinpath(dir, "empty"))          # empty dirs are excluded
        mkpath(joinpath(dir, ".git"))           # .git is excluded
        write(joinpath(dir, ".git", "x"), "ignored")
        h1 = SHA1(tree_hash(dir))
        Base.rm(joinpath(dir, "empty"))
        Base.rm(joinpath(dir, ".git"); recursive = true)
        @test SHA1(tree_hash(dir)) == h1        # exclusions really excluded
        write(joinpath(dir, "b.txt"), "hello!\n")
        @test SHA1(tree_hash(dir)) != h1
    end
    # Pkg.jl#1469 — the empty tree hashes to git's well-known empty tree id
    mktempdir() do dir
        @test bytes2hex(tree_hash(dir)) == "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    end
    if !Sys.iswindows()
        mktempdir() do dir
            symlink("schön", joinpath(dir, "link"))
            @test bytes2hex(tree_hash(dir)) == "289b9713bf8902fbd0688b0ca5584ec4cf08fdc9"
            @test bytes2hex(tree_hash(dir; legacy_symlink_size = true)) ==
                "23b444ffcdb0f0581971360378088dbaf47c011e"
        end
        mktempdir() do dir
            symlink("plain-target", joinpath(dir, "link"))
            @test tree_hash(dir) == tree_hash(dir; legacy_symlink_size = true)
        end
    end
end

if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end

@testset "Execution (local pkg server)" begin
    LocalPkgServer.ensure!()
    mktempdir() do tmpdepot
        depots = depot_stack([tmpdepot])        # forces a real (local) download
        VibePkg.Registries.add_default_registries!(depots; io = devnull)
        real_regs = reachable_registries(depots; read_from_tarball = true)
        @test any(r -> registry_name(r) == "General", real_regs)
        begin
            mktempdir() do dir
                env = load_environment(dir; depots)
                planned = plan_add(env, real_regs, Config(depots), [PackageRequest("Example")])
                result = apply!(env, planned, real_regs, Config(depots); io = devnull)
                begin
                    @test result.wrote
                    entry = result.env.manifest[EXAMPLE]
                    hash = entry_tree_hash(entry)
                    path = joinpath(tmpdepot, "packages", "Example", Base.version_slug(EXAMPLE, hash))
                    @test length(result.installed) == 1
                    @test result.installed[1].path == path
                    @test isfile(joinpath(path, "src", "Example.jl"))
                    @test SHA1(tree_hash(path)) == hash          # verified content
                    @test isfile(joinpath(dir, "Manifest.toml"))

                    # instantiate into a second fresh depot from the written env
                    mktempdir() do tmpdepot2
                        depots2 = depot_stack([tmpdepot2])
                        env2 = load_environment(dir; depots = depots2)
                        installed = instantiate!(env2, real_regs, Config(depots2); io = devnull)
                        @test any(i -> i.uuid == EXAMPLE, installed)
                        @test isfile(joinpath(tmpdepot2, "packages", "Example", Base.version_slug(EXAMPLE, hash), "src", "Example.jl"))
                        # idempotent: second instantiate installs nothing
                        @test isempty(instantiate!(env2, real_regs, Config(depots2); io = devnull))
                    end
                end
            end
        end
    end
end

# Pkg.jl#1491 — instantiate installs the manifest's pinned version even when
# the registry has yanked it (instantiate never consults registry versions)
@testset "instantiate at a yanked version" begin
    fx = LocalPkgServer.ensure!()
    v = "0.5.5"
    hash = fx.version_hashes[v]
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        # a local registry in which the pinned version is yanked
        reg = joinpath(depot, "registries", "YankedRegistry")
        pkg = mkpath(joinpath(reg, "E", "Example"))
        write(
            joinpath(reg, "Registry.toml"), """
            name = "YankedRegistry"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://example.invalid/YankedRegistry"

            [packages]
            $EXAMPLE = { name = "Example", path = "E/Example" }
            """
        )
        open(joinpath(pkg, "Package.toml"), "w") do io
            TOML.print(
                io, Dict(
                    "name" => "Example",
                    "uuid" => string(EXAMPLE),
                    "repo" => fx.git_repo,
                )
            )
        end
        write(
            joinpath(pkg, "Versions.toml"), """
            ["$v"]
            git-tree-sha1 = "$hash"
            yanked = true
            """
        )
        regs = reachable_registries(depots)
        @test VibePkg.Registries.is_version_yanked(regs, EXAMPLE, VersionNumber(v))

        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            Example = "$EXAMPLE"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.1"

            [[deps.Example]]
            git-tree-sha1 = "$hash"
            uuid = "$EXAMPLE"
            version = "$v"
            """
        )
        env = load_environment(envdir; depots)
        installed = instantiate!(env, regs, Config(depots); io = devnull)
        @test any(i -> i.uuid == EXAMPLE, installed)
        @test isfile(joinpath(depot, "packages", "Example", Base.version_slug(EXAMPLE, SHA1(hash)), "src", "Example.jl"))
    end
end
