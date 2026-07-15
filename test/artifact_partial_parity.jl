# Hermetic ports for the remaining public artifact/platform partials.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()
LocalPkgServer.ensure!()

using Test
using Base: SHA1, UUID
using Base.BinaryPlatforms: HostPlatform, Platform
using SHA: sha256
import LibGit2
import TOML
using VibePkg

const PARTIAL_A = VibePkg.Artifacts
const PARTIAL_PE = VibePkg.PlatformEngines
const PARTIAL_TAR = VibePkg.Fetch.Tar
const PARTIAL_SOCKETS = LocalPkgServer.Sockets
const PARTIAL_AUGMENT_UUID = UUID("91c08a6e-6c3c-46b5-a58a-bdad6409d89a")
const PARTIAL_CONCURRENT_UUID = UUID("a1c08a6e-6c3c-46b5-a58a-bdad6409d89b")

partial_toml_path(path::AbstractString) = replace(path, '\\' => '/')
function partial_file_url(path::AbstractString)
    path = partial_toml_path(path)
    startswith(path, '/') || (path = "/$path")
    return "file://$path"
end

function partial_with_depot(f::Function)
    return mktempdir() do root
        depot = realpath(mkpath(joinpath(root, "depot")))
        old_depots = copy(Base.DEPOT_PATH)
        old_depot_env = get(ENV, "JULIA_DEPOT_PATH", nothing)
        old_project = Base.ACTIVE_PROJECT[]
        stack = [depot; old_depots[2:end]]
        copy!(Base.DEPOT_PATH, stack)
        ENV["JULIA_DEPOT_PATH"] = join(stack, Sys.iswindows() ? ';' : ':')
        try
            return f(root, depot)
        finally
            Base.ACTIVE_PROJECT[] = old_project
            copy!(Base.DEPOT_PATH, old_depots)
            if old_depot_env === nothing
                delete!(ENV, "JULIA_DEPOT_PATH")
            else
                ENV["JULIA_DEPOT_PATH"] = old_depot_env
            end
        end
    end
end

function partial_write_augmented_project(root::String, preference::String)
    project = mkpath(joinpath(root, "PartialAugmented"))
    mkpath(joinpath(project, "src"))
    scripts = mkpath(joinpath(project, ".pkg"))
    write(
        joinpath(project, "Project.toml"),
        """
        name = "PartialAugmented"
        uuid = "$PARTIAL_AUGMENT_UUID"
        version = "0.1.0"

        [deps]
        Artifacts = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"
        """,
    )
    write(
        joinpath(project, "LocalPreferences.toml"),
        """
        [PartialAugmented]
        flooblecrank = "$preference"
        """,
    )
    write(
        joinpath(scripts, "platform_augmentation.jl"),
        """
        using Base.BinaryPlatforms
        function augment_platform!(platform::Platform)
            haskey(platform, "flooblecrank") && return platform
            value = get(Base.get_preferences(Base.UUID("$PARTIAL_AUGMENT_UUID")), "flooblecrank", "disengaged")
            platform["flooblecrank"] = value == "engaged" ? "engaged" : "disengaged"
            return platform
        end
        """,
    )
    write(
        joinpath(scripts, "select_artifacts.jl"),
        """
        using TOML, Artifacts, Base.BinaryPlatforms
        include("platform_augmentation.jl")
        target = get(ARGS, 1, Base.BinaryPlatforms.host_triplet())
        platform = augment_platform!(HostPlatform(parse(Platform, target)))
        selected = select_downloadable_artifacts(joinpath(dirname(@__DIR__), "Artifacts.toml"); platform)
        TOML.print(stdout, selected)
        """,
    )
    write(
        joinpath(project, "src", "PartialAugmented.jl"),
        """
        module PartialAugmented
        using Artifacts
        include("../.pkg/platform_augmentation.jl")
        artifact_dir() = @artifact_str("gooblebox", augment_platform!(HostPlatform()))
        end
        """,
    )
    return project
end

