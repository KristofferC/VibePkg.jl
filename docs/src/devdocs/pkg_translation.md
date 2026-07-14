# Coming from Pkg.jl

VibePkg is a from-scratch reimplementation of Pkg.jl with compatible
user-visible behavior but differently organized internals. This page is a
source map for developers who know Pkg.jl's code: where each Pkg module, type,
and function lives in VibePkg. Read it next to
[Architecture](architecture.md), which describes VibePkg on its own terms.

"Pkg" below means Pkg.jl's `src/`; unprefixed paths are VibePkg's.

## The five shifts to internalize

Most of the mapping falls out of five structural decisions:

1. **`EnvCache` became a value.** `Environments.Environment` is an immutable
   snapshot. There is no `original_project`/`original_manifest` bookkeeping:
   operations load an `Environment`, compute a *new* one, and
   `Environments.write_environment(old, new)` diffs the two at write time.
   Undo entries are references to old snapshots.

2. **`Context` became `Config` plus explicit arguments.** All process-state
   reads happen once per operation in `Configs.Config`, built by
   `API.op_context()` (which also loads/updates registries; the pair is
   `API.OpContext(config, registries)`). The environment is not inside the
   context — it is a separate `load_environment` value. `ctx.julia_version`
   survives only as a planner kwarg; there are no `f(ctx::Context, ...)`
   methods.

3. **`Operations.jl` split into pure planning and effectful execution.** Each
   `Operations.add`-style body becomes: `Planning.plan_*` computes a target
   `Environment` with no network/disk access (materializing a git-tracked
   package is injected as a `fetcher` closure, `Git.source_fetcher`), then
   `API.run_plan` runs `Execution.apply!`, prints the diff, records undo,
   builds, and auto-precompiles. There is no plan struct: the planned
   `Environment` *is* the plan. Side operations get their own modules:
   `BuildOps`, `TestOps`, `GCOps`, `AppsOps`, `ArtifactOps`.

4. **`PackageSpec` no longer flows through the pipeline.** VibePkg's
   `API.PackageSpec` is an immutable input record that never leaves the API
   layer: it is normalized into `Planning.PackageRequest` (registry request)
   or an already-materialized `EnvFiles.RepoPackage` (add-by-URL). Inside a
   plan the mutable working record is `Planning.Node`, private to the module
   and discarded after `build_manifest`.

5. **Manifest entries are typed by how they are tracked.** `PackageEntry`'s
   nullable `path`/`repo`/`version`/`tree_hash` fields become
   `EnvFiles.ManifestEntry` with
   `tracking::Union{PathTracked, RepoTracked, RegistryTracked}`, plus
   predicates (`is_path_tracked`, ...) and accessors (`entry_version`,
   `entry_tree_hash`, `entry_path`, `entry_repo_url`, ...).

A sixth, more diffuse one: `Types.jl` is dissolved into small modules included
in strict layer order (see `src/VibePkg.jl`), importing each other explicitly.

## File map

