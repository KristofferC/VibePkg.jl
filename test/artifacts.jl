# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Random
using Base: SHA1
using Base.BinaryPlatforms: HostPlatform, Platform, os, arch, triplet
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
        # Pkg.jl#4438 — the artifacts cache dir is tagged for backup tools
        @test isfile(joinpath(depot, "artifacts", "CACHEDIR.TAG"))
        # Pkg.jl artifacts.jl "File permissions" — an installed artifact tree is
        # read-only: files lose their write bits, executables keep the exec bit,
        # and directories stay traversable.
        if !Sys.iswindows()
            @test filemode(joinpath(path, "data.txt")) & 0o222 == 0     # no write bits
            tool = joinpath(path, "bin", "tool")
            @test Sys.isexecutable(tool)                                # exec bit kept
            @test filemode(tool) & 0o222 == 0                           # but read-only
            @test isdir(joinpath(path, "bin"))                          # dir traversable
        end
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

# Pkg.jl test/artifacts.jl "Artifact Usage" (line 396): one porous target
# selection must simultaneously omit a non-matching eager artifact, retain a
# platform-independent lazy artifact without installing it, and install a
# platform-independent eager artifact.
@testset "porous platform artifact installation" begin
    mktempdir() do dir
        nonmatching = make_gz_artifact(dir, "nonmatching")
        lazy_present = make_gz_artifact(dir, "lazy_present")
        portable = make_gz_artifact(dir, "portable")
        pkg = mkpath(joinpath(dir, "PorousPkg"))
        artifacts_toml = joinpath(pkg, "Artifacts.toml")
        write(
            artifacts_toml, """
            [[nonmatching]]
            git-tree-sha1 = "$(nonmatching.hash)"
            arch = "x86_64"
            os = "linux"

                [[nonmatching.download]]
                url = "$(file_url(nonmatching.gz))"
                sha256 = "$(nonmatching.sha)"

            [lazy_present]
            git-tree-sha1 = "$(lazy_present.hash)"
            lazy = true

                [[lazy_present.download]]
                url = "$(file_url(lazy_present.gz))"
                sha256 = "$(lazy_present.sha)"

            [portable]
            git-tree-sha1 = "$(portable.hash)"

                [[portable.download]]
                url = "$(file_url(portable.gz))"
                sha256 = "$(portable.sha)"
            """
        )

        bogus = Platform("bogus", "linux")
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])

        # With lazy entries included in selection, the platform-independent
        # lazy and eager entries remain visible, but the eager x86_64 entry
        # does not match the deliberately porous target.
        selected = ArtifactOps.selected_artifacts(pkg, artifacts_toml, bogus; include_lazy = true)
        @test Set(keys(selected)) == Set(["lazy_present", "portable"])
        @test VibePkg.Artifacts.artifact_hash("nonmatching", artifacts_toml; platform = bogus) === nothing
        @test VibePkg.Artifacts.artifact_hash("lazy_present", artifacts_toml; platform = bogus) == lazy_present.hash
        @test VibePkg.Artifacts.artifact_hash("portable", artifacts_toml; platform = bogus) == portable.hash

        installs = ArtifactOps.collect_artifact_installs(d, pkg; platform = bogus)
        @test only(first.(installs)) == "portable"
        @test all(!last(artifact_tree_path(d, hash)) for hash in (nonmatching.hash, lazy_present.hash, portable.hash))

        @test ensure_artifacts_installed!(d, pkg; platform = bogus, server = nothing, io = devnull) == ["portable"]
        @test !last(artifact_tree_path(d, nonmatching.hash))
        @test !last(artifact_tree_path(d, lazy_present.hash))
        portable_path, installed = artifact_tree_path(d, portable.hash)
        @test installed
        @test read(joinpath(portable_path, "portable.txt"), String) == "portable payload\n"
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
        preserved = make_gz_artifact(dir, "preserved")
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

        # Instantiation installs what the environment references, but must not
        # delete an unrelated artifact that already exists in the same depot.
        preserved_meta = Dict{String, Any}(
            "git-tree-sha1" => string(preserved.hash),
            "download" => [
                Dict{String, Any}(
                    "url" => file_url(preserved.gz),
                    "sha256" => preserved.sha,
                ),
            ],
        )
        preserved_path, preserved_new = ensure_artifact_installed!(
            d, "preserved", preserved_meta; server = nothing, io = devnull,
        )
        @test preserved_new
        @test read(joinpath(preserved_path, "preserved.txt"), String) == "preserved payload\n"
        @test SHA1(tree_hash(preserved_path)) == preserved.hash

        withenv("JULIA_PKG_SERVER" => "") do
            instantiate!(env, RegistryInstance[], Config(d); io = devnull)
        end
        path, installed = artifact_tree_path(d, art.hash)
        @test installed
        @test read(joinpath(path, "instart.txt"), String) == "instart payload\n"

        preserved_after, preserved_installed = artifact_tree_path(d, preserved.hash)
        @test preserved_installed
        @test preserved_after == preserved_path
        @test read(joinpath(preserved_after, "preserved.txt"), String) == "preserved payload\n"
        @test SHA1(tree_hash(preserved_after)) == preserved.hash
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

        # Pkg.jl#4641 — a file:// local-path pkg-server URL also produces a
        # filesystem-safe (colon/slash-free) server dir. NOTE: VibePkg sanitizes
        # the whole URL rather than using the path basename like Pkg does.
        fpath = VibePkg.Fetch.auth_file_path(d, "file:///some/local/path")
        fdir = basename(dirname(fpath))
        @test !occursin(':', fdir) && !occursin('/', fdir)
        @test !isempty(fdir)
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
            # Pkg.jl#4689 (JLSEC-2026-610) — the refreshed token is written
            # through a private (0o600) temp file, so the saved auth.toml is not
            # group/other-readable.
            if !Sys.iswindows()
                @test filemode(authfile) & 0o077 == 0
            end
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
        # get_extract_cmd canonicalizes the path (realpath) so `..`/symlink
        # segments resolve before 7z/zstd see it (Pkg.jl#4553).
        @test cmd.exec[end] == realpath(zst)

        gz = joinpath(dir, "data.tar.gz")
        write(gz, UInt8[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00])
        cmd = VibePkg.Fetch.get_extract_cmd(gz)
        @test occursin("7z", basename(cmd.exec[1]))
        @test cmd.exec[end] == realpath(gz)

        # a file shorter than the 4-byte magic takes the 7z path too
        tiny = joinpath(dir, "tiny")
        write(tiny, UInt8[0x28, 0xb5])
        @test occursin("7z", basename(VibePkg.Fetch.get_extract_cmd(tiny).exec[1]))
    end
