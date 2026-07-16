# Hermetic parity for the artifact/platform-engine behaviors that used to be
# labelled N/A solely because VibePkg lacked the compatibility entry points.

if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test

using VibePkg
const NA_A = VibePkg.Artifacts
const NA_PE = VibePkg.PlatformEngines
const NA_Tar = VibePkg.Fetch.Tar
const NA_Sockets = LocalPkgServer.Sockets
const na_sha256 = VibePkg.ArtifactOps.sha256

na_toml_path(path::AbstractString) = replace(path, '\\' => '/')
function na_file_url(path::AbstractString)
    path = na_toml_path(path)
    startswith(path, '/') || (path = "/$path")
    return "file://$path"
end

# Build the copy-dereference fixture as tar records rather than filesystem
# symlinks, so the test is runnable on Windows hosts without Developer Mode.
function na_copyderef_tarball(dir::String)
    tarball = joinpath(dir, "collapse.tar")
    payload = "payload\n"
    open(tarball, "w") do tar
        NA_Tar.write_tarball(
            tar,
            NA_Tar.Header(
                "collapse_the_symlink/foo", :file,
                UInt16(0o644), ncodeunits(payload), "",
            ),
            IOBuffer(payload),
        )
        for (path, target) in (
                "collapse_the_symlink/foo.1" => "foo",
                "collapse_the_symlink/foo.1.1" => "foo.1",
                "collapse_the_symlink/broken" => "missing",
            )
            NA_Tar.write_tarball(
                tar,
                NA_Tar.Header(path, :symlink, UInt16(0o755), 0, target),
            )
        end
    end
    gz = tarball * ".gz"
    run(pipeline(`$(VibePkg.Fetch.p7zip_jll.p7zip()) a -tgzip $gz $tarball`; stdout = devnull))
    return gz
end

# Pkg.jl artifacts.jl `with_artifacts_directory()`.
@testset "with_artifacts_directory redirects creation" begin
    mktempdir() do artifacts_dir
        NA_A.with_artifacts_directory(artifacts_dir) do
            hash = NA_A.create_artifact() do path
                touch(joinpath(path, "foo"))
            end
            @test startswith(NA_A.artifact_path(hash), artifacts_dir)
            @test isfile(joinpath(NA_A.artifact_path(hash), "foo"))
        end
    end
end

# Pkg.jl artifacts.jl `Artifact archival`.
@testset "artifact archival" begin
    mktempdir() do artifacts_dir
        NA_A.with_artifacts_directory(artifacts_dir) do
            hash = NA_A.create_artifact(path -> touch(joinpath(path, "foo")))
            tarball = joinpath(artifacts_dir, "foo.tar.gz")
            digest = NA_A.archive_artifact(hash, tarball)
            @test digest == bytes2hex(open(na_sha256, tarball))
            @test "foo" in NA_PE.list_tarball_files(tarball)

            NA_A.remove_artifact(hash)
            @test !NA_A.artifact_exists(hash)
            @test_throws ErrorException NA_A.archive_artifact(hash, tarball)
        end
    end
end

# Pkg.jl platformengines.jl `Packaging`.
@testset "platform packaging and listing" begin
    mktempdir() do dir
        prefix = mkpath(joinpath(dir, "prefix"))
        write(joinpath(mkpath(joinpath(prefix, "bin")), "bar.sh"), "#!/bin/sh\necho yolo\n")
        write(joinpath(mkpath(joinpath(prefix, "lib")), "baz.so"), "this is not an actual .so\n")
        write(joinpath(mkpath(joinpath(prefix, "etc")), "qux.conf"), "use_julia=true\n")

        tarball = joinpath(dir, "foo.tar.gz")
        NA_PE.package(prefix, tarball; io = devnull)
        @test isfile(tarball)
        contents = NA_PE.list_tarball_files(tarball)
        @test "bin/bar.sh" in contents
        @test "lib/baz.so" in contents
        @test "etc/qux.conf" in contents
    end
end

