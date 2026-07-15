# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: SHA1
import Tar
import p7zip_jll
using VibePkg
using VibePkg.TreeHash: tree_hash, blob_hash
using VibePkg.Fetch: read_tarball_simple

@testset "download diagnostics redact credentials" begin
    mktempdir() do dir
        secret = "download-secret"
        url = "http://user:$secret@127.0.0.1:1/archive?token=query-secret"
        err = try
            VibePkg.Fetch.download(
                url, joinpath(dir, "archive"); io = devnull, show_progress = false,
            )
            nothing
        catch caught
            caught
        end
        @test err isa VibePkg.Fetch.Downloads.RequestError
        message = sprint(showerror, err)
        @test occursin("127.0.0.1", message)
        @test !occursin(secret, message)
        @test !occursin("query-secret", message)
    end
end

# gzip a single (non-tar) file — used to fabricate a "valid gzip, corrupt
# tar" archive; 7z appends .gz to extensionless archive names
function gzip_plain_file(src::String, dest::String)
    run(pipeline(`$(p7zip_jll.p7zip()) a -tgzip $(dest * ".gz") $src`; stdout = devnull))
    mv(dest * ".gz", dest)
    return dest
end

# Hashing is an integrity boundary: a read failure must propagate (with the
# path in the message) instead of silently digesting partial content — a
# partial digest would let corrupt trees mis-verify.
@testset "blob_hash read failures propagate" begin
    if Sys.iswindows() || ccall(:getuid, Cint, ()) == 0
        @test_skip "chmod-based unreadable file not enforceable here"
    else
        mktempdir() do dir
            f = joinpath(dir, "secret.txt")
            write(f, "content")
            chmod(f, 0o000)
            try
                err = try
                    blob_hash(f)
                    nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test occursin("secret.txt", err.msg)
                @test occursin("Git blob hash", err.msg)
                # and through tree_hash of a containing directory
                @test_throws ErrorException tree_hash(dir)
            finally
                chmod(f, 0o644)
            end
            # readable again: hashing succeeds
            @test tree_hash(dir) isa Vector{UInt8}
        end
    end
end

# Entries rejected by the predicate must have their data drained so the
# stream stays aligned on the next header (previously a rejected non-empty
# entry left its data in the stream, corrupting every later header).
@testset "read_tarball_simple drains rejected entries" begin
    mktempdir() do dir
        src = mkpath(joinpath(dir, "src"))
        write(joinpath(src, "a.txt"), "A"^2000)   # multi-block data to skip
        write(joinpath(src, "b.txt"), "hello b")
        tarball = joinpath(dir, "t.tar")
        Tar.create(src, tarball)
        seen = Dict{String, String}()
        buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
        io = IOBuffer()
        open(tarball) do tar
            read_tarball_simple(hdr -> hdr.type == :file && hdr.path == "b.txt", tar; buf) do hdr
                Tar.read_data(tar, io; size = hdr.size, buf)
                seen[hdr.path] = String(take!(io))
            end
        end
        @test seen == Dict("b.txt" => "hello b")
    end
end

@testset "install_archive source fall-through" begin
    mktempdir() do dir
        src = mkpath(joinpath(dir, "Ex"))
        write(joinpath(src, "file.jl"), "module Ex end\n")
        hash = SHA1(tree_hash(src))
        good = LocalPkgServer.gzip_tarball(src, joinpath(dir, "good"))

        # valid gzip, but the decompressed stream is not a tar archive
        garbage = joinpath(dir, "garbage.bin")
        write(garbage, "this is not a tar stream " * "x"^4096)
        corrupt = gzip_plain_file(garbage, joinpath(dir, "corrupt"))

        # github-style archive (content nested one down) with TWO top-level
        # directories — previously an @assert failure aborted the install
        multi = mkpath(joinpath(dir, "multi"))
        write(joinpath(mkpath(joinpath(multi, "one")), "f"), "1")
        write(joinpath(mkpath(joinpath(multi, "two")), "f"), "2")
        multiroot = LocalPkgServer.gzip_tarball(multi, joinpath(dir, "multiroot"))

        missing_url = "file://$(joinpath(dir, "no-such-file"))"

        install = VibePkg.Fetch.install_archive
        pkgs = joinpath(dir, "depot", "packages")

        # every bad source (unreachable, corrupt, multi-root) falls through
        # to the good one instead of aborting
        vp = joinpath(pkgs, "Ex", "slug1")
        urls = [
            missing_url => true,
            "file://$(corrupt)" => true,
            "file://$(multiroot)" => false,
            "file://$(good)" => true,
        ]
        ok = @test_logs (:warn, r"(?i)failed to extract") (:warn, r"(?i)one top-level directory") match_mode = :any begin
            install(urls, hash, vp; io = devnull)
        end
        @test ok
        @test read(joinpath(vp, "file.jl"), String) == "module Ex end\n"

        # hash mismatch on the only source: no install, normal false return
        vp2 = joinpath(pkgs, "Ex", "slug2")
        ok2 = @test_logs (:warn, r"(?i)does not match the expected Git tree SHA-1") match_mode = :any begin
            install(["file://$(good)" => true], SHA1("1"^40), vp2; io = devnull)
        end
        @test !ok2
        @test !isdir(vp2)

        # all sources bad: false, not an exception
        vp3 = joinpath(pkgs, "Ex", "slug3")
        ok3 = @test_logs (:warn, r"(?i)failed to extract") match_mode = :any begin
            install([missing_url => true, "file://$(corrupt)" => true], hash, vp3; io = devnull)
        end
        @test !ok3
        @test !isdir(vp3)

        # download/extraction scratch space is cleaned up in every case
        @test isempty(readdir(joinpath(pkgs, "temp")))
    end
end
