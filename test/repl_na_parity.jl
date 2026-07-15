# Public REPL behaviors that were previously classified as N/A solely because
# VibePkg had not implemented the corresponding surface.
using Test
using REPL
using UUIDs: UUID
using VibePkg
using VibePkg.REPLMode
import TOML

if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

const _REPL_NA_EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
const _REPL_NA_JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
const _REPL_NA_EXT = Base.get_extension(VibePkg, :REPLExt)

function _repl_na_registry(depot, fixture)
    reg = mkpath(joinpath(depot, "registries", "MissingHookRegistry"))
    write(
        joinpath(reg, "Registry.toml"),
        """
        name = "MissingHookRegistry"
        uuid = "c00812b8-4e73-405d-b91e-f4361f7b1d84"

        [packages]
        $_REPL_NA_EXAMPLE_UUID = { name = "Example", path = "E/Example" }
        $_REPL_NA_JULIA_UUID = { name = "julia", path = "J/julia" }
        """,
    )
    pkg = mkpath(joinpath(reg, "E", "Example"))
    open(joinpath(pkg, "Package.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "name" => "Example", "uuid" => string(_REPL_NA_EXAMPLE_UUID),
                "repo" => fixture.git_repo,
            ),
        )
    end
    write(
        joinpath(pkg, "Versions.toml"),
        "[\"0.5.5\"]\ngit-tree-sha1 = $(repr(fixture.version_hashes["0.5.5"]))\n",
    )
    julia_pkg = mkpath(joinpath(reg, "J", "julia"))
    write(
        joinpath(julia_pkg, "Package.toml"),
        "name = \"julia\"\nuuid = $(repr(string(_REPL_NA_JULIA_UUID)))\n",
    )
    write(joinpath(julia_pkg, "Versions.toml"), "# dummy registry entry\n")
    return reg
end

@testset "REPL N/A parity" begin
    @test _REPL_NA_EXT !== nothing

    @testset "why: REPL (new.jl:2025)" begin
        REPLMode.TEST_MODE[] = true
        try
            api, args, opts = only(do_cmd("why Foo"))
            @test api === VibePkg.API.why
            @test args == Any[["Foo"]]
            @test isempty(opts)
            @test_throws VibePkg.PkgError do_cmd("why Foo Bar")
        finally
            REPLMode.TEST_MODE[] = false
        end
    end

    @testset "package subcommands (repl.jl:792)" begin
        REPLMode.TEST_MODE[] = true
        try
            api, args, _ = only(do_cmd("package add Example"))
            @test api === VibePkg.API.add
            @test only(args[1]).name == "Example"
            api, args, _ = only(do_cmd("package rm Example"))
            @test api === VibePkg.API.rm
            @test args == Any[["Example"]]
        finally
            REPLMode.TEST_MODE[] = false
        end
    end

    @testset "missing-package hook and interactive compat" begin
        fixture = LocalPkgServer.ensure!()
        old_active = Base.ACTIVE_PROJECT[]
        old_depots = copy(Base.DEPOT_PATH)
        old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
        try
            mktempdir() do root
                root = realpath(root)
                depot = mkpath(joinpath(root, "depot"))
                env = mkpath(joinpath(root, "env"))
                _repl_na_registry(depot, fixture)
                Base.ACTIVE_PROJECT[] = joinpath(env, "Project.toml")
                append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
                # The synthetic registry is immutable and intentionally has
                # no remote; the hook's accepted install remains a public add.
                VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true

                withenv("JULIA_PKG_SERVER" => fixture.url) do
                    @test _REPL_NA_EXT.try_prompt_pkg_add(
                        Symbol[:notapackage]; input_io = IOBuffer("y\n"), io = devnull,
                    ) == false
                    @test _REPL_NA_EXT.try_prompt_pkg_add(
                        Symbol[:julia]; input_io = IOBuffer("y\n"), io = devnull,
                    ) == false
                    @test _REPL_NA_EXT.try_prompt_pkg_add(
                        Symbol[:Example]; input_io = IOBuffer("n\n"), io = devnull,
                    ) == false
                    @test !haskey(VibePkg.dependencies(), _REPL_NA_EXAMPLE_UUID)
                    @test _REPL_NA_EXT.try_prompt_pkg_add(
                        Symbol[:Example]; input_io = IOBuffer("y\n"), io = devnull,
                    ) == true
                    @test haskey(VibePkg.dependencies(), _REPL_NA_EXAMPLE_UUID)
                    @test _REPL_NA_EXT.try_prompt_pkg_add in REPL.install_packages_hooks

                    # The explicit `package` namespace executes the same
                    # public add/rm workflow, not merely a parser alias.
                    do_cmd("package rm Example"; io = devnull)
                    @test !haskey(VibePkg.dependencies(), _REPL_NA_EXAMPLE_UUID)
                    do_cmd("package add Example"; io = devnull)
                    @test haskey(VibePkg.dependencies(), _REPL_NA_EXAMPLE_UUID)

                    # One down-arrow selects Example after the leading julia
                    # entry, then edits its empty compat to an incompatible
                    # 0.4. The entry is kept and the compliance error printed.
                    input = Base.BufferStream()
                    write(input, "\e[B\r0.4\r")
                    close(input)
                    output = IOBuffer()
                    _REPL_NA_EXT.interactive_compat(; io = output, input_io = input)
                    text = String(take!(output))
                    project = TOML.parsefile(joinpath(env, "Project.toml"))
                    @test project["compat"]["Example"] == "0.4"
                    @test occursin("Example = \"0.4\"", text)
                    @test occursin("checking for compliance with the new compat rules", text)
                    @test occursin("do not satisfy the project's [compat] constraint", text)

                    # Pkg.jl #3828: backspace on the empty first (`julia`)
                    # entry, including repeated backspace, is a no-op.
                    input = Base.BufferStream()
                    write(input, "\r\x7f\x7f \r")
                    close(input)
                    @test _REPL_NA_EXT.interactive_compat(
                        ; io = devnull, input_io = input,
                    ) === nothing
                end
            end
        finally
            Base.ACTIVE_PROJECT[] = old_active
            append!(empty!(Base.DEPOT_PATH), old_depots)
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
        end
    end
end
