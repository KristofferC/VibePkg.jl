# Registries

A registry is an index of packages: for every registered package it records the
name, UUID, repository location, released versions, their dependencies, and
their compatibility constraints. When you `add JSON`, registries are what turn
the name into a UUID and a set of resolvable versions. Any number of registries
can be installed at once — including private ones next to the public
[General](https://github.com/JuliaRegistries/General) registry — and packages
from all of them resolve together.

## Managing registries

On first use, when no registry is installed, the default registries (General)
are installed automatically. Registries can also be managed explicitly with
the `registry` REPL command; each subcommand exists as a function under
`VibePkg.Registry` too (`Registry.add`, `Registry.rm`, `Registry.update`,
`Registry.status`), taking the same strings.

Registries are always installed into the first depot in the
[depot stack](@ref Depots) — the same place all other writes go.

### Adding

`registry add` with no arguments installs every registry the package server
advertises — the same thing that happens automatically on first use. With
arguments, each one may be:

- a **known registry name**: `registry add General` works even without a
  package server (it falls back to a git clone of the known URL),
- a **git URL**: `registry add https://example.com/OurRegistry.git`,
- a **local path**: a git repository or a plain directory containing a
  `Registry.toml`.

```
(@v1.12) vpkg> registry add https://github.com/JuliaRegistries/General
```

When the configured package server advertises the requested registry, it is
fetched from there (in the fast packed form); otherwise it is git-cloned.

### Status

`registry status` (or `registry st`) lists the installed registries with
their short UUID, source, and on-disk form, and — for registries the package
server tracks — the serving server, the selected
[flavor](@ref Registry-flavors), and whether an update is available:

```
(@v1.12) vpkg> registry st
Registry Status
  [23338594] General (https://github.com/JuliaRegistries/General.git)
    packed registry, server https://pkg.julialang.org, flavor conservative
```

### Removing

`registry remove` (or `registry rm`) deletes an installed registry:

```
(@v1.12) vpkg> registry rm General
```

If several installed registries share a name, disambiguate with the UUID,
using the same `name=uuid` syntax as for packages:

```
(@v1.12) vpkg> registry rm General=23338594-aafe-5451-b93e-139f81909106
```

### Updating

`registry update` (or `registry up`) refreshes all installed registries;
naming one or more updates just those:

```
(@v1.12) vpkg> registry up General
```

Manual updates are rarely needed: registries are refreshed automatically once
per session by the first `add`/`develop`, and on every `up`.

## [How registries are stored](@id How-registries-are-stored)

A registry can exist in the depot in four forms; `registry status` shows
which one is installed:

- **packed** (the default with a package server): a single compressed tarball
  next to a small `Name.toml` pointing at it, read directly without
  unpacking. Fastest to download and read, and keeps file counts down.
- **unpacked**: the same server-provided data extracted to a directory tree
  (with a `.tree_info.toml` recording its content hash). Opt in with
  `JULIA_PKG_UNPACK_REGISTRY=true` — useful when you want to grep the files.
- **git clone**: the result of adding a registry by URL or path when the
  package server does not provide it. Updates fetch and fast-forward the
  clone, so they appear as soon as they are committed upstream, at the cost
  of carrying the full git history on disk.
- **bare directory**: a plain copy of registry files, installed from a local
  non-git path. Never updated automatically.

Server-backed registries (packed and unpacked) are updated by comparing the
server's current content hash with the installed one and re-downloading on
change. To convert a registry between forms, remove and re-add it — with the
package server for the packed form, by URL for a git clone. Setting
`JULIA_PKG_SERVER=""` disables package servers entirely, forcing git clones
even for the default registries.

Since General is large, VibePkg nudges once per session if it finds it
installed in the slower git/unpacked form; `JULIA_PKG_GEN_REG_FMT_CHECK=false`
silences that.

## Registry format

A registry is a directory (or tarball) with a top-level `Registry.toml` and
one directory per registered package. Knowing the layout helps when reading a
registry or maintaining a private one.

### `Registry.toml`

Identifies the registry and indexes its packages:

```toml
name = "OurRegistry"
uuid = "..."
repo = "https://example.com/OurRegistry.git"
description = "In-house packages"

[packages]
7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
```

`path` locates the package's directory, which holds the files below.

### `Package.toml`

The package's identity: `name`, `uuid`, the `repo` it is cloned from, and
optionally `subdir` when the package lives in a subdirectory of its
repository. An optional `[metadata]` table carries extensible per-package
metadata; the table VibePkg itself understands is `[metadata.deprecated]`:

```toml
name = "Example"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
repo = "https://github.com/JuliaLang/Example.jl.git"

[metadata.deprecated]
reason = "no longer maintained"
alternative = "BetterExample"
```

A deprecated package still resolves and installs normally, but is flagged in
`status` output, omitted from tab completion, and `status --deprecated`
prints the `reason` and `alternative` fields — see
[Deprecated packages](@ref) below.

### `Versions.toml`

One entry per released version, mapping it to the content hash of its source
tree (which is what `add` verifies downloads against). A version can also be
marked yanked:

```toml
["0.5.4"]
git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"

["0.5.5"]
git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
yanked = true
```

A yanked version is kept out of resolution for new environments but remains
installable from existing manifests — see [Yanked packages](@ref).

### `Deps.toml` and `Compat.toml`

`Deps.toml` records which dependencies each version has; `Compat.toml`
records the constraints on them. To keep the files small, versions with
identical data are grouped under dash ranges of versions:

```toml
["0.8-0.9"]
DependencyA = "0.4-0.5"

["0.9.2-0.9.5"]
DependencyB = "1"
```

A dash range covers everything from the left endpoint up to where the right
endpoint's prefix stops matching: `0.8-0.9` means `[0.8.0, 0.10.0)`, `0.7-0`
means `[0.7.0, 1.0.0)`, and `0.7-*` is unbounded above. Blocks can overlap —
a version picks up the data of every block containing it, so in the example
versions `0.9.2`–`0.9.5` depend on both `DependencyA` and `DependencyB`.

`WeakDeps.toml` and `WeakCompat.toml` have the same shape and cover
[weak dependencies](@ref Weak-dependencies-and-extensions).

## [Registry flavors](@id Registry-flavors)

The default package server (`pkg.julialang.org`) offers two "flavors" of
registry:

- `conservative` (the default): suitable for most users; every package and
  artifact in this flavor is available from the package server itself, with no
  need to download from other sources
- `eager`: carries the very latest versions, even those the package server has
  not finished processing — some packages and artifacts may have to be
  downloaded from their original hosts (such as GitHub)

The environment variable `JULIA_PKG_SERVER_REGISTRY_PREFERENCE` selects the
flavor; the selection itself happens on the server, per request. To switch,
set it and update:

```julia
ENV["JULIA_PKG_SERVER_REGISTRY_PREFERENCE"] = "eager"

import VibePkg

VibePkg.Registry.update()
```

`VibePkg.Registry.status()` shows the selected flavor next to the serving
package server, along with whether a registry update is available.

## Deprecated packages

A registry can mark a package as deprecated (no longer maintained, usually with
a suggested alternative) via the `[metadata.deprecated]` table described
above. Deprecated packages resolve normally, but
`status --deprecated` flags them in your environment so you can plan a
migration.

Registries can also *yank* individual versions — see
[Yanked packages](@ref).

## Creating and maintaining registries

VibePkg is a registry *client*: it installs, reads, and updates registries,
but has no commands for authoring them. The ecosystem tools for that are
[Registrator.jl](https://github.com/JuliaRegistries/Registrator.jl) (register
packages in General or a private registry),
[LocalRegistry.jl](https://github.com/GunnarFarneback/LocalRegistry.jl)
(create and update a registry with a git remote), and
[RegistryCI.jl](https://github.com/JuliaRegistries/RegistryCI.jl) (automated
testing and merging for registry pull requests). A registry produced by any
of them is added with `registry add <url>` as described above.
