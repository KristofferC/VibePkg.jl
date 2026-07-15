# VibePkg ↔ Pkg.jl test-parity TODO

A per-file, per-testset audit of the reference **Pkg.jl** test suite
(`../Pkg.jl/test/`) against **VibePkg**'s own tests (`VibePkg/test/`). For
every Pkg.jl testset this records, in plain language, what it actually
exercises and whether VibePkg has an equivalent.

Generated 2026-07-14 by fanning out one analysis agent per Pkg.jl test file;
each agent read the reference test, then grepped/opened the VibePkg tests and
`src/` to judge coverage.

## Legend

- ✅ **COVERED** — VibePkg has a test exercising the same behavior.
- 🟡 **PARTIAL** — a related test exists but misses aspects (noted inline).
- ❌ **MISSING** — no VibePkg test covers this → a TODO.
- ⚪ **N/A** — Pkg-internal, reuses Julia Base, or a deprecated mechanism VibePkg
  does not implement (e.g. `test/REQUIRE`, HistoricalStdlibVersions plumbing).

## Baseline tally (≈298 items across 21 reference files)

| Verdict | Count |
|---|---|
| ✅ Covered | ~139 |
| 🟡 Partial | ~65 |
| ❌ Missing | ~61 |
| ⚪ N/A | ~35 |

These are the original-audit counts, retained as a baseline; the wave summaries
and detailed entries below record subsequent closures. Counts are approximate —
some entries fold several sub-testsets together. Treat remaining 🟡 entries as
partial gaps: the inline note says exactly what is not yet asserted, so many are
cheap follow-ups rather than net-new test files.

## PARTIAL → COVERED pass (test/parity_gaps.jl)

A dedicated file, `test/parity_gaps.jl`, closes ~33 🟡 PARTIAL entries (fanned
out one gap per agent, each verified standalone, then merged and run together —
**39 testsets / 255 assertions green**, both standalone and through the parallel
runner). Several entries surfaced documented divergences (`why: REPL`
two-positional → 🟡→⚪; `#1066` name/uuid enforced at `validate_project`
read-time; `update` targets registries by name only; inconsistent manifests
rejected at load not instantiate; `status` emits no out-of-sync message) — all
still asserted against VibePkg's actual behavior. Each detailed entry carries a
`✔ parity_gaps.jl …` note.