end

# try_install_from owns its extraction dir: no failure mode may leave a
# partial tree in the GC-exempt `<artifacts>/temp` directory
@testset "try_install_from cleans up its extraction dir" begin
    mktempdir() do dir
        art = make_gz_artifact(dir, "cleanup")
        adir = mkpath(joinpath(dir, "artifacts"))
        temp_root = joinpath(adir, "temp")
        withenv("JULIA_PKG_IGNORE_HASHES" => nothing) do
            # (a) tree-hash mismatch: the source is rejected and the unpacked
            # tree is removed
            dest = joinpath(adir, "0"^40)
            quietly() do
                @test !ArtifactOps.try_install_from(
                    file_url(art.gz), art.sha, SHA1("0"^40), dest; io = devnull,
                )
            end
            @test !isdir(dest)
            @test isempty(readdir(temp_root))
            # (b) a file squatting on the destination: POSIX rename refuses to
            # replace a file with a directory and throws — the extraction dir
            # must still be cleaned up; Windows MoveFileEx replaces the file,
            # so the install simply wins there
            dest2 = joinpath(adir, string(art.hash))
            write(dest2, "in the way")
            if Sys.iswindows()
                @test ArtifactOps.try_install_from(
                    file_url(art.gz), art.sha, art.hash, dest2; io = devnull,
                )
                @test isdir(dest2)
            else
                @test_throws Base.IOError ArtifactOps.try_install_from(
                    file_url(art.gz), art.sha, art.hash, dest2; io = devnull,
                )
            end
            @test isempty(readdir(temp_root))
        end
    end
