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
import LibGit2
import TOML
using Base: UUID
using VibePkg
using VibePkg.REPLMode
using VibePkg.REPLMode: parse_package_word
using VibePkg: PackageSpec
using VibePkg.Planning: UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR
using VibePkg.Errors: PkgError
using VibePkg.Utils: expanduser_path

function write_repl_fixture_package(
        path::String, name::String, uuid::UUID;
        version::VersionNumber = v"0.1.0", with_tests::Bool = false,
    )
    mkpath(joinpath(path, "src"))
    write(
        joinpath(path, "Project.toml"),
        "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"$version\"\n",
    )
    write(
        joinpath(path, "src", "$name.jl"),
        "module $name\nvalue() = 1\nend\n",
    )
    if with_tests
        mkpath(joinpath(path, "test"))
        write(
            joinpath(path, "test", "runtests.jl"),
            "using $name\n@assert $name.value() == 1\n",
        )
    end
    return path
end

function init_repl_fixture_repo(path::String)
    repo = LibGit2.init(path)
    signature = LibGit2.Signature("fixture", "fixture@localhost")
    commit = try
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, "initial"; author = signature, committer = signature)
    finally
        close(repo)
    end
    return commit
end

function write_empty_repl_registry(depot::String, uuid::UUID)
    registry = mkpath(joinpath(depot, "registries", "REPLFixtures"))
    write(
        joinpath(registry, "Registry.toml"),
        "name = \"REPLFixtures\"\nuuid = \"$uuid\"\n\n[packages]\n",
    )
    return registry
end

@testset "REPLMode" begin
    REPLMode.TEST_MODE[] = true
    try
        capture(s) = only(do_cmd(s))

        # command → api mapping with package specs
        api, args, opts = capture("add Example")
        @test api === VibePkg.API.add
        @test args[1] == [PackageSpec("Example")]

        # Bare identifiers stay package names even beside a same-named local
        # directory; an explicit ./ prefix selects the path and the former
        # spelling emits Pkg's helpful local-directory nudge.
        mktempdir() do dir
            cd(dir) do
                mkdir("example")
                api, args, opts = capture("add Example")
                @test args[1] == [PackageSpec("Example")]
                message = "Use `./example` to add or develop the local directory at `$(abspath("example"))`."
                @test_logs (:info, message) begin
                    api, args, opts = capture("add example")
                    @test args[1] == [PackageSpec("example")]
                end
                api, args, opts = capture("add ./example")
                @test args[1] == [PackageSpec(; path = "./example")]
                cd("example") do
                    api, args, opts = capture("add .")
                    @test args[1] == [PackageSpec(; path = ".")]
                end
            end
        end

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
        @test args[1] == [PackageSpec(; path = expanduser_path("~/SomePkg"))]

        # options map to kwargs; short forms work
        api, args, opts = capture("rm --manifest Foo")
        @test api === VibePkg.API.rm && opts[:mode] === :manifest && args[1] == ["Foo"]
        api, _, opts = capture("st -m")
        @test api === VibePkg.API.status && opts[:mode] === :manifest
        @testset "REPL API `up` option conflicts" begin
            # Upgrade-level switches are individually valid and mutually exclusive.
            # Exercise both string input (`vpkg>` / pkgstr) and the argv driver used
            # by the `vpkg` app. Pkg's parser treats even a repeated switch as a
            # conflict because both occurrences map to the same `level` keyword.
            levels = (
                ("major", UPLEVEL_MAJOR),
                ("minor", UPLEVEL_MINOR),
                ("patch", UPLEVEL_PATCH),
                ("fixed", UPLEVEL_FIXED),
            )
            for (flag, level) in levels
                api, _, opts = capture("up --$flag")
                @test api === VibePkg.API.up && opts[:level] == level
                api, _, opts = only(do_cmd(["update", "--$flag"]))
                @test api === VibePkg.API.up && opts[:level] == level
                @test_throws PkgError do_cmd("up --$flag --$flag")
            end
            for first in eachindex(levels), second in (first + 1):length(levels)
                first_flag = levels[first][1]
                second_flag = levels[second][1]
                for command in (
                        "up --$first_flag --$second_flag",
                        "up --$second_flag --$first_flag",
                    )
                    err = try
                        do_cmd(command)
                        nothing
                    catch caught
                        caught
                    end
                    @test err isa PkgError
                    if err isa PkgError
                        @test occursin("conflicting options", lowercase(err.msg))
                        @test occursin("--$first_flag", err.msg)
                        @test occursin("--$second_flag", err.msg)
                    end
                end
                @test_throws PkgError do_cmd(
                    [
                        "update", "--$first_flag", "--$second_flag",
                    ]
                )
            end
        end
        api, _, opts = capture("gc --verbose")
        @test api === VibePkg.API.gc && opts[:verbose] === true
        api, _, opts = capture("gc -v")
        @test api === VibePkg.API.gc && opts[:verbose] === true
        api, args, opts = capture("activate --temp")
        @test api === VibePkg.API.activate && opts[:temp] === true && isempty(args)
        api, args, opts = capture("generate Foo")
        @test api === VibePkg.API.generate && args == Any["Foo"] && isempty(opts)
        withenv("HOME" => mktempdir()) do
            api, args, opts = capture("generate ~/HomePkg")
            @test api === VibePkg.API.generate
            @test args[1] == joinpath(ENV["HOME"], "HomePkg")
            @test isempty(opts)
        end
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

        # statement splitting is quote-aware: a quoted `;` stays literal
        api, args, _ = capture("activate \"dir;name\"")
        @test api === VibePkg.API.activate && args == Any["dir;name"]
        api, args, _ = capture("activate 'dir;name'")
        @test args == Any["dir;name"]
        cmds = do_cmd("activate \"a;b\"; st")
        @test length(cmds) == 2
        @test cmds[1][2] == Any["a;b"] && cmds[2][1] === VibePkg.API.status

        # url recognition covers every scheme the Git layer accepts:
        # `git://` and `file://` words are urls, not paths
        api, args, _ = capture("add git://example.com/Repo")
        @test args[1] == [PackageSpec(; url = "git://example.com/Repo")]
        api, args, _ = capture("add file:///home/user/Repo")
        @test args[1] == [PackageSpec(; url = "file:///home/user/Repo")]
        api, args, _ = capture("add file:///home/user/Repo#branch")
        @test args[1] == [PackageSpec(; url = "file:///home/user/Repo", rev = "branch")]

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
            VibePkg.REPLMode.reset_completion_cache!()
            try
                append!(empty!(Base.DEPOT_PATH), [depot])
                withenv("JULIA_PKG_SERVER" => "") do
                    cands, _ = REPLMode.completions_for("add Dep")
                    @test "DepKept" in cands
                    @test !("DepGone" in cands)
                end
            finally
                append!(empty!(Base.DEPOT_PATH), old_depots)
                VibePkg.REPLMode.reset_completion_cache!()
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
            VibePkg.REPLMode.reset_completion_cache!()
            try
                append!(empty!(Base.DEPOT_PATH), [depot])
                withenv("JULIA_PKG_SERVER" => "") do
                    cands, _ = REPLMode.completions_for("add Exa")
                    @test "Example" in cands
                end
            finally
                append!(empty!(Base.DEPOT_PATH), old_depots)
                VibePkg.REPLMode.reset_completion_cache!()
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
        @test_throws PkgError do_cmd("test --project Example") # invalid option surface
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

    # JuliaLang/julia#58690: the LineEdit-facing method must use the current
    # NamedCompletion/zero-based-region interface, including at an empty
    # insertion range. Exercise the provider directly, not just the core
    # string completion helper.
    @eval REPL.beforecursor(state::NamedTuple) =
        String(state.input_buffer.data[1:(state.input_buffer.ptr - 1)])
    mock_state = (
        input_buffer = let buffer = IOBuffer()
            write(buffer, "add Example")
            seek(buffer, sizeof("add Example"))
            buffer
        end,
    )
    completions, region, should_complete =
        @invokelatest REPL.LineEdit.complete_line(ext.VibeCompletionProvider(), mock_state)
    @test completions isa Vector{REPL.LineEdit.NamedCompletion}
    @test region isa Pair{Int, Int}
    @test should_complete isa Bool

    empty_state = (input_buffer = IOBuffer(),)
    empty_completions, empty_region, empty_should_complete =
        @invokelatest REPL.LineEdit.complete_line(ext.VibeCompletionProvider(), empty_state)
    @test empty_completions isa Vector{REPL.LineEdit.NamedCompletion}
    @test empty_region isa Pair{Int, Int}
    @test empty_should_complete isa Bool
