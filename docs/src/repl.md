# [The Pkg REPL mode](@id REPL-mode)

VibePkg comes with a REPL mode of its own. From the Julia REPL, press `]` at the
start of an empty line to enter it. The prompt changes to

```
(MyProject) vpkg>
```

where the part in parentheses shows the environment you are operating on: the
name of the active project's directory, or `@v1.12`-style names for shared
environments. The mode is sticky — after a command runs you stay in it. Press
backspace (or `Ctrl-C`) on an empty line to get back to the `julia>` prompt.

Several commands can be chained on one line by separating them with `;`:

```
(@v1.12) vpkg> add Example; status
```

Tab completion works throughout: command names at the start of the line,
registered package names after `add` and `develop`, names of packages already in
the environment after commands like `rm`, `up`, and `why`, option names after
`--`, and directory paths after `activate`.

Typing `?` (or `help`) shows a summary of all commands, and `? add` (or `?add`)
shows the full help for a single command.

!!! note
    While VibePkg is developed alongside Pkg, its REPL mode is installed
    explicitly with `VibePkg.REPLMode.install_repl!(; key = ']')` so it can
    coexist with (or replace) Pkg's own `]` mode.

## Package specification syntax

Commands that accept packages (`add`, `develop`, `pin`, …) understand a small
grammar for each word:

| Form                        | Meaning                                          |
|:--------------------------- |:------------------------------------------------ |
| `Example`                   | a registered package, by name                    |
| `Example.jl`                | the `.jl` suffix is stripped; same as above      |
| `Example@0.5`               | with a version (any `VersionSpec`, see [Compatibility](@ref)) |
| `Example=7876af07-...`      | name and UUID (disambiguates duplicate names)    |
| `7876af07-...`              | a bare UUID                                      |
| `Example#master`            | a registered package, tracked by git revision    |
| `https://github.com/...`    | a git URL, optionally with `#revision` or `:subdir` |
| `./LocalPkg`, `~/dev/Pkg`   | a local path (anything containing a slash), optionally with `:subdir` |

URLs and paths are only valid for `add` and `develop`; the other commands refer
to packages that are already part of the environment. Revisions (`#rev`) are
valid for `add` but not for `develop` — a developed package always tracks
whatever is checked out at its path.

GitHub `/tree/<rev>`, `/commit/<rev>`, and `/pull/<number>` URLs are recognized
directly and converted to the corresponding repository revision.

Words may be quoted with `'` or `"` when a path contains spaces.

## Command reference

### `add`

```
add [--preserve=<opt>] [-w|--weak] [-e|--extra]
    pkg[=uuid] [@version] [#rev] | url [#rev] [:subdir] | path ...
```

Add packages to the project. Registered names may carry a version (`@0.5`), a
UUID (`=uuid`), or a git revision (`#master`); URLs and local paths are tracked
as git sources. `--preserve` picks the resolve tier for the packages already in
the environment: `installed`, `all`, `direct`, `semver`, `none`,
`tiered_installed`, or `tiered` (the default). See
[Preserve tiers](@ref preserve-tiers) for what they mean.
`--weak` and `--extra` record registered packages in the project's
`[weakdeps]` or `[extras]` table without resolving or installing them.

**Examples**

```
vpkg> add Example
vpkg> add Example@0.5
vpkg> add Example#master
vpkg> add Example=7876af07-990d-54b4-ab0e-23690620f79a
vpkg> add https://github.com/JuliaLang/Example.jl#master
vpkg> add https://github.com/timholy/SnoopCompile.jl:SnoopCompileCore
vpkg> add --weak ChainRulesCore
vpkg> add Example JSON StaticArrays
```

### `develop`, `dev`

```
develop [--preserve=<opt>] [--shared|--local] pkg|path
```

Track a package by source path so that edits to it take effect immediately
(after a re-`resolve` picks up dependency changes). A registered name is cloned
into the shared development directory (`--shared`, the default, usually
`~/.julia/dev`) or into the project's own `dev/` folder (`--local`); a path is
used as-is.

**Examples**

```
vpkg> develop Example
vpkg> develop --local Example
vpkg> develop ./MyLocalPackage
```

### `remove`, `rm`

```
rm [-p|--project] [-m|--manifest] pkg ...
rm [-p|--project] [-m|--manifest] --all
```

Remove packages. In project mode (the default) the packages are dropped as
direct dependencies and anything no longer needed disappears from the manifest.
In manifest mode the packages are removed from the manifest together with
everything that depends on them. `--all` removes all packages in scope.

### `update`, `up`

```
up [-p|--project] [-m|--manifest] [--major|--minor|--patch|--fixed]
   [--preserve=<all|direct|none>] [--workspace] [pkg ...]
```

Update packages within the given level (`--major` is the default). With no
arguments the whole environment updates; with names, only those packages move
while the rest is held according to `--preserve`. `--manifest` seeds every
manifest package rather than just direct dependencies, and `--workspace` also
updates the dependencies of all workspace members.

**Examples**

```
vpkg> up
vpkg> up Example
vpkg> up --minor Example
```

### `pin`

```
pin pkg[@version] ...
pin [--workspace] --all
```

Pin packages at their current version, or at the given version. A pinned
package never moves — not even for `up` — until it is freed. `--all` pins every
package.

