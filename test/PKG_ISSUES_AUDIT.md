# Pkg.jl open-issue audit vs VibePkg

Audit of **all open** Pkg.jl issues
(<https://github.com/JuliaLang/Pkg.jl/issues?q=sort:updated-desc+is:issue+state:open>),
newest-updated first, one page at a time.

> ✅ **COMPLETE — all 426 open issues triaged** (verified by diffing every
> triaged issue number against the GitHub search API: 0 missing). The
> `/issues` API endpoint interleaves issues with PRs and runs out at page 18,
> so pages 1–18 span the entire open-issue set.

Goal: for each issue that is a **bug / deficiency / correctness** report (not a
feature request, RFC, or question), determine whether it **still reproduces in
VibePkg** or is **fixed / not-applicable**, and — where a bug reproduces or is
fixed and is testable offline — point to a covering test.

## Verdict legend

| verdict | meaning |
|---|---|
| `SKIP` | not a bug report (feature request, RFC/discussion, question, pure-docs enhancement) — no reproduction attempted |
| `FIXED` | in-scope bug that does **not** reproduce in VibePkg |
| `PERSISTS` | in-scope bug that **does** reproduce in VibePkg (a real gap to fix) |
| `N/A` | depends on Pkg internals / Julia Base behavior VibePkg doesn't share, or otherwise not meaningfully portable |
| `NEEDS-REPRO` | in-scope but not yet reproduced (network fixture needed, expensive, or deferred) |

Test column: file + testset that pins the behavior, or `—`.

## Progress & regression tests

- **Pages covered:** 1–18 = **all 426 open issues**. In-scope bugs: **124 → 99 FIXED, 19 PERSISTS, 6 N/A**. The other 302 issues are non-bugs (feature requests, RFCs, questions, pure-docs) → SKIP.
- **Every FIXED issue has a passing regression test.** Page-1 #4686 & #4691 → `test/ops.jl`; the other **97 FIXED** → **`test/pkg_issues.jl`** (97 self-contained `@testset`s, all green, auto-discovered by `runtests.jl`).
- **Every remaining PERSISTS bug has a `@test_broken` test** in **`test/pkg_issues_broken.jl`** (19 testsets, each asserting the *correct* behavior so it records **Broken** today and flips to an *Unexpected Pass* the moment the bug is fixed — at which point it moves into `test/pkg_issues.jl` as a passing `@test`).
- **Fixing progress (worktree-isolated agent per bug, file-partitioned):**
  - **Wave 1 — 8 fixed:** #4705 (`Planning.jl`), #4006 (`Resolve.jl`), #3420 (`compat/Registry.jl`), #3365 (`TreeHash.jl`), #3150 (`Display.jl`), #2894 (`Git.jl`), #1657 (`ArtifactOps.jl`), #1236 (`API.jl`).
  - **Wave 2 — 6 fixed:** #4553 (registry extract `..`/symlink path → `Fetch.jl`), #3644 (`Pkg.test` mirrors `--warn-overwrite` → `TestOps.jl`), #4103 (`is_manifest_current` detects deved-pkg dep changes → `Environments.jl`), #4351 (`resolve` picks up nested-`[sources]` rev changes → `Planning.jl`), #3795 (JLL build-metadata deps kept consistent → `Planning.jl`), #3496 (`up <unregistered>` doesn't force a registry update → `API.jl`).
  - **Wave 3 — 2 fixed:** #4131 (sysimage JLL build mismatch no longer downgrades on update → `Planning.jl`), #3555 (`instantiate` uses `:auto` registry update, no redundant refetch → `API.jl`).
  - **Deferred (attempted, not merged — need a lower-risk fix):** #3326 (symlinked `Project.toml`: the fix reworks core `write_environment`/`load_environment` and regressed manifest-mode `status`); #3901 (resolver error shows build numbers: fix makes hot `VersionBound` non-`isbits` — needs the `isbits` encoding); #2922 (interrupt-orphaned test child: interrupt handling exists but the assertion is load/timing-fragile). All three stay `@test_broken`.
  - **Excluded (features / design-calls, left as `@test_broken`):** #1568 (build-metadata version support), #3269 (raw-artifact file modes), #708 (git submodules), #4579/#4580 (offline-mode), #2028 (`semver_spec` consistency).
- Method: `Workflow` fan-out — triage, reproduce, write `@test`/`@test_broken`, and fix (worktree-isolated, one src file each, diffs integrated serially; test migration done centrally).

### The 19 remaining PERSISTS (each covered by a `@test_broken`)

Pages 1–6: #4580, #4579, #4082, #3269.
Pages 7–8: #4068, #3901, #3853, #2303.
Pages 9–11: #3494, #3326, #1568.
Pages 12–14: #2922, #2525, #708.
Pages 15–17: #2211, #2028, #2023, #2007, #1829.
(Fixed & moved to the passing suite — wave 1: #4705, #4006, #3420, #3365, #3150, #2894, #1657, #1236; wave 2: #4553, #3644, #4103, #4351, #3795, #3496; wave 3: #4131, #3555.)

Themes: resolver/`up` edge cases (build-metadata JLL deps, targeted-`up` no-ops, stale
explicit-requirement / dropped-build-number messages, name↔UUID mismatch), `JULIA_PKG_OFFLINE`
not honored on registry-update/instantiate, redundant registry updates on instantiate/`up`,
`Pkg.test` subprocess interrupt-orphaning & hardcoded `--warn-overwrite`, artifact file-mode &
missing-`arch` TypeError, `dev`/`add` not running `deps/build.jl`, symlinked project/depot dev
paths, git submodules & non-standard SSH ports, and `semver_spec("0.0.0")` / `Registry.rm(SubString)`
/ build-metadata version quirks. See per-page tables for per-issue evidence.

---

## Page 1 (issues #4680–#4723, updated 2026-07-14)

| # | title | type | verdict | notes / test |
|---|---|---|---|---|
| 4723 | Mention `resolve` in weak-dep docs | docs enhancement | SKIP | doc request, not a behavior bug |
| 4526 | Restore menu for multiple same-name registered pkgs | UX regression / feature | SKIP | feature (restore removed UI). VibePkg errors `there are multiple registered <name> packages, explicitly set the uuid` (Planning.jl:1176) — matches current Pkg ≥1.11 |
| 4691 | Does Pkg preserve custom `[tables]` in Project.toml? | behavior / clarification | **FIXED** | VibePkg **preserves** unknown tables (`Project.raw`); round-trip verified through `add` + `rm` (`[reuse_licensing]`, `[tool.mytool]` survive). ✔ test `test/ops.jl` "operations preserve custom Project.toml tables (#4691)" |
| 4705 | path-`[sources]` honored + hard-errors when developed as a dep | bug (MWE) | **PERSISTS** | Reproduced: `plan_develop` of a pkg whose `[sources]` points at an absent `../Example` throws `expected package Example [7876af07] to exist at path …`. `collect_project` (Planning.jl:288-304) honors a developed dep's own `[sources]`. Real gap — no passing test |
| 1070 | Standardised metadata in Project.toml | RFC/discussion | SKIP | feature request |
| 4577 | `activate --workspace` | feature | SKIP | feature request |
| 4688 | `precompile` MethodError switching `[sources]` path→url | bug (stacktrace) | **FIXED** | Cannot reproduce the `MethodError joinpath(::Nothing)`: with a stale path-manifest + url-`[sources]`, VibePkg `precompile`/`instantiate` runs clean; no-manifest case re-resolves and errors cleanly on the (dead) url fetch, not a `nothing`-crash. ✔ test `test/pkg_issues.jl` "Pkg.jl#4688 …" |
| 4687 | not-installed pkg loadable via stacked global env | Base loading | SKIP | Julia Base env-stacking/loading, not Pkg |
| 4686 | `free`ing a `develop`ed package errors | bug (MWE) | **FIXED** | `add` + `dev`-by-path + `free` of Example works; freed entry is registry-tracked again. ✔ test `test/ops.jl` "free re-tracks a develop'd package (#4686)" |
| 4680 | Improve re-precompilation messaging | enhancement | SKIP | feature request |

**Page 1 in-scope tally:** 3 FIXED (#4691, #4688, #4686), 1 PERSISTS (#4705), rest SKIP. Tests to add: #4691 (custom-table preservation → envfiles.jl), #4686 (free dev'd → ops.jl); #4705 is an open gap.

## Page 2

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 4676 | Allow `[sources]` to specify SSH SCP-like URLs from non-standard GitHu | bug | **FIXED** | Ran in daemon r4676. isurl("deploy@ghe.example.com:org/A.git") => true (also ci-bot@internal-git.corp:team/pkg.git => true; ../local/path and /abs/local/path => false). End-to-end: a Project.toml with [sources] A = {url = "deploy@ghe.exampl… — _test:_ In test/envfiles.jl add a testset asserting VibePkg.Utils.isurl("deploy@ghe.example.com:org/A.git") == true, plus a [sou… |
| 4675 | "Package name/uuid must precede subdir specifier" error on ]add | bug | **FIXED** | Ran the exact MWE through VibePkg's REPL parser in the --test daemon (LocalPkgServer isolate not needed — pure parse). `VibePkg.REPLMode.do_cmd("add Example@0.1 Scratch@0.1")` under TEST_MODE returned, with NO error thrown: api=add, args=Pa… — _test:_ In test/replmode.jl (parsing testset, alongside the existing capture("add Example@0.5.1 Other=...") at line 31), add: `a… |
| 4670 | Dependency cooldowns feature | feature | SKIP | Feature request to add a dependency-cooldown / install-delay mechanism |
| 4668 | race condition on `Pkg.build()` | bug | **FIXED** | Ran a genuine cross-process race adapted to the offline environment. Built a local git package repo (Foo, tree 1e5acfcc...) and launched 6 separate OS julia processes, barrier-synced to hit the install within milliseconds of each other, all… — _test:_ Two complementary offline tests. (1) Unit test of the guard helper in a new testset (e.g. test/buildtest.jl, which alrea… |
| 4664 | Support target-platform-aware offline preparation of environments/depo | feature | SKIP | Feature request for eager cross-platform artifact download / offline depot preparation |
| 4659 | Manifest with a dev-ed package that has sources entry internal errors  | bug | **FIXED** | Ran a Level-2 (API) repro in the r4659 --test daemon. Built an env whose Project.toml has a [sources] git entry (url+rev) for BaseBenchmarks and whose Manifest.toml has a dev/path-tracked entry pointing at a nonexistent directory, then call… — _test:_ In test/execution.jl (or test/public_api.jl), add a case: write a Project.toml with a [sources] git entry for a dep plus… |
| 4655 | [doc] What distinguishes a project's `Project.toml` from a package's? | docs | SKIP | Documentation-clarification request about project vs package fields; no concrete reproduci |
| 4654 | adding a different version of a pinned package fails silently | bug | **FIXED** | Ran plan-level repro (scratchpad/r4654.jl) on the offline Example fixture via jld --test daemon: add Example -> v0.5.1 pinned=false; pin -> v0.5.1 pinned=true; then plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.0")]) ret… — _test:_ In test/pins.jl, build a manifest with Example pinned at 0.5.1 (using the existing pin_env helper with version="0.5.1",… |
| 4653 | Consistency check for Julia depot | feature | SKIP | Feature request for a depot consistency/verification command |
| 4650 | `ERROR: AssertionError: !(entry.tree_hash !== nothing && entry.path != | bug | **FIXED** | Ran a Level-1 plan-level repro in the r4650 --test daemon: plan_add Example 0.5.1 (registry-tracked, tree_hash=222..2, path=nothing), then plan_develop on a synthetic local Example copy, then write_environment + reload. Output: "after dev:… — _test:_ In test/planning.jl: plan_add Example (registry-tracked), then plan_develop a local path copy, write_environment + reloa… |
| 4645 | Provide an entrypoint to programmatically determine if a project does  | feature | SKIP | Feature request for a programmatic 'is environment synchronized' status API |
| 4644 | Adding dependencies to a dev package doesn't quite work. | bug | **FIXED** | Ran a Level 1 plan-level repro on the r4644 --test daemon (script: /private/tmp/.../scratchpad/repro4644.jl). Steps: (1) created a synthetic local dev package Foo with NO deps; (2) plan_develop'd it into an empty global-like env and wrote/r… — _test:_ Add to test/ops.jl (which already sets up local dev packages + plan_develop + plan_resolve against the Example fixture):… |
| 4637 | Pkg "strict" mode for well-behaved `[compat]` + precompilation | rfc | SKIP | Design/RFC proposal for a strict environment mode |
| 4636 | Relative local package paths added through symlinks are not preserved | bug | **FIXED** | Live Level-1 offline repro in the r4636 test daemon. Setup: real package at dir/store/MyPkg with its Project.toml, plus a project-root relative symlink env/packages/MyPkg -> ../../store/MyPkg (islink=true, isdir=true through the link). Ran… — _test:_ In test/planning.jl (which already has plan_develop/[sources] testsets, e.g. around line 130-167), add a testset: create… |
| 4624 | Resolve not working as intended | feature | SKIP | Feature request for a 'relaxed' resolve that keeps manifest versions where possible |
| 4622 | Adding an unregistered package to our Application Project causes `has  | bug | **FIXED** | Ran an offline repro through the jld --test daemon (r4622). Set up a synthetic mono-repo: an unregistered package `Unreg` (registry_tracked=false, a path-tracked stand-in for the URL-added package — the dead proxy blocks real URLs, and Vibe… — _test:_ Add a case to test/planning.jl: build a tempdir env, plan_develop an unregistered synthetic package U (registry_tracked=… |
| 4552 | Pkg.develop, ]dev — Repo Clone Fails — Using GitHub CLI HTTPS Credenti | bug | SKIP | Credential/support issue rooted in LibGit2; environment/credential-dependent, not plausibl |
| 4216 | Feature request: allow a more general use of `[sources]` for dependenc | feature | SKIP | Feature request to honor [sources] when the package is used as a dependency |
| 3925 | install packages based on the state of the registry at some date | feature | SKIP | Feature request to resolve/install against a registry snapshot at a given date |
| 3741 | Pkg.rm should be able to remove weakdeps and extras | feature | SKIP | Enhancement request to let rm remove weakdeps/extras entries |
| 3171 | Support packages that use git lfs | feature | SKIP | Feature request to support git-lfs cloning of packages |
| 1859 | Feature request: start recording SHA-256 tree hashes in registries | feature | SKIP | Feature request to record SHA-256 tree hashes in registries |
| 871 | Equivalent of old Pkg.dependents (reverse dependencies) | feature | SKIP | Feature request for a reverse-dependency query API |

## Page 3

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 4610 | Backport label cleanup didn't run on 1.12 backports PR merge | other | SKIP | Repo GitHub Actions/CI workflow issue, not package-manager behavior |
| 4603 | `projects` autocompletion for test using `[workspace]` | feature | SKIP | Requests tab-completion of workspace projects and running tests for all projects; enhancem |
| 4600 | Adding to doc a workflow for using Julia package manager | docs | SKIP | Suggestion to add workflow diagrams to documentation |
| 4599 | Discrepancy between artifacts installation interface when downloading  | bug | **FIXED** | Pkg#4599 reports that on-demand (lazy) artifact downloads use a different install/progress interface than regular installs. In real Pkg this is structural: the lazy path (src/Artifacts.jl `ensure_artifact_installed` -> `download_artifact`,… — _test:_ In test/artifacts.jl, extend the "VibePkg.Artifacts (lazy on demand)" testset (or add a new one) to assert interface par… |
| 4590 | Incompatible revisions passing compilation. | bug | **FIXED** | Ran a Level-1 workspace repro in VibePkg (jld --test daemon). Setup: root Project.toml is a [workspace] with member `sub`; root [sources] Foo = {url, rev="v1.9.0"}; shared root Manifest.toml has Foo repo-tracked at version=1.9.0 / repo-rev=… — _test:_ Add a testset to test/workspaces.jl: build a workspace where the root and a member declare conflicting [sources] rev for… |
| 4588 | MethodError: no method matching project_rel_path(::Pkg.Types.EnvCache, | bug | **FIXED** | Ran a Level-2 API repro (/private/tmp/.../scratchpad/r4588.jl) on the offline fixture: a synthetic local package `TestModule` in root/deps/TestModule, referenced from root/env/Project.toml via `[sources] TestModule = {path = ...}`, then cal… — _test:_ In test/public_api.jl, using the with_api_env pattern: create a project whose only dep is a synthetic local package decl… |
| 4587 | Breaking change: cannot develop app with relative paths in Julia 1.12. | bug | **FIXED** | Ran the MWE against VibePkg's daemon: created a synthetic package "Runic" (Project.toml at root with a [apps] runic={} section + @main entry), cd'd into the package dir, and called AppsOps.app_develop(Config(depots), RegistryInstance[], "."… — _test:_ Already covered: test/apps.jl testset "apps: develop pwd" (lines 516-552, tagged Pkg.jl#4480) does exactly this — cd(pkg… |
| 4586 | ERROR: MethodError: no method matching normpath(::Nothing) | bug | **FIXED** | Ran repro in the r4586 daemon: workspace with a URL sources entry, then rm and write_environment succeeded with no normpath error. sync_sources only calls rebase_path when path is not nothing. — _test:_ Add a test in test/workspaces.jl that runs plan_rm then write_environment on a workspace member with a URL sources entry… |
| 4583 | Feature request: Display `y/n` package installation prompt for `import | feature | SKIP | Feature request to offer registry install prompt when no registries present |
| 4580 | `pkg> instantiate` does not respect `JULIA_PKG_OFFLINE=1` | bug | **PERSISTS** | Ran an API-level (Level 2) repro in the r4580 test daemon. Built an env with a path-tracked synthetic dev package "ArtiPkg" whose Artifacts.toml declares a non-lazy, not-installed artifact `myart` (git-tree-sha1 all-zeros) with a download s… — _test:_ In test/artifacts.jl: create a package with a non-lazy artifact whose git-tree-sha1 is not installed and whose only sour… |
| 4579 | `pkg> registry update` does not respect `JULIA_PKG_OFFLINE=1` | bug | **PERSISTS** | Ran an offline repro in the --test daemon (LocalPkgServer.isolate!). Set JULIA_PKG_OFFLINE=1 (API.is_offline()==true) and JULIA_PKG_SERVER=http://127.0.0.1:9, built make_test_registry(depot) and promoted TestRegistry to an unpacked server-i… — _test:_ In test/registry_ops.jl (which already exercises update_registries! and the /registries endpoint, e.g. lines 264-270, 55… |
| 4573 | Inconsistent example of version conflicts | docs | SKIP | Documentation example inconsistency in wording/package names |
| 4557 | git based registry fails to update | bug | **FIXED** | Ran a controlled offline repro in the --test daemon: built a local upstream git registry, cloned it, advanced upstream with new commits, then called VibePkg.Registries.update_git_registry!. Full clone (which is exactly what VibePkg creates)… — _test:_ In test/git.jl (or a registry-update test file), add a test that: creates a local upstream git repo with a Registry.toml… |
| 4553 | uncompress_registry: Cannot open the file as archive | bug | **PERSISTS** | Ran VibePkg.Fetch.uncompress_registry in the r4553 daemon against a General.tar.gz reached through a `..`+symlink path that mis-resolves lexically (real file at dir2/General.tar.gz; symlink dir1/mylink -> dir2/sub; path = dir1/mylink/../Gen… — _test:_ In test/registries.jl: build a small General.tar.gz, create a symlink so that a `..`-containing path lexically collapses… |
| 4527 | Tweak warning about local directories | feature | SKIP | Request to make the local-directory warning case-sensitive / smarter; enhancement not a co |
| 4506 | State in documentation when certain `Project.toml` features were added | docs | SKIP | Documentation request to add version-introduced notes |
| 4424 | Automatic compat for stdlibs is problematic | bug | **FIXED** | Ran two offline repros on the r4424 --test daemon (Julia 1.12.6) using the real Random stdlib. (1) On a package project (name+uuid), VibePkg.add("Random") DOES still write [compat] Random = "1.11.0" ("Compat entries added for Random") — aut… — _test:_ In test/planning.jl (Level-1 plan level, make_test_registry available): build an Environment whose Project has a Random… |
| 4247 | Support authentication when downloading files (e.g. artifacts) | feature | SKIP | Enhancement request to support auth tokens for private artifact downloads |
| 4129 | Automatic `[compat]` bounds added on `add` breaks some workflows | feature | SKIP | Design/workflow request to make auto-compat-on-add optional for monorepos |
| 4051 | Pkg hang in CI while building packages | bug | SKIP | Reporter cannot reproduce; rare non-deterministic precompile/build hang with no MWE |
| 3558 | "Edit on GitHub" button on REPL docs results in a 404 | docs | SKIP | Documentation site link/build issue, not package-manager behavior |
| 3027 | [Feature request] option to automatically install a package when using | feature | SKIP | Feature request to auto-install on `using` bypassing the prompt |
| 3005 | Docs for `up` is wrong | docs | SKIP | Primarily about incorrect/divergent documentation wording for `up` |
| 1233 | Proposal for "sub-projects". | rfc | SKIP | Design proposal/discussion for a new sub-projects feature |

## Page 4

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 4502 | Download packages and artifacts concurrently with each other | feature | SKIP | Performance enhancement request for concurrent downloads. |
| 4488 | Resolver errors in workspaces should make source of compat issues clea | feature | SKIP | Request to improve resolver error message wording, not wrong behavior. |
| 4413 | undo: no more states left | bug | **FIXED** | Ran an offline API-level repro (jld --test): fresh session (empty!(UNDO_STACKS)), project requiring Example with a stale/empty Manifest, using the local pkg-server registry. Sequence instantiate -> resolve -> undo -> redo. instantiate error… — _test:_ In test/public_api.jl (which already has an undo/redo testset at ~lines 181-219 that seeds the stack via manual API.reco… |
| 4410 | Make `]test` use `--depwarn=yes` | feature | SKIP | Enhancement to change default flag for ]test. |
| 4409 | workspace doesn't respect weakdeps of projects | bug | **FIXED** | Ran two offline reproductions via the r4409 --test daemon (Level-1 plan, offline Example fixture from make_test_registry). Variant A: workspace root project declares [weakdeps] Example + [extensions] RootExampleExt="Example" with [workspace… — _test:_ Add a @testset to test/workspaces.jl: build a workspace where a member Project.toml declares [weakdeps] Example = EXAMPL… |
| 4408 | Use Manifest-v*.toml by default | feature | SKIP | Requests changing default manifest naming to versioned files. |
| 4390 | `st` should show if package is precompiled yet or not | feature | SKIP | Enhancement to display precompilation state in status output. |
| 4367 | Better error message for invalid manifest | feature | SKIP | Asks for clearer error text ('Invalid Manifest') rather than reporting wrong behavior. |
| 4356 | Calling `Pkg.test()` in a workspace changes the `Project.toml` | bug | **FIXED** | Built a synthetic offline workspace: pkg A (workspace root) depends on sibling workspace member B with NO [sources] entry; A/test is a workspace member. Ran the real TestOps.test!(env, regs, cfg, UUID(A)) via the jld --test daemon. Output:… — _test:_ In test/workspaces.jl: construct a workspace where a member package A depends on sibling member B (path-tracked in the s… |
| 3939 | Improvements to registry status outputs | feature | SKIP | Enhancement requests for registry status/up warnings, framed as improvements. |
| 3824 | replace 7z with gzip | feature | SKIP | Security/refactor request to swap 7z for gzip, not a bug in current behavior. |
| 1928 | Feature Request: multi-package .git repositories | rfc | SKIP | Design proposal for multi-package repositories and registration. |
| 1743 | Refer to binary files in package directory as artifact for relocatable | feature | SKIP | Proposes new artifact-mechanism capability. |
| 1683 | advice for recovering from corrupted depot in the manual | docs | SKIP | Request for a manual section on recovering a corrupted depot. |
| 911 | SSH auth keys, just very painful outside of ssh-agent. | bug | SKIP | Meta-issue collecting many SSH/libssh/libgit2 problems, not a single cleanly reproducible/ |

## Page 5

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 4351 | `Pkg.resolve()` not picking up changes in nested `[sources]` | bug | **PERSISTS** | Ran two offline repros with real local git repos in the r4351 --test daemon (isolate!). NESTED case (scratchpad/repro4351.jl): root env deps a dev'd path-tracked PkgA whose OWN [sources] pins dep PkgB to a local git rev. resolve#1 -> manife… — _test:_ In test/planning.jl (already tests plan_resolve + [sources]): build a local git repo PkgB with two commits (rev1/rev2, d… |
| 4349 | `force_latest_compatible_version` does not respect julia version compa | bug | **FIXED** | Ran a Level-1 offline repro in the r4349 --test daemon (Julia 1.12.6). Built a synthetic registry with package Foo: v1.0.0 (julia="1.6-1", compatible) and v2.0.0 (julia="99", never resolvable). A project depending on Foo with compat "1, 2"… — _test:_ Already covered: test/buildtest.jl:500 `@testset "test: force_latest_compat"` (tagged # Pkg.jl#4349) uses make_flc_regis… |
| 4249 | Indicate which project(s) are active when emitting Pkg errors | feature | SKIP | Feature request (labeled) to add project context to Pkg error messages. |
| 4244 | Registry update failures should throw or return status | feature | SKIP | Requests API change so Registry.update() throws/returns status on failure; currently only  |
| 4237 | Automatic addition to `[sources]` does not play well with workspaces | bug | **FIXED** | Ran a Level 1 offline repro (jld --test daemon). Set up parent/Project.toml with [workspace] projects=["sub"], and parent/sub/Project.toml as a member with pre-existing [deps] and [sources] (Vendored = {path="../vendor/Vendored"}). load_env… — _test:_ In test/workspaces.jl, add a case: load a workspace member whose Project.toml has a pre-existing [sources] entry (e.g. V… |
| 4235 | Default `test` to `allow_reresolve=false` when a manifest is checked i | feature | SKIP | Proposes changing a default based on git-tracked manifest detection; design change, not a  |
| 4221 | [Workspaces] resolve does not report anything | bug | **FIXED** | Ran the MWE offline (Example as Documenter stand-in): root Project.toml with [workspace] projects=["docs"] and NO top-level deps; docs/Project.toml deps on Example (compat 0.5). Level 1: plan_resolve populated the shared workspace manifest… — _test:_ In test/workspaces.jl: create a temp workspace root with empty deps and a `docs` member depending on Example; run plan_r… |
| 4212 | `free --all` fails with confusing message | bug | **FIXED** | Ran an API-level repro against the offline pkg-server General fixture (scratchpad/r4212c.jl). Two scenarios of `VibePkg.free(PackageSpec[]; all_pkgs=true)`: (A) a pinned registry-tracked Example unpinned in place (v0.5.1 pinned => v0.5.1) a… — _test:_ In test/ops.jl (alongside the existing plan_free / #4686 testsets), add a testset covering the all_pkgs scope: build a m… |
| 4157 | Changing a source in `Project.toml` doesn't trigger a full resolution  | bug | **FIXED** | Ran a Level-1 plan-level repro in a fresh `--test` daemon against a synthetic local git repo (offline, no network). Built package `Foo` with two commits producing distinct trees: revA=df7c0d7 (tree 582fa2e8...) and revB=2b4e1c0d (tree 9b966… — _test:_ Add to test/planning.jl alongside the existing "[sources]" testsets (around line 130). Create a local git repo for a syn… |
| 4089 | Allow simultaneous `path` and `url` under `[sources]` with `path`-prio | feature | SKIP | Requests a new capability (path-then-url fallback in [sources]), not a bug. |
| 3963 | Add back support for full VersionNumbers to the resolver | rfc | SKIP | Design/enhancement to restore prerelease/build-metadata support in the resolver. |
| 3684 | Pkg.test(force_latest_compatible_version=true) errors with unregistere | bug | **FIXED** | Ran TestOps.force_latest_compat (VibePkg's analogue of Pkg's apply_force_latest_compatible_version!) offline via `jld --test` on a project with registered dep Example + unregistered dep FooDev (UUID not in offline registry) carrying a [comp… — _test:_ test/buildtest.jl already has @testset "test: force_latest_compat" (lines 500-520) asserting an unregistered dep WITHOUT… |
| 3644 | Since v1.10 --warn-overtype will be overwritten to yes in Pkg.test() | bug | **PERSISTS** | src/TestOps.jl:182 in test_subprocess_flags hardcodes `--warn-overwrite=yes` instead of mirroring Base.JLOptions().warn_overwrite like it does for depwarn/inline/startup-file/track-allocation. Base.JLOptions() DOES have a warn_overwrite fie… — _test:_ No test currently exercises test_subprocess_flags. Add a unit test (in test/buildtest.jl or a new test/testops.jl includ… |
| 3641 | Dependencies of an Extension | feature | SKIP | Feature request (labeled) to let package extensions declare their own dependencies. |
| 3269 | Support for "raw" artifacts (that are not extracted) | bug | **PERSISTS** | Ran a live repro through VibePkg's real extraction path (jld --test daemon, script /private/tmp/.../scratchpad/r3269.jl). Created a source file with mode -rw-r----- (0o640), tarred it with system `tar` (header confirmed preserving 0o640: `t… — _test:_ In test/artifacts.jl: build a tarball with system `tar` containing a file chmod'd to 0o640, call VibePkg.Fetch.unpack(ta… |
| 3185 | `stdin` closed / unavailable during testing | bug | **FIXED** | Ran a real repro through the r3185 daemon (LocalPkgServer.isolate!()). Built a synthetic local dev package "StdinProbe" whose test/runtests.jl asserts stdin availability and reads a line: `@test isopen(stdin)`, `@test isreadable(stdin)`, `l… — _test:_ In test/public_api.jl, alongside the existing "test op: Cmd args and allow_reresolve" @testset (which already develops a… |
| 2701 | Cloning repo using Pkg.add(url) results in a non-descriptive error | feature | SKIP | Requests a more descriptive error message for HTTP 403 (password auth removed); error itse |
| 2524 | Allow compat specifiers in Pkg.add | feature | SKIP | Requests allowing '^'/compat syntax in PackageSpec version; new capability, not a bug. |
| 2311 | add some way to show git commit hash when tracking branch | feature | SKIP | Requests new functionality to display the tracked commit hash. |
| 2153 | client-side pkg server selection | rfc | SKIP | Design proposal for client-side pkg server probing/selection; no observable bug. |

## Page 6

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 4189 | `activate` in the wrong current working directory | feature | SKIP | Feature request to resolve env by package name without a path. |
| 4184 | Registries are decompressed and unpacked twice when they are updated | other | SKIP | Internal efficiency/wastefulness note, not observable wrong behavior. |
| 4179 | Add `julia` compat entry automatically | feature | SKIP | Feature request to auto-add a julia compat entry. |
| 4164 | Are `dependencies` and `project` experimental? | question | SKIP | Question about API stabilization status. |
| 4149 | Treat julia compatibility as a normal package | rfc | SKIP | Internal resolver redesign proposal, not a bug. |
| 4131 | JLLs in the sysimage confuse Pkg.update when their Project.toml versio | bug | **PERSISTS** | Ran a Level-1 (plan-level) repro in the r4131 daemon using the offline Example fixture. src/Planning.jl:620-631 filters the resolver candidate set by `v != pkgorigin.version` for any package in the sysimage, with NO build-number normalizati… — _test:_ In test/planning.jl, add a test that: (1) make_test_registry + plan_add Example (resolves 0.5.1) and write_environment;… |
| 4125 | `add` should prefer versions of any already-loaded deps, if compatible | feature | SKIP | Feature request to bias resolution toward loaded versions. |
| 4120 | Bundled compile cache modified if writeable | bug | SKIP | Bug is in Base loading/precompile cache handling, not package-manager operations. |
| 4116 | Significant GC collection time in Pkg.add (and other performance relat | other | SKIP | Performance/allocation concern, not a correctness bug. |
| 4108 | `package` shown in autocompletion list of pkg mode but not a recognize | bug | **FIXED** | Ran via r4108 daemon. completions_for("") returns 26 entries (activate, add, app, build, compat, dev, develop, free, gc, generate, help, instantiate, pin, precompile, redo, registry, remove, resolve, rm, st, status, test, undo, up, update,… — _test:_ In test/replmode.jl, inside the existing completions @testset (~line 249), add invariant assertions: @test "package" ∉ R… |
| 4105 | Pkg docs: `Pkg.resolve` differs from `pkg> resolve` | docs | SKIP | Docstring wording improvement request. |
| 4103 | is_manifest_current doesn't detect changes to deved packages | bug | **PERSISTS** | Ran a Level-1 offline repro in the r4103 --test daemon (script: /private/tmp/.../scratchpad/repro4103.jl). Steps: created a synthetic local dev package DevPkg (no deps), `plan_develop`'d it into a fresh env, `plan_resolve`'d, wrote and relo… — _test:_ Add to test/envfiles.jl (or test/ops.jl) an offline testset using make_test_registry/isolate!: develop a synthetic local… |
| 4097 | compat errors should clearly state where each constraint comes from | feature | SKIP | Error-message clarity enhancement request. |
| 4085 | `add` vs `dev` for local path | question | SKIP | Question/proposal about add vs dev semantics for local paths. |
| 4082 | `Pkg.dependencies()` triggers `write_env_usage` | bug | **PERSISTS** | Ran an offline Level-2 repro in the r4082 test daemon: synthetic env (Project.toml + Manifest.toml with Example 0.5.1 on disk), isolated depot, deleted any pre-existing usage log, then called VibePkg.dependencies(). Observed: "usage exists… — _test:_ In test/public_api.jl, add a test: under an isolated depot, create a synthetic env with a Manifest.toml on disk, activat… |
| 4069 | Add automatically compat entry when adding a dependency to non-package | feature | SKIP | Enhancement request to auto-add compat in non-package envs. |
| 4060 | set compat version for specific package for whole environment | feature | SKIP | Feature request for environment-wide per-package compat override. |
| 4009 | Preserve option for `up` | feature | SKIP | Feature request for a preserve mode on update. |
| 3905 | Make `PRESERVE_TIERED_INSTALLED` the default | feature | SKIP | Enhancement request to change default preserve behavior. |
| 3667 | The CompatHelper functionality (`force_latest_compatible_version`) sho | feature | SKIP | Feature request to extend CompatHelper behavior to weakdeps. |
| 3112 | `Pkg.add` with a `ctx` operates in-place on the arguments without noti | bug | **FIXED** | Ran a plan-level repro in the r3112 daemon (LocalPkgServer.isolate!, make_test_registry with Example 0.5.1). Built req=PackageRequest("Example",nothing,"0.5.1"), ran plan_add(env0,regs,Config(depots),[req]). Output: BEFORE uuid=nothing vers… — _test:_ In test/planning.jl: build req=PackageRequest("Example",nothing,"0.5.1") and env0=load_environment(...); run plan_add(en… |
| 3080 | Merge Pkg docs fully into julia docs | docs | SKIP | Documentation hosting/organization request. |
| 2688 | A way to list environments | feature | SKIP | Feature request for an env-listing command. |
| 2640 | API to activate first parent dir with Project.toml | feature | SKIP | Feature request for search_parents option on activate. |
| 1415 | Make `activate` instantiate by default | feature | SKIP | Speculative design/feature request to auto-instantiate on activate. |

## Page 7

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 4074 | dev gives confusing error on stdlibs | feature | SKIP | Asks to improve the (correct) error-message wording when dev'ing an stdlib by name; error  |
| 4068 | When dev'ing a cloned repository Pkg.build is not triggered | bug | **PERSISTS** | Ran a Level-2 API repro in the r4068 --test daemon: created a synthetic local dev package BuildMe with deps/build.jl that writes a sentinel file deps/BUILD_RAN, set DEPOT_PATH/ACTIVE_PROJECT per with_api_env. Output: "sentinel exi… |
| 4063 | ArgumentError when adding packages with "+" in version | bug | **FIXED** | Ran plan_add offline against the Example fixture. plan_add(env, regs, cfg, [PackageRequest("Example", nothing, "2024.2.0+0")]) yields `VibePkg.Errors.PkgError :: invalid version specifier "2024.2.0+0" for package `Example``; same… |
| 4059 | Show manifest julia version in `status` | feature | SKIP | Enhancement to display the manifest's julia version inside `status` output. |
| 4043 | Prioritize higher versions of direct dependencies over indirect depend | rfc | SKIP | Resolver design proposal to weight direct deps over transitive deps; no incorrect behavior |
| 4021 | Intermittent failure in Julia's CI `Being precompiled by another proce | bug | SKIP | Flaky test in Pkg's own CI suite; intermittent, no deterministic user-facing MWE. |
| 4019 | Restrict the resolver to only consider the latest patch version per ma | rfc | SKIP | Resolver policy proposal to enable compat fixes via patch releases; design discussion, no  |
| 4012 | Strange output with Pkg add on 1.11.0-rc3, after "failed Task notice;  | bug | SKIP | REPLExt error-cascade producing garbage output after precompile failures; environment/REPL |
| 4006 | `ResolverError` coloring should be decided in `showerror`, not on cons | bug | **PERSISTS** | Ran a Level-1 resolver-conflict repro in the r4006 --test daemon (synthetic A/B/C graph copied from test/resolve.jl `solve`; requiring A=2 and B=1 is unsatisfiable -> VibePkg.Resolve.ResolverError). Two runs:  (1) Constructed the… |
| 3996 | Progress bar thinks displaysize width is always 80 | bug | **FIXED** | Ran show_progress via the r3996 daemon against IOContexts reporting displaysize widths 80/120/200 (with p.width raised so termwidth is the binding constraint). The rendered bar's glyph count scaled 50/90/170, proving the bar sizes… |
| 3991 | Fix devved packages actually being used when testing them | bug | **FIXED** | Ran a live Level-2 API repro in the r3991 --test daemon. Setup (all offline, tempdirs): a dev'd `Example` at path `.../ExampleDev` (Project.toml uuid 7876af07..., version 0.5.1) whose src defines a distinctive `const DEVMARKER = 4… |
| 3969 | Pkg CI does a lot of re-precompiling stdlibs | bug | SKIP | Observation about Pkg's own CI re-precompiling stdlibs (likely DEPOT_PATH overloading); no |
| 3947 | `status` can error when the RHS in `[extensions]` does not map to a we | bug | **FIXED** | Ran an API-level repro (jld --test) building the exact #3947 shape: a dev package Foo with Project.toml [deps] Test = "8dfed614-..." (a normal dep) and [extensions] TestExt = "Test" and NO [weakdeps] table. After develop+instantia… |
| 3942 | Dont overload `zero` for `VersionWeight` | other | SKIP | Internal code-cleanup request (avoid overloading Base.zero for VersionWeight); no user-fac |
| 3798 | Feature Request: Option to Exclude Non-Essential Directories on Packag | feature | SKIP | Feature request to let authors exclude test/docs/examples dirs from installs to save disk. |
| 3718 | Allow optional commit and tag metadata in Manifests and registries | feature | SKIP | Proposal to add optional git-commit/tag metadata fields to Manifest/registry format. |
| 3649 | Can we automatically run `registry update` if resolve errors with `Uns | feature | SKIP | Proposal to auto-run registry update on resolve failure; a behavior-change request, not a  |
| 3557 | Extension module is missing from the cache | bug | SKIP | Precompilation/loading warning (__precompile__(false) during precompile) surfacing from Ba |
| 3553 | Weak dep is required, but not installed message | bug | SKIP | Confusing 'required but does not seem to be installed' message on `using` a weakdep origin |
| 3549 | Make `add --weak` automatically create extension entries | feature | SKIP | Enhancement to have `add --weak` also write [extensions] entries. |
| 3389 | [Preferences] Test ignores preferences that are not explicitly listed  | feature | SKIP | Request to make `] test` respect JULIA_LOAD_PATH / propagate global preferences; a design/ |
| 3341 | is there a way to Pkg.add that doesn’t precompile the added Pkgs? | question | SKIP | Support question / request to expose an allow_autoprecomp-style kwarg on Pkg.add; not a wr |
| 2303 | Unsatisfiable requirements when changing compat versions of dependenci | bug | **PERSISTS** | Reproduced offline at plan level. Setup: synthetic dev pkg A (deps Example) developed while its compat pinned Example to =0.5.0, so the manifest recorded Example@0.5.0; then A's Project.toml compat was edited on disk to Example =… |
| 1249 | yanked packages cause resolver problems when testing | bug | **FIXED** | Ran an offline repro in the r1249 --test daemon using the Example fixture (1.0.0 is yanked). Built an env whose Project depends on Example and whose Manifest pins the yanked Example 1.0.0. Step 1 — plan_resolve (PRESERVE_ALL, the… |
| 819 | Better resolver failure messages | feature | SKIP | Labeled enhancement/resolver; asks for clearer unsatisfiable-requirements messages (e.g. s |
| 659 | Support for bare git repositories | feature | SKIP | Requests new support (auto-clone) for bare git repos or a better error; primarily a featur |

## Page 8

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 3937 | Bad resolution for SHA in manager | bug | **FIXED** | Ran a Level-1 offline repro: injected a competing registered SHA v1.6.7 into the make_test_registry fixture (tempdir only), then plan_add("SHA"). Output: registry offered only v1.6.7, but RESOLVED SHA version = 0.7.0 (the bundled… |
| 3933 | very unsound assumptions about REPL state injection | bug | SKIP | Soundness/design concern about __init__ mutating REPL state on a thread; no concrete obser |
| 3918 | `pkg> registry add https://github.com/staticfloat/General#sf/foo` does | bug | **FIXED** | Ran in isolated --test daemon: built a local git registry repo (Registry.toml with name+uuid) having a `main` and a `foo` branch, then called VibePkg.Registries.add_registry!. With the branch-qualified spec `add_registry!(depots,… |
| 3914 | REPL completions with `~` have incorrect offset | bug | **FIXED** | Ran completions_for via the r3914 daemon with a fake HOME where expanduser('~') is 57 chars longer than the typed '~'. For the path-completing command, completions_for("activate ~/jul") returned word="~/jul" (exactly equal to the… |
| 3908 | `expanduser` can fail causing a REPL error in completion | bug | **FIXED** | completions_for stays graceful on tilde inputs |
| 3907 | More direct resolver error when julia compat is a factor | feature | SKIP | Request to improve/clarify resolver error message wording when julia compat is the cause;  |
| 3902 | Pkg.test sandbox resolve merge doesn't respect JLL build numbers in ma | bug | **FIXED** | Built an offline synthetic registry with JLL package Foo_jll at build-numbered versions plus a manifest pinning Foo_jll=1.18.0+1, then ran plan_resolve (the same resolver entrypoint the test sandbox uses at src/TestOps.jl:344). Ob… |
| 3901 | Resolver errors don't show build numbers | bug | **PERSISTS** | Ran the exact resolver message-formatting path in VibePkg via the jld --test daemon. `range_compressed_versionspec([v"1.18.0+1", v"1.18.0+2"])` prints "1.18.0" (build numbers dropped, both indistinguishable); the single-version pa… |
| 3898 | Don't factor JLLs into the resolver decision when multiple update opti | feature | SKIP | Enhancement to resolver cost weighting for JLLs, a design change not an observable correct |
| 3892 | dev .. : Relative directory failing under Windows when having cd'ed wi | bug | **FIXED** | The reported bad behavior does NOT reproduce in VibePkg. Root cause of the original Pkg bug: its REPL parser `parse_package_identifier` gated `.`/`..`/path words behind `casesensitive_isdir(expanduser(word))`, which walks each pat… |
| 3891 | [workspace] Misleading printing of Manifest.toml change | bug | **FIXED** | Ran plan-level repro in the r3891 --test daemon with the offline Example fixture. Built the workspace analog: root Project.toml with [workspace] projects=["test"], a `test` member sharing the root manifest, Example path-tracked at… |
| 3880 | proposal: distinguish explicitly vs implicitly added registries | rfc | SKIP | Design proposal for explicit vs implicit registry tracking. |
| 3871 | Precompiling when using a single package causes unnecessary precompila | bug | N/A | The reported bug is in the precompilation-set/dependency-closure computation (deciding which packages get precompiled when using one package). That logic is not in VibePkg. Runtime check in the jld --test daemon: after `using Vibe… |
| 3869 | Pkg tree hash issues on linux with CIFS mounted network file server | bug | SKIP | Filesystem-specific (CIFS) tree-hash mismatch; not plausibly reproducible/checkable, repor |
| 3853 | Things get very confusing when putting the wrong name to a UUID in the | bug | **PERSISTS** | Level 1 plan-level repro on the offline Example fixture. Hand-wrote Project.toml with `ForwardDiff = "7876af07-990d-54b4-ab0e-23690620f79a"` (Example's UUID under the wrong name, analog of the report's ForwardDiff=WebIO-UUID). pla… |
| 3845 | Specifying registries needed for a project in the Project file | feature | SKIP | Design/feature discussion on declaring registries in the Project file. |
| 3808 | Make spinners spin more slowly | feature | SKIP | Feature request to make precompile spinner interval configurable. |
| 3795 | Bad resolve if different build metadata versions have different depend | bug | **PERSISTS** | Ran a plan-level repro in the r3795 daemon with a synthetic registry mirroring Wayland_jll/EpollShim_jll: Foo_jll has build-metadata versions 1.21.0+0 and 1.21.0+1; its Deps.toml keys deps on major.minor.patch (["1.21.0"] -> Bar_j… |
| 3781 | Move `Unregistered.jl` used in testing to `JuliaLang` org? | other | SKIP | Test-infrastructure hygiene request to relocate a test package. |
| 3780 | Add back recurring precompile tests | other | SKIP | Test-infrastructure task to restore reverted precompile tests. |
| 3774 | Base.runtests(["Pkg"]) hangs | bug | SKIP | Test-harness hang: Pkg tests prompt for git credentials when run single-worker with a tty  |
| 3503 | switching between pkg servers with different registries | rfc | SKIP | Multi-case proposal/discussion about pkg-server registry handling; mixes enhancement and d |
| 3453 | Simultaneous writing to manifest_usage on NFS crashes Julia | bug | SKIP | NFS-specific IO race in usage-log pidfile; not plausibly reproducible/checkable without an |
| 3146 | Feature request: function to precompile all projects | feature | SKIP | Explicit feature request for a precompile-all-projects function. |
| 3044 | LibGit2 Clone Fails: "Unable to exchange encryption keys" | bug | SKIP | SSH/libssh2 environment-specific clone failure against a private GitLab; not plausibly che |
| 2679 | stop using libgit2 | rfc | SKIP | Design/strategy discussion to replace libgit2 with CLI git. |
| 2549 | Unable to install JLL package from private repo | bug | SKIP | Private-repo/auth-specific artifact download failure; requires private credentials, not pl |
| 1967 | proposal for package tags and descriptions in registry | feature | SKIP | Feature proposal to add tags/description fields to registry and Project.toml. |
| 1062 | Introduce `down` as opposite of `up` | feature | SKIP | Feature request for a downgrade-to-oldest-compatible command. |

## Page 9

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 3726 | Edit links broken for files in the main Julia repo | docs | SKIP | Documentation edit links point to the wrong repo location. |
| 3717 | Allow passing a list of root manifests to Pkg.gc() | feature | SKIP | Feature request to gc against a supplied set of manifests and mark artifacts as used. |
| 3713 | Resolve should notice when you are being version bound to require some | feature | SKIP | Request to improve the unsatisfiable-requirements error message to suggest updating the re |
| 3686 | Allow comments in `[compat]` entries | feature | SKIP | Feature request for inline comment syntax in compat bounds. |
| 3682 | Suggestion: Allow for SubString{String} to be passed to `RegistrySpec` | feature | SKIP | API enhancement to accept AbstractString in the RegistrySpec constructor. |
| 3675 | Include system image packages in Pkg.status output | feature | SKIP | Feature request to show sysimage-provided packages in status. |
| 3629 | "Warning: The call to compilecache failed to create a usable precompil | bug | N/A | The reported warning ("The call to compilecache failed to create a usable precompiled cache file...") is emitted by Julia Base's loading/compilecache machinery, not by VibePkg. Grepping src/ for compilecache / "usable precompiled"… |
| 3628 | Standard libraries tagged in package conflict reports | feature | SKIP | Request that stdlibs (fixed to 0.0.0) be presented more clearly in resolver conflict repor |
| 3622 | precompile verbose output | feature | SKIP | Feature request for a verbose/debug mode for precompile. |
| 3612 | Feature request: different dependencies on different operating systems | feature | SKIP | Feature request for OS-specific dependency declarations. |
| 3611 | GitHub actions Pkg checkout of private dep hangs on Windows | bug | N/A | Read /Users/kc/JuliaPkgs/Pkg.jl/VibePkg/src/Git.jl: clone() (L107-160) and fetch() (L176-222) set credentials=LibGit2.CachedCredentials() and call LibGit2.clone/LibGit2.fetch with default callbacks. VibePkg never builds a LibGit2.… |
| 3609 | If a test segfaults, we don't print the test process's stacktrace | bug | **FIXED** | Ran a live repro with the VibePkg daemon (Level 2 API). Created a synthetic local dev package "Segfaulter" whose test/runtests.jl does `unsafe_load(Ptr{Int}(10))` (the exact MWE from the report), `VibePkg.develop(; path=...)`'d it… |
| 3608 | No easy way to see all package versions resolved in environment stack | feature | SKIP | Feature request for an effective/combined manifest across an environment stack. |
| 3607 | `--code-coverage` path in `Base.julia_cmd()` is shadowed if `coverage= | docs | SKIP | Labeled documentation; primary ask is clarifying that coverage may be a String/path, cover |
| 3588 | User can acidentially add external version of stdlib to Manifest | bug | **FIXED** | Level-1 offline repro (repro3588.jl, --name=r3588): built a synthetic local package claiming bundled stdlib Random's UUID+name at external version 99.9.0 (offline analog of `add <url to Statistics.jl>`), then plan_develop -> write… |
| 3569 | Move the "Creating Packages" section of the documentation to the Julia | docs | SKIP | Documentation reorganization request. |
| 3545 | Cannot `pkg> dev .` a package with extensions inside a shared environm | bug | **FIXED** | Reproduced offline via the r3545 --test daemon (Level 1 plan_develop). Built a synthetic local package Foo with [weakdeps] Example + [extensions] FooExt="Example" and ran plan_develop into three environment shapes, matching `pkg>… |
| 3518 | `resolve` complains if a dependency is not instantiated | bug | **FIXED** | Ran a Level-1 offline repro in the VibePkg daemon: built a manifest containing Example 0.5.1 via plan_add + write_environment, reloaded the env with NOTHING installed on disk (depot packages dir empty), then called plan_resolve. O… |
| 3412 | `]update` always downloads registries, no matter the options | bug | **FIXED** | Ran two offline repros in the --test daemon against a server-backed packed "General" registry (General.toml stub + General.tar.gz) installed from the local pkg server, mirroring ~/.julia/registries/General. (1) Direct: update_regi… |
| 3347 | Ability to easily repeatedly add a fixed group of packages | feature | SKIP | Feature request to add all packages from a named environment at once. |
| 3339 | `status --outdated` did not tell me why I couldn't update my package | feature | SKIP | Request for better diagnostics; `--outdated` output is technically accurate (newer version |
| 621 | Introduce `env` command to manage environments | feature | SKIP | Feature request for an env-listing command and activate autocompletion. |

## Page 10

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 3562 | `compat` tab completion should return a string of existing versions | bug | **FIXED** | Ran completions_for in VibePkg's --test daemon against an active project with compat `Example = "0.5, 0.5.1, 1.0"`. Results: completions_for("compat ")=["Example"], completions_for("compat Example ")=["Example"] (re-offers depende… |
| 3555 | `instantiate` on a Project without a `Manifest.toml` insists on reupda | bug | **PERSISTS** | Ran an offline Level-2 repro in the --test daemon (synthetic local dev package; no network). Set VibePkg.API.UPDATED_REGISTRY_THIS_SESSION[]=true, developed a local path package (creates Project+Manifest), then spied on VibePkg.Re… |
| 3551 | Develop can create an incorrect Manifest; moves `weakdeps` to `deps` | bug | **FIXED** | Ran VibePkg.develop(path=foodir) on a synthetic local dev package Foo declaring [weakdeps] Example + [extensions] FooExt="Example", in an isolated offline env (Level 2 full API). Develop succeeded with NO resolve error. Written Ma… |
| 3550 | Deadlock in freeing `dev`ed packages after fetching upstream | bug | **FIXED** | Reproduced the exact scenario at plan-level in the VibePkg test daemon using the offline `Example` fixture. Setup: project with dep `Example` @0.5.1 and project `[compat] Example = "0.5"`; dev'd `Example` to a synthetic local path… |
| 3546 | `free` should call `registry up` if needed | feature | SKIP | Enhancement request to have free auto-run registry up when compat is unsatisfiable. |
| 3541 | Unclear `resolve` behavior when upgrading a `weakdep` to hard `dep` | bug | **FIXED** | Ran a Level 1 plan-level repro in the r3541 test daemon. Built a synthetic project "MyPkg" with Example ONLY in [weakdeps] (deps empty), against the offline make_test_registry (Example 0.5.0/0.5.1). Then `plan_add(env0, regs, cfg,… |
| 3532 | Contextual test dependencies | feature | SKIP | Labeled feature request for conditionally-required test dependencies. |
| 3527 | Flag --preserve=all still allows upgrading a dependency of a package t | bug | **FIXED** | Ran a plan-level repro in VibePkg (jld --test, synthetic 2-package fixture registry, offline). Scenario mirroring #3527: App@1.0.0 depends on Lib (1-2); Lib@1.0.0 julia="1.6-999", Lib@2.0.0 julia="1.99-999" (requires a julia newer… |
| 3512 | Support multiple APIs and version numbers per package | rfc | SKIP | Labeled feature request / design proposal for multiple version numbers per package. |
| 3508 | Store project hash for dev'd deps | feature | SKIP | Enhancement request to detect stale dev'd dependency projects via stored hashes. |
| 3505 | Test-only artifacts | feature | SKIP | Feature request for artifacts installed by Pkg.test but not instantiate; current error is  |
| 3499 | Improving the docs for extensions | docs | SKIP | Documentation-clarification request for extensions. |
| 3497 | Feature request: `activate --cd Foo` to activate Foo and change workin | feature | SKIP | Labeled feature request for a new activate flag. |
| 3496 | ]up Foo downloads registry even if Foo is not registered | bug | **PERSISTS** | Ran an API-level repro in the --test daemon (isolated depot, dead proxy, no pkg server). Setup: make_test_registry converted into a git-backed registry with a dead remote (http://127.0.0.1:9/TestRegistry.git); an env whose ONLY de… |
| 3494 | Сompat does not include DEV version | bug | **PERSISTS** | Ran in the r3494 --test daemon calling VibePkg.Versions.semver_spec directly (the [compat] parser; confirmed as the compat load path at src/Planning.jl:1720-1721, which throws pkgerror("invalid version specifier ...") when semver_… |
| 3482 | Remove stacktrace pointing to Pkg when a Pkg.test fails | feature | SKIP | Output/UX request to suppress an internal backtrace when a tested package errors; not wron |
| 3471 | Clarify `up` documentation | docs | SKIP | Labeled documentation issue; help text says up updates registries but it also updates pack |
| 3463 | Registries with the same name in non-primary depots not being reported | bug | **FIXED** | Ran a repro via the r3463 --test daemon: wrote an identical make_test_registry (name "TestRegistry", uuid 23338594-aafe-5451-b93e-139f81909106) into two separate depots d1 and d2, then queried both the discovery layer and the stat… |
| 3458 | Disallow certain Pkg operations during precompilation | feature | SKIP | Hardening/enhancement request to guard against recursive precompilation (fork bomb). |
| 3434 | Bug in Pkg.PackageSpec: breaks when default branch of a repo changes | bug | **FIXED** | Ran materialize_repo_package! against a synthetic local git repo whose ONLY branch is `main` (created via `git init -b main`; `git branch` output confirmed "* main", no master). Results: rev=nothing (default branch) => OK name=MyP… |
| 3420 | Pkg.Registry.rm ERROR: MethodError: no method matching rm(::SubString{ | bug | **PERSISTS** | Ran in the r3420 --test daemon: `VibePkg.Registry.rm(SubString("General", 1))` throws `MethodError: no method matching rm(::SubString{String})` — identical to the report. `methods(VibePkg.Registry.rm)` shows only `rm(specs::String… |
| 3417 | Official API for `resolve()` | feature | SKIP | Labeled speculative feature request for a public resolve() endpoint. |
| 3411 | `PkgId` method error when adding by URL and specifying the UUID | bug | **FIXED** | Ran the exact MWE shape offline via the daemon using LocalPkgServer.ensure!()'s local Example git repo: VibePkg.add([PackageSpec(url=<local Example.jl git repo>, uuid="7876af07-990d-54b4-ab0e-23690620f79a")]). The spec had name=no… |
| 3225 | Feature request: loading dependencies and/or artifacts from package ho | feature | SKIP | Feature request to allow package hooks to load deps/lazy artifacts. |
| 3030 | Cannot dev private repos: libgit2 uses protocol phased out by Github t | bug | SKIP | Root cause is libgit2/SSH RSA-SHA1 deprecation external to Pkg; not reproducible in packag |
| 2764 | Lazy artifact without unpacking (non-tarball) | feature | SKIP | Feature request for an `unpack` keyword / non-tarball lazy artifacts. |
| 2393 | Dependency confusion between internal registries and General | rfc | SKIP | Security design discussion about shadowing across registries; proposal, not a concrete cod |
| 1860 | Tree Hash mismatch Error on Pkg installation | bug | SKIP | git-tree-sha1 mismatch only manifests on NFS depots; a filesystem-timing race not plausibl |

## Page 11

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 3405 | Feature request: `]test --quiet` | feature | SKIP | Explicit feature request for a quiet test flag; no wrong behavior. |
| 3380 | Autoname extensions | feature | SKIP | Requests automatic extension naming to reduce boilerplate. |
| 3377 | Specifying override artifacts using a relative path | feature | SKIP | Requests support for relative paths in overrides.toml. |
| 3367 | Potential feature: recommend project environment on unsatisfiable requ | feature | SKIP | Requests an added nudge message on conflicts; enhancement. |
| 3365 | tree_hash does not handle devices | bug | **PERSISTS** | Ran the exact MWE in the VibePkg r3365 daemon (LocalPkgServer not needed; tree_hash is pure). VibePkg.TreeHash.tree_hash("/dev/null") throws: `Base.IOError :: IOError: readdir("/dev/null"): not a directory (ENOTDIR)` — the same ba… |
| 3354 | Add feature to run specific test files. | feature | SKIP | Requests ability to run specific test files or name patterns. |
| 3348 | [docs] document indirect conditional loading | docs | SKIP | Asks for documentation of indirect extension triggering. |
| 3345 | Command to copy/fork environment | feature | SKIP | Requests a new command to fork an environment. |
| 3337 | Auto-Install with wrong package name does not hit the Suggestion Error | feature | SKIP | Requests the loading auto-install message to include name suggestions; enhancement. |
| 3335 | `ArgumentError: invalid base 10 digit` when fixing package with exotic | bug | **FIXED** | Ran a Level-1 pin repro in the --test daemon (isolate!, offline Example fixture at 0.5.0/0.5.1). Added Example, then called plan_pin(env, regs, cfg, [PackageRequest("Example", nothing, "0.5.1+3")]) — the exact user-facing pin path… |
| 3326 | Projects with symlinked `Project.toml`s are broken | bug | **PERSISTS** | VibePkg's find_project_file (src/Environments.jl:100) resolves a symlinked Project.toml via safe_realpath before anything else — identical to real Pkg (src/Types.jl:236) — so it writes/reads the Manifest next to the symlink TARGET… |
| 3316 | JET.jl gets lots of error using `Pkg.activate`, `Pkg.instantiate` and  | other | SKIP | JET static-analysis possible-error report (type instabilities), not observable runtime mis |
| 3305 | [Feature Request] Add an Option to Copy an Existing `Project.toml` to  | feature | SKIP | Requests option to seed a new/temp env from an existing Project.toml. |
| 3300 | `instantiate` triggers `build` on deps but not the active package | question | SKIP | Asks whether the build-on-deps-not-active-package behavior is intentional design. |
| 3292 | Registry updates from package server does not do incremental updates | feature | SKIP | Performance enhancement request for incremental registry downloads. |
| 3279 | `IOError: FDWatcher: bad file descriptor` running `Pkg.update()` | other | SKIP | Network/VPN-specific download failure; reporter attributes it to their own network. |
| 3270 | Prioritize full upgrade of direct dependencies over indirect dependenc | rfc | SKIP | Design proposal to change resolver upgrade priority/stability policy. |
| 3268 | Add `pkg> bump patch/minor/major` to bump the active env version | feature | SKIP | Requests a new bump command/API. |
| 3267 | Experimental status of Pkg.dependencies(), Pkg.project() | question | SKIP | Asks for clarification on API stability status. |
| 3259 | Feature request: add search function to search for available packages. | feature | SKIP | Requests a package search feature. |
| 3240 | Pkg can confusingly load env in secondary DEPOT_PATH by default | feature | SKIP | Enhancement request (auto-create/warn); reporter unsure of specific change, behavior follo |
| 3233 | Trying to fix broken manifests is really frustrating | rfc | SKIP | UX/design request for atomic or lenient operations on already-broken manifests. |
| 3175 | Suggest how to resolve conflict | feature | SKIP | Requests resolver heuristics that suggest packages to remove. |
| 3074 | Allow testing projects without a UUID | feature | SKIP | Asks to relax the UUID requirement for testing; an enhancement, not wrong behavior. |
| 2741 | Installation of Julia packages for fully offline environments | feature | SKIP | Requests offline installation workflow support. |
| 1568 | Feature request: support version numbers with build metadata | bug | **PERSISTS** | Ran a Level-1 plan repro in the r1568 daemon (LocalPkgServer.isolate!, Example fixture). Adapting the MWE to the offline Example package, `plan_add(env0, regs, Config(depots), [PackageRequest("Example", nothing, "2.23.0+1")])` thr… |

## Page 12

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 3222 | Opaque error message when specifically requested version doesn't exist | feature | SKIP | error-message wording enhancement, not wrong behavior |
| 3210 | Detect and warn about changes to package directory during testing | feature | SKIP | labeled feature request for a new warning during test |
| 3197 | The interactive compat editor should allow to edit mulitple entries | feature | SKIP | UX enhancement request for the interactive compat editor |
| 3194 | Artifact selection hooks should not read the output TOML dictionary fr | feature | SKIP | design/interface change proposal for artifact hooks |
| 3187 | Feature Request: Add branch by PR number | feature | SKIP | explicit feature request to add branch by PR number |
| 3164 | FR: Make different version upgrades distinguishable | feature | SKIP | cosmetic feature request (font/color for upgrade magnitude) |
| 3150 | upgradable marker sometimes inaccurate | bug | **PERSISTS** | Ran a plan/display-level repro offline with the Example fixture: added Example@0.5.0 (registry also has 0.5.1; 1.0.0 yanked), pinned it, then rendered print_status with registries and ran plan_up. Status printed "→⌃ [7876af07] Exa… |
| 3138 | Pkg.add() and `add` slightly different results | bug | **FIXED** | Ran an end-to-end repro in the --test daemon (Level 2 / API level) with a synthetic local git repo (pkg Foo, default branch + `mybranch`), adapting the network MWE offline. Output: REPL `parse_package_word("<repo>#mybranch")` => P… |
| 3119 | Pkg.update downgrades the packages | bug | **FIXED** | Ran a plan-level repro in the --test daemon using the offline Example fixture (0.5.0, 0.5.1 installable; 1.0.0 yanked). Seeded manifest at Example 0.5.0 via plan_add, then plan_up: whole-env `up` and targeted `up Example` both UPG… |
| 3115 | Make usage tips take form of current mode (REPL or API) | feature | SKIP | enhancement to format hints/warnings by invocation mode |
| 3084 | Behavior of no-arg activate with julia --project changed with julia v1 | docs | SKIP | no-arg Pkg.activate() activating default env matches docs; docs/behavior question |
| 3083 | Missing package add prompt needs more tests | other | SKIP | meta/testing task to add test coverage |
| 3077 | Updating JuliaRegistry on fresh install of 1.6.6 with `ENV["JULIA_PKG_ | bug | SKIP | Windows CLI-git file-locking prompts; external git behavior, not reproducible in code |
| 3063 | Interactive compat editor: io objects do not have a handle field | bug | **FIXED** | The reported bug lived in old Pkg's `compat()` with no args, which opened a `TerminalMenus`-based interactive editor whose `request`/`raw!` path did a ccall on `io.handle`, blowing up on any io that isn't a real TTY. VibePkg does… |
| 3060 | Interrupting add resulting in unending download error logs | bug | N/A | The `Error: curl_multi_socket_action: 8` spam originates entirely in Julia's Downloads.jl stdlib, not in Pkg/VibePkg. Traced the exact string to Downloads/src/Curl/Multi.jl:200 (`@check curl_multi_socket_action(...)`) inside the a… |
| 3054 | Prompt to install package should purge input buffer before reading fro | bug | N/A | Issue #3054 is about `try_prompt_pkg_add`, which real Pkg registers into `REPL.install_packages_hooks` (reference ext/REPLExt/REPLExt.jl:241 and 377-378) to prompt "Install packages? (y/n/o)" via `Base.prompt(stdin, ...)` when `us… |
| 3006 | Trouble Installing Packages | question | SKIP | support request; corrupt git index on Windows, environment-specific external error |
| 2922 | Interrupting Pkg.test sometimes orphans the test sandbox process | bug | **PERSISTS** | Ran a runtime repro against VibePkg's actual test code path (src/TestOps.jl:212 run_test_process) via the r2922 daemon. Built a synthetic sandbox package whose test/runtests.jl calls Base.exit_on_sigint(false), writes its PID, and… |
| 2789 | Can't specify a prerelease tag in the `compat` sectiion of a Project.t | feature | SKIP | labeled feature request to support prerelease tags in compat/VersionSpec |
| 2743 | 1.7.0-rc1: clean up bad registry tarball on EOF exception | bug | **FIXED** | Ran install_server_registry! against a LocalPkgServer serving a truncated General registry tarball (half the bytes, guaranteeing EOF). Observed: (1) the exact issue error is thrown — "EOFError :: EOFError: read end of file" during… |
| 2738 | Improve the "empty intersection" error message | feature | SKIP | error-message enhancement request |
| 2677 | Use WSL style NTFS extended attributes to store permissions of extract | feature | SKIP | design proposal for Windows permission storage |
| 2607 | API request: installable versions from package name | feature | SKIP | public API request to query installable versions |
| 2584 | `ctrl-c` during registry updates leads to corruption | bug | **FIXED** | Ran a live repro in the --test daemon against LocalPkgServer. Bootstrapped General (usable: plan_add Example -> v0.5.5). EXP1: forced an update against a mini-server advertising a new tree-hash but serving a corrupt tarball; updat… |
| 2451 | Pkg.pin resolves | bug | **FIXED** | Ran a Level-1 offline repro in the r2451 daemon. Developed a synthetic path package `Root` depending on `Example`, forced `Example` to the older 0.5.0 in the manifest (registry also has 0.5.1, which a naive resolve would pick), th… |
| 1982 | Allow named non-package project | feature | SKIP | feature request to permit named projects without src/Name.jl |
| 770 | Julep: interlocked changes across the package ecosystem | rfc | SKIP | design proposal (Julep) for cross-package branch coordination |

## Page 13

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 3043 | Error 400 Bad Request on redirection when using proxy | bug | SKIP | Proxy/redirect download failure lives in Downloads.jl/curl and requires a specific proxy e |
| 3032 | Feature Request: Given a Project.toml, generate a Manifest.toml withou | feature | SKIP | Explicit feature request for new resolve-only interface. |
| 3026 | Feature request: Pkg.precompile(; throw_error = true) | feature | SKIP | Feature request for a new keyword to make precompile throw. |
| 3019 | Proposal: warn (at least) on activation of a project made with a diffe | rfc | SKIP | Design proposal for new warning behavior on activate. |
| 3012 | Julia v1.8.0-beta1 shows outdated packages but does not update them | bug | **FIXED** | Re-reproduced: seed Example@0.5.0 (registry has 0.5.1; 1.0.0 yanked); print_status shows the ⌃ marker + 'may be upgradable' footer; both whole-env and targeted plan_up move Example 0.5.0->0.5.1. Marker and update AGREE (no diverge… |
| 2981 | Documentation for Pkg.resolve is very terse. Ok for this PR? | docs | SKIP | Documentation wording improvement request. |
| 2978 | Add warning in case of a single registry thats not the General registr | feature | SKIP | Enhancement request for a friendlier warning message. |
| 2977 | Inspecting nested exceptions from download errors | rfc | SKIP | Design discussion about persisting nested exceptions for inspection. |
| 2958 | a suggestion/bug to pkg install | feature | SKIP | Requests auto-applying a DLL-load workaround; not a concrete Pkg correctness bug. |
| 2935 | Wrong remote URL used when package already added from fork | bug | **FIXED** | Re-reproduced: add Example from a divergent FORK url+rev (records fork url in manifest+[sources]), then add Example#rev BY NAME -> manifest repo_url + [sources] url switch to the REGISTRY canonical url, not the stale fork. API.add… |
| 2902 | Feature request: sort packages by installation time | feature | SKIP | New status sorting option request. |
| 2894 | Non standard SSH port ignored in git URL for package add with Pkg.setp | bug | **PERSISTS** | Ran VibePkg.Git.normalize_url directly (offline, no network needed) after Pkg.setprotocol!(domain="domain", protocol="ssh"). Input "user@domain:2222/git-server/repos/ARTime.git" produced:    normalize_url => ssh://git@domain/2222/… |
| 2873 | Auto-install prompt fails without explanation if no registries are ava | bug | SKIP | Concerns the Base/REPL auto-install prompt and messaging when no registries/.julia exist;  |
| 2838 | Provide nicer API for dependency listing | feature | SKIP | Request for a convenience dependency-listing API. |
| 2794 | Improve situation with missing dev'ed packages | feature | SKIP | UX improvement request for recovering from missing dev'ed packages; the individual errors  |
| 2792 | Add line on which registry a package is being auto installed from | feature | SKIP | Enhancement to auto-install prompt output. |
| 2779 | Unable to add private registry | bug | SKIP | BoundsError crash is in LibGit2.ssh_knownhost_check callback, not Pkg code, and needs spec |
| 2771 | Make Pkg relocatable. | feature | SKIP | Enhancement to not assume stdlib files exist at runtime (relocatability), not a plain corr |
| 2747 | julia version requirement for package not satisfied | feature | SKIP | Error-message enhancement to state the required Julia version. |
| 2714 | Make tree hash for loaded package accessible | feature | SKIP | Feature request to expose a loaded package's tree hash. |
| 2704 | Add tab-completions for registry add | feature | SKIP | Request for REPL tab-completion of registry paths. |
| 2697 | Vague warnings about dependency graph not being a DAG | bug | SKIP | Complaint about clarity and repetition of the 'not a DAG' warning; a messaging/UX deficien |
| 2685 | gc: treat older manifest as unreachable? | feature | SKIP | Design proposal to change gc reachability heuristics. |
| 2684 | Pkg.gc could maybe clean up old precompile files | feature | SKIP | Enhancement idea for gc to remove stale precompile files. |
| 2664 | Don't download artifact when overwritten via Overrides.toml | bug | **FIXED** | Ran a Level-2 repro in the r2664 daemon against a synthetic local pkg with an Artifacts.toml declaring a non-lazy artifact (git-tree-sha1 = 1d5cc7b8...dc..., bogus download url https://example.invalid). Called VibePkg.ArtifactOps.… |
| 2525 | Pkg.add with a branch (and Pkg.dev) chooses a registry inconsistently  | bug | **PERSISTS** | Ran a Level-1 (pure/offline) two-registry repro in the r2525 daemon. Built the standard TestRegistry (Example max non-yanked = 0.5.1, repo https://example.com/Example.jl.git) plus a synthetic OtherRegistry with the SAME Example UU… |
| 1945 | Wishlist: Pkg.add option to ask for confirmation and report changes | feature | SKIP | Feature request for a confirmation/report-before-apply option. |
| 708 | Pkg.add on git repository with a submodule raises GitError | bug | **PERSISTS** | Ran an offline repro through VibePkg's real add-by-url path. Built a local git package repo (valid Project.toml, name=SubModPkg) containing a genuine git submodule (.gitmodules + gitlink entry to a second local repo), then called… |

## Page 14

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 2671 | Pkg.update help string does not make sense regarding the mode keyword | docs | SKIP | Request to clarify help/docstring wording for the mode kwarg. |
| 2667 | allow update of any package in manifest | feature | SKIP | Feature request to allow `up Foo` for manifest-only packages. |
| 2615 | misleading info given by `Pkg.status()` | bug | **FIXED** | Level-2 API repro in the r2615 --test daemon (offline, LocalPkgServer served General/Example fixture). Installed Example v0.5.5 into a depot, then wrote artifacts/Overrides.toml redirecting Example's UUID (7876af07-...) → "/nonexi… |
| 2591 | An option for `]test` to run under `rr` | feature | SKIP | Request for a new --bug-report=rr option in test. |
| 2590 | Artifact download failure is not reported in package-server mode | bug | **FIXED** | Ran a Level-1/ops repro in the r2590 daemon. Built a synthetic package root with an Artifacts.toml declaring one non-lazy artifact `foo` whose only sources are unreachable (a pkg-server endpoint https://pkgserver.invalid + a downl… |
| 2586 | Question: Should we document the `manifest` kwarg in the docstring for | question | SKIP | Question about whether/where to document a kwarg. |
| 2553 | The default behavior of the update command is not documented | docs | SKIP | Documentation gap for default update mode/level. |
| 2529 | Add more info to hash mismatch warning | feature | SKIP | Enhancement to include the artifact name in a warning message. |
| 2515 | Feature request: expose download URLs | feature | SKIP | Requests a public API to enumerate package download sources. |
| 2507 | Support multiple package servers | feature | SKIP | Feature request for JULIA_PKG_SERVER to accept a list. |
| 2503 | Feature request: update a `Manifest.toml` file without downloading any | feature | SKIP | Feature request for a resolve-only update mode. |
| 2433 | Registries fail to update when called from project | bug | **FIXED** | Ran the real registry-update path (VibePkg.API.op_context(update_registry=:force), the code `up` uses) against the live LocalPkgServer, with a fresh depot bootstrapped via add_default_registries!. To force an actual re-fetch, I re… |
| 2401 | Make printing "Activating Environment..." a no-op if you are already i | feature | SKIP | Enhancement to suppress activation message when already active. |
| 2385 | Feature: Dependency on a privately registered package | feature | SKIP | Feature/design request for project-declared registry dependencies. |
| 2381 | Unclear error message when adding/updating dependencies on broken modu | bug | **FIXED** | Ran two API-level repros in VibePkg (Julia 1.12.6) with a broken project package Foo (module Foo\nf(\nend) depending on the offline-installable Example fixture. (1) VibePkg.add("Example") on the broken project succeeds without err… |
| 2368 | filename extension in downloading incorrectly specified via Content-Di | bug | **FIXED** | The reported bug is that download_verify_unpack infers the archive extension from the URL, so a random-id URL (Google Drive/Dropbox) whose real extension is only in Content-Disposition picks the wrong decompressor and fails. VibeP… |
| 2320 | Inconsistent registry and packages in package server. | feature | SKIP | Requests server-side registry/storage consistency guarantee; not a client-code bug. |
| 2008 | Proposal for more first class handing of sysimages in Pkg | rfc | SKIP | Design proposal for new sysimage API surface. |
| 1938 | allow `] add path_or_url/to/tarball` | feature | SKIP | Feature request to add packages from plain tarballs. |
| 1888 | Feature request: override artifact downloading for specific URLs | feature | SKIP | Requests an extensible override mechanism for artifact downloads. |
| 1780 | Expand artifact selection beyond Platform/CompilerABI | rfc | SKIP | Design proposal for extensible artifact tag matching. |
| 1724 | Give hint for replacement of Pkg.installed() in deprecation warning | feature | SKIP | Enhancement to add a replacement hint to a deprecation message. |
| 1654 | Activating a directory that doesn't exist | bug | **FIXED** | Ran Level-2 API repro in the --test daemon (offline make_test_registry depot; active project = App/PkgB; cwd = App). (1) develop(path="./PkgA") resolves against the project dir to App/PkgB/PkgA (nonexistent) and throws a clean `Vi… |
| 1247 | Libgit2 has problems cloning on NFS mounts | bug | SKIP | libgit2/NFS-environment-specific clone failure, not plausibly checkable in Pkg code. |
| 1155 | VersionSpec printed incorrectly | bug | **FIXED** | Ran the faithful analog in the r1155 daemon. VibePkg.Versions.VersionSpec(["0.1","0.8-1"]) still prints as the bracketed "[0.1, 0.8 - 1]" (same as Pkg's print method), but the reported BAD serialization does not happen: (1) Handin… |
| 961 | status has no option to show all packages across the environment stack | feature | SKIP | Feature request for a status option spanning the env stack. |
| 11 | Feature Request: Show which versions of a package are installable give | feature | SKIP | Requests a new command to list installable versions. |

## Page 15

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 2246 | Add DEPOT_PATH[2]/environments/v#.# to the LOAD_PATH by default | feature | SKIP | Proposes changing default LOAD_PATH to include a system-wide environment; enhancement, not |
| 2244 | Strange behavior with existing manifest and missing project | bug | **FIXED** | Reproduced the exact setup at plan level (Level 1) in the r2244 daemon: built envdir with a real Manifest.toml (Example 0.5.1 + injected orphan path-package Foo uuid 1111...), then deleted Project.toml so manifest exists / project… |
| 2217 | bypass registry sync when handling stdlib packages | feature | SKIP | Requests skipping registry update when adding an stdlib; optimization/behavior change, not |
| 2215 | prevent package downgrade when pkg server is out-of-date | feature | SKIP | Requests failing (or a new flag) instead of downgrading against an out-of-date registry mi |
| 2211 | Resolve failure with odd error message | bug | **PERSISTS** | Ran a Level 1 plan-level repro offline (daemon r2211) with the Example fixture. Synthetic dev pkg TmpPkg (uuid 1111...) depends on Example; compat Example="=0.5.0", plan_develop+plan_resolve → manifest Example 0.5.0. Then changed… |
| 2206 | Include restricted package versions on log lines | feature | SKIP | Enhancement to add restricted version info to resolver log lines. |
| 2205 | internal assertion error if a local copy of a package exists | bug | **FIXED** | Ran an offline repro in the r2205 daemon (LocalPkgServer.isolate!, make_test_registry). Two probes of Planning.is_package_downloaded / source_path via entry_to_node: (1) a synthetic LOCAL dev package (plan_develop of a local Local… |
| 2177 | [FR] Terse names for unregistered packages | feature | SKIP | Feature request for github:/shorthand expansion of unregistered package URLs. |
| 2168 | Packages with special characters like ∂ (U+2202) cannot be removed but | bug | **FIXED** | Ran in the r2168 --test daemon. (1) Base.isidentifier("∂Components"/"∂xxxxx"/"Δfoo") all true; VibePkg.REPLMode.parse_package_word returns the ∂-name with no error. (2) REPL statement parser: "rm ∂xxxxx", "rm ∂Components", "add ∂C… |
| 2165 | Can `Resolve.Fixed` be removed? | rfc | SKIP | Internal design/refactoring question about the resolver's Fixed type. |
| 2164 | Can the function `Resolve.sanity_check` be moved to be a test utility? | rfc | SKIP | Internal refactoring question about relocating a test-only function. |
| 2131 | missing docstrings in artifacts API reference | docs | SKIP | Documenter reports missing docstrings in the artifacts API reference; documentation issue. |
| 2092 | remove unfinished artifact when there's an exception | bug | **FIXED** | Ran an offline repro in an isolated jld --test daemon exercising src/ArtifactOps.jl `try_install_from`/`ensure_artifact_installed!`. Built a real artifact tree + zstd tarball, overrode Fetch.download to serve it locally (dead netw… |
| 2060 | With global depot, still automatically clone General | feature | SKIP | Requests cloning General into a writable depot when the global one is stale and richer `re |
| 2056 | Feature request: `dev` for a repository containing multiple packages | feature | SKIP | Explicit feature request for recursive/glob dev of monorepo subdirs. |
| 2055 | dev'ing several subdirs of a single git repository cause the repo to b | feature | SKIP | Redundant re-clone when dev'ing a second subdir; final state is correct (one copy), so thi |
| 2044 | Stop using the raw manifest `Dict' inside Pkg operations | rfc | SKIP | Internal refactoring proposal to type the manifest to reduce invalidations. |
| 2028 | Should `Pkg.Types.semver_spec("0")` throw an error? | bug | **PERSISTS** | Ran in the r2028 test daemon: `using VibePkg.Versions: semver_spec` then parsed "0", "0.0", "0.0.0". Observed exactly the reported inconsistency:   "0"     => VersionSpec prints "0"   (accepted)   "0.0"   => VersionSpec prints "0.… |
| 2023 | Project file validation | bug | **PERSISTS** | Ran two offline Level-1 repros in the r2023 daemon with a synthetic local dev package (BadPkg) + the Example fixture registry. (1) plan_develop(env, regs, cfg, badpkg) where BadPkg/Project.toml has `[targets] test = ["Test"]` with… |
| 2016 | pkg update document defaults | docs | SKIP | Requests documenting the update command's optional pkg arg and option defaults; documentat |
| 2013 | REPL package mode completion for path with spaces | bug | **FIXED** | Ran VibePkg.REPLMode.completions_for in the jld --test daemon against a real cwd containing a package dir named "dir with spaces". Results: completions_for("dev dir") -> word="dir", cands=String[]; completions_for("develop dir") -… |
| 2007 | Symbolic linked julia home make `dev` outside `.julia/dev` fail | bug | **PERSISTS** | Ran scratchpad/r2007c.jl in the r2007 --test daemon. Setup: real depot at /base/real/julia, symlink /base/jl -> that (depth-changing, like ~/.julia -> /data/julia); dev package out-of-tree at /base/real/pkg_test/TestPackage11; act… |
| 1995 | The "Using Artifacts" example in the docs is incompatible with "immuta | docs | SKIP | Documentation clarity issue: the artifacts tutorial example conflicts with the read-only/i |
| 1975 | Add a Pkg.audit command to check dependencies against reported vulnera | feature | SKIP | Feature request (with speculative/security labels) for a new npm-audit-like command. |
| 1965 | Compatibility with rusty environment chains | feature | SKIP | Requests that Pkg check compat across the whole LOAD_PATH environment stack; stacked-env d |
| 1873 | Partial Artifacts | feature | SKIP | Design/feature proposal for partial artifacts. |
| 1855 | Improve appearance of Conflict messsages | feature | SKIP | Proposal to redesign/format unsatisfiable-requirements conflict messages; presentation enh |
| 1829 | `update Package` sometimes doesn't update Package even though it could | bug | **PERSISTS** | Ran a Level-1 (plan-level) repro in the r1829 --test daemon with a synthetic offline 2-package registry: Porcelain (direct dep) depends on Cutlery (indirect dep); Porcelain 1.0.0 requires Cutlery "1", Porcelain 2.0.0 requires Cutl… |
| 411 | Is the package manager ready for moving out stdlibs in their own repos | rfc | SKIP | Discussion label; design question about recording stdlib state in manifests. |

## Page 16

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 1921 | Support for non-tarball dependencies in Pkg.Artifacts | feature | SKIP | Feature request to allow single-file (non-tarball) artifact dependencies. |
| 1856 | curation & trust (registries are not the answer) | rfc | SKIP | Design discussion about a package trust/curation layer. |
| 1854 | Package groups | feature | SKIP | Proposal for curated environments / package groups. |
| 1849 | depot where package is compiled is dependent on filesystem state. | feature | SKIP | Requests creating ~/.julia or warning when first DEPOT_PATH slot is missing; a behavior/UX |
| 1836 | Feature request: first-class support for "namespaces" in registries | feature | SKIP | Proposal for first-class registry namespaces. |
| 1747 | Problem  with "try `Pkg.resolve()`" | bug | SKIP | Request to reword a misleading error suggestion (resolve vs update registry); error-messag |
| 1731 | support resuming downloads | feature | SKIP | Feature request for resumable downloads via HTTP range requests. |
| 1689 | Ability to pass `test_args` when using `] test MyPackage` in the REPL  | feature | SKIP | Feature request to pass test_args from REPL test mode. |
| 1687 | Feature Request: add flag build = true(default) /verbose/false) to ins | feature | SKIP | Requests flags to control/skip build during instantiate/add. |
| 1676 | Change `up --patch` to never update anything that is pre-1.0 | feature | SKIP | Proposes changing up --patch semantics for pre-1.0 packages. |
| 1665 | docs: add artifacts to the glossary | docs | SKIP | Documentation update request for the glossary. |
| 1657 | Error on instantiate with invalid artifact | bug | **PERSISTS** | Reproduced offline in VibePkg. Wrote a synthetic package with an Artifacts.toml holding a platform-specific entry missing the `arch` key (`[[MyArtifact]]` with `os = "windows"` only). Exercised the artifact-install path three ways… |
| 1634 | Feature Request Registry: Refer to master branch if no version is defi | feature | SKIP | Proposes installing master branch when a registered package has no version. |
| 1598 | Use @test_logs to test for hash errors | other | SKIP | About Pkg's own test suite hiding hash-error log output; internal testing, not package beh |
| 1593 | Pkg API issues | rfc | SKIP | Design discussion proposing breaking API changes to free/unpin/add/dev/activate. |
| 1574 | error logging | feature | SKIP | Enhancement proposal to log state on Pkg errors. |
| 1542 | Add `update --all` flag to also update lower stacked environments | feature | SKIP | Requests an up --all flag to update stacked environments. |
| 1527 | Do not offer to autocomplete `] add` with _jll packages | feature | SKIP | Enhancement to exclude _jll packages from add tab-completion. |
| 1467 | Document automatic unpacking of artifacts | docs | SKIP | Documentation request about artifact unpacking behavior. |
| 1465 | Better error message when failing to find an artifact due to missmatch | feature | SKIP | Requests improved error message when artifact platform/libc mismatch; message-wording enha |
| 1464 | artifact string macro in the REPL | bug | N/A | The `artifact"..."` / `@artifact_str` macro is defined solely in the Julia `Artifacts` stdlib (.../stdlib/v1.12/Artifacts/src/Artifacts.jl:689), not in Pkg or VibePkg. Real Pkg (src/Artifacts.jl:20) only imports+re-exports it from… |
| 1439 | Vendoring Python Wheels as Artifacts | rfc | SKIP | Speculative design proposal for Python virtualenvs via artifacts. |
| 1436 | Restrict OS? / Add to docs | question | SKIP | Question about whether OS restriction is possible plus docs request. |
| 1430 | Instantiating with dirty registry can get bad error message | bug | **FIXED** | Ran instantiate via the jld --test daemon against the offline Example fixture (isolate!()). Case A: Manifest.toml pinning Example to version 0.4.0 (a version absent from the dirty/out-of-date registry) with no git-tree-sha1, then… |
| 1071 | allow package to be disambiguated by `@user/package` | feature | SKIP | Enhancement to disambiguate same-named packages via @user/package syntax. |
| 973 | Add post-add hook? | feature | SKIP | Requests a generic Pkg.afteradd callback hook mechanism. |
| 837 | dev should also check for "MyPackage.jl" directory (and not just "MyPa | feature | SKIP | Requests dev to also detect a MyPackage.jl directory name. |
| 687 | Better error message for`Pkg.add()` when url is wrong. | feature | SKIP | Requests a friendlier error message for invalid URLs; outdated Pkg.clone API, message-word |

## Page 17

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 1395 | document `instantiate --project` | docs | SKIP | Documentation request; no bug behavior. |
| 1308 | Idea: automatic artifact & package deduplication | feature | SKIP | Design idea for shared-depot dedup. |
| 1288 | Feature request: full semver support(pre-release version and build met | feature | SKIP | Requests extended semver support. |
| 1280 | Documentation: What to do in case of version downgrades | docs | SKIP | Documentation content proposal. |
| 1268 | Official docs on package registration process | docs | SKIP | Documentation request. |
| 1263 | Method to print valid range of a version specifier | feature | SKIP | Requests new exported helper method. |
| 1254 | Getting user's working dir from Pkg.build | feature | SKIP | Enhancement to expose PWD to build scripts. |
| 1253 | Feature request: testing and building a non-package project | feature | SKIP | Requests test/build for non-package projects. |
| 1246 | Should compat `~0.y.z` be the same as `=0.y.z`? | rfc | SKIP | Proposal to change ~ semantics for 0.y.z; design discussion. |
| 1245 | Feature request: activate environment on top of current stack | feature | SKIP | Requests --stack style activate. |
| 1239 | document pin | docs | SKIP | Documentation improvement for pin. |
| 1236 | If add fails due to resolve error, a subsequent add will complete with | bug | **PERSISTS** | Reproduced at runtime in VibePkg (Level 2 API), then isolated the mechanism.  Exact #1236 scenario (fixture "General" registry served by LocalPkgServer): project has Example pinned `=0.5.0`; a local git repo `BuildDep#main` depend… |
| 1231 | Name of dependency does not get updated in Project.toml if it changes  | bug | **FIXED** | Level 1 plan-level repro in an isolated --test daemon: built a synthetic offline registry with package Foo (UUID aaaaaaaa-…) at v1.0.0, plan_add'd it (Project.toml + Manifest both -> "Foo"), then renamed the package in the registr… |
| 1218 | Pkg.build errors when depot is read-only | bug | **FIXED** | Ran a runtime repro (scratchpad/repro1218.jl) in the r1218 daemon: two-depot stack [depot1(writable primary), depot2], installed a synthetic registered package Foo (with deps/build.jl) INTO depot2, chmod -R ugo-w on depot2, then c… |
| 1212 | `instantiate` does not update registry sometimes? | bug | **FIXED** | Ran an end-to-end instantiate repro in the --test daemon (script /private/tmp/.../scratchpad/r1212b.jl). Setup mirrors the report: a Project.toml listing dep Example with NO Manifest.toml, in a fresh depot whose registry lists Exa… |
| 1208 | [docs] clarify meaning of "project" earlier | docs | SKIP | Documentation clarity request. |
| 1089 | Blacklist compat specifier | feature | SKIP | Requests new compat syntax; not a bug. |
| 1072 | allow registries to depend on other registries | feature | SKIP | Design/feature discussion. |
| 1001 | Verify permissions before modifying filesystem | feature | SKIP | Enhancement to improve error message on permission failure. |
| 928 | support for PSA through Pkg client? | feature | SKIP | Feature idea for public service announcements. |
| 860 | Suboptimal error message for un-instantiated package | other | SKIP | Error-message wording quality, not wrong package behavior. |
| 744 | Feature request: `dev` time dependencies | feature | SKIP | New feature for dev-time deps. |
| 710 | `] add` skips the `build` step | bug | **FIXED** | Reproduced the exact #710 scenario (registry `add` of a package carrying deps/build.jl) offline. I built a synthetic registry package "BuildPkg" whose deps/build.jl writes a marker file, served its tarball via LocalPkgServer.start… |
| 677 | Support relative paths in registries | feature | SKIP | Requests relative-path support for registry repos. |
| 562 | Should `up` also just ignore unknown packages? | rfc | SKIP | Design question about rm-vs-up consistency. |
| 479 | warn about invalid/unexpected sections in Project.toml | feature | SKIP | Requests warning for mistyped Project.toml sections. |
| 318 | status --tree | feature | SKIP | Requests tree display mode for status. |
| 274 | Print diff when a tracked branch changes | feature | SKIP | Display enhancement for tracked-branch updates. |
| 52 | levels of incompatibility | rfc | SKIP | Speculative resolver design proposal, not a bug. |

## Page 18 (tail — all remaining open issues are non-bugs)

| # | title | type | verdict | notes / evidence |
|---|---|---|---|---|
| 878 | Project package not isolated | question | SKIP | User unsure if bug; describes code-loading/stacked-env confusion, asks if expected. |
| 811 | A workflow for convieniently starting (unstacked) projects | other | SKIP | User sharing a workflow tip for possible documentation, not a bug. |
| 727 | Feature request: build dependencies | feature | SKIP | Explicit feature request for build-only dependencies. |
| 623 | request more extensive docs on how to develop application projects | docs | SKIP | Documentation expansion request. |
| 533 | Improve behavior when multiple overlapping registry entries exist? | feature | SKIP | Requests opt-in layered-registry/ordering behavior; a design/enhancement request. |
| 511 | Improve "Please specify by known `name=uuid`" error message | feature | SKIP | Request to improve error message wording; behavior is correct, not observably wrong. |
| 461 | Packages removed from the Project (but are still left in the Manifest) | rfc | SKIP | Open-ended design question about manifest freeing behavior. |
| 286 | Introduce flag to run tests in virgin environment | feature | SKIP | Enhancement proposing a new test flag, not a bug. |
| 127 | allow registries to specify per-julia-version branches | feature | SKIP | Enhancement proposing a new registry.toml [branches] feature. |

_Pages 19+ are empty. The `/issues` API endpoint (issues interleaved with PRs) ends at page 18; pages 1–18 span **all 426 open issues** — audit complete._
