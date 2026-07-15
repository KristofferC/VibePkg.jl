# End-to-end tests that need a *fresh* julia process (to load a package at one
# version and observe operations against another) — the same approach Pkg.jl
# uses. Each subprocess boots on the loose worker stack so it can load VibePkg,
# then calls isolate!()/ensure!() to switch to the strict fixture depot+server.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()
LocalPkgServer.ensure!()

using Test
using VibePkg
import TOML

# Run `code` in a fresh julia that loads VibePkg and isolates onto the fixture
# depot+server; returns (combined stdout+stderr, success::Bool).
function vibepkg_subprocess(code::AbstractString)
    cmd = vibepkg_cmd(code)
    iob = IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = iob, stderr = iob))
    return String(take!(iob)), success(p)
end

# Build the julia command for `code` with the loose boot stack. `test_depot`
# overrides VIBEPKG_TEST_DEPOT so several processes can isolate onto ONE shared
# depot (for concurrency tests).
function vibepkg_cmd(code::AbstractString; test_depot::Union{Nothing, String} = nothing)
    sep = Sys.iswindows() ? ';' : ':'
    prelude = string(
        "using VibePkg\n",
        "include(raw\"", joinpath(@__DIR__, "local_pkg_server.jl"), "\")\n",
        "LocalPkgServer.isolate!(); LocalPkgServer.ensure!()\n",
    )
    env = [
        "JULIA_LOAD_PATH" => join(["@", pkgdir(VibePkg), "@stdlib"], sep),
        "JULIA_DEPOT_PATH" => LocalPkgServer.worker_depot_path(),
        "JULIA_PROJECT" => nothing,
    ]
    test_depot === nothing || push!(env, "VIBEPKG_TEST_DEPOT" => test_depot)
    return addenv(`$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --color=no -e $(prelude * code)`, env...)
end

# Pkg.jl new.jl "test entryfile entries" — neither package has the conventional
# src/Name.jl entry point. Resolving must copy the path dependency's `entryfile`
# into the manifest so Julia's package loader can find both packages in a brand
# new process that has never loaded either module.
@testset "entryfile packages load in a fresh subprocess" begin
    mktempdir() do dir
        root = joinpath(dir, "ProjectPath")
        dep = joinpath(root, "ProjectPathDep")
        mkpath(dep)
        write(
            joinpath(root, "Project.toml"),
            """
            name = "ProjectPath"
            uuid = "32833bde-7fc1-4d28-8365-9d01e1bcbc1b"
            version = "0.1.0"
            entryfile = "CustomPath.jl"

            [deps]
            ProjectPathDep = "f18633fc-8799-43ff-aa06-99ed830dc572"

            [sources]
            ProjectPathDep = {path = "ProjectPathDep"}
            """,
        )
        write(
            joinpath(root, "CustomPath.jl"),
            """
            module ProjectPath
            using ProjectPathDep
            value() = "root/" * ProjectPathDep.value()
            end
            """,
        )
        write(
            joinpath(dep, "Project.toml"),
            """
            name = "ProjectPathDep"
            uuid = "f18633fc-8799-43ff-aa06-99ed830dc572"
            version = "0.1.0"
            entryfile = "CustomPath.jl"
            """,
        )
        write(
            joinpath(dep, "CustomPath.jl"),
            """
            module ProjectPathDep
            value() = "dependency"
            end
            """,
        )

        old_project = Base.ACTIVE_PROJECT[]
        try
            VibePkg.activate(root; io = devnull)
            VibePkg.resolve(; io = devnull)
        finally
            Base.ACTIVE_PROJECT[] = old_project
        end

        raw_manifest = TOML.parsefile(joinpath(root, "Manifest.toml"))
        dep_entry = only(raw_manifest["deps"]["ProjectPathDep"])
        @test dep_entry["entryfile"] == "CustomPath.jl"

        code = "using ProjectPath, ProjectPathDep; print(ProjectPath.value(), \"|\", ProjectPathDep.value())"
        cmd = `$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --compiled-modules=no --color=no --project=$root -e $code`
        iob = IOBuffer()
        process = run(pipeline(ignorestatus(cmd); stdout = iob, stderr = iob))
        out = String(take!(iob))
        success(process) || println(out)
        @test success(process)
        @test out == "root/dependency|dependency"
    end
end

# Pkg.jl new.jl "Concurrent setup/installation/precompilation across processes"
# — several processes adding the same package into one shared depot must not
# corrupt it; exactly one actually installs the tree (the rest block on its
# pidfile lock, then find it present).
@testset "concurrent add installs exactly once" begin
    mktempdir() do shared
        cmd = vibepkg_cmd(
            """
            VibePkg.activate(temp=true)
            VibePkg.add(VibePkg.PackageSpec(name="Example", version=v"0.5.4"))
            using Example
            """;
            test_depot = shared,               # all workers isolate to this one depot
        )
        # the installer is identified by Fetch's `@debug "Installed ..."`
        cmd = addenv(cmd, "JULIA_DEBUG" => "VibePkg")
        installed = Threads.Atomic{Int}(0)
        failed = Threads.Atomic{Int}(0)
        outs = fill("", 3)
        @sync for i in 1:3
            Threads.@spawn begin
                iob = IOBuffer()
                p = run(pipeline(ignorestatus(cmd); stdout = iob, stderr = iob))
                s = String(take!(iob))
                outs[i] = s
                success(p) || Threads.atomic_add!(failed, 1)
                occursin(r"Installed Example", s) && Threads.atomic_add!(installed, 1)
            end
        end
        (failed[] == 0 && installed[] == 1) || foreach(println, outs)
        @test failed[] == 0                    # no corruption / crash
        @test installed[] == 1                 # exactly one process installed it
    end
