# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Sockets
using LibGit2
using Base: UUID
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
        # already current: named and unrestricted updates are both no-ops
        @test isempty(Registries.update_registries!(depots; io = devnull))
        @test isempty(Registries.update_registries!(depots; names = ["General"], io = devnull))
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

                # reopening the gate makes the next op update again
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
        updated = @test_logs (:error, r"failed to update") match_mode = :any begin
            Registries.update_registries!(depots; server = nothing, io = devnull)
        end
        @test updated == ["ZGood"]
        r = only(filter(r -> registry_name(r) == "ZGood", reachable_registries(depots)))
        @test haskey(Registries.registry_info(r, r[UUID("7876af07-990d-54b4-ab0e-23690620f79a")]).version_info, v"0.6.0")
    end
end

# Pkg.jl registry.jl "multiple registries in one command" — the variadic
# Registry.add / Registry.rm operate on several registries in a single call.
@testset "add/rm multiple registries in one call" begin
    mktempdir() do dir
        mkreg(name, uuid) = (
            src = mkpath(joinpath(dir, name));
            write(
                joinpath(src, "Registry.toml"),
                "name = \"$name\"\nuuid = \"$uuid\"\nrepo = \"https://example.com/$name.git\"\n\n[packages]\n",
            );
            src
        )
        s1 = mkreg("RegOne", "11111111-1111-1111-1111-111111111111")
        s2 = mkreg("RegTwo", "22222222-2222-2222-2222-222222222222")

        VibePkg.Registry.add(s1, s2; io = devnull)          # one call → two registries
        out = sprint(io -> VibePkg.Registry.status(; io))
        @test occursin("RegOne", out) && occursin("RegTwo", out)

        VibePkg.Registry.rm("RegOne", "RegTwo"; io = devnull) # one call → both removed
        out2 = sprint(io -> VibePkg.Registry.status(; io))
        @test !occursin("RegOne", out2) && !occursin("RegTwo", out2)
    end
end
