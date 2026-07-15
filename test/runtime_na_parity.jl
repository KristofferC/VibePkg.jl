# Hermetic parity ports for public runtime behaviors previously marked N/A:
# broken local-repository updates, the process-global auto-precompile toggle,
# activate-time loaded-module mismatch warnings, and delayed-delete cleanup.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using UUIDs: UUID, uuid4
import LibGit2
using VibePkg
using VibePkg.Errors: PkgError
import VibePkg.API

function runtime_empty_registry(depot::String)
    reg = mkpath(joinpath(depot, "registries", "RuntimeEmpty"))
    write(
        joinpath(reg, "Registry.toml"),
        "name = \"RuntimeEmpty\"\nuuid = \"c3338594-aafe-5451-b93e-139f81909106\"\n\n[packages]\n",
    )
    return reg
end

function runtime_world(f::Function, root::String)
    depot = mkpath(joinpath(root, "depot"))
    runtime_empty_registry(depot)
    envdir = mkpath(joinpath(root, "env"))
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_update_gate = API.UPDATED_REGISTRY_THIS_SESSION[]
    old_auto = API.AUTO_PRECOMPILE_ENABLED[]
    try
        copy!(Base.DEPOT_PATH, [depot])
        Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
        API.UPDATED_REGISTRY_THIS_SESSION[] = true
        return withenv(
            "JULIA_PKG_SERVER" => "",
            "JULIA_PKG_OFFLINE" => "false",
            "JULIA_PKG_PRECOMPILE_AUTO" => "true",
            "JULIA_PKG_GC_AUTO" => "false",
        ) do
            f(envdir, depot)
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        copy!(Base.DEPOT_PATH, old_depots)
        API.UPDATED_REGISTRY_THIS_SESSION[] = old_update_gate
        API.autoprecompilation_enabled(old_auto)
    end
end

function runtime_git_package(root::String, name::String, uuid::UUID)
    pkg = mkpath(joinpath(root, name))
    mkpath(joinpath(pkg, "src"))
    write(
        joinpath(pkg, "Project.toml"),
        "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
    )
    write(joinpath(pkg, "src", "$name.jl"), "module $name\nend\n")
    repo = LibGit2.init(pkg)
    try
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("runtime fixture", "fixture@localhost")
        LibGit2.commit(repo, "initial"; author = sig, committer = sig)
        head = LibGit2.head(repo)
        branch = try
            LibGit2.shortname(head)
        finally
            close(head)
        end
        return (; pkg, branch)
    finally
        close(repo)
    end
end

# Pkg.jl new.jl "update: caching": a cached clone must not hide that its
# local source has ceased to be a Git repository.
@testset "update detects a broken local repository despite its clone cache" begin
    mktempdir() do root
        runtime_world(root) do _, _
            source = runtime_git_package(root, "BrokenLocalRepoPkg", uuid4())
            API.autoprecompilation_enabled(false)
            VibePkg.add(VibePkg.PackageSpec(; path = source.pkg); io = devnull)
            Base.rm(joinpath(source.pkg, ".git"); force = true, recursive = true)
            @test_throws PkgError VibePkg.update(; io = devnull)
        end
    end
end

# Pkg.jl api.jl "autoprecompilation_enabled global control": exercise only
# the public contract, not Pkg's private backing variable.
@testset "autoprecompilation_enabled global control" begin
    mktempdir() do root
        runtime_world(root) do _, depot
            name = "RuntimeAutoPrecompilePkg"
            uuid = uuid4()
            source = runtime_git_package(root, name, uuid)

            @test VibePkg.autoprecompilation_enabled(false) === false
            @test !API.should_autoprecompile()
            io = IOBuffer()
            VibePkg.add(
                VibePkg.PackageSpec(; path = source.pkg, rev = source.branch); io,
            )
            @test !occursin("Precompiling", String(take!(io)))

            pkgid = Base.PkgId(uuid, name)
            @test !Base.isprecompiled(pkgid)
            VibePkg.precompile(; io)
            @test occursin("Precompiling", String(take!(io)))
            @test Base.isprecompiled(pkgid)

            VibePkg.rm(name; io = devnull)
            cache = joinpath(
                depot, "compiled", "v$(VERSION.major).$(VERSION.minor)", name,
            )
            Base.rm(cache; force = true, recursive = true)
            @test VibePkg.autoprecompilation_enabled(true) === true
            auto_precompile_available = Base.JLOptions().use_compiled_modules == 1
            @test API.should_autoprecompile() == auto_precompile_available
            VibePkg.add(
                VibePkg.PackageSpec(; path = source.pkg, rev = source.branch); io,
            )
            @test occursin("Precompiling", String(take!(io))) == auto_precompile_available
            if !auto_precompile_available
                VibePkg.precompile(; io)
                @test occursin("Precompiling", String(take!(io)))
            end
            @test Base.isprecompiled(pkgid)
        end
    end
