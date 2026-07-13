# Architecture

This page documents the internal architecture of VibePkg for developers working
on the package itself. It describes the module layering, the core data types,
and how data flows from user input through registry and environment parsing,
into the resolver, and back out to disk and the terminal.

## Design principles

A few principles shape almost every module and are worth stating up front:

- **Values, not caches.** `Project`, `Manifest`, and `Environment` are immutable
  snapshots. An operation loads an `Environment`, computes a *new* `Environment`,
  and diffs the two at write time. There is no mutable `EnvCache` with "original"
  bookkeeping — an immutable snapshot is its own original, and an undo entry is
  just a reference to an old snapshot.
- **Configuration is data.** Everything an operation needs from the process
  environment (depot stack, package server, offline flag, download concurrency,
  dev dir) is read *once* at the operation boundary into an immutable
  `Configs.Config` and passed down as an argument. Planning and Execution never
  read `ENV`.
- **Pure planning, effectful edges.** `Planning` computes what the world should
  look like (a target `Environment`) without touching the network or disk;
  `Execution` makes disk match the target without making any resolution
  decisions. The one exception in Planning — materializing a package tracked by
  a git URL — is injected as a `fetcher` function so the module itself stays
  pure and testable.
- **Strict layering.** `src/VibePkg.jl` includes modules in a fixed order and
  each file may depend only on files included before it. Dependencies flow one
  way; there are no include-order cycles.
- **Round-trip fidelity.** Parsed TOML values keep the raw dict they came from
  (a `raw` field, excluded from `==`/`hash`), and writers overlay typed fields
  onto a deep copy of that raw dict, so unknown keys in user files survive a
  read–modify–write cycle.

## Module layering

The include order in `src/VibePkg.jl` is the dependency order. Grouped by role:

```
┌───────────────────────────────────────────────────────────────────┐
│ Frontends        API, REPLMode (+ ext/REPLExt), compat/*          │
├───────────────────────────────────────────────────────────────────┤
│ Presentation     Display                                          │
├───────────────────────────────────────────────────────────────────┤
│ Side operations  GCOps, BuildOps, TestOps, AppsOps                │
├───────────────────────────────────────────────────────────────────┤
│ Core pipeline    Environments, Queries, Planning, Execution       │
├───────────────────────────────────────────────────────────────────┤
│ Resolution       Resolve (versionweights, fieldvalues,            │
│                  graphtype, maxsum)                               │
├───────────────────────────────────────────────────────────────────┤
│ Data access      Registries, ArtifactOps                          │
├───────────────────────────────────────────────────────────────────┤
│ Acquisition      TreeHash, Git, Fetch                             │
├───────────────────────────────────────────────────────────────────┤
│ Foundations      Errors, Utils, MiniProgressBars, FuzzySorting,   │
│                  Versions, EnvFiles, Depots, Configs, Stdlibs     │
└───────────────────────────────────────────────────────────────────┘
```

Each `src/*.jl` file defines a submodule of the same name. Modules import from
each other explicitly (`using ..Errors: pkgerror`), never through globals.

## Foundations

### Errors

`Errors` defines the single user-facing exception, `PkgError`, and the
`pkgerror(msg...)` helper that throws it. It renders as its bare message. The
convention is that every pinned error string is constructed at exactly one call
site, which keeps error-message tests unambiguous.

### Utils

Shared low-level helpers, most importantly the IO indirection layer: all user
output flows through `stdout_f()`/`stderr_f()`, which honor the `DEFAULT_IO`
`ScopedValue` (used to silence the precompile workload) and wrap streams via
`unstableio` into a single `IOContext{IO}` specialization. Also here:
`printpkgstyle` (the styled/indented print primitive), TOML path normalization
for Windows, `set_readonly`, and `mv_temp_dir_retries` — the atomic
temp-dir-then-rename primitive with backoff that all content-addressed installs
go through.

### Versions

Version bounds, ranges, and specs, plus the two version-string grammars:

- `VersionBound` — an `NTuple{3,UInt32}` with a significance count `n`, so
  `"1.2"` (two significant components) and `"1.2.0"` are distinct bounds.
- `VersionRange` — a lower/upper bound pair.
- `VersionSpec` — a frozen, normalized (sorted, merged, empties dropped) set of
  ranges. Specs are immutable after construction; `copy` is identity.

