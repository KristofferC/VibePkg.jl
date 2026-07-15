# Pkg.jl subdir.jl "registry-resolved subdir add/develop".  The fixture is a
# fully local Git monorepo plus an unpacked synthetic registry: `Package`
# lives under `julia/`, depends on the sibling `Dep` under
# `dependencies/Dep`, and neither repository nor registry needs the network.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: SHA1, UUID
import LibGit2
import TOML
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack, find_installed
using VibePkg.Registries: reachable_registries, registry_info
using VibePkg.Environments: load_environment
using VibePkg.Planning: plan_add, PackageRequest
using VibePkg.Execution: apply!
using VibePkg.EnvFiles: entry_path, entry_repo_subdir, entry_tree_hash,
    entry_version, is_path_tracked, is_registry_tracked, is_repo_tracked

const SUBREG_PACKAGE_UUID = UUID("408b23ff-74ea-48c4-abc7-a671b41e2073")
const SUBREG_DEP_UUID = UUID("d43cb7ef-9818-40d3-bb27-28fb4aa46cc5")

function subreg_tree_hash(repo::LibGit2.GitRepo, spec::String)
    obj = LibGit2.GitObject(repo, spec)
    try
        return SHA1(string(LibGit2.GitHash(obj)))
    finally
        close(obj)
    end
end

function make_subdir_registry_fixture(dir::String)
    repo_path = mkpath(joinpath(dir, "Mono"))
    package_path = mkpath(joinpath(repo_path, "julia", "src"))
    dep_path = mkpath(joinpath(repo_path, "dependencies", "Dep", "src"))
    write(
        joinpath(repo_path, "julia", "Project.toml"), """
        name = "Package"
        uuid = "$SUBREG_PACKAGE_UUID"
        version = "1.0.0"

        [deps]
        Dep = "$SUBREG_DEP_UUID"
        """
    )
    write(joinpath(package_path, "Package.jl"), "module Package\nusing Dep\nend\n")
    write(
        joinpath(repo_path, "dependencies", "Dep", "Project.toml"), """
        name = "Dep"
        uuid = "$SUBREG_DEP_UUID"
        version = "1.0.0"
        """
    )
    write(joinpath(dep_path, "Dep.jl"), "module Dep end\n")
    write(joinpath(repo_path, "README.md"), "repository root only\n")

    repo = LibGit2.init(repo_path)
    package_hash = dep_hash = nothing
    try
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("vibepkg-test", "test@example.com")
        LibGit2.commit(repo, "initial"; author = sig, committer = sig)
        LibGit2.headname(repo) == "master" || LibGit2.branch!(repo, "master")
        package_hash = subreg_tree_hash(repo, "HEAD:julia")
        dep_hash = subreg_tree_hash(repo, "HEAD:dependencies/Dep")
    finally
        close(repo)
    end

    depot = mkpath(joinpath(dir, "depot"))
    registry = mkpath(joinpath(depot, "registries", "SubdirRegistry"))
    package_registry = mkpath(joinpath(registry, "P", "Package"))
    dep_registry = mkpath(joinpath(registry, "D", "Dep"))
    write(
        joinpath(registry, "Registry.toml"), """
        name = "SubdirRegistry"
        uuid = "cade28e2-3b52-4f58-aeba-0b1386f9894b"
        repo = "local"

        [packages]
        $SUBREG_PACKAGE_UUID = { name = "Package", path = "P/Package" }
        $SUBREG_DEP_UUID = { name = "Dep", path = "D/Dep" }
        """
    )
    for (path, name, uuid, subdir, hash) in (
            (package_registry, "Package", SUBREG_PACKAGE_UUID, "julia", package_hash),
            (dep_registry, "Dep", SUBREG_DEP_UUID, "dependencies/Dep", dep_hash),
        )
        open(joinpath(path, "Package.toml"), "w") do io
            TOML.print(
                io,
                Dict(
                    "name" => name,
                    "uuid" => string(uuid),
                    "repo" => repo_path,
                    "subdir" => subdir,
                ),
            )
        end
        write(joinpath(path, "Versions.toml"), "[\"1.0.0\"]\ngit-tree-sha1 = \"$hash\"\n")
    end
    write(joinpath(package_registry, "Deps.toml"), "[\"1\"]\nDep = \"$SUBREG_DEP_UUID\"\n")
    return (; repo_path, depot, package_hash, dep_hash)
end

