# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

# Doc-parity features: Pkg.dependencies /
# project / readonly / setprotocol!, `activate -` and activate-by-dep-name,
# compat-on-add, `add --weak/--extra`, precompile options, the artifact
# creation API, and pkg-server auth error handling (handler hooks + 401
# refresh-and-retry).

using Test
using Sockets
using TOML
using Base: UUID, SHA1
using Base.BinaryPlatforms: HostPlatform, Platform
using VibePkg
using VibePkg: API, Git, Fetch, Depots, EnvFiles
using VibePkg.Depots: depot_stack
using VibePkg.Errors: PkgError

const DF_EXAMPLE = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

# run `f` against an isolated depot + active project (fixture pkg server)
function with_temp_world(f; project_toml::Union{Nothing, String} = nothing)
    LocalPkgServer.ensure!()
    return mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        envdir = mkpath(joinpath(dir, "env"))
        project_toml === nothing || write(joinpath(envdir, "Project.toml"), project_toml)
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_auto = API.AUTO_PRECOMPILE_ENABLED[]
        API.AUTO_PRECOMPILE_ENABLED[] = false
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            f(dir, envdir)
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            API.AUTO_PRECOMPILE_ENABLED[] = old_auto
        end
    end
end

@testset "compat-on-add in a package project" begin
    with_temp_world(
        project_toml = """
        name = "MyPkg"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000"
        version = "0.1.0"
        """
    ) do dir, envdir
        out = IOBuffer()
        VibePkg.add("Example"; io = out)
        text = String(take!(out))
        # a compat entry lower-bounded at the resolved version was recorded
        @test occursin("Compat", text) && occursin("entries added for Example", text)
        proj = TOML.parsefile(joinpath(envdir, "Project.toml"))
        v = VersionNumber(proj["compat"]["Example"])
        @test v >= v"0.5.0" && string(v) == proj["compat"]["Example"]
        manifest_v = VibePkg.dependencies()[DF_EXAMPLE].version
        @test v == manifest_v

        # an existing compat entry is never overwritten by a re-add
        write(
            joinpath(envdir, "Project.toml"), """
            name = "MyPkg"
            uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000"
            version = "0.1.0"

            [deps]
            Example = "$DF_EXAMPLE"

            [compat]
            Example = "0.5.1"
            """
        )
        VibePkg.add("Example"; io = devnull)
        proj = TOML.parsefile(joinpath(envdir, "Project.toml"))
        @test proj["compat"]["Example"] == "0.5.1"
    end

    # a plain (non-package) environment gets no compat entry
    with_temp_world() do dir, envdir
        VibePkg.add("Example"; io = devnull)
        proj = TOML.parsefile(joinpath(envdir, "Project.toml"))
        @test !haskey(proj, "compat")
    end
end

@testset "add --weak / --extra (target kwarg)" begin
    with_temp_world() do dir, envdir
        out = IOBuffer()
        VibePkg.add("Example"; target = :weakdeps, io = out)
        @test occursin("Added Example to [weakdeps]", String(take!(out)))
        proj = TOML.parsefile(joinpath(envdir, "Project.toml"))
        @test proj["weakdeps"]["Example"] == string(DF_EXAMPLE)
        @test !haskey(proj, "deps")
        # nothing was resolved or installed
        @test !isfile(joinpath(envdir, "Manifest.toml"))

        VibePkg.add("Example"; target = :extras, io = out)
        @test occursin("Added Example to [extras]", String(take!(out)))
        proj = TOML.parsefile(joinpath(envdir, "Project.toml"))
        @test proj["extras"]["Example"] == string(DF_EXAMPLE)

        @test_throws PkgError VibePkg.add("Example"; target = :bogus, io = devnull)
        @test_throws PkgError VibePkg.add(
            VibePkg.PackageSpec(url = "https://example.invalid/X.jl.git");
            target = :weakdeps, io = devnull,
        )
    end
end

