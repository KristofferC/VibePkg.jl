# Precompile workload (PrecompileTools): drive the entry points through a
# hermetic synthetic registry so inference precompiles the whole pipeline
# transitively — parsing, registry queries, the resolver, planning,
# execution, rendering, and the REPL grammar. No network, no subprocesses,
# nothing outside a temp directory.
#
# The session runs the real API layer in the exact shapes users type
# (`add("Example")`, `do_cmd("st")`): output is silenced through
# `Utils.DEFAULT_IO` (the same `IOContext{IO}` wrapper real sessions get from
# `stdout_f`/`stderr_f`), package trees are pre-materialized at their slug
# paths so `apply!` finds everything installed, and the package server is
# disabled so no registry bootstrap/update is attempted.
#
# Module-level caches and global session state are scrubbed afterwards so no
# temp paths or session state bake into the image.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    __precompile_dir = mktempdir()
    __saved_active_project = Base.ACTIVE_PROJECT[]
    __saved_depot_path = copy(Base.DEPOT_PATH)
    __saved_auto_precompile = API.AUTO_PRECOMPILE_ENABLED[]
    try # the state scrub below must run even when the workload fails
        let dir = __precompile_dir
            example_uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
            depends_uuid = "f7a26766-1b5e-4bc8-b4b1-fc4f5f2f6c1a"

            # registry: Example with several interchangeable versions (exercises
            # the resolver's eq-class machinery) and Depends depending on it
            reg = joinpath(dir, "depot", "registries", "PrecompileRegistry")
            mkpath(joinpath(reg, "E", "Example"))
            mkpath(joinpath(reg, "D", "Depends"))
            write(
                joinpath(reg, "Registry.toml"), """
                name = "PrecompileRegistry"
                uuid = "23338594-aafe-5451-b93e-139f81909106"
                [packages]
                $example_uuid = { name = "Example", path = "E/Example" }
                $depends_uuid = { name = "Depends", path = "D/Depends" }
                a1a1a1a1-0000-4000-8000-000000000001 = { name = "TriA", path = "T/TriA" }
                b1b1b1b1-0000-4000-8000-000000000002 = { name = "TriB", path = "T/TriB" }
                c1c1c1c1-0000-4000-8000-000000000003 = { name = "TriC", path = "T/TriC" }
                """
            )
            write(
                joinpath(reg, "E", "Example", "Package.toml"), """
                name = "Example"
                uuid = "$example_uuid"
                repo = "https://example.com/Example.jl.git"
                """
            )
            write(
                joinpath(reg, "E", "Example", "Versions.toml"), """
                ["0.5.0"]
                git-tree-sha1 = "$("1"^40)"
                ["0.5.1"]
                git-tree-sha1 = "$("2"^40)"
                ["0.5.2"]
                git-tree-sha1 = "$("3"^40)"
                ["1.0.0"]
                git-tree-sha1 = "$("4"^40)"
                """
            )
            write(
                joinpath(reg, "E", "Example", "Compat.toml"), """
                ["0.5-1"]
                julia = "1.6.0-2"
                """
            )
            write(
                joinpath(reg, "D", "Depends", "Package.toml"), """
                name = "Depends"
                uuid = "$depends_uuid"
                repo = "https://example.com/Depends.jl.git"
                """
            )
            write(
                joinpath(reg, "D", "Depends", "Versions.toml"), """
                ["1.0.0"]
                git-tree-sha1 = "$("5"^40)"
                ["1.1.0"]
                git-tree-sha1 = "$("6"^40)"
                """
            )
            write(
                joinpath(reg, "D", "Depends", "Deps.toml"), """
                ["1"]
                Example = "$example_uuid"
                """
            )
            write(
                joinpath(reg, "D", "Depends", "Compat.toml"), """
                ["1"]
                Example = "0.5-1"
                julia = "1.6.0-2"
                """
            )

            # TriA→TriB→TriC→TriA at their highest versions: individually
            # consistent, jointly unsatisfiable — greedy fails, MaxSum runs
            tri = [
                ("TriA", "a1a1a1a1-0000-4000-8000-000000000001", "7", "TriB", "b1b1b1b1-0000-4000-8000-000000000002"),
                ("TriB", "b1b1b1b1-0000-4000-8000-000000000002", "8", "TriC", "c1c1c1c1-0000-4000-8000-000000000003"),
                ("TriC", "c1c1c1c1-0000-4000-8000-000000000003", "9", "TriA", "a1a1a1a1-0000-4000-8000-000000000001"),
            ]
            for (name, uuid, hex, dep, dep_uuid) in tri
                pkgdir = joinpath(reg, "T", name)
                mkpath(pkgdir)
                write(
                    joinpath(pkgdir, "Package.toml"), """
                    name = "$name"
                    uuid = "$uuid"
                    repo = "https://example.com/$name.jl.git"
                    """
                )
                write(
                    joinpath(pkgdir, "Versions.toml"), """
                    ["1.0.0"]
                    git-tree-sha1 = "$(hex^40)"
                    ["2.0.0"]
                    git-tree-sha1 = "$(hex^20)$("0"^20)"
                    """
                )
                write(
                    joinpath(pkgdir, "Deps.toml"), """
                    ["2"]
                    $dep = "$dep_uuid"
                    """
                )
                write(
                    joinpath(pkgdir, "Compat.toml"), """
                    ["1-2"]
                    julia = "1.6.0-2"
                    ["2"]
                    $dep = "1"
                    """
                )
            end

            # pre-materialized install trees (slug paths) so apply! never fetches
            tri_trees = vcat(
                [(name, uuid, "1.0.0", hex^40, "") for (name, uuid, hex, _, _) in tri],
                [
                    (
                            name, uuid, "2.0.0", hex^20 * "0"^20, """
                            [deps]
                            $dep = "$dep_uuid"
                            """,
                        ) for (name, uuid, hex, dep, dep_uuid) in tri
                ],
            )
            for (name, uuid, version, sha, extra) in [
                    ("Example", example_uuid, "0.5.0", "1"^40, ""),
                    ("Example", example_uuid, "0.5.1", "2"^40, ""),
                    ("Example", example_uuid, "0.5.2", "3"^40, ""),
                    ("Example", example_uuid, "1.0.0", "4"^40, ""),
                    (
                        "Depends", depends_uuid, "1.0.0", "5"^40, """
                        [deps]
                        Example = "$example_uuid"
                        [extensions]
                        DependsExt = ["Example"]
                        """,
                    ),
                    (
                        "Depends", depends_uuid, "1.1.0", "6"^40, """
                        [deps]
                        Example = "$example_uuid"
                        [extensions]
                        DependsExt = ["Example"]
                        """,
                    ),
                    tri_trees...,
                ]
                slug = Base.version_slug(Base.UUID(uuid), Base.SHA1(sha))
                tree = joinpath(dir, "depot", "packages", name, slug)
                mkpath(joinpath(tree, "src"))
                write(
                    joinpath(tree, "Project.toml"), """
                    name = "$name"
                    uuid = "$uuid"
                    version = "$version"
                    $extra
                    """
                )
                write(joinpath(tree, "src", "$name.jl"), "module $name end\n")
            end
            # a pre-existing usage log: log_usage's parse-and-merge branch only
            # runs against entries read back from disk
            mkpath(joinpath(dir, "depot", "logs"))
            write(
                joinpath(dir, "depot", "logs", "manifest_usage.toml"), """
                "/nonexistent/prior/Manifest.toml" = [{ time = 2026-01-01T00:00:00 }]
                """
            )
            mkpath(joinpath(dir, "env"))
        end

        API.AUTO_PRECOMPILE_ENABLED[] = false

        @compile_workload begin
            let dir = __precompile_dir
                envdir = joinpath(dir, "env")
                copy!(Base.DEPOT_PATH, [joinpath(dir, "depot")])
                # auto-gc would sweep fixture packages that no manifest references yet
                withenv("JULIA_PKG_SERVER" => "", "JULIA_PKG_OFFLINE" => "false", "JULIA_PKG_GC_AUTO" => "false") do
                    Base.ScopedValues.with(Utils.DEFAULT_IO => Utils.unstableio(devnull)) do
                        # a real session, in the exact call shapes users type
                        API.activate(envdir)
                        API.add("Example")                 # resolves to 1.0.0
                        API.status()
                        API.status(outdated = true)
                        API.status(mode = :manifest)
                        API.compat("Example", "0.5")       # non-compliant: entry kept, error rendered
                        API.compat("Example", "0.5, 1")    # compliant
                        API.pin("Example")
                        API.free("Example")
                        API.add("Depends")                 # multi-package graph
                        API.status(extensions = true)
                        API.why("Example")
                        API.add(["TriA", "TriB", "TriC"])  # greedy-infeasible: runs MaxSum
                        API.rm(["TriA", "TriB", "TriC"])
                        API.instantiate()
                        API.resolve()
                        API.rm("Depends")
                        API.up()
                        REPLMode.do_cmd("add Example@0.5.1; st; up --minor; up; rm Example")
                        # the io-kwarg shape the REPL extension's on_done uses, and
                        # commands that must *execute* (not just parse) through the
                        # REPL path: help rendering, splat args, status modes
                        REPLMode.do_cmd("st"; io = Utils.stderr_f())
                        REPLMode.do_cmd("activate \"$envdir\"; st -m; ?; ?add"; io = Utils.stderr_f())
                        API.status()

                        # the session must end where we think it does — a swallowed
                        # REPL-printed error would silently shrink coverage
                        depots = Depots.depot_stack()
                        env = Environments.load_environment(envdir; depots)
                        isempty(env.project.deps) || error("Internal precompile workload error: session did not complete")

                        # acquisition-adjacent bits not reached without a server
                        Fetch.pkg_server_headers("https://pkg.julialang.org"; depots)
                        Fetch.package_archive_urls(
                            Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a"),
                            Base.SHA1("1"^40),
                            ["https://example.com/Example.jl.git"]; server = "https://server",
                        )
                        if !Sys.iswindows()   # file:// spelling differs on Windows
                            dlsrc = "file://" * joinpath(envdir, "Project.toml")
                            Fetch.download(dlsrc, joinpath(dir, "downloaded"))
                            Fetch.download(dlsrc, joinpath(dir, "downloaded"); depots)
                        end
                    end
                end

                # entry-point shims the session calls inlined away: give them
                # dispatchable compiled instances so nothing compiles on first use
                Base.precompile(API.activate, (String,))
                Base.precompile(API.add, (String,))
                Base.precompile(API.add, (Vector{String},))
                Base.precompile(API.develop, (String,))
                Base.precompile(API.rm, (String,))
                Base.precompile(API.rm, (Vector{String},))
                Base.precompile(API.up, (String,))
                Base.precompile(API.up, ())
                Base.precompile(API.pin, (String,))
                Base.precompile(API.free, (String,))
                Base.precompile(API.why, (String,))
                Base.precompile(API.compat, (String, String))
                Base.precompile(API.status, ())
                Base.precompile(API.resolve, ())
                Base.precompile(API.instantiate, ())

                # grammar + version machinery
                REPLMode.TEST_MODE[] = true
                try
                    REPLMode.do_cmd("add Example@0.5 Other=22222222-2222-2222-2222-222222222222; st -m; up --minor")
                    REPLMode.do_cmd("pin Example; free Example; registry status; ?add")
                finally
                    REPLMode.TEST_MODE[] = false
                end
                REPLMode.completions_for("ad")
                REPLMode.completions_for("rm --")
                REPLMode.completions_for("rm Ex")    # environment dependency names
                REPLMode.completions_for("add Ex")   # registry + stdlib names
                Versions.semver_spec("1.2, 0.3 - 0.5")
                Versions.VersionSpec("1.2-3") ∩ Versions.VersionSpec("1")
                v"1.2.3" in Versions.semver_spec("~1.2")
                TreeHash.tree_hash(envdir)
            end
        end

    finally
        # scrub caches and session state so no temp paths bake into the image
        # (and no altered globals leak out of a failed workload)
        Base.ACTIVE_PROJECT[] = __saved_active_project
        copy!(Base.DEPOT_PATH, __saved_depot_path)
        API.AUTO_PRECOMPILE_ENABLED[] = __saved_auto_precompile
        API.UPDATED_REGISTRY_THIS_SESSION[] = false
        empty!(Registries.REGISTRY_CACHE)
        REPLMode.reset_completion_cache!()
        Stdlibs.STDLIB[] = nothing
        empty!(Stdlibs.UPGRADABLE_STDLIBS_UUIDS)
        empty!(API.UNDO_STACKS)
        API.PREV_ENV_PATH[] = ""
        Base.rm(__precompile_dir; force = true, recursive = true)
    end
end