function assert_subdir_state(envdir::String, direct::String, mode::Symbol)
    env = load_environment(envdir; depots = depot_stack())
    direct_uuid = direct == "Package" ? SUBREG_PACKAGE_UUID : SUBREG_DEP_UUID
    sibling_uuid = direct == "Package" ? SUBREG_DEP_UUID : SUBREG_PACKAGE_UUID
    @test env.project.deps == Dict(direct => direct_uuid)
    @test haskey(env.manifest, direct_uuid)
    if direct == "Package"
        @test env.manifest[direct_uuid].deps == Dict("Dep" => SUBREG_DEP_UUID)
        @test haskey(env.manifest, SUBREG_DEP_UUID)
    else
        @test !haskey(env.manifest, sibling_uuid)
    end

    entry = env.manifest[direct_uuid]
    if mode === :registry
        @test is_registry_tracked(entry)
        path, installed = find_installed(
            depot_stack(), direct, direct_uuid, entry_tree_hash(entry),
        )
        @test installed
        @test isfile(joinpath(path, "Project.toml"))
        @test !ispath(joinpath(path, "README.md"))
        @test !ispath(joinpath(path, direct == "Package" ? "dependencies" : "julia"))
    elseif mode === :repo
        @test is_repo_tracked(entry)
        @test entry_repo_subdir(entry) ==
            (direct == "Package" ? "julia" : "dependencies/Dep")
        path, installed = find_installed(
            depot_stack(), direct, direct_uuid, entry_tree_hash(entry),
        )
        @test installed
        @test isfile(joinpath(path, "Project.toml"))
        @test !ispath(joinpath(path, "README.md"))
    elseif mode === :path
        @test is_path_tracked(entry)
        path = entry_path(entry)
        @test path !== nothing
        @test endswith(
            normpath(path),
            direct == "Package" ? normpath(joinpath("Package", "julia")) :
                normpath(joinpath("Dep", "dependencies", "Dep")),
        )
        @test isfile(joinpath(path, "Project.toml"))
    else
        error("unknown subdir test mode: $mode")
    end
    return env
end

@testset "registry-resolved subdir add/version/rev/develop matrix" begin
    mktempdir() do dir
        dir = realpath(dir)
        fixture = make_subdir_registry_fixture(dir)
        depots = depot_stack([fixture.depot])
        regs = reachable_registries(depots)

        # Retain the lower-level contract assertions: registry metadata drives
        # resolution, and installation checks out the subdirectory Git tree.
        package_info = registry_info(only(regs), only(regs)[SUBREG_PACKAGE_UUID])
        dep_info = registry_info(only(regs), only(regs)[SUBREG_DEP_UUID])
        @test package_info.subdir == "julia"
        @test dep_info.subdir == "dependencies/Dep"
        low_env = load_environment(mkpath(joinpath(dir, "low-level")); depots)
        low_plan = plan_add(low_env, regs, Config(depots), [PackageRequest("Package")])
        @test entry_version(low_plan.manifest[SUBREG_PACKAGE_UUID]) == v"1.0.0"
        @test low_plan.manifest[SUBREG_PACKAGE_UUID].deps == Dict("Dep" => SUBREG_DEP_UUID)
        Base.ScopedValues.with(VibePkg.Utils.DEFAULT_IO => devnull) do
            apply!(low_env, low_plan, regs, Config(depots); io = devnull)
        end
        package_path, package_installed = find_installed(
            depots, "Package", SUBREG_PACKAGE_UUID, fixture.package_hash,
        )
        @test package_installed
        @test isfile(joinpath(package_path, "src", "Package.jl"))
        @test !isfile(joinpath(package_path, "README.md"))

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [fixture.depot])
            withenv(
                "JULIA_PKG_SERVER" => "",
                "JULIA_PKG_DEVDIR" => joinpath(dir, "dev"),
            ) do
                scenarios = (
                    ("Package", :plain, VibePkg.PackageSpec(name = "Package"), :registry),
                    ("Dep", :plain, VibePkg.PackageSpec(name = "Dep"), :registry),
                    ("Package", :version, VibePkg.PackageSpec(name = "Package", version = v"1.0.0"), :registry),
                    ("Dep", :version, VibePkg.PackageSpec(name = "Dep", version = v"1.0.0"), :registry),
                    ("Package", :branch, VibePkg.PackageSpec(name = "Package", rev = "master"), :repo),
                    ("Dep", :branch, VibePkg.PackageSpec(name = "Dep", rev = "master"), :repo),
                )
                for (direct, label, spec, mode) in scenarios
                    envdir = mkpath(joinpath(dir, "env-$direct-$label"))
                    Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
                    VibePkg.add(spec; io = devnull)
                    if label === :branch && direct == "Package"
                        # Pkg.jl #3391: adding the same registry-resolved
                        # subdir/revision twice is idempotent.
                        VibePkg.add(spec; io = devnull)
                    end
                    assert_subdir_state(envdir, direct, mode)
                end

                for direct in ("Package", "Dep")
                    envdir = mkpath(joinpath(dir, "env-$direct-develop"))
                    Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
                    VibePkg.develop(direct; io = devnull)
                    if direct == "Package"
                        # Pkg.jl #3391: developing the same registry-resolved
                        # subdir package twice is idempotent.
                        VibePkg.develop(direct; io = devnull)
                    end
                    assert_subdir_state(envdir, direct, :path)
                end
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end