function partial_bind_augmented_artifacts(project::String, root::String)
    records = Dict{String, NamedTuple}()
    for status in ("engaged", "disengaged")
        hash = PARTIAL_A.create_artifact() do dir
            write(joinpath(dir, "status.txt"), status)
        end
        archive = joinpath(root, "$status.tar.gz")
        digest = PARTIAL_A.archive_artifact(hash, archive)
        PARTIAL_A.remove_artifact(hash)
        records[status] = (; hash, archive, digest)

        platform = HostPlatform()
        platform["flooblecrank"] = status
        PARTIAL_A.bind_artifact!(
            joinpath(project, "Artifacts.toml"), "gooblebox", hash;
            download_info = [(partial_file_url(archive), digest)], platform,
        )
    end
    return records
end

function partial_run_augmented(project::String)
    code = "using PartialAugmented; print(PartialAugmented.artifact_dir())"
    cmd = addenv(
        `$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --color=no --project=$project -e $code`,
        "JULIA_DEPOT_PATH" => ENV["JULIA_DEPOT_PATH"],
    )
    output = IOBuffer()
    process = run(pipeline(ignorestatus(cmd); stdout = output, stderr = output))
    return chomp(String(take!(output))), success(process)
end

@testset "artifact platform augmentation and cross-platform installation" begin
    for preference in ("engaged", "disengaged")
        partial_with_depot() do root, _
            project = partial_write_augmented_project(root, preference)
            records = partial_bind_augmented_artifacts(project, root)
            right = records[preference].hash
            wrong = records[preference == "engaged" ? "disengaged" : "engaged"].hash
            @test !PARTIAL_A.artifact_exists(right)
            @test !PARTIAL_A.artifact_exists(wrong)

            VibePkg.activate(project; io = devnull)
            VibePkg.add(
                VibePkg.PackageSpec(name = "Example", version = v"0.5.4");
                io = devnull,
            )
            @test PARTIAL_A.artifact_exists(right)
            @test !PARTIAL_A.artifact_exists(wrong)

            platform = HostPlatform()
            platform["flooblecrank"] = preference
            @test PARTIAL_A.artifact_hash(
                "gooblebox", joinpath(project, "Artifacts.toml"); platform,
            ) == right
            output, ok = partial_run_augmented(project)
            @test ok
            @test last(split(output, '\n')) == PARTIAL_A.artifact_path(right)
        end
    end

    partial_with_depot() do root, _
        project = partial_write_augmented_project(root, "disengaged")
        records = partial_bind_augmented_artifacts(project, root)
        engaged = records["engaged"].hash
        disengaged = records["disengaged"].hash
        @test !PARTIAL_A.artifact_exists(engaged)
        @test !PARTIAL_A.artifact_exists(disengaged)

        target = HostPlatform()
        target["flooblecrank"] = "engaged"
        VibePkg.activate(project; io = devnull)
        VibePkg.add(
            VibePkg.PackageSpec(name = "Example", version = v"0.5.4");
            platform = target, io = devnull,
        )
        @test PARTIAL_A.artifact_exists(engaged)
        @test !PARTIAL_A.artifact_exists(disengaged)
    end

    partial_with_depot() do root, _
        project = partial_write_augmented_project(root, "disengaged")
        records = partial_bind_augmented_artifacts(project, root)
        engaged = records["engaged"].hash
        disengaged = records["disengaged"].hash
        @test !PARTIAL_A.artifact_exists(engaged)
        @test !PARTIAL_A.artifact_exists(disengaged)

        VibePkg.activate(project; io = devnull)
        VibePkg.add(
            VibePkg.PackageSpec(name = "Example", version = v"0.5.4");
            io = devnull,
        )
        @test !PARTIAL_A.artifact_exists(engaged)
        @test PARTIAL_A.artifact_exists(disengaged)

        target = HostPlatform()
        target["flooblecrank"] = "engaged"
        VibePkg.instantiate(; platform = target, io = devnull)
        @test PARTIAL_A.artifact_exists(engaged)
        @test PARTIAL_A.artifact_exists(disengaged)
    end
end