end

# Pkg.jl new.jl "status showing incompatible loaded deps" — status annotates a
# dependency with `[loaded: v…]` when the version loaded in the session differs
# from the one recorded in the active environment.
@testset "status shows loaded-version mismatch" begin
    out, ok = vibepkg_subprocess(
        """
        VibePkg.activate(temp=true)
        VibePkg.add(VibePkg.PackageSpec(name="Example", version=v"0.5.4"); io=stderr)
        using Example
        VibePkg.activate(temp=true)
        VibePkg.add(VibePkg.PackageSpec(name="Example", version=v"0.5.5"); io=stderr)
        VibePkg.status(io=stdout)
        """
    )
    ok || println(out)
    @test ok
    @test occursin("[loaded: v0.5.4]", out)
end

# Pkg.jl new.jl "Pkg.add prefers loaded dependency versions" — a plain add picks
# the newest version, but add(prefer_loaded_versions=true) (and the REPL-mode
# default) picks the version already loaded in the session and says so.
@testset "add prefers the loaded version" begin
    out, ok = vibepkg_subprocess(
        """
        io = IOBuffer()
        VibePkg.activate(temp=true)
        VibePkg.add(VibePkg.PackageSpec(name="Example", version=v"0.5.4"); io)
        @assert occursin("+ Example v0.5.4", String(take!(io)))
        using Example
        VibePkg.activate(temp=true)
        VibePkg.add("Example"; io)                        # newest: 0.5.5
        @assert occursin("+ Example v0.5.5", String(take!(io)))
        VibePkg.activate(temp=true)
        VibePkg.add("Example"; io, prefer_loaded_versions=true)
        o = String(take!(io))
        @assert occursin("was able to add the version of Example that is already loaded", o)
        @assert occursin("+ Example v0.5.4", o)
        VibePkg.activate(temp=true)
        Base.ScopedValues.@with VibePkg.API.IN_REPL_MODE => true begin
            VibePkg.add("Example"; io)                    # REPL default prefers loaded
        end
        o = String(take!(io))
        @assert occursin("was able to add the version of Example that is already loaded", o)
        @assert occursin("+ Example v0.5.4", o)
        println("PREFER_LOADED_OK")
        """
    )
    ok || println(out)
    @test occursin("PREFER_LOADED_OK", out)
end

# Pkg.jl pkg.jl "test atomicity of write_env_usage (parallel processes)" —
# several processes hammering the shared depot's usage log concurrently must
# never corrupt it (log_usage takes a pidlock and writes atomically). All
# workers succeed and the resulting log is still valid, non-empty TOML.
@testset "concurrent usage-log writes stay atomic" begin
    mktempdir() do shared
        cmd = vibepkg_cmd(
            """
            VibePkg.activate(temp=true)
            VibePkg.add(VibePkg.PackageSpec(name="Example", version=v"0.5.4"); io=devnull)
            for _ in 1:20
                VibePkg.status(io=devnull)      # loading the env writes manifest_usage.toml
            end
            println("USAGE_OK")
            """;
            test_depot = shared,
        )
        n = 4
        oks = Threads.Atomic{Int}(0)
        @sync for _ in 1:n
            Threads.@spawn begin
                iob = IOBuffer()
                p = run(pipeline(ignorestatus(cmd); stdout = iob, stderr = iob))
                (success(p) && occursin("USAGE_OK", String(take!(iob)))) && Threads.atomic_add!(oks, 1)
            end
        end
        @test oks[] == n                       # every worker finished cleanly
        usage_file = joinpath(shared, "logs", "manifest_usage.toml")
        @test isfile(usage_file)
        parsed = TOML.parsefile(usage_file)    # never a partial/garbled write
        @test parsed isa Dict && !isempty(parsed)
    end
end

# Pkg.jl api.jl "pidlocked precompile" — two processes precompiling the same
# slow package contend on its pidlock: one does the work ("Precompiling"), the
# other waits and reports it is being precompiled elsewhere.
@testset "pidlocked precompile" begin
    mktempdir() do dir
        shared = mkpath(joinpath(dir, "depot"))
        proj = mkpath(joinpath(dir, "proj"))
        slow = joinpath(dir, "SlowPkg")
        mkpath(joinpath(slow, "src"))
        write(joinpath(slow, "Project.toml"), "name=\"SlowPkg\"\nuuid=\"aaaaaaaa-0000-0000-0000-0000000000ff\"\nversion=\"0.1.0\"\n")
        write(joinpath(slow, "src", "SlowPkg.jl"), "module SlowPkg\nsleep(8)\nend\n")   # slow to precompile
        # setup: dev + resolve so the manifest exists before the race
        setup = vibepkg_cmd(
            "VibePkg.activate(raw\"$proj\"); VibePkg.develop(VibePkg.PackageSpec(path=raw\"$slow\"); io=devnull); VibePkg.resolve(io=devnull)";
            test_depot = shared,
        )
        @test success(run(pipeline(ignorestatus(setup); stdout = devnull, stderr = devnull)))

        pc = vibepkg_cmd("VibePkg.activate(raw\"$proj\"); VibePkg.precompile(io=stderr)"; test_depot = shared)
        outs = fill("", 2)
        @sync for i in 1:2
            Threads.@spawn begin
                iob = IOBuffer()
                run(pipeline(ignorestatus(pc); stdout = iob, stderr = iob))
                outs[i] = String(take!(iob))
            end
        end
        both = join(outs, "\n")
        @test occursin("Precompiling", both)
        @test occursin("Being precompiled by another process", both)
    end
end