The `semver_spec` function parses the `[compat]` grammar (caret default, `~`,
`=`, inequalities, hyphen ranges, comma unions), which is deliberately disjoint
from the `VersionRange` grammar used inside registries.
`matches_spec_range!` is the batch membership test the resolver uses to build
its compatibility bitmasks.

### EnvFiles

Project.toml and Manifest.toml as immutable values. The important types:

- `Project` — name/uuid/version, `deps`, `weakdeps`, `extras`, `sources`
  (`SourceSpec`: path or url+rev+subdir), `compat` (`Compat` keeps both the
  parsed `VersionSpec` and the original string), `targets`, `workspace`,
  `apps`, `readonly`, and the frozen `raw` dict.
- `ManifestEntry` — name/uuid plus a `tracking` field of one of three concrete
  types: `PathTracked` (develop), `RepoTracked` (url+rev+tree hash), or
  `RegistryTracked` (version + tree hash + registry provenance). The
  `AnyTracking` union keeps dispatch type-stable, and predicates like
  `is_registry_tracked` plus accessors like `entry_version` dispatch on it.
- `Manifest` — `julia_version`, `manifest_format`, `project_hash`, a
  `Dict{UUID,ManifestEntry}`, and (format 2.1+) a `[registries]` provenance
  table of `RegistryRef`s.

Reading is split into a pure core (`parse_project` / `parse_manifest` on dicts)
and thin filesystem wrappers (`read_project` / `read_manifest`) that return
empty values for missing files. Each TOML section has a typed happy-path reader
plus a catch-all method that throws a pinned `pkgerror` on a wrong shape; dict
access uses `x::T` unpack-asserts throughout. Manifest v1 files are converted
to v2 form at read time, and conflicting `path`+repo fields are repaired at
parse time in favor of `path`.

Writing goes through `destructure_project` / `destructure_manifest`, which
deep-copy the `raw` dict and overlay typed fields, deleting keys that equal
their defaults. Because `==` skips `raw`, a freshly computed value compares
equal to its re-parsed form, which is what makes diff-aware writes work.
Functional update helpers (`with_project`, `with_manifest`, `with_entry`)
replace mutation.

### Depots

`DepotStack` is a snapshot of `Base.DEPOT_PATH` taken at operation start, so an
operation sees one consistent stack. The rule everywhere is *read from all
depots, write to the first*. Layout accessors (`packages_dir`, `clones_dir`,
`registries_dir`, `artifacts_dir`, `environments_dir`, `bin_dir`, `logdir`, …)
centralize the on-disk schema. `find_installed` probes both the current 5-char
and legacy 4-char version slugs across the stack. `log_usage` appends
compacted, pidlocked usage entries to `logs/` — the marking data GC later
relies on. `atomic_toml_write` gives torn-write-free TOML updates.

### Configs

The `Config` struct: `depots`, `io`, `server` (package server URL or
`nothing`), `offline`, `devdir`, `concurrency`, `respect_sysimage_versions`.
Its constructor is the one place environment variables (`JULIA_PKG_SERVER`,
`JULIA_PKG_OFFLINE`, `JULIA_PKG_DEVDIR`, `JULIA_PKG_CONCURRENT_DOWNLOADS`, …)
are consulted. Configs also owns the operation-option enums shared by all
frontends: `PreserveLevel`, `UpgradeLevel`, and `PackageMode`.

### Stdlibs

The stdlib model distinguishes bundled unversioned stdlibs, externally
versioned ones (jlls, Tar), and "upgradable" ex-stdlibs (DelimitedFiles,
Statistics) that are treated as ordinary packages. `stdlib_infos()` lazily
scans `Sys.STDLIB`. `get_last_stdlibs(julia_version)` resolves the stdlib set
for a *different* Julia version from tables populated externally by
HistoricalStdlibVersions.jl; `julia_version === nothing` means "treat
registered stdlibs as normal resolvable packages".

## Acquisition layer

### TreeHash

Pure git-exact tree hashing — the only content checksum used for packages and
artifacts. `tree_hash` reproduces the git tree object hash (blob headers,
git-style sort order, `.git` and empty dirs excluded), with a legacy
symlink-size variant kept for old hashes; `tree_hash_matches` accepts either.
Verification happens where content enters the store: after tarball extraction
in `Fetch.install_archive` and `ArtifactOps.try_install_from`. Git checkouts
trust LibGit2's canonical tree id instead of re-hashing.