# Pkg.jl platformengines.jl `Verification`, including the sidecar state
# machine rather than only a one-shot digest comparison.
@testset "sha256 verification sidecar states" begin
    mktempdir() do dir
        path = joinpath(dir, "foo")
        write(path, "test")
        expected = bytes2hex(na_sha256("test"))

        @test_logs (:info, r"No hash cache found") match_mode = :any begin
            ok, status = NA_PE.verify(path, expected; verbose = true, report_cache_status = true)
            @test ok
            @test status == :hash_cache_missing
        end
        @test isfile("$(path).sha256")

        @test_logs (:info, r"Hash cache is consistent") match_mode = :any begin
            ok, status = NA_PE.verify(path, expected; verbose = true, report_cache_status = true)
            @test ok
            @test status == :hash_cache_consistent
        end

        # Put the content mtime strictly after the cache even on coarse filesystems.
        sleep(1.1)
        touch(path)
        @test_logs (:info, r"File has been modified") match_mode = :any begin
            ok, status = NA_PE.verify(path, expected; verbose = true, report_cache_status = true)
            @test ok
            @test status == :file_modified
        end

        Base.rm("$(path).sha256"; force = true)
        @test_logs (:error, r"Hash Mismatch!") match_mode = :any begin
            @test !NA_PE.verify(path, "0"^64; verbose = true)
        end
        @test_throws ErrorException NA_PE.verify(path, "0"^65; verbose = true)

        @test NA_PE.verify(path, expected)
        write("$(path).sha256", "this is not the right hash")
        @test_logs (:info, r"hash cache invalidated") match_mode = :any begin
            ok, status = NA_PE.verify(path, expected; verbose = true, report_cache_status = true)
            @test ok
            @test status == :hash_cache_mismatch
        end

        write(path, "this is not the right content")
        Base.rm("$(path).sha256"; force = true)
        @test_logs (:error, r"Hash Mismatch!") match_mode = :any begin
            ok, status = NA_PE.verify(path, expected; verbose = true, report_cache_status = true)
            @test !ok
            @test status == :hash_mismatch
        end
    end
end

# Pkg.jl platformengines.jl `Copyderef unpacking`, with the upstream network
# tarball replaced by an equivalent generated file:// fixture.
@testset "copy-dereference unpacking" begin
    mktempdir() do dir
        tarball = na_copyderef_tarball(dir)
        digest = bytes2hex(open(na_sha256, tarball))
        target = joinpath(dir, "target")

        withenv("BINARYPROVIDER_COPYDEREF" => "true") do
            @test NA_PE.download_verify_unpack(
                na_file_url(tarball), digest, target;
                verbose = false, quiet_download = true,
            )
        end
        root = joinpath(target, "collapse_the_symlink")
        @test isfile(joinpath(root, "foo"))
        @test isfile(joinpath(root, "foo.1"))
        @test isfile(joinpath(root, "foo.1.1"))
        @test !islink(joinpath(root, "foo"))
        @test !islink(joinpath(root, "foo.1.1"))
        @test !ispath(joinpath(root, "broken"))
    end
end

# Pkg.jl platformengines.jl `Download GitHub API #88`: a loopback redirect
# reproduces GitHub's API-to-archive redirect without a live-network dependency.
@testset "download follows API archive redirect" begin
    listener = NA_Sockets.listen(NA_Sockets.localhost, 0)
    port = Int(last(NA_Sockets.getsockname(listener)))
    requests = String[]
    body = "redirected archive bytes\n"
    server_task = @async try
        for response_number in 1:2
            socket = NA_Sockets.accept(listener)
            try
                push!(requests, readline(socket))
                while !isempty(rstrip(readline(socket)))
                end
                if response_number == 1
                    write(
                        socket,
                        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:$port/archive\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    )
                else
                    write(
                        socket,
                        "HTTP/1.1 200 OK\r\nContent-Length: $(ncodeunits(body))\r\nConnection: close\r\n\r\n$body",
                    )
                end
                flush(socket)
            finally
                close(socket)
            end
        end
    finally
        close(listener)
    end

    mktempdir() do dir
        destination = joinpath(dir, "BinaryProvider")
        url = "http://127.0.0.1:$port/repos/JuliaPackaging/BinaryProvider.jl/tarball/ref"
        @test NA_PE.download(url, destination; verbose = false) == destination
        @test read(destination, String) == body
    end
    wait(server_task)
    @test length(requests) == 2
    @test occursin("/repos/JuliaPackaging/BinaryProvider.jl/tarball/ref", requests[1])
    @test occursin("/archive", requests[2])
end