@testset "dependencies() and project()" begin
    with_temp_world(
        project_toml = """
        name = "MyPkg"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000"
        version = "0.1.0"
        """
    ) do dir, envdir
        VibePkg.add("Example"; io = devnull)

        deps = VibePkg.dependencies()
        @test deps isa Dict{UUID, VibePkg.PackageInfo}
        info = deps[DF_EXAMPLE]
        @test info.name == "Example"
        @test info.version isa VersionNumber
        @test info.is_direct_dep
        @test !info.is_pinned
        @test info.is_tracking_registry
        @test !info.is_tracking_path && !info.is_tracking_repo
        @test info.git_revision === nothing && info.git_source === nothing
        @test info.tree_hash isa String && length(info.tree_hash) == 40
        @test info.source isa String && isfile(joinpath(info.source, "Project.toml"))
        @test info.dependencies isa Dict{String, UUID}

        # a dev'd package reports path tracking; pin reports pinned
        devved = joinpath(dir, "Devved")
        mkpath(joinpath(devved, "src"))
        write(
            joinpath(devved, "Project.toml"), """
            name = "Devved"
            uuid = "bbbbbbbb-cccc-dddd-eeee-ffff00001111"
            version = "0.1.0"
            """
        )
        write(joinpath(devved, "src", "Devved.jl"), "module Devved end")
        VibePkg.develop(path = devved, io = devnull)
        VibePkg.pin("Example"; io = devnull)
        deps = VibePkg.dependencies()
        dev_info = deps[UUID("bbbbbbbb-cccc-dddd-eeee-ffff00001111")]
        @test dev_info.is_tracking_path && !dev_info.is_tracking_registry
        @test dev_info.source == devved
        @test deps[DF_EXAMPLE].is_pinned

        proj = VibePkg.project()
        @test proj isa VibePkg.ProjectInfo
        @test proj.name == "MyPkg"
        @test proj.uuid == UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000")
        @test proj.version == v"0.1.0"
        @test proj.ispackage
        @test proj.dependencies["Example"] == DF_EXAMPLE
        # (realpath: the env snapshot canonicalizes /var → /private/var on macOS)
        @test proj.path == realpath(Base.active_project())
    end

    # non-package environment: ispackage is false
    with_temp_world() do dir, envdir
        VibePkg.add("Example"; io = devnull)
        proj = VibePkg.project()
        @test proj.name === nothing && proj.uuid === nothing
        @test !proj.ispackage
    end
end

@testset "readonly() getter/setter" begin
    with_temp_world() do dir, envdir
        VibePkg.add("Example"; io = devnull)
        @test VibePkg.readonly() === false
        # setting returns the previous state and writes the project file
        @test VibePkg.readonly(true; io = devnull) === false
        @test VibePkg.readonly() === true
        @test TOML.parsefile(joinpath(envdir, "Project.toml"))["readonly"] === true
        # a readonly environment rejects modification
        err = try
            VibePkg.rm("Example"; io = devnull)
            nothing
        catch e
            e
        end
        @test err isa PkgError && occursin("readonly", err.msg)
        @test VibePkg.readonly(false; io = devnull) === true
        @test VibePkg.readonly() === false
        VibePkg.rm("Example"; io = devnull)         # works again
    end
end

