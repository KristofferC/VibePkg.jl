# API Reference

Every REPL command is a thin layer over one function in this reference, so
anything you can do interactively you can also do from a script. The functions
live in the `VibePkg` module; the most common ones (`add`, `rm`, `up`,
`status`, …) are also exported.

## Calling conventions

Operations that produce log output accept an `io` keyword to redirect it, e.g.
`VibePkg.add("Example"; io = devnull)`. Pure queries such as `project()` and
`dependencies()`, and session toggles such as `offline()`, do not produce log
output and therefore have no `io` keyword.

The package operations `add`, `develop`, `rm`, `up`, `pin`, and `free`
uniformly accept these argument shapes:

```julia
VibePkg.add("Example")                             # a name
VibePkg.add(["Example", "JSON"])                   # several names
VibePkg.add(name = "Example", version = "0.5")     # keyword form
VibePkg.add(PackageSpec(name = "Example", version = "0.5"))
VibePkg.add([PackageSpec(name = "Example"), PackageSpec(name = "JSON")])
VibePkg.add([(; name = "Example"), (; name = "JSON", version = "0.21")])  # named tuples
```

Note that plain strings are *names only* — the REPL micro-syntax
(`"Example@0.5"`, `"Example#master"`) is not parsed by the API; use the
keyword/`PackageSpec` forms for versions, revisions, URLs, and paths.
`test` and `build` also accept the wrapper forms when each spec supplies a
`name` or UUID; their other package-spec fields are not used. `status`, `why`,
and `precompile` accept names, vectors, and `PackageSpec`s as described in
their entries below.

### The `pkg"..."` string macro

```julia
pkg"add Example"
pkg"status --manifest"
```

`pkg"..."` runs VibePkg REPL-mode syntax from Julia code. It is convenient
when translating an interactive command literally into a script; for code
that constructs package names or options dynamically, prefer the ordinary
functions.

## Types

### `PackageSpec`

```julia
PackageSpec(; name, uuid, version, url, rev, path, subdir)
PackageSpec(name)
PackageSpec(name, uuid)
PackageSpec(name, version)
```

An immutable description of a package for an operation. Only meaningful
combinations are accepted: `url` and `path` are mutually exclusive, `rev`
requires a name, URL, or path, and a `version` cannot be combined with
URL/path/`rev` tracking.

### `PreserveLevel`

Passed as `preserve` to `add` and `develop` (and optionally `up`):
`PRESERVE_ALL_INSTALLED`, `PRESERVE_ALL`, `PRESERVE_DIRECT`,
`PRESERVE_SEMVER`, `PRESERVE_NONE`, `PRESERVE_TIERED` (default),
`PRESERVE_TIERED_INSTALLED`. See [Preserve tiers](@ref preserve-tiers).

### `UpgradeLevel`

Passed as `level` to `up`: `UPLEVEL_MAJOR` (default), `UPLEVEL_MINOR`,
`UPLEVEL_PATCH`, and `VibePkg.UPLEVEL_FIXED`. The first three are exported;
the fixed-level compatibility spelling must be qualified.

### `PackageMode`

Several operations accept `mode = PKGMODE_PROJECT` (or `:project`) and
`mode = PKGMODE_MANIFEST` (or `:manifest`). Project mode acts on direct
dependencies; manifest mode widens the operation to the full resolved graph.

## Package operations

### `VibePkg.add`

```julia
add(
    pkgs; preserve = PRESERVE_TIERED, target = :deps,
    prefer_loaded_versions = false, io = stderr
)
```

Add packages to the project and resolve, download, install, and precompile as
needed. `preserve` controls how much the existing environment may move.
`target = :weakdeps` or `:extras` records registered packages in that project
table without resolving or installing them.

With `prefer_loaded_versions = true`, resolution prefers versions of packages
already loaded in the Julia session when they are not yet in the manifest.
This is the default for an interactive `vpkg>` `add`, but ordinary API calls
default to `false` for reproducibility.

### `VibePkg.develop` / `VibePkg.dev`

```julia
develop(pkgs; shared = true, preserve = PRESERVE_TIERED, io = stderr)
```

Track packages by source path. Registered names are cloned to the shared dev
directory (`shared = true`) or the project's `dev/` folder (`shared = false`);
specs with `path` are used in place. Developed packages are never
auto-precompiled. `rev` is not supported — use `add` for revision tracking.

### `VibePkg.rm`

```julia
rm(pkgs; mode = :project, all_pkgs = false, io = stderr)
```

