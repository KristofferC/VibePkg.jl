# Pkg.jl open-issue audit vs VibePkg

Running audit of **open** Pkg.jl issues
(<https://github.com/JuliaLang/Pkg.jl/issues?q=sort:updated-desc+is:issue+state:open>),
newest-updated first, one page (~30 API items ≈ 10 real issues) at a time.

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

- **Pages covered:** 1–6 (of ~40). **In-scope bugs:** 40 → **31 FIXED, 9 PERSISTS, 0 N/A**. Non-bugs skipped: ~76.
- **Every FIXED issue has a regression test.** Page-1 #4686 & #4691 → `test/ops.jl`; the other **29 FIXED** (pages 1–6) → **`test/pkg_issues.jl`** (one self-contained `@testset "Pkg.jl#NNNN …"` each, all green, auto-discovered by `runtests.jl`).
- **The 9 PERSISTS** are real gaps (mostly faithful ports of still-open Pkg bugs), listed in the per-page tables below and summarized in the [pkg-issue-audit] memory. No passing test (they'd be `@test_broken`); #4705 is the page-1 one.
- Method: `Workflow` fan-out — one agent/page to triage, one agent/bug to reproduce in its own `jld --test` daemon, one agent/FIXED to write+verify its testset.

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
