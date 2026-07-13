# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: SHA1
using Base.BinaryPlatforms: HostPlatform, os, arch, triplet
using VibePkg
using VibePkg.Configs: Config
import Tar
import p7zip_jll
import TOML
using Logging
using SHA: sha256
using VibePkg.Depots: depot_stack
using VibePkg.ArtifactOps
using VibePkg.TreeHash
using VibePkg.Errors: PkgError
using VibePkg.Environments: load_environment
using VibePkg.Execution: instantiate!
using VibePkg.Registries: RegistryInstance

# fixture builder shared by the testsets below: content dir → tar → gzip
function make_gz_artifact(dir::String, label::String; payload::String = "$label payload\n")
    content = mkpath(joinpath(dir, label))
    write(joinpath(content, "$label.txt"), payload)
    hash = SHA1(tree_hash(content))
    tarball = joinpath(dir, "$label.tar")
    Tar.create(content, tarball)
    gz = joinpath(dir, "$label.tar.gz")
    run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $gz $tarball`; stdout = devnull))
    return (; hash, gz, sha = bytes2hex(open(sha256, gz)))
end

# expected-failure paths @warn on purpose; keep the test output clean
quietly(f) = Logging.with_logger(f, Logging.NullLogger())

# Keep generated TOML portable: a raw Windows path contains backslashes that
# TOML basic strings interpret as escapes.  File URLs additionally need a
# leading slash before a drive letter (`file:///C:/...`).
toml_path(path::AbstractString) = replace(path, '\\' => '/')
function file_url(path::AbstractString)
    path = toml_path(path)
    startswith(path, '/') || (path = "/$path")
    return "file://$path"
end

