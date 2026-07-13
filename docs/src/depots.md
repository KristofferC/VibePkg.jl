# Depots

The depot is where everything VibePkg installs and records lives — by default
`~/.julia`. Environments *reference* content in the depot; the depot *stores*
it, exactly once per version, no matter how many environments use it.

## The depot stack

`Base.DEPOT_PATH` is a stack of depots, configured with the
`JULIA_DEPOT_PATH` environment variable. All depots are searched when looking
things up (packages, artifacts, registries), but only the **first** depot is
written to. The last entries are Julia's own bundled depots, which hold the
standard library. A typical multi-depot setup is a per-user first depot over a
read-only, administrator-maintained shared depot on a multi-user system:

```
export JULIA_DEPOT_PATH="/home/me/.julia:/opt/julia/shared_depot"
```

A trailing empty entry (`"/custom/depot:"`) prepends the custom depot while
keeping the default entries.

## Configuring the depot path

Reasons to move the depot off its default location:

- **Roaming user profiles** — a depot holds tens of thousands of small files;
  if the home directory syncs to a server on login/logout, keep the depot out
  of it.
- **Quotas and slow filesystems** — home directories on clusters are often
  small or NFS-mounted; a depot on local scratch is faster and does not eat
  the quota.
- **Shared systems** — several users can layer their own depot over one
  centrally maintained depot (see below).

`JULIA_DEPOT_PATH` is an operating-system environment variable and must be
set before Julia starts. On Unix, put an `export` line in the shell startup
file (`~/.zshrc`, `~/.bashrc`, …); on Windows, set it per-session with
`$env:JULIA_DEPOT_PATH = "C:\custom\depot;"` in PowerShell or permanently
through the *Environment Variables* system dialog.

!!! note
    Keep the trailing separator (`:` on Unix, `;` on Windows). It expands to
    the default entries, including the bundled depots that carry the standard
    library — without it Julia falls back to precompiling the standard
    library into your depot.

The depot path can also be set from
`~/.julia/config/startup.jl` by mutating `DEPOT_PATH` directly:

```julia
empty!(DEPOT_PATH)
push!(DEPOT_PATH, "/custom/depot")
append!(DEPOT_PATH, Base.append_default_depot_path!(String[]))
```

Prefer the environment variable when possible — it takes effect before any
code loads. Never rearrange `DEPOT_PATH` in a running session that has already
loaded packages from the old locations.

## Shared depots on clusters

On HPC clusters, pointing every worker at one shared depot avoids downloading
and precompiling the same packages once per node. VibePkg serializes
conflicting depot writes across processes with pid-file locks, and Julia's
precompilation does the same, so many workers can start against a shared depot
concurrently — one does the work, the rest wait and reuse it.

Two caveats:

- Precompilation caches contain native code. If the nodes have different CPU
  generations, set `JULIA_CPU_TARGET` to a common baseline (or a multi-target
  spec) so a cache produced on one node is usable on the others.
- Put the depot on a filesystem where file locking works reliably; some
  parallel filesystems need their lock manager enabled.

## Shared depots on multi-user systems

For lab machines, JupyterHub deployments, and similar setups an administrator
can maintain one depot of common packages while users keep installing their
own. The scheme is exactly the depot stack from above:

1. the user's own depot first (all writes go here),
2. the shared read-only depot second,
3. the bundled depots last (the trailing separator).

### Administrator setup

Install into the shared location by making it the *first* depot while
installing:

```sh
sudo mkdir -p /opt/julia/shared_depot
sudo chown $ADMIN /opt/julia/shared_depot
export JULIA_DEPOT_PATH="/opt/julia/shared_depot:"
vpkg add Plots DataFrames CSV
```

Driving the installation from a committed `Project.toml`/`Manifest.toml` and
`instantiate` instead of ad-hoc `add`s makes the shared set reproducible.

Afterwards, make the depot readable but not writable for users:

```sh
sudo chmod -R a+rX,go-w /opt/julia/shared_depot
```

The `registries/` subdirectory may be deleted from the shared depot: users get
their own registry copies in their first depot anyway (only the first depot is
written to), so the shared copy is dead weight.

### User setup

Each user — or a system-wide profile script such as `/etc/profile.d/julia.sh`
— layers the shared depot into the stack:

```sh
export JULIA_DEPOT_PATH="$HOME/.julia:/opt/julia/shared_depot:"
```

Everything present in the shared depot is found there; anything else a user
adds is downloaded into their own depot. A user who needs a different version
of a shared package simply resolves to it — the version in their manifest
wins, and it installs into their depot without touching the shared one.

To pre-seed projects (student labs, container images), publish a template
`Project.toml`/`Manifest.toml`; users copy it and run `instantiate`, which
only downloads what the shared depot does not already provide.

### Updating the shared depot

Repeat the administrator setup with `up` (or an updated manifest plus
`instantiate`). New versions install *alongside* old ones, so users whose
manifests reference the old versions are unaffected. If old versions are
garbage-collected from the shared depot to save space, affected users can
`instantiate` to re-download them into their own depot.

### Troubleshooting

If shared packages are not found, inspect the stack from Julia — it shows
exactly what the environment variable expanded to:

```julia-repl
julia> DEPOT_PATH
3-element Vector{String}:
 "/home/user/.julia"
 "/opt/julia/shared_depot"
 "/usr/local/share/julia"
```

The usual causes are a missing trailing separator or the variable not being
set in the environment the Julia process actually starts from (e.g. a batch
job that does not source the profile script).

## Layout

The subdirectories of a depot, all managed by VibePkg unless noted:

| Directory              | Contents                                                            |
|:---------------------- |:------------------------------------------------------------------- |
| `packages/Name/slug/`  | installed package source trees, one per version, read-only          |
| `artifacts/<treehash>/`| installed artifact trees, content-addressed, read-only              |
| `registries/`          | installed registries (packed tarballs or unpacked trees)            |
| `clones/`              | bare git clones cached for repo-tracked packages                    |
| `environments/`        | shared environments, incl. the default `v1.x` and `apps/`           |
| `dev/`                 | default target of `develop` (`JULIA_PKG_DEVDIR` overrides)          |
| `scratchspaces/`       | per-package mutable scratch storage, incl. `build.log` files        |
| `logs/`                | usage logs (which manifests/artifacts have been used) and REPL history |
| `bin/`                 | executable shims for installed [Apps](@ref)                         |
| `servers/`             | package-server authentication (`auth.toml`)                         |
| `compiled/`            | precompilation caches (written by Julia itself)                     |

The five-character *slug* in `packages/Example/AqEK9/` distinguishes versions
(it hashes the package UUID and content tree), which is how many versions of
one package coexist.

Installed trees are immutable: `packages/` and `artifacts/` content is made
read-only on installation and verified by content hash. Anything mutable a
package needs at run time belongs in a scratchspace.

The usage logs in `logs/` are what `gc` uses to decide reachability: every
environment load appends the manifest path, and every artifact use appends the
`Artifacts.toml` path. When those files no longer exist, the content they kept
alive becomes collectable — see
[Garbage collecting old, unused packages](@ref).

`compiled/` is worth an occasional manual look: caches for Julia versions you
no longer run are never cleaned up by those Julias, so deleting stale
`compiled/v1.x` subdirectories is safe and can reclaim real space.