@testset "setprotocol! rewrites clone urls per domain" begin
    domain = "mygit.example.com"
    default_domain = "github.com"
    had_default_protocol = haskey(Git.GIT_PROTOCOLS, default_domain)
    had_default_user = haskey(Git.GIT_USERS, default_domain)
    old_default_protocol = get(Git.GIT_PROTOCOLS, default_domain, nothing)
    old_default_user = get(Git.GIT_USERS, default_domain, nothing)
    try
        # protocol unset: urls pass through untouched
        @test Git.normalize_url("git@$domain:Org/Pkg.jl.git") == "git@$domain:Org/Pkg.jl.git"

        VibePkg.setprotocol!(domain = domain, protocol = "https")
        @test Git.normalize_url("git@$domain:Org/Pkg.jl.git") == "https://$domain/Org/Pkg.jl.git"
        @test Git.normalize_url("ssh://git@$domain/Org/Pkg.jl.git") == "https://$domain/Org/Pkg.jl.git"

        VibePkg.setprotocol!(domain = domain, protocol = "ssh")
        @test Git.normalize_url("https://$domain/Org/Pkg.jl.git") == "ssh://git@$domain/Org/Pkg.jl.git"

        # The former positional API remains callable, but points callers at
        # the keyword form through the standard deprecation mechanism. Like
        # upstream, that old shape controls the default github.com domain.
        @test_deprecated VibePkg.setprotocol!("https")
        @test Git.normalize_url("git@$default_domain:Org/Pkg.jl.git") == "https://$default_domain/Org/Pkg.jl.git"
        @test_deprecated Git.setprotocol!("ssh")
        @test Git.normalize_url("https://$default_domain/Org/Pkg.jl.git") == "ssh://git@$default_domain/Org/Pkg.jl.git"

        # nothing delegates the choice back to the url author
        VibePkg.setprotocol!(domain = domain, protocol = nothing)
        @test Git.normalize_url("git@$domain:Org/Pkg.jl.git") == "git@$domain:Org/Pkg.jl.git"

        # other domains are unaffected
        VibePkg.setprotocol!(domain = domain, protocol = "https")
        @test Git.normalize_url("git@other.host:Org/Pkg.jl.git") == "git@other.host:Org/Pkg.jl.git"
    finally
        delete!(Git.GIT_PROTOCOLS, domain)
        delete!(Git.GIT_USERS, domain)
        had_default_protocol ?
            (Git.GIT_PROTOCOLS[default_domain] = old_default_protocol) :
            delete!(Git.GIT_PROTOCOLS, default_domain)
        had_default_user ?
            (Git.GIT_USERS[default_domain] = old_default_user) :
            delete!(Git.GIT_USERS, default_domain)
    end
end

@testset "activate - and activate(dep name)" begin
    # the env snapshot canonicalizes /var → /private/var on macOS
    canon(p) = joinpath(realpath(dirname(p)), basename(p))
    with_temp_world() do dir, envdir
        old_prev = API.PREV_ENV_PATH[]
        try
            # with no previous environment `activate -` errors
            API.PREV_ENV_PATH[] = ""
            @test_throws PkgError VibePkg.activate("-"; io = devnull)

            env2 = mkpath(joinpath(dir, "env2"))
            first_active = canon(Base.active_project())
            VibePkg.activate(env2; io = devnull)
            @test canon(Base.active_project()) == canon(joinpath(env2, "Project.toml"))
            # back to the previous environment, and `-` toggles
            VibePkg.activate("-"; io = devnull)
            @test canon(Base.active_project()) == first_active
            VibePkg.activate("-"; io = devnull)
            @test canon(Base.active_project()) == canon(joinpath(env2, "Project.toml"))
            VibePkg.activate("-"; io = devnull)

            # activate(s) where `s` names a path-tracked dep activates that path
            devved = joinpath(dir, "Devved")
            mkpath(joinpath(devved, "src"))
            write(
                joinpath(devved, "Project.toml"), """
                name = "Devved"
                uuid = "bbbbbbbb-cccc-dddd-eeee-ffff00001111"
                version = "0.1.0"
                """
            )
            write(joinpath(devved, "src", "Devved.jl"), "module Devved end")
            VibePkg.develop(path = devved, io = devnull)
            VibePkg.activate("Devved"; io = devnull)
            @test canon(Base.active_project()) == canon(joinpath(devved, "Project.toml"))
            # Resolution by dependency name is anchored to the active
            # manifest, not the caller's cwd.
            VibePkg.activate("-"; io = devnull)
            elsewhere = mkpath(joinpath(dir, "elsewhere"))
            cd(elsewhere) do
                VibePkg.activate("Devved"; io = devnull)
                @test canon(Base.active_project()) == canon(joinpath(devved, "Project.toml"))
            end

            # A registered, non-developed dependency is deliberately not
            # activated from its package-store source. Its name remains an
            # ordinary relative path, just like any non-dependency name.
            VibePkg.activate(envdir; io = devnull)
            VibePkg.add("Example"; io = devnull)
            cd(envdir) do
                VibePkg.activate("Example"; io = devnull)
                @test normpath(Base.active_project()) ==
                    joinpath(realpath(envdir), "Example", "Project.toml")
            end
        finally
            API.PREV_ENV_PATH[] = old_prev
        end
    end
