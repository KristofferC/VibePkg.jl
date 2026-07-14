# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
# REPL must load before isolate!(): it triggers the REPLExt extension, whose
# precompile subprocess needs the boot depot stack to still see VibePkg's
# dependency sources in the user depot
using REPL
LocalPkgServer.isolate!()

using Test
using Base: UUID
using VibePkg
using VibePkg.REPLMode
using VibePkg.REPLMode: parse_package_word
using VibePkg: PackageSpec
using VibePkg.Planning: UPLEVEL_MINOR
using VibePkg.Errors: PkgError

@testset "REPLMode" begin
    REPLMode.TEST_MODE[] = true
    try
        capture(s) = only(do_cmd(s))

        # command → api mapping with package specs
        api, args, opts = capture("add Example")
        @test api === VibePkg.API.add
        @test args[1] == [PackageSpec("Example")]

        api, args, opts = capture("add Example@0.5.1 Other=22222222-2222-2222-2222-222222222222")
        @test args[1][1] == PackageSpec("Example", "0.5.1")
        @test args[1][2].uuid == UUID("22222222-2222-2222-2222-222222222222")

        # `.jl` suffix is stripped
        api, args, _ = capture("add Example.jl")
        @test args[1] == [PackageSpec("Example")]

        # urls and paths route to the right kwarg forms
        api, args, opts = capture("add https://github.com/JuliaLang/Example.jl#master")
        @test api === VibePkg.API.add
        @test args[1] == [PackageSpec(; url = "https://github.com/JuliaLang/Example.jl", rev = "master")]

        # name#rev and mixed forms parse in one statement
        api, args, _ = capture("add Example#master Other")
        @test args[1] == [PackageSpec(; name = "Example", rev = "master"), PackageSpec("Other")]

        # subdir specifiers on urls, paths, and names
        api, args, _ = capture("add https://github.com/Company/MonoRepo:juliapkgs/Package.jl")
        @test args[1] == [PackageSpec(; url = "https://github.com/Company/MonoRepo", subdir = "juliapkgs/Package.jl")]
        api, args, _ = capture("add ssh://git@server.com/repo.git:subdir/nested")
        @test args[1] == [PackageSpec(; url = "ssh://git@server.com/repo.git", subdir = "subdir/nested")]
        api, args, _ = capture("add https://example.com:8080/git/repo.git:packages/core")
        @test args[1] == [PackageSpec(; url = "https://example.com:8080/git/repo.git", subdir = "packages/core")]
        api, args, _ = capture("add https://github.com/TimG1964/XLSX.jl#Bug-fixing-post-#289:subdir")
        @test args[1] == [PackageSpec(; url = "https://github.com/TimG1964/XLSX.jl", rev = "Bug-fixing-post-#289", subdir = "subdir")]
        api, args, _ = capture("dev ./Mono:sub/dir")
        @test args[1] == [PackageSpec(; path = "./Mono", subdir = "sub/dir")]
        api, args, _ = capture("add Example:sub")
        @test args[1] == [PackageSpec(; name = "Example", subdir = "sub")]

        # windows drive letters are not subdir separators
        api, args, _ = capture("add C:\\Users\\test\\project")
        @test args[1] == [PackageSpec(; path = "C:\\Users\\test\\project")]
        api, args, _ = capture("add C:\\Users\\test\\project:subdir")
        @test args[1] == [PackageSpec(; path = "C:\\Users\\test\\project", subdir = "subdir")]

        # scp-style ssh urls, including non-git users and IP hosts
        api, args, _ = capture("add git@github.com:user/repo.git#feature")
        @test args[1] == [PackageSpec(; url = "git@github.com:user/repo.git", rev = "feature")]
        api, args, _ = capture("add user@10.20.30.40:PackageName.jl")
        @test args[1] == [PackageSpec(; url = "user@10.20.30.40:PackageName.jl")]
        api, args, _ = capture("add user@server.com:Repo.jl")
        @test args[1] == [PackageSpec(; url = "user@server.com:Repo.jl")]
        # Pkg.jl#2054 — scp-style ssh url with a subdir specifier
        api, args, _ = capture("add git@github.com:myorg/myrepo.git:MySubdir")
        @test args[1] == [PackageSpec(; url = "git@github.com:myorg/myrepo.git", subdir = "MySubdir")]

        # github tree/commit/pull urls carry the revision
        api, args, _ = capture("add https://github.com/JuliaLang/Pkg.jl/tree/aa/gitlab")
        @test args[1] == [PackageSpec(; url = "https://github.com/JuliaLang/Pkg.jl", rev = "aa/gitlab")]
        api, args, _ = capture("add https://github.com/JuliaPy/PythonCall.jl/pull/529")
        @test args[1] == [PackageSpec(; url = "https://github.com/JuliaPy/PythonCall.jl", rev = "pull/529/head")]

        # standalone modifier words attach to the previous package
        api, args, _ = capture("add Example @0.5.1")
        @test args[1] == [PackageSpec("Example", "0.5.1")]
        api, args, _ = capture("add Example #master Other")
        @test args[1] == [PackageSpec(; name = "Example", rev = "master"), PackageSpec("Other")]
        api, args, _ = capture("add https://github.com/JuliaLang/Example.jl :sub/dir")
        @test args[1] == [PackageSpec(; url = "https://github.com/JuliaLang/Example.jl", subdir = "sub/dir")]

        # name=uuid composes with a version; the uuid part never carries specifiers
        api, args, _ = capture("add Example=22222222-2222-2222-2222-222222222222@0.5")
        @test args[1] == [PackageSpec(; name = "Example", uuid = UUID("22222222-2222-2222-2222-222222222222"), version = "0.5")]

        # quoted words are literal: no specifier extraction, but a bare
        # `#rev` after the closing quote still attaches
        api, args, _ = capture("add \"Weird#Name\"")
        @test args[1] == [PackageSpec(; name = "Weird#Name")]
        api, args, _ = capture("add \"git@github.com:JuliaLang/Example.jl.git\"#master")
        @test args[1] == [PackageSpec(; url = "git@github.com:JuliaLang/Example.jl.git", rev = "master")]

        api, args, opts = capture("dev ./LocalPkg")
        @test api === VibePkg.API.develop
        @test args[1] == [PackageSpec(; path = "./LocalPkg")]

        api, args, opts = capture("develop Example")
        @test api === VibePkg.API.develop
        @test args[1] == [PackageSpec("Example")]

        # `dev Name.jl` strips the suffix (Pkg REPL parity); `dev Name#rev`
        # parses and is rejected later by validate_specs with the pinned msg
        api, args, _ = capture("dev Example.jl")
        @test args[1] == [PackageSpec("Example")]
        api, args, _ = capture("dev Example#master")
        @test args[1] == [PackageSpec(; name = "Example", rev = "master")]

        # Pkg.jl#2719 — relative paths with `..` parse as paths
        api, args, _ = capture("dev ../Dependency")
        @test args[1] == [PackageSpec(; path = "../Dependency")]

        # Pkg.jl#1435 — `~` expands to the home directory in path words
        api, args, _ = capture("dev ~/SomePkg")
        @test args[1] == [PackageSpec(; path = expanduser("~/SomePkg"))]

        # options map to kwargs; short forms work
        api, args, opts = capture("rm --manifest Foo")
        @test api === VibePkg.API.rm && opts[:mode] === :manifest && args[1] == ["Foo"]
        api, _, opts = capture("st -m")
        @test api === VibePkg.API.status && opts[:mode] === :manifest
        api, _, opts = capture("up --minor")
        @test api === VibePkg.API.up && opts[:level] == UPLEVEL_MINOR
        # Pkg.jl repl.jl rejects conflicting level flags; VibePkg instead takes
        # the last one given (last-wins), so `up --major --minor` == `up --minor`.
        api, _, opts = capture("up --major --minor")
        @test api === VibePkg.API.up && opts[:level] == UPLEVEL_MINOR
        api, _, opts = capture("gc --verbose")
        @test api === VibePkg.API.gc && opts[:verbose] === true
        api, _, opts = capture("gc -v")
        @test api === VibePkg.API.gc && opts[:verbose] === true
        api, args, opts = capture("activate --temp")
        @test api === VibePkg.API.activate && opts[:temp] === true && isempty(args)
        api, _, opts = capture("test --coverage Foo")
        @test api === VibePkg.API.test && opts[:coverage] === true
        api, _, opts = capture("instantiate --julia_version_strict")
        @test api === VibePkg.API.instantiate && opts[:julia_version_strict] === true
        api, _, opts = capture("rm -p Foo")
        @test api === VibePkg.API.rm && opts[:mode] === :project
        api, _, opts = capture("st -p")
        @test api === VibePkg.API.status && opts[:mode] === :project
        api, _, opts = capture("st -o")
        @test api === VibePkg.API.status && opts[:outdated] === true
        api, _, opts = capture("st -d -e")
        @test api === VibePkg.API.status && opts[:diff] === true && opts[:extensions] === true
        api, _, opts = capture("st --deprecated")
        @test api === VibePkg.API.status && opts[:deprecated] === true

        # option arguments and conversions
        api, args, opts = capture("add --preserve=none Example")
        @test api === VibePkg.API.add && opts[:preserve] == VibePkg.API.Planning.PRESERVE_NONE
        api, _, opts = capture("up --preserve=direct Example")
        @test api === VibePkg.API.up && opts[:preserve] == VibePkg.API.Planning.PRESERVE_DIRECT
        api, _, opts = capture("up -m")
        @test api === VibePkg.API.up && opts[:mode] === :manifest
        api, _, opts = capture("up --workspace")
        @test api === VibePkg.API.up && opts[:workspace] === true
        api, args, opts = capture("dev --local Example")
        @test api === VibePkg.API.develop && opts[:shared] === false
        api, _, opts = capture("dev --shared Example")
        @test opts[:shared] === true
        api, args, opts = capture("rm --all")
        @test api === VibePkg.API.rm && opts[:all_pkgs] === true && isempty(args)
        api, args, opts = capture("pin --all")
        @test api === VibePkg.API.pin && opts[:all_pkgs] === true && args == Any[PackageSpec[]]
        api, args, opts = capture("free --all")
        @test api === VibePkg.API.free && opts[:all_pkgs] === true && isempty(args)
        api, _, opts = capture("why --workspace Foo")
        @test api === VibePkg.API.why && opts[:workspace] === true
        api, _, opts = capture("instantiate -p")
        @test api === VibePkg.API.instantiate && opts[:manifest] === false
        api, _, opts = capture("instantiate -m -v -u --workspace")
        @test opts[:manifest] === true && opts[:verbose] === true &&
            opts[:update_on_mismatch] === true && opts[:workspace] === true
        api, _, opts = capture("build -v Foo")
        @test api === VibePkg.API.build && opts[:verbose] === true
        api, args, opts = capture("activate --shared myenv")
        @test api === VibePkg.API.activate && opts[:shared] === true && args == Any["myenv"]

        # add --weak / --extra (and the -w / -e shorts) select the target
        api, args, opts = capture("add --weak Example")
        @test api === VibePkg.API.add && opts[:target] === :weakdeps
        api, _, opts = capture("add -w Example")
        @test opts[:target] === :weakdeps
        api, args, opts = capture("add --extra Example")
        @test api === VibePkg.API.add && opts[:target] === :extras
        api, _, opts = capture("add -e Example")
        @test opts[:target] === :extras

        # precompile takes packages and options
        api, args, opts = capture("precompile")
        @test api === VibePkg.API.precompile && isempty(args) && isempty(opts)
        api, args, opts = capture("precompile --strict --timing --workspace Foo Bar")
        @test api === VibePkg.API.precompile && args[1] == ["Foo", "Bar"]
        @test opts[:strict] === true && opts[:timing] === true && opts[:workspace] === true

        # aliases and no-arg commands
        @test capture("instantiate")[1] === VibePkg.API.instantiate
        @test capture("update")[1] === VibePkg.API.up
        @test capture("compat Example 0.5")[2] == Any["Example", "0.5"]

        # statement chaining
        cmds = do_cmd("add Example; st")
        @test length(cmds) == 2 && cmds[2][1] === VibePkg.API.status

        # quoting
        api, args, _ = capture("activate \"some dir/with space\"")
        @test args == Any["some dir/with space"]

        # registry subcommands parse, with positional arguments
        @test length(do_cmd("registry status")) == 1
        api, args, _ = capture("registry add General")
        @test api === REPLMode.VibePkgRegistryAdd && args == Any["General"]
        api, args, _ = capture("registry rm TestRegistry")
        @test api === REPLMode.VibePkgRegistryRm && args == Any["TestRegistry"]
        api, args, _ = capture("registry remove Foo Bar")
        @test api === REPLMode.VibePkgRegistryRm && args == Any["Foo", "Bar"]
        @test_throws PkgError capture("registry rm")
        api, args, _ = capture("registry update General")
        @test api === REPLMode.VibePkgRegistryUpdate && args == Any["General"]
        @test_throws PkgError capture("registry status Foo")

        # app subcommands: update (0/1 names) and filterable status
        VibeApps = VibePkg.Apps
        api, args, _ = capture("app update")
        @test api === VibeApps.update && isempty(args)
        api, args, _ = capture("app update Foo")
        @test api === VibeApps.update && args == Any["Foo"]
        @test_throws PkgError capture("app update Foo Bar")
        api, args, _ = capture("app status Foo Bar")
        @test api === VibeApps.status && args == Any["Foo", "Bar"]

        # help maps to the help command in all three spellings
        for input in ("?", "? add", "?add", "help add")
            api, args, _ = capture(input)
            @test api === REPLMode.help_command
        end
        @test occursin("registry", sprint(io -> REPLMode.show_help(io)))
        @test occursin("@version", sprint(io -> REPLMode.show_help(io, "add")))
        @test_throws PkgError REPLMode.show_help(devnull, "bogus")

        # completions: commands, options; never throws
        cands, word = REPLMode.completions_for("a")
        @test "add" in cands && "activate" in cands && "app" in cands && word == "a"
        cands, _ = REPLMode.completions_for("rm --")
        @test cands == ["--all", "--manifest", "--project"]
        cands, _ = REPLMode.completions_for("add --pr")
        @test cands == ["--preserve"]
        cands, _ = REPLMode.completions_for("st --o")
        @test cands == ["--outdated"]
        @test isempty(REPLMode.completions_for("bogus wo")[1])

        # Pkg.jl#1453 — unterminated quote must not crash completions
        cands, _ = REPLMode.completions_for("include(\"")
        @test cands isa Vector

        # Pkg.jl#1336 — malformed option must not crash completions
        cands, _ = REPLMode.completions_for("rm -rf ")
        @test cands isa Vector

        # Pkg.jl#4418 / julia#59829 — a command with a trailing space completes
        # its first (package) argument without crashing
        @test REPLMode.completions_for("rm ")[1] isa Vector
        @test REPLMode.completions_for("add ")[1] isa Vector

        # a non-ASCII package name parses as a name (no BoundsError from the
        # Windows drive-letter string-indexing path)
        api, args, _ = capture("add ÖÖÖ")
        @test api === VibePkg.API.add && args[1][1].name == "ÖÖÖ"

        # Pkg.jl#658 — stdlib names complete after add/dev
        cands, _ = REPLMode.completions_for("add LinearAlg")
        @test "LinearAlgebra" in cands

        # Pkg.jl#801 — activate completes directory paths, including `~`
        mktempdir() do dir
            mkdir(joinpath(dir, "subenv"))
            cands, _ = REPLMode.completions_for("activate $(joinpath(dir, "su"))")
            @test joinpath(dir, "subenv") in cands
        end
        cands, _ = REPLMode.completions_for("activate ~/")
        @test all(startswith("~"), cands)

        # Pkg.jl#1003 — unreadable directory must not crash path completion
        if Sys.iswindows()
            @test_skip "chmod cannot make a directory unreadable on Windows"
        else
            mktempdir() do dir
                sub = mkdir(joinpath(dir, "locked"))
                changed_mode = Base.Libc.getuid() != 0
                try
                    changed_mode && chmod(sub, 0o000)
                    cands, _ = REPLMode.completions_for("activate $sub/")
                    @test cands isa Vector
                finally
                    changed_mode && chmod(sub, 0o700)
                end
            end
        end

        # deprecated packages are excluded from add/develop completions
        # (but stay installable — the exclusion is completion-only)
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            reg = joinpath(depot, "registries", "DepReg")
            for (name, uuid, deprecated) in (
                    ("DepGone", "11111111-1111-1111-1111-111111111111", true),
                    ("DepKept", "22222222-2222-2222-2222-222222222222", false),
                )
                pkgdir = mkpath(joinpath(reg, "D", name))
                write(
                    joinpath(pkgdir, "Package.toml"), """
                    name = "$name"
                    uuid = "$uuid"
                    repo = "https://example.invalid/$name.jl.git"
                    $(deprecated ? "[metadata.deprecated]\nreason = \"abandoned\"" : "")
                    """
                )
                write(
                    joinpath(pkgdir, "Versions.toml"), """
                    ["0.1.0"]
                    git-tree-sha1 = "1111111111111111111111111111111111111111"
                    """
                )
            end
            write(
                joinpath(reg, "Registry.toml"), """
                name = "DepReg"
                uuid = "33338594-aafe-5451-b93e-139f81909106"

                [packages]
                11111111-1111-1111-1111-111111111111 = { name = "DepGone", path = "D/DepGone" }
                22222222-2222-2222-2222-222222222222 = { name = "DepKept", path = "D/DepKept" }
                """
            )
            old_depots = copy(Base.DEPOT_PATH)
            VibePkg.Queries.reset_completion_cache!()
            try
                append!(empty!(Base.DEPOT_PATH), [depot])
                withenv("JULIA_PKG_SERVER" => "") do
                    cands, _ = REPLMode.completions_for("add Dep")
                    @test "DepKept" in cands
                    @test !("DepGone" in cands)
                end
            finally
                append!(empty!(Base.DEPOT_PATH), old_depots)
                VibePkg.Queries.reset_completion_cache!()
            end
        end

        # Pkg.jl#1289 — registered names complete after add/dev
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            reg = joinpath(depot, "registries", "NameReg")
            pkgdir = mkpath(joinpath(reg, "E", "Example"))
            write(
                joinpath(pkgdir, "Package.toml"), """
                name = "Example"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                repo = "https://example.invalid/Example.jl.git"
                """
            )
            write(
                joinpath(pkgdir, "Versions.toml"), """
                ["0.5.3"]
                git-tree-sha1 = "1111111111111111111111111111111111111111"
                """
            )
            write(
                joinpath(reg, "Registry.toml"), """
                name = "NameReg"
                uuid = "44448594-aafe-5451-b93e-139f81909106"

                [packages]
                7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
                """
            )
            old_depots = copy(Base.DEPOT_PATH)
            VibePkg.Queries.reset_completion_cache!()
            try
                append!(empty!(Base.DEPOT_PATH), [depot])
                withenv("JULIA_PKG_SERVER" => "") do
                    cands, _ = REPLMode.completions_for("add Exa")
                    @test "Example" in cands
                end
            finally
                append!(empty!(Base.DEPOT_PATH), old_depots)
                VibePkg.Queries.reset_completion_cache!()
            end
        end

        # errors
        @test_throws PkgError do_cmd("frobnicate")
        @test_throws PkgError do_cmd("add")                 # too few args
        @test_throws PkgError do_cmd("rm --bogus Foo")      # unknown option
        @test_throws PkgError do_cmd("rm -x Foo")           # unknown short option
        @test_throws PkgError do_cmd("st -x")               # unknown short option
        @test_throws PkgError do_cmd("add --preserve Foo")  # --preserve requires an argument
        @test_throws PkgError do_cmd("add --preserve=bogus Foo")
        @test_throws PkgError do_cmd("st --diff=yes")       # flag options take no argument
        @test_throws PkgError do_cmd("add \"unterminated")  # quote
        @test_throws PkgError do_cmd("add @0.5")            # modifier without a package
        @test_throws PkgError do_cmd("add Example #a #b")   # duplicate revision specifier
        @test_throws PkgError do_cmd("pin https://github.com/JuliaLang/Example.jl") # urls only for add/dev
    finally
        REPLMode.TEST_MODE[] = false
    end