@testset "ArtifactOps" begin
    mktempdir() do dir
        # build an artifact: content dir → tar → gzip, served via file://
        content = mkpath(joinpath(dir, "content"))
        write(joinpath(content, "data.txt"), "artifact payload\n")
        mkpath(joinpath(content, "bin"))
        write(joinpath(content, "bin", "tool"), "#!/bin/sh\necho hi\n")
        chmod(joinpath(content, "bin", "tool"), 0o755)
        hash = SHA1(tree_hash(content))

        tarball = joinpath(dir, "artifact.tar")
        Tar.create(content, tarball)
        gz = joinpath(dir, "artifact.tar.gz")
        run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $gz $tarball`; stdout = devnull))
        sha = bytes2hex(open(sha256, gz))

        # a package that declares it (plus a lazy one that must be skipped)
        pkg = mkpath(joinpath(dir, "MyPkg"))
        write(
            joinpath(pkg, "Artifacts.toml"), """
            [payload]
            git-tree-sha1 = "$hash"

                [[payload.download]]
                url = "$(file_url(gz))"
                sha256 = "$sha"

            [lazystuff]
            git-tree-sha1 = "1111111111111111111111111111111111111111"
            lazy = true

                [[lazystuff.download]]
                url = "file:///nonexistent"
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        new_names = ensure_artifacts_installed!(depots, pkg; server = nothing, io = devnull)
        @test new_names == ["payload"]

        path, installed = artifact_tree_path(depots, hash)
        @test installed
        @test read(joinpath(path, "data.txt"), String) == "artifact payload\n"
        @test SHA1(tree_hash(path)) == hash
        # usage logged for gc
        @test isfile(joinpath(depot, "logs", "artifact_usage.toml"))
        # idempotent
        @test isempty(ensure_artifacts_installed!(depots, pkg; server = nothing, io = devnull))

        # overrides suppress downloads entirely (bogus source would fail)
        pkg2 = mkpath(joinpath(dir, "OverriddenPkg"))
        ov_hash = "9999999999999999999999999999999999999999"
        write(
            joinpath(pkg2, "Artifacts.toml"), """
            [blob]
            git-tree-sha1 = "$ov_hash"

                [[blob.download]]
                url = "file:///nonexistent"
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
            """
        )
        override_dir = mkpath(joinpath(dir, "override-content"))
        pkg2_uuid = Base.UUID("99999999-9999-9999-9999-999999999999")
        write(
            joinpath(depot, "artifacts", "Overrides.toml"), """
            $ov_hash = "$(toml_path(override_dir))"
            """
        )
        @test isempty(ensure_artifacts_installed!(depots, pkg2; pkg_uuid = pkg2_uuid, server = nothing, io = devnull))
        # uuid/name form works too (this was a Pkg quirk: it did NOT suppress)
        write(
            joinpath(depot, "artifacts", "Overrides.toml"), """
            [$pkg2_uuid]
            blob = "$(toml_path(override_dir))"
            """
        )
        @test isempty(ensure_artifacts_installed!(depots, pkg2; pkg_uuid = pkg2_uuid, server = nothing, io = devnull))

        # auth/header construction is pure and complete
        headers = Dict(
            VibePkg.Fetch.pkg_server_headers(
                "https://pkg.julialang.org";
                env = Dict("CI" => "true", "JULIA_PKG_SERVER_REGISTRY_PREFERENCE" => "eager"),
                interactive = false,
            )
        )
        @test headers["Julia-Pkg-Protocol"] == "1.0"
        @test occursin("CI=t", headers["Julia-CI-Variables"])
        @test headers["Julia-Registry-Preference"] == "eager"
        @test headers["Julia-Interactive"] == "false"
        @test !haskey(headers, "Authorization")
        # a valid auth.toml adds a bearer token
        auth_dir = mkpath(joinpath(depot, "servers", "pkg.julialang.org"))
        write(joinpath(auth_dir, "auth.toml"), "access_token = \"sekrit\"\n")
        headers = Dict(VibePkg.Fetch.pkg_server_headers("https://pkg.julialang.org"; depots, env = Dict{String, String}()))
        @test headers["Authorization"] == "Bearer sekrit"
    end
end

@testset "JULIA_PKG_IGNORE_HASHES" begin
    mktempdir() do dir
        art = make_gz_artifact(dir, "mismatch")
        wrong = SHA1("f"^40)
        pkg = mkpath(joinpath(dir, "MismatchPkg"))
        write(
            joinpath(pkg, "Artifacts.toml"), """
            [blob]
            git-tree-sha1 = "$wrong"

                [[blob.download]]
                url = "$(file_url(art.gz))"
                sha256 = "$(art.sha)"
            """
        )

        # default: the tree-hash mismatch fails the source, and the install
        depot = mkpath(joinpath(dir, "depot1"))
        quietly() do
            @test_throws PkgError ensure_artifacts_installed!(
                depot_stack([depot]), pkg; server = nothing, io = devnull,
            )
        end

        # env set: downgraded to a warning, artifact lands at the declared hash
        depots2 = depot_stack([mkpath(joinpath(dir, "depot2"))])
        withenv("JULIA_PKG_IGNORE_HASHES" => "1") do
            quietly() do
                @test ensure_artifacts_installed!(depots2, pkg; server = nothing, io = devnull) == ["blob"]
            end
        end
        path, installed = artifact_tree_path(depots2, wrong)
        @test installed
        @test read(joinpath(path, "mismatch.txt"), String) == "mismatch payload\n"

        # the env parse rules
        adir = mkpath(joinpath(dir, "adir"))
        withenv("JULIA_PKG_IGNORE_HASHES" => "true") do
            @test ArtifactOps.ignore_hashes(adir)
        end
        withenv("JULIA_PKG_IGNORE_HASHES" => "0") do
            @test !ArtifactOps.ignore_hashes(adir)
        end
        withenv("JULIA_PKG_IGNORE_HASHES" => "sideways") do   # invalid: @error, then off
            @test_logs (:error, r"Invalid ENV") @test !ArtifactOps.ignore_hashes(adir)
        end
        if !Sys.iswindows()
            withenv("JULIA_PKG_IGNORE_HASHES" => nothing) do
                @test !ArtifactOps.ignore_hashes(adir)
            end
        end
    end
end

# Pkg.Artifacts-compatible namespace: lazy artifacts install on demand
@testset "VibePkg.Artifacts (lazy on demand)" begin
    mktempdir() do dir
        content = mkpath(joinpath(dir, "lazycontent"))
        write(joinpath(content, "lazy.txt"), "lazy payload\n")
        hash = SHA1(tree_hash(content))
        tarball = joinpath(dir, "lazy.tar")
        Tar.create(content, tarball)
        gz = joinpath(dir, "lazy.tar.gz")
        run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $gz $tarball`; stdout = devnull))
        sha = bytes2hex(open(sha256, gz))

        pkg = mkpath(joinpath(dir, "LazyPkg"))
        atoml = joinpath(pkg, "Artifacts.toml")
        write(
            atoml, """
            [lazything]
            git-tree-sha1 = "$hash"
            lazy = true

                [[lazything.download]]
                url = "$(file_url(gz))"
                sha256 = "$sha"
            """
        )

        depot = mkpath(joinpath(dir, "depot"))
        depots = depot_stack([depot])
        # instantiate-time collection skips lazy entries; include_lazy selects them
        @test isempty(ArtifactOps.collect_artifact_installs(depots, pkg))
        @test length(ArtifactOps.collect_artifact_installs(depots, pkg; include_lazy = true)) == 1

        # the on-demand entry point (what lazy loading bottoms out in) uses
        # the session depots — point them at the temp depot
        pushfirst!(Base.DEPOT_PATH, depot)
        try
            withenv("JULIA_PKG_SERVER" => "") do
                A = VibePkg.Artifacts
                @test !A.artifact_exists(hash)
                path = A.ensure_artifact_installed("lazything", atoml; io = devnull)
                @test isdir(path)
                @test read(joinpath(path, "lazy.txt"), String) == "lazy payload\n"
                @test A.artifact_exists(hash)
                @test A.verify_artifact(hash)
                @test A.artifact_path(hash) == path
                # second call is a cheap no-op returning the same path
                @test A.ensure_artifact_installed("lazything", atoml; io = devnull) == path
                A.remove_artifact(hash)
                @test !A.artifact_exists(hash)
                @test !A.verify_artifact(hash)
            end
        finally
            popfirst!(Base.DEPOT_PATH)
        end
    end