### Git

LibGit2-backed (or CLI git when `JULIA_PKG_USE_CLI_GIT` is set) clone/fetch
with progress, shallow-clone support, and rev-shape-aware fetch escalation
(branch/tag refspecs first, unshallow for commit hashes, full refspecs as a
fallback). Clone caches live at `clones_dir/<sha1(url)[1:16]>`.
`setprotocol!` rewrites clone URLs per configured domain protocol/user.

Two functions matter to the pipeline: `install_tree_from_git!` — the fallback
when no tarball source can produce an expected tree — and
`materialize_repo_package!`, the effectful pre-phase of add-by-URL: clone or
update the cache, resolve the rev, check the (sub)tree out into the package
store, read its Project.toml, and return a `RepoPackage` (name, uuid, url, rev,
subdir, tree hash, install path). `source_fetcher(depots)` packages this up as
the closure Planning receives as its injected `fetcher`.

### Fetch

The download and package-server client layer:

- **URL priority.** `package_archive_urls` returns candidate tarball URLs in
  order: the package server (`$server/package/$uuid/$tree_hash`), then a
  synthesized GitHub archive URL for GitHub-hosted repos.
- **Protocol headers.** Requests to server-matching URLs carry
  `Julia-Pkg-Protocol: 1.0`, Julia version/system triplet, CI/interactive
  hints, any `JULIA_PKG_SERVER_*` variables forwarded as `Julia-*` headers, and
  a bearer token when available.
- **Auth.** Tokens come from `<depot1>/servers/<host>/auth.toml`; expiring
  tokens are refreshed ahead of time via the recorded `refresh_url`, a 401
  triggers one refresh-and-retry, and failures degrade to anonymous access.
  Error handlers are pluggable (`register_auth_error_handler`).
- **Install.** `ensure_package_installed!` is content-addressed: if any depot
  already has the tree it is a no-op; otherwise, under a pidlock, each
  candidate URL is downloaded, extracted (zstd or gzip sniffed by magic bytes,
  piped through `Tar.extract`), tree-hash-verified, and atomically renamed
  into `packages_dir`. If all archive sources fail it falls back to
  `Git.install_tree_from_git!`.
- `uncompress_registry` reads a packed registry tarball into an in-memory
  `filename => content` dict without extracting to disk.

## Registries

`Registries` is read-side only; add/update/remove of registries lives in the
same file but calls down into `Fetch`/`Git`. Three on-disk forms coexist under
each depot's `registries/` directory: package-server *packed tarballs*
(a `Name.toml` stub next to `Name.tar.gz`), unpacked directories
(`JULIA_PKG_UNPACK_REGISTRY`), and git clones / plain directory copies.

`reachable_registries(depots)` walks the depot stack (first depot wins
conflicts) and returns `RegistryInstance`s. Loading is lazy at two levels:

1. **Registry index.** A `RegistryInstance` holds only the path, tree info, and
   a lock until first access; `registry_info`-level access parses
   `Registry.toml` into a `LoadedRegistry` with a `Dict{UUID,PkgEntry}` and a
   name→UUIDs index. Packed registries are decompressed into an in-memory
   file dict rather than onto disk. A process-wide cache keyed on path and
   tree hash makes repeated loads cheap.
2. **Per-package info.** A `PkgEntry` holds no version data until
   `registry_info(reg, pkg)` parses that package's `Package.toml`,
   `Versions.toml`, `Deps.toml`, `Compat.toml` (and weak variants) into a
   `PkgInfo` under double-checked locking, then evicts the raw files from the
   in-memory registry to free memory.

Crucially, deps and compat stay **range-compressed** in memory exactly as the
registry stores them — `Dict{VersionRange,Set{UUID}}` and
`Dict{VersionRange,Dict{UUID,VersionSpec}}` — because uncompressing the whole
registry per operation would be prohibitively slow. Query helpers
(`query_deps_for_version`, `query_compat_for_version_multi_registry!`,
`uuids_from_name`, `is_version_yanked`, `deprecation_info`, …) answer questions
against the compressed form; the multi-registry compat query takes the first
registry that actually has the version, per dependency.

Registry installation from a package server compares tree hashes advertised by
`$server/registries` against what is installed and re-downloads on mismatch;
git-cloned registries update via fetch + fast-forward merge.

