# [Managing Packages](@id Managing-Packages)

This chapter goes through the package operations in depth: adding packages from
registries, git repositories, and local paths; developing packages; removing,
updating, and pinning; testing and building; and housekeeping such as garbage
collection and offline mode.

## Adding packages

### Adding registered packages

The normal way to get a package is by name, from a registry (usually the
General registry):

```
(@v1.12) vpkg> add JSON
```

VibePkg resolves a version of JSON compatible with everything else in the
environment, downloads it together with its dependencies, and records the
result. The direct dependency lands in `Project.toml`; the full dependency
graph, with exact versions, lands in `Manifest.toml`. `status` shows the
former, `status --manifest` the latter:

```
(@v1.12) vpkg> st
Status `~/.julia/environments/v1.12/Project.toml`
  [682c06a0] JSON v0.21.4

(@v1.12) vpkg> st -m
Status `~/.julia/environments/v1.12/Manifest.toml`
  [682c06a0] JSON v0.21.4
  [69de0a69] Parsers v2.7.2
  ...
```

After adding, the package can be loaded:

```julia-repl
julia> using JSON

julia> JSON.json(Dict("foo" => [1, "bar"])) |> print
{"foo":[1,"bar"]}
```

A specific version (or range — see [Compatibility](@ref)) can be requested with
`@`:

```
(@v1.12) vpkg> add JSON@0.21.1
```

If the requested version holds other packages back, `status` marks them: `⌃`
means a newer version exists and could be installed, `⌅` means a newer version
exists but compatibility constraints block it. `status --outdated` explains
which constraints are responsible.

A registered package can also be tracked by a git revision instead of a
released version:

```
(@v1.12) vpkg> add Example#master
(@v1.12) vpkg> add Example#025cf7e
```

Tracking a branch means `up` will pull in new commits to that branch. Tracking
a commit gives you that exact state. To go back to following registered
releases, use `free`:

```
(@v1.12) vpkg> free Example
```

### Adding unregistered packages

A package that is not in a registry can be added by its repository URL:

```
(@v1.12) vpkg> add https://github.com/fredrikekre/ImportMacros.jl
```

This clones the repository, reads the package's `Project.toml` for its name and
UUID, and tracks the default branch (a `#revision` suffix picks a branch or
commit). For SSH-style URLs, quote the word so the `git@` part isn't
misparsed:

```
(@v1.12) vpkg> add "git@github.com:fredrikekre/ImportMacros.jl.git"
```

If the package lives in a subdirectory of the repository, use the API and pass
`subdir`:

```julia-repl
julia> VibePkg.add(url = "https://github.com/timholy/SnoopCompile.jl", subdir = "SnoopCompileCore")
```

### Adding a local package

`add` also accepts a local path to a git repository:

```
(@v1.12) vpkg> add ~/code/MyPackage
```

Note that this records the *committed* state of the repository at add time —
uncommitted edits (and future commits) are not picked up until you `add` it
again.

!!! warning
    For a package you are actively working on, this is rarely what you want:
    use `develop` instead, which uses the source at the path directly.

### Developing packages

`develop` (short form `dev`) makes the environment load a package from a local
source tree, whatever its state — edits take effect the next time the package
is loaded, with no need to commit or re-add:

```
(@v1.12) vpkg> dev Example
```

For a registered name like this, the repository is cloned to the development
directory, by default `~/.julia/dev` (override with `JULIA_PKG_DEVDIR`), and
the environment tracks that path. With `--local` the clone goes into a `dev/`
folder next to the project instead, which is convenient for keeping everything
in one place:

```
(@v1.12) vpkg> dev --local Example
```

A path develops that source directly, without any cloning:

```
(@v1.12) vpkg> dev ~/code/MyPackage
```

To try this out: after `dev Example`, add a function to
`~/.julia/dev/Example/src/Example.jl`:

```julia
plusone(x::Int) = x + 1
```

restart Julia (or use Revise.jl to avoid restarting), and:

```julia-repl
julia> Example.plusone(1)
2
```