end

@testset "REPL extension" begin
    ext = Base.get_extension(VibePkg, :REPLExt)
    @test ext !== nothing

    terminal = REPL.Terminals.TTYTerminal("dumb", devnull, devnull, devnull)
    repl = REPL.LineEditREPL(terminal, false)
    repl.history_file = false
    repl.interface = REPL.setup_interface(repl)
    mode = ext.create_mode(repl, repl.interface.modes[1])

    @test mode isa REPL.LineEdit.Prompt
    @test mode.hist === repl.interface.modes[1].hist
end

# Pkg.jl repl.jl "unit test for REPLMode.promptf" + JuliaLang/julia #55850 —
# the interactive prompt reflects the active project's name, marks a shared
# `@vX.Y` environment, appends `[offline]`, and is cached until invalidated.
@testset "REPL prompt (promptf)" begin
    ext = Base.get_extension(VibePkg, :REPLExt)
    old = Base.ACTIVE_PROJECT[]
    try
        mktempdir() do d
            # a named project → "(Name) vpkg> "
            proj = joinpath(d, "MyProj", "Project.toml")
            mkpath(dirname(proj))
            touch(proj)
            Base.ACTIVE_PROJECT[] = proj
            ext.invalidate_prompt!()
            @test ext.promptf() == "(MyProj) vpkg> "

            # a shared vX.Y environment → "(@vX.Y) vpkg> " (#55850)
            vname = "v$(VERSION.major).$(VERSION.minor)"
            venv = joinpath(d, vname, "Project.toml")
            mkpath(dirname(venv))
            touch(venv)
            Base.ACTIVE_PROJECT[] = venv
            ext.invalidate_prompt!()
            @test ext.promptf() == "(@$vname) vpkg> "

            # caching: the prompt is not recomputed until invalidated
            Base.ACTIVE_PROJECT[] = proj
            ext.invalidate_prompt!()
            p1 = ext.promptf()
            VibePkg.API.OFFLINE_MODE[] = true
            try
                @test ext.promptf() == p1                 # still the cached value
                ext.invalidate_prompt!()
                @test ext.promptf() == "(MyProj) [offline] vpkg> "
            finally
                VibePkg.API.OFFLINE_MODE[] = false
                ext.invalidate_prompt!()
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old
        ext.invalidate_prompt!()
    end
end