Remove packages. `mode = :project` removes direct dependencies;
`mode = :manifest` removes manifest packages together with all their
dependents. `all_pkgs = true` removes everything in scope instead of naming
packages.

### `VibePkg.up` / `VibePkg.update`

```julia
up(pkgs = ...; level = UPLEVEL_MAJOR, mode = :project, preserve = nothing,
   workspace = false, io = stderr)
```

Update packages (all of them when none are named) within `level`, after
force-refreshing the registries. `mode = :manifest` seeds all manifest
packages; `workspace = true` includes all workspace members' dependencies;
`preserve` controls how the non-named packages are held (defaults to `all`
when names are given).

### `VibePkg.pin`

```julia
pin(pkgs; all_pkgs = false, workspace = false, io = stderr)
```

Pin packages at their current version, or at `version` when the spec carries
one (pinning to a version requires the package to be registered).

### `VibePkg.free`

```julia
free(pkgs; all_pkgs = false, workspace = false, io = stderr)
```

Return pinned, developed, or repo-tracked packages to registry tracking.

### `VibePkg.resolve`

```julia
resolve(; io = stderr)
```

Make the manifest consistent with the project without moving installed
versions, e.g. after editing project files or changing a developed
dependency's dependencies.

### `VibePkg.instantiate`

```julia
instantiate(;
    manifest = nothing, verbose = false, workspace = false,
    julia_version_strict = false, update_on_mismatch = false, io = stderr
)
```

Install exactly what the manifest records. With no manifest (or
`manifest = false`) resolves from the project first. `update_on_mismatch`
falls back to `up` when project and manifest disagree instead of erroring;
`julia_version_strict` escalates manifest Julia-version warnings to errors.

### `VibePkg.status`

```julia
status(
    pkgs = PackageSpec[];
    mode = :project, diff = false, outdated = false, deprecated = false,
    compat = false, extensions = false, workspace = false, io = stdout
)
```

Print the environment. Supplying names, UUID-bearing `PackageSpec`s, or a
vector filters the listing to matching packages; in manifest mode, a match is
shown with its dependencies. See [`status` in the REPL reference](@ref
REPL-mode) for the meaning of each toggle.

### `VibePkg.compat`

```julia
compat()                      # print the [compat] table
compat(pkg)                   # remove pkg's entry
compat(pkg, version)          # set pkg's entry
compat(; current = true)      # fill missing entries from resolved versions
```

### `VibePkg.activate`

```julia
activate()                    # the default environment
activate(path)                # the project at path
activate(name; shared = true) # a named shared environment
activate(; temp = true)       # a fresh temporary environment
activate("-")                 # the previously active environment
activate(; prev = true)       # the same, in keyword form
```

Set the environment subsequent operations act on. Activating never installs
anything. If `path` names a dependency developed at a local path, that
dependency's project is activated; otherwise the string is treated as a
filesystem path. Repeatedly activating the previous environment toggles
between the two most recent environments.

### `VibePkg.generate`

```julia
generate(path; io = stderr) -> Dict{String, UUID}
```

Create a package skeleton (`Project.toml` and `src/Name.jl`) at `path`; the
package is named after the last path component.

### `VibePkg.why`

```julia
why(pkgs; workspace = false, io = stdout)
```

Print the dependency paths from the project's direct dependencies to one or
more packages as a tree, with already-printed sub-trees shown as `Name (*)`.
Names, vectors, and `PackageSpec`s are accepted.

### `VibePkg.build`

```julia
build(pkgs = ...; verbose = false, io = stderr)
```

Run `deps/build.jl` of the given packages (default: all direct dependencies
with one), dependencies first.

### `VibePkg.test`

```julia
test(pkgs = ...; test_args = String[], julia_args = String[],
     coverage = false, allow_reresolve = true,
     force_latest_compatible_version = false,
     allow_earlier_backwards_compatible_versions = true, io = stderr)
```

Run package test suites in a sandbox (default: the active project).
`test_args` are passed to the test script's `ARGS`; `julia_args` are extra
command-line flags for the test process. Both accept either a vector of
strings or a `Cmd`. `coverage` may be a `Bool` or a coverage-path string.

The sandbox first tries to retain exact versions from the active manifest. If
that is impossible, `allow_reresolve = true` permits a fresh resolution;
setting it to `false` is useful when CI must verify the checked-in manifest.
`force_latest_compatible_version = true` raises test dependencies toward the
latest versions allowed by compat. By default it may still use earlier
backwards-compatible releases; set
`allow_earlier_backwards_compatible_versions = false` to require the latest
compatible release exactly.

