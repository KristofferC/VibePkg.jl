# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using VibePkg
using VibePkg.Configs: Config
using VibePkg.Utils: normalize_path_for_toml, denormalize_path_from_toml

# Pkg.jl misc.jl "inference" — the stdlib lookup constants are concretely
# typed so accessing them stays type-stable.
@testset "inference" begin
    f1() = VibePkg.Stdlibs.STDLIBS_BY_VERSION
    @test (@inferred f1()) === VibePkg.Stdlibs.STDLIBS_BY_VERSION
    f2() = VibePkg.Stdlibs.UNREGISTERED_STDLIBS
    @test (@inferred f2()) === VibePkg.Stdlibs.UNREGISTERED_STDLIBS
end

# Pkg.jl misc.jl "normalize_path_for_toml" — relative paths are rendered with
# forward slashes on Windows for cross-platform manifests; absolute paths and
# every path on Unix are left untouched. denormalize is its read-time inverse.
@testset "normalize_path_for_toml" begin
    if Sys.iswindows()
        @test normalize_path_for_toml("foo\\bar\\baz") == "foo/bar/baz"
        @test normalize_path_for_toml("..\\parent\\dir") == "../parent/dir"
        @test normalize_path_for_toml(".\\current") == "./current"
        @test normalize_path_for_toml("C:\\absolute\\path") == "C:\\absolute\\path"
        # round trip back to native separators
        @test denormalize_path_from_toml("foo/bar/baz") == "foo\\bar\\baz"
    else
        @test normalize_path_for_toml("foo/bar/baz") == "foo/bar/baz"
        @test normalize_path_for_toml("../parent/dir") == "../parent/dir"
        @test normalize_path_for_toml("./current") == "./current"
        @test normalize_path_for_toml("/absolute/path") == "/absolute/path"
        @test denormalize_path_from_toml("foo/bar/baz") == "foo/bar/baz"
    end
end

# Pkg.jl api.jl "set number of concurrent requests" — the download concurrency
# comes from JULIA_PKG_CONCURRENT_DOWNLOADS (default 8). Unlike Pkg (which
# errors on 0), VibePkg clamps to at least 1 and falls back to 8 on garbage.
@testset "concurrent-download config" begin
    @test withenv(() -> Config().concurrency, "JULIA_PKG_CONCURRENT_DOWNLOADS" => nothing) == 8
    @test withenv(() -> Config().concurrency, "JULIA_PKG_CONCURRENT_DOWNLOADS" => "5") == 5
    @test withenv(() -> Config().concurrency, "JULIA_PKG_CONCURRENT_DOWNLOADS" => "0") == 1
    @test withenv(() -> Config().concurrency, "JULIA_PKG_CONCURRENT_DOWNLOADS" => "garbage") == 8
end

# Pkg.jl#4438 / issue #2728 — depot cache directories get a CACHEDIR.TAG file
# (Cache Directory Tagging Spec) so backup tools skip them. The tag carries the
# spec's exact signature on the first line, is written once (idempotent), and
# creation silently no-ops on a read-only directory.
@testset "create_cachedir_tag" begin
    cct = VibePkg.Utils.create_cachedir_tag
    mktempdir() do dir
        @test cct(dir) === nothing
        tag = joinpath(dir, "CACHEDIR.TAG")
        @test isfile(tag)
        content = read(tag, String)
        @test startswith(content, "Signature: 8a477f597d28d172789f06886806bc55")
        @test occursin("bford.info/cachedir", content)
        # idempotent: an existing tag is never overwritten
        write(tag, "custom")
        cct(dir)
        @test read(tag, String) == "custom"
    end
    # a read-only directory is tolerated (no throw, no tag)
    if !Sys.iswindows()
        mktempdir() do dir
            ro = mkpath(joinpath(dir, "ro"))
            chmod(ro, 0o555)
            try
                @test cct(ro) === nothing
                @test !isfile(joinpath(ro, "CACHEDIR.TAG"))
            finally
                chmod(ro, 0o755)
            end
        end
    end
end

# Pkg.jl misc.jl "subprocess_handler forwards interrupts to the child" — at the
# REPL a ^C only raises an InterruptException in the parent; the test/build
# child must be signalled explicitly or it gets SIGKILLed without reporting.
# Use a shell child so this doesn't depend on julia's own SIGINT handling.
@testset "subprocess_handler forwards interrupts to the child" begin
    if Sys.iswindows()
        @test_skip "SIGINT forwarding not exercised on Windows"
    else
        mktempdir() do dir
            marker = joinpath(dir, "started")
            outfile = joinpath(dir, "out.log")
            script = """
            trap 'echo CHILD ABORT REPORT; exit 7' INT
            : > $(marker)
            while true; do sleep 0.1; done
            """
            cmd = `sh -c $script`
            p, interrupted = open(outfile, "w") do f
                t = @async VibePkg.TestOps.subprocess_handler(cmd, f, "Tests interrupted")
                @test timedwait(() -> isfile(marker), 60) == :ok
                schedule(t, InterruptException(); error = true)   # simulate ^C in the parent
                fetch(t)
            end
            @test interrupted
            @test p.exitcode == 7                    # child trapped INT, reported, exited
            @test p.termsignal in (0, -1)            # not SIGKILLed
            @test occursin("CHILD ABORT REPORT", read(outfile, String))
        end
    end
end