## The resolver

`Resolve` is a self-contained constraint solver, a port of Pkg's max-sum
resolver. Its inputs are UUID-keyed and still registry-compressed; the `Graph`
constructor is what converts them into numeric form:

- `GraphData` assigns each package an integer index, each version of a package
  a state index (plus one extra "uninstalled" state), and keeps the
  UUID↔index and version↔state mappings.
- For every dependency edge it builds a `BitMatrix` compatibility mask over
  the two packages' state spaces, computed from the compressed compat data via
  `Versions.matches_spec_range!`. Requirements become per-package `BitVector`
  constraints. Fixed packages (the project itself, developed and pinned
  packages) constrain the graph but are excluded from the output.

Solving proceeds in stages inside `resolve(graph)`:

1. `simplify_graph!` propagates constraints and prunes: versions that can never
   be selected are dropped and equivalence classes of indistinguishable
   versions are collapsed.
2. A **greedy fast path** tries to pick the highest version of everything and
   bails as soon as a nontrivial conflict appears — most real resolves finish
   here.
3. Otherwise **max-sum belief propagation** (message passing over the factor
   graph, with decimation and snapshot-based backtracking) searches for an
   assignment. Version preference is encoded in `FieldValue`, a 5-level
   lexicographic objective: hard constraint violations dominate, then higher
   versions of explicitly required packages, then higher versions of everything
   else, then uninstalling unneeded packages. Already-loaded versions can be
   soft-preferred via a large `VersionWeight` bonus (used by the REPL so that
   `add` in a running session favors loaded versions).
4. `enforce_optimality!` post-processes the solution to a local optimum and the
   solver re-runs with the previous solution as a lower bound until it stops
   improving.

Failures throw `ResolverError` carrying a human-readable trace assembled from
`ResolveLog`, a per-package journal of every pruning and propagation decision
(this is what produces the familiar "Unsatisfiable requirements detected"
message). A time limit (`JULIA_PKG_RESOLVE_MAX_TIME`) produces
`ResolverTimeoutError`. The output of a successful resolve is simply
`Dict{UUID,VersionNumber}` for the packages that should be installed.

## Environments

`Environments.Environment` is the value the whole pipeline pivots on:

```julia
struct Environment
    project_file::String
    manifest_file::String
    project::Project
    manifest::Manifest
    workspace::Vector{Pair{String, Project}}  # other workspace members
end
```

`load_environment` resolves the target (active project, `@shared` name, or
path), reads project and manifest via `EnvFiles`, discovers workspace members
(walking `workspace.projects` recursively and cycle-safely), and logs the
manifest to `manifest_usage.toml` for GC liveness.

`write_environment(old, new)` is diff-aware: the project file is written only
if `new.project != old.project` and likewise for the manifest (remember `==`
ignores `raw`). Before writing it re-derives the project `[sources]` table
from the manifest and enforces the `readonly` project flag.

`resolve_hash(env)` computes a SHA1 over the project's deps/weakdeps/compat;
it is stored in the manifest as `project_hash` and is how
`is_manifest_current` / `Pkg.instantiate` detect that the project changed
since the manifest was resolved.

`Queries` is a small read-only façade over environments, registries and
stdlibs (registered package names, current dependency names, deprecation
checks) used by frontends — REPL completions consume these instead of reaching
into internals.

## Planning

`Planning` holds the operation semantics: every planner takes
`(Environment, Vector{RegistryInstance}, Config, ...)` and returns a **new
`Environment`** — there is no separate "plan" struct; the planned environment
*is* the plan, and Execution later diffs it against the old one.

### Normalizing user input

The API layer converts user `PackageSpec`s into `Planning.PackageRequest`
(name/uuid/version) or, for URL/path additions, into materialized
`RepoPackage`s. `resolve_request` performs name→UUID resolution in a fixed
order: project deps/extras/weakdeps → manifest → registries → stdlibs, erroring
on ambiguity and producing fuzzy "did you mean" suggestions (via
`FuzzySorting`) on failure.

### Building resolver input

Inside a plan, manifest entries and requests become mutable working `Node`
records (never escaping the module). Seed loaders assign each node a version
constraint and a preserve policy: direct dependencies default to
`PRESERVE_DIRECT`, manifest entries to `PRESERVE_ALL`, and project `[sources]`
are overlaid on top. `collect_fixed` walks the project, workspace members, and
the recursive closure of developed/repo-tracked packages — reading their actual
Project.tomls on disk — and turns them into `Resolve.Fixed` entries (this is
where the injected `fetcher` materializes repo-tracked trees that are not yet
installed).