function partial_compressed_archives(root::String)
    source = mkpath(joinpath(root, "source", "bin"))
    payload = "hermetic socrates payload\n"
    write(joinpath(source, "socrates"), payload)
    tarball = joinpath(root, "socrates.tar")
    PARTIAL_TAR.create(dirname(source), tarball)
    archives = Dict{String, NamedTuple}()
    sevenzip = VibePkg.Fetch.p7zip_jll.p7zip()
    for (extension, kind) in (("gz", "gzip"), ("bz2", "bzip2"), ("xz", "xz"))
        archive = joinpath(root, "socrates.tar.$extension")
        run(pipeline(`$sevenzip a -t$kind $archive $tarball`; stdout = devnull))
        archives[extension] = (;
            archive, digest = bytes2hex(open(sha256, archive)),
        )
    end
    return archives, bytes2hex(sha256(payload))
end

@testset "PlatformEngines downloading cache across gz bz2 xz" begin
    mktempdir() do root
        archives, payload_hash = partial_compressed_archives(root)
        for extension in ("gz", "bz2", "xz")
            remote = archives[extension].archive
            digest = archives[extension].digest
            prefix = mkpath(joinpath(root, "case-$extension"))
            cached = joinpath(prefix, "download_target.tar.$extension")
            target = joinpath(prefix, "target")

            @test PARTIAL_PE.download_verify_unpack(
                partial_file_url(remote), digest, target;
                tarball_path = cached, quiet_download = true,
            )
            @test isfile(cached)
            installed = joinpath(target, "bin", "socrates")
            @test isfile(installed)
            @test bytes2hex(open(sha256, installed)) == payload_hash

            @test !PARTIAL_PE.download_verify_unpack(
                partial_file_url(remote), digest, target;
                tarball_path = cached, quiet_download = true,
            )

            write(cached, "corruptify\n")
            @test PARTIAL_PE.download_verify_unpack(
                partial_file_url(remote), digest, target;
                tarball_path = cached, force = true, quiet_download = true,
            )
            @test bytes2hex(open(sha256, cached)) == digest
            @test bytes2hex(open(sha256, installed)) == payload_hash
        end
    end
end

function partial_test_server_dir(url, server, ::Nothing)
    return @test PARTIAL_PE.get_server_dir(url, server) === nothing
end
function partial_test_server_dir(url, server, expected_name::AbstractString)
    observed = PARTIAL_PE.get_server_dir(url, server)
    expected = joinpath(first(Base.DEPOT_PATH), "servers", expected_name)
    @test observed == expected
    @test startswith(observed, first(Base.DEPOT_PATH))
    return @test startswith(observed, joinpath(first(Base.DEPOT_PATH), "servers"))
end

@testset "PlatformEngines get_server_dir matrix" begin
    partial_test_server_dir("https://foo.bar/baz/a", nothing, nothing)
    partial_test_server_dir("https://foo.bar/baz/a", "https://bar", nothing)
    partial_test_server_dir("https://foo.bar/baz/a", "foo.bar", nothing)
    partial_test_server_dir("https://foo.bar/bazx", "https://foo.bar/baz", nothing)

    for host in ("localhost", "foo", "foo.bar", "foo.bar.baz"),
            protocol in ("http", "https"),
            (original_port, normalized_port) in (("", ""), (":1234", "_1234")),
            server_suffix in ("", "/hello", "/hello/world"),
            url_suffix in ("/", "/foo", "/foo/bar", "/foo/bar/baz")
        server = "$protocol://$host$original_port$server_suffix"
        partial_test_server_dir(
            server * url_suffix, server, host * normalized_port,
        )
    end

    for (path, expected) in (
            "/some/local/path" => "some",
            "/srv/pkg" => "srv",
            "/c%3A/foo/bar" => "c%3A",
        )
        server = "file://$path"
        partial_test_server_dir("$server/foo", server, expected)
    end
end

