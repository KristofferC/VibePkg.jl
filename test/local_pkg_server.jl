# A fully local package server for the test suite: the pkg-server protocol
# (four static GET endpoints) served over a Sockets-stdlib HTTP listener,
# backed by GENERATED fixtures — a synthetic "General" registry (real
# General uuid) containing Example (real Example uuid) at versions
# 0.5.0–0.5.5, package tarballs built from generated sources, and a local
# git repository with one tagged commit per version for add-by-url flows.
#
# Nothing is ever downloaded: tree hashes are computed from the generated
# trees, so VibePkg verifies everything against our own hashes. `ensure!()`
# additionally points
# `http_proxy`/`https_proxy` at a dead port (with localhost exempted) so any
# stray request to the real internet fails loudly instead of silently
# passing on a developer machine.
module LocalPkgServer

using Sockets
using LibGit2
import Tar
import TOML
import p7zip_jll
using Base: SHA1, UUID
using VibePkg.TreeHash: tree_hash

const EXAMPLE_UUID = "7876af07-990d-54b4-ab0e-23690620f79a"
const GENERAL_UUID = "23338594-aafe-5451-b93e-139f81909106"
const VERSIONS = ["0.5.0", "0.5.1", "0.5.2", "0.5.3", "0.5.4", "0.5.5"]

const STATE = Ref{Any}(nothing)
const ISOLATED = Ref(false)
const DEPOT_SEP = Sys.iswindows() ? ';' : ':'

# per-run temp depot, NOT inside the package directory (which may be
# read-only); shared across processes via the inherited env var. realpath:
# depot paths end up in manifests and are compared byte-for-byte, and on
# macOS tempdirs live behind the /var → /private/var symlink
test_depot() = get!(() -> realpath(mktempdir(; prefix = "vibepkg_test_depot_")), ENV, "VIBEPKG_TEST_DEPOT")

# the strict stack every test operation runs under: the per-run test depot
# for writes plus the julia install's own depots
# for the shipped stdlib caches — the user depot is not in it
strict_depots() = [
    test_depot(),
    abspath(Sys.BINDIR, "..", "local", "share", "julia"),
    abspath(Sys.BINDIR, "..", "share", "julia"),
]

# the loose stack a julia process needs to BOOT with the package under
# test: test depot first (all writes land there), then the default depots —
# explicitly, because a trailing empty entry in JULIA_DEPOT_PATH does NOT
# re-add the user depot — so VibePkg's dependency sources and artifacts
# (which live in the user depot) resolve. Only used for process startup,
# never for running tests.
worker_depot_path() = join(
    [test_depot(); joinpath(homedir(), ".julia"); Base.append_bundled_depot_path!(String[])],
    DEPOT_SEP,
)

"""
    isolate!()

Make this process's ambient depot stack independent of the user's depot:
`Base.DEPOT_PATH` becomes the strict test stack (so every in-process
operation reads and writes only there), and `JULIA_DEPOT_PATH` is exported
likewise so subprocesses spawned BY TESTS inherit the same isolation.
Also installs the dead-proxy hermeticity guard. Idempotent per sandbox.

Processes that still need to LOAD VibePkg (whose dependency sources live
in the user depot) must boot on `worker_depot_path()` and call this only
after loading — which is what the test runner arranges.
"""
function isolate!()
    ISOLATED[] && return
    guard_proxies!()
    stack = strict_depots()
    ENV["JULIA_DEPOT_PATH"] = join(stack, DEPOT_SEP)
    append!(empty!(Base.DEPOT_PATH), stack)
    # the shared test depot never carries a gc stamp, so the first mutating
    # op of every test file would otherwise trigger an auto-gc (races with
    # parallel workers and pollutes pinned op output); gc tests opt back in
    # with withenv
    ENV["JULIA_PKG_GC_AUTO"] = "false"
    # every mutating op would otherwise spawn precompile workers over the
    # fixture envs (Pkg's suite disables this the same way); tests that
    # want auto-precompile opt back in with withenv
    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "false"
    ISOLATED[] = true
    return