`deps_graph` then does a BFS from the required and fixed UUIDs, pulling
per-registry compressed deps/compat/version data through
`Registries.registry_info`, filtering yanked versions, and synthesizing
single-version entries for stdlibs from `Stdlibs.get_last_stdlibs` (stdlibs are
never resolved from registries; when resolving for the running Julia they are
fixed, and "upgradable" ex-stdlibs are ordinary packages). Its output tuple is
exactly what the `Resolve.Graph` constructor consumes.

### Tiered resolution

`resolve_versions` orchestrates: build requirements from nodes → `deps_graph` →
`Resolve.Graph` → `simplify_graph!` → `Resolve.resolve` → apply the returned
`Dict{UUID,VersionNumber}` back onto the nodes and compute the final
per-package dependency maps via `query_deps_for_version`. JLL build-number
quirks are fixed up around the solver, and tree hashes are attached from
registry data.

When the caller asks for tiered preservation (the default), `tiered_resolve`
retries with progressively weaker constraints, catching `ResolverError` at each
tier:

```
PRESERVE_ALL_INSTALLED → PRESERVE_ALL → PRESERVE_DIRECT → PRESERVE_SEMVER → PRESERVE_NONE
```

### Producing the target environment

`build_manifest` converts the resolved nodes into `ManifestEntry` values,
choosing the tracking type per node (path / repo / registry), carrying
weakdeps/extensions/apps from old entries (Execution corrects them after
install from the real Project.tomls), recording registry provenance, pruning
unreachable entries, and stamping `project_hash`. The result, packaged with the
(possibly modified) project, is the planned `Environment`.

Planner entry points map one-to-one to operations: `plan_add` (with a
`plan_promote` fast path that skips resolution when the request is already
satisfiable from the manifest), `plan_rm`, `plan_up`, `plan_develop`,
`plan_pin`, `plan_free`, `plan_resolve`, `plan_compat`. `instantiate` has no
planner at all — the manifest is used as-is.

## Execution

`Execution.apply!(old_env, planned_env, registries, config)` makes disk match
the plan:

1. `ensure_sources_installed!` walks the planned manifest and installs every
   tree that is missing from all depots. Downloads run concurrently under a
   `Base.Semaphore(config.concurrency)` with an aggregate progress bar; each
   install is pidlocked and atomic. Registry-tracked entries get candidate
   URLs from registry metadata (package server first), repo-tracked entries
   use their recorded URL, path-tracked entries are only checked for
   existence.
2. `ensure_artifacts!` collects each installed package's (Julia)Artifacts.toml
   selections and installs missing artifact trees, deduplicated by tree hash,
   with the same concurrency scheme.
3. `fixups_from_projectfile` re-reads the installed packages' Project.tomls to
   correct manifest fields the registry cannot know (weakdeps, extensions,
   entryfile).
4. `write_environment(old_env, env)` performs the diff-aware write.

`instantiate!` is the no-replan variant: it validates that every direct dep is
present in the manifest, warns if `project_hash` is stale, and runs the same
two install phases without ever rewriting the manifest.

`sandbox_manifest` — slicing a manifest to a set of roots plus their recursive
strong deps, absolutizing paths — lives here and is shared by the build and
test sandboxes.

### Artifacts

`ArtifactOps` owns networked/mutating artifact work (the Artifacts stdlib owns
lookup). Selection honors `.pkg/select_artifacts.jl` hooks (run in a minimal
Julia subprocess) over the static platform-based selection, and
`Overrides.toml` redirections are respected across the depot stack. Installation
tries `$server/artifact/$hash` first, then the Artifacts.toml `download`
entries (sha256-verified, then tree-hash-verified), through the same
download → unpack → verify → atomic-rename path as packages. Every
Artifacts.toml consulted is logged to `artifact_usage.toml` for GC.

## Frontends and user input

### API

`API` is the public façade. User input arrives as `PackageSpec`s — an immutable
record of name/uuid/version/url/rev/path/subdir — validated by
`validate_specs` (legal field combinations per operation) and partitioned by
`split_specs` into registry requests vs repo-like additions.