end

function runtime_make_path_package(dir::String, name::String, uuid::UUID, marker::String)
    mkpath(joinpath(dir, "src"))
    write(
        joinpath(dir, "Project.toml"),
        "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
    )
    write(
        joinpath(dir, "src", "$name.jl"),
        "module $name\nconst MARKER = $(repr(marker))\nend\n",
    )
    return dir
end

function runtime_make_path_env(dir::String, source::String, name::String, uuid::UUID)
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), "[deps]\n$name = \"$uuid\"\n")
    write(
        joinpath(dir, "Manifest.toml"),
        """
        julia_version = "$(VERSION)"
        manifest_format = "2.1"

        [[deps.$name]]
        path = $(repr(source))
        uuid = "$uuid"
        version = "0.1.0"
        """,
    )
    return dir
end

# The package name and UUID are unique on every inclusion so this can be
# rerun in one daemon despite loaded modules being process-global.
@testset "activate warns on loaded module mismatch" begin
    mktempdir() do root
        suffix = replace(string(uuid4()), "-" => "")[1:10]
        name = "RuntimeMismatchPkg_$suffix"
        uuid = uuid4()
        pkg_a = runtime_make_path_package(joinpath(root, "a", name), name, uuid, "A")
        pkg_b = runtime_make_path_package(joinpath(root, "b", name), name, uuid, "B")
        env_a = runtime_make_path_env(joinpath(root, "envA"), pkg_a, name, uuid)
        env_b = runtime_make_path_env(joinpath(root, "envB"), pkg_b, name, uuid)
        old_active = Base.ACTIVE_PROJECT[]
        try
            VibePkg.activate(env_a; io = devnull)
            pkgid = Base.PkgId(uuid, name)
            mod = Base.require(pkgid)
            @test getfield(mod, :MARKER) == "A"

            same_io = IOBuffer()
            VibePkg.activate(env_a; io = same_io)
            @test !occursin("Some loaded packages differ", String(take!(same_io)))

            mismatch_io = IOBuffer()
            VibePkg.activate(env_b; io = mismatch_io)
            mismatch = String(take!(mismatch_io))
            @test occursin("Some loaded packages differ", mismatch)
            @test occursin(name, mismatch)
            @test occursin(joinpath(pkg_a, "src", "$name.jl"), mismatch)
            @test occursin(joinpath(pkg_b, "src", "$name.jl"), mismatch)

            VibePkg.activate(env_a; io = devnull)
            repeated_io = IOBuffer()
            VibePkg.activate(env_b; io = repeated_io)
            @test !occursin("Some loaded packages differ", String(take!(repeated_io)))
        finally
            Base.ACTIVE_PROJECT[] = old_active
        end
    end
end

# Pkg.jl pkg.jl "Pkg.gc for delayed deletes": the public GC retries Base's
# global delayed-delete references and prunes the now-empty staging directory.
if isdefined(Base.Filesystem, :delayed_delete_ref)
    @testset "gc processes delayed-delete references" begin
        mktempdir() do root
            runtime_world(root) do _, _
                dir = joinpath(root, "julia_delayed_deletes")
                mkdir(dir)
                testfile = joinpath(dir, "testfile")
                write(testfile, "foo bar")
                refs = Base.Filesystem.delayed_delete_ref()
                mkpath(refs)
                ref = tempname(refs; cleanup = false)
                write(ref, testfile)
                try
                    @test isfile(testfile)
                    VibePkg.gc(; io = devnull)
                    @test !ispath(testfile)
                    @test !ispath(dir)
                    @test !ispath(ref)
                    @test !ispath(refs) || !isempty(readdir(refs))
                finally
                    Base.rm(ref; force = true)
                    Base.rm(dir; force = true, recursive = true)
                end
            end
        end
    end
end
