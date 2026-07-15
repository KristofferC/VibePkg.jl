# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Sockets
using LibGit2
import Dates
import TOML
using Base: UUID, SHA1
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Depots: depot_stack
using VibePkg.Registries
using VibePkg.Errors: PkgError
using VibePkg.Fetch: pkg_server
using VibePkg.Environments: load_environment
using VibePkg.Planning: plan_add, PackageRequest
using VibePkg.EnvFiles: entry_version

if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
if !@isdefined(make_test_registry)
    include("testhelpers.jl")
end

@testset "registry bootstrap (local pkg server)" begin
    LocalPkgServer.ensure!()
    @test pkg_server() !== nothing
    begin
        mktempdir() do depot
            depots = depot_stack([depot])
            added = Registries.add_default_registries!(depots; io = devnull)
            begin
                @test !isempty(added)
                regs = reachable_registries(depots)
                general = findfirst(r -> registry_name(r) == "General", regs)
                @test general !== nothing
                # a fresh depot can now plan real operations
                mktempdir() do dir
                    env = load_environment(dir; depots)
                    planned = plan_add(env, regs, Config(depots), [PackageRequest("Example")])
                    entry = planned.manifest[UUID("7876af07-990d-54b4-ab0e-23690620f79a")]
                    @test entry_version(entry) >= v"0.5.5"
                end
                # update: already current, nothing to do
                @test isempty(Registries.update_registries!(depots; io = devnull))
            end
        end
    end
end

# no network: pkg_server is a pure function of JULIA_PKG_SERVER
@testset "pkg_server selection" begin
    withenv("JULIA_PKG_SERVER" => nothing) do
        @test pkg_server() == "https://pkg.julialang.org"   # unset ⇒ default
    end
    withenv("JULIA_PKG_SERVER" => "") do
        @test pkg_server() === nothing                      # empty ⇒ no server
    end
    withenv("JULIA_PKG_SERVER" => "pkg.example.com") do
        @test pkg_server() == "https://pkg.example.com"     # bare host ⇒ https://
    end
    withenv("JULIA_PKG_SERVER" => "http://localhost:8000/") do
        @test pkg_server() == "http://localhost:8000"       # scheme kept, slash stripped
    end
end

@testset "registries land in the first depot of the stack" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot1 = mkpath(joinpath(dir, "depot1"))
        depot2 = mkpath(joinpath(dir, "depot2"))
        depots = depot_stack([depot1, depot2])

        # server bootstrap installs into depots1 only
        added = Registries.add_default_registries!(depots; io = devnull)
        @test "General" in added
        @test isfile(joinpath(depot1, "registries", "General.toml"))
        @test isfile(joinpath(depot1, "registries", "General.tar.gz"))
        @test !isdir(joinpath(depot2, "registries"))
        @test any(r -> registry_name(r) == "General", reachable_registries(depots))

        # source-based add (plain directory registry) also targets depots1
        reg_src = make_test_registry(mkpath(joinpath(dir, "src")))
        name = Registries.add_registry_from_source!(depots, reg_src; io = devnull)
        @test name == "TestRegistry"
        @test isfile(joinpath(depot1, "registries", "TestRegistry", "Registry.toml"))
        @test !isdir(joinpath(depot2, "registries"))
    end
end