end

# bind/unbind treat semantically equivalent platforms (platforms_match, where
# a missing tag is a wildcard) as the same entry, and leave no pidlock litter
@testset "bind/unbind platforms_match + transaction hygiene" begin
    mktempdir() do dir
        A = VibePkg.Artifacts
        toml = joinpath(dir, "Artifacts.toml")
        h1 = SHA1("1"^40)
        h2 = SHA1("2"^40)
        base_plat = Platform("x86_64", "linux")
        tagged = Platform("x86_64", "linux"; libgfortran_version = v"4")
        A.bind_artifact!(toml, "plat", h1; platform = base_plat)
        # an equivalent (matching) platform is a rebind: refused without force…
        @test_throws PkgError A.bind_artifact!(toml, "plat", h2; platform = tagged)
        # …and with force it REPLACES the matching entry instead of
        # accumulating a second one for the same platform
        A.bind_artifact!(toml, "plat", h2; platform = tagged, force = true)
        entries = TOML.parsefile(toml)["plat"]
        @test entries isa Vector && length(entries) == 1
        @test entries[1]["git-tree-sha1"] == string(h2)
        # unbind with an equivalent platform removes the entry too
        A.unbind_artifact!(toml, "plat"; platform = base_plat)
        @test isempty(TOML.parsefile(toml)["plat"])
        # a genuinely different platform is a separate entry
        A.bind_artifact!(toml, "plat", h1; platform = Platform("aarch64", "macos"), force = true)
        A.bind_artifact!(toml, "plat", h2; platform = base_plat)
        @test length(TOML.parsefile(toml)["plat"]) == 2
        # the pidlock protecting the transaction does not linger
        @test !isfile(toml * ".pid")

        # concurrent binds to one file serialize; every mapping survives
        toml2 = joinpath(dir, "Concurrent.toml")
        @sync for i in 1:8
            @async A.bind_artifact!(toml2, "art$i", SHA1(string(i)^40))
        end
        parsed = TOML.parsefile(toml2)
        @test all(haskey(parsed, "art$i") for i in 1:8)
        @test !isfile(toml2 * ".pid")
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

# create_artifact + chmod files to 0o644 so hashes are stable across umasks
# (mirrors Pkg.jl test/artifacts.jl create_artifact_chmod)
function create_artifact_chmod(f::Function)
    return VibePkg.Artifacts.create_artifact() do path
        f(path)
        for (root, dirs, files) in walkdir(path)
            for name in files
                fp = joinpath(root, name)
                islink(fp) || chmod(fp, 0o644)
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl test/artifacts.jl "Artifact Creation" (line 30): known-hash vectors.
@testset "Artifact Creation known-hash vectors" begin
    A = VibePkg.Artifacts
    make_empty(path) = nothing
    make_single(path) = write(joinpath(path, "foo"), "Hello, world!")
    function make_multi(path)
        write(joinpath(path, "foo1"), "Hello")
        write(joinpath(path, "foo2"), "world!")
        return
    end
    function make_nested(path)
        mkpath(joinpath(path, "bar", "bar"))
        write(joinpath(path, "bar", "bar", "foo1"), "Hello")
        write(joinpath(path, "bar", "foo2"), "world!")
        write(joinpath(path, "foo3"), "baz!")
        # empty (even nested-empty) dirs must not affect the hash
        mkpath(joinpath(path, Random.randstring(8), "inner"))
        # symlinks are hashed as links, never followed
        symlink("foo3", joinpath(path, "foo3_link"))
        symlink("../bar", joinpath(path, "bar", "infinite_link"))
        return
    end

    creators = Any[
        (make_empty, "4b825dc642cb6eb9a060e54bf8d69288fbee4904"),
        (make_single, "339aad93c0f854604248ea3b7c5b7edea20625a9"),
        (make_multi, "98cda294312216b19e2a973e9c291c0f5181c98c"),
    ]
    # the nested-dirs + empty-dirs + symlinks vector needs symlink support
    if !Sys.iswindows()
        push!(creators, (make_nested, "86a1ce580587d5851fdfa841aeb3c8d55663f6f9"))
    end

    for (creator, known_hash) in creators
        hash = create_artifact_chmod(creator)
        @test all(hash.bytes .== hex2bytes(known_hash))
        # it lands under `artifacts/<hash>` and is discoverable
        @test basename(dirname(A.artifact_path(hash))) == "artifacts"
        @test basename(A.artifact_path(hash)) == known_hash
        @test A.artifact_exists(hash)
        @test A.verify_artifact(hash)
    end