Nearly every operation starts with `op_context()`, which builds the
`OpContext`: a fresh `Config` (the single ENV read) plus
`reachable_registries` — bootstrapping default registries into a fresh depot,
and updating registries per policy (`:none` / `:auto` once per session /
`:force` for `up`), all skipped when offline.

The standard mutating-operation shape is:

```
load_environment → Planning.plan_* → run_plan
```

where `run_plan` executes `Execution.apply!`, prints the diff
(`Display.print_env_diff`), records an undo snapshot, runs `deps/build.jl` for
newly installed packages (`BuildOps.build!`), and auto-precompiles.
Precompilation itself is owned by Base
(`Base.Precompilation.precompilepkgs`); VibePkg only decides when to call it.
Operations that can strand data (`rm`, `up`, `pin`, `free`) end with
`_auto_gc`, which runs a GC sweep if the last one is more than a week old.

Session-level state lives only here, in module Refs and ScopedValues: offline
mode, auto-precompile/auto-gc toggles, the once-per-session registry-update
guard, `IN_REPL_MODE` (which makes `add` soft-prefer already-loaded versions),
and the undo/redo stacks — per-project vectors of `Environment` references,
capped at 50.

### REPLMode and the REPL extension

`REPLMode` implements the `pkg>` command language as data: a lazily built table
of `CommandSpec`s, each mapping one command name (plus option specs and an
argument shape) to exactly one `API` function. Input is tokenized
(quote-aware, no escapes, with `add A, B` comma sugar), package words are
parsed by a micro-syntax layer (`Name@version`, `#rev`, `:subdir`, URL/path
detection, GitHub tree/commit URL unwrapping) and folded into `PackageSpec`s,
and `ParsedCommand` dispatch calls the API function with converted options.
Completions are served from `Queries`. A `TEST_MODE` flag makes `do_cmd`
return the parsed `(api, args, opts)` tuple instead of executing, which is how
the command language is unit-tested.

`ext/REPLExt.jl` is a package extension that installs the interactive mode: a
sticky prompt (with cached `(env) vpkg>` rendering), a completion provider, and
an `on_done` that funnels the buffer into `REPLMode.do_cmd`. The same
`do_cmd(args::Vector)` entry serves the `vpkg` CLI app installed via
`pkg> app add VibePkg` (see the `@main` in `src/VibePkg.jl`).

### Display

`Display` owns all user-visible rendering, byte-compatible with Pkg's pinned
strings. Its two main consumers of pipeline data are `print_env_diff` — which
takes two `Environment`s and prints the `+`/`-`/`↑`/`↓`/`~` lines for project
and manifest — and `print_status`, which renders `Pkg.status` including
upgrade-hold glyphs (`⌃`/`⌅`, computed against registry version info),
not-downloaded markers, yanked/deprecated/loaded annotations, and the
`--outdated`/`--compat` detail views.

### Compatibility shims

`compat/` provides Pkg-namespace-compatible modules: `Artifacts` (stdlib
re-exports plus install/bind/unbind bottoming out in `ArtifactOps`),
`Registry` (add/rm/update/status over `Registries`), and `Apps` (thin wrappers
over `AppsOps`). Top-level `const add = API.add` aliases in `VibePkg.jl` mirror
Pkg's export surface.

## Side operations

- **BuildOps** runs `deps/build.jl` scripts deps-first in an isolated sandbox:
  a temp project containing only the package being built over a
  `sandbox_manifest` slice, executed in a `julia -O0` subprocess with a clean
  load path. Preferences are flattened into the sandbox (see TestOps). Logs go
  next to dev packages or into a scratchspace keyed by tree hash, and each
  build logs `scratch_usage.toml`.
- **TestOps** constructs the test sandbox: a project from `test/Project.toml`
  (or synthesized from legacy `[targets]`), the tested package force-added and
  pinned as path-tracked, preferences flattened from the full load-path
  cascade (test project over parent environment over default environments,
  via `Base.get_preferences`) into the sandbox's `JuliaLocalPreferences.toml`,
  and a manifest merged from
  the parent environment (parent wins) — then resolved and installed through
  the *normal* `plan_resolve`/`apply!` pipeline before spawning the test
  subprocess with mirrored `Base.JLOptions` flags. Workspace members skip the
  sandbox and test in place.