!!! warning
    A package can only be loaded once per Julia session. If Example was already
    loaded, the developed copy is not picked up until Julia is restarted.
    [Revise.jl](https://github.com/timholy/Revise.jl) removes most of this
    friction and is highly recommended when developing packages.

`free` stops tracking the path and returns the package to its registered
version:

```
(@v1.12) vpkg> free Example
```

Note that `develop` tracks whatever is checked out at the path — it does not
accept a `#revision`.

## Removing packages

`rm` removes packages from the project:

```
(@v1.12) vpkg> rm JSON
```

Anything that was only in the manifest to support a removed package disappears
with it. `rm --all` empties the project.

`rm` can also operate on the manifest directly, removing a package *and
everything that depends on it*:

```
(@v1.12) vpkg> rm --manifest Parsers
```

## Updating packages

`up` updates packages to their latest compatible versions, after refreshing the
registries:

```
(@v1.12) vpkg> up            # update everything
(@v1.12) vpkg> up Example    # update only Example
```

When packages are named, only they are candidates for updating; the rest of the
environment is held back as much as possible (`--preserve=all`, the default
when names are given). `--preserve=direct` also allows indirect dependencies to
move, and `--preserve=none` lets everything move if it helps:

```
(@v1.12) vpkg> up --preserve=none Example
```

The update can also be bounded by semver level: `--major` (the default),
`--minor`, `--patch`, or `--fixed` (don't move this package at all — useful in
combination with updating everything else).

Packages tracking a git branch are updated to the latest commit on that branch;
pinned and developed packages are never moved by `up`.

## Pinning a package

A pin holds a package at its version through any operation until it is freed:

```
(@v1.12) vpkg> pin Example
    Updating `~/.julia/environments/v1.12/Project.toml`
  [7876af07] ~ Example v0.5.5 ⇒ v0.5.5 ⚲
```

Pinned packages are marked with `⚲` in `status`. Pinning to a different
version directly is also allowed, as is pinning everything:

```
(@v1.12) vpkg> pin Example@0.5.1
(@v1.12) vpkg> pin --all
```

`free` removes the pin:

```
(@v1.12) vpkg> free Example
```

## [Preserve tiers: how much may an operation change?](@id preserve-tiers)

`add` and `develop` need to fit new packages into the existing environment, and
there is a trade-off between getting the newest versions and not disturbing
what is already there. The `--preserve` option (`preserve` keyword in the API)
picks the strategy:

| Value              | Meaning                                                            |
|:------------------ |:------------------------------------------------------------------ |
| `installed`        | only use versions that are already installed in the depot          |
| `all`              | keep the version of every existing package (direct and indirect)   |
| `direct`           | keep the version of every direct dependency                        |
| `semver`           | keep versions semver-compatible with what is currently there       |
| `none`             | no constraint — resolve everything freshly                         |
| `tiered`           | try `all`, then `direct`, then `semver`, then `none` (**default**) |
| `tiered_installed` | like `tiered`, but first try to add the package without downloading anything |

The default, `tiered`, means an `add` first tries not to touch your existing
versions at all and only relaxes if the resolver reports a conflict — so an
`add` typically only ever adds. Setting the environment variable
`JULIA_PKG_PRESERVE_TIERED_INSTALLED=true` makes `tiered_installed` the
default, which additionally prefers fully offline-capable resolutions.

## Testing packages

`test` runs a package's test suite (its `test/runtests.jl`) in a sandboxed
environment assembled from the package's test dependencies:

```
(@v1.12) vpkg> test Example
     Testing Example
     Testing Example tests passed
```

With no arguments the active project itself is tested. `--coverage` collects
coverage statistics while the tests run. The API form accepts a few extra
knobs: `test_args` (forwarded to the test script's `ARGS`) and `julia_args`
(extra flags for the test process).

## Building packages

Packages with a `deps/build.jl` script have it run automatically the first
time they are installed. `build` re-runs it on demand, for the named packages
and their dependencies (dependencies first), or for the whole project:

```
(@v1.12) vpkg> build IJulia
    Building Conda ─→ `~/.julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/599391.../build.log`
    Building IJulia → `~/.julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/6ac2b4.../build.log`
```

Build output is written to the indicated `build.log`; pass `--verbose` to see
it directly.

## Understanding why a package is installed

Manifests grow, and it is not always obvious what pulled a package in. `why`
prints the dependency chains from your direct dependencies down to the
package as a tree. Branches terminating in the queried package are marked
with a (colored) `▶`, and a package whose sub-tree has already been printed
is shown as `Name (*)` instead of being expanded again:

```
(@v1.12) vpkg> why Parsers
  CSV
  ├─ InlineStrings
  │  └─▶ Parsers
  ├─▶ Parsers
  └─ WeakRefStrings
     └─ InlineStrings (*)
  JSON3
  └─▶ Parsers
```

## Interpreting and resolving version conflicts

Sometimes there is no version assignment that satisfies everyone, and the
resolver reports an error. Suppose the project requires packages `B` and `C`,
`B` requires `D` at `0.1`, and `C` requires `D` at `0.2`:

```
(@v1.12) vpkg> add C
ERROR: Unsatisfiable requirements detected for package D [6f418443]:
 D [6f418443] log:
 ├─possible versions are: [0.1.0, 0.2.0] or uninstalled
 ├─restricted by compatibility requirements with B [f4259836] to versions: 0.1.0
 │ └─B [f4259836] log:
 │   ├─possible versions are: 0.1.0 or uninstalled
 │   └─restricted to versions * by an explicit requirement, leaving only versions 0.1.0
 └─restricted by compatibility requirements with C [c99a7cb2] to versions: 0.2.0 — no versions left
   └─C [c99a7cb2] log: ...
```

Read the tree from the top: each `restricted by` line is one constraint on
`D`, and the error is that their intersection is empty. Ways out, in rough
order of preference:

- update the packages involved (`up B C`) — a newer release may have widened
  its compat;
- relax your own `[compat]` entries if they are the restriction;
- if a dependency's compat is outdated, `develop` it, widen its `[compat]`
  entry, verify with its tests, and contribute the fix upstream (see
  [Fixing conflicts](@ref compat-fixing-conflicts));
- as a last resort, remove one of the conflicting packages.

Note that if the environment already resolved once, a failed operation changes
nothing — planning happens on an in-memory copy and is only written out when it
succeeds.

## Yanked packages

Registries can *yank* a released version — mark it as broken or harmful.
Yanked versions are never selected by the resolver, but an environment that
already has one keeps working; `status` flags it:

```
(@v1.12) vpkg> st
Status `~/tutorial/Project.toml`
  [7876af07] Example v1.2.0 [yanked]
```

Update or re-resolve to move off a yanked version.

## Garbage collecting old, unused packages

Every package version, artifact, and repository clone is stored once in the
depot and shared between environments. As environments change and disappear,
content becomes unreachable. `gc` finds and deletes it:

```
(@v1.12) vpkg> gc
      Active manifest files: 5 found
      Active artifact files: 32 found
      Active scratchspaces: 6 found
     Deleted 4 package installations (60.202 MiB)
     Deleted 2 artifact installations (124.031 MiB)
```

Reachability is computed from usage logs the package manager keeps: every
manifest that has been loaded, every artifact that has been used. A manifest
file that no longer exists on disk no longer keeps its packages alive.
Unreachable content is deleted immediately — there is no grace period. By
default only the first depot in the depot stack is swept; `gc --all`
(`force = true` in the API) sweeps all writable depots.

A collection also runs automatically after `up`, `pin`, `free`, and `rm` when
the depot has not been swept for a week. Set the environment variable
`JULIA_PKG_GC_AUTO=false` (or call `VibePkg.API.auto_gc(false)` for the
session) to disable the automatic collection.

## Offline mode

Offline mode makes VibePkg operate without touching the network: registries are
not updated, and the resolver only considers package versions that are already
installed.

```julia-repl
julia> VibePkg.offline(true)
```

The same is achieved by setting the environment variable `JULIA_PKG_OFFLINE=true`.
Operations that fundamentally require the network (adding a package that is not
installed, for instance) will fail cleanly.

## Undoing changes

Every operation that changes the environment first snapshots it, and `undo`
steps back through those snapshots (`redo` steps forward again):

```
(@v1.12) vpkg> rm JSON

(@v1.12) vpkg> undo    # JSON is back

(@v1.12) vpkg> redo    # removed again
```

Each project keeps its own undo history (up to 50 states) for the duration of
the session.

## Package servers

By default packages, registries, and artifacts are downloaded from a *package
server* (`https://pkg.julialang.org`), which serves them as content-verified
tarballs — faster and firewall-friendlier than cloning repositories. Set
`JULIA_PKG_SERVER` to use a different server (for instance a private mirror),
or set it to the empty string to bypass package servers entirely and fetch from
the original hosts. Content is verified by tree hash regardless of where it
came from, and unregistered `add url` packages always come from their git host.

Downloads run in parallel; `JULIA_PKG_CONCURRENT_DOWNLOADS` (default 8)
controls how many at a time.

The wire protocol, server-side authentication, and how to hook into
authentication failures are described in
[Package server protocols](@ref Pkg-Server-Protocols).

## [Configuration through environment variables](@id config-envvars)

Most of VibePkg's behavior can be configured through `JULIA_PKG_*` environment
variables — the package server to use, offline mode, automatic precompilation
and garbage collection, resolver budgets, and more. The full reference lives
on its own page: [Environment variables](@ref env-vars).