end

# `[[name]]` array-of-tables entries with os/arch keys: selection (delegated
# to select_downloadable_artifacts with HostPlatform) picks the host's entry
@testset "platform-keyed artifact selection" begin
    mktempdir() do dir
        hp = HostPlatform()
        other_os = os(hp) == "linux" ? "macos" : "linux"
        art = make_gz_artifact(dir, "platbin")
        nonmatch_hash = SHA1("2222222222222222222222222222222222222222")
        pkg = mkpath(joinpath(dir, "PlatPkg"))
        write(
            joinpath(pkg, "Artifacts.toml"), """
            [[platbin]]
            git-tree-sha1 = "$(art.hash)"
            os = "$(os(hp))"
            arch = "$(arch(hp))"

                [[platbin.download]]
                url = "$(file_url(art.gz))"
                sha256 = "$(art.sha)"

            [[platbin]]
            git-tree-sha1 = "$nonmatch_hash"
            os = "$other_os"
            arch = "$(arch(hp))"

                [[platbin.download]]
                url = "file:///nonexistent"
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        installs = ArtifactOps.collect_artifact_installs(d, pkg)
        @test length(installs) == 1
        name, meta = installs[1]
        @test name == "platbin"
        @test SHA1(meta["git-tree-sha1"]) == art.hash
        # and installing goes through the matching entry only
        @test ensure_artifacts_installed!(d, pkg; server = nothing, io = devnull) == ["platbin"]
        path, installed = artifact_tree_path(d, art.hash)
        @test installed
        @test read(joinpath(path, "platbin.txt"), String) == "platbin payload\n"
        @test !artifact_tree_path(d, nonmatch_hash)[2]
    end
end

# source ordering + verification: a 404 first source falls through to the
# second; sha256 and tree-hash mismatches reject the download entirely
@testset "download fallback and rejection" begin
    mktempdir() do dir
        served = mkpath(joinpath(dir, "served"))
        art = make_gz_artifact(dir, "fallback")
        cp(art.gz, joinpath(served, "fallback.tar.gz"))
        srv = LocalPkgServer.start_server(served)
        try
            depot = mkpath(joinpath(dir, "depot"))
            d = depot_stack([depot])

            # (a) the first URL 404s → the second download entry is used
            pkg = mkpath(joinpath(dir, "FallbackPkg"))
            write(
                joinpath(pkg, "Artifacts.toml"), """
                [fb]
                git-tree-sha1 = "$(art.hash)"

                    [[fb.download]]
                    url = "$(srv.url)/missing.tar.gz"
                    sha256 = "$(art.sha)"

                    [[fb.download]]
                    url = "$(srv.url)/fallback.tar.gz"
                    sha256 = "$(art.sha)"
                """
            )
            @test ensure_artifacts_installed!(d, pkg; server = nothing, io = devnull) == ["fb"]
            path, installed = artifact_tree_path(d, art.hash)
            @test installed
            @test read(joinpath(path, "fallback.txt"), String) == "fallback payload\n"

            # (b) a download whose sha256 doesn't match is rejected
            bad = make_gz_artifact(dir, "badsha")
            cp(bad.gz, joinpath(served, "badsha.tar.gz"))
            pkgb = mkpath(joinpath(dir, "BadShaPkg"))
            write(
                joinpath(pkgb, "Artifacts.toml"), """
                [badsha]
                git-tree-sha1 = "$(bad.hash)"

                    [[badsha.download]]
                    url = "$(srv.url)/badsha.tar.gz"
                    sha256 = "$("1"^64)"
                """
            )
            @test_throws PkgError quietly() do
                ensure_artifacts_installed!(d, pkgb; server = nothing, io = devnull)
            end
            @test !artifact_tree_path(d, bad.hash)[2]

            # (c) a tarball whose unpacked tree hash doesn't match the
            # declared git-tree-sha1 is rejected (sha256 alone is not enough)
            wrong_hash = SHA1("3333333333333333333333333333333333333333")
            pkgc = mkpath(joinpath(dir, "BadTreePkg"))
            write(
                joinpath(pkgc, "Artifacts.toml"), """
                [badtree]
                git-tree-sha1 = "$wrong_hash"

                    [[badtree.download]]
                    url = "$(srv.url)/badsha.tar.gz"
                    sha256 = "$(bad.sha)"
                """
            )
            @test_throws PkgError quietly() do
                ensure_artifacts_installed!(d, pkgc; server = nothing, io = devnull)
            end
            @test !artifact_tree_path(d, wrong_hash)[2]
        finally
            close(srv.server)
        end
    end
end

@testset "artifact stanza with no download sources" begin
    mktempdir() do dir
        pkg = mkpath(joinpath(dir, "NoSrcPkg"))
        atoml = joinpath(pkg, "Artifacts.toml")
        write(
            atoml, """
            [nosrc]
            git-tree-sha1 = "4444444444444444444444444444444444444444"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        # static selection skips download-less stanzas (local-only artifacts)…
        @test isempty(ArtifactOps.collect_artifact_installs(d, pkg))
        # …but an attempted install of such a stanza errors
        meta = TOML.parsefile(atoml)["nosrc"]
        err = @test_throws PkgError ensure_artifact_installed!(
            d, "nosrc", meta; server = nothing, io = devnull
        )
        @test occursin("no download sources", sprint(showerror, err.value))
    end
end

# a `.pkg/select_artifacts.jl` hook gets the platform triplet as ARGS[1] and
# its TOML output (not the static selection) decides what installs
@testset "select_artifacts.jl hook" begin
    mktempdir() do dir
        chosen = make_gz_artifact(dir, "chosen")
        other = make_gz_artifact(dir, "other")
        pkg = mkpath(joinpath(dir, "HookPkg"))
        write(
            joinpath(pkg, "Artifacts.toml"), """
            [chosen]
            git-tree-sha1 = "$(chosen.hash)"

                [[chosen.download]]
                url = "$(file_url(chosen.gz))"
                sha256 = "$(chosen.sha)"

            [other]
            git-tree-sha1 = "$(other.hash)"

                [[other.download]]
                url = "$(file_url(other.gz))"
                sha256 = "$(other.sha)"
            """
        )
        hook_dir = mkpath(joinpath(pkg, ".pkg"))
        write(
            joinpath(hook_dir, "select_artifacts.jl"), """
            using TOML
            write(joinpath(@__DIR__, "triplet.txt"), ARGS[1])
            toml = TOML.parsefile(joinpath(@__DIR__, "..", "Artifacts.toml"))
            TOML.print(stdout, Dict("chosen" => toml["chosen"]))
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        @test ensure_artifacts_installed!(d, pkg; server = nothing, io = devnull) == ["chosen"]
        # the hook ran and received the platform triplet as its argument
        @test read(joinpath(hook_dir, "triplet.txt"), String) == triplet(HostPlatform())
        @test artifact_tree_path(d, chosen.hash)[2]
        @test !artifact_tree_path(d, other.hash)[2]
    end
end

# Pkg.jl#1775 Pkg.jl#1338 — instantiate installs the artifacts declared by
# the manifest's packages (here a path-tracked one carrying an Artifacts.toml)
@testset "instantiate installs artifacts" begin
    mktempdir() do dir
        art = make_gz_artifact(dir, "instart")
        pkg_uuid = Base.UUID("55555555-5555-5555-5555-555555555555")
        pkg = mkpath(joinpath(dir, "ArtPkg"))
        write(
            joinpath(pkg, "Project.toml"), """
            name = "ArtPkg"
            uuid = "$pkg_uuid"
            version = "0.1.0"
            """
        )
        mkpath(joinpath(pkg, "src"))
        write(joinpath(pkg, "src", "ArtPkg.jl"), "module ArtPkg end\n")
        write(
            joinpath(pkg, "Artifacts.toml"), """
            [instart]
            git-tree-sha1 = "$(art.hash)"

                [[instart.download]]
                url = "$(file_url(art.gz))"
                sha256 = "$(art.sha)"
            """
        )
        envdir = mkpath(joinpath(dir, "env"))
        write(
            joinpath(envdir, "Project.toml"), """
            [deps]
            ArtPkg = "$pkg_uuid"
            """
        )
        write(
            joinpath(envdir, "Manifest.toml"), """
            julia_version = "$VERSION"
            manifest_format = "2.1"

            [[deps.ArtPkg]]
            path = "$(toml_path(pkg))"
            uuid = "$pkg_uuid"
            version = "0.1.0"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        env = load_environment(envdir; depots = d)
        withenv("JULIA_PKG_SERVER" => "") do
            instantiate!(env, RegistryInstance[], Config(d); io = devnull)
        end
        path, installed = artifact_tree_path(d, art.hash)
        @test installed
        @test read(joinpath(path, "instart.txt"), String) == "instart payload\n"
    end
end

# Pkg.jl#3130 — the servers/<host> dir must be a valid directory name on
# Windows: ':' in host:port maps to '_'
@testset "server dir name sanitization" begin
    mktempdir() do dir
        d = depot_stack([dir])
        path = VibePkg.Fetch.auth_file_path(d, "http://localhost:8888")
        server_dir = basename(dirname(path))
        @test server_dir == "localhost_8888"
        @test !occursin(':', server_dir)
    end
end

# auth.toml lifecycle (Fetch.get_auth_token): expiry is
# min(expires_at, mtime + expires_in); near-expired/expired tokens refresh
# through refresh_url (http://localhost is permitted, Fetch.jl:81)
@testset "auth.toml expiry and refresh" begin
    mktempdir() do dir
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        server = "https://pkg.example.org"
        authfile = joinpath(mkpath(joinpath(depot, "servers", "pkg.example.org")), "auth.toml")
        get_tok() = VibePkg.Fetch.get_auth_token(d, server)

        # (a) a token with a future expires_at is used as-is
        write(
            authfile, """
            access_token = "tok-a"
            expires_at = $(floor(Int, time()) + 100_000)
            """
        )
        @test get_tok() == "tok-a"

        # (b) expiry is min(expires_at, mtime + expires_in):
        # mtime + expires_in in the past wins over a future expires_at…
        write(
            authfile, """
            access_token = "tok-b1"
            expires_at = $(floor(Int, time()) + 100_000)
            expires_in = -10
            """
        )
        @test get_tok() === nothing
        # …a past expires_at wins over a generous expires_in…
        write(
            authfile, """
            access_token = "tok-b2"
            expires_at = $(floor(Int, time()) - 10)
            expires_in = 100000
            """
        )
        @test get_tok() === nothing
        # …and when both lie comfortably in the future the token is used
        write(
            authfile, """
            access_token = "tok-b3"
            expires_at = $(floor(Int, time()) + 100_000)
            expires_in = 100000
            """
        )
        @test get_tok() == "tok-b3"

        # (c) refresh through a local refresh_url saves the new auth.toml
        served = mkpath(joinpath(dir, "served"))
        write(
            joinpath(served, "auth.toml"), """
            access_token = "tok-fresh"
            refresh_token = "rtok-fresh"
            expires_in = 100000
            """
        )
        srv = LocalPkgServer.start_server(served)
        port = parse(Int, split(srv.url, ':')[end])
        refresh_url = "http://localhost:$port/auth.toml"
        try
            # a token inside the 10-minute early-refresh window is refreshed
            # and the fresh token returned
            write(
                authfile, """
                access_token = "tok-stale"
                refresh_token = "rtok"
                refresh_url = "$refresh_url"
                expires_at = $(floor(Int, time()) + 300)
                """
            )
            @test get_tok() == "tok-fresh"
            saved = TOML.parsefile(authfile)
            @test saved["access_token"] == "tok-fresh"
            # expires_in from the served file was converted to expires_at
            @test saved["expires_at"] >= floor(Int, time()) + 90_000

            # a fully expired token is refreshed, the new file saved, and
            # the fresh token returned by the same call (it is judged by its
            # own expiry, not the stale one that triggered the refresh)
            write(
                authfile, """
                access_token = "tok-stale2"
                refresh_token = "rtok"
                refresh_url = "$refresh_url"
                expires_at = 1
                """
            )
            @test get_tok() == "tok-fresh"
            @test TOML.parsefile(authfile)["access_token"] == "tok-fresh"
        finally
            close(srv.server)
        end
    end
end

# get_extract_cmd sniffs the zstd frame magic; everything else goes to 7z
@testset "get_extract_cmd magic bytes" begin
    mktempdir() do dir
        zst = joinpath(dir, "data.tar.zst")
        write(zst, UInt8[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x00, 0x00])
        cmd = VibePkg.Fetch.get_extract_cmd(zst)
        @test occursin("zstd", basename(cmd.exec[1]))
        @test cmd.exec[end] == zst

        gz = joinpath(dir, "data.tar.gz")
        write(gz, UInt8[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00])
        cmd = VibePkg.Fetch.get_extract_cmd(gz)
        @test occursin("7z", basename(cmd.exec[1]))
        @test cmd.exec[end] == gz

        # a file shorter than the 4-byte magic takes the 7z path too
        tiny = joinpath(dir, "tiny")
        write(tiny, UInt8[0x28, 0xb5])
        @test occursin("7z", basename(VibePkg.Fetch.get_extract_cmd(tiny).exec[1]))
    end
end

if !Sys.iswindows()
    @testset "non-ASCII symlink artifact hash compatibility" begin
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            old_depots = copy(Base.DEPOT_PATH)
            try
                append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])

                corrected = VibePkg.Artifacts.create_artifact() do path
                    symlink("schön", joinpath(path, "link"))
                end
                legacy = VibePkg.Artifacts.create_artifact(; legacy_symlink_size = true) do path
                    symlink("schön", joinpath(path, "link"))
                end

                @test corrected != legacy
                @test VibePkg.Artifacts.verify_artifact(corrected)
                @test VibePkg.Artifacts.verify_artifact(legacy)
                @test VibePkg.Artifacts.tree_hash_matches(
                    joinpath(depot, "artifacts", string(corrected)), corrected,
                )
                @test VibePkg.Artifacts.tree_hash_matches(
                    joinpath(depot, "artifacts", string(legacy)), legacy,
                )
            finally
                append!(empty!(Base.DEPOT_PATH), old_depots)
            end
        end

        mktempdir() do dir
            content = mkpath(joinpath(dir, "content"))
            symlink("schön", joinpath(content, "link"))
            legacy = SHA1(tree_hash(content; legacy_symlink_size = true))
            tarball = joinpath(dir, "artifact.tar")
            Tar.create(content, tarball)
            gz = joinpath(dir, "artifact.tar.gz")
            run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $gz $tarball`; stdout = devnull))

            dest = joinpath(dir, "installed")
            @test ArtifactOps.try_install_from(
                file_url(gz), nothing, legacy, dest; io = devnull,
            )
            @test SHA1(tree_hash(dest; legacy_symlink_size = true)) == legacy
            @test SHA1(tree_hash(dest)) != legacy
        end
    end
end