end

@testset "precompile accepts packages and options" begin
    with_temp_world() do dir, envdir
        # empty environment: a no-op precompile with every option exercised
        @test VibePkg.precompile(; strict = true, timing = true, io = devnull) === nothing
        @test hasmethod(VibePkg.precompile, Tuple{Vector{String}})
        @test hasmethod(VibePkg.precompile, Tuple{String})
    end
end

@testset "artifact creation API: create/bind/unbind" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        old_depots = copy(Base.DEPOT_PATH)
        try
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])

            hash = VibePkg.Artifacts.create_artifact() do adir
                write(joinpath(adir, "data.txt"), "artifact payload")
            end
            @test hash isa SHA1
            tree = joinpath(depot, "artifacts", string(hash))
            @test isdir(tree)
            @test read(joinpath(tree, "data.txt"), String) == "artifact payload"
            @test VibePkg.Artifacts.verify_artifact(hash)
            # identical content maps to the identical artifact
            hash2 = VibePkg.Artifacts.create_artifact() do adir
                write(joinpath(adir, "data.txt"), "artifact payload")
            end
            @test hash2 == hash

            toml = joinpath(dir, "Artifacts.toml")
            VibePkg.Artifacts.bind_artifact!(toml, "myart", hash)
            @test VibePkg.Artifacts.artifact_hash("myart", toml) == hash
            # rebinding requires force
            @test_throws PkgError VibePkg.Artifacts.bind_artifact!(toml, "myart", hash)
            other = VibePkg.Artifacts.create_artifact(adir -> write(joinpath(adir, "x"), "y"))
            VibePkg.Artifacts.bind_artifact!(toml, "myart", other; force = true)
            @test VibePkg.Artifacts.artifact_hash("myart", toml) == other

            # lazy + download stanzas render into the standard layout
            VibePkg.Artifacts.bind_artifact!(
                toml, "lazyart", hash;
                lazy = true,
                download_info = [("https://example.invalid/a.tar.gz", "ab"^32, 123)],
            )
            data = TOML.parsefile(toml)
            @test data["lazyart"]["lazy"] === true
            @test data["lazyart"]["download"][1]["url"] == "https://example.invalid/a.tar.gz"
            @test data["lazyart"]["download"][1]["sha256"] == "ab"^32
            @test data["lazyart"]["download"][1]["size"] == 123

            # platform-specific bindings coexist under one name
            linux = Platform("x86_64", "linux")
            mac = Platform("aarch64", "macos")
            VibePkg.Artifacts.bind_artifact!(toml, "platart", hash; platform = linux)
            VibePkg.Artifacts.bind_artifact!(toml, "platart", other; platform = mac)
            @test VibePkg.Artifacts.artifact_hash("platart", toml; platform = linux) == hash
            @test VibePkg.Artifacts.artifact_hash("platart", toml; platform = mac) == other
            # same-platform rebind without force errors
            @test_throws PkgError VibePkg.Artifacts.bind_artifact!(toml, "platart", other; platform = linux)

            # unbind: platform-specific first, then the whole name
            VibePkg.Artifacts.unbind_artifact!(toml, "platart"; platform = linux)
            @test VibePkg.Artifacts.artifact_hash("platart", toml; platform = linux) === nothing
            @test VibePkg.Artifacts.artifact_hash("platart", toml; platform = mac) == other
            VibePkg.Artifacts.unbind_artifact!(toml, "myart")
            @test VibePkg.Artifacts.artifact_hash("myart", toml) === nothing
            # unbinding a missing name is silently ignored
            VibePkg.Artifacts.unbind_artifact!(toml, "neverbound")
        finally
            append!(empty!(Base.DEPOT_PATH), old_depots)
        end
    end
