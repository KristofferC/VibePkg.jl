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
        # git records only the user-executable bit (mode 100755 vs 100644);
        # group/other exec bits are ignored, so they must not change the hash.
        mktempdir() do dir
            f = joinpath(dir, "script.sh")
            write(f, "#!/bin/sh\n")
            chmod(f, 0o644)
            h_plain = tree_hash(dir)
            chmod(f, 0o755)                     # user-exec set -> 100755
            h_exec = tree_hash(dir)
            @test h_exec != h_plain
            chmod(f, 0o744)                     # still user-exec -> same 100755
            @test tree_hash(dir) == h_exec
            chmod(f, 0o645)                     # only group/other exec -> back to 100644
            @test tree_hash(dir) == h_plain
        end
        # A `.git` *subdirectory* is excluded, so a tree with one hashes the
        # same as the identical tree without it (Foo == FooGit, Pkg.jl).
        mktempdir() do dir
            foo = mkpath(joinpath(dir, "Foo"))
            write(joinpath(foo, "a.txt"), "x\n")
            h_foo = tree_hash(foo)
            foogit = mkpath(joinpath(dir, "FooGit"))
            write(joinpath(foogit, "a.txt"), "x\n")
            mkpath(joinpath(foogit, ".git"))
            write(joinpath(foogit, ".git", "config"), "junk")
            @test tree_hash(foogit) == h_foo
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
                    # Pkg.jl#4438 — the packages cache dir is tagged for backup tools
                    @test isfile(joinpath(tmpdepot, "packages", "CACHEDIR.TAG"))

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

# Pkg.jl new.jl "Issue #2931" — a registry-tracked manifest entry that records
# a tree hash but no version still resolves and materializes; after its install
# directory is deleted, a re-instantiate downloads it again.
@testset "instantiate a versionless entry and re-download (#2931)" begin
    fx = LocalPkgServer.ensure!()
    h = fx.version_hashes["0.5.5"]
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        VibePkg.Registries.add_default_registries!(depots; io = devnull)
        regs = reachable_registries(depots; read_from_tarball = true)
        envdir = mkpath(joinpath(dir, "env"))
        write(joinpath(envdir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE\"\n")
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.0"

            [[deps.Example]]
            uuid = "$EXAMPLE"
            git-tree-sha1 = "$h"
            """
        )
        env = load_environment(envdir; depots)
        pkgdir = joinpath(depot, "packages", "Example", Base.version_slug(EXAMPLE, SHA1(h)))

        @test any(i -> i.uuid == EXAMPLE, instantiate!(env, regs, Config(depots); io = devnull))
        @test isfile(joinpath(pkgdir, "src", "Example.jl"))

        # delete the install dir → a fresh instantiate re-materializes it
        Base.rm(pkgdir; recursive = true, force = true)
        @test any(i -> i.uuid == EXAMPLE, instantiate!(env, regs, Config(depots); io = devnull))
        @test isfile(joinpath(pkgdir, "src", "Example.jl"))
    end
end

if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

# Regression: pkg_may_have_extensions must be conservative — it may return
# false only when a registry that knows the exact version affirmatively
# records no weakdeps for it. Otherwise (package or version unknown to every
# registry) selective instantiate could skip a real extension provider.
@testset "pkg_may_have_extensions is conservative" begin
    mktempdir() do depot
        make_test_registry(depot)   # Example: 0.5.0, 0.5.1, 1.0.0; WeakDeps for "1"
        regs = reachable_registries(depot_stack([depot]))
        may = VibePkg.Execution.pkg_may_have_extensions
        # registry records weakdeps covering 1.0.0
        @test may(regs, EXAMPLE_UUID, v"1.0.0")
        # registry knows 0.5.0 and no weakdeps range covers it
        @test !may(regs, EXAMPLE_UUID, v"0.5.0")
        # version unknown to every registry → nothing rules extensions out
        @test may(regs, EXAMPLE_UUID, v"0.6.0")
        # package unknown to every registry → nothing rules extensions out
        @test may(regs, UUID("deadbeef-dead-beef-dead-beefdeadbeef"), v"1.0.0")
        # non-concrete version → always possible
        @test may(regs, EXAMPLE_UUID, nothing)
        # no registries at all → nothing rules extensions out
        @test may(VibePkg.Registries.RegistryInstance[], EXAMPLE_UUID, v"1.0.0")
    end
end

# bytes2hex helper mirroring Pkg.jl's `tree_hash` wrapper (new.jl:3517)
th(root::AbstractString; kwargs...) = bytes2hex(tree_hash(root; kwargs...))

@testset "git tree hash computation (parity)" begin
    # Pkg.jl test/new.jl "git tree hash computation" (line 3519)
    # -- executable-bit sensitivity matrix (new.jl:3531-3537) --------------
    # Only git's user-exec bit (100755) affects the hash; group/other-exec
    # bits do not. Hashes are git's actual command-line output.
    mktempdir() do dir
        file = joinpath(dir, "hello.txt")
        open(file, write = true) do io
            println(io, "Hello, world.")
        end
        chmod(file, 0o644)
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == th(dir)
        chmod(file, 0o645)  # other-x bit doesn't matter
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == th(dir)
        chmod(file, 0o654)  # group-x bit doesn't matter
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == th(dir)
        chmod(file, 0o744)  # user-x bit matters
        @test "952cfce0fb589c02736482fa75f9f9bb492242f8" == th(dir)
    end

    # -- Foo vs FooGit: a .git subdirectory is excluded (new.jl:3557-3571) --
    mktempdir() do dir
        mkdir(joinpath(dir, "Foo"))
        mkdir(joinpath(dir, "FooGit"))
        mkdir(joinpath(dir, "FooGit", ".git"))
        write(joinpath(dir, "Foo", "foo"), "foo")
        chmod(joinpath(dir, "Foo", "foo"), 0o644)
        write(joinpath(dir, "FooGit", "foo"), "foo")
        chmod(joinpath(dir, "FooGit", "foo"), 0o644)
        write(joinpath(dir, "FooGit", ".git", "foo"), "foo")
        chmod(joinpath(dir, "FooGit", ".git", "foo"), 0o644)
        @test th(joinpath(dir, "Foo")) ==
            th(joinpath(dir, "FooGit")) ==
            "2f42e2c1c1afd4ef8c66a2aaba5d5e1baddcab33"
    end

    # -- symlink whose name is a prefix of a sibling dir (new.jl:3573-3583) --
    # "5.28" (symlink) must sort AFTER "5.28.1/" the way git sorts entries
    # (directories compared as "name/"), so the tree hash matches git's.
    if !Sys.iswindows()
        mktempdir() do dir
            mkdir(joinpath(dir, "5.28.1"))
            write(joinpath(dir, "5.28.1", "foo"), "")
            chmod(joinpath(dir, "5.28.1", "foo"), 0o644)
            symlink("5.28.1", joinpath(dir, "5.28"))
            @test th(dir) == "5e50a4254773a7c689bebca79e2954630cab9c04"
        end
    end
end
