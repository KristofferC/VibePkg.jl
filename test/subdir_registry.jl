# Pkg.jl subdir.jl "registry-resolved subdir add/develop" — a registry whose
# package declares a `subdir` field. VibePkg resolves such a package (the
# subdir is read from the registry and the version selected) and installs it
# without a package server through the git fallback: the registry's subdir
# tree hash is itself a git tree object, so it is checked out directly from
# a clone of the repository (tarball synthesis stays excluded — a repo-root
# tarball cannot verify against the subdir tree hash).
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: SHA1
import LibGit2
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack, find_installed
using VibePkg.Registries: reachable_registries, registry_info
using VibePkg.Environments: load_environment
using VibePkg.Planning: plan_add, PackageRequest
using VibePkg.Execution: apply!
using VibePkg.EnvFiles: entry_version
using VibePkg.Errors: PkgError
import TOML

const SUB_UUID = "5ab5ab5a-0000-0000-0000-000000000001"

@testset "registry package with a subdir field" begin
    mktempdir() do dir
        # a git repo with the package living in a subdirectory
        repo = mkpath(joinpath(dir, "Mono"))
        pk = mkpath(joinpath(repo, "pkgs", "SubPkg", "src"))
        write(joinpath(repo, "pkgs", "SubPkg", "Project.toml"), "name = \"SubPkg\"\nuuid = \"$SUB_UUID\"\nversion = \"0.1.0\"\n")
        write(joinpath(pk, "SubPkg.jl"), "module SubPkg end\n")
        write(joinpath(repo, "README.md"), "top-level\n")
        r = LibGit2.init(repo)
        LibGit2.add!(r, ".")
        sig = LibGit2.Signature("t", "t@example.com")
        LibGit2.commit(r, "init"; author = sig, committer = sig)
        obj = LibGit2.GitObject(r, "HEAD:pkgs/SubPkg")   # git tree of the subdir subtree
        th = SHA1(string(LibGit2.GitHash(obj)))
        LibGit2.close(obj)
        LibGit2.close(r)

        depot = mkpath(joinpath(dir, "depot"))
        reg = mkpath(joinpath(depot, "registries", "R", "S", "SubPkg"))
        write(joinpath(depot, "registries", "R", "Registry.toml"), "name = \"R\"\nuuid = \"23338594-aafe-5451-b93e-139f81909107\"\nrepo = \"x\"\n\n[packages]\n$SUB_UUID = { name = \"SubPkg\", path = \"S/SubPkg\" }\n")
        # `repo` is an absolute path; on Windows it contains backslashes that
        # must be escaped as a TOML string, so write this file via TOML.print
        open(joinpath(reg, "Package.toml"), "w") do io
            TOML.print(io, Dict("name" => "SubPkg", "uuid" => SUB_UUID, "repo" => repo, "subdir" => "pkgs/SubPkg"))
        end
        write(joinpath(reg, "Versions.toml"), "[\"0.1.0\"]\ngit-tree-sha1 = \"$th\"\n")

        depots = depot_stack([depot])
        regs = reachable_registries(depots)

        # the registry exposes the subdir field...
        info = registry_info(only(regs), only(regs)[Base.UUID(SUB_UUID)])
        @test info.subdir == "pkgs/SubPkg"

        # ...and the package resolves to its registered version
        env = load_environment(mkpath(joinpath(dir, "env")); depots)
        planned = plan_add(env, regs, Config(depots), [PackageRequest("SubPkg")])
        @test entry_version(planned.manifest[Base.UUID(SUB_UUID)]) == v"0.1.0"

        # with no pkg server reachable, the git fallback clones the repo and
        # checks the registry's subdir tree object out directly
        Base.ScopedValues.with(VibePkg.Utils.DEFAULT_IO => devnull) do
            apply!(env, planned, regs, Config(depots); io = devnull)
        end
        path, installed = find_installed(depots, "SubPkg", Base.UUID(SUB_UUID), th)
        @test installed
        @test isfile(joinpath(path, "Project.toml"))
        @test isfile(joinpath(path, "src", "SubPkg.jl"))
        @test !isfile(joinpath(path, "README.md"))   # the subdir tree, not the repo root
    end
end