end

@testset "auth error handler hooks" begin
    mktempdir() do depot
        d = depot_stack([depot])
        server = "https://pkg.example.org"
        authfile = joinpath(depot, "servers", "pkg.example.org", "auth.toml")
        seen = String[]
        dereg = Fetch.register_auth_error_handler(
            "pkg.example.org", (url, pkgserver, err) -> begin
                push!(seen, err)
                # the handler provisions credentials and asks for a retry
                mkpath(dirname(authfile))
                write(authfile, "access_token = \"tok-from-handler\"\n")
                (true, true)
            end
        )
        try
            @test Fetch.get_auth_token(d, server) == "tok-from-handler"
            @test seen == ["no-auth-file"]

            # a non-matching url scheme leaves the failure unhandled
            Base.rm(authfile)
            @test Fetch.get_auth_token(d, "https://other.example.org") === nothing
            @test seen == ["no-auth-file"]

            # deregistration via the returned function
            dereg()
            @test isempty(Fetch.AUTH_ERROR_HANDLERS)
            @test Fetch.get_auth_token(d, server) === nothing
            @test seen == ["no-auth-file"]
        finally
            dereg()
        end
    end
end

# Minimal HTTP server for the 401 story: /auth.toml serves the refresh
# response; /package/x requires the freshest bearer token and otherwise
# answers 401 with a diagnostic body.
function start_401_server(dir::String, accepted::Ref{String})
    port, server = Sockets.listenany(Sockets.localhost, 42000)
    @async while isopen(server)
        sock = try
            accept(server)
        catch
            break
        end
        @async try
            request = readline(sock)
            auth = ""
            while true
                line = readline(sock)
                isempty(strip(line)) && break
                m = match(r"^authorization:\s*(.*)$"i, line)
                m === nothing || (auth = strip(m[1]))
            end
            parts = split(request)
            target = length(parts) >= 2 ? String(parts[2]) : ""
            respond(status, body) = (
                write(sock, "HTTP/1.1 $status\r\nContent-Length: $(sizeof(body))\r\nConnection: close\r\n\r\n");
                write(sock, body)
            )
            if target == "/auth.toml"
                respond("200 OK", read(joinpath(dir, "auth.toml"), String))
            elseif target == "/package/x"
                if auth == "Bearer $(accepted[])"
                    respond("200 OK", "PKGDATA")
                else
                    respond("401 Unauthorized", "token rejected by test server")
                end
            else
                respond("404 Not Found", "")
            end
        catch
        finally
            close(sock)
        end
    end
    return "http://127.0.0.1:$(Int(port))", server
end

@testset "HTTP 401 refreshes the token and retries once" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        served = mkpath(joinpath(dir, "served"))
        accepted = Ref("fresh-token")
        url, server = start_401_server(served, accepted)
        port = split(url, ':')[end]
        try
            withenv("JULIA_PKG_SERVER" => url) do
                # host:port is sanitized for the on-disk dir name (Pkg.jl#3130)
                authdir = mkpath(joinpath(depot, "servers", Fetch.server_dirname(url)))
                # the local token looks valid but the server rejects it; the
                # refresh endpoint hands out the accepted one
                write(
                    joinpath(served, "auth.toml"), """
                    access_token = "fresh-token"
                    expires_in = 100000
                    """
                )
                write(
                    joinpath(authdir, "auth.toml"), """
                    access_token = "revoked-token"
                    refresh_token = "rtok"
                    refresh_url = "http://localhost:$port/auth.toml"
                    expires_at = $(floor(Int, time()) + 100_000)
                    """
                )
                dest = joinpath(dir, "dl")
                Fetch.download("$url/package/x", dest; depots = d, io = devnull)
                @test read(dest, String) == "PKGDATA"
                # the refreshed credentials were persisted
                @test TOML.parsefile(joinpath(authdir, "auth.toml"))["access_token"] == "fresh-token"

                # a refresh that still yields a rejected token: the second
                # 401 surfaces the server's response body
                accepted[] = "unobtainable"
                err = try
                    Fetch.download("$url/package/x", joinpath(dir, "dl2"); depots = d, io = devnull)
                    nothing
                catch e
                    e
                end
                @test err isa PkgError
                @test occursin("401", err.msg)
                @test occursin("token rejected by test server", err.msg)
            end
        finally
            close(server)
        end
    end