### `VibePkg.precompile`

```julia
precompile(
    pkgs = String[]; strict = false, timing = false,
    workspace = false, io = stderr
)
precompile(f; kwargs...)  # defer automatic precompilation while f runs
```

Instantiate, then precompile the environment. `pkgs` limits the run to named
packages and their dependencies; `strict` makes every compile failure throw;
`timing` reports per-package time; `workspace` includes all workspace members.
The do-block form batches environment-changing operations and precompiles once
after the block.

### `VibePkg.gc`

```julia
gc(; verbose = false, force = false, io = stderr)
```

Delete depot content not reachable from any environment that still exists:
package versions, artifacts, repo clones, and scratchspaces. `force = true`
sweeps every depot in the stack instead of only the first.

### `VibePkg.offline`

```julia
offline(b::Bool = true)
```

Toggle [offline mode](@ref Offline-mode) for the session: no registry updates,
resolution restricted to installed versions.

### `VibePkg.undo` / `VibePkg.redo`

```julia
undo()
redo()
```

Step the active environment backwards/forwards through its snapshot history
(up to 50 states per project, kept for the session).

## Introspection and configuration

### `VibePkg.dependencies`

```julia
dependencies() -> Dict{UUID, PackageInfo}
```

Return the full manifest graph keyed by UUID. Each `PackageInfo` reports the
package's name, version, tree hash, source path, dependency map, whether it is
direct or pinned, and whether it tracks a registry, repository, or local path.
Because UUIDs are the keys, two packages with the same name remain distinct.

### `VibePkg.project`

```julia
project() -> ProjectInfo
```

Return the active project's name, UUID, version, project-file path, direct
dependencies, and whether the project is a package.

### `VibePkg.readonly`

```julia
readonly() -> Bool
readonly(on::Bool; io = stderr) -> Bool
```

Query or change the active project's `readonly` flag. The setter writes the
project file and returns the previous value. While enabled, operations that
would change the environment fail.

### `VibePkg.setprotocol!`

```julia
setprotocol!(;
    domain = "github.com", protocol = nothing,
    user = protocol == "ssh" ? "git" : nothing
)
```

Configure how git clone URLs for a domain are rewritten during this session.
For example, `protocol = "ssh", user = "git"` turns GitHub clone URLs into
SSH URLs; `protocol = "https"` forces HTTPS; `protocol = nothing` disables the
rewrite. When `user` is omitted it defaults to `"git"` for SSH and to no user
otherwise.

## `VibePkg.Registry`

```julia
Registry.add()          # install the default registries
Registry.add(spec...)   # install by name ("General"), URL, or local path
Registry.rm(spec...)    # remove; spec is a name, "name=uuid", or a uuid
Registry.rm(; name, uuid) # programmatic removal without string parsing
Registry.update()       # update all installed registries
Registry.update(names...) # update only the named ones
Registry.status()       # list installed registries (form, server, flavor)
```

See [Registries](@ref).

## `VibePkg.Artifacts`

Re-exports `artifact_meta`, `artifact_hash`, `artifact_exists`,
`artifact_path`, `find_artifacts_toml`, and `select_downloadable_artifacts`
from the `Artifacts` standard library, and provides:

```julia
ensure_artifact_installed(name, artifacts_toml; platform = HostPlatform()) -> path
verify_artifact(hash::SHA1) -> Bool
remove_artifact(hash::SHA1)
create_artifact(f) -> SHA1                 # f fills a fresh directory
bind_artifact!(artifacts_toml, name, hash; platform, download_info, lazy, force)
unbind_artifact!(artifacts_toml, name; platform)
```

See [Artifacts](@ref).

## `VibePkg.Apps`

```julia
Apps.add(pkg)           # install a registered package's apps by name
Apps.develop(path)      # run apps directly from a source tree
Apps.rm(name)           # remove by package or app name
Apps.update([name])     # update all apps, or one package/app
Apps.status(names...)   # list installed apps, optionally filtered
```

See [Apps](@ref).

## Package-server authentication hooks

```julia
Fetch.register_auth_error_handler(urlscheme, f) -> deregister::Function
Fetch.deregister_auth_error_handler(urlscheme, f)
```

Register `f(url, pkgserver, err) -> (handled, should_retry)` to run when a
token for an authenticated package server cannot be produced — for example to
launch a login flow that writes a fresh `auth.toml`. See
[Authentication hooks](@ref) in the protocol reference.
