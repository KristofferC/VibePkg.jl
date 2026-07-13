# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
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
end