end

# Pkg.jl test/artifacts.jl "Artifact Creation → File permissions" (line 126):
# created artifacts make files read-only without making directories read-only,
# including when those modes are observed through file/directory symlinks.
@testset "Artifact Creation file permissions" begin
    if !Sys.iswindows()
        A = VibePkg.Artifacts
        nonce = Random.randstring(16)
        hash = A.create_artifact() do dir
            subdir = mkpath(joinpath(dir, "subdir"))
            write(joinpath(subdir, "file1"), nonce)
            write(joinpath(subdir, "file2"), "second file")
            symlink("subdir", joinpath(dir, "dir_link"))
            symlink("file1", joinpath(subdir, "file_link"))
        end
        artifact_dir = A.artifact_path(hash)
        subdir = joinpath(artifact_dir, "subdir")
        file1 = joinpath(subdir, "file1")
        file2 = joinpath(subdir, "file2")
        file_link = joinpath(subdir, "file_link")
        dir_link = joinpath(artifact_dir, "dir_link")

        @test islink(file_link)
        @test iszero(filemode(file1) & 0o222)
        @test iszero(filemode(file2) & 0o222)
        @test iszero(filemode(file_link) & 0o222)

        @test islink(dir_link)
        @test !iszero(filemode(subdir) & 0o222)
        @test !iszero(filemode(dir_link) & 0o222)
        @test !iszero(filemode(subdir) & 0o111)
        @test !iszero(filemode(dir_link) & 0o111)

        # Read-only files must not require a chmod pass before tree removal.
        Base.rm(artifact_dir; recursive = true)
        @test !ispath(artifact_dir)
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl test/artifacts.jl "Artifacts.toml Utilities" (line 168):
# find_artifacts_toml search semantics + artifact_hash/artifact_meta +
# the extract_all_hashes equivalent (VibePkg: GCOps.artifact_hashes).
@testset "find_artifacts_toml + hash query utilities" begin
    A = VibePkg.Artifacts
    mktempdir() do root
        ATS = mkpath(joinpath(root, "ArtifactTOMLSearch"))
        arty_hex = "43563e7631a7eafae1f9f8d9d332e3de44ad7239"
        atoml_body = """
        [arty]
        git-tree-sha1 = "$arty_hex"
        """
        # top-level Artifacts.toml
        write(joinpath(ATS, "Artifacts.toml"), atoml_body)
        write(joinpath(ATS, "pkg.jl"), "module pkg end\n")
        # a plain sub-directory (not a package): search walks up past it
        submod = mkpath(joinpath(ATS, "sub_module"))
        write(joinpath(submod, "pkg.jl"), "module pkg end\n")
        # a sub-directory carrying its OWN Artifacts.toml wins there
        subpkg = mkpath(joinpath(ATS, "sub_package"))
        write(joinpath(subpkg, "Artifacts.toml"), atoml_body)
        write(joinpath(subpkg, "pkg.jl"), "module pkg end\n")
        # JuliaArtifacts.toml is also recognised
        jat = mkpath(joinpath(ATS, "julia_artifacts_test"))
        write(joinpath(jat, "JuliaArtifacts.toml"), atoml_body)
        write(joinpath(jat, "pkg.jl"), "module pkg end\n")
        # a package (has a Project.toml) with no Artifacts.toml: search stops
        # at the package boundary and finds nothing
        sandbox = mkpath(joinpath(root, "BasicSandbox", "src"))
        write(joinpath(root, "BasicSandbox", "Project.toml"), "name = \"BasicSandbox\"\n")
        write(joinpath(sandbox, "Foo.jl"), "module Foo end\n")

        cases = [
            joinpath(ATS, "pkg.jl") => joinpath(ATS, "Artifacts.toml"),
            joinpath(submod, "pkg.jl") => joinpath(ATS, "Artifacts.toml"),
            joinpath(subpkg, "pkg.jl") => joinpath(subpkg, "Artifacts.toml"),
            joinpath(jat, "pkg.jl") => joinpath(jat, "JuliaArtifacts.toml"),
            joinpath(sandbox, "Foo.jl") => nothing,
        ]
        for (src, expected) in cases
            @test A.find_artifacts_toml(src) == expected
        end

        # artifact_hash / artifact_meta read the located file
        toml = joinpath(ATS, "Artifacts.toml")
        @test A.artifact_hash("arty", toml) == SHA1(arty_hex)
        @test A.artifact_hash("nope", toml) === nothing
        meta = A.artifact_meta("arty", toml)
        @test meta["git-tree-sha1"] == arty_hex

        # extract_all_hashes equivalent: VibePkg's GCOps.artifact_hashes returns
        # every git-tree-sha1 as a hex string (Pkg returns SHA1 objects)
        @test arty_hex in VibePkg.GCOps.artifact_hashes(toml)
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl test/artifacts.jl "Artifacts.toml Utilities" bad-file block (line 300):
# structural parse errors are logged by artifact_meta.
@testset "bad Artifacts.toml structural parse errors" begin
    A = VibePkg.Artifacts
    mktempdir() do dir
        no_gitsha = joinpath(dir, "no_gitsha.toml")
        write(
            no_gitsha, """
            [broken_artifact]
            not_a_hash = "whoops"
            """
        )
        @test_logs (:error, r"contains no `git-tree-sha1`") A.artifact_meta("broken_artifact", no_gitsha)

        not_a_table = joinpath(dir, "not_a_table.toml")
        write(not_a_table, "broken_artifact = \"i am a scalar\"\n")
        @test_logs (:error, r"malformed, must be array or dict!") A.artifact_meta("broken_artifact", not_a_table)
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl test/artifacts.jl "Override.toml" (line 623): multi-depot precedence,
# name-based (UUID.name) resolution, clearing (""), and invalid-entry logging.
# VibePkg's override engine is ArtifactOps.load_overrides / override_for; the
# actual artifact_path redirect at load time is delegated to the Artifacts
# stdlib, which shares the same Overrides.toml file format.
@testset "Override.toml precedence, resolution and clearing" begin
    mktempdir() do container
        depot1 = mkpath(joinpath(container, "depot1", "artifacts"))
        depot2 = mkpath(joinpath(container, "depot2", "artifacts"))
        depot3 = mkpath(joinpath(container, "depot3", "artifacts"))

        foo = SHA1("1"^40)
        bar = SHA1("2"^40)
        baz = SHA1("3"^40)
        aol_uuid = Base.UUID("7b879065-7f74-5fa4-bdd5-9b7a15df8941")

        path_a = mkpath(joinpath(container, "override_a"))
        path_b = mkpath(joinpath(container, "override_b"))

        # depot2 (outer): baz->bar (hash form), arty->bar and barty->path_a (uuid form)
        write(
            joinpath(depot2, "Overrides.toml"), """
            $(string(baz)) = "$(string(bar))"

            [$aol_uuid]
            arty = "$(string(bar))"
            barty = "$(toml_path(path_a))"
            """
        )
        # depot1 (innermost, wins): foo->path_b, clear baz, arty->path_b
        write(
            joinpath(depot1, "Overrides.toml"), """
            $(string(foo)) = "$(toml_path(path_b))"
            $(string(baz)) = ""

            [$aol_uuid]
            arty = "$(toml_path(path_b))"
            """
        )

        d = depot_stack([dirname(depot1), dirname(depot2), dirname(depot3)])
        ov = ArtifactOps.load_overrides(d)

        # hash-form: innermost depot's path override wins. `override_for` returns
        # the path exactly as written in Overrides.toml (forward-slashed by
        # `toml_path`), so compare against that form rather than the native
        # backslash `path_b`/`path_a` (a no-op off Windows)
        @test ArtifactOps.override_for(ov, nothing, "x", foo) == toml_path(path_b)
        # clearing ("") in the innermost depot removes the outer depot's override
        @test ArtifactOps.override_for(ov, nothing, "x", baz) === nothing
        # a hash used only as an override *target* is not itself overridden
        @test ArtifactOps.override_for(ov, nothing, "x", bar) === nothing
        # name-based (uuid.name): innermost depot wins for `arty`
        @test ArtifactOps.override_for(ov, aol_uuid, "arty", SHA1("0"^40)) == toml_path(path_b)
        # `barty` exists only in the outer depot
        @test ArtifactOps.override_for(ov, aol_uuid, "barty", SHA1("0"^40)) == toml_path(path_a)
        # a uuid override does not apply to a different uuid
        @test ArtifactOps.override_for(ov, Base.UUID("0"^8 * "-0000-0000-0000-" * "0"^12), "arty", foo) == toml_path(path_b)

        # invalid Overrides.toml entry: a non-UUID key with a table value is
        # skipped with a warning (VibePkg divergence: it does NOT @error on the
        # non-absolute-path / invalid-SHA1 / non-string cases Pkg rejects — it
        # tolerates them silently).
        write(
            joinpath(depot3, "Overrides.toml"), """
            ["invalid UUID key"]
            "$(string(foo))" = "$(string(bar))"
            """
        )
        d3 = depot_stack([dirname(depot3)])
        @test_logs (:warn, r"ignoring invalid key") match_mode = :any ArtifactOps.load_overrides(d3)

        # tolerated-silently cases (no error, entry simply ignored)
        write(
            joinpath(depot3, "Overrides.toml"), """
            "not-a-40-char-hex" = "$(string(bar))"
            """
        )
        ov3 = @test_logs min_level = Logging.Error ArtifactOps.load_overrides(d3)
        @test isempty(ov3.hash_overrides) && isempty(ov3.uuid_overrides)
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl test/artifacts.jl "artifacts for non package project" (line 800):
# a bare project dir carrying only an Artifacts.toml gets its artifacts
# installed by instantiate().
@testset "artifacts for non-package project" begin
    mktempdir() do dir
        art = make_gz_artifact(dir, "bareart")
        envdir = mkpath(joinpath(dir, "env"))
        # a bare (non-package) project: no name/uuid, just an Artifacts.toml
        write(joinpath(envdir, "Project.toml"), "")
        write(
            joinpath(envdir, "Artifacts.toml"), """
            [bareart]
            git-tree-sha1 = "$(art.hash)"

                [[bareart.download]]
                url = "$(file_url(art.gz))"
                sha256 = "$(art.sha)"
            """
        )
        depot = mkpath(joinpath(dir, "depot"))
        d = depot_stack([depot])
        env = load_environment(envdir; depots = d)

        # not present before instantiate
        @test !last(artifact_tree_path(d, art.hash))
        withenv("JULIA_PKG_SERVER" => "") do
            instantiate!(env, RegistryInstance[], Config(d); io = devnull)
        end
        path, installed = artifact_tree_path(d, art.hash)
        @test installed
        @test read(joinpath(path, "bareart.txt"), String) == "bareart payload\n"
    end
end