- **AppsOps** manages per-app environments under
  `<depot>/environments/apps/<Name>` plus a global `AppManifest.toml`, and
  installs self-locating shell/batch shims into `<depot>/bin` that exec
  `julia -m Module`. Shims embed a version stamp and are migrated in place
  when the shim format changes. App installation stages the environment in a
  temp dir via the normal plan/apply pipeline, then swaps it in atomically.
- **GCOps** is mark-and-sweep with no grace period. Mark: compact the three
  usage logs (`manifest_usage.toml`, `artifact_usage.toml`,
  `scratch_usage.toml`), drop entries whose files no longer exist, then read
  every live manifest to collect reachable package trees, clones, artifact
  trees, and scratchspaces. Sweep: delete anything in those directories not in
  the keep-sets (first depot only, unless `force`). A `gc.stamp` file throttles
  the automatic weekly sweep.

## Life of a `pkg> add Example`

Putting it all together:

1. **Parse.** REPLExt's `on_done` hands the buffer to `REPLMode.do_cmd`;
   tokenization and the package micro-syntax produce `PackageSpec("Example")`,
   and the command table dispatches to `API.add` under `IN_REPL_MODE`.
2. **Context.** `op_context` builds a `Config` (ENV read once: depot stack,
   server, offline, concurrency) and loads `reachable_registries`, updating
   them once per session unless offline.
3. **Environment.** `load_environment` parses Project.toml/Manifest.toml into
   an immutable `Environment` (logging manifest usage for GC).
4. **Normalize.** `validate_specs`/`split_specs` classify the request;
   `resolve_request` maps the name to a UUID via project → manifest →
   registries → stdlibs.
5. **Plan.** `plan_promote` first checks whether the manifest already satisfies
   the request (fast path: just promote to a direct dep). Otherwise `plan_add`
   seeds nodes from the manifest with preserve levels, collects fixed packages,
   and `deps_graph` BFS-loads compressed registry data.
6. **Resolve.** `Resolve.Graph` turns UUIDs into indices and compat into
   bitmasks; greedy solve, falling back to max-sum with tiered preserve
   retries. Output: `Dict{UUID,VersionNumber}`.
7. **Target.** `build_manifest` produces the planned `Environment` with new
   `ManifestEntry`s, tree hashes, and registry provenance.
8. **Execute.** `Execution.apply!` downloads missing package trees
   (pkg server → GitHub archive → git fallback; tree-hash-verified; atomic
   renames; concurrent under a semaphore), installs artifacts, fixes up
   weakdeps/extensions from real Project.tomls, and writes only the files
   whose values actually changed.
9. **Report.** `run_plan` prints the env diff, pushes an undo snapshot, runs
   build scripts for new installs, and auto-precompiles via
   `Base.Precompilation.precompilepkgs`.

## Cross-cutting concerns

- **Concurrency and locking.** In-process parallelism is limited to downloads
  (semaphore-gated tasks). Cross-process safety uses `mkpidlock` around every
  store-mutating step (package installs, artifact installs, usage-log appends,
  app operations) and atomicity comes from temp-dir-plus-rename
  (`mv_temp_dir_retries`) and temp-file-plus-rename (`atomic_toml_write`).
- **Laziness and caching.** Registries parse lazily at both the index and
  per-package level, stay range-compressed in memory, and are cached
  process-wide keyed by tree hash; TOML files are cached mtime-keyed via
  `Base.parsed_toml`; the completion name list is cached in `Queries`.
- **Offline mode.** `offline` lives in `Config`; it skips registry updates and
  makes planners prefer installed versions (`PRESERVE_ALL_INSTALLED` tier).
  `Fetch` itself has no offline branch — with no server configured the server
  URL source simply drops out.
- **Error handling.** All expected failures are `PkgError`s thrown via
  `pkgerror` with pinned, single-call-site messages; resolver failures carry a
  structured `ResolveLog` trace. `@assert` is reserved for internal invariants.
- **Precompile workload.** `src/precompile_workload.jl` drives the real API
  (including REPL command strings) against a hermetic synthetic registry and
  pre-materialized install trees in a temp depot, with IO silenced through
  `Utils.DEFAULT_IO`. Anything that makes operations touch the network or
  sweep the fixture depot (e.g. auto-gc) breaks precompilation; the workload
  scrubs all module-level caches afterwards so no session state leaks into the
  sysimage.
