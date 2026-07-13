# [Environment variables](@id env-vars)

Every environment variable VibePkg reads, in one place. The linked sections
describe each feature in context.

## Package servers and downloads

| Variable | Effect |
|:-------- |:------ |
| `JULIA_PKG_SERVER` | The [package server](@ref Package-servers) to download packages, registries, and artifacts from. Default `https://pkg.julialang.org`; the empty string disables package servers entirely and forces fetching from the original hosts. |
| `JULIA_PKG_SERVER_*` | Any variable with this prefix is forwarded to the package server as a `Julia-*` HTTP header (`JULIA_PKG_SERVER_REGISTRY_PREFERENCE` → `Julia-Registry-Preference`), so servers can offer configuration of their own. |
| `JULIA_PKG_SERVER_REGISTRY_PREFERENCE` | The [registry flavor](@ref Registry-flavors) served by the package server: `conservative` (default) or `eager`. Applied server-side on registry update; shown by `Registry.status()`. |
| `JULIA_PKG_OFFLINE` | `true` enables [offline mode](@ref Offline-mode): no registry updates, and resolution only considers installed versions. |
| `JULIA_PKG_CONCURRENT_DOWNLOADS` | Number of parallel package/artifact downloads. Default 8. |
| `JULIA_PKG_USE_CLI_GIT` | `true` uses the command-line `git` executable instead of the built-in LibGit2 for git operations. |

## [Registries](@id env-registries)

| Variable | Effect |
|:-------- |:------ |
| `JULIA_PKG_UNPACK_REGISTRY` | `true` stores server-provided registries [unpacked as a directory tree](@ref How-registries-are-stored) instead of as a packed tarball. |
| `JULIA_PKG_GEN_REG_FMT_CHECK` | `false` silences the once-per-session nudge to reinstall a git/unpacked General registry in the faster packed form. Default true. |

## Resolution

| Variable | Effect |
|:-------- |:------ |
| `JULIA_PKG_RESOLVE_MAX_TIME` | Resolver time budget in seconds. Default 300. |
| `JULIA_PKG_RESOLVE_ACCURACY` | Resolver effort multiplier (integer ≥ 1, default 1): higher values try harder on conflict-heavy graphs at the cost of time. `JULIA_PKGRESOLVE_ACCURACY` is the legacy spelling. |
| `JULIA_PKG_PRESERVE_TIERED_INSTALLED` | `true` makes `tiered_installed` the default [preserve tier](@ref preserve-tiers) for `add`, preferring already-installed versions. |

## Precompilation

| Variable | Effect |
|:-------- |:------ |
| `JULIA_PKG_PRECOMPILE_AUTO` | `0`/`false` disables the automatic precompilation after environment-changing operations. |
| `JULIA_NUM_PRECOMPILE_TASKS` | Number of parallel precompilation tasks (honored by `Base.Precompilation`). |
| `JULIA_PKG_DISALLOW_PKG_PRECOMPILATION` | `true` makes precompiling VibePkg itself (or its REPL extension) an error. Useful when working on VibePkg, to catch an accidental recompile of the package manager mid-session. |

## Garbage collection

| Variable | Effect |
|:-------- |:------ |
| `JULIA_PKG_GC_AUTO` | `false` disables the [automatic weekly `gc`](@ref "Garbage collecting old, unused packages") that otherwise runs after `up`/`pin`/`free`/`rm`. |

## [Artifacts](@id env-artifacts)

| Variable | Effect |
|:-------- |:------ |
| `JULIA_PKG_IGNORE_HASHES` | `1` downgrades artifact tree-hash mismatches to a warning and installs anyway; `0` forbids that even on Windows, where it otherwise applies automatically for users who cannot create symlinks. See [Installation and verification](@ref Installation-and-verification). |

## Paths and tools

| Variable | Effect |
|:-------- |:------ |
| `JULIA_DEPOT_PATH` | The depot stack — where packages, registries, artifacts, and logs live. See [Depots](@ref). |
| `JULIA_PKG_DEVDIR` | Where `develop` clones packages. Default `~/.julia/dev`. |
| `JULIA_APPS_JULIA_CMD` | The julia binary [app](@ref Apps) shims launch. Default: the julia that installed the app. |

## Output

| Variable | Effect |
|:-------- |:------ |
| `CI` | `true` disables the interactive (fancy) progress output, as do non-TTY streams. |