@testset "registry names stay inside the registry directory" begin
    mktempdir() do dir
        source = mkpath(joinpath(dir, "source"))
        write(
            joinpath(source, "Registry.toml"), """
            name = "../outside"
            uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            repo = "https://example.invalid/Outside.git"

            [packages]
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        err = try
            Registries.add_registry_from_source!(depot_stack([depot]), source; io = devnull)
            nothing
        catch e
            e
        end
        @test err isa PkgError
        @test occursin("invalid registry name", err.msg)
        @test !ispath(joinpath(depot, "outside"))
        reg_dir = joinpath(depot, "registries")
        @test !any(startswith(".adding-"), readdir(reg_dir))
    end
end

@testset "registry status / rm / add-by-name" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        old_depots = copy(Base.DEPOT_PATH)
        try
            append!(empty!(Base.DEPOT_PATH), [depot])

            # nothing installed yet
            out = sprint(io -> VibePkg.Registry.status(; io))
            @test occursin("Registry Status", out)
            @test occursin("(no registries found)", out)

            # `registry add General` by name (served by the fixture server)
            VibePkg.Registry.add("General"; io = devnull)
            out = sprint(io -> VibePkg.Registry.status(; io))
            @test occursin("Registry Status", out)
            @test occursin("[23338594]", out)                 # short uuid
            @test occursin(" General", out)
            @test occursin("packed registry with hash", out)
            # server-tracked and current: served-by line, no update offer
            @test occursin("served by $(VibePkg.Configs.pkg_server())", out)
            @test !occursin("update available", out)
            @test !occursin("flavor", out)
            # JULIA_PKG_SERVER_REGISTRY_PREFERENCE is surfaced as the flavor
            withenv("JULIA_PKG_SERVER_REGISTRY_PREFERENCE" => "eager") do
                out = sprint(io -> VibePkg.Registry.status(; io))
                @test occursin("served by", out)
                @test occursin("(eager flavor)", out)
            end
            # offline mode skips the server query
            VibePkg.offline(true)
            try
                out = sprint(io -> VibePkg.Registry.status(; io))
                @test occursin("packed registry with hash", out)
                @test !occursin("served by", out)
            finally
                VibePkg.offline(false)
            end
            # unknown names are rejected with a pointer to url/path adds
            @test_throws PkgError VibePkg.Registry.add("NoSuchRegistry"; io = devnull)

            # a second, unpacked-directory registry with the same name but a
            # different uuid makes bare-name rm ambiguous
            reg_dir = mkpath(joinpath(depot, "registries", "General"))
            write(
                joinpath(reg_dir, "Registry.toml"), """
                name = "General"
                uuid = "99998594-aafe-5451-b93e-139f81909106"

                [packages]
                """
            )
            @test_throws PkgError VibePkg.Registry.rm("General"; io = devnull)

            # `name=uuid` disambiguates: the packed one goes, the dir stays
            VibePkg.Registry.rm("General=23338594-aafe-5451-b93e-139f81909106"; io = devnull)
            @test !isfile(joinpath(depot, "registries", "General.toml"))
            @test !isfile(joinpath(depot, "registries", "General.tar.gz"))
            @test isdir(reg_dir)
            out = sprint(io -> VibePkg.Registry.status(; io))
            @test occursin("[99998594]", out)
            @test occursin("bare registry", out)

            # rm by bare name now unambiguous; unknown registries report, not throw
            VibePkg.Registry.rm("General"; io = devnull)
            @test !isdir(reg_dir)
            out = sprint(io -> VibePkg.Registry.rm("General"; io))
            @test occursin("registry `General` not found.", out)
            @test occursin("(no registries found)", sprint(io -> VibePkg.Registry.status(; io)))
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
        end
    end
end

@testset "JULIA_PKG_GEN_REG_FMT_CHECK gates the General format nudge" begin
    withenv("JULIA_PKG_GEN_REG_FMT_CHECK" => nothing) do
        @test_logs (:info, r"The General registry is installed via git") #=
        =# VibePkg.Registries.warn_general_registry_format("git")
    end
    withenv("JULIA_PKG_GEN_REG_FMT_CHECK" => "false") do
        @test_logs VibePkg.Registries.warn_general_registry_format("git")
    end
end

@testset "JULIA_PKG_SERVER=\"\" bootstraps default registries over git" begin
    mktempdir() do dir
        # a git registry fixture standing in for General
        src = make_test_registry(joinpath(dir, "src"))
        repo = LibGit2.init(src)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("fixture", "fixture@localhost")
        LibGit2.commit(repo, "registry"; author = sig, committer = sig)
        close(repo)

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        old_defaults = copy(Registries.DEFAULT_REGISTRIES)
        try
            empty!(Registries.DEFAULT_REGISTRIES)
            push!(
                Registries.DEFAULT_REGISTRIES,
                (name = "TestRegistry", uuid = Registries.GENERAL_UUID, url = src),
            )
            withenv("JULIA_PKG_SERVER" => "") do
                added = Registries.add_default_registries!(depots; io = devnull)
                @test added == ["TestRegistry"]
                # a git clone, discoverable and queryable
                @test isdir(joinpath(depot, "registries", "TestRegistry", ".git"))
                regs = reachable_registries(depots)
                @test any(r -> registry_name(r) == "TestRegistry", regs)
                # already installed: the bootstrap is idempotent
                @test isempty(Registries.add_default_registries!(depots; io = devnull))
            end
        finally
            append!(empty!(Registries.DEFAULT_REGISTRIES), old_defaults)
        end
    end
end

@testset "JULIA_PKG_UNPACK_REGISTRY installs server registries unpacked" begin
    LocalPkgServer.ensure!()
    mktempdir() do depot
        depots = depot_stack([depot])
        withenv("JULIA_PKG_UNPACK_REGISTRY" => "true") do
            added = Registries.add_default_registries!(depots; io = devnull)
            @test "General" in added
        end
        reg_dir = joinpath(depot, "registries", "General")
        # an unpacked directory with a recorded tree hash, no packed form
        @test isdir(reg_dir)
        @test isfile(joinpath(reg_dir, ".tree_info.toml"))
        @test isfile(joinpath(reg_dir, "Registry.toml"))
        @test !isfile(joinpath(depot, "registries", "General.toml"))
        @test !isfile(joinpath(depot, "registries", "General.tar.gz"))
        # discoverable even without tarball reading, and queryable
        regs = reachable_registries(depots; read_from_tarball = false)
        general = findfirst(r -> registry_name(r) == "General", regs)
        @test general !== nothing
        @test !isempty(Registries.uuids_from_name(regs[general], "Example"))
        # already current: named and unrestricted updates are both no-ops,
        # but the successful check is stamped in the update log (unpacked form)
        @test isempty(Registries.update_registries!(depots; io = devnull))
        log = Registries.read_registry_update_log(depot)
        @test get(log, LocalPkgServer.GENERAL_UUID, nothing) isa Dates.DateTime
        @test isempty(Registries.update_registries!(depots; names = ["General"], io = devnull))
    end
end

@testset "corrupt server-registry tree hash forces refresh" begin
    state = LocalPkgServer.ensure!()
    expected_hash = SHA1(state.registry_hash)
    corrupt_hash = "179182faa6a80b3cf24445e6f55c954938d57941"
    @test SHA1(corrupt_hash) != expected_hash

    for unpack in (nothing, "true")
        mktempdir() do depot
            depots = depot_stack([depot])
            withenv("JULIA_PKG_UNPACK_REGISTRY" => unpack) do
                @test Registries.add_default_registries!(depots; io = devnull) == ["General"]

                registries = joinpath(depot, "registries")
                reg_dir = joinpath(registries, "General")
                stub_file = joinpath(registries, "General.toml")
                tarballs = filter(
                    isfile,
                    [joinpath(registries, "General$ext") for ext in (".tar.gz", ".tar.zst")],
                )
                @test isempty(tarballs) == (unpack == "true")

                # Forge only the recorded content identity. The registry data
                # remain usable, but update must not mistake them for current.
                if unpack == "true"
                    open(joinpath(reg_dir, ".tree_info.toml"), "w") do io
                        TOML.print(io, Dict("git-tree-sha1" => corrupt_hash))
                    end
                else
                    @test length(tarballs) == 1
                    open(stub_file, "w") do io
                        TOML.print(
                            io,
                            Dict(
                                "git-tree-sha1" => corrupt_hash,
                                "uuid" => LocalPkgServer.GENERAL_UUID,
                                "path" => basename(only(tarballs)),
                            ),
                        )
                    end
                end

                @test Registries.update_registries!(depots; io = devnull) == ["General"]
                tree_info_file = unpack == "true" ?
                    joinpath(reg_dir, ".tree_info.toml") : stub_file
                @test SHA1(TOML.parsefile(tree_info_file)["git-tree-sha1"]) == expected_hash

                regs = reachable_registries(depots; read_from_tarball = unpack != "true")
                general = only(filter(r -> registry_name(r) == "General", regs))
                @test general.tree_info == expected_hash
                @test !isempty(Registries.uuids_from_name(general, "Example"))

                Registries.remove_registry!(
                    depots, "General", UUID(LocalPkgServer.GENERAL_UUID); io = devnull,
                )
                @test readdir(registries) == ["CACHEDIR.TAG"]
            end
        end
    end
end

# A counting front for the fixture server: serves the same files, tallying
# hits on the /registries endpoint (the request every registry update makes).
function start_counting_server(files::String, hits::Ref{Int})
    port, server = Sockets.listenany(Sockets.localhost, 41000)
    @async while isopen(server)
        sock = try
            accept(server)
        catch
            break
        end
        @async try
            request = readline(sock)
            while !isempty(readline(sock))   # drain headers
            end
            parts = split(request)
            target = length(parts) >= 2 ? String(parts[2]) : ""
            target == "/registries" && (hits[] += 1)
            file = joinpath(files, lstrip(target, '/'))
            if !occursin("..", target) && !isempty(target) && isfile(file)
                body = read(file)
                write(sock, "HTTP/1.1 200 OK\r\nContent-Length: $(length(body))\r\nConnection: close\r\n\r\n")
                write(sock, body)
            else
                write(sock, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            end
        catch
        finally
            close(sock)
        end
    end
    return "http://127.0.0.1:$(Int(port))", server
end

@testset "registry auto-update runs once per session" begin
    LocalPkgServer.ensure!()
    files = joinpath(ENV["VIBEPKG_TEST_FIXTURES"], "files")
    hits = Ref(0)
    url, server = start_counting_server(files, hits)

    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            withenv("JULIA_PKG_SERVER" => url) do
                # first op in the session: bootstraps the registry AND runs
                # the once-per-session auto-update, flipping the gate
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                VibePkg.add("Example"; io = devnull)
                @test VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
                @test hits[] >= 1
                first_op_hits = hits[]

                # second op in the same session: gate closed, no update, so
                # the server sees no further /registries request
                VibePkg.add("Example"; io = devnull)
                @test hits[] == first_op_hits

                # reopening the gate alone is not enough: the first op's
                # already-current check stamped the persisted update log, so
                # the one-day auto-update cooldown suppresses the server query
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                VibePkg.add("Example"; io = devnull)
                @test VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
                @test hits[] == first_op_hits

                # with the cooldown stamp cleared, a fresh session updates again
                Registries.save_registry_update_log(depot, Dict{String, Any}())
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                VibePkg.add("Example"; io = devnull)
                @test VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
                @test hits[] == first_op_hits + 1
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            close(server)
        end
    end
end

# Pkg.jl#3463 — a registry in a NON-PRIMARY depot (e.g. a stale system-level
# General shadowing the user's) must show up in `registry status` too
@testset "same-named registries in multiple depots are all reported" begin
    mktempdir() do dir
        depot1 = mkpath(joinpath(dir, "depot1"))
        depot2 = mkpath(joinpath(dir, "depot2"))
        for depot in (depot1, depot2)
            reg = mkpath(joinpath(depot, "registries", "General"))
            write(
                joinpath(reg, "Registry.toml"), """
                name = "General"
                uuid = "88888594-aafe-5451-b93e-139f81909106"

                [packages]
                """
            )
        end
        old_depots = copy(Base.DEPOT_PATH)
        try
            append!(empty!(Base.DEPOT_PATH), [depot1, depot2])
            out = sprint(io -> VibePkg.Registry.status(; io))
            @test occursin(" General", out)
            @test count(" General", out) == 2
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
        end
    end
end

# Pkg.jl#2555 — a version published after the registry was installed is
# visible to the SAME operation that updates the registry (no second try
# needed): op_context reloads the in-memory registries after updating
@testset "newly published version visible in the same op" begin
    LocalPkgServer.ensure!()
    fixtures = ENV["VIBEPKG_TEST_FIXTURES"]
    example_uuid = UUID(LocalPkgServer.EXAMPLE_UUID)
    mktempdir() do dir
        # a private copy of the fixture server's files, so we can republish
        files = joinpath(dir, "files")
        cp(joinpath(fixtures, "files"), files)
        srv = LocalPkgServer.start_server(files)
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            withenv("JULIA_PKG_SERVER" => srv.url) do
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                VibePkg.add("Example"; io = devnull)
                env = load_environment(envdir; depots = depot_stack())
                @test entry_version(env.manifest[example_uuid]) == v"0.5.5"

                # publish Example 0.5.6: package tarball + reindexed registry
                pkgdir = LocalPkgServer.write_example!(mkpath(joinpath(dir, "pkg")), "0.5.6")
                pkg_hash = bytes2hex(VibePkg.TreeHash.tree_hash(pkgdir))
                LocalPkgServer.gzip_tarball(pkgdir, joinpath(files, "package", string(example_uuid), pkg_hash))
                regdir = joinpath(dir, "registry")
                cp(joinpath(fixtures, "registry"), regdir)
                versions_file = joinpath(regdir, "E", "Example", "Versions.toml")
                write(
                    versions_file, read(versions_file, String) * """

                        ["0.5.6"]
                        git-tree-sha1 = "$pkg_hash"
                        """
                )
                reg_hash = bytes2hex(VibePkg.TreeHash.tree_hash(regdir))
                LocalPkgServer.gzip_tarball(regdir, joinpath(files, "registry", LocalPkgServer.GENERAL_UUID, reg_hash))
                write(joinpath(files, "registries"), "/registry/$(LocalPkgServer.GENERAL_UUID)/$reg_hash\n")

                # clear the update-log stamp from the add's already-current
                # check so up's ~1s explicit-update cooldown cannot race the
                # publishing steps above
                Registries.save_registry_update_log(depot, Dict{String, Any}())
                # the op that updates the registry already resolves 0.5.6
                VibePkg.up(; io = devnull)
                env = load_environment(envdir; depots = depot_stack())
                @test entry_version(env.manifest[example_uuid]) == v"0.5.6"
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            close(srv.server)
        end
    end
end

# Pkg.jl#1939 — instantiate never updates registries (not even when the
# once-per-session auto-update has not run yet)
@testset "instantiate never updates registries" begin
    LocalPkgServer.ensure!()
    files = joinpath(ENV["VIBEPKG_TEST_FIXTURES"], "files")
    hits = Ref(0)
    url, server = start_counting_server(files, hits)
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            withenv("JULIA_PKG_SERVER" => url) do
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
                VibePkg.add("Example"; io = devnull)   # bootstrap + install
                reg_dir = joinpath(depot, "registries")
                snapshot() = Dict(f => mtime(joinpath(reg_dir, f)) for f in readdir(reg_dir))
                before = snapshot()
                hits_before = hits[]
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false   # fresh session
                VibePkg.instantiate(; io = devnull)
                @test hits[] == hits_before                        # no /registries request
                @test !VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] # gate untouched
                @test snapshot() == before                         # files untouched
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
            close(server)
        end
    end
end

# Pkg.jl manifests.jl "Instantiate with non-default registry from manifest"
# (line 417) — registry provenance is actionable, not just metadata. A fresh
# depot which has some other registry installed must install the custom
# registry named by Manifest.toml before materializing a registry-tracked
# package. Both registry and package sources are local git repositories, so
# this exercises the public API without network access.
@testset "instantiate installs non-default registry from manifest" begin
    mktempdir() do dir
        pkg_uuid = UUID("19c274d2-4aeb-4c41-a775-86db79acb842")
        reg_uuid = UUID("4d88b79e-6e4c-4f2c-b57b-6c413f0295de")
        sentinel_uuid = UUID("87bc0461-8087-488d-a175-5f47cfb3d491")

        # The registered package source and its exact git tree hash.
        pkg_src = mkpath(joinpath(dir, "TestPkg"))
        mkpath(joinpath(pkg_src, "src"))
        write(
            joinpath(pkg_src, "Project.toml"),
            "name = \"TestPkg\"\nuuid = \"$pkg_uuid\"\nversion = \"0.1.0\"\n",
        )
        write(
            joinpath(pkg_src, "src", "TestPkg.jl"),
            "module TestPkg\ngreet() = \"Hello from TestPkg!\"\nend\n",
        )
        pkg_repo = LibGit2.init(pkg_src)
        LibGit2.add!(pkg_repo, ".")
        sig = LibGit2.Signature("fixture", "fixture@localhost")
        LibGit2.commit(pkg_repo, "initial"; author = sig, committer = sig)
        pkg_obj = LibGit2.GitObject(pkg_repo, "HEAD")
        pkg_tree = LibGit2.peel(LibGit2.GitTree, pkg_obj)
        pkg_hash = SHA1(string(LibGit2.GitHash(pkg_tree)))
        close(pkg_tree)
        close(pkg_obj)
        close(pkg_repo)

        # A custom git-backed registry whose source path is recorded as the
        # manifest registry URL.
        reg_src = mkpath(joinpath(dir, "CustomReg-source"))
        reg_pkg = mkpath(joinpath(reg_src, "T", "TestPkg"))
        open(joinpath(reg_src, "Registry.toml"), "w") do io
            TOML.print(
                io,
                Dict(
                    "name" => "CustomReg",
                    "uuid" => string(reg_uuid),
                    "repo" => reg_src,
                    "packages" => Dict(
                        string(pkg_uuid) => Dict("name" => "TestPkg", "path" => "T/TestPkg"),
                    ),
                ),
            )
        end
        open(joinpath(reg_pkg, "Package.toml"), "w") do io
            TOML.print(
                io,
                Dict("name" => "TestPkg", "uuid" => string(pkg_uuid), "repo" => pkg_src),
            )
        end
        open(joinpath(reg_pkg, "Versions.toml"), "w") do io
            TOML.print(io, Dict("0.1.0" => Dict("git-tree-sha1" => string(pkg_hash))))
        end
        reg_repo = LibGit2.init(reg_src)
        LibGit2.add!(reg_repo, ".")
        LibGit2.commit(reg_repo, "initial"; author = sig, committer = sig)
        close(reg_repo)

        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        depots = depot_stack([depot])

        # Suppress default-General bootstrap without installing CustomReg.
        # This also proves instantiate handles one missing registry among an
        # already nonempty reachable-registry set.
        sentinel = mkpath(joinpath(dir, "Sentinel-source"))
        open(joinpath(sentinel, "Registry.toml"), "w") do io
            TOML.print(
                io,
                Dict(
                    "name" => "Sentinel",
                    "uuid" => string(sentinel_uuid),
                    "repo" => sentinel,
                    "packages" => Dict{String, Any}(),
                ),
            )
        end
        Registries.add_registry_from_source!(depots, sentinel; io = devnull)

        open(joinpath(envdir, "Project.toml"), "w") do io
            TOML.print(io, Dict("deps" => Dict("TestPkg" => string(pkg_uuid))))
        end
        open(joinpath(envdir, "Manifest.toml"), "w") do io
            TOML.print(
                io,
                Dict(
                    "julia_version" => string(VERSION),
                    "manifest_format" => "2.1",
                    "deps" => Dict(
                        "TestPkg" => [
                            Dict(
                                "uuid" => string(pkg_uuid),
                                "version" => "0.1.0",
                                "git-tree-sha1" => string(pkg_hash),
                                "registries" => ["CustomReg"],
                            ),
                        ],
                    ),
                    "registries" => Dict(
                        "CustomReg" => Dict(
                            "uuid" => string(reg_uuid),
                            "url" => reg_src,
                        ),
                    ),
                ),
            )
        end

        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = VibePkg.API.AUTO_PRECOMPILE_ENABLED[]
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = false
            withenv("JULIA_PKG_SERVER" => "") do
                @test !any(r -> registry_uuid(r) == reg_uuid, reachable_registries(depot_stack()))

                VibePkg.instantiate(; io = devnull)

                regs = reachable_registries(depot_stack())
                @test any(r -> registry_uuid(r) == reg_uuid, regs)
                @test isfile(joinpath(depot, "registries", "CustomReg", "Registry.toml"))
                installed = only(filter(isdir, readdir(joinpath(depot, "packages", "TestPkg"); join = true)))
                @test occursin(
                    "Hello from TestPkg!",
                    read(joinpath(installed, "src", "TestPkg.jl"), String),
                )
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

# a git registry fixture with a configurable name/uuid (Pkg.jl#3249 needs
# two distinct git-backed registries in one depot)
function make_named_git_registry(dir::String; name::String, uuid::String)
    pkg = mkpath(joinpath(dir, "E", "Example"))
    write(
        joinpath(dir, "Registry.toml"), """
        name = "$name"
        uuid = "$uuid"

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
        """
    )
    repo = LibGit2.init(dir)
    LibGit2.add!(repo, ".")
    sig = LibGit2.Signature("fixture", "fixture@localhost")
    LibGit2.commit(repo, "registry"; author = sig, committer = sig)
    close(repo)
    return dir
end

# Pkg.jl registry.jl "registries" — exercise the complete lifecycle through
# both public string API and the executed REPL driver. RegistrySpec objects and
# vector overloads are not part of VibePkg's API; its equivalent spellings are
# name, bare uuid, and name=uuid strings.
@testset "registry lifecycle identity spellings" begin
    mktempdir() do dir
        reg_name = "LifecycleReg"
        reg_uuid = UUID("8c6f2c42-9126-4f21-bfe5-a51d6962227b")
        example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        source = make_named_git_registry(
            joinpath(dir, "source"); name = reg_name, uuid = string(reg_uuid),
        )
        depot = mkpath(joinpath(dir, "depot"))
        old_depots = copy(Base.DEPOT_PATH)
        old_defaults = copy(Registries.DEFAULT_REGISTRIES)
        revision = Ref(0)

        function publish_version!()
            revision[] += 1
            version = VersionNumber(0, 6, revision[])
            tree_hash = lpad(string(revision[]; base = 16), 40, '0')
            versions_file = joinpath(source, "E", "Example", "Versions.toml")
            write(
                versions_file, read(versions_file, String) * """

                    ["$version"]
                    git-tree-sha1 = "$tree_hash"
                    """
            )
            repo = LibGit2.GitRepo(source)
            try
                LibGit2.add!(repo, ".")
                sig = LibGit2.Signature("fixture", "fixture@localhost")
                LibGit2.commit(repo, "add $version"; author = sig, committer = sig)
            finally
                close(repo)
            end
            return version
        end

        function assert_installed(version = v"0.5.0")
            regs = reachable_registries(depot_stack())
            @test length(regs) == 1
            reg = only(regs)
            @test registry_name(reg) == reg_name && registry_uuid(reg) == reg_uuid
            @test haskey(reg, example_uuid)
            @test haskey(registry_info(reg, reg[example_uuid]).version_info, version)
            return
        end

        try
            append!(empty!(Base.DEPOT_PATH), [depot])
            empty!(Registries.DEFAULT_REGISTRIES)
            push!(
                Registries.DEFAULT_REGISTRIES,
                (name = reg_name, uuid = reg_uuid, url = source),
            )
            withenv("JULIA_PKG_SERVER" => "") do
                spellings = (reg_name, string(reg_uuid), "$reg_name=$reg_uuid")

                # Public facade: add, targeted update, and rm all accept each
                # supported identity spelling.
                for spec in spellings
                    VibePkg.Registry.add(spec; io = devnull)
                    assert_installed()
                    version = publish_version!()
                    Base.rm(Registries.registry_update_log_file(depot); force = true)
                    VibePkg.Registry.update(spec; io = devnull)
                    assert_installed(version)
                    VibePkg.Registry.rm(spec; io = devnull)
                    @test isempty(reachable_registries(depot_stack()))
                end

                # No-argument API add installs the configured defaults.
                VibePkg.Registry.add(; io = devnull)
                assert_installed()
                VibePkg.Registry.rm(reg_name; io = devnull)
                @test isempty(reachable_registries(depot_stack()))

                # Execute the same round trips through the real REPL driver.
                for spec in spellings
                    VibePkg.REPLMode.do_cmd("registry add $spec"; io = devnull)
                    assert_installed()
                    version = publish_version!()
                    Base.rm(Registries.registry_update_log_file(depot); force = true)
                    VibePkg.REPLMode.do_cmd("registry up $spec"; io = devnull)
                    assert_installed(version)
                    VibePkg.REPLMode.do_cmd("registry rm $spec"; io = devnull)
                    @test isempty(reachable_registries(depot_stack()))
                end

                # The REPL no-argument spelling follows the same bootstrap path.
                VibePkg.REPLMode.do_cmd("registry add"; io = devnull)
                assert_installed()
                VibePkg.REPLMode.do_cmd("registry rm $reg_name"; io = devnull)
                @test isempty(reachable_registries(depot_stack()))
            end
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
            append!(empty!(Registries.DEFAULT_REGISTRIES), old_defaults)
        end
    end
end

# UUID selectors must remain UUID selectors below the public facade. In
# particular, registries in different depots may share a declared name;
# resolving a later-depot UUID back to that name would wrongly update the
# same-named registry in the primary depot.
@testset "registry update preserves UUID identity" begin
    mktempdir() do dir
        reg_name = "SharedName"
        uuid_a = UUID("58e09b9d-877b-470f-95c9-7d2aa51c0ad1")
        uuid_b = UUID("7108527d-3576-4111-9d63-99d296a2d51a")
        example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        source_a = make_named_git_registry(
            joinpath(dir, "source-a"); name = reg_name, uuid = string(uuid_a),
        )
        source_b = make_named_git_registry(
            joinpath(dir, "source-b"); name = reg_name, uuid = string(uuid_b),
        )
        depot_a = mkpath(joinpath(dir, "depot-a"))
        depot_b = mkpath(joinpath(dir, "depot-b"))
        installed_a = joinpath(mkpath(joinpath(depot_a, "registries")), reg_name)
        installed_b = joinpath(mkpath(joinpath(depot_b, "registries")), reg_name)
        close(LibGit2.clone(source_a, installed_a))
        close(LibGit2.clone(source_b, installed_b))
        old_depots = copy(Base.DEPOT_PATH)

        function publish_version!(source, version, tree_hash)
            versions_file = joinpath(source, "E", "Example", "Versions.toml")
            write(
                versions_file, read(versions_file, String) * """

                    ["$version"]
                    git-tree-sha1 = "$tree_hash"
                    """
            )
            repo = LibGit2.GitRepo(source)
            try
                LibGit2.add!(repo, ".")
                sig = LibGit2.Signature("fixture", "fixture@localhost")
                LibGit2.commit(repo, "add $version"; author = sig, committer = sig)
            finally
                close(repo)
            end
            return
        end
        function has_version(path, version)
            reg = Registries.RegistryInstance(path)
            return haskey(registry_info(reg, reg[example_uuid]).version_info, version)
        end

        try
            append!(empty!(Base.DEPOT_PATH), [depot_a, depot_b])
            withenv("JULIA_PKG_SERVER" => "") do
                regs = reachable_registries(depot_stack())
                @test Set(registry_name.(regs)) == Set([reg_name])
                @test Set(registry_uuid.(regs)) == Set([uuid_a, uuid_b])

                version_a = v"0.6.1"
                version_b = v"0.7.1"
                publish_version!(source_a, version_a, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                publish_version!(source_b, version_b, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

                # B is reachable but not primary. Its UUID must not collapse
                # to the shared name and accidentally update primary A.
                VibePkg.Registry.update(string(uuid_b); io = devnull)
                @test !has_version(installed_a, version_a)
                @test !has_version(installed_b, version_b)

                # Once B is primary, name=uuid reaches exactly B; UUID is
                # authoritative, matching Pkg's RegistrySpec search rule.
                append!(empty!(Base.DEPOT_PATH), [depot_b, depot_a])
                VibePkg.REPLMode.do_cmd("registry up $reg_name=$uuid_b"; io = devnull)
                @test !has_version(installed_a, version_a)
                @test has_version(installed_b, version_b)

                # Switching back lets the bare UUID advance only A.
                append!(empty!(Base.DEPOT_PATH), [depot_a, depot_b])
                VibePkg.Registry.update(string(uuid_a); io = devnull)
                @test has_version(installed_a, version_a)
                @test has_version(installed_b, version_b)
            end
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
        end
    end
end

# Pkg.jl#3249 — a registry whose remote is broken must not abort updating
# the remaining registries
@testset "one broken registry does not abort updates" begin
    mktempdir() do dir
        src_broken = make_named_git_registry(
            joinpath(dir, "src_broken");
            name = "ABroken", uuid = "aaaa8594-aafe-5451-b93e-139f81909106",
        )
        src_good = make_named_git_registry(
            joinpath(dir, "src_good");
            name = "ZGood", uuid = "bbbb8594-aafe-5451-b93e-139f81909106",
        )
        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        @test Registries.add_registry_from_source!(depots, src_broken; io = devnull) == "ABroken"
        @test Registries.add_registry_from_source!(depots, src_good; io = devnull) == "ZGood"

        # break the first (alphabetically) registry's remote
        LibGit2.set_remote_url(
            joinpath(depot, "registries", "ABroken"), "origin",
            "file:///nonexistent/bogus.git",
        )
        # publish a new version upstream in the good one
        versions_file = joinpath(src_good, "E", "Example", "Versions.toml")
        write(
            versions_file, read(versions_file, String) * """

                ["0.6.0"]
                git-tree-sha1 = "4444444444444444444444444444444444444444"
                """
        )
        repo = LibGit2.GitRepo(src_good)
        LibGit2.add!(repo, ".")
        sig = LibGit2.Signature("fixture", "fixture@localhost")
        LibGit2.commit(repo, "add 0.6.0"; author = sig, committer = sig)
        close(repo)

        # the broken one is reported (not thrown), the good one updates
        updated = @test_logs (:error, r"(?i)failed to update") match_mode = :any begin
            Registries.update_registries!(depots; server = nothing, io = devnull)
        end
        @test updated == ["ZGood"]
        r = only(filter(r -> registry_name(r) == "ZGood", reachable_registries(depots)))
        @test haskey(Registries.registry_info(r, r[UUID("7876af07-990d-54b4-ab0e-23690620f79a")]).version_info, v"0.6.0")
    end
end

# Pkg.jl registry.jl "multiple registries in one command" — VibePkg's
# variadic string API and REPL driver operate on several registries per call.
@testset "add/update/rm multiple registries in one call" begin
    mktempdir() do dir
        s1 = make_named_git_registry(
            joinpath(dir, "source-one");
            name = "RegOne", uuid = "11111111-1111-1111-1111-111111111111",
        )
        s2 = make_named_git_registry(
            joinpath(dir, "source-two");
            name = "RegTwo", uuid = "22222222-2222-2222-2222-222222222222",
        )
        depot = mkpath(joinpath(dir, "depot"))
        old_depots = copy(Base.DEPOT_PATH)
        example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

        function publish_version!(source, version, tree_hash)
            versions_file = joinpath(source, "E", "Example", "Versions.toml")
            write(
                versions_file, read(versions_file, String) * """

                    ["$version"]
                    git-tree-sha1 = "$tree_hash"
                    """
            )
            repo = LibGit2.GitRepo(source)
            try
                LibGit2.add!(repo, ".")
                sig = LibGit2.Signature("fixture", "fixture@localhost")
                LibGit2.commit(repo, "add $version"; author = sig, committer = sig)
            finally
                close(repo)
            end
            return
        end
        function registry_has_version(name, version)
            reg = only(filter(r -> registry_name(r) == name, reachable_registries(depot_stack())))
            return haskey(registry_info(reg, reg[example_uuid]).version_info, version)
        end

        try
            append!(empty!(Base.DEPOT_PATH), [depot])
            withenv("JULIA_PKG_SERVER" => "") do
                # Public API: each lifecycle operation is one variadic call.
                VibePkg.Registry.add(s1, s2; io = devnull)
                out = sprint(io -> VibePkg.Registry.status(; io))
                @test occursin("RegOne", out) && occursin("RegTwo", out)

                publish_version!(s1, v"0.6.0", "2222222222222222222222222222222222222222")
                publish_version!(s2, v"0.6.0", "3333333333333333333333333333333333333333")
                VibePkg.Registry.update("RegOne", "RegTwo"; io = devnull)
                @test registry_has_version("RegOne", v"0.6.0")
                @test registry_has_version("RegTwo", v"0.6.0")

                VibePkg.Registry.rm("RegOne", "RegTwo"; io = devnull)
                out = sprint(io -> VibePkg.Registry.status(; io))
                @test !occursin("RegOne", out) && !occursin("RegTwo", out)

                # REPL driver: execute the combined add/up/rm forms, not just
                # parser introspection, and prove both registries move.
                VibePkg.REPLMode.do_cmd("registry add \"$s1\" \"$s2\""; io = devnull)
                @test registry_has_version("RegOne", v"0.6.0")
                @test registry_has_version("RegTwo", v"0.6.0")

                publish_version!(s1, v"0.7.0", "4444444444444444444444444444444444444444")
                publish_version!(s2, v"0.7.0", "5555555555555555555555555555555555555555")
                # The preceding API update stamped these UUIDs less than the
                # one-second duplicate-update cooldown ago. Model a new REPL
                # session so this explicit command performs its fetches.
                Base.rm(Registries.registry_update_log_file(depot); force = true)
                VibePkg.REPLMode.do_cmd("registry up RegOne RegTwo"; io = devnull)
                @test registry_has_version("RegOne", v"0.7.0")
                @test registry_has_version("RegTwo", v"0.7.0")

                VibePkg.REPLMode.do_cmd("registry rm RegOne RegTwo"; io = devnull)
                out = sprint(io -> VibePkg.Registry.status(; io))
                @test !occursin("RegOne", out) && !occursin("RegTwo", out)
            end
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
        end
    end
end

# a registry tarball whose embedded Registry.toml declares a different uuid
# than the one it was requested under must be rejected, not installed
@testset "server registry with mismatched uuid is rejected" begin
    state = LocalPkgServer.ensure!()
    fixtures = ENV["VIBEPKG_TEST_FIXTURES"]
    mktempdir() do dir
        files = joinpath(dir, "files")
        cp(joinpath(fixtures, "files"), files)
        bogus = UUID("99999999-aafe-5451-b93e-139f81909106")
        reg_hash = state.registry_hash
        # advertise the General tarball (embedded uuid = GENERAL_UUID) under
        # a different uuid
        mkpath(joinpath(files, "registry", string(bogus)))
        cp(
            joinpath(files, "registry", LocalPkgServer.GENERAL_UUID, reg_hash),
            joinpath(files, "registry", string(bogus), reg_hash),
        )
        write(joinpath(files, "registries"), "/registry/$bogus/$reg_hash\n")
        srv = LocalPkgServer.start_server(files)
        try
            depot = mkpath(joinpath(dir, "depot"))
            err = try
                Registries.install_server_registry!(
                    depot, srv.url, bogus, SHA1(reg_hash); io = devnull,
                )
                nothing
            catch e
                e
            end
            @test err isa PkgError
            @test occursin(string(bogus), err.msg)
        @test occursin("declares uuid", lowercase(err.msg))
            # nothing was installed
            @test !isfile(joinpath(depot, "registries", "General.toml"))
            @test !isfile(joinpath(depot, "registries", "General.tar.gz"))
            @test !isdir(joinpath(depot, "registries", "General"))
        finally
            close(srv.server)
        end
    end
end

# an update that finds the registry already current must stamp the persisted
# update log, so a later session inside the cooldown skips the server query
@testset "already-current update stamps the cooldown log" begin
    LocalPkgServer.ensure!()
    files = joinpath(ENV["VIBEPKG_TEST_FIXTURES"], "files")
    hits = Ref(0)
    url, server = start_counting_server(files, hits)
    try
        mktempdir() do depot
            depots = depot_stack([depot])
            withenv("JULIA_PKG_SERVER" => url) do
                Registries.add_default_registries!(depots; io = devnull)
                @test !haskey(Registries.read_registry_update_log(depot), LocalPkgServer.GENERAL_UUID)
                # explicit update: the server says "already current" — no
                # update happens, but the successful check is stamped
                @test isempty(Registries.update_registries!(depots; io = devnull))
                log = Registries.read_registry_update_log(depot)
                @test get(log, LocalPkgServer.GENERAL_UUID, nothing) isa Dates.DateTime
                # a fresh "session" within the cooldown makes no server request
                before = hits[]
                @test isempty(
                    Registries.update_registries!(
                        depots; update_cooldown = Dates.Hour(1), io = devnull,
                    )
                )
                @test hits[] == before
            end
        end
    finally
        close(server)
    end
end

# a bare directory registry cannot be updated by `update_registries!`, so
# status must not claim the server can update it, even for a tracked uuid
@testset "status: no server update offer for bare registries" begin
    LocalPkgServer.ensure!()
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        reg = mkpath(joinpath(depot, "registries", "General"))
        write(
            joinpath(reg, "Registry.toml"), """
            name = "General"
            uuid = "$(LocalPkgServer.GENERAL_UUID)"

            [packages]
            """
        )
        old_depots = copy(Base.DEPOT_PATH)
        try
            append!(empty!(Base.DEPOT_PATH), [depot])
            out = sprint(io -> VibePkg.Registry.status(; io))
            @test occursin("bare registry", out)
            @test !occursin("update available", out)
            @test !occursin("served by", out)
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
        end
    end
end
