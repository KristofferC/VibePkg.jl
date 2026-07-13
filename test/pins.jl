# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

# Pinned-string diagnostics:
# suggestions, wrong-UUID quartet, path messages, repo field, yanked
# marker/legend, outdated details, all-pinned up, readonly, compat family,
# extension tree, status --diff.
using Test
using Base: UUID
using LibGit2
using VibePkg
using VibePkg.Configs: Config
using VibePkg: Display, Planning, Environments, Depots, Registries
using VibePkg.Display: print_status, print_compat
using VibePkg.Errors: PkgError

const PIN_EX = "7876af07-990d-54b4-ab0e-23690620f79a"

pin_msg(f) = try
    f(); "NO ERROR"
catch e
    e isa PkgError ? e.msg : rethrow()
end

function pin_registry(depot; yank_051::Bool = false)
    reg = joinpath(depot, "registries", "TestRegistry")
    pkg = joinpath(reg, "E", "Example")
    mkpath(pkg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "TestRegistry"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "https://example.com/TestRegistry.git"

        [packages]
        $PIN_EX = { name = "Example", path = "E/Example" }
        """
    )
    write(
        joinpath(pkg, "Package.toml"), """
        name = "Example"
        uuid = "$PIN_EX"
        repo = "https://example.com/Example.jl.git"
        """
    )
    return write(
        joinpath(pkg, "Versions.toml"), """
        ["0.5.0"]
        git-tree-sha1 = "1111111111111111111111111111111111111111"

        ["0.5.1"]
        git-tree-sha1 = "2222222222222222222222222222222222222222"
        $(yank_051 ? "yanked = true" : "")
        """
    )
end

function pin_env(dir; version = "0.5.0", compat = nothing, pinned = false)
    write(
        joinpath(dir, "Project.toml"), """
        [deps]
        Example = "$PIN_EX"
        $(compat === nothing ? "" : "[compat]\nExample = \"$compat\"")
        """
    )
    write(
        joinpath(dir, "Manifest.toml"), """
        julia_version = "1.12.6"
        manifest_format = "2.0"
        project_hash = "1111111111111111111111111111111111111111"

        [[deps.Example]]
        git-tree-sha1 = "1111111111111111111111111111111111111111"
        uuid = "$PIN_EX"
        version = "$version"
        $(pinned ? "pinned = true" : "")
        """
    )
    return joinpath(dir, "Project.toml")
end

@testset "pinned diagnostics (round 3)" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        pin_registry(depot)
        depots = Depots.depot_stack([depot])
        regs = Registries.reachable_registries(depots)
        pf = pin_env(mkpath(joinpath(dir, "env")))
        env = Environments.load_environment_from(pf; depots)

        # unresolved-name suggestions
        m = pin_msg(() -> Planning.resolve_request(env, regs, Planning.PackageRequest("Examplle")))
        @test occursin("The following package names could not be resolved:", m)
        @test occursin("* Examplle (not found in project, manifest or registry)", m)
        @test occursin("Suggestions:", m) && occursin("Example", m)

        # wrong-UUID quartet
        m = pin_msg(() -> Planning.check_registered(env, regs, "Example", UUID("00000000-0000-0000-0000-000000000001")))
        @test occursin("expected package `Example [00000000]` to be registered", m)
        @test occursin("You may have provided the wrong UUID for package Example.", m)
        @test occursin("Found the following UUIDs for that name:", m)
        @test occursin("- $PIN_EX from registry: TestRegistry", m)

        # path/dev-path messages
        missing_path = joinpath(dir, "definitely", "not", "a", "path")
        @test pin_msg(() -> VibePkg.add(path = missing_path)) ==
            "Path `$missing_path` does not exist."
        m = pin_msg(() -> Planning.plan_develop(env, regs, Config(depots), joinpath(dir, "nope")))
        @test m == "Dev path `$(joinpath(dir, "nope"))` does not exist."
        f = joinpath(dir, "afile"); write(f, "x")
        m = pin_msg(() -> Planning.plan_develop(env, regs, Config(depots), f))
        @test m == "Dev path `$f` is a file, but a directory is required."

        # repo is a private field
        @test pin_msg(() -> PackageSpec(repo = "https://x.com/y.git")) ==
            "`repo` is a private field of PackageSpec and should not be set directly"
    end
end

@testset "status pins (round 3)" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        pin_registry(depot; yank_051 = true)
        depots = Depots.depot_stack([depot])
        regs = Registries.reachable_registries(depots)

        # [yanked] marker + legend (env AT the yanked version)
        pf = pin_env(mkpath(joinpath(dir, "y")); version = "0.5.1")
        env = Environments.load_environment_from(pf; depots)
        out = sprint(io -> print_status(io, env; registries = regs))
        @test occursin("[yanked]", out)
        @test occursin("Package versions marked with [yanked] have been pulled from their registry. It is recommended to update them to resolve a valid version.", out)

        # --outdated details: held back by project compat
        depot2 = mkpath(joinpath(dir, "depot2"))
        pin_registry(depot2)
        depots2 = Depots.depot_stack([depot2])
        regs2 = Registries.reachable_registries(depots2)
        pf = pin_env(mkpath(joinpath(dir, "o")); compat = "=0.5.0")
        env = Environments.load_environment_from(pf; depots = depots2)
        out = sprint(io -> print_status(io, env; registries = regs2, outdated = true))
        @test occursin("(<v0.5.1)", out) && occursin("[compat]", out)

        # all-pinned up short-circuit
        pf = pin_env(mkpath(joinpath(dir, "p")); pinned = true)
        old = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = pf
        try
            buf = IOBuffer()
            VibePkg.up(io = buf)
            @test occursin("All dependencies are pinned - nothing to update.", String(take!(buf)))
        finally
            Base.ACTIVE_PROJECT[] = old
        end

        # (readonly) header
        rdir = mkpath(joinpath(dir, "r"))
        write(joinpath(rdir, "Project.toml"), "readonly = true\n\n[deps]\nExample = \"$PIN_EX\"\n")
        env = Environments.load_environment_from(joinpath(rdir, "Project.toml"); depots)
        @test occursin("(readonly)", sprint(io -> print_status(io, env)))
    end
end

@testset "compat pins" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        pin_registry(depot)
        pf = pin_env(dir)
        old_active = Base.ACTIVE_PROJECT[]
        old_depot = copy(Base.DEPOT_PATH)
        Base.ACTIVE_PROJECT[] = pf
        pushfirst!(Base.DEPOT_PATH, depot)
        try
            withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_OFFLINE" => "true") do
                # view
                depots = Depots.depot_stack()
                env = Environments.load_environment_from(pf; depots)
                out = sprint(io -> print_compat(io, env))
                @test occursin("Compat `", out)
                @test occursin(Regex("julia\\s+none"), out)
                @test occursin(Regex("\\[7876af07\\] Example\\s+none"), out)

                # --current messages
                buf = IOBuffer()
                VibePkg.compat(current = true, io = buf)
                @test occursin("new entries set for Example and julia based on their current versions", String(take!(buf)))
                buf = IOBuffer()
                VibePkg.compat(current = true, io = buf)
                @test occursin("no missing compat entries found. No changes made.", String(take!(buf)))

                # set → conflict keeps entry with Error + Suggestion; remove
                buf = IOBuffer()
                VibePkg.compat("Example", "=0.4.0"; io = buf)
                out = String(take!(buf))
                @test occursin("Compat entry set:\n  Example = \"=0.4.0\"", out)
                @test occursin("checking for compliance with the new compat rules...", out)
                @test occursin("Call `update` to attempt to meet the compatibility requirements.", out)
                @test VibePkg.EnvFiles.read_project(pf).compat["Example"].str == "=0.4.0"
                buf = IOBuffer()
                VibePkg.compat("Example"; io = buf)
                @test occursin("Compat entry removed:\n  Example = \"=0.4.0\"", String(take!(buf)))
                @test !haskey(VibePkg.EnvFiles.read_project(pf).compat, "Example")
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depot)
        end
    end
end

@testset "extension tree pin" begin
    mktempdir() do dir
        write(joinpath(dir, "Project.toml"), "[deps]\nExample = \"$PIN_EX\"\n")
        write(
            joinpath(dir, "Manifest.toml"), """
            julia_version = "1.12.6"
            manifest_format = "2.0"
            project_hash = "1111111111111111111111111111111111111111"

            [[deps.Example]]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            uuid = "$PIN_EX"
            version = "0.5.0"

                [deps.Example.weakdeps]
                WeakThing = "11111111-2222-3333-4444-555555555555"

                [deps.Example.extensions]
                ExampleWeakExt = "WeakThing"
            """
        )
        env = Environments.load_environment_from(joinpath(dir, "Project.toml"); depots = Depots.depot_stack())
        out = sprint(io -> print_status(io, env; extensions = true))
        @test occursin("└─ ExampleWeakExt [WeakThing]", out)
        @test !occursin("└─", sprint(io -> print_status(io, env)))
    end
end

@testset "status line format pin" begin
    mktempdir() do dir
        # Example is a direct dep; Indirect only reachable through Example
        write(joinpath(dir, "Project.toml"), "[deps]\nExample = \"$PIN_EX\"\n")
        write(
            joinpath(dir, "Manifest.toml"), """
            julia_version = "1.12.6"
            manifest_format = "2.0"
            project_hash = "1111111111111111111111111111111111111111"

            [[deps.Example]]
            deps = ["Indirect"]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            uuid = "$PIN_EX"
            version = "0.5.0"

            [[deps.Indirect]]
            git-tree-sha1 = "2222222222222222222222222222222222222222"
            uuid = "99999999-8888-7777-6666-555555555555"
            version = "1.2.3"
            """
        )
        env = Environments.load_environment_from(joinpath(dir, "Project.toml"); depots = Depots.depot_stack())

        # documented line format: `[<short-uuid>] <Name> v<version>`
        out = sprint(io -> print_status(io, env))
        @test occursin("[7876af07] Example v0.5.0", out)
        @test occursin(r"\[[0-9a-f]{8}\] Example v0\.5\.0", out)
        @test !occursin("Indirect", out)                 # project mode: direct only

        out = sprint(io -> print_status(io, env; manifest_mode = true))
        @test occursin("[7876af07] Example v0.5.0", out)
        @test occursin("[99999999] Indirect v1.2.3", out)  # manifest mode: indirect too
    end
end

@testset "compat status mode pins" begin
    @test pin_msg(() -> VibePkg.status(compat = true, diff = true)) ==
        "Compat status has no `diff` mode"
    @test pin_msg(() -> VibePkg.status(compat = true, outdated = true)) ==
        "Compat status has no `outdated` mode"
    @test pin_msg(() -> VibePkg.status(compat = true, deprecated = true)) ==
        "Compat status has no `deprecated` mode"
    @test pin_msg(() -> VibePkg.status(compat = true, extensions = true)) ==
        "Compat status has no `extensions` mode"
end

@testset "status --diff pin" begin
    mktempdir() do dir
        pf = pin_env(dir)
        repo = LibGit2.init(dir)
        LibGit2.add!(repo, "Project.toml", "Manifest.toml")
        sig = LibGit2.Signature("t", "t@t.t")
        LibGit2.commit(repo, "init"; author = sig, committer = sig)
        old = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = pf
        try
            buf = IOBuffer()
            VibePkg.status(diff = true, io = buf)
            @test occursin("No Matches in diff for `", String(take!(buf)))
            pin_env(dir; version = "0.5.1")
            buf = IOBuffer()
            VibePkg.status(diff = true, io = buf)
            out = String(take!(buf))
            @test occursin("Diff `", out)
            @test occursin("↑ Example v0.5.0 ⇒ v0.5.1", out)
            # Pkg.jl#1180: corrupt manifest at HEAD warns and falls back to plain status
            write(joinpath(dir, "Manifest.toml"), "not toml [")
            LibGit2.add!(repo, "Manifest.toml")
            LibGit2.commit(repo, "corrupt manifest"; author = sig, committer = sig)
            pin_env(dir; version = "0.5.1")   # readable working tree again
            buf = IOBuffer()
            @test_logs (:warn, "could not read project from HEAD, displaying absolute status instead.") VibePkg.status(diff = true, io = buf)
            @test occursin("Status `", String(take!(buf)))
            # non-git project warns and falls back
            mktempdir() do d2
                write(joinpath(d2, "Project.toml"), "")
                Base.ACTIVE_PROJECT[] = joinpath(d2, "Project.toml")
                buf = IOBuffer()
                @test_logs (:warn, "diff option only available for environments in git repositories, ignoring.") VibePkg.status(diff = true, io = buf)
                @test occursin("(empty project)", String(take!(buf)))
            end
        finally
            Base.ACTIVE_PROJECT[] = old
        end
    end
end