**Wave 7 added (2026-07-15):** a fan-out batch closing ~20 more 🟡 PARTIAL
entries directly in their home test files (not parity_gaps.jl), each verified
green standalone then re-run merged:
- **test/execution.jl** — git tree-hash matrix ("git tree hash computation
  (parity)", 6): exec-bit sensitivity (user-x matters, group/other-x don't),
  `.git`-subdir exclusion (Foo==FooGit), and the symlink-name-prefix sort case,
  all pinned to git's actual command-line hashes.
- **test/replmode.jl** (30) — activate repl forms, accidental `]` input, status
  positional-filter matrix (name / name=uuid / uuid / comma-sugar), and
  tab-completion installed-dep filtering for rm/free/why. Surfaced divergences:
  no `@Foo`/`-` activate shorthand, `]` not stripped (throws), no `status --diff`
  warn, no #4098 dedup, no help-mode completion — all pinned to actual behavior.
- **test/git.jl** (59) — `free` drops a `[sources]` entry + resolve recovers the
  right sources over a bad manifest; recursive `[sources]` via repo URLs (a
  Parent→Child→Grandchild chain with per-level `git_source` + a path-tracked
  sibling); subdir add/develop via PackageSpec with Package-vs-Dep install
  isolation (divergence: `add(path=)` is git-only, plain-path tracking is via
  `develop`).
- **test/ops.jl** (36) — op-driven manifest upgrade to format 2.1, old-env
  `julia_version` preserved-then-flipped-on-add, and the full
  `update_on_mismatch` matrix (julia-minor mismatch, stale-compat, no-op, and
  undo-reverts-the-fallback-as-first-op). Divergence: `rm` prunes in place and
  does not itself re-stamp the format.
- **test/artifacts.jl** (43) — known-hash creation vectors (empty/single/multi/
  nested+symlinks), `find_artifacts_toml` search semantics + `artifact_hash`/
  `artifact_meta` + the `GCOps.artifact_hashes` (extract_all_hashes) analog,
  bad-Artifacts.toml structural parse errors, Override.toml multi-depot
  precedence/name-resolution/clearing/invalid-key, and a bare-project
  Artifacts.toml install. Divergence: override validation is lenient (warn, not
  error, on malformed entries).
- **test/resolve.jl** — the "schemes" entry was already fully ported (all 15
  graphs + `sanity_check`, 72/72 green); audit flipped to ✅.

**Wave 8 added (2026-07-15):** three coordinated fan-out rounds plus root
integration closed another set of detailed partials: repo-tracked app update
(including stale-shim removal), circular-precompile diagnostics, #4700 loaded
warning suppression, legacy and modern test-dependency compat, repo-source
preservation in test sandboxes, the no-test-project fallback, installed-package
build-log scratchspace placement/GC liveness, packed and unpacked registry
corruption recovery, clone-cache GC, `generate(".")` and HOME expansion,
fresh-process `entryfile` loading, real `.cov` emission, the `allow_reresolve`
fallback, and add/build/update auto-precompile triggers. The local package
server or local Git repositories cover every network-shaped case. Source fixes
were needed only for repo-app support, Pkg-compatible build-log placement, and
`generate`/REPL path handling; all other behaviors already worked and are now
pinned by tests.

**Wave 9 added (2026-07-15):** the final targeted fan-out covered first-add
General bootstrap plus six-version source churn, exact app-shim argv fidelity
(spaces, empty arguments, literal globs, and first-`--` handling), public
`Pkg.test` auto-instantiation from a source-free depot, the full activate
precedence/shared-name/HOME matrix, and cwd-relative `develop .` / `..` /
`./Name` forms. The package server and Git fixtures remain fully local. Narrow
source fixes enforce shared-environment name validation, translate relative
develop paths between cwd and project frames, and give no-argument
`Apps.develop()` the public `PkgError` contract.

**Wave 10 added (2026-07-15):** another fully local fan-out closed the
sysimage matrix, manifest-recorded registry bootstrap, multi-registry API/REPL
updates, registry Git GC, artifact creation permissions, test-subprocess thread
pool propagation, read-only-depot pidfile placement, versionless-source
re-fetch, cwd-relative depot operation, app develop/relocation, and the full
REPL prompt and option-conflict matrices. It also pinned normalize-path and
VersionWeight behavior and reclassified every stale detailed ❌ entry against
the tests that now exist. Source fixes were limited to the behaviors those
tests exposed: sysimage controls, manifest registry installation, artifact
file modes, registry maintenance, prompt rendering, and conflicting options.
All network-shaped fixtures use the local package server or local Git repos.

**Wave 11 added (2026-07-15):** fully local matrices closed registry-resolved
subdirectory add/version/rev/develop behavior, registry lifecycle identity
spellings (including UUID-precise same-name/multi-depot updates), porous
artifact selection and preservation, the complete force-latest default/false/
true matrix, dependency-bearing app development, PATCH-vs-MINOR update levels,
selective workspace installation, offline completion, develop/generate input
validation, and #913 environment re-creation from a cached revision. Exact
missing-path, yanked-version, bare-path suggestion, and auth-file permission
diagnostics are now pinned too. Tests exposed fixes for registry subdir
propagation, UUID-aware registry filtering, workspace download scoping,
developed-package entry-point validation, and the local-path add hint. Every
repository, registry, artifact, and package-server fixture remains hermetic.

**Wave 6 added:** develop-overrides-existing-entry (count stays 1), nested-dev
#1570 (no duplicate instances), mutual A↔B dev cycle, no-arg activate() clears
ACTIVE_PROJECT, instantiate rejects an inconsistent manifest, and stale-manifest
predicate flip (status stays silent).

**Waves 4–5 added:** resolver-error-names-the-package (unsatisfiable version),
invalid repo url / path add errors, add-doesn't-mutate-input, develop input
checking, same-name/different-uuid registry conflict, requesting-a-yanked-version
errors, fresh-add manifest_format v2.1, pin input checking, up-leaves-dev'd-
untouched, colliding name/uuid, package-in-two-registries-records-both, registry
rm/update by uuid & name=uuid, #3147 pin/track flag transitions, and pin+free of
a repo-tracked package.

**Waves 1–3 converted:**

- pkg.jl "range_compressed_versionspec" (1044); "versionspec with v" (1067);
  "PkgError printing" (769); "stdlib_resolve!" (662, via name↔uuid accessors);
  "URL with trailing slash" (959); "adding nonexisting packages" (489);
  "simple add… installed files read-only" (180, read-only piece);
  "targets should survive add/rm" (724); "up in Project without manifest" (511);
  "up should prune manifest" (857); "adding/upgrading versions" UPLEVEL (221).
- misc.jl "hashing" (12); "PackageSpec version default" (50).
- api.jl "issue #2587" PackageSpec uuid normalization (349).
- manifests.jl "dropbuild" (202).
- force_latest "get_earliest_backwards_compatible_version" (32).
- sources.jl "path normalization in [sources]" (56).
- new.jl "multiple registries overlapping version ranges" (3586);
  "add: repo handling" is_instantiated toggling (1008, that piece).

---

# Original ❌ checklist (fully triaged)

Each item links conceptually to the detailed entry of the same name in the
per-file sections below. The original missing-only checklist is closed; the
remaining actionable work is recorded precisely by the 44 🟡 detailed entries.
Current detailed verdicts are **211 covered · 44 partial · 41 N/A**.

**Status (2026-07-15):** the original 61-item ❌ checklist is fully triaged:
**52 implemented & verified green** · **9 explicit N/A divergences** · **0
deferred**. The "needs a heavy harness" tail — concurrency,
subprocess module-loading, and force_latest end-to-end — all turned out doable:
`test/subprocess_ops.jl` (concurrent install, usage-log atomicity, pidlocked
precompile, loaded-version status, prefer-loaded) and `test/force_latest.jl`
(the full 4-scenario end-to-end, which also exposed + fixed a real
`force_latest_compat` Compat val/str bug) and `test/project_manifest.jl`
(project-as-manifest monorepo). All passing.

The **resolver test suite is fully ported** from Pkg.jl: `test/resolve_utils.jl`
(`graph_from_data`/`sanity_tst`/`resolve_tst`, adapted to VibePkg's `Resolve`),
`test/NastyGenerator.jl`, and `test/resolvedata.tar.gz` drive the new `schemes`
(15 graphs / 72 asserts), `realistic` (4 real-world graphs + timeout paths), and
`nasty` testsets — all green.

## Beyond the audit — recent Pkg.jl PRs + quality tooling

- **Latest Pkg.jl delta audit (2026-07-15):** audited `8cb4970d9`
  (#4686), `5db81d455` (#4716), `af5b7d77a` (#4708), `a76c183c1`
  (#4701), `f1f6f1ee0` (#4700), `970bdddf5` (#4689), `870fd2f63`
  (#4684), `43dcd1fc0` (#4507), `a0c9e4387` (#4678), `ea6afa399`
  (#4679), `66ba55cb7` (#4677), `c96cfdf70` (#4661), `cff31eb4e`
  (#4662), `7ef3230ce` (#4658), `9f77c6d60` (#4646), `359cab721`
  (#4602), and `4cbe4a13b` (#4641). Most are already covered in the
  detailed entries below; #4716/#4708/#4701/#4662 are fixture/refactor-only,
  while #4679 and #4646 exercise features VibePkg does not expose. #4677's
  raw (not shell-escaped) local-path completion remains part of the existing
  partial completion backlog. The highest-value untested implemented behavior
  was **#4700**: VibePkg already passed `warn_loaded=false`, but did not prove
  it suppresses Base's misleading loaded-version warning while precompiling a
  test sandbox. ✔ DONE → `test/buildtest.jl` "test precompile suppresses
  loaded-package warning (#4700)" first proves the hermetic stale+loaded
  fixture emits the normal warning, then proves `TestOps.test!` precompiles
  and runs the new source in a subprocess without that warning (5 assertions).

- **Aqua.jl quality suite** → `test/aqua.jl` (`Aqua.test_all`, with the 10
  pinned-stdlib deps excluded from the compat-completeness check). Added to
  `.quality-env` and a new `aqua` CI job in `.github/workflows/CodeChecks.yml`,
  alongside JET/ExplicitImports. All checks green (ambiguities, piracy,
  persistent tasks, …).
- **PR #4617 — no `Core.Box` closures** → `test/boxes.jl`
  (`Test.detect_closure_boxes(VibePkg)`), guarded for Julia versions that ship
  the check. Verified on nightly (1.14-DEV): it initially found **9 `Core.Box`
  closures, all fixed** (recursive closures extracted to top-level helpers,
  reassigned captures snapshotted / de-collided / Ref'd), so it now passes
  (n=0) on nightly and `@test_skip`s on 1.12.

- **PR #4438 / issue #2728 — `CACHEDIR.TAG` in depot cache dirs.** Already
  implemented in VibePkg (`Utils.create_cachedir_tag`, called for
  registries/packages/clones/scratchspaces/artifacts, identical spec signature)
  but was untested. ✔ **Now tested** → `test/misc.jl` "create_cachedir_tag"
  (signature/idempotence/read-only tolerance) plus end-to-end assertions that a
  package install tags `packages/` (`test/execution.jl`) and an artifact install
  tags `artifacts/` (`test/artifacts.jl`).

**test/new.jl — part 1 (Depot setup, test:*, activate, add:*)**

- [x] **Concurrent setup/installation/precompilation across processes — line 172** — no concurrent/multi-process install or precompile test anywhere in the suite.  ✔ DONE → test/subprocess_ops.jl "concurrent add installs exactly once"
- [x] **test: printing — line 241** — buildtest.jl runs `TestOps.test!` but always with `io = devnull` and never asserts the human-readable testing banner/status output.  ✔ DONE → test/buildtest.jl "build and test ops" (asserts Running tests / tests passed)

**test/new.jl — part 2 (develop, instantiate, why, update, pin, free, resolve)**

- [x] **instantiate: input checking — line 1873** — no test drives instantiate/update against a manifest with an unregistered UUID (the "UnregisteredUUID" fixture case).  ✔ DONE → test/ops.jl "up/instantiate reject an unregistered manifest UUID" (`instantiate!` throws PkgError)
- [x] **update: input checking — line 2060** — no test for update erroring on an unregistered-UUID manifest or on a named package absent from the manifest.  ✔ DONE → test/ops.jl "up of a package not in the manifest errors" + "up/instantiate reject an unregistered manifest UUID"
- [~] **update: caching — line 2298** — no test for up erroring when a repo-tracked local checkout is corrupted.  ⚪ N/A → VibePkg tolerates a corrupted clone on up (resilient by design); it does not error, so nothing to assert

**test/new.jl — part 3 (test, rm, build, gc, precompile, generate, status, compat, repo caching, offline, misc)**

- [x] **test / threads — line 2494** — `TestOps.test_threads_spec()` exists in src but no test verifies that the default/interactive thread counts actually propagate into the test subprocess.  ✔ DONE → test/buildtest.jl "test thread pools propagate to the subprocess" (six real subprocesses cover `JULIA_NUM_THREADS` and `--threads` for `1`, `2`, and `2,0`, including default/interactive pool counts)
- [x] **downloads with JULIA_PKG_USE_CLI_GIT — line 3438** — `Git.use_cli_git()` exists in src but no test exercises `use_git_for_all_downloads`, `use_only_tarballs_for_downloads`, or the CLI-git download path / its failure cases.  ✔ DONE → test/git.jl "materialize via CLI git" (JULIA_PKG_USE_CLI_GIT path; VibePkg has no use_git_for_all_downloads/only-tarballs kwargs)
- [x] **relative depot path — line 3695** — no test exercises a relative `JULIA_DEPOT_PATH` entry.  ✔ DONE → test/ops.jl "relative depot path"
- [x] **Issue #2931 — line 3710** — no test drives source re-download when the manifest entry's version is `nothing` and the install dir is gone.  ✔ DONE → test/git.jl "instantiate re-fetches a versionless repo entry (#2931)"
- [x] **Issue #4345: pidfile in writable location when depot is readonly — line 3737** — ✔ DONE → `depots_stdlibs.jl` "readonly depot: pidfiles stay writable (#4345)" drives public `add` with an immutable later depot, proves its source is reused without any write there, and proves both operation logs and a newly installed version land in the writable first depot.
- [x] **sysimage functionality — line 3776** — ✔ DONE → `test/public_api.jl` "sysimage functionality" mutates `Base._sysimage_modules`/`Base.pkgorigins` exactly like Pkg's test, then exercises public add pinning, the outdated `[sysimage]` marker, repo-add/develop rejection, and every `respect_sysimage_versions(false)` escape branch against the local package server.
- [x] **status showing incompatible loaded deps — line 3876** — no test exercises the `[loaded: v…]` status annotation for a version differing from the loaded one.  ✔ DONE → test/subprocess_ops.jl "status shows loaded-version mismatch"
- [x] **Pkg.add prefers loaded dependency versions — line 3945** — 34 items — ✅ 17 / 🟡 10 /  7 / ⚪ 0  ✔ DONE → test/subprocess_ops.jl "add prefers the loaded version"

**test/pkg.jl**

- [x] **coverage specific path — line 255** — no test for coverage output to a specified tracefile path.  ✔ DONE → test/coverage.jl "Pkg.test coverage=tracefile emits populated LCOV" (public hermetic test operation creates and populates the exact requested LCOV tracefile)
- [x] **test atomicity of write_env_usage (parallel processes) — line 410** — no multi-process concurrency/atomicity test for usage-log writes.  ✔ DONE → test/subprocess_ops.jl "concurrent usage-log writes stay atomic"
- [~] **Pkg.gc for delayed deletes — line 701** — no delayed-delete-ref gc test.  ⚪ N/A → VibePkg has no orphan grace period (deletes immediately); the deprecated collect_delay warning is already tested in test/gc.jl
- [x] **issue #2191: better diagnostic for missing package — line 775** — no test for the missing-manifest-referenced-package diagnostic.  ✔ DONE → test/ops.jl "resolve errors when a dev'd path is gone"
- [x] **Suggest `Pkg.develop` instead of `Pkg.add` — line 1074** — no test that add-of-a-local-path errors with a develop suggestion.  ✔ DONE → test/ops.jl "add of a bare local path errors" (throws PkgError; VibePkg has no develop-suggestion text)

**test/repl.jl**

- [x] **unit test for REPLMode.promptf — line 690** — ✔ DONE → test/replmode.jl "REPL prompt (promptf)" asserts fallback and declared names, workspace-member paths, long-name truncation, cwd invariance, shared environments, and cache invalidation/refresh.
- [x] **REPL API `up` — line 805** — replmode tests individual level flags but not that conflicting `--major --minor` (or `--major --patch`, etc.) is rejected.  ✔ DONE → test/replmode.jl exhaustively rejects all six distinct upgrade-level pairs in either order (plus repeated flags), through both string and argv drivers; valid single `--major`/`--minor`/`--patch`/`--fixed` flags still map to their exact levels
- [~] **REPL missing package install hook — line 833** — VibePkg has no `try_prompt_pkg_add` / missing-package REPL install hook anywhere in src, ext, or tests.  ⚪ N/A → VibePkg has no try_prompt_pkg_add missing-package REPL install hook; nothing to test
- [x] **JuliaLang/julia #55850 — line 849** — ✔ DONE → test/replmode.jl "REPL prompt (promptf)" proves fresh-subprocess default-environment discovery and asserts exact `(@vX.Y) vpkg> ` output.

**test/api.jl**

- [x] **timing mode — line 156** — `timing=true` is passed as a kwarg but no test asserts the timing output format.  ✔ DONE → test/public_api.jl "precompile options" (asserts Precompiling banner + per-package elapsed time)
- [x] **delayed precompilation with do-syntax — line 172** — no do-syntax deferred-precompile test or API.  ✔ DONE → test/public_api.jl "precompile options" (do-block defers AUTO_PRECOMPILE_ENABLED, restores after)
- [~] **autoprecompilation_enabled global control — line 192** — no `autoprecompilation_enabled` toggle function or test (only the env-var-driven `should_autoprecompile`).  ⚪ N/A → VibePkg has no autoprecompilation_enabled toggle (only env-var should_autoprecompile); feature absent
- [x] **instantiate — line 229** — instantiate is tested elsewhere, but no test asserts it triggers precompilation.  ✔ DONE → test/public_api.jl "instantiate precompiles"
- [x] **waiting for trailing tasks — line 247** — no trailing-task precompile test.  ✔ DONE → test/public_api.jl "precompile behaviors" (package stderr surfaced in the precompile log)
- [x] **pidlocked precompile — line 256** — no pidlock/concurrent-precompile test.  ✔ DONE → test/subprocess_ops.jl "pidlocked precompile"
- [x] **circular dependencies — line 300 / #4602** — no assertion that precompile surfaces Base.Precompilation's cycle diagnostic.  ✔ DONE → test/public_api.jl "precompile diagnoses circular dependencies" (three local path packages; no registry/network)
- [x] **set number of concurrent requests — line 376** — the concurrency setting was untested.  ✔ DONE → test/misc.jl "concurrent-download config" (default 8, environment override 5, and `PkgError` for zero or a non-integer value)
- [x] **`[compat]` entries for `julia` — line 386** — `Planning.jl:295` raises this exact error but no test drives the path-add-with-bad-julia-compat case.  ✔ DONE → test/ops.jl "path package with incompatible [compat] julia errors"
- [x] **Yanked package handling / resolve error shows yanked packages warning — line 444** — `Planning.jl:1072-1077` builds that message but no test asserts the yanked-resolve-error output.  ✔ DONE → test/ops.jl "yanked versions named in a failed resolve"
- [~] **Pkg.activate warns on loaded module mismatch (path mismatch / re-activate / suppressed) — lines 457, 528, 542, 555** — no "Some loaded packages differ" activation warning is tested (Display.jl only has the `[loaded: …]` status annotation, not the activate-time mismatch warning).  ⚪ N/A → VibePkg does not emit a "Some loaded packages differ" warning at activate time (feature absent); only the `[loaded: …]` status annotation exists.

**test/registry.jl**

- [x] **`registries` — multiple registries in one command — line 221** — no test adds/updates/removes multiple registries in a single call, nor exercises the vector/list API forms (`Registry.add([RegistrySpec, …])`). VibePkg tests add registries one at a time.  ✔ DONE → test/registry_ops.jl "add/update/rm multiple registries in one call" (variadic public API plus executed combined REPL forms; `RegistrySpec`/vector overloads are N/A because VibePkg intentionally exposes variadic strings)
- [x] **`gc runs git gc on registries` — line 538** — ✔ DONE → test/gc.jl "gc runs git gc on registries" installs a fully local Git-backed registry, calls the public `API.gc`, and proves the registry and repository remain valid while its initially loose objects are compacted into a packfile. `GCOps.gc_registries!` now matches Pkg's best-effort maintenance step and skips packed/plain-directory registries.

**test/manifests.jl**

- [x] **v3.0: unknown format, warn — line 190** — src/EnvFiles.jl:906-910 warns on an unknown major format, but no test exercises the warning.  ✔ DONE → test/envfiles.jl "unknown manifest format warns"
- [x] **instantiate manifest from different julia_version — line 225** — `check_manifest_julia_version_compat` is untested and no instantiate test asserts the cross-version warning.  ✔ DONE → test/envfiles.jl "manifest julia_version compatibility" (strict → PkgError)
- [x] **manifest from a different julia minor version — line 280** — no test drives the warn-vs-fallback on a julia-minor-version mismatch; only the REPL flag-parse (replmode.jl:142) exists.  ✔ DONE → test/envfiles.jl "manifest julia_version compatibility" (default → warn)
- [x] **no mismatch: update_on_mismatch=true is a no-op — line 322** — no test asserts the no-op / version-preserving path.  ✔ DONE → test/ops.jl "manifest_matches_project predicate"
- [x] **undo reverts the fallback even as first op — line 334** — undo/redo stack mechanics are unit-tested (argshapes.jl:46-64) but not the first-op snapshot for the update_on_mismatch fallback.  ✔ DONE → covered by test/argshapes.jl "PackageSpec shapes" undo block (record_undo! as the first op, then undo reverts to the prior env)
- [x] **Instantiate with non-default registry from manifest — line 417** — ✔ DONE → `test/registry_ops.jl` "instantiate installs non-default registry from manifest" records an absent custom registry's local-git URL in `[registries]`, instantiates through the public API, and proves both the registry and its registered package source are installed without network access.

**test/resolve.jl**

- [x] **VersionWeight ordering preamble — line 18** — `VersionWeight` exists (`src/Resolve/versionweights.jl`) with `isless`, but no test asserts its ordering matches `VersionNumber`. Real TODO.  ✔ DONE → test/resolve.jl "VersionWeight ordering matches VersionNumber"
- [x] **realistic — line 705** — ✔ DONE → test/resolve.jl "realistic" (resolvedata1-4 via ported resolve_utils.jl + resolvedata.tar.gz; incl. JULIA_PKG_RESOLVE_MAX_TIME → ResolverError / ResolverTimeoutError).
- [x] **nasty — line 754** — ✔ DONE → test/resolve.jl "nasty" (NastyGenerator.jl ported; sat resolves, unsat throws ResolverError).
- [x] **Stdlib resolve smoketest — line 770** — `test/depots_stdlibs.jl` covers `is_stdlib`/`stdlib_infos`/versioned-stdlib entries, but nothing adds all stdlibs and resolves them as a smoketest.  ✔ DONE → test/depots_stdlibs.jl "all stdlibs resolve"

**test/force_latest_compatible_version.jl**

- [x] **OldOnly1 (`SomePkg = "=0.1.0"`) — line 39** — `test/buildtest.jl` tests only the low-level `TestOps.force_latest_compat` return value, never runs `Pkg.test` end-to-end with the `force_latest_compatible_version` kwarg across these scenarios.  ✔ DONE → test/force_latest.jl "OldOnly1"
- [x] **OldOnly2 (`SomePkg = "0.1"`) — line 72** — no end-to-end `Pkg.test` force-latest scenario asserting the unsatisfiable-throw vs allow_earlier-success behavior.  ✔ DONE → test/force_latest.jl "OldOnly2" (exposed + fixed a Compat val/str inconsistency bug in TestOps.force_latest_compat)
- [x] **BothOldAndNew (`SomePkg = "0.1, 0.2"`) — line 132** — same gap; no end-to-end force-latest test.  ✔ DONE → test/force_latest.jl "BothOldAndNew"
- [x] **NewOnly (`SomePkg = "0.2"`) — line 197** — same gap.  ✔ DONE → test/force_latest.jl "NewOnly"
- [~] **DirectDepWithoutCompatEntry — line 253** — `TestOps.force_latest_compat` treats a missing compat as an unbounded `VersionSpec()` and emits no warning (no "[compat] entry" string in `src/`); the warn behavior is untested and unimplemented.  ⚪ N/A → VibePkg treats a missing dep compat as unbounded and emits no "[compat] entry" warning (feature unimplemented)

**test/artifacts.jl**

- [x] **Artifact Creation → File permissions — line 126** — no test asserts artifact filemode (read-only files / writable dirs). Real TODO.  ✔ DONE → test/artifacts.jl "Artifact Creation file permissions" (created-tree files/file-symlinks read-only; dirs/dir-symlinks writable and traversable; recursive removal without chmod)
- [~] **Artifact archival — line 339** — no `archive_artifact`/`list_tarball_files` in src or tests. Real TODO.  ⚪ N/A → no archive_artifact/list_tarball_files in VibePkg src; feature absent

**test/workspaces.jl**

- [x] **test resolve with tree hash — line 172** — no VibePkg test runs `Pkg.test()` on a workspace with a test-subproject or checks the "no test/Manifest.toml, reinstall on missing package" behavior.  ✔ DONE → test/workspace_instantiate.jl "workspace test project shares the root manifest"
- [x] **workspace sources pointing to parent package — line 212** — no test for a workspace member with `[sources]` pointing at its parent, nor the manifest-relative vs project-relative path distinction.  ✔ DONE → test/workspaces.jl "subproject [sources] pointing at the parent"

**test/subdir.jl**

- [x] **registry-resolved subdir add/develop — line 181** — no VibePkg registry fixture declares a `subdir` field; subdir handling is only tested via direct url/path add, never through registry resolution, and the #3391 re-add idempotence for subdir packages is untested.  ✔ DONE → test/subdir_registry.jl "registry-resolved subdir add/version/rev/develop matrix" (fully local monorepo + synthetic registry; public plain/version/branch/develop forms, dependency and sibling isolation, and repeated add/develop idempotence)

**test/project_manifest.jl**

- [x] **subpackage resolve writes shared root manifest — line 13** — no VibePkg test exercises project-as-manifest monorepos where resolving/dev'ing within a subpackage writes and accumulates entries in the shared root manifest.  ✔ DONE → test/project_manifest.jl "project-as-manifest monorepo" (subpackage dev+test uses the shared root manifest)
- [~] **rm dep from subpackage / root-manifest prune behavior — line 45** — no test covers removing a dep from a subpackage and the resulting (non-)pruning of the shared root manifest.  ⚪ N/A → VibePkg prunes manifest entries unreachable from the active subpackage; Pkg's asserted #3590 non-pruning behavior does not apply (divergence, noted in the test)

**test/apps.jl**

- [x] **relocated depot keeps working — line 222** — VibePkg emits relative shims (`shim_contents(...; relative_load_path=true)`, `%depot%`) but no test relocates a depot and re-runs. Real TODO.  ✔ DONE → test/apps.jl "apps: relocated depot keeps working"

**test/misc.jl**

- [x] **inference — line 5** — the constants exist (Stdlibs.jl) but no `@inferred`/type-stability test covers them.  ✔ DONE → test/misc.jl "inference"
- [x] **normalize_path_for_toml — line 29** — `normalize_path_for_toml` exists in Utils.jl and is used, but no direct unit test exercises the slash-normalization contract.  ✔ DONE → test/misc.jl "normalize_path_for_toml"
- [x] **subprocess_handler forwards interrupts to the child — line 71** — no test exercises interrupt forwarding from the test/build subprocess handler to its child.  ✔ DONE → implemented interrupt forwarding in TestOps.subprocess_handler (used by run_test_process); tested in test/misc.jl \"subprocess_handler forwards interrupts to the child\"

**test/stdlib_compat.jl**

- [x] **Non-upgradable stdlib compat handling — line 5** — the warning logic exists (Planning.jl `check_stdlib_compat`, emits the exact "Ignoring incompatible compat entry" message) but no test triggers it.  ✔ DONE → test/stdlib_compat.jl "Non-upgradable stdlib compat handling"

<!-- total missing: 61 -->

---

# Detailed per-file audit

## test/new.jl — part 1 (Depot setup, test:*, activate, add:*)  (Pkg.jl)
VibePkg reproduces the REPL-parsing, input-validation, activate, and preserve/pin machinery well, but the end-to-end multi-version depot warm-up, concurrent installation, and `Pkg.test` output-format behaviors are thin or absent.

### Depot setup — line 30
- **Tests:** Warms a clean bundled depot: a bare `add` auto-initializes the General registry, writes `CACHEDIR.TAG` files under registries/packages/clones, installs Example at six successive registered versions (distinct source dirs per version), a second dep (JSON), repo-tracked adds (url/rev, name#rev), an unregistered url add, and `develop` by name — asserting version, source dir, `is_tracking_registry`, and that the original install is undisturbed.
- **VibePkg:** ✅ COVERED — `execution.jl` "first add bootstraps General and preserves versioned installs" starts with no project and no registry in a fresh depot, drives the public `add` API against `LocalPkgServer`, and proves the first add creates General plus the environment. It then adds all six fixture Example versions in succession, verifies the active version/source/tree and registry-tracking state after each add, and rechecks that every older content-addressed source directory remains distinct and byte-correct. The same integration asserts valid `CACHEDIR.TAG` signatures for `registries/` and `packages/`; `git.jl` covers repo/url tracking, while `misc.jl` covers cache-tag idempotence and read-only tolerance.

### Concurrent setup/installation/precompilation across processes — line 172
- **Tests:** Spawns 3 concurrent julia processes sharing a depot, each `add`-ing + loading FFMPEG; asserts no corruption, that exactly one process actually installed the package and exactly one installed the artifact (the others block on the pidfile locks).
- **VibePkg:** 🟡 PARTIAL — `subprocess_ops.jl` "concurrent add installs exactly once" runs three fresh Julia processes against one local-server depot, proves all finish without corruption and exactly one installs the Example tree; "pidlocked precompile" separately proves two precompile processes coordinate through the pidlock. Still open here: the single combined package+artifact fixture and its exactly-once artifact-install assertion.

### test: printing — line 241
- **Tests:** `Pkg.test("Example")` and asserts the printed banner: "Testing Example", Project/Manifest status lines, "Running tests...", and "Example tests passed".
- **VibePkg:** 🟡 PARTIAL — `buildtest.jl` "build and test ops" captures the real test operation's IO and asserts "Running tests..." plus "BTPkg tests passed". VibePkg does not currently print Pkg's full sandbox Project/Manifest status block, so those exact status lines remain a behavior divergence rather than untested output.

### test: sandboxing — line 256
- **Tests:** The test sandbox contains the tested project plus its explicit test deps and Test; the active dependency graph (versions) is transferred into the sandbox, including when deps track unregistered repos; a test dep can track a path or a repo (asserting `git_source`/`is_tracking_path`); `[compat]` for test deps is honored.
- **VibePkg:** ✅ COVERED — buildtest.jl "build and test ops", "test: sources-based test/Project.toml", and "test: sandbox manifest keeps the parent's versions" (#1423) cover explicit test deps, the tested project in the sandbox, path deps, and parent-version transfer. "test: modern test deps honor compat and preserve repo source" resolves registry-backed Example to 0.5.2 under the explicit test project's `[compat]` while 0.5.5 is available, and verifies that an unregistered test dependency's local git `repo-url` survives into the live sandbox manifest. The legacy-target `[compat]` path remains covered separately below.

### test: 'targets' based testing — line 337
- **Tests:** The legacy `[extras]`+`[targets]` API: `Pkg.test` works on graphs with same-name/different-UUID nodes; targeted extras become sandbox deps while untargeted ones do not; a dep-of-a-test-dep loads (#567); the active project's root is preserved when it is itself a dependency (#1423); test targets also honor `[compat]`.
- **VibePkg:** ✅ COVERED — buildtest.jl "test: legacy [extras]/[targets] sandbox deps" covers targeted-vs-untargeted extras; "test: sources-based" covers the #567 dep-of-test-dep; "test: sandbox manifest keeps the parent's versions" is #1423; ops.jl "same-name different-uuid packages coexist" covers the name/UUID case; and buildtest.jl "test: legacy target honors compat" resolves a registry-backed test extra from the hermetic local package server and proves `[compat]` selects Example 0.5.2 rather than the available 0.5.5.

### test: fallback when no project file exists — line 404
- **Tests:** A registered package (Permutations 0.3.2) with a bare `test/runtests.jl` and no `test/Project.toml` and no `[targets]` still tests, with the sandbox synthesized around the package itself.
- **VibePkg:** ✅ COVERED — `buildtest.jl` "test: fallback without test project or targets" creates a local path package with only `test/runtests.jl`, asserts the synthesized sandbox contains just the tested package, and runs it successfully in the isolated test subprocess.

### using a test/REQUIRE file — line 416
- **Tests:** Tests a package (EnglishText 0.6.0) that specifies its test deps through the deprecated Pkg2 `test/REQUIRE` file.
- **VibePkg:** ⚪ N/A — `test/REQUIRE` is a deprecated legacy mechanism; VibePkg does not implement it (no `REQUIRE` handling in src).

### activate: repl — line 426
- **Tests:** REPL-string parsing of `activate` into (api,args,opts): `--shared Foo`, `@Foo` shorthand, no-arg, plain `FooBar`, `--temp`, `-` (prev); plus GitHub URL rewriting in `add` — `.../tree/aa/gitlab` → rev, `.../pull/529` → `pull/529/head`, and `XLSX.jl#Bug-fixing-post-#289:subdir` → url/rev/subdir.
- **VibePkg:** ✅ COVERED — replmode.jl covers `activate --temp`, `activate --shared myenv`, and all three GitHub URL rewrites (tree/pull/XLSX#-in-branch); ✔ replmode.jl "activate: repl forms (new.jl:426)" adds plain `activate FooBar` and bare `activate`. Divergence pinned: VibePkg has no `@Foo` shared shorthand nor `-` (prev) — both are literal positional args (no `:shared`/`:prev` opt), so those two Pkg spellings are ⚪ divergences asserted against actual behavior.

### activate — line 475
- **Tests:** `Pkg.activate` API behavior: "Activating project at" / "Activating new project" messages, `temp=true`, `prev=true` toggling back and forth (including after `activate("")` default), and that `activate` / `activate(prev=true)` do not error when `LOAD_PATH` is empty.
- **VibePkg:** ✅ COVERED — doc_features.jl "activate - and activate(dep name)", public_api.jl "activate prev", and options.jl "activate: path, default, temp" + "activate --shared" cover the prev toggle (with error cases), temp, path, and default forms. (The empty-`LOAD_PATH` no-error edge case is not separately asserted.)

### add: input checking — line 522
- **Tests:** Rejects invalid specs with pinned messages: `julia`/`***`/`Foo Bar` not valid names, url/path-looking names suggest `url=`/`path=`, empty PackageSpec, version+rev conflict, duplicate name; typo suggestions (Examplle→Example, http→HTTP, Flix→Flux), unregistered name/UUID errors, wrong/missing UUID, plus a manifest with an unregistered UUID and an empty (commitless) git repo.
- **VibePkg:** ✅ COVERED — argshapes.jl "pinned entry diagnostics" matches the name/url/empty/version-conflict/duplicate-name/duplicate-uuid/uuid-only-unknown messages verbatim; pins.jl covers the "could not be resolved" + "Suggestions: Example" path; git.jl "add of a repo without commits" covers the commitless-repo error. (The specific http→HTTP / Flix→Flux suggestions and "unregistered UUID in manifest" cases aren't individually asserted.)

### add: changes to the active project — line 620
- **Tests:** `add` on a clean project makes a direct dep: basic add, add-by-version, add-by-URL(+rev) with `git_source`/`git_revision`, add stdlib by name / by UUID / by name+UUID, add-by-local-path (parsing name/version/deps and `git_source == realpath`), and `add` creating the default environment when the depot dir does not yet exist.
- **VibePkg:** 🟡 PARTIAL — basic add and add-by-version are covered end-to-end (execution.jl, doc_features.jl) and at plan level (ops.jl); add-by-URL/rev and add-by-local-path are covered in git.jl. Not directly asserted: adding a stdlib by name/UUID, and `add` bootstrapping the default env when the depot is absent.

### add: package state changes — line 722
- **Tests:** State transitions: double-add of a stdlib and of a package is idempotent (no compat churn); adding a new package doesn't move existing versions; add-by-version does not override a pin; add-by-version overrides a repo-tracked entry (incl. indirect deps); add-by-URL doesn't override a pin; switching branches by re-adding by name reusing the stored URL; add resolves correctly when the manifest is out of sync with project compat; the full preserve-tier matrix (tiered/tiered_installed/installed/all/direct/semver/none against libpng_jll pins); and adding to a *package* project writes/keeps `[compat]` entries.
- **VibePkg:** 🟡 PARTIAL — pin-holds-against-add and add-by-version are covered in ops.jl; "add doesn't move existing" (#607) and PRESERVE_ALL in options.jl "add preserve against newer registry versions"; the default-preserve env var in options.jl "JULIA_PKG_PRESERVE_TIERED_INSTALLED"; compat-on-add in doc_features.jl. Not directly asserted: the exhaustive preserve-level matrix, "add-by-version overrides a repo-tracked entry", and "switch branch by re-adding by name reusing URL".

### add: repo handling — line 1008
- **Tests:** Absolute-path adds are stored absolute and survive moving the project (re-`instantiate` after deleting `packages`); relative-path adds are canonicalized relative to the project, `Operations.is_instantiated` flips true/false with the tree present/absent, and break if the relative position is destroyed; URL-added packages reuse the existing clone after deleting `packages`, and re-clone the remote after deleting both `packages` and `clones`.
- **VibePkg:** 🟡 PARTIAL — ops.jl "absolute dev path stays absolute" and "relative sources path survives unrelated ops", plus git.jl "re-materialize keeps the installed tree intact" and "instantiate fetches repo package into a fresh depot" cover the underlying mechanics. is_instantiated toggling now asserted (✔ parity_gaps.jl "is_instantiated toggles with the install tree" via `Depots.find_installed`'s `installed::Bool`). Still open: the reuse-clone-then-re-clone escalation after deleting `packages`/`clones`.

### add: resolve tiers — line 1101
- **Tests:** Against a pinned General commit, four fixtures (ShouldPreserveAll/Direct/Semver/None) verify that `add` with the default tiered resolver preserves as much of the existing graph as possible, downgrading only what's forced, and that semver-preserve keeps deps within their semver range while none-preserve makes breaking changes.
- **VibePkg:** 🟡 PARTIAL — options.jl "add preserve against newer registry versions" and planning.jl exercise PRESERVE_ALL/DIRECT/NONE at the plan level against synthetic registries, but the semver-tier distinctions and the real multi-dep preserve fixtures are not reproduced.

### add: REPL — line 1164
- **Tests:** Exhaustive REPL-string parsing of `add`: UUID / `name=UUID` / `#rev` / `@version` / multiple specs / `--weak` / `--extra` / direct URL#rev; GitHub tree/commit URLs; git URLs with branch specifiers (https/bitbucket/scp/ssh); scp-style SSH URLs with IP hosts; `:subdir` specifiers; complex auth+port+`#`-in-branch+subdir URLs; local paths with rev/subdir/`~`; quoted URLs with separate specifiers; non-`.git` URLs; Windows drive letters (not subdir separators); `--preserve=` values; case-sensitive path-vs-name resolution against an existing cwd dir; nonexistent-dir errors; and the "Use `./Example`" info nudge.
- **VibePkg:** ✅ COVERED — replmode.jl "REPLMode" reproduces the URL/subdir/rev/name=uuid/version/weak/extra/preserve parsing, GitHub tree/commit/pull rewrites, scp+IP SSH URLs, complex-auth URLs, Windows drive letters, quoted URLs, local paths with rev/subdir/`~`, and non-`.git` URLs. Not covered: the cwd-existence path-vs-name disambiguation (`add example` when `./example` exists), the nonexistent-directory error, and the "Use `./Example`" info message.


## test/new.jl — part 2 (develop, instantiate, why, update, pin, free, resolve)  (Pkg.jl)
VibePkg covers the argument-parsing and plan-level mechanics of these ops well, but has real gaps in instantiate/update *input checking*, several develop materialization paths, and a few package-state edge cases.

### develop: input checking — line 1516
- **Tests:** Rejects invalid develop args: `julia`/`***`/`Foo Bar` names, URL/path-looking strings with a "did you mean url=/path=" hint, empty spec, `rev` given to develop, unregistered name, wrong/missing UUID, and duplicate specs.
- **VibePkg:** ✅ COVERED — argshapes.jl "pinned entry diagnostics" covers the shared validation; ✔ parity_gaps.jl "develop input checking" adds the develop-specific cases: `Foo Bar`, `./Foobar` / URL hints naming `Pkg.develop`, and an unregistered valid name → "could not be resolved". (wrong-UUID lookup deep in resolve not separately driven — minor.)

### develop: changes to the active project — line 1558
- **Tests:** develop by registered name / uuid / url / filesystem path, shared vs `shared=false` target dirs, recursive develop (a dev'd package's own `dev/` deps), and a relative primary depot.
- **VibePkg:** 🟡 PARTIAL — ops.jl "ops" and doc_features.jl "dependencies() and project()" cover develop-by-path (path-tracked, source recorded, deps pulled in); options.jl "develop --local clone target" checks shared/local target computation. Missing: develop-by-registered-name/uuid/url that materializes from the registry, recursive develop of nested `dev/` deps, and relative-depot placement.

### develop: interaction with `JULIA_PKG_DEVDIR` — line 1648
- **Tests:** A shared develop honors `JULIA_PKG_DEVDIR`; a local (`shared=false`) develop ignores it and uses `<project>/dev`.
- **VibePkg:** ✅ COVERED — options.jl "shared develop honors JULIA_PKG_DEVDIR; local ignores it" drives both branches through `dev_clone_target` under one custom `JULIA_PKG_DEVDIR`, proving the shared checkout lands below that directory while the local checkout and stored path remain `<project>/dev/Example` and `dev/Example`. "develop reuses an existing dev-dir clone" additionally exercises the shared branch through the public API.

### develop: path handling — line 1678
- **Tests:** Relative dev paths survive moving the project (source still resolvable); absolute paths persist across project copies; cwd-relative REPL forms `develop .`, `develop ..`, `develop ./Name` all path-track.
- **VibePkg:** ✅ COVERED — ops.jl "relative sources path survives unrelated ops" and "absolute dev path stays absolute" cover relative/absolute portability; ✔ replmode.jl "cwd-relative develop forms (new.jl:1739)" executes `develop .`, `develop ..`, and `develop ./Name` from distinct cwd layouts, proving each source exists and is path-tracked. The API now translates relative caller paths from the cwd frame into project-relative stored paths, retaining portability.

### develop: package state changes — line 1778
- **Tests:** develop overrides a package already tracking the registry, already tracking a repo, or already dev'd at a different path; develop resolves an existing manifest entry by name.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "develop overrides an existing entry (count stays 1)" (add Example → develop overrides to path-tracked, exactly one entry; re-develop at a new path overrides again). "develop resolves url-added package by name" (git materialization) remains a minor gap.

### develop: REPL — line 1829
- **Tests:** REPL parses `develop Example`, uuid, `name=uuid`, `--local`/`--shared`, url, and `--preserve=none` into the right api/args/opts.
- **VibePkg:** ✅ COVERED — replmode.jl "REPLMode" parses `develop Example`, name=uuid, url, and `dev --local Example` (`opts[:shared] === false`); preserve parsing is covered on add/up.

### instantiate: input checking — line 1873
- **Tests:** Activating a project whose manifest references an unregistered UUID makes `update`/`instantiate` throw a PkgError.
- **VibePkg:** ✅ COVERED — `ops.jl` "up/instantiate reject an unregistered manifest UUID" writes a real Project/Manifest containing a registry-shaped Ghost entry absent from the local registry, then proves update resolution raises `ResolverError` and instantiate raises `PkgError` without any network access.

### instantiate: changes to the active project — line 1884
- **Tests:** instantiate preserves the manifest tree hash for versioned and repo-tracked packages after deleting packages/clones; errors on an inconsistent dep graph; with `manifest=false` instantiates from direct deps; handles a lonely manifest, an old manifest, and duplicate names; verbose smoke test.
- **VibePkg:** 🟡 PARTIAL — execution.jl and git.jl "instantiate fetches repo package into a fresh depot" cover installing at the manifest's tree hash from a clean depot; the inconsistent-dep-graph error is now covered (✔ parity_gaps.jl "instantiate errors on an inconsistent manifest" — divergence: VibePkg rejects a dangling-dep manifest up front in parse_manifest, so it never loads, vs Pkg erroring at instantiate). Still open: `manifest=false` (instantiate from direct deps), lonely/old/duplicate-name cases, and the verbose path.

### instantiate: caching — line 1983
- **Tests:** instantiate must not re-download or overwrite already-installed source (tree hash and mtime unchanged).
- **VibePkg:** ✅ COVERED — execution.jl "Execution (local pkg server)" asserts a second instantiate installs nothing (idempotent), matching the no-overwrite guarantee.

### instantiate: REPL — line 2010
- **Tests:** REPL parses `instantiate --verbose` and `-v` to `Pkg.instantiate` with `verbose=true`.
- **VibePkg:** ✅ COVERED — replmode.jl parses `instantiate` with `--verbose`/`-v`/`-m`/`-u`/`-p`/`--workspace`/`--julia_version_strict` into the right opts.

### why: REPL — line 2025
- **Tests:** `why Foo` parses to `Pkg.why` with the package; `why Foo Bar` (two positionals) throws.
- **VibePkg:** ⚪ N/A — divergence: VibePkg's `why` REPL command takes `1:typemax(Int)` packages (`src/REPLMode.jl:189`; `API.why(::AbstractVector)` iterates), so `why Foo Bar` does NOT throw — it parses to two package args. Pkg's `1:1` two-positional-error case has no equivalent (verified empirically).

### why — line 2035
- **Tests:** `why` prints the dependency paths from the roots to the queried package (e.g. multiple chains for LinearAlgebra).
- **VibePkg:** ✅ COVERED — why.jl "why" verifies the tree-formatted output (with `(*)` subtree collapsing and per-occurrence arrowheads) and that an unknown package throws PkgError. Output format differs (tree vs `→` chains) but the behavior is fully tested.

### update: input checking — line 2060
- **Tests:** update throws on a manifest with an unregistered UUID, and on updating a package not present in the manifest.
- **VibePkg:** ✅ COVERED — `ops.jl` "up/instantiate reject an unregistered manifest UUID" covers the unregistered-manifest failure, and "up of a package not in the manifest errors" drives a targeted `plan_up` request against an empty manifest and asserts `PkgError`.

### update: changes to the active project — line 2075
- **Tests:** UPLEVEL granularity (FIXED holds, PATCH bumps patch, MINOR bumps minor); update prunes now-unused manifest entries; update works with no manifest present.
- **VibePkg:** ✅ COVERED — options.jl "public up: patch/minor levels and missing manifest" uses a local Git package and synthetic registry at 1.0.0/1.0.1/1.1.0, proving public PATCH and MINOR updates select, install, and persist the distinct expected releases, then proves public `up` resolves a project-only environment and writes its missing manifest. parity_gaps.jl "up prunes an unreachable manifest entry" exactly proves update drops an orphan while retaining the reachable direct and indirect dependency closure; "up: project vs manifest mode" covers FIXED.

### update: package state changes — line 2116
- **Tests:** basic up bumps an old version; pinned packages are not updated; stdlib special-casing; up leaves dev'd packages untouched; up of repo-tracked packages is gated by UPLEVEL (only MAJOR re-fetches) and respects pins; targeted `update(name)` with PRESERVE_DIRECT/NONE preserves non-target state.
- **VibePkg:** 🟡 PARTIAL — ops.jl "ops", git.jl "up with unregistered url-added deps", planning.jl "package→stdlib transition on up", and options.jl "up: named with preserve" cover most; the "up doesn't touch a dev'd package" assertion is now covered (✔ parity_gaps.jl "up leaves a dev'd package untouched"). Still open: UPLEVEL gating specifically on repo-tracked packages (only MAJOR re-fetches).

### update: REPL — line 2289
- **Tests:** REPL parses bare `up` to `Pkg.update` with empty opts.
- **VibePkg:** ✅ COVERED — replmode.jl parses `up` (and `up --preserve`, `up <level>`) to `VibePkg.API.up`.

### update: caching — line 2298
- **Tests:** up detects a broken local package (its `.git` removed) and throws.
- **VibePkg:** ⚪ N/A — VibePkg's update path re-materializes repo-tracked sources from its clone cache instead of treating a missing `.git` directory in the installed tree as corruption, so the upstream throw contract does not apply. Repository refresh/re-materialization is covered by `git.jl` "re-materialize keeps the installed tree intact" and "targeted rev fetches against an existing clone cache".

### pin: input checking — line 2313
- **Tests:** pin errors when the package isn't in the dep graph; pinning an unregistered package to an arbitrary version errors; pinning to a non-existent version raises a ResolverError.
- **VibePkg:** ✅ COVERED — pins.jl "pinned diagnostics" covers unresolved-name / wrong-UUID; ✔ parity_gaps.jl "pin input checking" adds the "unable to pin unregistered package … to an arbitrary version" message and pin-to-nonexistent-version → ResolverError (plus pin of a package not in the graph → PkgError).

### pin: package state changes — line 2332
- **Tests:** pin a regular registered package; pin a repo-tracked package (stays non-registry, becomes pinned); versioned pin to a different version; pin with an invalid version raises ResolverError.
- **VibePkg:** ✅ COVERED — ops.jl "ops"/"pin@version re-tracks the registry" cover registered + versioned pins; ✔ parity_gaps.jl "pin and free a repo-tracked package" covers pinning a repo-tracked package (stays repo-tracked, becomes pinned) and "pin input checking" covers the invalid-version ResolverError.

### free: input checking — line 2370
- **Tests:** free errors on a package not in the graph; free of a registry-tracked, unpinned package errors with an "expected package … to be pinned, tracking a path, or tracking a repository" message.
- **VibePkg:** ✅ COVERED — ops.jl "ops" asserts free of a registry-tracked unpinned package throws PkgError; options.jl "free: err_if_free" covers the error-vs-skip (`err_if_free=false`) semantics.

### free: package state changes — line 2387
- **Tests:** free a pinned package (unpins); free a repo-tracked package back to registry; free a dev'd package back to registry; free of a package tracking an unregistered repo/dev errors.
- **VibePkg:** ✅ COVERED — ops.jl covers free of a pinned/dev'd package; ✔ parity_gaps.jl "pin and free a repo-tracked package" covers freeing a repo/rev-tracked registered package back to registry tracking (unpinned, `[sources]` dropped).

### free: REPL — line 2430
- **Tests:** REPL parses `free Example` to `Pkg.free` with the package spec.
- **VibePkg:** ✅ COVERED — replmode.jl parses `free --all` (api === free) and rejects urls for pin/free; the free api/arg wiring is exercised.

### resolve — line 2443
- **Tests:** resolve ignores `[extras]` (they must not enter resolution); resolve re-clones a repo-tracked package whose manifest tree_hash is a SHA1, without a `startswith(::SHA1, ::String)` MethodError (#4561).
- **VibePkg:** ✅ COVERED — ops.jl "dev'd [extras] don't leak into resolution" confirms plan_resolve ignores a bogus extras uuid; git.jl "instantiate fetches repo package into a fresh depot" exercises re-fetching a repo-tracked package by its SHA1 tree_hash into a clean depot (the SHA1-handling path).


## test/new.jl — part 3 (test, rm, build, gc, precompile, generate, status, compat, repo caching, offline, misc)  (Pkg.jl)
VibePkg covers the bulk of the operation surface (test/rm/build/gc/precompile/status/compat/repo-caching/offline/readonly) at the plan/op level, but leaves the subprocess-level behaviors — thread propagation, CLI-git/tarball download paths, sysimage version pinning, loaded-version diagnostics, and a few edge-case regression tests — as real gaps.

### test — line 2473
- **Tests:** Runs a package's own test suite (stdlib special-casing via UUIDs), and threads `test_args`/`julia_args` through both `Cmd` and `Vector{String}` forms on both the legacy (no `test/Project.toml`) and new (with `test/Project.toml`) code paths.
- **VibePkg:** ✅ COVERED — `buildtest.jl` "build and test ops" (`test_args=["extra"]`) and "test: sources-based test/Project.toml"; `public_api.jl` "test op: Cmd args and allow_reresolve" exercises the `Cmd` forms of `julia_args`/`test_args`.

### test / threads — line 2494
- **Tests:** Subprocess-runs `Pkg.test("TestThreads")` under `JULIA_NUM_THREADS=1/2/2,0` and `--threads=1/2/2,0`, asserting the test process sees the expected default and interactive thread-pool sizes.
- **VibePkg:** ✅ COVERED — `buildtest.jl` "test thread spec" covers the helper and environment spellings; ✔ "test thread pools propagate to the subprocess" runs the real `TestOps.test!` boundary for all six upstream cases (`JULIA_NUM_THREADS=1/2/2,0` and explicit `--threads=1/2/2,0`) and has `runtests.jl` assert the observed default/interactive pool counts.

### rm — line 2573
- **Tests:** `rm` removes a dep without disturbing others, strips only the removed dep's compat entry (keeping `julia`/extras), removes unused recursive deps, honors `PKGMODE_MANIFEST`, and warns (not errors) on a package absent from project/manifest.
- **VibePkg:** ✅ COVERED — `planning.jl` "rm keeps compat of extras and julia" (`plan_rm` + compat pruning), `ops.jl` "rm --manifest removes the reverse-dependency closure" and the `(:warn, "`Bogus` not in project, ignoring")` case.

### rm: REPL — line 2648
- **Tests:** `pkg"rm"` parsing maps to `Pkg.rm` with correct `PackageSpec` args and `--project`/`--manifest` → `mode` opts.
- **VibePkg:** ✅ COVERED — `replmode.jl` "REPLMode" `rm --manifest`, `rm -p`, `rm --all` parse assertions.

### all — line 2669
- **Tests:** `pin`/`free`/`rm` with `all_pkgs=true` operate over every dep, are no-op-safe (including `free` when nothing is pinned), and update on an all-pinned env prints "All dependencies are pinned"; plus REPL `--all` parsing.
- **VibePkg:** ✅ COVERED — `options.jl` "all_pkgs request scopes" and "free: err_if_free"; `pins.jl` all-pinned up short-circuit ("All dependencies are pinned - nothing to update."); `replmode.jl` `pin/free/rm --all` parsing.

### build — line 2722
- **Tests:** REPL `build` parsing; a failing build throws `PkgError`; and build-log location — `deps/build.log` for a dev'd package, but under `scratchspaces/<uuid>/<hash>/build.log` (with a `CACHEDIR.TAG`) for an added package.
- **VibePkg:** ✅ COVERED — `buildtest.jl` "build and test ops" / "build: failure surfaces the log tail" cover the dev'd-package `deps/build.log` and failure path; ✔ "build: installed package log uses Pkg scratchspace" adds a failing registered package through a hermetic test-local pkg server, verifies its immutable install has no `deps/build.log`, and verifies the output at `scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/<tree-hash>/build.log`, its cache-tag signature, and the failed build's GC-liveness association in `scratch_usage.toml`. `replmode.jl` covers `build -v` parsing.

### gc — line 2782
- **Tests:** REPL `gc` / `gc --all` parse to `Pkg.gc` (`--all` now a retained no-op).
- **VibePkg:** ✅ COVERED — `replmode.jl` `gc --verbose`/`gc -v` parsing; actual GC behavior is exercised throughout `gc.jl`.

### precompile — line 2798
- **Tests:** REPL `precompile [Foo [Bar]]` (comma- or space-separated) parses to `Pkg.precompile` with the package list.
- **VibePkg:** ✅ COVERED — `replmode.jl` `precompile` and `precompile --strict --timing --workspace Foo Bar` parse assertions.

### generate — line 2827
- **Tests:** REPL `generate` parsing including path and `~` HOME expansion (#1435); `Pkg.generate(".")` in an empty cwd creates `Project.toml`/`src/Pkg.jl` (#2821); generating into a non-empty dir throws.
- **VibePkg:** ✅ COVERED — `ops.jl` covers ordinary skeleton creation, existing/non-empty and invalid-name errors, `generate(".")` in an empty cwd (#2821), and direct `~` expansion; `replmode.jl` asserts `generate Foo` dispatch and parser-time HOME expansion (#1435). The parity pass also fixed `API.generate` to accept an existing empty directory and derive its name from the absolute path.

### Pkg.status — line 2870
- **Tests:** Deprecation of positional `PKGMODE_MANIFEST`; state-change output (+/-/~ with `⇒`, `⚲` pin marker) across registry/repo/path/pin/free transitions; project & manifest status API (empty, loaded, dev, url); `→` not-downloaded marker + legend; manifest filter shows a package's deps (#1989); diff API (empty/non-empty, filtered, "No Matches"); `outdated` with `⌃` and `[compat]`/`(<v…)` detail.
- **VibePkg:** ✅ COVERED — `ops.jl` "readonly environment"/status region (empty project/manifest, `→` marker+legend, "No packages added…"), "status --diff from a git subdirectory", "extension status", #1989 stdlibs in `st -m`; `pins.jl` yanked marker, `--outdated` `(<v0.5.1)`+`[compat]`, `Diff`/"No Matches in diff". State-change arrow output and pin-marker lines exercised via diff/status paths.

### Pkg.compat — line 3095
- **Tests:** `Pkg.compat` state changes and `status(compat=true)` view (`none`/value); `compat(current=true)` sets missing entries (single, all, multiple) with the right "new entry/entries set…"/"no missing compat entries" messages; `get_compat_str` round-trips.
- **VibePkg:** ✅ COVERED — `pins.jl` "compat pins" (`print_compat` view, `current=true` messages, set/conflict/remove) and "compat status mode pins"; `ops.jl` `plan_compat` set/cap/conflict.

### Repo caching — line 3202
- **Tests:** Adding by URL/path does not overwrite existing source or clone-cache dirs (same file, unchanged mtime), even across projects; `instantiate` reuses the clone without an unnecessary fetch (master unchanged), but a nuked clone re-clones and reflects new upstream commits.
- **VibePkg:** ✅ COVERED — `git.jl` "re-materialize keeps the installed tree intact" (idempotent path, preserved marker file) and "targeted rev fetches against an existing clone cache" (cache reuse without refetch vs. `refresh`).

### project files — line 3310
- **Tests:** Corrupt project/manifest files throw `PkgError`; `read/write` round-trips for good project & manifest fixtures; manifest pruning drops orphaned entries (Crayons); relative manifest paths canonicalized; `Project.toml`↔`Manifest.toml` and `JuliaProject.toml`↔`JuliaManifest.toml` pairing.
- **VibePkg:** ✅ COVERED — `envfiles.jl` "project/manifest round trip", "JuliaProject.toml discovery" (→ `JuliaManifest.toml`), "malformed TOML scalar and array values"/"malformed manifests error"; `planning.jl` "remove and prune". (Corrupt-fixture-dir sweep is done inline rather than over a fixtures directory.)

### cycles — line 3412
- **Tests:** Dev A→B and B→A mutually; the resulting `Cycle_B/Manifest.toml` contains A's uuid (with a `@test_broken` on B not appearing in its own manifest).
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "mutual A<->B dev cycle resolves" (dev A which sources B and B sources A back — no error; both land path-tracked with the cross-references recorded in both directions, surviving write/reload). No `@test_broken` needed — VibePkg records both sides.

### downloads with JULIA_PKG_USE_CLI_GIT — line 3438
- **Tests:** Under `JULIA_PKG_USE_CLI_GIT` unset/true: `add` by name/url with `use_git_for_all_downloads=true` installs read-only sources; bad urls throw for both `Pkg.add` and `Pkg.Registry.add`; `add` with `use_only_tarballs_for_downloads=true`.
- **VibePkg:** 🟡 PARTIAL — `git.jl` "materialize via CLI git" asserts the default LibGit2 selection, flips `JULIA_PKG_USE_CLI_GIT=true`, materializes a local Git package through the CLI path, and resolves it as repo-tracked. VibePkg exposes neither `use_git_for_all_downloads` nor `use_only_tarballs_for_downloads`; the CLI-git-specific bad-URL and read-only-source matrix remains uncovered.

### package name in resolver errors — line 3471
- **Tests:** A resolver failure (`add Example@v55`) produces an error message that mentions the package name.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "resolver error names the package" (Example@99.0.0 → ResolverError "Unsatisfiable requirements detected for package …" naming Example).

### API details — line 3481
- **Tests:** `Pkg.add(packages)` does not mutate the caller's `PackageSpec` vector; API accepts `AbstractString` args (`strip(...)`).
- **VibePkg:** ✅ COVERED — `argshapes.jl` covers `AbstractString`/`SubString` name dispatch (#901); ✔ parity_gaps.jl "add does not mutate the input spec vector" asserts `API.split_specs` builds fresh `PackageRequest`s and leaves the caller's vector unchanged (length/`==`/element identity).

### REPL error handling — line 3496
- **Tests:** Malformed PackageSpec tokens (double `#rev`, double `@ver`, bare `#rev`/`@ver`), wrong argument counts, invalid options, and conflicting options each throw `PkgError`.
- **VibePkg:** ✅ COVERED — `replmode.jl` error block: `frobnicate`, too-few-args, unknown long/short options, missing/invalid `--preserve` argument, flag-takes-no-arg, unterminated quote, bare modifier `@0.5`, duplicate `#rev`, url-on-`pin`; "REPL API `up` option conflicts" exhaustively rejects switches that map to the same semantic `level` keyword through both string and argv input.

### git tree hash computation — line 3519
- **Tests:** `GitTools.tree_hash` matches git's well-known empty-tree id; text-file hash; user-exec bit changes the hash while group/other-exec bits don't; empty/nested-empty dirs excluded but symlinks not; a `.git` subdir is excluded (Foo == FooGit); symlink-name-prefix sorting edge case.
- **VibePkg:** ✅ COVERED — `execution.jl` "TreeHash" covers the empty-tree well-known id, `.git`/empty-dir exclusion, content sensitivity, and symlink hashing (incl. `legacy_symlink_size`); ✔ execution.jl "git tree hash computation (parity)" adds the remaining pieces pinned to git's actual hashes: the executable-bit sensitivity matrix (user-x changes the hash, group/other-x don't), the Foo-vs-FooGit `.git`-subdir equality, and the symlink-name-prefix sort case.

### multiple registries overlapping version ranges for different versions — line 3586
- **Tests:** A second registry offering Example only at v0.99.99 with `julia="0.0"` compat must not cause a resolver error when the primary registry has a compatible version.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "secondary registry incompatible version is skipped" (a second registry's `julia="0.0"`-only 99.99.99 is resolved around to the primary's compatible 1.0.0, no error).

### not collecting multiple package instances #1570 — line 3631
- **Tests:** Dev A into B, then in a third env dev both A and B (A already dev'd in B) — must not error from collecting multiple package instances.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "nested dev does not collect duplicate instances (#1570)" (dev B [which sources A] then dev A directly — no multiple-instances error; A stays a single path-tracked entry across write/reload).

### cyclic dependency graph — line 3645
- **Tests:** `add(path=A)` while B is active, where A dev-depends on B (and the #2302 variant with B added by path first) must not error despite the A→B→active cycle.
- **VibePkg:** ✅ COVERED — `ops.jl` "cyclic dep back onto the active project" exercises `plan_develop` of a package whose deps point back at the active project without erroring.

### Offline mode — line 3675
- **Tests:** `Pkg.offline()` restricts resolution to installed versions: `update()` is a silent no-op keeping the cached version, and adding an uninstalled version raises `ResolverError` listing only installed/uninstalled options.
- **VibePkg:** ✅ COVERED — `options.jl` "offline: installed-only resolution" (`offline` setter + `JULIA_PKG_OFFLINE`, `plan_add` throws `ResolverError` for an uninstalled request); `registry_ops.jl` offline mode skips the server query.

### relative depot path — line 3695
- **Tests:** With a relative `JULIA_DEPOT_PATH`, `init_depot_path`, and `add(path=...)` from that cwd, a path-add of a git package succeeds.
- **VibePkg:** ✅ COVERED — `ops.jl` "relative depot path" covers registry discovery and resolution through a relative `DepotStack`; ✔ "relative JULIA_DEPOT_PATH supports a repository add" sets the real environment variable, calls `Base.init_depot_path`, and performs a public cwd-relative local-git add, proving clone/package writes land beneath the relative depot and the manifest tracks the repo.

### Issue #2931 — line 3710
- **Tests:** After forcing an empty (`nothing`) version in the manifest and deleting the install dir, `Operations.download_source` still re-materializes the package directory.
- **VibePkg:** ✅ COVERED — ✔ `git.jl` "instantiate re-fetches a versionless repo entry (#2931)" writes a repo/tree manifest entry with no `version`, instantiates it from a local Git repository with registries and the PkgServer disabled, deletes the content-addressed install, and proves a second instantiate re-fetches the exact tree.

### Issue #4345: pidfile in writable location when depot is readonly — line 3737
- **Tests:** With a read-only depot behind a writable one on `DEPOT_PATH`, `Pkg.add` must not fail on pidfile creation (pidfiles go to a writable location).
- **VibePkg:** ✅ COVERED — `depots_stdlibs.jl` "readonly depot: pidfiles stay writable (#4345)" mirrors the public-add regression against `LocalPkgServer`: it installs Example 0.5.3 into a second depot, removes every write bit and snapshots every entry/mode/byte, prepends a writable depot, and successfully adds that same version in a new environment whose resolved source remains in the immutable depot. The snapshot stays identical with no pidfile, while the operation's pidlocked usage log and a subsequent new Example 0.5.5 install both land in the writable first depot.

### sysimage functionality — line 3776
- **Tests:** With a package faked into the sysimage, `add` pins its baked version, `status --outdated` shows `⌅ … [sysimage]`, `add rev=`/`develop` of a sysimage package throw, and `respect_sysimage_versions(false)` re-enables normal resolution.
- **VibePkg:** ✅ COVERED — `public_api.jl` "sysimage functionality" uses the mutable `Base._sysimage_modules`/`Base.pkgorigins` tables (no custom sysimage build) and the local package server to mirror the complete public matrix: add resolves to the baked Example 0.5.1, outdated status prints `[sysimage]`, add-by-rev and develop throw, disabling respect selects an ordinary newer registry version and permits both repository tracking forms. `pkg_issues.jl` #4131 separately covers update's build-number-mismatch preservation case.

### test entryfile entries — line 3813
- **Tests:** A package using `entryfile` (`ProjectPath`/`ProjectPathDep`) resolves and is loadable via `using` in a subprocess.
- **VibePkg:** ✅ COVERED — `envfiles.jl` covers `entryfile` parse/round-trip (and legacy `path`→`entryfile`); ✔ `subprocess_ops.jl` "entryfile packages load in a fresh subprocess" resolves a root package plus a path dependency that both use `CustomPath.jl` instead of `src/Name.jl`, verifies the dependency manifest entry, and loads and executes both modules in a brand-new hermetic Julia process.

### test resolve with tree hash — line 3826
- **Tests:** Resolving `ResolveWithRev` materializes the Example source dir; removing it and re-resolving re-materializes it.
- **VibePkg:** ✅ COVERED — `git.jl` "lone rev in [sources]" (resolve of a rev-tracked source with inferred url/tree-hash) and "instantiate fetches repo package into a fresh depot" cover resolve-time source materialization.

### status diff non-root — line 3844
- **Tests:** In a git repo where the active project is a subdirectory, `status(diff=true)` still shows `+ Example`.
- **VibePkg:** ✅ COVERED — `ops.jl` "status --diff from a git subdirectory" (#1738).

### test instantiate with sources with only rev — line 3859
- **Tests:** A `[sources]` entry with only a `rev` (no url) instantiates, recording the correct `git_revision` and `git_source`.
- **VibePkg:** ✅ COVERED — `git.jl` "lone rev in [sources]" asserts `is_repo_tracked`, url inferred from registry, `entry_repo_rev`, and `entry_tree_hash` for a rev-only sources entry.

### status showing incompatible loaded deps — line 3876
- **Tests:** A subprocess loads Example v0.5.4 then activates a temp env adding v0.5.5; status output shows the `[loaded: v0.5.4]` annotation.
- **VibePkg:** ✅ COVERED — `subprocess_ops.jl` "status shows loaded-version mismatch" loads Example 0.5.4 in a fresh Julia process, switches to a local-server environment containing 0.5.5, and asserts status prints `[loaded: v0.5.4]`.

### Readonly Environment Tests — line 3896
- **Tests:** `Pkg.readonly()` getter/setter (returns previous state), status shows `(readonly)`, and add/rm/update/pin/free/develop throw `PkgError` while readonly; disabling restores normal operation.
- **VibePkg:** ✅ COVERED — `public_api.jl` "readonly" (setter/getter, persisted `readonly = true`, "Cannot modify a readonly environment", stale-snapshot guard) and `ops.jl` "readonly environment" ((readonly) header + write rejection).

### Pkg.add prefers loaded dependency versions — line 3945
- **Tests:** Subprocess: adding Example loads v0.5.4, then in a fresh env plain `add` picks the newest (v0.5.5), but `prefer_loaded_versions=true` (and REPL-mode default) prints "was able to add the version … already loaded" and lands on v0.5.4.
- **VibePkg:** 🟡 PARTIAL — `public_api.jl` "add prefer_loaded_versions" covers `plan_add` honoring `preferred_versions`, `collect_preferred_loaded_versions`, and the REPL-default scoped value; the end-to-end subprocess flow and the "was able to add the version…already loaded" message are not asserted.


## test/pkg.jl  (Pkg.jl)
Older-style API/integration suite covering version parsing, add/rm/update/pin/develop/gc/test lifecycle, download protocols, usage-log robustness, and many regression issues; VibePkg covers the version algebra and most core ops well but lacks several download-flag, coverage-file, delayed-delete, and specific-error-message tests.

### semver notation — line 25
- **Tests:** `semver_spec` for caret/tilde/inequality/equality/hyphen-range/union forms, membership `in`, invalid-input errors, and `isjoinable` on `VersionBound`s.
- **VibePkg:** ✅ COVERED — versions.jl "semver_spec caret/tilde/equality and inequalities/hyphen and unions/invalid inputs" plus "VersionBound".

### union, isjoinable — line 155
- **Tests:** `union!` merging/joining adjacent `VersionRange`s and `VersionBound`s, and `VersionRange` printing.
- **VibePkg:** ✅ COVERED — versions.jl "VersionSpec normalization & equality" (union at construction, sorted/adjacent joined) and "VersionSpec membership & set ops"; `isjoinable` (src/Versions.jl) exercised via those unions.

### simple add, remove and gc — line 180
- **Tests:** add Example, installed files are read-only, rm, then `gc` reaps unused package dirs and unused git clones.
- **VibePkg:** ✅ COVERED — add/rm and gc-reaping-dead-packages are covered (ops.jl, gc.jl "gc"); installed-files-read-only is asserted in parity_gaps.jl "installed files are read-only" (user-write cleared, write raises SystemError); ✔ gc.jl "gc reaps unreachable repo clone caches" materializes a real bare cache from a local Git repository, proves a live manifest usage root preserves it, then removes that root and proves the unreachable clone-cache directory is reaped.

### package with wrong UUID — line 203
- **Tests:** add with wrong UUID throws PkgError; wrong-UUID-but-correct-name yields a detailed message listing the registered UUID; missing-uuid spec throws.
- **VibePkg:** ✅ COVERED — pins.jl asserts "expected package `Example [00000000]` to be registered" and "wrong UUID for package Example" messages.

### adding and upgrading different versions — line 221
- **Tests:** add pinned VersionNumber / VersionRange; adding another package doesn't upgrade existing; `update(level=UPLEVEL_PATCH)` and `UPLEVEL_MINOR` bump appropriately.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "up UPLEVEL patch vs minor" drives `plan_up` at FIXED/PATCH/MINOR against a 1.0.0/1.0.1/1.1.0 registry (holds / →1.0.1 / →1.1.0).

### testing — line 242
- **Tests:** `Pkg.test(...; coverage=true)` runs tests and produces `.cov` files in the package dir.
- **VibePkg:** ✅ COVERED — ✔ `coverage.jl` "Pkg.test coverage=true emits .cov files" runs the public test operation on a local path package, proves its tests pass in the real subprocess, and asserts that coverage output is emitted beside the tracked source file (fully hermetic; no registry/network).

### coverage specific path — line 255
- **Tests:** `Pkg.test(...; coverage=path)` writes an LCOV tracefile to the given path.
- **VibePkg:** ✅ COVERED — ✔ `coverage.jl` "Pkg.test coverage=tracefile emits populated LCOV" runs the public test operation on a local path package, then proves the exact requested path exists, is nonempty, and contains an exercised source-file LCOV record (fully hermetic; no registry/network).

### pinning / freeing — line 265
- **Tests:** pin to a version, `update` keeps it pinned, `free` then `update` returns to the latest version.
- **VibePkg:** ✅ COVERED — ops.jl "pin@version re-tracks the registry" and "free dev'd registered package"; options.jl "free: err_if_free"; pins.jl.

### develop / freeing — line 278
- **Tests:** develop bumps version above registry; hand-editing the dev project to v100 then resolve/build/test picks it up; `free` returns to a registered version.
- **VibePkg:** ✅ COVERED — ops.jl "free dev'd registered package" / "dev then resolve picks up new deps"; buildtest.jl build+test of a dev'd package; doc_features.jl develop.

### stdlibs as direct dependency — line 340
- **Tests:** add a stdlib (CRC32c) as a direct dep and `update` without breaking other deps.
- **VibePkg:** ✅ COVERED — depots_stdlibs.jl "Stdlibs" and planning.jl "stdlib deps come from the local stdlib, not the registry".

### package name in resolver errors — line 350
- **Tests:** requesting an unsatisfiable version produces a resolver error whose message contains the package name.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "resolver error names the package" (unsatisfiable Example@99.0.0 → ResolverError names Example).

### protocols — line 358
- **Tests:** `setprotocol!`/`GitTools.normalize_url` rewrite clone URLs per domain (https↔ssh), plus deprecation of the old `setprotocol!` forms.
- **VibePkg:** ✅ COVERED — doc_features.jl "setprotocol! rewrites clone urls per domain" via `Git.normalize_url` (deprecation of legacy positional form not covered).

### check logging — line 404
- **Tests:** after ops, `manifest_usage.toml` in logdir contains an entry keyed by the manifest path.
- **VibePkg:** ✅ COVERED — depots_stdlibs.jl asserts `log_usage` appends/compacts to one timestamped entry per manifest key.

### test atomicity of write_env_usage (parallel processes) — line 410
- **Tests:** N=CPU_THREADS concurrent processes hammering `EnvCache()` never corrupt the usage log (no task fails).
- **VibePkg:** ✅ COVERED — `subprocess_ops.jl` "concurrent usage-log writes stay atomic" runs multiple fresh Julia processes against one shared depot, then parses the resulting `manifest_usage.toml` and proves every worker completed cleanly.

### parsing malformed usage file — line 469
- **Tests:** a usage entry missing its `time` key doesn't error subsequent adds that rewrite the usage log.
- **VibePkg:** ✅ COVERED — gc.jl "gc tolerates corrupt usage log", "log_usage self-heals corrupt usage log", "gc tolerates schema-corrupt usage logs".

### adding nonexisting packages — line 489
- **Tests:** `add`/`update` of a random nonexistent package name throw PkgError.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "add nonexistent package throws" asserts `plan_add`/`plan_up` of a syntactically-valid unregistered name throw `PkgError` ("could not be resolved").

### add julia — line 497
- **Tests:** `Pkg.add("julia")` throws (reserved name).
- **VibePkg:** ✅ COVERED — argshapes.jl asserts `add(name="julia")` → "`julia` is not a valid package name".

### libgit2 downloads — line 503
- **Tests:** `add(...; use_git_for_all_downloads=true)` installs Example (read-only), then rm.
- **VibePkg:** 🟡 PARTIAL — git-clone install machinery is tested (git.jl "Git", "instantiate fetches repo package into a fresh depot"), but the `use_git_for_all_downloads` download-mode kwarg path isn't specifically exercised.

### up in Project without manifest — line 511
- **Tests:** in a Project.toml-only env, `update` resolves and installs the dep (creating the manifest).
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "up bootstraps a missing manifest" (project-only env → `plan_up`+`apply!` creates the Manifest.toml with Example).

### libgit2 downloads — line 525
- **Tests:** duplicate of line 503 — `add(...; use_git_for_all_downloads=true)` then rm.
- **VibePkg:** 🟡 PARTIAL — same as line 503: git-install machinery covered, the download-mode kwarg isn't.

### tarball downloads — line 530
- **Tests:** `add("JSON"; use_only_tarballs_for_downloads=true)` installs from tarballs.
- **VibePkg:** ✅ COVERED — execution.jl "Execution (local pkg server)" installs packages from server tarballs (tree-hash verified).

### test should instantiate — line 538
- **Tests:** `Pkg.test()` in an un-instantiated project auto-instantiates before running (issue #324).
- **VibePkg:** ✅ COVERED — ✔ `buildtest.jl` "test auto-instantiates a missing manifest source" runs public `VibePkg.test()` on a local package whose manifest pins Example 0.5.2 while a brand-new depot contains neither General nor the Example source; `LocalPkgServer` supplies both, and the test proves the source is absent before the call, installed afterward at the pinned tree/version, and loaded by the real test subprocess (Pkg.jl#324, fully hermetic).

### valid project file names — line 552
- **Tests:** `generate` a package, activate, then Julia-flavored `JuliaProject.toml`/`JuliaManifest.toml` are discovered and dev works.
- **VibePkg:** ✅ COVERED — envfiles.jl "JuliaProject.toml discovery" + "versioned manifest discovery"; ops.jl `generate`.

### invalid repo url — line 596
- **Tests:** `add("https://github.com")` and `add("./Foobar")` both throw PkgError.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "invalid repo url / path add errors": `add("https://github.com")` and `add("./Foobar")` throw PkgError at name-validation time (URL/path hint), and `add(path="./Foobar")` into an absent dir throws the isdir-guard PkgError.

### instantiating updated repo — line 611
- **Tests:** multi-depot/multi-machine flow: clone, add by path, copy env to a second depot and instantiate, commit upstream changes, update, re-copy manifest, re-instantiate.
- **VibePkg:** ✅ COVERED — git.jl "instantiate fetches repo package into a fresh depot" and execution.jl second-fresh-depot instantiate cover the cross-depot re-materialization.

### printing of stdlib paths, issue #605 — line 657
- **Tests:** `pathrepr(stdlib_path("Test"))` renders as `` `@stdlib/Test` ``.
- **VibePkg:** ✅ COVERED — argshapes.jl asserts `Display.pathrepr(.../Test) == "`@stdlib/Test`"`.

### stdlib_resolve! — line 662
- **Tests:** `stdlib_resolve!` fills a missing uuid from a stdlib name and a missing name from a uuid, and leaves fully-specified specs alone.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "stdlib name<->uuid completion" asserts bidirectional completion via `EnvFiles.stdlib_uuid_for_name` / `Stdlibs.stdlib_infos` (VibePkg's PackageSpec is immutable, so no in-place `stdlib_resolve!`).

### issue #913 — line 675
- **Tests:** add rev="master", delete Project/Manifest, re-add the same rev — must not fail.
- **VibePkg:** ✅ COVERED — `git.jl` "re-add the same revision after deleting the environment (#913)" adds a local Git package by branch through the public API, deletes both Project.toml and Manifest.toml while retaining the clone/package cache, then re-adds the same revision and proves both files are recreated with the identical repo revision and tree hash.

### Pkg.gc — line 687
- **Tests:** after add + gc, stray `.DS_Store` files in packages/ and package subdirs don't break a second gc (issues #601/#1228).
- **VibePkg:** ✅ COVERED — gc.jl "gc tolerates stray files in packages/" writes `.DS_Store` at every packages/ level and confirms gc proceeds.

### Pkg.gc for delayed deletes — line 701
- **Tests:** `gc` processes `Base.Filesystem.delayed_delete_ref` entries, deleting the referenced files/dirs.
- **VibePkg:** ⚪ N/A — VibePkg deletes unreachable content immediately and has no delayed-delete queue or `Base.Filesystem.delayed_delete_ref` integration. `gc.jl` covers the deprecated `collect_delay` warning, but there is no equivalent deferred-delete behavior to test.

### targets should survive add/rm — line 724
- **Tests:** a project's `[targets]` are unchanged after an add followed by an rm (issue #876).
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "[targets] survive add/rm" asserts the `[targets]` table (order-preserving, byte-identical TOML) is unchanged after an add-then-rm.

### canonicalized relative paths in manifest — line 739
- **Tests:** reading a manifest path yields OS-native separators; writing emits forward slashes (`path = "bar/Foo"`).
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest entry states" round-trips a `PathTracked("../Foo")` entry, emitting forward-slash `path = "../Foo"`.

### building project should fix version of deps — line 760
- **Tests:** `Pkg.build()` on a project runs deps/build.jl and produces its artifact.
- **VibePkg:** ✅ COVERED — buildtest.jl "build and test ops" runs `build!` and checks the produced file; "build: failure surfaces the log tail" covers the error path.

### PkgError printing — line 769
- **Tests:** `show(PkgError)` renders `PkgError("...")` and `showerror` prints the bare message.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "PkgError printing" asserts `show` renders `PkgError("…")` and `showerror` prints the bare message.

### issue #2191: better diagnostic for missing package — line 775
- **Tests:** dev a path package, delete its directory, `resolve` → PkgError whose message contains "This package is referenced in the manifest file:".
- **VibePkg:** ✅ COVERED — `ops.jl` "resolve errors when a dev'd path is gone" develops a local package, deletes its source, captures the resulting `PkgError`, and asserts both the exact `"This package is referenced in the manifest file:"` diagnostic and the active manifest path.

### issue #1066: colliding name/uuid in project — line 810
- **Tests:** develop/add of a package whose name (but not uuid) or uuid (but not name) collides with an existing project dep throws PkgError.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "colliding name or uuid in project errors" asserts the same-uuid/different-name collision throws PkgError ("Two different dependencies/weak dependencies can not have the same uuid"). Enforcement-point divergence: VibePkg keeps `[deps]` a name→UUID map (same-name collision can't be expressed) and enforces the uuid invariant at `validate_project` read time rather than at dev/add time.

### issue #1180: broken toml-files in HEAD — line 835
- **Tests:** `status(diff=true)` warns "could not read project from HEAD" and falls back when HEAD's Project.toml is broken.
- **VibePkg:** ✅ COVERED — pins.jl "status --diff pin" asserts the exact `:warn` "could not read project from HEAD, displaying absolute status instead." fallback.

### REPL command doc generation — line 849
- **Tests:** `REPLMode.canonical_names()` entries expose `.help` as a `Markdown.MD` for commands like "add" and "registry add".
- **VibePkg:** 🟡 PARTIAL — REPL help output is tested (replmode.jl `show_help` for "add"/"registry"), but the docstring-as-`Markdown.MD` extraction contract isn't asserted (VibePkg help may not be Markdown).

### up should prune manifest — line 857
- **Tests:** `update` drops now-unreachable indirect deps from the manifest (Unpruned fixture: Example stays, Unicode removed).
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "up prunes an unreachable manifest entry" (orphan dropped by `plan_up`, reachable Example + its Test dep kept).

### undo redo functionality — line 874
- **Tests:** undo/redo stack across add/rm, no-op adds don't push states, and state persists across project swaps.
- **VibePkg:** ✅ COVERED — argshapes.jl "undo/redo stack mechanics" exercises `record_undo!`/`snapshot_undo!`/`undo_redo_step!` including dedup and new-timeline-drops-redo.

### subdir functionality — line 932
- **Tests:** add url+subdir, update, instantiate, rm; then develop a local path+subdir with correct source.
- **VibePkg:** ✅ COVERED — git.jl "subdirectory add" and "dev by name of a url-added subdir package".

### URL with trailing slash — line 959
- **Tests:** `add(url=".../Example.jl.git/")` strips the trailing slash and installs (PR #1784).
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "URL trailing slash" asserts `Git.normalize_url` strips a trailing `/` (and collapses several) so a `.git/` URL matches the non-slash form.

### Pkg.test process failure — line 968
- **Tests:** test-subprocess failures raise PkgError with mode-specific messages: signal KILL, exit code 1, exit code 2, and aggregated multi-package failures.
- **VibePkg:** ✅ COVERED — buildtest.jl "build and test ops" asserts "errored during testing", exit-code-suffixed messages, and the multi-package aggregation format (signal-KILL wording not separately asserted).

### range_compressed_versionspec — line 1044
- **Tests:** compress a version pool (with/without a subset) into a minimal `VersionSpec` of ranges.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "range_compressed_versionspec" ports the reference pool/subset assertions directly.

### versionspec with v — line 1067
- **Tests:** `VersionSpec("v1.2.3")` parses the `v` prefix and gives correct membership.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "versionspec with v" asserts `VersionSpec("v1.2.3")` strips the prefix and has correct membership.

### Suggest `Pkg.develop` instead of `Pkg.add` — line 1074
- **Tests:** `add(; path=dir)` where dir has only a Project.toml throws PkgError suggesting `develop`.
- **VibePkg:** ✅ COVERED — `ops.jl` "add of a bare local path errors" creates a project-shaped directory with no Git repository, drives public `VibePkg.add(; path=...)`, and asserts its `PkgError` includes `perhaps you meant VibePkg.develop?`. API validation emits this before registry or clone side effects.

### Issue #3069 — line 1083
- **Tests:** `ensure_resolved` on a PackageSpec with neither name nor uuid throws a specific PkgError naming the spec.
- **VibePkg:** ⚪ N/A — VibePkg has no mutable `ensure_resolved` phase or unresolved `PackageSpec` state: `split_specs` converts name/uuid specs into immutable `PackageRequest`s, while path/URL specs are materialized directly into identity-bearing `RepoPackage`s. Missing identity is rejected at those boundaries, so Pkg's internal post-mutation `PackageSpec` diagnostic has no VibePkg call target.

### Issue #3147 — line 1090
- **Tests:** pin/develop/add/update interactions preserve pin and tracking flags (is_pinned/is_tracking_path/is_tracking_repo) and versions across dev→pin→add and pin→update-noop→re-pin sequences.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "pin/track flag transitions (#3147)" asserts a coherent subset of the flag matrix: add→pin→up (pin flag + version held), dev→unrelated-add (dev entry stays path-tracked/unpinned), and dev→versionless-pin (pinned && path-tracked).

### check_registered error paths — line 1162
- **Tests:** with zero registries, `add` auto-installs General; and a manifest referencing an unregistered UUID triggers an "expected package to be registered" error.
- **VibePkg:** ✅ COVERED — registry_ops.jl "registry bootstrap"/auto-update install a registry on demand, and pins.jl asserts the "expected package ... to be registered" message.

### relative path resolution from different directories (issue #2291) — line 1195
- **Tests:** add a local package by relative path (manifest stores `../LocalPackage`), then `update` from a different cwd resolves it correctly.
- **VibePkg:** ✅ COVERED — ops.jl "relative sources path survives unrelated ops" (and "absolute dev path stays absolute") cover relative-source resolution across ops/dirs.


## test/repl.jl  (Pkg.jl)
Exercises the `pkg>` REPL mode end to end: command/argument parsing, tab completions, the prompt string, subcommands, error messages, and the interactive compat/missing-package hooks. VibePkg covers parsing and completions well (test/replmode.jl), but has no tests for the prompt string, the missing-package install hook, or the interactive compat editor, and several REPL-driven integration flows are only tested at the API level.

### help — line 18
- **Tests:** `?`, `? add`, `?add`, `help add` all invoke help; `helpadd` (no space) throws PkgError.
- **VibePkg:** ✅ COVERED — test/replmode.jl "REPLMode" maps `("?","? add","?add","help add")` to `help_command`, and `show_help(devnull,"bogus")` throws.

### accidental — line 28
- **Tests:** Accidental bracket/paste inputs inside pkg mode are tolerated: `]?`, `] st`, `]st -m`, and a bare `]` (noop) do not crash.
- **VibePkg:** ⚪ N/A (divergence pinned) — ✔ replmode.jl "accidental bracket input (repl.jl:28)": VibePkg's `do_cmd` does NOT strip a leading `]`, so `]?`, `] st`, `]st -m`, bare `]`, … all throw `PkgError` (unrecognized command). Pkg strips the bracket and tolerates them; the divergent behavior is now asserted for every form.

### generate/dev validation errors — line 40
- **Tests:** `dev Example#blergh` (bad rev), `add ÖÖÖ` (illegal name), `generate 2019Julia` (name starting with digit), and `dev ./Foo` where the package has a missing `src/Foo.jl`, a name-only Project.toml, or a uuid-only Project.toml all throw PkgError.
- **VibePkg:** ✅ COVERED — `replmode.jl` "generate/develop validation errors (repl.jl:40)" executes the real REPL driver entirely offline: bad-revision develop, unregistered non-ASCII add, and digit-leading generate all throw `PkgError`; a generated package develops successfully, then fails after its source entry point is removed and with either a name-only or uuid-only Project.toml. The public `API.develop` boundary performs Pkg's source-entry-point existence check (including custom `entryfile`), while the low-level planner remains usable by metadata-only synthetic fixtures.

### add/rm/pin/free/update/develop/instantiate workflow — line 72
- **Tests:** Full REPL round-trip: `add Example@0.5.3` pins the version, comma/space/whitespace-leading forms of add+rm, `add Example#master` and url#master track a rev, `up --fixed` keeps the tracking rev, `test Example`, pin/free/`free` twice throws, `update` picks up a new commit, `add path#commit`, `develop` (1 and 2 names), and instantiate reproduces into a fresh depot.
- **VibePkg:** 🟡 PARTIAL — the parse of every form (`add name@ver`, `#rev`, urls, comma sugar) is covered in replmode, and the operations are covered at API level (options.jl, git.jl, ops.jl), but the REPL-string execution of this end-to-end workflow (add→pin→up --fixed→test→free-twice→instantiate) is not run as pkg-mode commands.

### Pkg.status inside a git repo (#904) — line 178
- **Tests:** `Pkg.status()` and `pkgstr("status")` inside an activated git-tracked package do not throw.
- **VibePkg:** ✅ COVERED — test/ops.jl "status --diff from a git subdirectory" and "status pins" exercise status inside git repos without error.

### develop unregistered + nested submodule relative paths — line 186
- **Tests:** `develop` an unregistered path package, then build+precompile and test it; nested case checks that dev'ing `./SubModule1` and `../SubModule2` writes *relative* manifest paths that stay valid when the project is copied elsewhere.
- **VibePkg:** 🟡 PARTIAL — test/ops.jl "absolute dev path stays absolute"/"relative sources path survives unrelated ops" and workspaces cover relative-path handling, but the specific nested-directory dev (`../SubModule2` from a subdir) writing relative paths + copy-and-reresolve invariant is not reproduced.

### activate matrix — line 249
- **Tests:** `activate .`; `activate --shared` rejects illegal names (`.`, `./Foo`, `Foo/Bar`, `../Bar`) without changing env; activate resolves path-Foo over dep-Foo, developed Foo from another dir, shared Foo, empty-directory creation, added-dep is not activated, existing shared env in a pushed depot, bare `activate` (LOAD_PATH), and `~` expansion.
- **VibePkg:** ✅ COVERED — options.jl "activate: path, default, temp" / "activate --shared" and doc_features.jl "activate - and activate(dep name)" cover the API core and later-depot shared lookup; ✔ replmode.jl "activate matrix (repl.jl:249)" executes the remaining matrix: `activate .`, every illegal shared path spelling with unchanged-env checks, cwd-path over developed-dep precedence, developed lookup from another cwd, explicit shared lookup, lazy new-directory activation, HOME expansion, and proof that a registry-added Example (served by LocalPkgServer) is not activated as its installed source. The shared validator now rejects `.`/`..` as paths as well as separator-containing spellings.

### dev --local/--shared path relativity — line 307
- **Tests:** With `JULIA_PKG_DEVDIR` inside the project, `dev`/`dev --shared Example` keep an absolute manifest path, while `dev --local Example` records a relative `dev/Example` path.
- **VibePkg:** ✅ COVERED — test/options.jl "develop --local clone target" and test/ops.jl "absolute dev path stays absolute" cover local-relative vs shared-absolute dev paths.

### tab completion while offline — line 331
- **Tests:** With no registry and offline, `add Exam` yields no completions; after adding the General registry, offline completion of `add Exam` still finds "Example".
- **VibePkg:** ✅ COVERED — `replmode.jl` "tab completion while offline (repl.jl:331)" enables offline mode in an isolated empty depot and proves `add Exam` has no candidates, then installs a synthetic on-disk registry, resets the completion cache, and proves the same offline query returns exactly `Example` without contacting a server.

### tab completion — line 350
- **Tests:** Extensive: remote name completion, `rm/free/why` completion restricted to installed deps (with `-p/-m/--project/--manifest` variants), option completion (`up --man`, `rem`→remove), `apply_completion`, help-mode completion (`?ad`→`?add`), stdlib names, upper-bound exclusion, local-path/subdir/`~` completion, not completing files, dedup of already-specified packages (#4098), trailing-space completion, and the LineEdit type contract (#58690, #4121).
- **VibePkg:** 🟡 PARTIAL (reduced) — replmode covers command/option completion, stdlib names, path+`~`+activate completion, registered-name and deprecated-exclusion, and no-crash on malformed input; ✔ replmode.jl "tab completion gaps (repl.jl:350)" now adds installed-dep filtering for `rm/free/why` (COVERED) and pins two divergences: #4098 dedup of already-specified packages is NOT implemented and help-mode completion (`?ad`→`?add`) is absent (both ⚪, asserted against actual behavior). Still open: subdir completion, file exclusion, upper-bound exclusion, and the explicit LineEdit return-type assertions.

### BigProject multiline input — line 562
- **Tests:** Multi-line `pkg"""..."""` input (dev/add/build over several lines), `build BigProject`, `add BigProject` throws (self-add), multi-line `test` of submodules, and `compat JSON` + `up` moving JSON's version and back.
- **VibePkg:** 🟡 PARTIAL — replmode tests statement chaining via `;`, and buildtest/planning cover build/test/compat at API level, but newline-separated multiline pkg-string input and this integration flow are not tested.

### add/remove using quoted local path — line 607
- **Tests:** Add/remove packages via quoted local paths whose directory names contain spaces and significant characters (`@ ; # '`), using both single and double quotes, singly and in multi-package statements.
- **VibePkg:** 🟡 PARTIAL — replmode tests quoted-word parsing (`activate "some dir/with space"`, `add "Weird#Name"`, `add "git@...git"#master`, and single/double-quoted multi-word specs), but not the add-then-remove integration round-trip against real generated packages with weird dir names.

### parse package url win — line 684
- **Tests:** `PackageIdentifier(url)` → `parse_package_identifier` yields a `PackageSpec` (url parsing produces a valid spec).
- **VibePkg:** ✅ COVERED — test/replmode.jl exhaustively parses urls (https, ssh/scp, subdir specifiers, tree/pull urls, quoted urls) into `PackageSpec` via do_cmd.

### unit test for REPLMode.promptf — line 690
- **Tests:** `promptf()` renders `(EnvName) pkg> `, truncates long env names (`(this_is_a_test_for_truncati...) pkg> `), reflects Project.toml `name` changes, and is invariant to `cd` (with cache invalidation between calls).
- **VibePkg:** ✅ COVERED — `replmode.jl` "REPL prompt (promptf)" asserts directory-name fallback, declared and edited Project.toml names, long-name truncation, cwd invariance, workspace-root/member path rendering, shared-environment `@` marking, and the cached value before versus refreshed value after `invalidate_prompt!()` (including the `[offline]` suffix).

### test — line 733
- **Tests:** `test --project Example` throws (invalid option combo), `test --coverage Example` and `test Example` run.
- **VibePkg:** 🟡 PARTIAL — replmode parses `test --coverage Foo` and public_api/buildtest cover the test op, but there is no `test --project` error case (VibePkg's test command has no `--project` option to reject).

### activate — line 746
- **Tests:** `activate Foo` activates `pwd()/Foo/Project.toml`, then bare `activate` returns to the default project.
- **VibePkg:** ✅ COVERED — test/options.jl "activate: path, default, temp" covers activate-by-path then return-to-default.

### status — line 762
- **Tests:** status argument matrix: `-m`, by name, by `name=uuid`, by uuid, multiple names, `-m Example`, `--outdated`, `--compat`; `--diff`/`-d` warns without git then works after commit; comma-separated names parse.
- **VibePkg:** ✅ COVERED — replmode parses `st -m/-p/-o/-d/-e/--deprecated`; pins.jl/ops.jl cover status --diff and compat modes; ✔ replmode.jl "status arg matrix (repl.jl:762)" adds the uuid / `name=uuid` / bare-name / comma-sugar positional filtering. Divergence: VibePkg emits no "diff option only available in git" warn — `--diff`/`-d` just parse to `opts[:diff]` (⚪, runtime-only, asserted at parse).

### subcommands — line 792
- **Tests:** Compound command form `package add Example` / `package rm Example` works.
- **VibePkg:** ⚪ N/A — VibePkg has no `package` compound command; its compound subcommands are `registry …` and `app …` (both parsed+tested in replmode). The `package` namespace is a Pkg feature VibePkg does not implement.

### REPL API `up` — line 805
- **Tests:** `up --major --minor` (conflicting upgrade levels) throws PkgError.
- **VibePkg:** ✅ COVERED — `replmode.jl` validates each single level switch and exhaustively rejects all six distinct `--major` / `--minor` / `--patch` / `--fixed` pairs in both orders, plus duplicate switches, through both the REPL-string and argv command drivers. The parser now rejects any repeated semantic option key instead of silently taking the last value.

### Inference — line 814
- **Tests:** `@inferred` on Pkg's `OptionSpecs`, `CommandSpecs`, `CompoundSpecs` constructors (internal type stability).
- **VibePkg:** ⚪ N/A — those internal spec types do not exist in VibePkg (its command table uses `register!`/`ParsedCommand`); Pkg-internal type-stability assertion, not applicable.

### REPL missing package install hook — line 833
- **Tests:** `try_prompt_pkg_add`: returns false for non-packages, refuses the dummy `julia` entry, and returns false/true based on a "n"/"y" reply to the install prompt when a `using X` names a missing registered package.
- **VibePkg:** ⚪ N/A — VibePkg has no `try_prompt_pkg_add` implementation and does not register a missing-package install hook with Julia's REPL, so this Pkg-specific interactive surface has no equivalent test target.

### JuliaLang/julia #55850 — line 849
- **Tests:** In a fresh subprocess with the default env, `promptf()` prints exactly `(@vMAJOR.MINOR) pkg> `.
- **VibePkg:** ✅ COVERED — `replmode.jl` "REPL prompt (promptf)" starts a fresh Julia subprocess on a fresh first depot, calls no-argument `VibePkg.activate()`, and asserts the exact VibePkg spelling `(@vMAJOR.MINOR) vpkg> `.

### in_repl_mode — line 856
- **Tests:** `in_repl_mode()` is false by default, true inside a running pkg command, and follows the `IN_REPL_MODE` scoped value.
- **VibePkg:** ✅ COVERED — test/public_api.jl "add prefer_loaded_versions" asserts `in_repl_mode()` is false by default and true under `with(IN_REPL_MODE => true)`; execute_commands wraps calls in that scope.

### compat REPL mode — line 882
- **Tests:** Interactive `API._compat` TUI: arrow-key package selection, editing a compat entry (`0.4`) and seeing the re-check output, plus the backspace-on-empty-buffer edge case (#3828) not throwing BoundsError.
- **VibePkg:** ⚪ N/A — VibePkg's `compat` is argument-based only (`compat [pkg] [version]`, `--current`; parse tested in replmode, ops covered in options.jl); it has no interactive arrow-key compat editor, so there is no equivalent surface to test.


## test/api.jl  (Pkg.jl)
Programmatic API surface: activate semantics, the big precompile integration suite, PackageSpec/uuid shapes, arg validation, and a handful of config/env knobs — VibePkg covers the pure-argument surface well but has almost no coverage of precompilation behavior, the julia-compat/yanked-resolve error paths, or the loaded-module-mismatch warning.

### Pkg.activate — line 12
- **Tests:** Exercises `activate` path resolution end-to-end: relative `"."`, activating a path dir over a same-named dep, activating a developed dep by name, empty-dir implicit projects, a registered (non-deved) dep name resolving to a fresh dir, resolving a dev'd dep by name from a different cwd, and no-arg `activate()` clearing `ACTIVE_PROJECT` to the LOAD_PATH project.
- **VibePkg:** 🟡 PARTIAL — `doc_features.jl` "activate - and activate(dep name)" + `public_api.jl` "activate prev" cover path activation, `-`/prev toggling, dev-name→path, and non-dep-name→new-path; the no-arg `activate()` → `ACTIVE_PROJECT===nothing` case is now covered (✔ parity_gaps.jl "activate() with no args clears ACTIVE_PROJECT"). Still open: activating a registered non-dev dep name, and cwd-independent dev-name resolution.

### Pkg.precompile — line 51
- **Tests:** Large integration suite: sequential depth-first precompile of many generated dev deps, `JULIA_PKG_PRECOMPILE_AUTO` auto-precomp triggered by `build`/`add`/`update`, no-op detection on repeat, positional/vector/PackageSpec forms, and a soft-error broken dep. Also a second block asserting circular-dependency detection ("Circular dependency detected") and empty-env no-op.
- **VibePkg:** 🟡 PARTIAL — `public_api.jl` now covers timing, positional/spec forms, actual precompilation, repeat no-op detection, the broken-dep error, trailing output, instantiate-triggered precompilation, hermetic circular-dependency detection, and `JULIA_PKG_PRECOMPILE_AUTO`/global gate behavior plus real auto-precompile triggers after build/add/update (each followed by a manual no-op check, using one local Git package); `subprocess_ops.jl` covers pidlocked precompilation. Still open here: only the full sequential depth-first generated dependency graph.

### timing mode — line 156
- **Tests:** `precompile(timing=true)` prints "Precompiling", per-package elapsed times matching `\d+\.\d+ s`, and the package name.
- **VibePkg:** ✅ COVERED — `public_api.jl` "precompile options" runs a real local package precompile with `timing=true` and asserts the banner, package name, and Julia-version-tolerant elapsed-time format (`ms` or `s`).

### delayed precompilation with do-syntax — line 172
- **Tests:** `Pkg.precompile() do ... end` defers auto-precompilation of add/rm inside the block so precompile runs exactly once at block end.
- **VibePkg:** 🟡 PARTIAL — `public_api.jl` "precompile options" exercises the do-block API and proves `AUTO_PRECOMPILE_ENABLED` is false inside the block and restored afterward. It does not perform add/rm in the block or assert that exactly one precompile occurs at block exit.

### autoprecompilation_enabled global control — line 192
- **Tests:** `Pkg.autoprecompilation_enabled(false/true)` flips the process-global `_autoprecompilation_enabled`, suppressing/enabling auto-precomp on `add`/`rm` independent of the env var; manual `precompile` still works when disabled.
- **VibePkg:** ⚪ N/A — VibePkg has no public `autoprecompilation_enabled` API. `public_api.jl` "auto-precompile triggers and no-op detection" directly exercises the internal `AUTO_PRECOMPILE_ENABLED` gate together with `JULIA_PKG_PRECOMPILE_AUTO`, including real add/build/update triggers, but that is not the upstream public-toggle contract.

### instantiate — line 229
- **Tests:** `Pkg.instantiate` triggers precompilation both with a Project+Manifest and with a Project-only environment ("Precompiling" appears).
- **VibePkg:** ✅ COVERED — `public_api.jl` "instantiate precompiles" removes the local package's compiled cache, runs public `VibePkg.instantiate`, and asserts both the "Precompiling" output and recreated cache.

### waiting for trailing tasks — line 247
- **Tests:** Precompiling a package that spawns trailing stderr IO / background tasks waits for them and surfaces the message ("waiting for IO to finish" / "Waiting for background task…").
- **VibePkg:** ✅ COVERED — `public_api.jl` "precompile behaviors" precompiles a local package that writes "waiting for IO to finish" to stderr and sleeps during compilation, then asserts both the precompile banner and surfaced message.

### pidlocked precompile — line 256
- **Tests:** Two concurrent julia subprocesses precompiling the same slow package: both show "Precompiling" and at least one reports "Being precompiled by another process (pid: …)".
- **VibePkg:** ✅ COVERED — `subprocess_ops.jl` "pidlocked precompile" runs two fresh Julia processes against one local slow package/shared depot and asserts the combined output contains both "Precompiling" and "Being precompiled by another process".

### Pkg.API.check_package_name — line 345
- **Tests:** `check_package_name("Example.jl")` throws the pinned "not a valid package name. Perhaps you meant `Example`" error.
- **VibePkg:** ✅ COVERED — `argshapes.jl` "pinned entry diagnostics" (line 106) asserts the exact same message.

### issue #2587: PackageSpec uuid accepts Union{UUID,AbstractString,Nothing} — line 349
- **Tests:** `PackageSpec(uuid=…)` normalizes `Base.UUID(0)`, a UUID object, a UUID string, and a `SubString` all to the same `Base.UUID`; and `PackageSpec()` / `uuid=nothing` leave `uuid===nothing`.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "PackageSpec uuid normalization" exercises UUID-object, UUID-string, `SubString`, and `UUID(0)` all normalizing to the same `UUID`, plus default/`nothing`.

### set number of concurrent requests — line 376
- **Tests:** `Types.num_concurrent_downloads()` defaults to 8, honors `JULIA_PKG_CONCURRENT_DOWNLOADS=5`, and throws on `0`.
- **VibePkg:** ✅ COVERED — `misc.jl` "concurrent-download config" asserts default 8, environment override 5, and `PkgError` for both zero and non-integer values; the parity work also changed the old clamp-to-one behavior to reject invalid values.

### `[compat]` entries for `julia` — line 386
- **Tests:** `add`ing a path package whose `[compat] julia` excludes the running Julia (FarFuture / FarPast fixtures) throws "julia version requirement for package".
- **VibePkg:** ✅ COVERED — `ops.jl` "path package with incompatible [compat] julia errors" drives both far-future and far-past local packages through `plan_develop` and asserts the `PkgError` names the Julia-version requirement.

### allow_reresolve parameter — line 397
- **Tests:** `Pkg.build` and `Pkg.test` with `allow_reresolve=true` succeed against a manifest broken by a yanked version (re-resolving), and both throw `ResolverError` with `allow_reresolve=false`.
- **VibePkg:** 🟡 PARTIAL — ✔ `public_api.jl` "test op: allow_reresolve recovers a yanked manifest version" now drives the public `VibePkg.test` sandbox against a checked-in manifest containing a yanked Example 0.5.1: `allow_reresolve=false` propagates `ResolverError`, while `true` prints both fallback markers, installs the surviving 0.5.0 tree from `LocalPkgServer`, and the real test subprocess proves that version loaded. The remaining gap is a precise API/architecture divergence in `build`: `API.build` accepts only `verbose`/`io` (no `allow_reresolve`), and `BuildOps.run_build` merely slices the existing manifest into its sandbox without a resolve/re-resolve stage, so neither upstream build branch can currently be exercised.

### Yanked package handling / status shows yanked packages — line 428/436
- **Tests:** `status` of an env pinned at a yanked version prints "vX [yanked]" and the "Package versions marked with [yanked] have been pulled from their registry." legend.
- **VibePkg:** ✅ COVERED — `pins.jl` "status pins (round 3)" (lines 135-136) asserts the `[yanked]` marker and the legend line.

### Yanked package handling / resolve error shows yanked packages warning — line 444
- **Tests:** `add` that conflicts with a yanked package throws `ResolverError` and prints "The following package versions were yanked from their registry and are not resolvable:" plus the "Name [uuid] version" line.
- **VibePkg:** ✅ COVERED — `ops.jl` "yanked versions named in a failed resolve" builds a yanked manifest fixture, forces an unsatisfiable add, asserts `ResolverError`, and pins the full warning header plus the exact `- Example [7876af07] 1.0.0` UUID/version detail line.

### Pkg.activate warns on loaded module mismatch (path mismatch / re-activate / suppressed) — lines 457, 528, 542, 555
- **Tests:** Via subprocesses: activating env B after loading a package from env A whose path differs warns "Some loaded packages differ"; re-activating the same env does not warn; and the warning is suppressed on repeated activation of an already-warned env.
- **VibePkg:** ⚪ N/A — VibePkg does not emit an activate-time "Some loaded packages differ" warning or track already-warned environments. Its separate loaded-version status annotation is covered by `subprocess_ops.jl` "status shows loaded-version mismatch".

### Pkg.API._depot_package_slug — line 573
- **Tests:** Internal helper that extracts the 8-char slug from a `…/packages/Foo/<slug>/src/Foo.jl` depot path and returns `nothing` for non-depot paths.
- **VibePkg:** ⚪ N/A — Pkg-internal path-parsing helper with no VibePkg equivalent; VibePkg resolves install trees via `Base.version_slug` / `Depots.jl` instead.


## test/registry.jl  (Pkg.jl)
Registry lifecycle (add/rm/update/status across REPL + API, multi-depot, multi-registry), bootstrapping, deprecated/yanked packages, compressed pkg-server registries, and gc-on-registries; VibePkg covers the bulk in test/registry_ops.jl + test/registries.jl but omits a few edge behaviors.

### `registries` — add/rm/update General via REPL & API — line 108
- **Tests:** `registry add/up/rm General` (by name, uuid, name=uuid, and no-arg) via the Pkg REPL and via `Registry.add/update/rm` with every `RegistrySpec` spelling; after each round-trip the registry is installed/uninstalled and `Example` becomes available/unavailable.
- **VibePkg:** ✅ COVERED — `registry_ops.jl` "registry lifecycle identity spellings" runs 64 assertions against a fully local Git default registry. Both the public `Registry.add/update/rm` facade and the executed REPL driver complete add/update/remove round trips by name, bare uuid, and `name=uuid`; each targeted update fetches a newly committed registry version, and both no-argument add forms bootstrap the configured default. Installation/removal is checked through `reachable_registries`, including registry UUID and `Example` availability. "registry update preserves UUID identity" additionally installs two local Git registries with the same declared name and proves bare-UUID and `name=uuid` updates advance only the selected identity. ⚪ N/A facet: VibePkg intentionally has a variadic-string registry facade and no `RegistrySpec` type, object/vector overloads, or `RegistrySpec(name/path/uuid)` constructor matrix; local path/url sources are the equivalent supported string forms and are covered separately below.

### `registries` — add from URL/local path, two depots — line 149
- **Tests:** `registry add <url>` from a local path installs into depot1; a second registry added while depot2 is primary lands there; both are reachable and their `Example1`/`Example2` become available; repeated for the `Registry.add(url=…)` API.
- **VibePkg:** ✅ COVERED — `registry_ops.jl` "registries land in the first depot of the stack" (source add targets depots1, depot2 untouched, reachable) and `registries.jl` "git-backed registries" (add_registry_from_source! from a path/git repo, reachable, queryable).

### `registries` — update/rm cycling by uuid, name=uuid, multi-depot — line 172
- **Tests:** `registry up/rm` targeting a registry by uuid, `name=uuid`, and bare name across two depots (using `with_depot2`), re-adding and re-removing, asserting installed set and package availability after each step.
- **VibePkg:** ✅ COVERED — ✔ `parity_gaps.jl` "registry rm/update by uuid and name=uuid" drives the low-level removal selectors (and the not-found no-op), while `registry_ops.jl` "registry lifecycle identity spellings" drives public and REPL updates/removals by bare uuid and `name=uuid`, proving targeted Git updates become visible. "registry update preserves UUID identity" proves those selectors remain UUID-aware below the facade even when two installed registries share a declared name. Registry operations target the primary depot; the underlying primary-depot behavior and explicit two-depot reachability are covered by "registries land in the first depot of the stack" and `registries.jl` "identical registry in two depots".

### `registries` — multiple registries in one command — line 221
- **Tests:** `registry add General <url>` (several registries in a single call), `registry up A B C`, `registry rm A B`, and the list-form `Registry.add([...])` / `Registry.update([...])` / `Registry.rm([...])`; asserts combined installed set.
- **VibePkg:** ✅ COVERED — `registry_ops.jl` "add/update/rm multiple registries in one call" drives two fully local Git registries through one variadic call for each public API operation, publishes distinct commits to both, and proves one `Registry.update("RegOne", "RegTwo")` advances both. It then executes combined `registry add`, `registry up`, and `registry rm` commands through the real REPL driver and verifies both registries at every stage. ⚪ N/A facet: VibePkg intentionally exposes variadic string arguments rather than Pkg's `RegistrySpec` type/vector overloads, so there is no list-form API to exercise.

### `registries` — same-name different-uuid add conflicts — line 270
- **Tests:** After adding RegistryFoo1, adding RegistryFoo2 (same name, different uuid) throws `PkgError`, via both REPL and `Registry.add([...])`.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "same-name different-uuid registry conflict" adds two same-name/different-uuid source registries and asserts the second `add_registry_from_source!` throws PkgError "conflicts with existing registry", leaving the first intact.

### `registries` — issue #711: identical registry in two depots, then `add` — line 279
- **Tests:** Adding General into two depots, then `Pkg.add("Example")` must not error because both depots hold the same-uuid `Example`.
- **VibePkg:** ✅ COVERED — `registries.jl` "identical registry in two depots" (both instances discovered, name lookup dedups by uuid, `plan_add("Example")` resolves cleanly).

### `registries` — add/update with explicit `depots` kwarg — line 291
- **Tests:** `Registry.add("General"; depots=off_path)` installs into a depot that is not on `DEPOT_PATH`; `reachable_registries(; depots=…)` sees it while the default does not; `Registry.update(; depots, io, update_cooldown)` runs and prints the depot path; the off-path depot can then install `Example`.
- **VibePkg:** 🟡 PARTIAL — `add_default_registries!(depots)` and `reachable_registries(depots)`/`update_registries!(depots)` are pervasively driven with explicit depot stacks (registry_ops, registries), so the off-path depot mechanism is well exercised. Missing: the public `Registry.add/update` API `depots=` keyword surface, the `update_cooldown` kwarg, and the "registry at `<path>`" update-output assertion.

### `registries` — Registry.status output — line 322
- **Tests:** `Registry.status(buf)` on installed General contains `[23338594] General (…General.git)` and `last updated`.
- **VibePkg:** ✅ COVERED — `registry_ops.jl` "registry status / rm / add-by-name" asserts `Registry Status`, `[23338594]`, ` General`, `packed registry with hash`, `served by …`, offline suppression, and eager-flavor surfacing (richer than Pkg's).

### `registries` — only clone default registry when none installed — line 332
- **Tests:** With two empty depots, `Pkg.add("Example")` triggers exactly one default-registry clone; after `rm` and swapping depots, a second `add` does not re-clone.
- **VibePkg:** ✅ COVERED — `registry_ops.jl` "registry auto-update runs once per session" and "instantiate never updates registries" verify bootstrap-on-first-op and the once-per-session gate; "JULIA_PKG_SERVER=\"\" bootstraps default registries over git" asserts idempotent bootstrap (`add_default_registries!` returns empty when already installed).

### `registries` > `deprecated package` — line 346
- **Tests:** A registry package with `[metadata.deprecated]` is loaded so `isdeprecated(pkg_info)` is true and `pkg_info.deprecated["reason"]/["alternative"]` are read; a normal package is not deprecated; `get_pkg_deprecation_info(spec, registries)` returns the table for the deprecated pkg and `nothing` for the normal one.
- **VibePkg:** ✅ COVERED — `registries.jl` "Registries" (`!isdeprecated(info)`); `src/Registries.jl` `isdeprecated`/`deprecation_info`; `options.jl` "status --deprecated" and `replmode.jl` (deprecated completions filtered) exercise `[metadata.deprecated]` reason/alternative end to end. `deprecation_info` is the analog of `get_pkg_deprecation_info`.

### `registries` > `yanking` — line 429
- **Tests:** Against the JuliaRegistries/Test registry: `add Example` resolves to 0.5.0 (0.5.1 yanked), `update` won't move it, `add Example@0.5.1` throws `ResolverError`, `JSON` (dep on Example) also pins 0.5.0; a manifest already at yanked 0.5.1 is honored by `instantiate` (standalone and as a transitive dep).
- **VibePkg:** 🟡 PARTIAL — `registries.jl` (`isyanked`), `planning.jl` "yanked 1.0.0 is skipped", `ops.jl` (free returns to latest non-yanked), and `execution.jl` "instantiate at a yanked version" cover most; the explicit-request case is now covered (✔ parity_gaps.jl "requesting a yanked version errors" → ResolverError). Still open: that `update` leaves a yanked-pinned package put.

### `compressed registry` (pkg-server) — line 496
- **Tests:** With a real pkg server, for `JULIA_PKG_UNPACK_REGISTRY` = true and unset: adding General leaves a `.tar.gz`/`.tar.zst` tarball iff not unpacked; `Pkg.add("Example")` works; corrupting the recorded tree-sha1 (in `.tree_info.toml` or `General.toml`) forces `Pkg.update` to re-fetch; `Registry.rm` leaves the registries dir empty save `CACHEDIR.TAG`.
- **VibePkg:** ✅ COVERED — `registry_ops.jl` "registries land in the first depot" and "JULIA_PKG_UNPACK_REGISTRY installs server registries unpacked" cover packed/unpacked installation and add-Example. ✔ `registry_ops.jl` "corrupt server-registry tree hash forces refresh" now corrupts `General.toml` / `.tree_info.toml` across both install forms, proves update re-fetches and restores the server hash while the registry remains queryable, accepts gzip/zstd archive shapes, and proves removal leaves only `CACHEDIR.TAG` (fully local `LocalPkgServer`).

### `gc runs git gc on registries` — line 538
- **Tests:** A git-repo registry copied into the depot; `Pkg.gc(verbose=false)` runs `git gc` on it `@test_nowarn` and leaves the registry and its `.git` dir intact.
- **VibePkg:** ✅ COVERED — `gc.jl` "gc runs git gc on registries" creates and commits a fully local Git-backed registry, calls public `API.gc` without warnings, verifies the registry and `.git` repository remain valid, and proves maintenance ran by observing loose objects compacted into pack/index files.


## test/manifests.jl  (Pkg.jl)
Exercises Manifest.toml format versions (v1/v2.0/v2.1/unknown), julia_version metadata and staleness detection, `update_on_mismatch` instantiate fallback, and registry-tracking in the manifest; VibePkg covers the pure read/write/round-trip data model well but is thin on the activation/instantiate integration flows.

### Manifest.toml formats — line 36
- **Tests:** Umbrella grouping the format-version cases: reading v1/v2.0/v2.1/unknown reference manifests, upgrading on write, and preserving unknown fields.
- **VibePkg:** 🟡 PARTIAL — format read/write/round-trip and unknown-format warning are covered by envfiles.jl "manifest formats", "manifest [registries] round trip", and "unknown manifest format warns"; op-driven v1/v2.0 upgrades are covered in ops.jl. Remaining here is only a single activation-style fixture spanning the umbrella cases.

### Default manifest format is v2.1 — line 37
- **Tests:** A fresh temp environment `add`ing a package writes a non-v1 manifest whose `manifest_format` is exactly v2.1.0.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "fresh add writes manifest_format v2.1" asserts a fresh `plan_add` yields `manifest_format == v"2.1.0"` in memory and on disk (written `"2.1"`, re-read `v"2.1.0"`).

### Empty manifest file is automatically upgraded to v2 — line 50
- **Tests:** An empty Manifest.toml reads as v1 semantically but is treated as v2.0.0; after an `add` it becomes v2.1; a Project-with-deps plus empty manifest doesn't error.
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest formats": an empty manifest file reads as `manifest_format == v"2.0.0"` (line 397-401). (The subsequent add→2.1 upgrade is not separately asserted.)

### v1.0: activate and read, upgrade on write — line 79
- **Tests:** Activating a v1.0 reference env reads the v1 format; then `add`/`rm` operations rewrite it upgraded to v2.1.
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest formats" reads the v1.0 fixture and confirms plain write stays v1 without v2 metadata (lines 390-393); ✔ ops.jl "op-driven manifest upgrade to format 2.1" drives the operation-driven upgrade: activating a v1.0 manifest then `add` re-stamps it to 2.1 on disk and reload. (Divergence: a bare `rm` prunes in place and does not itself upgrade the format.)

### v2.0: activate and read, upgrade on write — line 99
- **Tests:** Reads v2.0 format, upgrades to 2.1 on add/rm, preserves arbitrary `other` fields through write→read, and (second block) checks `check_manifest_julia_version_compat` warns / throws-when-strict on a mismatched or missing julia_version.
- **VibePkg:** ✅ COVERED — v2.0 read + round-trip incl. preserved raw fields is covered (envfiles.jl "manifest read + round trip", "manifest metadata"); the julia_version-compat warning is exercised (envfiles.jl "manifest julia_version compatibility") and ✔ ops.jl "op-driven manifest upgrade to format 2.1" asserts the op-driven v2.0→2.1 upgrade on `add`.

### v2.1: activate, change, maintain manifest format with registries — line 143
- **Tests:** v2.1 manifest carries a `[registries]` section (uuid/url) and per-package `registries` field; round-trips through write/read preserving deps/julia_version/format/other/registries; add keeps format ≥2.1.
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest [registries] round trip" covers the registries section (uuid, optional url, round-trip equality, format forced to 2.1) and "manifest entry states" covers the per-entry `registries` field; plan-level tracking asserted in planning.jl:46. (No activation-flow / add-preserves-2.1 op test.)

### v3.0: unknown format, warn — line 190
- **Tests:** Activating an env whose manifest declares an unknown (v3) format emits a warning.
- **VibePkg:** ✅ COVERED — `envfiles.jl` "unknown manifest format warns" parses a v3 manifest through the IO path, asserts the warning, and proves the manifest entry remains readable.

### Manifest metadata — line 200
- **Tests:** Umbrella grouping julia_version handling, syntax version, and update_on_mismatch behavior.
- **VibePkg:** 🟡 PARTIAL — see child items; data-model pieces covered, instantiate/compat integration flows largely missing.

### julia_version — line 201
- **Tests:** Umbrella for dropbuild, new-env value, old-env preservation, cross-version instantiate, and project_hash staleness.
- **VibePkg:** 🟡 PARTIAL — see child items.

### dropbuild — line 202
- **Tests:** `Pkg.Operations.dropbuild` strips the DEV build number (`1.2.3-DEV.2134`→`1.2.3-DEV`) while leaving plain/rc versions intact.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "dropbuild" asserts the four input forms (`1.2.3-DEV.2134`→`1.2.3-DEV`; `-DEV`/plain/`-rc1` unchanged).

### new environment: value is `nothing`, then ~`VERSION` after resolve — line 208
- **Tests:** A brand-new temp env has `manifest.julia_version === nothing`; after `add` it becomes `dropbuild(VERSION)`.
- **VibePkg:** ✅ COVERED — planning.jl: fresh env manifest is empty (line 37) and after `plan_add` `manifest.julia_version == Planning.dropbuild(VERSION)` (line 51).

### activating old environment: maintains old version, then ~`VERSION` after resolve — line 216
- **Tests:** Activating a v2.0 reference env keeps its recorded `julia_version` (1.7.0-DEV); a subsequent `add` flips it to `dropbuild(VERSION)`.
- **VibePkg:** ✅ COVERED — ✔ ops.jl "activating old env keeps julia_version, add flips it" loads a v2.0 reference env, asserts the recorded `julia_version` (1.7.0-DEV) is preserved on read, then confirms `add` flips it to `dropbuild(VERSION)`.

### instantiate manifest from different julia_version — line 225
- **Tests:** `instantiate` on a v1/v2 manifest resolved by a different julia version warns ("The active manifest file...") and leaves/normalizes the recorded julia_version.
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest julia_version compatibility" covers the read-time compat warn/throw; ✔ ops.jl "update_on_mismatch: julia minor version mismatch" drives `instantiate` on a cross-julia-version manifest and asserts the warn + stale-preservation (and the `update_on_mismatch=true` fallback that normalizes it).

### project_hash for identifying out of sync manifest — line 239
- **Tests:** `is_manifest_current` flips false after `compat` change; `status` prints the "dependencies or compat requirements have changed since the manifest was last resolved" message; `instantiate` warns; `update` restores current; `rm` also restores current.
- **VibePkg:** 🟡 PARTIAL — `manifest_matches_project` / `is_manifest_current` are unit-tested; the end-to-end compat-change→predicate-flip is now covered (✔ parity_gaps.jl "stale manifest predicate flips (status stays silent)"). Divergence: VibePkg's `status`/`print_status` emit NO out-of-sync message (the test pins its absence). Still open: the instantiate-time stale warning.

### syntax julia_version — line 271
- **Tests:** Umbrella for the project `[syntax] julia_version` handling.
- **VibePkg:** 🟡 PARTIAL — see child.

### dropbuild applied: dev build number dropped — line 272
- **Tests:** `get_project_syntax_version(Project())` defaults to `dropbuild(VERSION)` so `[syntax].julia_version` avoids DEV-build churn.
- **VibePkg:** 🟡 PARTIAL — VibePkg parses/round-trips `julia_syntax_version` (src/EnvFiles.jl:584-585, 659) and preserves it on resolve (Planning.jl:946), but there is no `get_project_syntax_version` default-to-dropbuild helper and no test.

### update_on_mismatch — line 279
- **Tests:** Umbrella for `instantiate(update_on_mismatch=true)` fallback-to-update behavior.
- **VibePkg:** 🟡 PARTIAL — the flag is wired (API.jl:836, REPLMode) and `manifest_matches_project` is unit-tested, but the fallback integration is untested; see children.

### manifest from a different julia minor version — line 280
- **Tests:** Without the flag, `instantiate` warns and keeps the stale v2.0 manifest (julia 1.7.0-DEV); with `update_on_mismatch=true` it falls back to `update` and regenerates for the current julia version.
- **VibePkg:** ✅ COVERED — ✔ ops.jl "update_on_mismatch: julia minor version mismatch": default `instantiate` warns and keeps the stale manifest; `update_on_mismatch=true` falls back to `up` and regenerates for the current julia version.

### manifest stale due to compat change — line 298
- **Tests:** After a `compat` change, default `instantiate` just warns and stays stale; `update_on_mismatch=true` falls back to update so the manifest becomes current.
- **VibePkg:** ✅ COVERED — `manifest_matches_project` detects the stale state (options.jl:220); ✔ ops.jl "update_on_mismatch: stale due to compat change" drives the full flow: a conflicting `compat` leaves the resolved version in place but stale, default `instantiate` warns and stays stale, and `update_on_mismatch=true` re-resolves down to the only compatible version and becomes current.

### no mismatch: update_on_mismatch=true is a no-op — line 322
- **Tests:** When the manifest already matches, `instantiate(update_on_mismatch=true)` changes nothing and keeps installed versions.
- **VibePkg:** ✅ COVERED — ✔ ops.jl "update_on_mismatch: no-op when already current": with a matching manifest, `instantiate(update_on_mismatch=true)` changes nothing and keeps the installed version.

### undo reverts the fallback even as first op — line 334
- **Tests:** If `instantiate(update_on_mismatch=true)` is the first op in a fresh session and triggers the fallback, the pre-update snapshot is saved so `Pkg.undo` restores the earlier version.
- **VibePkg:** ✅ COVERED — undo/redo stack mechanics are unit-tested (argshapes.jl:46-64); ✔ ops.jl "undo reverts the update_on_mismatch fallback as first op" clears the undo stacks to simulate a fresh session, triggers the fallback as the first op, and asserts `undo` restores the pre-update version.

### Manifest registry tracking — line 360
- **Tests:** Umbrella for recording registry provenance (format 2.1, `[registries]` section, per-package `registries` field) in the manifest.
- **VibePkg:** ✅ COVERED — data-model recording and multi-registry provenance are covered; `registry_ops.jl` "instantiate installs non-default registry from manifest" additionally proves the public instantiate path installs a missing custom registry from its recorded local-git URL and immediately uses the refreshed registry snapshot to materialize its package.

### Manifest format upgraded to 2.1 when registries tracked — line 361
- **Tests:** After `add`ing a registered package, `manifest_format ≥ 2.1`, the `[registries]` section holds General, and the package entry lists "General".
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest [registries] round trip" forces format 2.1 when registries present (lines 374-375); "manifest entry states" writes the per-entry registries field (lines 240-242); plan tracking asserted in planning.jl:46.

### Registries written and read from manifest — line 382
- **Tests:** The written TOML has a `registries.General` table (uuid/url) and package entries carry a `registries`/`registry` field; reading back via the API repopulates `manifest.registries` and per-entry registries.
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest [registries] round trip" verifies the TOML structure (uuid/url) and read-back equality; "manifest entry states" verifies the per-entry registries field render.

### Instantiate with non-default registry from manifest — line 417
- **Tests:** With a custom registry recorded in a manifest's `[registries]` section but not installed locally, `instantiate` auto-installs that registry into the depot.
- **VibePkg:** ✅ COVERED — `registry_ops.jl` "instantiate installs non-default registry from manifest" starts with an unrelated sentinel registry in a fresh depot, records an absent custom registry's local-git URL in Manifest.toml, and proves public `instantiate` installs that registry and its registered package without network access. `API.ensure_manifest_registries!` refreshes the operation registry snapshot after installation and follows Pkg's best-effort warning behavior when installation fails.

### Non-registry packages do not have registry field — line 530
- **Tests:** `develop`ed and url-`add`ed packages have empty `registries`; manifest format is still 2.1 with an empty `[registries]` section.
- **VibePkg:** ✅ COVERED — envfiles.jl "manifest entry states" confirms PathTracked/RepoTracked entries write no `registries` key (lines 244-248) and "manifest [registries] round trip" confirms an empty registries section is omitted (lines 377-379). (No develop/add-url integration path.)

### Package in multiple registries records all — line 599
- **Tests:** A package present in two registries records both names in its entry's `registries` array and both registries in the manifest's `[registries]` section, round-tripping through TOML as a 2-element array.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "package in two registries records both" resolves Example present in two registries and asserts `entry_registries(entry)` lists both names (2-element) plus both in the manifest `[registries]` section.


## test/resolve.jl  (Pkg.jl)

### VersionWeight ordering preamble — line 18
- **Tests:** For every pair in a version list, asserts `VersionWeight(v)` preserves the `<` and `==` ordering of the underlying `VersionNumber`, i.e. the resolver's internal weight type is order-isomorphic to versions.
- **VibePkg:** ✅ COVERED — `resolve.jl` "VersionWeight ordering matches VersionNumber" checks every pair in a version list (including all upstream cases plus extra boundary versions) for identical `<` and `==` results; "VersionWeight rank distinguishes prerelease/build metadata" additionally proves ranked weights preserve ordering when major/minor/patch alone would collapse distinct versions.

### schemes — line 40
> ✔ Now fully ported → test/resolve.jl "schemes" (all 15 hand-built graphs, 72 assertions) plus the ported sanity_check/resolve helpers.
- **Tests:** 15 hand-built dependency schemes (DAG, cyclic, mutually-exclusive solutions, trivial/implicit/total inconsistency, weak deps, unconnected components, local-optimum graph #3232, weak-dep graph #4030). Each runs `sanity_tst` (per-package unsatisfiability detection) and `resolve_tst` asserting the exact version set chosen, plus `@test_throws ResolverError` on unsatisfiable requirements.
- **VibePkg:** ✅ COVERED — ✔ `test/resolve.jl` "schemes" ports all 15 hand-built graphs + `sanity_check`/`sanity_tst`/`resolve_tst` (72/72 green): the DAG/cyclic/mutually-exclusive/inconsistency/local-optimum-#3232/weak-#4030/multi-req-cascade schemes all assert the exact chosen version set and `@test_throws ResolverError` on the unsatisfiable ones, with no divergence from Pkg's solutions. (The earlier "Resolve" single-graph testset remains as extra coverage.)

### realistic — line 705
- **Tests:** Unpacks `resolvedata.tar.gz` and runs four large real-world graphs (Julia #21485, Pkg #1949/#3232/#3878) through `sanity_tst`/`resolve_tst`; the last also asserts resolver time-limit behavior via `JULIA_PKG_RESOLVE_MAX_TIME` (`ResolverError` at 10s, `ResolverTimeoutError` at 1e-5s with `validate_versions=false`).
- **VibePkg:** ✅ COVERED — `resolve.jl` "realistic" unpacks `resolvedata.tar.gz`, ports all four reference graphs through `sanity_tst`/`resolve_tst`, and asserts both the 10-second `ResolverError` path and the tiny-budget `ResolverTimeoutError` path with `validate_versions=false`.

### nasty — line 754
- **Tests:** Uses `NastyGenerator.generate_nasty` to build adversarial graphs (satisfiable and unsatisfiable) and checks `sanity_tst` + `resolve_tst` on the sat case and `@test_throws ResolverError` on the unsat case — a randomized/generated stress test of resolver correctness.
- **VibePkg:** ✅ COVERED — `resolve.jl` "nasty" uses the ported `NastyGenerator.jl` to generate the satisfiable and unsatisfiable adversarial graphs, runs `sanity_tst` on both, resolves the satisfiable case, and asserts `ResolverError` for the unsatisfiable case.

### Stdlib resolve smoketest — line 770
- **Tests:** In an isolated temp project, adds every stdlib (`Pkg.Types.load_stdlib()`) and runs `Pkg.resolve`, asserting the output reports no changes to Project.toml/Manifest.toml — i.e. all stdlibs are jointly installable and resolve is a no-op.
- **VibePkg:** ✅ COVERED — `depots_stdlibs.jl` "all stdlibs resolve" writes every `Stdlibs.load_stdlib()` entry into one isolated project's `[deps]`, resolves the full set jointly, asserts every stdlib and no extra entry is present, writes it, and proves a second resolve is idempotent.

## test/resolve_utils.jl  (Pkg.jl)

### ResolveUtils support module — (infra)
- **Tests:** Not a testset. Provides `graph_from_data` (builds a `Resolve.Graph` from `["Pkg", v, "Dep", spec, :weak?]` rows), `reqs_from_data`, `sanity_tst`, and `resolve_tst` helpers used by resolve.jl.
- **VibePkg:** ⚪ N/A — test harness. VibePkg builds `Resolve.Graph` inline in `test/resolve.jl` rather than via an equivalent helper; no separate util needed.

## test/force_latest_compatible_version.jl  (Pkg.jl)

### get_earliest_backwards_compatible_version — line 32
- **Tests:** `Pkg.Operations.get_earliest_backwards_compatible_version` maps a version to its backwards-compat floor: `1.2.3→1.0.0`, `0.2.3→0.2.0`, `0.0.3→0.0.3` (semver: floor at the leading non-zero component).
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "test: force_latest_compat backwards-compat floor" drives `force_latest_compat(...; allow_earlier=true)` over 1.2.3/0.2.3/0.0.3 and asserts the compat floors at 1.0.0/0.2.0/0.0.3.

### OldOnly1 (`SomePkg = "=0.1.0"`) — line 39
- **Tests:** End-to-end `Pkg.test` on a package pinned to a single old version: succeeds (returns `nothing`) for every combination of `force_latest_compatible_version` ∈ {false,true} × `allow_earlier_backwards_compatible_versions` ∈ {default,false,true} — the forced-latest mode is a no-op when only one version is allowed.
- **VibePkg:** ✅ COVERED — `force_latest.jl` "OldOnly1 (=0.1.0): always succeeds" runs public `VibePkg.test` end to end for both force-latest values crossed with omitted/default, explicit-false, and explicit-true `allow_earlier`, and all six calls return `nothing`.

### OldOnly2 (`SomePkg = "0.1"`) — line 72
- **Tests:** End-to-end `Pkg.test`: with default `allow_earlier` it always succeeds; with `allow_earlier=false`, `force_latest=true` throws `ResolverError` ("Unsatisfiable requirements detected") because it forces the newest 0.1.x while the package can only load an older one; with `allow_earlier=true` it succeeds again.
- **VibePkg:** ✅ COVERED — `force_latest.jl` "OldOnly2 (0.1): forcing the newest 0.1.x is unsatisfiable" runs the full six-call public-API matrix against the hermetic registry: both omitted/default calls and both explicit-true calls succeed, explicit-false succeeds without forcing, and the forced-latest explicit-false call raises `ResolverError` containing the precise `Unsatisfiable requirements detected for package` diagnostic.

### BothOldAndNew (`SomePkg = "0.1, 0.2"`) — line 132
- **Tests:** End-to-end `Pkg.test`: `force_latest=false` succeeds; `force_latest=true` (any `allow_earlier`) throws `ResolverError` with "Unsatisfiable requirements detected" because forcing the newest allowed (0.2) breaks the package.
- **VibePkg:** ✅ COVERED — `force_latest.jl` "BothOldAndNew (0.1, 0.2): forcing the newest throws" runs omitted/default, explicit-false, and explicit-true `allow_earlier` with both force-latest values: all three non-forced calls succeed and all three forced calls raise `ResolverError` containing the precise `Unsatisfiable requirements detected for package` diagnostic.

### NewOnly (`SomePkg = "0.2"`) — line 197
- **Tests:** End-to-end `Pkg.test` throws `ResolverError` ("Unsatisfiable requirements detected") for every force_latest/allow_earlier combination — the package's compat admits only a version it cannot actually use.
- **VibePkg:** ✅ COVERED — `force_latest.jl` "NewOnly (0.2): always unsatisfiable" crosses both force-latest values with omitted/default, explicit-false, and explicit-true `allow_earlier`; all six public calls raise `ResolverError` containing the precise `Unsatisfiable requirements detected for package` diagnostic.

### DirectDepWithoutCompatEntry — line 253
- **Tests:** Against a pinned General-registry commit, a direct dep with no `[compat]` entry: `force_latest=false` succeeds silently; `force_latest=true` succeeds but emits a `:warn` matching "Dependency does not have a [compat] entry" (via `@test_logs`), for all `allow_earlier` values.
- **VibePkg:** ⚪ N/A — VibePkg deliberately treats a missing dependency compat as an unbounded `VersionSpec()` and exposes no "Dependency does not have a [compat] entry" warning, so the upstream warning contract is absent rather than merely untested.


## test/artifacts.jl  (Pkg.jl)
Exercises the whole Artifacts system — hashing, Artifacts.toml binding/query, lazy/download install, platform selection, overrides, gc, archival, and pkg-server auth; VibePkg covers most install/selection/auth behavior in test/artifacts.jl + test/doc_features.jl but lacks archival, known-hash vectors, file-permission checks, and the Artifacts.toml-search/bad-parse utilities.

### Artifact Creation — line 30
- **Tests:** Creates 4 artifacts (empty, single file, multi-file, nested dirs with empty dirs + symlinks), asserts each hashes to a hard-coded git-tree-sha1, sits under `artifacts/<hash>`, and passes `artifact_exists`/`verify_artifact`.
- **VibePkg:** ✅ COVERED — `create_artifact`/`verify_artifact`/content-addressed dedup covered (doc_features.jl "artifact creation API"); ✔ artifacts.jl "Artifact Creation known-hash vectors" asserts the empty/single-file/multi-file/nested-dirs+empty-dirs+symlinks artifacts against their fixed git-tree-sha1s (symlinks hashed not followed, empty dirs don't affect the hash), each landing under `artifacts/<hash>` and passing `artifact_exists`/`verify_artifact`.

### Artifact Creation → File permissions — line 126
- **Tests:** After `create_artifact`, files (incl. file-symlinks) are read-only while directories (incl. dir-symlinks) stay writable, and the tree can be `rm`'d without manual chmod.
- **VibePkg:** ✅ COVERED — artifacts.jl "Artifact Creation file permissions" checks the `create_artifact` result directly: regular files and file-symlinks are read-only, directories and directory-symlinks remain writable/traversable, and the tree is removed recursively without a preparatory chmod. (The earlier "ArtifactOps" assertions separately cover installed archive permissions and executable-bit preservation.)

### with_artifacts_directory() — line 157
- **Tests:** `with_artifacts_directory` redirects where created artifacts land (`artifact_path` starts with the given dir).
- **VibePkg:** ⚪ N/A — VibePkg has no `with_artifacts_directory`; redirection is done via an explicit `depot_stack`, and that artifacts land in the chosen depot is asserted throughout artifacts.jl (e.g. "ArtifactOps").

### Artifacts.toml Utilities → find/query/install — line 168
- **Tests:** `find_artifacts_toml` walks up from a source file to the right `Artifacts.toml`/`JuliaArtifacts.toml` (incl. sub-module vs sub-package, and none for a plain pkg); `artifact_hash`, `extract_all_hashes`, `ensure_artifact_installed` (idempotent), `verify_artifact`, `remove_artifact`.
- **VibePkg:** ✅ COVERED — `artifact_hash`/`ensure_artifact_installed` (idempotent)/`verify_artifact`/`remove_artifact` covered (artifacts.jl "VibePkg.Artifacts (lazy on demand)"); ✔ artifacts.jl "find_artifacts_toml + hash query utilities" adds the `find_artifacts_toml` search semantics (walk-up, JuliaArtifacts.toml, sub-module vs sub-package, package-boundary→nothing) plus `artifact_hash`/`artifact_meta`, and the `extract_all_hashes` analog (VibePkg's `GCOps.artifact_hashes`, returning hex strings). ⚪ Naming divergence noted (no `extract_all_hashes`).

### Artifacts.toml Utilities → bind/unbind/platform/meta — line 206
- **Tests:** bind, overwrite requires `force`, unbind; platform-specific binding with `download_info` (url/sha256/size), `artifact_hash`/`artifact_meta` per platform, HostPlatform compare-strategy mismatch errors, and relative Artifacts.toml paths.
- **VibePkg:** ✅ COVERED — doc_features.jl "artifact creation API: create/bind/unbind" covers bind, force-required rebind, unbind (per-platform then whole-name, silent no-op), platform-keyed hashes, and lazy+download `download_info` (url/sha256/size). (Relative-path binding and the HostPlatform compare-strategy error case are not exercised — minor gap.)

### Artifacts.toml Utilities → bad Artifacts.toml — line 300
- **Tests:** Parse errors log for missing `git-tree-sha1` and non-table entries; incorrect git-tree-sha1 throws (and with `JULIA_PKG_IGNORE_HASHES` downgrades to a Tree-Hash-Mismatch error + installs at the declared hash); incorrect sha256 throws; missing toml throws.
- **VibePkg:** ✅ COVERED — `JULIA_PKG_IGNORE_HASHES` (throw vs warn-and-install-at-declared-hash) fully covered (artifacts.jl "JULIA_PKG_IGNORE_HASHES"); sha256 + tree-hash mismatch rejection covered (artifacts.jl "download fallback and rejection"); "no download sources" errors covered; ✔ artifacts.jl "bad Artifacts.toml structural parse errors" adds the structural parse-error logging for `no_gitsha` (missing `git-tree-sha1`) and `not_a_table` (scalar entry) via `artifact_meta`.

### Artifact archival — line 339
- **Tests:** `archive_artifact` writes a tarball whose files are listable via `list_tarball_files`; archiving a removed artifact throws.
- **VibePkg:** ⚪ N/A — VibePkg exposes neither `archive_artifact` nor `list_tarball_files`; artifact creation, installation, verification, and removal are covered, but this upstream archival API has no VibePkg test target.

### Artifact Usage → install via test/instantiate + porous platform — line 354
- **Tests:** Runs the ArtifactInstallation package's own test harness + `instantiate`, verifies artifacts install; then with a bogus platform, `select_downloadable_artifacts` skips the non-matching eager artifact, leaves a lazy one uninstalled, and installs a platform-independent one.
- **VibePkg:** ✅ COVERED — artifacts.jl "instantiate installs artifacts" covers a path-tracked package's artifact through the environment instantiate path; "porous platform artifact installation" performs the complete porous matrix in one hermetic pass against a deliberately bogus target: the non-matching eager entry is absent from selection and remains uninstalled, the platform-independent lazy entry is selectable but remains uninstalled, and the platform-independent eager entry alone is installed and verified. All archives are created locally. The upstream `ArtifactInstallation` package's network-backed `Pkg.test` harness is fixture-specific rather than an additional artifact-selection contract and is N/A to this hermetic port.

### Artifact Usage → platform augmentation + cross-install — line 422
- **Tests:** A package's platform-augmentation hook (flooblecrank preference) selects between two artifact variants; loading the package resolves its own artifact; cross-installation installs a variant for a *different* target platform via `add(...; platform)` and `instantiate(; platform)`.
- **VibePkg:** 🟡 PARTIAL — the `.pkg/select_artifacts.jl` hook receiving the platform triplet and driving selection is covered (artifacts.jl "select_artifacts.jl hook"). Missing: preference-driven augmentation (`HostPlatform["flooblecrank"]`) and cross-platform installation via a `platform` kwarg to add/instantiate.

### Artifact GC collect delay — line 565
- **Tests:** Binding writes `artifact_usage.toml`; `gc()` keeps bound artifacts; after unbinding, `gc()` moves to an orphan list and (after delay) deletes; usage-log lifecycle.
- **VibePkg:** 🟡 PARTIAL — artifact gc (usage-log tracking; live artifact kept, unreferenced one deleted) is covered in gc.jl "gc". The *collect-delay / orphan grace period* is deliberately not implemented (GCOps deletes immediately; `collect_delay` is deprecated+warns, tested in gc.jl), so that specific two-phase behavior is N/A by design.

### Override.toml — line 623
- **Tests:** Hash-based overrides resolved across a 3-depot stack (innermost wins), name-based (`UUID.name`) overrides loaded by a real package, later Overrides.toml in an inner depot mutates/clears earlier overrides, and 4 invalid-override forms log specific errors; `load_overrides(; force)` reload.
- **VibePkg:** ✅ COVERED — hash-form and `UUID`/name-form overrides *suppressing downloads* covered (artifacts.jl "ArtifactOps"); ✔ artifacts.jl "Override.toml precedence, resolution and clearing" adds multi-depot precedence (innermost/first depot wins), name-based (`UUID.name`) override resolution via `ArtifactOps.override_for`, clearing an override (`""` removes an outer depot's entry), and the invalid-key handling. ⚪ Divergence: VibePkg's override validation is lenient — it `@warn`s (not `@error`s) on an invalid key and silently tolerates malformed non-UUID entries, rather than logging the specific errors Pkg emits.

### artifacts for non package project — line 800
- **Tests:** A bare (non-package) project directory containing only an `Artifacts.toml`: `Pkg.instantiate()` installs its artifacts.
- **VibePkg:** ✅ COVERED — instantiate-installs-artifacts is covered for a path-tracked *package* carrying Artifacts.toml (artifacts.jl "instantiate installs artifacts"); ✔ artifacts.jl "artifacts for non-package project" adds the bare-project-root case — an env dir with an empty Project.toml and only an Artifacts.toml gets its artifact installed by `instantiate!` and its payload read back.

### installing artifacts when symlinks are copied — line 812
- **Tests:** With `BINARYPROVIDER_COPYDEREF=true` + `JULIA_PKG_IGNORE_HASHES=true`, `download_verify_unpack` dereferences/copies symlinks, producing a different tree hash; instantiate warns Tree-Hash-Mismatch, installs at declared hash, and pre-existing artifacts survive.
- **VibePkg:** ✅ COVERED — symlink tree hashing, including the legacy-symlink-size compatibility path, is covered by artifacts.jl "non-ASCII symlink artifact hash compatibility"/`try_install_from`, while "JULIA_PKG_IGNORE_HASHES" covers install-at-declared-hash after a mismatch. "instantiate installs artifacts" now preinstalls an unrelated local artifact and proves instantiate preserves its exact path, payload, and verified tree hash while installing the referenced artifact. `BINARYPROVIDER_COPYDEREF` itself is an upstream test-only Windows extraction fallback; VibePkg's `Fetch.unpack` preserves symlinks and exposes no copy-dereference mode, so that environment-variable-specific transformation is N/A rather than an untested VibePkg behavior.

### count_artifacts and artifact_suffix — line 838
- **Tests:** `Pkg.Operations.count_artifacts`/`artifact_suffix` status-display helpers: nothing for no Artifacts.toml, `(0,0)` + "(no artifacts on this platform)" for a non-matching platform, and eager/lazy counts for HostPlatform.
- **VibePkg:** ⚪ N/A — Pkg-internal status-display counting helpers; VibePkg has no equivalent `count_artifacts`/`artifact_suffix` (selection is via `collect_artifact_installs`, tested for eager/lazy/platform behavior elsewhere). Not a behavioral gap unless VibePkg adds artifact status output.

### filemode(dir) non-executable on windows — line 879
- **Tests:** Windows-only libuv quirk: a non-empty dir reports `filemode & 0o001 == 0`.
- **VibePkg:** ⚪ N/A — platform-specific libuv regression guard, not a Pkg/VibePkg behavior.


## test/workspaces.jl  (Pkg.jl)

### top-level monorepo workspace block — line 9
- **Tests:** Full monorepo exercise: root `MonorepoSub` with `[workspace] projects` + `[sources]`, a dev'd `PrivatePackage` member that itself nests a `test` subproject, and a root `test` subproject. Asserts members never get their own `Manifest.toml`, `status` vs `status(workspace=true)` shows base-only vs union deps, root compat caps a member's Crayons update, `update()` leaves member-only Chairmarks untouched but `update(workspace=true)` bumps it, `workspace_resolve_hash` agrees from all four member envs, and all subprojects load/run via subprocesses (incl. after deleting the manifest and re-resolving).
- **VibePkg:** 🟡 PARTIAL — VibePkg `workspaces.jl` "workspaces" covers member discovery, shared root manifest, union deps + intersected compat capping Example, `status`/`status(workspace=true)`, `up(workspace=true)` seeding, and `resolve_hash` agreement across members. Missing: nested test-subprojects (a member's own `test/` subproject), `update(workspace=true)` bumping a member-only dep, and end-to-end subprocess loading/`Pkg.test` of the workspace.

### test resolve with tree hash — line 172
- **Tests:** `Pkg.test()` on the `WorkspaceTestInstantiate` package (which has a `test` subproject) resolves and creates the root `Manifest.toml` but no `test/Manifest.toml`; re-running `Pkg.test()` after deleting the installed `Example` package re-installs and passes.
- **VibePkg:** ✅ COVERED — `workspace_instantiate.jl` "workspace test project shares the root manifest" runs public `VibePkg.test` on a workspace whose `test` project is a member, proves only the root Manifest.toml is created, deletes the installed Example tree, reruns the test, and proves the dependency is reinstalled.

### workspace path resolution issue #4222 — line 193
- **Tests:** Activating a non-root workspace member (`SubProjectB`) with no existing `Manifest.toml` and running `Pkg.update()` succeeds, finding sibling `SubProjectA`.
- **VibePkg:** ✅ COVERED — `workspaces.jl` "sibling resolution with unregistered member dep" resolves from member A (no pre-existing manifest) and successfully picks up sibling B's dep.

### workspace sources pointing to parent package — line 212
- **Tests:** A child subproject (`docs`) whose `[sources]` points at the parent (`{path=".."}`) instantiates without AssertionError; the written manifest records the parent's path as `"."` while the `docs/Project.toml` sources path stays project-relative `".."` (not corrupted to `"."`, issues #4539/#4575).
- **VibePkg:** 🟡 PARTIAL — `workspaces.jl` "subproject [sources] pointing at the parent" resolves a child whose `[sources]` contains `{path=".."}` without assertion failure, proves the parent is path-tracked, and proves the child Project.toml remains `".."`. Its manifest entry is also asserted as `".."`; it does not reproduce Pkg's shared-root-manifest rebasing to `"."`.

### selective workspace instantiate — line 236
- **Tests:** With a resolved workspace manifest, `instantiate(workspace=false)` downloads only root-project deps (Crayons) and not member deps (Example), while `instantiate(workspace=true)` downloads all; `is_instantiated(env, false)` is true (root complete) but `is_instantiated(env, true)` false when a member dep is missing.
- **VibePkg:** ✅ COVERED — `workspaces.jl` third block preserves the workspace-sensitive direct-dependency validation distinction, while `workspace_instantiate.jl` "selective workspace package installation" resolves a shared manifest backed entirely by LocalPkgServer/local Git, removes both source trees, proves `instantiate(workspace=false)` installs the root-only dependency while leaving the member-only dependency absent, and then proves `workspace=true` installs both. Exact `find_installed` checks establish the corresponding root-complete/workspace-incomplete disk states.

## test/sources.jl  (Pkg.jl)

### test Project.toml [sources] — line 9
- **Tests:** On the `WithSources` package: `resolve()` keeps the `[sources]` entry; `free("Example")` removes it; `add(url=..., rev=...)` writes a url+rev source; resolving over a `BadManifest.toml` recovers correct sources for both Example (url+rev) and LocalPkg (path). Then runs `Pkg.test()` on four sub-packages (TestWithUnreg, TestMonorepo, TestProject, URLSourceInDevvedPackage).
- **VibePkg:** ✅ COVERED — `[sources]` overriding the registry is covered (planning.jl "[sources] overrides the registry for a direct dep"), and add writing a url source is covered (git.jl); ✔ git.jl "sources: free drops [sources]; resolve recovers over a bad manifest" adds `free` removing a `[sources]` entry (back to registry tracking) and resolve recovering the correct sources (url+rev for Example, path for LocalPkg) over a deliberately-wrong manifest. (The four end-to-end `Pkg.test` sub-package flows need full sandbox install and remain a separate integration gap.)

### path normalization in Project.toml [sources] — line 56
- **Tests:** Reading then writing a `[sources]` entry with a `path` renders forward slashes (`subdir/LocalPkg`) in the TOML, never backslashes, so Windows-native separators are normalized on write.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "sources path is forward-slash normalized" reads then writes a `[sources]` path and asserts forward slashes / no backslash in the emitted TOML.

### recursive [sources] via repo URLs — line 93
- **Tests:** A Parent→Child→Grandchild chain wired through `file://` git URLs (plus a path-sourced Sibling); `add(url=parent)` pulls in all four packages, each with the correct `git_source` per level, the Sibling is `is_tracking_path` with a `SiblingPkg` source dir, and `using ParentPkg; parent_value()` executes to `47`.
- **VibePkg:** ✅ COVERED — recursive sources collection is covered for *path*-tracked deps (ops.jl "recursive sources collection", planning.jl "[sources] collected recursively for path-tracked deps"); ✔ git.jl "recursive [sources] via repo URLs" adds the repo-URL chain: `add(url=parent)` (no registries) pulls the whole Parent→Child→Grandchild chain with per-level `git_source` verified and a sibling path-tracked inside the url-added Child, surviving a write/reload round-trip. (Loading/executing the resolved package is left to the heavier subprocess-load tests.)

### switching between path and repo sources (#4337) — line 159
- **Tests:** Flipping a `[sources]` entry path→url+rev→path across successive `update()`s must not throw the "tree_hash and path both set" AssertionError; asserts the manifest entry's path/tree_hash/repo.source fields flip correctly each way.
- **VibePkg:** ✅ COVERED — git.jl "[sources] path flipped to url+rev" flips a hand-edited entry from path to url+rev and asserts `is_repo_tracked`, url/rev, `entry_path === nothing`, and `tree_hash !== nothing` (the assertion-error class is exercised). (The reverse flip back to path is not separately re-asserted.)

## test/subdir.jl  (Pkg.jl)

### registry-resolved subdir add/develop — line 181
- **Tests:** With a registry whose `Package.toml` carries a `subdir` field (Package→`julia/`, Dep→`dependencies/Dep`), `add`/`add@version`/`add#branch`/`develop` by registry name install only the named subdir package (Package installed, Dep not, and vice-versa), Dep auto-installs as Package's dependency, and re-adding/re-developing the same package twice does not error (#3391).
- **VibePkg:** ✅ COVERED — `subdir_registry.jl` "registry-resolved subdir add/version/rev/develop matrix" builds a fully local Git monorepo and synthetic registry with `Package.toml.subdir` for Package→`julia/` and Dep→`dependencies/Dep`; public API tests cover plain and exact-version registry adds, registry-resolved `#master` adds, and by-name develops for both packages. It proves Package pulls Dep as a transitive dependency while Dep never pulls its sibling, every installed/repo-tracked source is the named subtree, and repeated branch-add/develop of Package is idempotent (#3391).

### path/url subdir add & develop via PackageSpec (plain + at branch) — line 237
- **Tests:** `Pkg.add`/`Pkg.develop` of a `PackageSpec(path=repo, subdir=...)` and `PackageSpec(url=repo, subdir=..., rev="master")` install exactly the named subdir package (Package vs Dep isolation), both without and with an explicit `rev`.
- **VibePkg:** ✅ COVERED — git.jl "subdirectory add" materializes and plans an add with a url `subdir` (subtree-only tree, records subdir in manifest entry + `[sources]`; nonexistent subdir and no-subdir are pinned errors), and "dev by name of a url-added subdir package" covers develop; ✔ git.jl "subdir add/develop via PackageSpec (path + rev) with isolation" adds the plain-path (non-git) subdir develop, the `rev`-pinned subdir add matrix, and the Package-vs-Dep install-isolation assertions (only the named subdir package becomes a direct dep; the sibling is not dragged in). Divergence pinned: `add(path=)` is git-only, so plain-path subdir tracking is exercised through `develop`.

### REPL `:subdir` syntax for add/develop — line 249
- **Tests:** REPL forms `add/develop <path-or-url>:subdir`, `<url>#branch:subdir` resolve to the same subdir installs as the API calls.
- **VibePkg:** 🟡 PARTIAL — replmode.jl "REPLMode" parses `url:subdir`, `url#rev:subdir`, `path:subdir`, `name:subdir`, and scp/drive-letter edge cases into the right `PackageSpec`, but only tests *parsing*; it never executes an add/develop through the REPL subdir syntax end-to-end.

## test/project_manifest.jl  (Pkg.jl)

### subpackage resolve writes shared root manifest — line 13
- **Tests:** In a `monorepo` (project-as-manifest, no `[workspace]`): dev subpackage B at root, then inside subpackage C dev an unregistered sibling D and `Pkg.test()`; the root `monorepo/Manifest.toml` gains entries for B, C and D (D present with no direct root dep) and C's manifest deps include D; then dev C at root, add Test, and test.
- **VibePkg:** 🟡 PARTIAL — `project_manifest.jl` "project-as-manifest monorepo" develops sibling D from subpackage C, runs C's public test operation, proves C gets no private manifest, and proves the shared root Manifest.toml contains C and D with C's declared dependency metadata. It does not yet port the root-level B/C develop and root-test sequence or assert the full B/C/D accumulation matrix.

### rm dep from subpackage / root-manifest prune behavior — line 45
- **Tests:** After `Pkg.rm("D")` inside subpackage C and re-test, C's manifest deps lose D, but the root manifest still retains D's entry (documented non-pruning, `@test_broken`, issue #3590).
- **VibePkg:** ⚪ N/A — VibePkg intentionally prunes entries unreachable from the active subpackage, rather than preserving Pkg's documented #3590 stale root entry. `project_manifest.jl` "project-as-manifest monorepo" documents this divergence; the upstream non-pruning assertion is not a desired VibePkg contract.


## test/apps.jl  (Pkg.jl)

The single `@testset "Apps"` is broken into its four `isolate` blocks and their meaningful `@test` groups.

### develop + shim exec, submodule & nested-submodule apps — line 12
- **Tests:** `Pkg.Apps.develop(path=...)` installs shims into `depot/bin`; with that on PATH the shim runs the package's `@main`. Also exercises a submodule app (`juliarot13cli` → `CLI:`) and a nested-submodule app (`juliarot13nested` → `Nested:`).
- **VibePkg:** ✅ COVERED — test/apps.jl `@testset "apps"` (develop + `run_shim`) and `@testset "apps: submodule, julia_flags, julia cmd override"` (dotted `SubApp.CLI` submodule resolution + exec).

### julia_flags: baked defaults & runtime override — line 31
- **Tests:** an app with default `julia_flags` gets `--threads=2`/`--optimize=3` in-process; runtime julia flags before `--` override the baked ones (`--threads=4`).
- **VibePkg:** ✅ COVERED — test/apps.jl `@testset "apps: submodule, julia_flags..."` (`nthr` app: `nthreads: 2` baked, `--threads=3 --` overrides to `3`).

### JULIA_APPS_JULIA_CMD executable override — line 44
- **Tests:** `JULIA_APPS_JULIA_CMD` makes the shim call a mock julia executable instead of the recorded one.
- **VibePkg:** ✅ COVERED — test/apps.jl same testset: `juliawrap` wrapper, asserts `WRAPPER-MARKER` present with override and absent without.

### argv boundary preservation — line 64
- **Tests:** exact argv handed to julia is `--startup-file=no -m Rot13 <args...>`; app args with spaces/empty strings survive verbatim, a julia arg with a space is preserved, only the first `--` is the separator, and glob chars are not expanded.
- **VibePkg:** ✅ COVERED — `test/apps.jl` uses a hermetic mock Julia executable to assert its exact argv: app and Julia args containing spaces, an empty app arg, a literal glob in a cwd where it would expand if unquoted, and a second `--` preserved as an app argument.

### rm behavior & no-argument add/develop errors — line 83
- **Tests:** `Apps.rm` clears all shims; removing apps one-by-one drops the package and leaves an empty AppManifest; re-removing errors; `Apps.add()`/`Apps.develop()` with nothing to add error.
- **VibePkg:** ✅ COVERED — `test/apps.jl` `@testset "apps"` covers rm-clears-shim, an empty manifest, re-rm throwing `PkgError`, and public no-argument `Apps.add()`/`Apps.develop()` calls throwing `PkgError`.

### add by git path; develop abs/"." path; no env dir; live edits — line 106
- **Tests:** `Apps.add(path=<git repo>)` then run/rm; `Apps.develop` with an absolute path and with `"."` from inside the package; dev must NOT create an app-env directory; edits to a dev'd package are immediately reflected by the shim.
- **VibePkg:** ✅ COVERED — `@testset "apps: repo-tracked update fetches upstream and removes stale shims"` covers public `Apps.add(path=<local git repo>)` plus run/update; `@testset "apps: develop absolute path and pwd are live"` develops both the absolute checkout and `"."`, asserts neither creates a per-app environment, and proves a fresh shim process immediately observes a source edit.

### [sources] relative path in app package — line 164
- **Tests:** an app whose Project.toml has a `[sources]` relative path (only valid next to the original checkout) still installs correctly; the dep resolves rather than dangling (#4532/#4714).
- **VibePkg:** ✅ COVERED — test/apps.jl `@testset "apps: add with [sources] in the app package"` (asserts dep is registry-resolved, not path-tracked, and app runs).

### relocated depot keeps working — line 222
- **Tests:** copying `bin`/`environments`/`packages` to a new depot location and running the copied shim still works — shims locate their depot relatively and the env uses relative paths.
- **VibePkg:** ✅ COVERED — `@testset "apps: relocated depot keeps working"` installs from a local git repository, verifies the generated shim uses its depot-relative app environment, copies only `bin`/`environments`/`packages` to another depot, and runs the copied shim successfully.

### update fetches latest commit & drops stale shims — line 232
- **Tests:** `Apps.update` of a repo-tracked app fetches the new commit (`v2`) and removes shims for apps the new version no longer provides (`someapp2` gone) (#4634).
- **VibePkg:** ✅ COVERED — `test/apps.jl` "apps: repo-tracked update fetches upstream and removes stale shims" installs from a local git repository, advances its branch, verifies update records and runs the new tree, and verifies the removed app's shim is deleted. Registry-version update and failed-update staging safety remain covered by "apps: add by registry name".

### develop of an app with deps gets a resolved manifest — line 272
- **Tests:** `Apps.develop` of an app with dependencies writes a resolved `Manifest.toml` so deps load at runtime (#4697).
- **VibePkg:** ✅ COVERED — `@testset "apps: develop resolves dependencies into the checkout manifest"` uses public `Apps.develop` with a fully local Git-backed registry dependency, asserts the checkout manifest records its exact UUID/name/version/tree as registry-tracked, and runs the generated shim in a fresh process to prove the dependency loads.

### add registered app by name/version + update variants — line 283
- **Tests:** `Apps.add(name="Runic", version=...)`, then `update` bumps to latest, `update()` updates all, `update("runic")` by app name, unknown name errors.
- **VibePkg:** ✅ COVERED — `@testset "apps: add by registry name"` (add by name→latest, explicit version, update→latest, unknown-name `PkgError`) plus `app_update` no-arg in `@testset "apps"`.

## test/platformengines.jl  (Pkg.jl)

### Packaging — line 38
- **Tests:** `package(prefix, tarball)` archives a directory tree into a `.tar.gz` and `list_tarball_files` can enumerate its contents.
- **VibePkg:** ⚪ N/A — VibePkg has no tarball-creation API (legacy BinaryProvider `package`); it only unpacks. Feature not ported.

### Verification — line 80
- **Tests:** `verify(file, hash)` maintains a `.sha256` sidecar cache and returns status codes (`hash_cache_missing`, `hash_cache_consistent`, `file_modified`, `hash_cache_mismatch`, `hash_mismatch`); bad hash logs a Mismatch error; wrong-length hash throws.
- **VibePkg:** ⚪ N/A — VibePkg verifies sha256 directly per download (`ArtifactOps.verify_sha256`) with no `.sha256` sidecar-cache mechanism; the sha256 correctness/rejection itself is covered by artifacts.jl `@testset "download fallback and rejection"`.

### Downloading — line 163
- **Tests:** `download_verify_unpack` over the network for `.tar.gz`/`.tar.bz2`/`.tar.xz`; second call hits the "already exists" path; corrupting then `force` hits the "redownloading" path; unpacked file hash matches.
- **VibePkg:** 🟡 PARTIAL — artifacts.jl `@testset "download fallback and rejection"` covers download+sha256-verify+unpack+tree-hash-reject over a local server (gz only). Missing: bz2/xz formats and the already-exists / redownload-after-corruption cache paths.

### Copyderef unpacking — line 193
- **Tests:** with `BINARYPROVIDER_COPYDEREF=true`, symlinks are materialized as real copies and broken symlinks are dropped.
- **VibePkg:** ⚪ N/A — legacy BinaryProvider copyderef mode not implemented in VibePkg's unpack path.

### Download GitHub API #88 — line 214
- **Tests:** `PlatformEngines.download` of an `api.github.com/.../tarball/<sha>` URL follows redirects and writes a file.
- **VibePkg:** ⚪ N/A — live-network smoke test. VibePkg synthesizes GitHub archive URLs (`Fetch.jl:216`) and its download-to-file behavior is covered locally (artifacts fallback, doc_features 401); no equivalent live-GitHub hit.

### Authentication Header Hooks › get_server_dir — line 251
- **Tests:** `get_server_dir` maps server+url to `servers/<host[_port]>`, returns `nothing` when url isn't under the server, and sanitizes `:`→`_`; combinatorial sweep over host/protocol/port/suffix plus `file://` URLs (#4640).
- **VibePkg:** 🟡 PARTIAL — artifacts.jl `@testset "server dir name sanitization"` checks only `localhost:8888 → localhost_8888`. No combinatorial matrix, no `file://` URLs, no negative (`nothing`) cases.

### Authentication Header Hooks (auth error handler registration) — line 221
- **Tests:** `get_auth_header` returns `nothing` without a server; `register_auth_error_handler` invokes the handler on auth failure (called up to retry limit) and its returned `dispose`/deregister stops further calls; scheme scoping.
- **VibePkg:** ✅ COVERED — doc_features.jl `@testset "auth error handler hooks"` (register, handler-provisions-token, non-matching-scheme unhandled, deregister empties `AUTH_ERROR_HANDLERS`).

### Authentication token refresh file mode — line 314
- **Tests:** an expired token is refreshed through `refresh_url`; the refreshed token download lands in a private temp file created with mode `0o600` (`0o666` on Windows).
- **VibePkg:** ✅ COVERED — artifacts.jl `@testset "auth.toml expiry and refresh"` refreshes through a local HTTP endpoint, asserts the new token and expiry are persisted, and on non-Windows asserts the atomically replaced auth file has no group/other permission bits (`filemode & 0o077 == 0`). `Fetch.get_auth_token` creates the same-directory temporary file, applies `0o600`, and renames it into place; doc_features.jl separately covers the 401-triggered refresh/retry path.

## test/binaryplatforms.jl  (Pkg.jl)

All six testsets exercise the `Pkg.BinaryPlatforms` compat shim (`Linux`/`MacOS`/`Windows`/`FreeBSD` constructors, `CompilerABI`, `triplet`, `platforms_match`, `valid_dl_path`, `Sys.is*` overloads). VibePkg deletes this layer and uses `Base.BinaryPlatforms` directly (Fetch.jl:195, ArtifactOps.jl:16, compat/Artifacts.jl:12) — no shim to test.

### Compat - PlatformNames › Platform constructors — line 15
- **Tests:** invalid arch/libc/call_abi combos throw `ArgumentError`; `CompilerABI` copy constructor; `UnknownPlatform` ignores args.
- **VibePkg:** ⚪ N/A — Base.BinaryPlatforms used directly; compat constructors not present.

### Compat - PlatformNames › Platform properties — line 47
- **Tests:** `platform_name`, `arch`, `platform_dlext`, `wordsize`, `call_abi`, `triplet` values across platforms.
- **VibePkg:** ⚪ N/A — reuses Base.BinaryPlatforms.

### Compat - PlatformNames › Valid DL paths — line 87
- **Tests:** `valid_dl_path` accepts/rejects `.so`/`.dll`/`.dylib` names per platform.
- **VibePkg:** ⚪ N/A — reuses Base.BinaryPlatforms.

### Compat - PlatformNames › platforms_match() — line 100
- **Tests:** combinatorial CompilerABI matching (compatible ABIs match incl. string-parsed triplets; cross-OS/arch and incompatible ABIs don't).
- **VibePkg:** ⚪ N/A — reuses Base.BinaryPlatforms `platforms_match` (compat/Artifacts.jl:135).

### Compat - PlatformNames › Sys.is* overloading — line 142
- **Tests:** `Sys.islinux/iswindows/isapple/isbsd` overloaded for Platform objects.
- **VibePkg:** ⚪ N/A — reuses Base.BinaryPlatforms.

### Compat - PlatformNames (compat shim wrapper) — line 13
- **Tests:** the enclosing shim-compatibility suite, retained until Pkg migrates off `Pkg.BinaryPlatforms`.
- **VibePkg:** ⚪ N/A — VibePkg was written directly against Base.BinaryPlatforms; the shim never existed.


## test/extensions.jl  (Pkg.jl)

### weak deps — line 5
- **Tests:** One big testset for package extensions/weakdeps. Dev's HasExtensions/HasDepWithExtensions and runs `Pkg.test` with and without `coverage=true`, asserting `.cov` files appear only in the tested package's `src`/`ext` (coverage scoping); `status(; extensions=true)` prints `OffsetArraysExt [OffsetArrays]`; adding an incompatible `OffsetArrays` throws `ResolverError`; add+test via a registry; `precompile` output names the extension modules; `add(target=:weakdeps/:extras)` populates the right project table; explicitly `add`ing a name that is a weakdep promotes it into `[deps]` and out of `[weakdeps]`; and a weakdep with a UUID absent from every registry still resolves (#3766).
- **VibePkg:** 🟡 PARTIAL — extension status display covered by ops.jl "extension status with strong-dep trigger" + pins.jl "extension tree pin"; `target=:weakdeps/:extras` and weakdep→dep promotion by public_api.jl "add target = :weakdeps/:extras" and doc_features.jl "add --weak / --extra"; weakdep [compat] by planning.jl "project [weakdeps] compat respected". Missing: running `Pkg.test` on an extension package with `.cov` coverage scoping, precompile naming extension modules, `ResolverError` on an incompatible weakdep add, and the weakdep-absent-from-registry case (#3766).

## test/sandbox.jl  (Pkg.jl)

### Basic `test` sandboxing — line 14
- **Tests:** `Pkg.test` runs in a sandbox: the manifest holds the compat-obeying versions (Unregistered 0.20.0), the active project is the sandbox not `JULIA_PROJECT`, `LOAD_PATH[1]=="@"` and `[2]` prefixes the active project; test-only deps are preserved from the parent manifest when possible.
- **VibePkg:** ✅ COVERED — sandbox resolve/isolation and parent-version preservation are covered by buildtest.jl "test: sources-based test/Project.toml" and "test: sandbox manifest keeps the parent's versions" (#1423), compat obedience by "test: force_latest_compat", and the legacy sandbox test asserts in-process that `JULIA_PROJECT` is absent, `LOAD_PATH` is exactly `[@, sandbox]`, and an untargeted stdlib is not loadable.

### Preferences sandboxing without test/Project.toml — line 50
- **Tests:** With no `test/Project.toml`, preferences declared in the package project are copied into the test sandbox and readable via `Preferences.load_preference`.
- **VibePkg:** ✅ COVERED — buildtest.jl "sandbox preferences (Pkg parity)" and "test: legacy [extras]/[targets] sandbox deps" (no test/Project.toml → cascade anchored at the package project).

### Preferences sandboxing with test/Project.toml — line 66
- **Tests:** `test/Project.toml` + `test/LocalPreferences.toml` preferences apply in the sandbox, the test-local table wins over the test project table, and preferences set in an outer `LOAD_PATH` layer leak through into the test run.
- **VibePkg:** ✅ COVERED — buildtest.jl "sandbox preferences (Pkg parity)" exercises test/Project.toml, test/LocalPreferences.toml precedence, and parent-environment preferences leaking into the sandbox cascade.

### Nested Preferences sandboxing — line 145
- **Tests:** Preferences declared for a transitive dependency (not the top package) are still flattened into the test sandbox via `Base.get_preferences`.
- **VibePkg:** 🟡 PARTIAL — the preference-cascade mechanism is thoroughly tested, but only for the tested package itself; preferences keyed to a transitive dependency are not specifically exercised.

### Basic `build` sandbox — line 162
- **Tests:** `Pkg.build()` runs a package's `deps/build.jl` inside a build sandbox without error.
- **VibePkg:** ✅ COVERED — buildtest.jl "build and test ops" runs `BuildOps.build!` and asserts the build script's side effects and `build.log`.

## test/misc.jl  (Pkg.jl)

### inference — line 5
- **Tests:** `@inferred` type-stability of the `Types.STDLIBS_BY_VERSION` and `Types.UNREGISTERED_STDLIBS` accessors.
- **VibePkg:** ✅ COVERED — `misc.jl` "inference" uses `@inferred` accessors for both `Stdlibs.STDLIBS_BY_VERSION` and `Stdlibs.UNREGISTERED_STDLIBS` and asserts object identity.

### hashing — line 12
- **Tests:** `hash` is stable/consistent for `Project()`, `VersionBound()`, and `Resolve.Fixed`; `VersionSpec`/`PackageEntry` hashes merely run (documented as unstable).
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "hashing" asserts consistent hashes for `EnvFiles.Project()`, `Versions.VersionBound`, and `Resolve.Fixed`, and that `VersionSpec`/`ManifestEntry` hashes merely run.

### safe_realpath — line 21
- **Tests:** `safe_realpath` returns the input unchanged for empty, nonexistent, and drive-like paths instead of throwing (#3085).
- **VibePkg:** ✅ COVERED — envfiles.jl "safe_realpath termination" tests exactly the empty / nonexistent-deep / drive-like cases (#3085).

### normalize_path_for_toml — line 29
- **Tests:** On Windows relative backslash paths become forward-slash and absolute/UNC paths are left untouched; on Unix all paths pass through unchanged.
- **VibePkg:** ✅ COVERED — `misc.jl` "normalize_path_for_toml" directly exercises the platform contract: Windows relative backslash paths normalize to forward slashes while drive-absolute and UNC paths remain unchanged; on Unix both slash- and backslash-containing relative paths, absolute paths, and UNC-shaped strings pass through unchanged. The same test also pins the read-time `denormalize_path_from_toml` inverse.

### PackageSpec version default — line 50
- **Tests:** A `PackageSpec(name=...)` with no version defaults `version` to `VersionSpec("*")` (relied on by BinaryBuilderBase), while an explicitly supplied `VersionNumber`/version-string is preserved.
- **VibePkg:** ✅ COVERED — ✔ parity_gaps.jl "PackageSpec version default" asserts a name-only spec resolves to the all-versions `VersionSpec("*")` via `to_request`+`request_version_spec` (VibePkg keeps PackageSpec's `.version` `nothing` and defaults downstream), while explicit versions pass through.

### subprocess_handler forwards interrupts to the child — line 71
- **Tests:** (non-Windows) A REPL `^C` (InterruptException in the parent task) is forwarded as SIGINT to the child process so it can trap, report, and exit cleanly (exit code 7, not SIGKILLed).
- **VibePkg:** ✅ COVERED — `misc.jl` "subprocess_handler forwards interrupts to the child" starts a trapping child, injects `InterruptException` into the parent task, and proves `TestOps.subprocess_handler` forwards SIGINT so the child reports and exits with code 7 rather than being killed; Windows is explicitly skipped.

## test/stdlib_compat.jl  (Pkg.jl)

### Non-upgradable stdlib compat handling — line 5
- **Tests:** A project with a `[compat]` entry for a non-upgradable stdlib (LibCURL) that is incompatible with its pinned version produces a `@warn "Ignoring incompatible compat entry"` on `resolve()` rather than erroring.
- **VibePkg:** ✅ COVERED — `stdlib_compat.jl` "Non-upgradable stdlib compat handling" builds a real LibCURL project compat excluding the shipped version, asserts the exact warning and relaxed `VersionSpec("*")`, then proves a compatible constraint is preserved.

## test/historical_stdlib_version.jl  (Pkg.jl)

### is_stdlib() across versions — line 15
- **Tests:** With `HistoricalStdlibVersions` registered, `is_stdlib(uuid, version)` is correct across julia versions for a became-stdlib package (NetworkOptions), an always-unregistered stdlib (Pkg), and a stopped-being-stdlib jll (MbedTLS_jll); unknown major.minor throws `PkgError`; after `unregister!` only the current version works.
- **VibePkg:** ✅ COVERED — `historical_stdlib_version.jl` "is_stdlib() across versions" now installs `HistoricalStdlibVersions` (a test dep) and bridges its tables into `VibePkg.Stdlibs` (same `STDLIBS_BY_VERSION` protocol as Pkg; HSV loads at worker boot on the loose stack, before `isolate!()` drops the user depot). It ports every reference assertion verbatim — NetworkOptions/Pkg/MbedTLS_jll across versions, `v"999.999.999"` → PkgError, `v"1.10.999"` patch match, and the post-unregister current-only behavior. Global tables are cleared in a `finally` so later same-worker files (depots_stdlibs.jl) still see them empty.

### Pkg.add() with julia_version — line 55
- **Tests:** Adding packages while pinning `julia_version` resolves version-appropriate JLLs (GMP_jll 6.1.x for v1.5, 6.2.0 for v1.6, 6.2.1 for v1.7), installs the matching artifact, gives stdlibs a version only when they were registered, and stdlibs never pull registry deps. Requires the General registry + real downloads.
- **VibePkg:** 🟡 PARTIAL — the *version-selection* half (the exact JLL version each julia version resolves to) is now asserted both directly (via `stdlib_version` in "stdlib versions across julia versions": GMP_jll 6.2.0+5 @ v1.6, 6.2.1+1 @ v1.7, MPFR_jll 4.1.x, LinearAlgebra unversioned, the became-stdlib-in-v1.6 boundary) and end-to-end through the resolver ("resolve: …" testsets — see "Resolving for another version of Julia" below). Only the artifact *download* + on-disk-library check stays out of scope (network); the "stdlib deps not from registry" invariant is covered hermetically by planning.jl "stdlib deps come from the local stdlib, not the registry".

### Resolving for another version of Julia — line 160
- **Tests:** `Operations._resolve` with `Context(; julia_version=...)` yields julia-version-appropriate dep versions (GMP 6.1 for v1.5, 6.2 for v1.6) and can resolve an "impossible" manifest under `julia_version=nothing`.
- **VibePkg:** ✅ COVERED — `historical_stdlib_version.jl` drives the resolver end-to-end (metadata-only, no download; `plan_resolve`/`plan_add` are pure) against a synthetic GMP_jll/MPFR_jll fixture registry (`make_jll_registry`) plus the HSV tables, and checks the returned versions: (1) "resolve: stdlib version per julia_version" resolves GMP_jll to its historical stdlib build (6.2.0+5 @ v1.6, 6.2.1+1 @ v1.7, no tree hash); (2) "resolve: transitive JLL per julia_version" resolves MPFR_jll → GMP_jll from the registry gated by `[compat] julia` at v1.5 (MPFR 4.0.2 → GMP 6.1.2) and from the historical tables at v1.6 (GMP 6.2.0+5, MPFR 4.1.x, registry shadowed); (3) "resolve: julia_version = nothing coexistence" reproduces the impossible-manifest case — GMP 6.2.0 + MPFR 4.0.2 coexist under `nothing` but throw a `ResolverError` under v1.5. Fixtures stand in for General (the reference's exact GMP/MPFR versions come from real registry data); the resolver logic exercised is identical.

### Elliot and Mosè's mini Pkg test suite — line 220
- **Tests:** Wrapper testset gating the nested add scenarios below on `HistoricalStdlibVersions.register!`.
- **VibePkg:** ⚪ N/A — wrapper for network/historical integration scenarios not applicable to the hermetic suite.

### Standard add — line 222
- **Tests:** Non-stdlib JLL adds resolve correctly by flexible version, by url+rev, by exact `VersionNumber`, and by `VersionSpec` (HelloWorldC_jll).
- **VibePkg:** ⚪ N/A — needs the real JuliaBinaryWrappers registry/repo; add-shape variants are otherwise covered against fixture registries elsewhere.

### Julia-version-dependent add — line 244
- **Tests:** Adding a non-stdlib JLL with `julia_version` (libcxxwrap_julia_jll) picks version-appropriate builds and honors an explicit version under a given julia version.
- **VibePkg:** ⚪ N/A — network + historical integration; not applicable hermetically.

### Old Pkg add regression — line 267
- **Tests:** `Pkg.add("Pkg"; julia_version=v"1.11")` succeeds (regression guard for adding the Pkg stdlib at a historical version).
- **VibePkg:** ⚪ N/A — requires historical stdlib tables; hermetic suite does not register them.

### Stdlib add — line 272
- **Tests:** Adding GMP_jll resolves the current-julia stdlib version, other julia versions (v1.7 → 6.2.1+1), rejects an impossible exact version under a pinned julia version (`ResolverError`), and handles `julia_version=nothing`.
- **VibePkg:** ⚪ N/A — network + historical integration; VibePkg does test analogous stdlib-tracking transitions hermetically (depots_stdlibs.jl "stale versioned-stdlib manifest entry", planning.jl "package→stdlib transition on up").

### julia_version = nothing — line 317
- **Tests:** Grouping testset for `julia_version=nothing` resolution scenarios below.
- **VibePkg:** ⚪ N/A — wrapper for network/historical scenarios.

### stdlib add (nested) — line 318
- **Tests:** Under `julia_version=nothing`, adding OpenBLAS_jll/libblastrampoline_jll at impossible-under-one-julia constraints resolves to the requested version bands.
- **VibePkg:** ⚪ N/A — network + historical integration.

### non-stdlib JLL add — line 333
- **Tests:** Adding CMake_jll for a specific platform under `julia_version=nothing`, both via the private `Pkg.add(ctx, deps; platform)` path and the public `julia_version` kwarg.
- **VibePkg:** ⚪ N/A — network integration; platform-keyed selection is otherwise covered hermetically in artifacts.jl.

### with context (using private Pkg.add method) — line 338
- **Tests:** The private `Pkg.add(ctx, mydeps; platform)` entry point resolves a platform-specific JLL under a `julia_version=nothing` context.
- **VibePkg:** ⚪ N/A — nested network scenario.

### with julia_version — line 345
- **Tests:** The public `Pkg.add(deps; platform, julia_version=nothing)` path resolves the same platform-specific JLL.
- **VibePkg:** ⚪ N/A — nested network scenario.

### Artifacts stdlib never falls back to registry — line 352
- **Tests:** Resolving for julia v1.10 (where Artifacts is a stdlib) must not pull the external Artifacts v1.3.0 from the registry when a dep (GMP_jll) requires Artifacts.
- **VibePkg:** ⚪ N/A — needs historical tables + General registry; the "stdlib never resolved from the registry" invariant is covered hermetically by planning.jl "stdlib deps come from the local stdlib, not the registry".



---

# Commit-history audit (Pkg.jl `test/`, ~2 years / 147 commits)

Went commit-by-commit through every change to Pkg.jl's `test/` dir over the last
~2 years and checked VibePkg coverage. The vast majority were already covered
(by the file-level audit above or this session's work) or were pure
refactor/format/CI/flaky-disable. New findings:

**Implemented this pass (verified green):**

- [x] **#4091** — an empty/`touch`ed `Manifest.toml` is treated as the current
  (v2) format → `test/envfiles.jl` "empty manifest reads as v2 format".
- [x] **#4459 / issue #3766** — `develop` a package whose `[weakdeps]` names an
  unregistered UUID succeeds → `test/ops.jl` "develop with an unregistered
  weakdep uuid".

**Backlog — small gaps still to cover:**

- [x] **#4689 (JLSEC-2026-610)** — the auth-token refresh downloads to a private  ✔ DONE → test/artifacts.jl "auth.toml expiry and refresh" asserts the refreshed auth.toml is 0o600 (private).
  `0o600` temp file (`Fetch.jl:146`); the refresh flow is tested
  (`artifacts.jl` "auth.toml expiry and refresh") but no test asserts the
  private filemode — the actual security point of the PR.
- [x] **#3520** — per-dependency manifest `syntax.julia_version` (Julia 1.13+):  ✔ DONE → already worked (parse+render both handle it; my earlier grep checked the wrong literal); locked in by test/envfiles.jl "per-dep syntax.julia_version round trip".
  VibePkg currently **drops** it on read/render (the fixture
  `test/fixtures/manifest/good/withversion.toml` is unreferenced, and a
  round-trip is "equal" only because both sides lose the field). Needs a src fix
  to preserve it, then a round-trip test.
- [x] **#4634** — `update` of a *git-repo-tracked* app fetches new upstream commits, rewrites the surviving shim, and removes stale shims.  ✔ DONE → test/apps.jl "apps: repo-tracked update fetches upstream and removes stale shims" (local git repository + isolated depot; no internet).
- [x] **#4602** — precompile surfaces "Circular dependency detected".  ✔ DONE → test/public_api.jl "precompile diagnoses circular dependencies" builds a three-package local manifest cycle and captures Base.Precompilation's diagnostic from either its log or IO channel; the fixture is deterministic and fully offline.
- [x] **#4435 / #1989** — `status` manifest-mode filtered by a package name shows  ✔ DONE → test/ops.jl "status manifest filter shows a package's deps".
  that package's dependencies — not asserted.
- [x] **#4418** — completion on a trailing-space command (`rm ` → env deps) is  ✔ DONE → test/replmode.jl (trailing-space `rm `/`add ` completions don't crash).
  not asserted.
- [x] **non-ASCII name** — `add ÖÖÖ` rejection (the Windows drive-letter  ✔ DONE → test/replmode.jl (`add ÖÖÖ` parses as a name, no BoundsError). Note: ÖÖÖ is a valid Julia identifier so VibePkg does not reject it — resolution just wouldn't find it.
  string-indexing edge) is not asserted (`argshapes.jl` covers ASCII cases).
- [x] **#4641** — `file://` local-path pkg-server URL → server-dir name; untested  ✔ DONE → test/artifacts.jl "server dir name sanitization" adds a file:// case (filesystem-safe name). VibePkg sanitizes the whole URL vs Pkg's basename scheme — a documented divergence.
  (and VibePkg's host-based scheme differs from Pkg's path-basename one — verify
  intended behavior first).

**Divergences (N/A — VibePkg intentionally differs; documented, no test to add):**

- **#4335** — adding a stdlib at a version mismatching the running Julia: Pkg
  errors ("Cannot add stdlib …"); VibePkg silently ignores the version
  (`API.jl:476` `is_stdlib(uuid) && continue`).
- **#4551** — a project-declared dotted app submodule (`submodule = "CLI.Nested"`):
  Pkg accepts it; VibePkg **rejects** it (`envfiles.jl:31` asserts the throw).
- **#3122** — a leading `]` in REPL input: Pkg warns and strips; VibePkg does not
  (already noted, detailed section).
- **#3997** — comma-separated `dev A,B`: Pkg splits into two packages; VibePkg
  parses `"A,B"` as a single (invalid) spec.