@testset "artifact GC public bind-unbind lifecycle" begin
    partial_with_depot() do root, depot
        live_hash = PARTIAL_A.create_artifact() do path
            write(joinpath(path, "README.md"), "I will not go quietly.")
            write(joinpath(path, "binary.data"), fill(UInt8(0x11), 1024))
        end
        die_hash = PARTIAL_A.create_artifact() do path
            write(joinpath(path, "README.md"), "Let me sleep!")
            write(joinpath(path, "binary.data"), fill(UInt8(0x22), 1024))
        end
        @test live_hash != die_hash

        usage_path = joinpath(depot, "logs", "artifact_usage.toml")
        @test !isfile(usage_path)
        artifacts_toml = joinpath(root, "Artifacts.toml")
        PARTIAL_A.bind_artifact!(artifacts_toml, "live", live_hash)
        PARTIAL_A.bind_artifact!(artifacts_toml, "die", die_hash)
        usage = TOML.parsefile(usage_path)
        @test any(path -> startswith(path, artifacts_toml), keys(usage))

        @test PARTIAL_A.artifact_exists(live_hash)
        @test PARTIAL_A.artifact_exists(die_hash)
        VibePkg.gc(; io = devnull)
        @test PARTIAL_A.artifact_exists(live_hash)
        @test PARTIAL_A.artifact_exists(die_hash)

        PARTIAL_A.unbind_artifact!(artifacts_toml, "die")
        VibePkg.gc(; io = devnull)
        @test PARTIAL_A.artifact_exists(live_hash)
        @test !PARTIAL_A.artifact_exists(die_hash)

        PARTIAL_A.unbind_artifact!(artifacts_toml, "live")
        VibePkg.gc(; io = devnull)
        @test !PARTIAL_A.artifact_exists(live_hash)
        @test !PARTIAL_A.artifact_exists(die_hash)
    end
end

function partial_vibepkg_cmd(code::AbstractString, shared_depot::String)
    separator = Sys.iswindows() ? ';' : ':'
    prelude = string(
        "using VibePkg\n",
        "include(raw\"", joinpath(@__DIR__, "local_pkg_server.jl"), "\")\n",
        "LocalPkgServer.isolate!(); LocalPkgServer.ensure!()\n",
    )
    return addenv(
        `$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --color=no -e $(prelude * code)`,
        "JULIA_LOAD_PATH" => join(["@", pkgdir(VibePkg), "@stdlib"], separator),
        "JULIA_DEPOT_PATH" => LocalPkgServer.worker_depot_path(),
        "JULIA_PROJECT" => nothing,
        "VIBEPKG_TEST_DEPOT" => shared_depot,
        "JULIA_DEBUG" => "VibePkg",
    )
end

function partial_concurrent_fixture(root::String, artifact_url::String)
    artifact_source = mkpath(joinpath(root, "artifact-source"))
    write(joinpath(artifact_source, "payload.txt"), "concurrent artifact\n")
    artifact_hash = SHA1(VibePkg.TreeHash.tree_hash(artifact_source))
    artifact_archive = joinpath(root, "artifact.tar.gz")
    VibePkg.Fetch.package(artifact_source, artifact_archive; io = devnull)
    artifact_digest = bytes2hex(open(sha256, artifact_archive))

    package = mkpath(joinpath(root, "ConcurrentArtifactPkg"))
    mkpath(joinpath(package, "src"))
    write(
        joinpath(package, "Project.toml"),
        "name = \"ConcurrentArtifactPkg\"\nuuid = \"$PARTIAL_CONCURRENT_UUID\"\nversion = \"0.1.0\"\n",
    )
    write(
        joinpath(package, "src", "ConcurrentArtifactPkg.jl"),
        "module ConcurrentArtifactPkg\nvalue() = :ready\nend\n",
    )
    write(
        joinpath(package, "Artifacts.toml"),
        """
        [payload]
        git-tree-sha1 = "$artifact_hash"

            [[payload.download]]
            url = "$artifact_url"
            sha256 = "$artifact_digest"
        """,
    )
    repo = LibGit2.init(package)
    try
        LibGit2.add!(repo, ".")
        signature = LibGit2.Signature("fixture", "fixture@localhost")
        LibGit2.commit(repo, "initial"; author = signature, committer = signature)
    finally
        close(repo)
    end
    package_hash = SHA1(VibePkg.TreeHash.tree_hash(package))

    registry = mkpath(joinpath(root, "shared", "registries", "ConcurrentRegistry"))
    write(
        joinpath(registry, "Registry.toml"),
        """
        name = "ConcurrentRegistry"
        uuid = "b1c08a6e-6c3c-46b5-a58a-bdad6409d89c"
        repo = "https://example.invalid/ConcurrentRegistry"

        [packages]
        $PARTIAL_CONCURRENT_UUID = { name = "ConcurrentArtifactPkg", path = "C/ConcurrentArtifactPkg" }
        """,
    )
    package_meta = mkpath(joinpath(registry, "C", "ConcurrentArtifactPkg"))
    open(joinpath(package_meta, "Package.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "name" => "ConcurrentArtifactPkg",
                "uuid" => string(PARTIAL_CONCURRENT_UUID),
                "repo" => package,
            ),
        )
    end
    write(
        joinpath(package_meta, "Versions.toml"),
        "[\"0.1.0\"]\ngit-tree-sha1 = \"$package_hash\"\n",
    )
    return (; artifact_hash, artifact_archive, package_hash)