end

# the Authorization header must go only to the package server itself: a raw
# prefix match would also send the bearer token to attacker-chosen sibling
# hosts (e.g. a malicious artifact url `https://pkg.server.evil.tld/...`)
@testset "auth headers stop at the server boundary" begin
    server = "https://pkg.example.org"
    @test Fetch.url_is_pkg_server(server, server)
    @test Fetch.url_is_pkg_server("$server/registries", server)
    @test Fetch.url_is_pkg_server("$server/artifact/abc", server)
    # sibling-domain prefixes must not match
    @test !Fetch.url_is_pkg_server("https://pkg.example.org.evil.tld/artifact/abc", server)
    @test !Fetch.url_is_pkg_server("https://pkg.example.orgx/artifact/abc", server)
    # same host but a different scheme or port is a different server
    @test !Fetch.url_is_pkg_server("http://pkg.example.org/artifact/abc", server)
    @test !Fetch.url_is_pkg_server("https://pkg.example.org:8080/artifact/abc", server)
    # userinfo tricks do not reach the host either
    @test !Fetch.url_is_pkg_server("https://pkg.example.org@evil.tld/artifact/abc", server)
    # a server url with a path component keeps its own boundary
    @test Fetch.url_is_pkg_server("https://example.org/pkg/registries", "https://example.org/pkg")
    @test !Fetch.url_is_pkg_server("https://example.org/pkgevil/x", "https://example.org/pkg")

    # end-to-end: download() attaches credentials to server urls only
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        port, tcpserver = Sockets.listenany(Sockets.ip"127.0.0.1", 40000)
        received = Channel{String}(Inf)   # auth header per request, "" if absent
        srv = errormonitor(
            @async while isopen(tcpserver)
                sock = try
                    Sockets.accept(tcpserver)
                catch
                    break
                end
                @async try
                    readline(sock)  # request line
                    auth = ""
                    while true
                        line = readline(sock)
                        isempty(strip(line)) && break
                        m = match(r"^authorization:\s*(.*)$"i, line)
                        m === nothing || (auth = String(strip(m[1])))
                    end
                    put!(received, auth)
                    body = "OK"
                    write(sock, "HTTP/1.1 200 OK\r\nContent-Length: $(sizeof(body))\r\nConnection: close\r\n\r\n")
                    write(sock, body)
                catch
                finally
                    close(sock)
                end
            end
        )
        url = "http://127.0.0.1:$(Int(port))/pkg"
        try
            withenv("JULIA_PKG_SERVER" => url) do
                authdir = mkpath(joinpath(depot, "servers", Fetch.server_dirname(url)))
                write(
                    joinpath(authdir, "auth.toml"), """
                    access_token = "secret-token"
                    expires_at = $(floor(Int, time()) + 100_000)
                    """
                )
                # a real server url carries the token
                Fetch.download("$url/x", joinpath(dir, "dl1"); depots = d, io = devnull)
                @test take!(received) == "Bearer secret-token"
                # a prefix-matching sibling path must not
                Fetch.download("$(url)evil/x", joinpath(dir, "dl2"); depots = d, io = devnull)
                @test take!(received) == ""
            end
        finally
            close(tcpserver)
            wait(srv)
        end
    end
end