**Examples**

```
vpkg> pin Example
vpkg> pin Example@0.5.1
vpkg> pin --all
```

### `free`

```
free pkg ...
free [--workspace] --all
```

Undo a `pin`, `develop`, or repo-tracking (`#rev`): return the packages to
tracking the registry. `--all` frees everything freeable.

### `status`, `st`

```
status [-p|--project] [-m|--manifest] [-d|--diff] [-o|--outdated]
       [--deprecated] [-c|--compat] [-e|--extensions] [--workspace] [pkg ...]
```

Show the environment. Project mode (default) lists the direct dependencies;
`--manifest` lists everything in the manifest. In the listing, `⌃` marks
packages with a newer version available and `⌅` packages held back from their
newest version by compatibility constraints; `--outdated` explains what is
holding each one back. `--diff` shows the change relative to the last git
committed version of the environment files, `--compat` shows the declared
compat entries, `--extensions` the state of package extensions, `--deprecated`
flags packages marked deprecated in the registry, and `--workspace` includes
every workspace member's dependencies. Package names filter the listing to
matching entries; manifest-mode matches include their dependencies.

### `undo` / `redo`

```
undo
redo
```

Revert the active environment to its previous state, and reapply an undone
change. Each environment keeps its own undo stack for the session.

### `instantiate`

```
instantiate [-p|--project] [-m|--manifest] [-v|--verbose] [--workspace]
            [--julia_version_strict] [-u|--update_on_mismatch]
```

Make the environment ready to use: download and install exactly what the
manifest records (and precompile it). This is the command to run after checking
out a project that ships a `Manifest.toml`. `--project` ignores the manifest
and resolves from the project file instead; `--verbose` shows build output;
`--julia_version_strict` turns manifest version-check warnings into errors; and
`--update_on_mismatch` falls back to `up` when the manifest does not match the
project.

### `resolve`

```
resolve
```

Reconcile the manifest with the project — for example after a developed
dependency changed its own dependencies — while keeping installed versions in
place as far as possible.

### `precompile`

```
precompile [--strict] [--timing] [--workspace] [pkg ...]
```

Precompile all packages in the environment, or only the named packages and
their dependency closure. `--strict` makes every compile failure an error,
`--timing` reports per-package compile time, and `--workspace` includes all
workspace members. Packages are auto-precompiled after operations that change
the environment, so running this by hand is rarely needed (see
[Configuration](@ref config-envvars) for how to turn auto-precompilation off).

### `test`

```
test [--coverage] [pkg ...]
```

Run package tests in a sandboxed environment built from the package's test
setup. With no arguments the active project itself is tested. `--coverage`
enables collection of coverage statistics.

### `build`

```
build [-v|--verbose] [pkg ...]
```

Run the `deps/build.jl` script of the given packages (dependencies first), or
of every package with a build script when no names are given. `--verbose` shows
the build output directly instead of only logging it to a file.

### `gc`

```
gc [-v|--verbose] [--all]
```

Garbage-collect the depot: delete packages, artifacts, repo clones, and
scratchspaces that are no longer reachable from any environment that has been
used. Unreachable content is deleted immediately. By default only the first
depot in the depot stack is swept; `--all` sweeps all of them. `--verbose`
lists what is kept and what is deleted.

### `activate`

```
activate [path]
activate --shared name
activate --temp
activate -
```

Set the environment commands operate on. With no argument, the default (`@v#.#`)
environment; with a path, the project at that path (created on first mutation
if it doesn't exist). `--shared name` activates the named environment in the
depot's `environments` folder, creating it if needed. `--temp` creates and
activates a temporary environment that is deleted when the Julia process exits.
`activate -` toggles between the current and previously active environments.
If a name identifies a path-developed dependency, its project is activated.

**Examples**

```
vpkg> activate .
vpkg> activate MyProject
vpkg> activate --shared plotting
vpkg> activate --temp
vpkg> activate -
vpkg> activate
```

### `generate`

```
generate path
```

Create a minimal package skeleton: a `Project.toml` with a name, a fresh UUID,
and an author, plus `src/<Name>.jl` with a module definition.

### `compat`

```
compat [pkg] [version]
compat --current
```

With no arguments, show the project's `[compat]` table. With one argument,
remove that entry. With two, set the entry and re-check the environment against
it. `--current` fills in missing compat entries from the currently resolved
versions.

**Examples**

```
vpkg> compat
vpkg> compat Example 0.5
vpkg> compat Example
vpkg> compat --current
```

### `why`

```
why [--workspace] pkg ...
```

Show the dependency paths that lead from the project to the given packages as
a tree — the answer to "why is this in my manifest?". Branches terminating in
a queried package are marked with a colored `▶`; a package whose sub-tree has
already been printed is shown as `Name (*)` instead of being expanded again.

### `registry`

```
registry add [url]
registry update
registry status
```

Manage registries: `add` installs a registry (with no URL, the default
registries — typically General), `update` refreshes all installed registries,
and `status` lists them. See [Registries](@ref).

### `app`

```
app add pkg
app develop path
app rm name
app update [name]
app status
```

Manage applications: Julia packages installed so that their command-line
entry points become executables on your `PATH`. `app update` refreshes every
installed app, or only the named package/app. See [Apps](@ref).
