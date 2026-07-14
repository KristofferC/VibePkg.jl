# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Logging
using VibePkg.MiniProgressBars

@testset "MiniProgressBars" begin
    bar = MiniProgressBar(header = "Downloading", color = :cyan, mode = :data, always_reprint = true)
    bar.max = 2 * 1024 * 1024
    bar.current = 1024 * 1024
    io = IOContext(IOBuffer(), :color => true, :displaysize => (24, 80))
    show_progress(io, bar)
    out = String(take!(io.io))
    @test occursin("Downloading", out)
    @test occursin("MiB", out)

    bar = MiniProgressBar(header = "Fetching:", mode = :percentage, always_reprint = true)
    bar.max = 4; bar.current = 1
    io = IOContext(IOBuffer(), :displaysize => (24, 80))
    show_progress(io, bar)
    @test occursin("25.0 %", String(take!(io.io)))

    # Pkg.jl#3581: unchanged state emits nothing; a redraw is one \r-anchored
    # line with no cursor-movement escapes
    bar = MiniProgressBar(header = "Updating", mode = :percentage)
    bar.max = 100; bar.current = 10
    io = IOContext(IOBuffer(), :displaysize => (24, 80))
    show_progress(io, bar)
    @test !isempty(String(take!(io.io)))
    show_progress(io, bar)                       # unchanged: no output
    @test isempty(String(take!(io.io)))
    bar.current = 50
    bar.time_shown = 0.0                         # defeat the time throttle
    show_progress(io, bar)
    out = String(take!(io.io))
    @test endswith(out, "\r") && count(==('\r'), out) == 1
    @test !occursin("\e[A", out) && !occursin("\e[1A", out)

    # progress going backwards (git objects → deltas phase) still redraws
    bar.current = 10
    bar.time_shown = 0.0
    show_progress(io, bar)
    @test occursin("10.0 %", String(take!(io.io)))

    # a header change alone redraws (git's "Resolving Deltas:" switch)
    bar.header = "Resolving Deltas:"
    bar.time_shown = 0.0
    show_progress(io, bar)
    @test occursin("Resolving", String(take!(io.io)))

    # a status change alone redraws; status text replaces the bar
    # (the indeterminate no-Content-Length download display)
    bar = MiniProgressBar(header = "Downloading", mode = :data)
    io = IOContext(IOBuffer(), :displaysize => (24, 80))
    bar.status = "1.2 MiB"
    show_progress(io, bar)
    @test occursin("1.2 MiB", String(take!(io.io)))
    bar.status = "2.4 MiB"
    bar.time_shown = 0.0
    show_progress(io, bar)
    @test occursin("2.4 MiB", String(take!(io.io)))

    # current > max (server understated Content-Length) must not draw past
    # the bar width or error
    bar = MiniProgressBar(header = "Downloading", mode = :data, always_reprint = true)
    bar.max = 100; bar.current = 250
    io = IOContext(IOBuffer(), :color => true, :displaysize => (24, 80))
    show_progress(io, bar)
    out = String(take!(io.io))
    @test count(==('━'), out) <= bar.width

    # in-flight names: rendered as dimmed lines under the bar
    bar = MiniProgressBar(header = "Downloading packages", mode = :int, always_reprint = true)
    bar.max = 4; bar.current = 1
    bar.below = ["PkgA", "PkgB"]
    io = IOContext(IOBuffer(), :displaysize => (24, 80))
    show_progress(io, bar)
    out = String(take!(io.io))
    @test occursin("\n\e[2K      PkgA", out) && occursin("\n\e[2K      PkgB", out)
    @test bar.prev_lines == 3
    # a redraw rewrites the block in place: up over it, then line by line
    bar.current = 2
    show_progress(io, bar)
    @test startswith(String(take!(io.io)), "\e[2A\e[2K")
    # shrinking wipes the leftover lines and moves back up
    bar.below = ["PkgB"]
    show_progress(io, bar)
    out = String(take!(io.io))
    @test occursin("\n\e[2K\e[1A", out) && bar.prev_lines == 2
    # long names are truncated to the terminal width
    bar.below = ["X"^200]
    show_progress(io, bar)
    @test occursin("…", String(take!(io.io)))
    # end_progress erases the whole block
    bar.below = ["PkgA", "PkgB"]
    show_progress(io, bar)
    take!(io.io)
    end_progress(io, bar)
    @test String(take!(io.io)) == "\e[1G\e[2K\e[1A\e[2K\e[1A\e[2K\e[?25h"

    # force overrides the redraw throttles
    bar = MiniProgressBar(header = "Updating", mode = :percentage)
    bar.max = 100; bar.current = 10
    io = IOContext(IOBuffer(), :displaysize => (24, 80))
    show_progress(io, bar)
    take!(io.io)
    show_progress(io, bar; force = true)
    @test !isempty(String(take!(io.io)))

    # ProgressLogger: log records erase the block, print, and redraw below
    bar = MiniProgressBar(header = "Downloading packages", mode = :int, always_reprint = true)
    bar.max = 2; bar.current = 1
    bar.below = ["PkgA"]
    io = IOContext(IOBuffer(), :displaysize => (24, 80))
    show_progress(io, bar)
    take!(io.io)
    logio = IOBuffer()
    logger = ProgressLogger(Logging.ConsoleLogger(logio), io, bar)
    Logging.with_logger(logger) do
        @warn "tarball mismatch"
    end
    @test startswith(String(take!(io.io)), "\e[1G\e[2K\e[1A\e[2K")   # erase block, then redraw
    @test occursin("tarball mismatch", String(take!(logio)))
end