end

# Pkg.jl repl.jl "unit test for REPLMode.promptf" + JuliaLang/julia #55850 —
# the interactive prompt reflects project names and workspace paths, truncates
# long names, marks shared environments, and is cached until invalidated.
@testset "REPL prompt (promptf)" begin
    ext = Base.get_extension(VibePkg, :REPLExt)
    old_project = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    fresh_prompt() = (ext.invalidate_prompt!(); ext.promptf())
    try
        VibePkg.API.OFFLINE_MODE[] = false
        mktempdir() do d
            # A nameless project falls back to its directory name.
            fallback = joinpath(d, "SomeEnv", "Project.toml")
            mkpath(dirname(fallback))
            write(fallback, "")
            Base.ACTIVE_PROJECT[] = fallback
            @test fresh_prompt() == "(SomeEnv) vpkg> "

            # Long root names are capped at 30 columns (27 plus an ellipsis).
            long = joinpath(
                d,
                "this_is_a_test_for_truncating_long_folder_names_in_the_prompt",
                "Project.toml",
            )
            mkpath(dirname(long))
            write(long, "")
            Base.ACTIVE_PROJECT[] = long
            @test fresh_prompt() == "(this_is_a_test_for_truncati...) vpkg> "

            # A declared name wins over the directory. The cached result is
            # stable across file edits until explicitly invalidated; afterward
            # both cwd contexts observe the edited name.
            declared = joinpath(d, "FolderName", "Project.toml")
            mkpath(dirname(declared))
            write(declared, "name = \"DeclaredName\"\n")
            Base.ACTIVE_PROJECT[] = declared
            @test fresh_prompt() == "(DeclaredName) vpkg> "
            write(declared, "name = \"ChangedName\"\n")
            @test ext.promptf() == "(DeclaredName) vpkg> "
            @test ext.invalidate_prompt!() === nothing
            @test ext.CACHED_PROMPT[] === nothing
            @test ext.promptf() == "(ChangedName) vpkg> "
            cd(dirname(declared)) do
                @test fresh_prompt() == "(ChangedName) vpkg> "
            end
            @test fresh_prompt() == "(ChangedName) vpkg> "

            # A workspace member shows the root name and member-relative path.
            workspace = joinpath(d, "workspace")
            member = joinpath(workspace, "member")
            mkpath(member)
            root_project = joinpath(workspace, "Project.toml")
            member_project = joinpath(member, "Project.toml")
            write(
                root_project,
                "name = \"WorkspaceRoot\"\n[workspace]\nprojects = [\"member\"]\n",
            )
            write(member_project, "name = \"MemberName\"\n")
            Base.ACTIVE_PROJECT[] = member_project
            @test fresh_prompt() == "(WorkspaceRoot/member) vpkg> "

            # Shared environments are detected from the depot path, rather
            # than merely because their directory happens to start with `v`.
            depot = mkpath(joinpath(d, "depot"))
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots])
            vname = "v$(VERSION.major).$(VERSION.minor)"
            venv = joinpath(depot, "environments", vname, "Project.toml")
            mkpath(dirname(venv))
            write(venv, "")
            Base.ACTIVE_PROJECT[] = venv
            @test fresh_prompt() == "(@$vname) vpkg> "

            # Offline-mode changes also become visible only after invalidation.
            Base.ACTIVE_PROJECT[] = declared
            ext.invalidate_prompt!()
            p1 = ext.promptf()
            VibePkg.API.OFFLINE_MODE[] = true
            @test ext.promptf() == p1
            @test fresh_prompt() == "(ChangedName) [offline] vpkg> "
        end
    finally
        Base.ACTIVE_PROJECT[] = old_project
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        ext.invalidate_prompt!()
    end

    # Prove default-environment discovery in a fresh Julia process, not just
    # by assigning Base.ACTIVE_PROJECT[] to a version-shaped test path.
    mktempdir() do depot
        code = """
        using VibePkg, REPL
        VibePkg.activate(; io = devnull)
        ext = Base.get_extension(VibePkg, :REPLExt)
        print(ext.promptf())
        """
        sep = Sys.iswindows() ? ';' : ':'
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(VibePkg)) -e $code`,
            "JULIA_DEPOT_PATH" => join(
                [depot, LocalPkgServer.worker_depot_path()], sep
            ),
            "JULIA_LOAD_PATH" => nothing,
            "JULIA_PROJECT" => nothing,
        )
        @test read(cmd, String) ==
            "(@v$(VERSION.major).$(VERSION.minor)) vpkg> "
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl new.jl "activate: repl" (line 426) — the currently-unasserted forms.
# COVERED: plain `activate FooBar` and bare `activate`.
# ⚪ DIVERGENCE: VibePkg does not special-case `@Foo` (shared shorthand) or
#   `-` (previous project); `activate` is a plain :splat command, so those
#   words are passed through literally with no `:shared`/`:prev` option.
# ---------------------------------------------------------------------------
@testset "activate: repl forms (new.jl:426)" begin
    REPLMode.TEST_MODE[] = true
    try
        capture(s) = only(do_cmd(s))

        # regular activate (COVERED — matches Pkg)
        api, args, opts = capture("activate FooBar")
        @test api === VibePkg.API.activate && args == Any["FooBar"] && isempty(opts)

        # no-arg activate (COVERED — matches Pkg)
        api, args, opts = capture("activate")
        @test api === VibePkg.API.activate && isempty(args) && isempty(opts)

        # ⚪ `activate @Foo`: Pkg maps `@Foo` → shared=true, arg "Foo".
        # VibePkg has no `@`-shorthand: the word is a literal positional.
        api, args, opts = capture("activate @Foo")
        @test api === VibePkg.API.activate && args == Any["@Foo"] && isempty(opts)

        # ⚪ `activate -`: Pkg maps `-` → prev=true. VibePkg has no `prev`
        # option; `-` is a literal positional argument.
        api, args, opts = capture("activate -")
        @test api === VibePkg.API.activate && args == Any["-"] && isempty(opts)
    finally
        REPLMode.TEST_MODE[] = false
    end
end

@testset "activate matrix (repl.jl:249)" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_prev = VibePkg.API.PREV_ENV_PATH[]
    old_offline = VibePkg.API.OFFLINE_MODE[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            work = mkdir(joinpath(root, "work"))
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])

            cd(work) do
                # `activate .` targets the cwd without eagerly creating a
                # project file.
                do_cmd("activate ."; io = devnull)
                root_project = joinpath(work, "Project.toml")
                @test Base.active_project() == root_project
                @test !isfile(root_project)

                # Shared environments accept names, never path spellings, and
                # a rejected spelling must leave the active environment alone.
                for bad in (".", "./Foo", "Foo/Bar", "../Bar")
                    @test_throws PkgError do_cmd("activate --shared $bad"; io = devnull)
                    @test Base.active_project() == root_project
                end

                # A cwd directory wins over a same-named path-tracked dep.
                foo_uuid = UUID("f00f0001-f00f-4000-8000-f00f00000001")
                foo = mkpath(joinpath(work, "modules", "Foo"))
                mkpath(joinpath(foo, "src"))
                write(
                    joinpath(foo, "Project.toml"),
                    "name = \"Foo\"\nuuid = \"$foo_uuid\"\nversion = \"0.1.0\"\n",
                )
                write(joinpath(foo, "src", "Foo.jl"), "module Foo end\n")
                mkdir(joinpath(work, "Foo"))
                do_cmd("develop modules/Foo"; io = devnull)

                do_cmd("activate Foo"; io = devnull)
                @test Base.active_project() == joinpath(work, "Foo", "Project.toml")
                do_cmd("activate ."; io = devnull)

                # The explicit shared spelling bypasses both cwd and deps.
                do_cmd("activate --shared Foo"; io = devnull)
                @test Base.active_project() ==
                    joinpath(depot, "environments", "Foo", "Project.toml")
                do_cmd("activate ."; io = devnull)

                # Once the cwd path is gone, a plain name resolves to the
                # developed dependency, including from a different cwd.
                Base.rm(joinpath(work, "Foo"); recursive = true)
                other_cwd = mkdir(joinpath(work, "elsewhere"))
                cd(other_cwd) do
                    do_cmd("activate Foo"; io = devnull)
                    @test Base.active_project() == joinpath(foo, "Project.toml")
                end

                # An explicit path never falls back to a dependency. A new
                # target is activated lazily: neither dir nor file is created.
                do_cmd("activate ."; io = devnull)
                do_cmd("activate ./Foo"; io = devnull)
                @test Base.active_project() == joinpath(work, "Foo", "Project.toml")
                @test !isdir(joinpath(work, "Foo"))
                @test !isfile(joinpath(work, "Foo", "Project.toml"))
                do_cmd("activate ."; io = devnull)

                # A registry-added (non-path-tracked) dependency is not an
                # activation target. Exercise the real add through the local
                # package server, then prove its name still means a new cwd
                # environment rather than the immutable installed source.
                LocalPkgServer.ensure!()
                VibePkg.API.OFFLINE_MODE[] = false
                try
                    do_cmd("add Example"; io = devnull)
                finally
                    VibePkg.API.OFFLINE_MODE[] = true
                end
                installed = VibePkg.dependencies()[
                    UUID("7876af07-990d-54b4-ab0e-23690620f79a"),
                ].source
                @test isdir(installed)
                do_cmd("activate Example"; io = devnull)
                @test Base.active_project() ==
                    joinpath(work, "Example", "Project.toml")
                @test dirname(Base.active_project()) != installed
                do_cmd("activate ."; io = devnull)

                # REPL activation expands HOME before dispatch.
                fake_home = mkdir(joinpath(root, "home"))
                withenv("HOME" => fake_home) do
                    do_cmd("activate ~/HomeEnv"; io = devnull)
                    @test Base.active_project() ==
                        joinpath(fake_home, "HomeEnv", "Project.toml")
                end
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.PREV_ENV_PATH[] = old_prev
        VibePkg.API.OFFLINE_MODE[] = old_offline
    end
end

@testset "cwd-relative develop forms (new.jl:1739)" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_offline = VibePkg.API.OFFLINE_MODE[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        cases = (
            (".", "CwdDot", UUID("c0dd0001-c0dd-4000-8000-c0dd00000001"), :package),
            ("..", "CwdParent", UUID("c0dd0002-c0dd-4000-8000-c0dd00000002"), :src),
            ("./CwdNamed", "CwdNamed", UUID("c0dd0003-c0dd-4000-8000-c0dd00000003"), :parent),
        )
        for (form, name, uuid, cwd_kind) in cases
            mktempdir() do root
                root = realpath(root)
                envdir = mkdir(joinpath(root, "env"))
                package = mkdir(joinpath(root, name))
                src = mkdir(joinpath(package, "src"))
                write(
                    joinpath(package, "Project.toml"),
                    "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
                )
                write(joinpath(src, "$name.jl"), "module $name end\n")
                Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")

                command_cwd = cwd_kind === :package ? package :
                    cwd_kind === :src ? src : root
                cd(command_cwd) do
                    do_cmd("develop $form"; io = devnull)
                end

                info = VibePkg.dependencies()[uuid]
                @test info.name == name
                @test info.is_tracking_path
                @test isdir(info.source)
                @test Base.samefile(info.source, package)
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        VibePkg.API.OFFLINE_MODE[] = old_offline
    end
end

@testset "nested relative develop survives project copy (repl.jl:213)" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_offline = VibePkg.API.OFFLINE_MODE[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        mktempdir() do root
            root = realpath(root)
            original = mkpath(joinpath(root, "original", "HelloWorld"))
            copied_parent = mkpath(joinpath(root, "copied"))
            uuids = (
                UUID("51b10001-51b1-4000-8000-51b100000001"),
                UUID("51b20002-51b2-4000-8000-51b200000002"),
            )
            for (name, uuid) in zip(("SubModule1", "SubModule2"), uuids)
                package = mkpath(joinpath(original, name))
                mkpath(joinpath(package, "src"))
                write(
                    joinpath(package, "Project.toml"),
                    "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
                )
                write(joinpath(package, "src", "$name.jl"), "module $name end\n")
            end

            Base.ACTIVE_PROJECT[] = joinpath(original, "Project.toml")
            cd(original) do
                do_cmd("develop ./SubModule1"; io = devnull)
                tests = mkdir("tests")
                cd(tests) do
                    do_cmd("develop ../SubModule2"; io = devnull)
                end
            end

            env = VibePkg.Environments.load_environment(
                ; depots = VibePkg.Depots.depot_stack(),
            )
            @test VibePkg.EnvFiles.entry_path(env.manifest[uuids[1]]) == "SubModule1"
            @test VibePkg.EnvFiles.entry_path(env.manifest[uuids[2]]) == "SubModule2"
            @test all(uuid -> VibePkg.dependencies()[uuid].version == v"0.1.0", uuids)

            copied = joinpath(copied_parent, "HelloWorld")
            cp(original, copied)
            Base.ACTIVE_PROJECT[] = joinpath(copied, "Project.toml")
            copied_deps = VibePkg.dependencies()
            @test Base.samefile(copied_deps[uuids[1]].source, joinpath(copied, "SubModule1"))
            @test Base.samefile(copied_deps[uuids[2]].source, joinpath(copied, "SubModule2"))
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        VibePkg.API.OFFLINE_MODE[] = old_offline
    end
end

@testset "BigProject multiline REPL input (repl.jl:562)" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            write_empty_repl_registry(
                depot, UUID("b1900000-b190-4000-8000-b19000000000"),
            )
            big = write_repl_fixture_package(
                mkpath(joinpath(root, "BigProject")), "BigProject",
                UUID("b1900001-b190-4000-8000-b19000000001"); with_tests = true,
            )
            dependencies = (
                (
                    "RecursiveDep", UUID("b1900002-b190-4000-8000-b19000000002"),
                ),
                (
                    "SubModule", UUID("b1900003-b190-4000-8000-b19000000003"),
                ),
            )
            for (name, uuid) in dependencies
                write_repl_fixture_package(
                    mkpath(joinpath(big, name)), name, uuid; with_tests = true,
                )
            end

            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(big, "Project.toml")
            cd(big) do
                do_cmd(
                    """
                    dev ./RecursiveDep
                    dev ./SubModule
                    add Random
                    build
                    """; io = devnull,
                )
                deps = VibePkg.dependencies()
                @test all((haskey(deps, uuid) for (_, uuid) in dependencies))
                @test all((deps[uuid].is_tracking_path for (_, uuid) in dependencies))
                @test haskey(deps, UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c"))

                # Each newline is a command boundary here too; both real test
                # subprocesses must run rather than becoming arguments to the
                # first `test` command.
                do_cmd(
                    """
                    test RecursiveDep
                    test SubModule
                    """; io = devnull,
                )
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
    end
end

@testset "quoted local-path add/remove (repl.jl:607)" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            envdir = mkpath(joinpath(root, "environment"))
            write_empty_repl_registry(
                depot, UUID("aadd0000-aadd-4000-8000-aadd00000000"),
            )
            fixtures = (
                (
                    joinpath("space dir", "WeirdName77"), "WeirdName77",
                    UUID("aadd0001-aadd-4000-8000-aadd00000001"),
                ),
                (
                    joinpath("some@d;ir#", "WeirdName78"), "WeirdName78",
                    UUID("aadd0002-aadd-4000-8000-aadd00000002"),
                ),
                (
                    joinpath("two space dir", "QuotedName1"), "QuotedName1",
                    UUID("aadd0003-aadd-4000-8000-aadd00000003"),
                ),
                (
                    joinpath("two'quote'dir", "QuotedName2"), "QuotedName2",
                    UUID("aadd0004-aadd-4000-8000-aadd00000004"),
                ),
            )
            for (relative, name, uuid) in fixtures
                package = write_repl_fixture_package(
                    mkpath(joinpath(root, relative)), name, uuid,
                )
                init_repl_fixture_repo(package)
            end

            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            cd(root) do
                first_path, first_name, first_uuid = fixtures[1]
                do_cmd("add \"$first_path\""; io = devnull)
                @test haskey(VibePkg.dependencies(), first_uuid)
                do_cmd("remove \"$first_name\""; io = devnull)
                @test !haskey(VibePkg.dependencies(), first_uuid)

                second_path, second_name, second_uuid = fixtures[2]
                do_cmd("add \"$second_path\""; io = devnull)
                @test haskey(VibePkg.dependencies(), second_uuid)
                do_cmd("remove '$second_name'"; io = devnull)
                @test !haskey(VibePkg.dependencies(), second_uuid)

                third_path, third_name, third_uuid = fixtures[3]
                fourth_path, fourth_name, fourth_uuid = fixtures[4]
                do_cmd("add '$third_path' \"$fourth_path\""; io = devnull)
                @test all(
                    uuid -> haskey(VibePkg.dependencies(), uuid),
                    (third_uuid, fourth_uuid),
                )
                do_cmd("remove '$third_name' \"$fourth_name\""; io = devnull)
                @test all(
                    uuid -> !haskey(VibePkg.dependencies(), uuid),
                    (third_uuid, fourth_uuid),
                )
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
    end
end

@testset "REPL add/develop :subdir end-to-end" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            envdir = mkpath(joinpath(root, "environment"))
            write_empty_repl_registry(
                depot, UUID("5abd0000-5abd-4000-8000-5abd00000000"),
            )
            repo = mkpath(joinpath(root, "MainRepo"))
            subdir_uuid = UUID("5abd0001-5abd-4000-8000-5abd00000001")
            subdir = write_repl_fixture_package(
                mkpath(joinpath(repo, "SubDir")), "SubDir", subdir_uuid,
            )
            init_repl_fixture_repo(repo)

            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            do_cmd("add $repo:SubDir"; io = devnull)
            added = VibePkg.dependencies()[subdir_uuid]
            @test added.is_tracking_repo
            @test isfile(joinpath(added.source, "Project.toml"))

            do_cmd("rm SubDir"; io = devnull)
            @test !haskey(VibePkg.dependencies(), subdir_uuid)
            do_cmd("develop $repo:SubDir"; io = devnull)
            developed = VibePkg.dependencies()[subdir_uuid]
            @test developed.is_tracking_path
            @test Base.samefile(developed.source, subdir)
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
    end
end

@testset "REPL add/rm/pin/free/update/develop/instantiate workflow" begin
    LocalPkgServer.ensure!()
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    try
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            envdir = mkpath(joinpath(root, "environment"))
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            VibePkg.API.OFFLINE_MODE[] = false
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false

            example_uuid = UUID(LocalPkgServer.EXAMPLE_UUID)
            do_cmd("add Example@0.5.3"; io = devnull)
            @test VibePkg.dependencies()[example_uuid].version == v"0.5.3"
            do_cmd("rm Example"; io = devnull)

            # Space-, comma-, compact-comma-, and leading-whitespace forms all
            # run through the string REPL driver rather than direct API calls.
            for (add_command, rm_command) in (
                    ("add Example, Random", "rm Example Random"),
                    ("add Example,Random", "rm Example,Random"),
                    ("    add Example, Random", "rm Example Random"),
                )
                do_cmd(add_command; io = devnull)
                @test haskey(VibePkg.dependencies(), example_uuid)
                do_cmd(rm_command; io = devnull)
                @test !haskey(VibePkg.dependencies(), example_uuid)
            end

            do_cmd("add Example#master"; io = devnull)
            before_fixed = VibePkg.dependencies()[example_uuid]
            @test before_fixed.is_tracking_repo
            @test before_fixed.git_revision == "master"
            do_cmd("up --fixed"; io = devnull)
            after_fixed = VibePkg.dependencies()[example_uuid]
            @test after_fixed.is_tracking_repo
            @test after_fixed.git_revision == "master"

            do_cmd("pin Example"; io = devnull)
            @test VibePkg.dependencies()[example_uuid].is_pinned
            do_cmd("free Example"; io = devnull)
            @test !VibePkg.dependencies()[example_uuid].is_pinned
            @test_throws PkgError do_cmd("free Example"; io = devnull)

            flow_uuid = UUID("f10a0001-f10a-4000-8000-f10a00000001")
            flow_repo = write_repl_fixture_package(
                mkpath(joinpath(root, "FlowPkg")), "FlowPkg", flow_uuid;
                with_tests = true,
            )
            init_repl_fixture_repo(flow_repo)
            do_cmd("add $flow_repo#master"; io = devnull)
            flow_before = VibePkg.dependencies()[flow_uuid]
            @test flow_before.version == v"0.1.0"
            @test flow_before.is_tracking_repo

            write_repl_fixture_package(
                flow_repo, "FlowPkg", flow_uuid; version = v"0.2.0", with_tests = true,
            )
            repo_handle = LibGit2.GitRepo(flow_repo)
            signature = LibGit2.Signature("fixture", "fixture@localhost")
            try
                LibGit2.add!(repo_handle, "*")
                LibGit2.commit(
                    repo_handle, "version 0.2"; author = signature, committer = signature,
                )
            finally
                close(repo_handle)
            end
            do_cmd("update"; io = devnull)
            @test VibePkg.dependencies()[flow_uuid].version == v"0.2.0"

            do_cmd("pin FlowPkg"; io = devnull)
            @test VibePkg.dependencies()[flow_uuid].is_pinned
            do_cmd("free FlowPkg"; io = devnull)
            @test !VibePkg.dependencies()[flow_uuid].is_pinned
            @test_throws PkgError do_cmd("free FlowPkg"; io = devnull)
            do_cmd("test FlowPkg"; io = devnull)

            do_cmd("develop $flow_repo"; io = devnull)
            developed = VibePkg.dependencies()[flow_uuid]
            @test developed.version == v"0.2.0"
            @test developed.is_tracking_path
            @test Base.samefile(developed.source, flow_repo)

            # Reproduce the REPL-created environment in a fresh depot via the
            # public `instantiate` string command. The developed source remains
            # available at its recorded absolute path; registry materialization
            # for Example must be rebuilt in the new depot.
            project_text = read(joinpath(envdir, "Project.toml"), String)
            manifest_text = read(joinpath(envdir, "Manifest.toml"), String)
            fresh_depot = mkpath(joinpath(root, "fresh-depot"))
            fresh_env = mkpath(joinpath(root, "fresh-environment"))
            write(joinpath(fresh_env, "Project.toml"), project_text)
            write(joinpath(fresh_env, "Manifest.toml"), manifest_text)
            Base.ACTIVE_PROJECT[] = joinpath(fresh_env, "Project.toml")
            append!(empty!(Base.DEPOT_PATH), [fresh_depot; old_depots[2:end]])
            VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = false
            do_cmd("instantiate"; io = devnull)
            fresh_deps = VibePkg.dependencies()
            @test fresh_deps[flow_uuid].version == v"0.2.0"
            @test Base.samefile(fresh_deps[flow_uuid].source, flow_repo)
            @test haskey(fresh_deps, example_uuid)
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
    end
end

# Pkg.jl repl.jl "accidental" (line 28) — a pasted Julia-mode transition
# bracket is stripped inside package mode, and a bare bracket is a no-op.
@testset "accidental bracket input (repl.jl:28)" begin
    REPLMode.TEST_MODE[] = true
    warning = r"^Removing leading `]`, which should only be used once to switch to pkg> mode$"
    try
        @test_logs (:warn, warning) @test only(do_cmd("]?"))[1] === REPLMode.help_command
        @test_logs (:warn, warning) @test only(do_cmd("] ?"))[1] === REPLMode.help_command
        @test_logs (:warn, warning) @test only(do_cmd("]st"))[1] === VibePkg.API.status
        @test_logs (:warn, warning) @test only(do_cmd("] st"))[1] === VibePkg.API.status
        @test_logs (:warn, warning) @test only(do_cmd("]st -m"))[3][:mode] === :manifest
        @test_logs (:warn, warning) @test only(do_cmd("] st -m"))[3][:mode] === :manifest
        @test_logs (:warn, warning) @test isempty(do_cmd("]"))
    finally
        REPLMode.TEST_MODE[] = false
    end
end

@testset "comma-separated develop (Pkg.jl#3997)" begin
    # Pin the public parser contract independently of the effectful test: an
    # unquoted comma is a separator for `dev`, exactly as it is for `add`.
    REPLMode.TEST_MODE[] = true
    try
        api, args, opts = only(do_cmd("dev CommaA,CommaB"))
        @test api === VibePkg.API.develop
        @test args == [[PackageSpec("CommaA"), PackageSpec("CommaB")]]
        @test isempty(opts)
    finally
        REPLMode.TEST_MODE[] = false
    end

    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    old_gate = VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = true
        mktempdir() do root
            root = realpath(root)
            depot = mkpath(joinpath(root, "depot"))
            envdir = mkpath(joinpath(root, "environment"))
            devdir = joinpath(root, "dev")
            comma_a = UUID("c0aa0001-c0aa-4000-8000-c0aa00000001")
            comma_b = UUID("c0bb0002-c0bb-4000-8000-c0bb00000002")

            function make_repo(name, uuid)
                path = mkpath(joinpath(root, "repos", name))
                mkpath(joinpath(path, "src"))
                write(
                    joinpath(path, "Project.toml"),
                    "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
                )
                write(joinpath(path, "src", "$name.jl"), "module $name end\n")
                repo = LibGit2.init(path)
                sig = LibGit2.Signature("fixture", "fixture@localhost")
                try
                    LibGit2.add!(repo, "*")
                    LibGit2.commit(repo, "initial"; author = sig, committer = sig)
                finally
                    close(repo)
                end
                return path
            end

            repositories = Dict(
                "CommaA" => (comma_a, make_repo("CommaA", comma_a)),
                "CommaB" => (comma_b, make_repo("CommaB", comma_b)),
            )
            registry = mkpath(joinpath(depot, "registries", "CommaRegistry"))
            write(
                joinpath(registry, "Registry.toml"),
                """
                name = "CommaRegistry"
                uuid = "c0cc0003-c0cc-4000-8000-c0cc00000003"

                [packages]
                $comma_a = { name = "CommaA", path = "C/CommaA" }
                $comma_b = { name = "CommaB", path = "C/CommaB" }
                """,
            )
            for (name, (uuid, repo)) in repositories
                package = mkpath(joinpath(registry, "C", name))
                open(joinpath(package, "Package.toml"), "w") do io
                    TOML.print(
                        io,
                        Dict("name" => name, "uuid" => string(uuid), "repo" => repo),
                    )
                end
            end

            append!(empty!(Base.DEPOT_PATH), [depot; old_depots[2:end]])
            Base.ACTIVE_PROJECT[] = joinpath(envdir, "Project.toml")
            withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_DEVDIR" => devdir) do
                do_cmd("dev CommaA,CommaB"; io = devnull)
            end

            deps = VibePkg.dependencies()
            @test all(uuid -> haskey(deps, uuid), (comma_a, comma_b))
            @test all(uuid -> deps[uuid].is_tracking_path, (comma_a, comma_b))
            @test Base.samefile(deps[comma_a].source, joinpath(devdir, "CommaA"))
            @test Base.samefile(deps[comma_b].source, joinpath(devdir, "CommaB"))
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[] = old_gate
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl repl.jl "status" (line 762) — the positional-filter argument matrix.
# COVERED: name, `name=uuid`, bare uuid, multiple names, and comma-separated
#   names all parse into the right PackageSpec filter list (status uses the
#   :requests package micro-syntax + comma-sugar).
# ⚪ DIVERGENCE (runtime, not parse): Pkg's `status --diff` warns "diff option
#   only available…" without a git repo then works once committed. VibePkg has
#   no such warn — `--diff` simply parses to `opts[:diff] => true` and the API
#   handles it. Asserting the parse result.
# ---------------------------------------------------------------------------
@testset "status arg matrix (repl.jl:762)" begin
    REPLMode.TEST_MODE[] = true
    try
        capture(s) = only(do_cmd(s))
        exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

        api, args, _ = capture("status Example")
        @test api === VibePkg.API.status && args[1] == [PackageSpec("Example")]

        # name=uuid positional filter
        api, args, _ = capture("status Example=7876af07-990d-54b4-ab0e-23690620f79a")
        @test args[1] == [PackageSpec(; name = "Example", uuid = exuuid)]

        # bare uuid positional filter
        api, args, _ = capture("status 7876af07-990d-54b4-ab0e-23690620f79a")
        @test args[1] == [PackageSpec(; uuid = exuuid)]

        # multiple names
        api, args, _ = capture("status Example Random")
        @test args[1] == [PackageSpec("Example"), PackageSpec("Random")]

        # comma-separated names parse (status is in the comma-sugar set)
        api, args, _ = capture("status Example, Random")
        @test args[1] == [PackageSpec("Example"), PackageSpec("Random")]

        # ⚪ --diff / -d parse to opts[:diff] with no warn (divergence is runtime)
        @test only(do_cmd("status --diff"))[3][:diff] === true
        @test only(do_cmd("status -d"))[3][:diff] === true
    finally
        REPLMode.TEST_MODE[] = false
    end
end

# ---------------------------------------------------------------------------
# Pkg.jl repl.jl "tab completion" (line 350): installed-dependency
# filtering, #4098 deduplication, help mode, directory-only local-path
# traversal, Julia-compat upper bounds, and the core return types.
@testset "tab completion gaps (repl.jl:350)" begin
    mktempdir() do dir
        proj = joinpath(dir, "Project.toml")
        write(
            proj, """
            name = "Sandbox"
            uuid = "12345678-1234-1234-1234-123456789abc"

            [deps]
            Example = "7876af07-990d-54b4-ab0e-23690620f79a"
            PackageWithDependency = "88888888-8888-8888-8888-888888888888"
            """
        )
        old = Base.ACTIVE_PROJECT[]
        try
            Base.ACTIVE_PROJECT[] = proj

            # installed-dependency filtering: rm/free/why offer only project deps
            @test REPLMode.completions_for("rm Exam")[1] == ["Example"]
            @test REPLMode.completions_for("rm Pack")[1] == ["PackageWithDependency"]
            @test REPLMode.completions_for("free Exam")[1] == ["Example"]
            @test REPLMode.completions_for("why Exam")[1] == ["Example"]
            # a non-dependency name yields nothing
            @test isempty(REPLMode.completions_for("rm Bogus")[1])
            # trailing space offers every dependency
            @test REPLMode.completions_for("rm ")[1] == ["Example", "PackageWithDependency"]

            # Pkg.jl#4098: already-specified names are not suggested again,
            # including package micro-syntax and multi-package input.
            @test !("Example" in REPLMode.completions_for("rm Example E")[1])
            @test !("Example" in REPLMode.completions_for("rm Example@0.5 Exam")[1])
            cands, _ = REPLMode.completions_for(
                "rm Example PackageWithDependency E",
            )
            @test !("Example" in cands)
            @test !("PackageWithDependency" in cands)
            @test !("Example" in REPLMode.completions_for("add Example E")[1])
        finally
            Base.ACTIVE_PROJECT[] = old
        end
    end

    apply_completion(input) = begin
        candidates, word = REPLMode.completions_for(input)
        input[1:(end - length(word))] * only(candidates)
    end
    @test apply_completion("?ad") == "?add"
    @test apply_completion("?act") == "?activate"
    @test apply_completion("? ad") == "? add"
    @test apply_completion("? act") == "? activate"

    # Local add/develop candidates recurse through directories and never
    # offer ordinary files.
    mktempdir() do dir
        cd(dir) do
            mkpath(joinpath("testdir", "foo", "bar"))
            touch("README.md")
            separator = Sys.iswindows() ? '\\' : '/'
            @test "testdir$separator" in REPLMode.completions_for("add tes")[1]
            @test "testdir$(separator)foo$(separator)" in
                REPLMode.completions_for("add testdir$(separator)f")[1]
            @test "testdir$(separator)foo$(separator)" in
                REPLMode.completions_for("dev testdir$(separator)f")[1]
            @test !("README.md" in REPLMode.completions_for("add RE")[1])
        end
    end

    # Registry names whose every version excludes this Julia must not be
    # suggested, while a sibling with compatible Julia bounds remains.
    old_depots = copy(Base.DEPOT_PATH)
    try
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            registry = mkpath(joinpath(depot, "registries", "CompatCompletion"))
            entries = (
                (
                    "Chunks", "ccaa0001-ccaa-4000-8000-ccaa00000001",
                    "0.6",
                ),
                (
                    "CurrentChunk", "ccbb0002-ccbb-4000-8000-ccbb00000002",
                    "1",
                ),
            )
            package_lines = String[]
            for (name, uuid, julia_compat) in entries
                path = "C/$name"
                package = mkpath(joinpath(registry, path))
                push!(package_lines, "$uuid = { name = \"$name\", path = \"$path\" }")
                write(
                    joinpath(package, "Package.toml"),
                    "name = \"$name\"\nuuid = \"$uuid\"\nrepo = \"https://example.invalid/$name.jl\"\n",
                )
                write(
                    joinpath(package, "Versions.toml"),
                    "[\"0.1.0\"]\ngit-tree-sha1 = \"1111111111111111111111111111111111111111\"\n",
                )
                write(
                    joinpath(package, "Compat.toml"),
                    "[\"0\"]\njulia = \"$julia_compat\"\n",
                )
            end
            write(
                joinpath(registry, "Registry.toml"),
                "name = \"CompatCompletion\"\nuuid = \"cccc0003-cccc-4000-8000-cccc00000003\"\n\n[packages]\n" *
                    join(package_lines, '\n') * "\n",
            )
            append!(empty!(Base.DEPOT_PATH), [depot])
            REPLMode.reset_completion_cache!()
            @test !("Chunks" in REPLMode.completions_for("add Chu")[1])
            @test "CurrentChunk" in REPLMode.completions_for("add Cur")[1]
        end
    finally
        append!(empty!(Base.DEPOT_PATH), old_depots)
        REPLMode.reset_completion_cache!()
    end
end

@testset "tab completion while offline (repl.jl:331)" begin
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            append!(empty!(Base.DEPOT_PATH), [depot])
            REPLMode.reset_completion_cache!()

            # Offline mode must not invent remote completions when no registry
            # is installed.
            @test isempty(REPLMode.completions_for("add Exam")[1])

            # Once a registry is present, the same offline completion is
            # entirely local and should discover its package names.
            registry = mkpath(joinpath(depot, "registries", "OfflineReg"))
            package = mkpath(joinpath(registry, "E", "Example"))
            write(
                joinpath(registry, "Registry.toml"), """
                name = "OfflineReg"
                uuid = "55558594-aafe-5451-b93e-139f81909106"

                [packages]
                7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
                """
            )
            write(
                joinpath(package, "Package.toml"), """
                name = "Example"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                repo = "https://example.invalid/Example.jl.git"
                """
            )
            write(
                joinpath(package, "Versions.toml"), """
                ["0.5.3"]
                git-tree-sha1 = "1111111111111111111111111111111111111111"
                """
            )
            REPLMode.reset_completion_cache!()
            @test REPLMode.completions_for("add Exam")[1] == ["Example"]
            @test VibePkg.API.OFFLINE_MODE[]
        end
    finally
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
        REPLMode.reset_completion_cache!()
    end
end

@testset "generate/develop validation errors (repl.jl:40)" begin
    old_active = Base.ACTIVE_PROJECT[]
    old_depots = copy(Base.DEPOT_PATH)
    old_offline = VibePkg.API.OFFLINE_MODE[]
    try
        VibePkg.API.OFFLINE_MODE[] = true
        mktempdir() do dir
            depot = mkpath(joinpath(dir, "depot"))
            environment = mkpath(joinpath(dir, "environment"))
            append!(empty!(Base.DEPOT_PATH), [depot])
            Base.ACTIVE_PROJECT[] = joinpath(environment, "Project.toml")
            cd(dir) do
                @test_throws PkgError do_cmd("develop Example#blergh"; io = devnull)
                @test_throws PkgError do_cmd("add ÖÖÖ"; io = devnull)
                @test_throws PkgError do_cmd("generate 2019Julia"; io = devnull)

                do_cmd("generate Foo"; io = devnull)
                do_cmd("develop ./Foo"; io = devnull)

                source = joinpath("Foo", "src", "Foo.jl")
                moved_source = joinpath("Foo", "src", "Foo2.jl")
                mv(source, moved_source)
                @test_throws PkgError do_cmd("develop ./Foo"; io = devnull)

                mv(moved_source, source)
                project = joinpath("Foo", "Project.toml")
                write(project, "name = \"Foo\"\n")
                @test_throws PkgError do_cmd("develop ./Foo"; io = devnull)
                write(project, "uuid = \"b7b78b08-812d-11e8-33cd-11188e330cbe\"\n")
                @test_throws PkgError do_cmd("develop ./Foo"; io = devnull)
            end
        end
    finally
        Base.ACTIVE_PROJECT[] = old_active
        append!(empty!(Base.DEPOT_PATH), old_depots)
        VibePkg.API.OFFLINE_MODE[] = old_offline
    end
end
