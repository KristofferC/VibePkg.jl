# API Reference

Every REPL command is a thin layer over one function in this reference, so
anything you can do interactively you can also do from a script. The functions
live in the `VibePkg` module; the most common ones (`add`, `rm`, `up`,
`status`, …) are also exported.

## Calling conventions

All operations accept an `io` keyword to redirect their log output, e.g.
`VibePkg.add("Example"; io = devnull)`.

The functions that take packages — `add`, `develop`, `rm`, `up`, `pin`,
`free` — uniformly accept these argument shapes:

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
`test` and `build` take plain names (`String` or `Vector{String}`).

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
`UPLEVEL_PATCH`, `UPLEVEL_FIXED`.

## Package operations

### `VibePkg.add`

```julia
add(pkgs; preserve = PRESERVE_TIERED, io = stderr)
```

Add packages to the project and resolve, download, install, and precompile as
needed. `preserve` controls how much the existing environment may move.

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
status(;
    mode = :project, diff = false, outdated = false, deprecated = false,
    compat = false, extensions = false, workspace = false, io = stdout
)
```

Print the environment. See [`status` in the REPL reference](@ref REPL-mode)
for the meaning of each toggle.

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
```

Set the environment subsequent operations act on. Activating never installs
anything.

### `VibePkg.generate`

```julia
generate(path; io = stderr) -> Dict{String, UUID}
```

Create a package skeleton (`Project.toml` and `src/Name.jl`) at `path`; the
package is named after the last path component.

### `VibePkg.why`

```julia
why(pkg; workspace = false, io = stdout)
```

Print the dependency paths from the project's direct dependencies to `pkg` as
a tree, with already-printed sub-trees shown as `Name (*)`.

### `VibePkg.build`

```julia
build(pkgs = ...; verbose = false, io = stderr)
```

Run `deps/build.jl` of the given packages (default: all direct dependencies
with one), dependencies first.

### `VibePkg.test`

```julia
test(pkgs = ...; test_args = String[], julia_args = String[],
     coverage = false, io = stderr)
```

Run package test suites in a sandbox (default: the active project).
`test_args` are passed to the test script's `ARGS`; `julia_args` are extra
command-line flags for the test process; `coverage` may be a `Bool` or a
coverage-path string.

### `VibePkg.precompile`

```julia
precompile(; io = stderr)
```

Instantiate, then precompile the environment.

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

## `VibePkg.Registry`

```julia
Registry.add()          # install the default registries
Registry.add(spec...)   # install by name ("General"), URL, or local path
Registry.rm(spec...)    # remove; spec is a name, "name=uuid", or a uuid
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
Apps.add(pkg)           # install a package's apps (name, URL, or path)
Apps.develop(path)      # run apps directly from a source tree
Apps.rm(name)           # remove by package or app name
Apps.status()           # list installed apps
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