| Pkg | VibePkg | Notes |
|:--|:--|:--|
| `src/Pkg.jl` | `src/VibePkg.jl` | same export/`const`-alias surface; adds the `vpkg` `@main` CLI; globals moved into `API`/`Configs` |
| `src/Types.jl` | dissolved | `PkgError` → `Errors`; Project/Manifest types → `EnvFiles`; `EnvCache`/workspace/write → `Environments`; enums → `Configs`; stdlibs → `Stdlibs`; `PackageSpec` → `API`; name→UUID resolution → `Planning`; repo handling → `Git` |
| `src/project.jl`, `src/manifest.jl` | `src/EnvFiles.jl` | readers keep Pkg's names; `destructure` → `destructure_project`/`destructure_manifest` |
| `src/Operations.jl` | `src/Planning.jl` + `src/Execution.jl` | op semantics/resolution → Planning; download/install/instantiate → Execution; status/diff rendering → `Display`; build/test → `BuildOps`/`TestOps` |
| `src/API.jl` | `src/API.jl` | same role, plus session state and `run_plan`; the `gc` body → `GCOps` |
| `src/Versions.jl` | `src/Versions.jl` | same grammars and algorithms |
| `src/utils.jl` | `src/Utils.jl` | except `atomic_toml_write` → `Depots`, `safe_realpath` → `Environments`, `discover_repo` → `Git` |
| — | `src/Depots.jl` | new home for the depot schema: `DepotStack`, layout accessors, `find_installed`, `log_usage` (in Pkg scattered over `Pkg.jl`/`Types.jl`/`Operations.jl`) |
| — | `src/Configs.jl` | `Config` plus the operation enums (`PreserveLevel`, `UpgradeLevel`, `PackageMode`) |
| `src/HistoricalStdlibs.jl` | folded into `src/Stdlibs.jl` | same `STDLIBS_BY_VERSION`/`UNREGISTERED_STDLIBS` protocol, still populated externally |
| `src/GitTools.jl` | `src/Git.jl` + `src/TreeHash.jl` | tree hashing is its own bottom-layer module |
| `src/PlatformEngines.jl` | `src/Fetch.jl` | download/unpack/auth/package-server client |
| `src/Registry/` | `src/Registries.jl` | instance + lazy loading + queries + add/rm/update in one module; Pkg-namespace API in `src/compat/Registry.jl` |
| `src/Resolve/` | `src/Resolve/` | vendored — see below |
| `src/Artifacts.jl` | `src/ArtifactOps.jl` + `src/compat/Artifacts.jl` | mutating/network half vs. Pkg-namespace API |
| `src/Apps/Apps.jl` | `src/AppsOps.jl` + `src/compat/Apps.jl` | |
| `src/REPLMode/` (3 files) | `src/REPLMode.jl` | declarations, parsing, help, and completions in one module |
| `ext/REPLExt/` (4 files) | `ext/REPLExt.jl` + `ext/precompile_workload.jl` | completions moved into `REPLMode`; no interactive `compat` editor |
| `src/generate.jl` | inline in `src/API.jl` | |
| `src/precompile.jl` | `src/precompile_workload.jl` | PrecompileTools-based, hermetic synthetic registry |
| `src/fuzzysorting.jl` | `src/FuzzySorting.jl` | byte-identical file |
| `src/MiniProgressBars.jl` | `src/MiniProgressBars.jl` | forked: adds `ProgressLogger`, drops `print_progress_bottom` |
| `src/BinaryPlatformsCompat.jl` | — | no legacy platform shim; use `Base.BinaryPlatforms` |
| — | `src/Timing.jl` | optional TimerOutputs instrumentation ([Timing](timing.md)) |
| — | `src/Queries.jl` | read-only façade for frontends/completions (Pkg's completion code reads `EnvCache`/registries directly) |
| — | `src/Display.jl` | status/diff/compat rendering extracted from `Operations.jl` |

## Type dictionary

| Pkg | VibePkg |
|:--|:--|
| `Types.EnvCache` | `Environments.Environment` (immutable; no `original_*`; no `pkg::PackageSpec` — use `project.name`/`uuid`) |
| `Types.Context` | `Configs.Config` + `API.OpContext` |
| `Types.PackageSpec` | `API.PackageSpec` → `Planning.PackageRequest` / `EnvFiles.RepoPackage` / `Planning.Node` |
| `Types.Project` | `EnvFiles.Project` (`other` → frozen `raw`, excluded from `==`; `sources` typed as `SourceSpec`) |
| `Types.Manifest` | `EnvFiles.Manifest` (`project_hash` typed field is authoritative; Pkg keeps the live value in `manifest.other["project_hash"]`) |
| `Types.PackageEntry` | `EnvFiles.ManifestEntry` + tracking union |
| `Types.GitRepo` | split into `EnvFiles.SourceSpec` (project `[sources]`), `RepoTracked` fields, `RepoPackage` |
| `Types.ManifestRegistryEntry` | `EnvFiles.RegistryRef` |
| `Types.Compat` | `EnvFiles.Compat` |
| `Types.StdlibInfo` | `Stdlibs.StdlibInfo` |
| `Registry.RegistryInstance`/`PkgEntry`/`PkgInfo`/`VersionInfo` | same names in `Registries`; the lazy payload is a separate `LoadedRegistry` behind accessors (`registry_name(reg)` instead of `reg.name`) |
| `Registry.RegistrySpec` | — (management functions take strings; `compat/Registry.jl` has `parse_registry_spec`) |
| `API.UndoSnapshot` | entries of `API.UNDO_STACKS` — plain `Environment` references; capped at 50 on both sides |
| `REPLMode.CommandSpec`/`OptionSpec`/`ArgSpec` | `REPLMode.CommandSpec` (immutable; `arg_kind`/`arg_count`/`opts` fields) |
| `REPLMode.QString` | `REPLMode.Word` |
| `REPLMode.Command` | `REPLMode.ParsedCommand` |

## Function map

Context, environments, env files:

| Pkg | VibePkg |
|:--|:--|
| `Types.Context()` | `API.op_context(; update_registry = :none/:auto/:force)` |
| `Types.EnvCache(env)` | `Environments.load_environment(env)` |
| `Types.read_project` / `read_manifest` | same names in `EnvFiles` (pure cores: `parse_project`/`parse_manifest`) |
| `write_project` / `write_manifest` / `destructure` | `EnvFiles.write_project` / `write_manifest` / `destructure_project`+`destructure_manifest` |
| `Types.write_env` | `Environments.write_environment(old, new)` — undo is not its job |
| `Types.write_env_usage` | `Depots.log_usage` |
| `Types.find_project_file` | `Environments.find_project_file` |
| `Types.collect_workspace` | `Environments.workspace_members` |
| `Types.workspace_resolve_hash` | `Environments.resolve_hash` |
| `Operations.is_manifest_current` | `Environments.is_manifest_current` (internal; takes an `Environment`) |
| `Pkg.depots()`/`depots1()` | `Depots.depots(stack)`/`depots1(stack)` — snapshot, not live `Base.DEPOT_PATH` |
| `Pkg.logdir`/`envdir` + inline `joinpath(depot, "packages")` etc. | `Depots.logdir`, `environments_dir`, `packages_dir`, `clones_dir`, `registries_dir`, `artifacts_dir`, `scratchspaces_dir`, `bin_dir` |
| `Operations.find_installed` | `Depots.find_installed` — returns `(path, installed::Bool)` |
| `Pkg.pkg_server()` / `Pkg.devdir()` | `Configs.pkg_server()` / `Config.devdir` |
| `Types.stdlibs`/`stdlib_infos`/`is_stdlib`/`stdlib_version`/`get_last_stdlibs` | same names in `Stdlibs` |
| `API.add_snapshot_to_undo` | `API.record_undo!` (called from `run_plan`) |

Input normalization and repo handling:

| Pkg | VibePkg |
|:--|:--|
| `API.handle_package_input!` | `API.validate_specs` + `API.split_specs` + `API.to_request` |
| `Types.project_deps_resolve!` → `manifest_resolve!` → `registry_resolve!` → `stdlib_resolve!` → `ensure_resolved` | `Planning.resolve_request` — one pure function, same lookup order |
| `Types.handle_repo_add!` / `handle_repos_add!` | `Git.materialize_repo_package!` — runs *before* planning, returns a `RepoPackage`; wrapped as the `fetcher` closure (`Git.source_fetcher`) for plan-time materialization |
| `Types.handle_repo_develop!` / `handle_repos_develop!` | dev-path logic in `API` (`dev_clone_target`) + `Planning.plan_develop` |
| `Types.get_object_or_branch` | `Git.lookup_rev` |
| `Types.resolve_projectfile!` | inlined in `Git.materialize_repo_package!` |
| `Types.add_repo_cache_path` | `Git.repo_cache_path` — different key (`Base.hash(url)` vs `sha1(url)[1:16]`), so URL clone caches are not shared |
| `project.jl` `get_path_repo` | `Planning.project_source` / `Environments.source_location` |

Resolution and planning:

| Pkg | VibePkg |
|:--|:--|
| `Operations.add`/`rm`/`up`/`pin`/`free`/`develop` | `Planning.plan_add`/`plan_rm`/`plan_up`/`plan_pin`/`plan_free`/`plan_develop` + `API.run_plan` |
| `Operations.can_skip_resolve_for_add` (inline fast path) | `Planning.plan_promote` |
| `Operations.resolve_versions!` | `Planning.resolve_versions` — returns nodes instead of mutating specs and `env.manifest` |
| `deps_graph`, `collect_fixed!`, `collect_project`, `tiered_resolve`, `targeted_resolve`, `load_direct_deps`, `load_all_deps`, `load_manifest_deps`, `load_tree_hash!`, `prune_manifest`, `get_compat_str`, `dropbuild`, `source_path`, `is_package_downloaded` | same (or bang-less) names in `Planning` — near-line-for-line ports |
| `Operations.update_manifest!` + `record_project_hash` | `Planning.build_manifest` (stamps `Environments.resolve_hash`) |
| `Operations.up_load_versions!` | `Planning.level_spec` + `API.refresh_repo_packages` |
| `Operations.set_compat` | `Planning.plan_compat_entry` / `plan_compat` |
| `API.resolve` (= `up(level = UPLEVEL_FIXED, mode = PKGMODE_MANIFEST)`) | a dedicated planner, `Planning.plan_resolve` |
| `Operations.default_preserve` | `Configs.default_preserve` |

Execution:

| Pkg | VibePkg |
|:--|:--|
| `Operations.download_source` | `Execution.ensure_sources_installed!` → `Fetch.ensure_package_installed!` |
| `Operations.install_archive` / `install_git` | `Fetch.install_archive` / `Git.install_tree_from_git!` |
| `Operations.find_urls` | `Execution.repo_urls_for` + `Fetch.package_archive_urls` |
| `Operations.get_archive_url_for_version` | `Fetch.github_archive_url` |
| `Operations.download_artifacts` / `collect_artifacts` | `Execution.ensure_artifacts!` / `ArtifactOps.collect_artifact_installs` |
| `Operations.fixups_from_projectfile!` | `Execution.fixups_from_projectfile` — pure, returns a new `Manifest` |
| `Operations.show_update` | `Display.print_env_diff(io, old, new)` |
| `API.instantiate` internals (`Operations.is_instantiated`, ...) | `Execution.instantiate!` — never rewrites the manifest; missing/stale manifests handled in `API.instantiate` by delegating to `up` |
| `Operations.sandbox` / `sandbox_preserve` / `abspath!` | `Execution.sandbox_manifest` + `Execution.sandbox_preferences` — shared slice + preferences; there is no common resolving `sandbox` function |

Acquisition and registries:

| Pkg | VibePkg |
|:--|:--|
| `PlatformEngines.download` / `get_auth_header` / `get_metadata_headers` / `register_auth_error_handler` | `Fetch.download` / `get_auth_token` / `pkg_server_headers` / `register_auth_error_handler` |
| `PlatformEngines.unpack` / `get_extract_cmd` | same names in `Fetch` |
| `PlatformEngines.verify` (sha256) | `ArtifactOps.verify_sha256` |
| `PlatformEngines.download_verify_unpack` and friends | — composed inline at call sites |
| `GitTools.clone`/`fetch`/`ensure_clone`/`checkout_tree_to_path`/`normalize_url`/`setprotocol!` | same names in `Git` |
| `GitTools.tree_hash` | `TreeHash.tree_hash` (+ `tree_hash_matches` for the legacy symlink variant) |
| `Registry.reachable_registries`, `registry_info`, `query_deps_for_version`, `query_compat_for_version_multi_registry!`, `uuids_from_name`, `isyanked`, `treehash`, `REGISTRY_CACHE` | same names in `Registries` — laziness and caching design identical |
| `Registry.uncompress_registry` | `Fetch.uncompress_registry` |
| `Registry.download_default_registries` | `Registries.add_default_registries!` (driven from `op_context`) |
| `Registry.add`/`rm`/`update` | `Registries.add_registry!`/`remove_registry!`/`update_registries!` (+ the `VibePkg.Registry` shim) |
| `Operations.get_pkg_deprecation_info` | `Registries.deprecation_info` |

REPL and rendering:

| Pkg | VibePkg |
|:--|:--|
| `REPLMode/command_declarations.jl` (declaration DSL) | `REPLMode.build_command_table()` — imperative `register!` calls |
| `REPLMode.do_cmds(str)` / `do_cmd(::Command)` | `REPLMode.do_cmd(::AbstractString)` (and `do_cmd(::Vector)` for the CLI) |
| `argument_parsers.jl` micro-syntax (`parse_package`, `looks_like_url`, `extract_revision`/`extract_subdir`/`extract_version`, GitHub URL unwrapping) | same-named helpers in `REPLMode` (`package_word_tokens` + `fold_package_tokens` replace `parse_package`) |
| `ext/REPLExt/completions.jl` | `REPLMode.completions_for`, fed by `Queries` |
| `REPLExt.promptf` / `create_mode` / `repl_init` | `REPLExt.promptf` / `create_mode` / `install_in` (+ public `REPLMode.install_repl!`) |
| `Operations.print_status`, `status_compat_info`, `status_ext_info`, `print_compat`, `compat_line` | same names in `Display` |
| `Operations.print_diff` / `diff_array` | `Display.print_diff_body` / `print_diff_rows` |
| `Operations.git_head_env` | `API.git_head_env` |
| `@pkg_str`, `REPLMode.pkgstr`, `REPLMode.TEST_MODE` | same on both sides |

Side operations:

| Pkg | VibePkg |
|:--|:--|
| `Operations.build_versions` | `BuildOps.build!` |
| `Operations.dependency_order_uuids` | `BuildOps.topo_order` |
| `Operations.test` | `TestOps.test!` |
| `Operations.gen_target_project` | `TestOps.sandbox_project` |
| `Operations.gen_subprocess_flags` / `get_threads_spec` | `TestOps.test_subprocess_flags` / `test_threads_spec` |
| `API.gc` body / `Pkg._auto_gc` | `GCOps.gc` / `API._auto_gc` (throttled by `logs/gc.stamp`) |
| `Apps.add`/`develop`/`rm`/`update`/`status` | `AppsOps.app_add`/`app_develop`/`app_rm`/`app_update`/`app_status` (+ the `VibePkg.Apps` shim) |
| `Apps.generate_shims_for_apps`/`generate_shim`/`shell_shim`/`windows_shim` | `AppsOps.write_shim`/`shim_contents`/`sh_shim`/`bat_shim` |
| `PkgArtifacts.ensure_artifact_installed` | `ArtifactOps.ensure_artifact_installed!` (drop-in wrapper: `VibePkg.Artifacts.ensure_artifact_installed`) |
| `PkgArtifacts.bind_artifact!`/`unbind_artifact!`/`create_artifact`/`remove_artifact`/`verify_artifact` | same names in `VibePkg.Artifacts` (compat shim over `ArtifactOps`/`TreeHash`) |
| `Pkg.generate` (`src/generate.jl`) | `API.generate` |

Session state:

| Pkg | VibePkg |
|:--|:--|
| `Pkg.OFFLINE_MODE`, `UPDATED_REGISTRY_THIS_SESSION`, `IN_REPL_MODE`, `PREV_ENV_PATH` | same names, as `API` Refs/ScopedValues |
| `Pkg.DEFAULT_IO` | `Utils.DEFAULT_IO` (ScopedValue on both sides) |
| `API.undo_entries` / `max_undo_limit` | `API.UNDO_STACKS` / `API.MAX_UNDO` |
| `Pkg._autoprecompilation_enabled` | `API.AUTO_PRECOMPILE_ENABLED` |
| `Pkg._auto_gc_enabled` / `DEPOT_ORPHANAGE_TIMESTAMPS` | `API.AUTO_GC_ENABLED` / the `logs/gc.stamp` file |
| `Types.num_concurrent_downloads()` | `Config.concurrency` |
| `Pkg.RESPECT_SYSIMAGE_VERSIONS` | `Config.respect_sysimage_versions` |

## The resolver

`src/Resolve/` is vendored from Pkg. `fieldvalues.jl` and `versionweights.jl`
are byte-identical; `maxsum.jl` is within a few lines. `Resolve.jl` carries
minimal-diff alias shims (`const Registry = Registries`,
`const Types = Stdlibs`) so the port stays close to upstream, plus `@timeit`
instrumentation; `graphtype.jl` has localized performance rewrites
(equivalence-class grouping, `BitMatrix` slicing, compat-mask reuse).
Everything else — including `ResolverTimeoutError` and
`JULIA_PKG_RESOLVE_MAX_TIME` — is as in Pkg.

## Same name, same place

Beyond the tables above, whole families kept their Pkg names and can be found
by grepping for the identical identifier: the `Versions` API (`semver_spec`,
`VersionSpec`, `VersionRange`, `matches_spec_range!`), the `Registries` query
layer, the `Git` clone/fetch layer, the `Utils` helpers (`printpkgstyle`,
`can_fancyprint`, `stdout_f`/`stderr_f`, `set_readonly`,
`mv_temp_dir_retries`), the `Stdlibs` tables, the install mechanics (version
slugs, `*.pid` pidlocks, temp-dir-plus-rename), the usage-log file names, and
the pinned user-facing strings (VibePkg keeps each at a single call site, so
grep-for-message works even better than in Pkg).

## False friends

Same name, different thing — worth knowing before grepping:

| Name | Pkg | VibePkg |
|:--|:--|:--|
| `PackageSpec` | mutable, flows through the whole operation | immutable input record, never leaves `API` |
| `resolve` | alias for `up(level = UPLEVEL_FIXED, mode = PKGMODE_MANIFEST)` | its own planner (`plan_resolve`) |
| `build` | recursive dep closure, instantiates, resolves a build sandbox | exactly the requested uuids, no instantiate, no sandbox resolve |
| `do_cmd` | takes a parsed `Command`; string entry is `do_cmds` | *is* the string/vector entry point |
| "sandbox" | one shared resolving `Operations.sandbox` for build and test | no such function; only slice + preferences shared |
| `find_installed` | returns a (possibly hypothetical) path | returns `(path, installed::Bool)` |
| `depots()` | live `Base.DEPOT_PATH` | immutable `DepotStack` snapshot |
| `fixups_from_projectfile[!]` | mutating, `ctx`-based | pure, returns a new `Manifest` |
| `write_env` vs `write_environment` | diffs against hidden originals, records undo as a side effect | explicit `(old, new)`, undo separate |
| `project_hash` | live value in `manifest.other` | the typed `Manifest` field |
| `is_manifest_current` | public, takes a path | internal, takes an `Environment` |

## Life of `add Example`, side by side

| Stage | Pkg | VibePkg |
|:--|:--|:--|
| Parse | `REPLMode.do_cmds` → generated `API.add` wrapper (default registries, undo snapshot, `handle_package_input!`) | `REPLMode.do_cmd` → `API.add` (`validate_specs`, `split_specs`) |
| Context | `Types.Context()` + `Operations.update_registries` | `API.op_context(update_registry = :auto)` |
| Environment | `EnvCache()` built inside `Context` | `Environments.load_environment` |
| Name → UUID | the `*_resolve!` passes + `ensure_resolved` | `Planning.resolve_request` (inside the plan) |
| Fast path | `Operations.can_skip_resolve_for_add`, inline in `Operations.add` | `Planning.plan_promote` |
| Resolve | `Operations.tiered_resolve` → `resolve_versions!` (mutates specs and `ctx.env`) | `Planning.plan_add` → `tiered_resolve` → `resolve_versions` (returns nodes) |
| Manifest | `Operations.update_manifest!` mutates `ctx.env.manifest` | `Planning.build_manifest` returns the planned `Environment` |
| Execute | `download_source` → `fixups_from_projectfile!` → `download_artifacts` → `write_env` → `show_update` → `build_versions` → `_auto_precompile` | `API.run_plan`: `Execution.apply!` (sources → artifacts → fixups → diff-aware write) → `Display.print_env_diff` → `record_undo!` → `BuildOps.build!` → `_auto_precompile` |

## No counterpart

Only in Pkg: `Context`-first methods and `Context!`; `julia_version`/
`platform` kwargs on operations; `PKGMODE_COMBINED`; `RegistrySpec` and
symlinked registry installs; `try_prompt_pkg_add` (the REPL auto-install
hook); the interactive TerminalMenus `compat` editor; `precompile`
`monitor`/`stop`/`cancel`; `Apps.precompile`; `BinaryPlatformsCompat`;
`Operations.ensure_manifest_registries!`; legacy `test/REQUIRE`.

Only in VibePkg: `Timing` ([Timing](timing.md)); `Queries`; the `vpkg` CLI
(`@main` in `src/VibePkg.jl`) and the `(env) vpkg>` prompt; the `fetcher`
injection; the `compat/` Pkg-namespace shims; functional updates
(`with_project`/`with_manifest`/`with_entry`); `AppsOps.migrate_shims!`;
`MiniProgressBars.ProgressLogger`.

## Testing the package itself

The two suites are set up on different principles:

| Aspect | Pkg | VibePkg |
|:--|:--|:--|
| Runner | `test/runtests.jl` `include`s a hardcoded file list sequentially in one process, inside sandbox modules that snapshot/restore `DEPOT_PATH`, `LOAD_PATH`, `ENV`, and the active project | the Testosterone runner: test files are auto-discovered, every file is standalone-runnable, and files run in parallel worker processes scheduled by recorded durations |
| Network | real network: `Utils.check_init_reg` downloads the actual General registry once per run (pkg-server tarball, else GitHub clone), and tests `add` real packages (`TEST_PKG` = the registered Example) | fully hermetic: `test/local_pkg_server.jl` serves the pkg-server protocol from *generated* fixtures — a synthetic General (real General/Example UUIDs, Example 0.5.0–0.5.5, tarballs + a tagged local git repo for add-by-URL), tree hashes computed from the generated trees. `ensure!()` also points `http_proxy`/`https_proxy` at a dead port so any stray internet request fails loudly |
| Depot isolation | `Utils.isolate(fn)` per testset: fresh temp depot with the cached General registry symlinked in, optional pre-warmed `LOADED_DEPOT` | one per-run temp depot (`VIBEPKG_TEST_DEPOT`, shared with workers) plus julia's bundled depots — never `~/.julia`; workers boot on a loose stack so VibePkg's deps/REPL load, then each file's prelude calls `LocalPkgServer.isolate!()` to tighten the whole process to the strict stack |
| Helpers | `test/utils.jl` (`Utils`): `temp_pkg_dir`, `with_temp_env`, `copy_test_package` (fixtures under `test/test_packages/`), `git_init_package`, `add_this_pkg` | `test/local_pkg_server.jl` (server + isolation) and `test/testhelpers.jl` (e.g. `make_test_registry`), included behind `@isdefined` guards so files stay standalone |
| Organization | roughly by frontend surface (`new.jl`, `pkg.jl`, `api.jl`, `repl.jl`, ...) | by VibePkg module (`test/planning.jl`, `test/execution.jl`, `test/registries.jl`, ...) plus parity suites (`test/parity_gaps.jl`, `test/pkg_issues.jl`, `test/doc_features.jl`); `test/resolve.jl`, `test/resolve_utils.jl`, and `test/NastyGenerator.jl` are direct ports |
| Static checks | Aqua | Aqua + JET (`test/jet.jl`) + ExplicitImports (`test/explicit_imports.jl`) |

Both suites use HistoricalStdlibVersions as a test dependency for
cross-julia-version stdlib tables; VibePkg bridges its data into
`VibePkg.Stdlibs` (`test/historical_stdlib_version.jl`) since HSV registers
into `Pkg.Types` directly.

Remaining user-visible behavior differences are tracked in
`test/TEST_PARITY_TODO.md` — check there before assuming a divergence is a
bug.