end

@testset "concurrent package and artifact install exactly once" begin
    mktempdir() do root
        shared = realpath(mkpath(joinpath(root, "shared")))
        listener = PARTIAL_SOCKETS.listen(PARTIAL_SOCKETS.localhost, 0)
        port = Int(last(PARTIAL_SOCKETS.getsockname(listener)))
        request_count = Threads.Atomic{Int}(0)
        archive_body = Ref{Vector{UInt8}}()
        server_task = @async while isopen(listener)
            socket = try
                PARTIAL_SOCKETS.accept(listener)
            catch
                break
            end
            try
                request = readline(socket)
                while !isempty(rstrip(readline(socket)))
                end
                occursin("/artifact", request) && Threads.atomic_add!(request_count, 1)
                body = archive_body[]
                write(
                    socket,
                    "HTTP/1.1 200 OK\r\nContent-Length: $(length(body))\r\nConnection: close\r\n\r\n",
                )
                write(socket, body)
                flush(socket)
            finally
                close(socket)
            end
        end

        artifact_url = "http://127.0.0.1:$port/artifact"
        fixture = partial_concurrent_fixture(root, artifact_url)
        archive_body[] = read(fixture.artifact_archive)
        cmd = partial_vibepkg_cmd(
            """
            ENV["JULIA_PKG_SERVER"] = ""
            VibePkg.activate(temp = true)
            VibePkg.add(VibePkg.PackageSpec(name = "ConcurrentArtifactPkg", version = v"0.1.0"); io = stderr)
            using ConcurrentArtifactPkg
            @assert ConcurrentArtifactPkg.value() == :ready
            """,
            shared,
        )

        package_installs = Threads.Atomic{Int}(0)
        artifact_installs = Threads.Atomic{Int}(0)
        failures = Threads.Atomic{Int}(0)
        outputs = fill("", 3)
        @sync for worker in 1:3
            Threads.@spawn begin
                output = IOBuffer()
                process = run(pipeline(ignorestatus(cmd); stdout = output, stderr = output))
                text = String(take!(output))
                outputs[worker] = text
                success(process) || Threads.atomic_add!(failures, 1)
                occursin("Installed ConcurrentArtifactPkg", text) &&
                    Threads.atomic_add!(package_installs, 1)
                occursin("Installed artifact payload", text) &&
                    Threads.atomic_add!(artifact_installs, 1)
            end
        end
        close(listener)
        wait(server_task)
        (failures[] == 0 && package_installs[] == 1 && artifact_installs[] == 1) ||
            foreach(println, outputs)
        @test failures[] == 0
        @test package_installs[] == 1
        @test artifact_installs[] == 1
        @test request_count[] == 1
        installed = joinpath(shared, "artifacts", string(fixture.artifact_hash))
        @test read(joinpath(installed, "payload.txt"), String) == "concurrent artifact\n"
    end
end