end

function write_example!(dir::String, v::String)
    mkpath(joinpath(dir, "src"))
    write(
        joinpath(dir, "Project.toml"), """
        name = "Example"
        uuid = "$EXAMPLE_UUID"
        version = "$v"
        """
    )
    write(
        joinpath(dir, "src", "Example.jl"), """
        module Example
        # synthetic test fixture, version $v

        hello(who::String) = "Hello, \$who"
        domath(x::Number) = x + 5

        end
        """
    )
    return dir
end

function gzip_tarball(src_dir::String, dest::String)
    mkpath(dirname(dest))
    tarball = dest * ".tar"
    Tar.create(src_dir, tarball)
    # 7z appends .gz when the archive name has no extension — name it
    # explicitly and move into place (endpoints are extensionless)
    run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $(dest * ".gz") $tarball`; stdout = devnull))
    Base.rm(tarball; force = true)
    mv(dest * ".gz", dest)
    return dest
end

# one commit + tag per version; only ever modifies the same two files, so
# the worktree at each tag is exactly the generated package tree
function commit_tree_hash(repo::LibGit2.GitRepo, commit::LibGit2.GitHash)
    return LibGit2.with(LibGit2.GitCommit(repo, commit)) do commit_obj
        LibGit2.with(LibGit2.peel(LibGit2.GitTree, commit_obj)) do tree
            string(LibGit2.GitHash(tree))
        end
    end
end

function make_git_repo!(repo_dir::String)
    repo = LibGit2.init(repo_dir)
    sig = LibGit2.Signature("fixture", "fixture@localhost")
    version_hashes = Dict{String, String}()
    for v in VERSIONS
        write_example!(repo_dir, v)
        LibGit2.add!(repo, "Project.toml", "src/Example.jl")
        commit = LibGit2.commit(repo, "Example v$v"; author = sig, committer = sig)
        LibGit2.tag_create(repo, "v$v", string(commit); msg = "v$v", sig)
        version_hashes[v] = commit_tree_hash(repo, commit)
    end
    close(repo)
    return repo_dir, version_hashes
end

function generate_fixtures(dir::String)
    files = mkpath(joinpath(dir, "files"))

    # package trees + tarballs, hashed from what we generate
    packages = Dict{String, String}()
    for v in VERSIONS
        pkg = write_example!(mkpath(joinpath(dir, "pkgs", v)), v)
        packages[v] = pkg
    end

    git_repo, version_hashes = make_git_repo!(mkpath(joinpath(dir, "Example.jl")))
    for v in VERSIONS
        gzip_tarball(
            packages[v], joinpath(files, "package", EXAMPLE_UUID, version_hashes[v]),
        )
    end

    # the registry: a synthetic "General" so default-registry bootstrap in
    # both clients finds it without special-casing
    reg = mkpath(joinpath(dir, "registry"))
    write(
        joinpath(reg, "Registry.toml"), """
        name = "General"
        uuid = "$GENERAL_UUID"
        repo = "https://example.invalid/General"
        description = "synthetic test registry"

        [packages]
        $EXAMPLE_UUID = { name = "Example", path = "E/Example" }
        """
    )
    pkg_dir = mkpath(joinpath(reg, "E", "Example"))
    # Let the TOML writer escape native Windows separators in the local repo
    # path (`C:\\...`); interpolating it into a basic string makes `\\U` an
    # invalid TOML Unicode escape.
    open(joinpath(pkg_dir, "Package.toml"), "w") do io
        TOML.print(
            io, Dict(
                "name" => "Example",
                "uuid" => EXAMPLE_UUID,
                "repo" => git_repo,
            )
        )
    end
    write(
        joinpath(pkg_dir, "Versions.toml"),
        join(("[\"$v\"]\ngit-tree-sha1 = \"$(version_hashes[v])\"\n" for v in VERSIONS), "\n")
    )
    registry_hash = bytes2hex(tree_hash(reg))
    gzip_tarball(reg, joinpath(files, "registry", GENERAL_UUID, registry_hash))
    write(joinpath(files, "registries"), "/registry/$GENERAL_UUID/$registry_hash\n")

    return (; files, git_repo, version_hashes, registry_hash)
end

sanitized(path::AbstractString) = !occursin("..", path) && !occursin('\0', path)

function handle_connection(sock, files::String)
    try
        request = readline(sock)
        while !isempty(readline(sock))   # drain headers
        end
        parts = split(request)
        target = length(parts) >= 2 ? String(parts[2]) : ""
        file = joinpath(files, lstrip(target, '/'))
        body = (sanitized(target) && !isempty(target) && isfile(file)) ? read(file) : nothing
        if body === nothing
            write(sock, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        else
            write(sock, "HTTP/1.1 200 OK\r\nContent-Length: $(length(body))\r\nConnection: close\r\n\r\n")
            write(sock, body)
        end
    catch
        # broken pipe etc. — client went away, nothing to do
    finally
        close(sock)
    end
    return
end

function start_server(files::String)
    port, server = Sockets.listenany(Sockets.localhost, 40000)
    task = @async while isopen(server)
        sock = try
            accept(server)
        catch
            break
        end
        @async handle_connection(sock, files)
    end
    return (; url = "http://127.0.0.1:$(Int(port))", server, task)
end

"""
    ensure!() -> (; url, git_repo, version_hashes, registry_hash)

Generate the fixtures and start the local package server once, point
`JULIA_PKG_SERVER` at it, and block non-local HTTP via a dead proxy.
Idempotent, and shared ACROSS processes: a parent that already runs a
server (e.g. the parallel test runner's main process) publishes its fixture
directory in `VIBEPKG_TEST_FIXTURES`, and children reuse the live server
instead of starting their own.
"""
function ensure!()
    STATE[] === nothing || return STATE[]
    isolate!()
    # a parent process (test runner) already serves the fixtures
    parent_dir = get(ENV, "VIBEPKG_TEST_FIXTURES", "")
    if !isempty(parent_dir) && isfile(joinpath(parent_dir, "fixtures.toml"))
        t = TOML.parsefile(joinpath(parent_dir, "fixtures.toml"))
        STATE[] = (;
            url = t["url"]::String, git_repo = t["git_repo"]::String,
            version_hashes = Dict{String, String}(t["version_hashes"]),
            registry_hash = t["registry_hash"]::String,
        )
        ENV["JULIA_PKG_SERVER"] = STATE[].url
        return STATE[]
    end
    # realpath: Pkg canonicalizes repo paths (macOS /var → /private/var), so
    # fixture paths must already be canonical for byte-equal comparisons
    dir = realpath(mktempdir())
    fx = generate_fixtures(dir)
    srv = start_server(fx.files)
    ENV["JULIA_PKG_SERVER"] = srv.url
    open(joinpath(dir, "fixtures.toml"), "w") do io
        TOML.print(
            io, Dict(
                "url" => srv.url, "git_repo" => fx.git_repo,
                "version_hashes" => fx.version_hashes,
                "registry_hash" => fx.registry_hash,
            )
        )
    end
    ENV["VIBEPKG_TEST_FIXTURES"] = dir
    atexit(() -> close(srv.server))
    STATE[] = (; srv.url, fx.git_repo, fx.version_hashes, fx.registry_hash)
    return STATE[]
end

# hermeticity guard: anything that isn't the local server fails fast
function guard_proxies!()
    ENV["http_proxy"] = ENV["https_proxy"] = "http://127.0.0.1:9"
    ENV["no_proxy"] = "127.0.0.1,localhost"
    return
end

end # module
