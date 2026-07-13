# [Working with Environments](@id Working-with-Environments)

An *environment* is an independent set of packages: a `Project.toml` with the
direct dependencies, and next to it a `Manifest.toml` with the exact resolved
version of everything. The pair fully determines what `using`/`import` load.
This chapter covers creating environments, reproducing someone else's,
temporary and shared environments, workspaces, and precompilation.

## Creating your own environments

`activate` a path to make it the active environment. Nothing is created until
the first operation writes to it:

```
(@v1.12) vpkg> activate MyProject
  Activating new project at `~/MyProject`

(MyProject) vpkg> st
Status `~/MyProject/Project.toml` (empty project)

(MyProject) vpkg> add Example
```

Now `~/MyProject` contains the two environment files. The project file lists
what you asked for:

```toml
[deps]
Example = "7876af07-990d-54b4-ab0e-23690620f79a"
```

and the manifest records the full picture, sufficient to reconstruct the
environment exactly:

```toml
# This file is machine-generated - editing it directly is not advised

julia_version = "1.12.0"
manifest_format = "2.1"
project_hash = "2ca1c6c58cb30e79e021fb54e5626c96d05d5fdc"

[[deps.Example]]
git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.5"
```

!!! note "Loaded packages and activation"
    Activating an environment does not reload anything: packages already loaded
    in the session stay as they are. The environment determines what *future*
    `using`/`import` statements load.

To start Julia directly in an environment, use the `--project` flag:

```
$ julia --project=.          # use the environment in the current directory
$ julia --project=. script.jl
```

## Using someone else's project

Because the manifest pins every version, reproducing an environment is two
commands: activate it and `instantiate` it.

```
$ git clone https://github.com/JuliaLang/Example.jl.git
$ julia

(@v1.12) vpkg> activate Example.jl

(Example.jl) vpkg> instantiate
```

`instantiate` downloads and installs exactly what the manifest records (and
precompiles it). If the project ships only a `Project.toml`, there is nothing
exact to reproduce; `instantiate` then resolves fresh versions and creates the
manifest.

If the manifest was written by a different Julia version, a warning is printed
(the resolution may not be optimal for your Julia); `instantiate
--julia_version_strict` turns that into an error, and `instantiate
--update_on_mismatch` re-resolves instead when project and manifest disagree.

## Returning to the default environment

`activate` with no argument switches back to the default environment:

```
(MyProject) vpkg> activate
  Activating project at `~/.julia/environments/v1.12`

(@v1.12) vpkg>
```

and `activate -` toggles between the current and the previously active
environment, like `cd -` in a shell.

## Temporary environments

For quickly trying a package out without touching any real environment:

```
(@v1.12) vpkg> activate --temp
  Activating new project at `/tmp/jl_a1B2c3`

(jl_a1B2c3) vpkg> add Example
```

The environment lives in a fresh temporary directory that is deleted when the
Julia process exits.

## Shared environments

A shared environment lives in the depot rather than next to any particular
project, and is addressed by name:

```
(@v1.12) vpkg> activate --shared plotting

(@plotting) vpkg>
```

The `@` in the prompt signals a shared environment; the files live in
`~/.julia/environments/plotting`. The default `v1.12` environment is itself
just a shared environment with a version-derived name.

Shared environments are useful for tool-style packages you want available
everywhere (profilers, formatters, plotting) without adding them to every
project. Note that any environment can also be put on Julia's *load path* to
make its packages loadable alongside the active project — see the Julia manual
on code loading.

## Workspaces

A *workspace* is a set of projects that resolve together and share one
manifest. The root project declares its members:

```toml
[workspace]
projects = ["test", "docs", "MySubPackage"]
```

Each member keeps its own `Project.toml` with its own dependencies, but there
is a single `Manifest.toml`, next to the root project, holding the resolved
union of everyone's dependencies with compatibility respected across all
members. This guarantees that, for example, a package and its test or docs
environment agree on shared dependency versions — and it is the natural setup
for monorepos with several packages developed in lockstep.

Operating from a member behaves as you would expect: changes to that member's
dependencies edit *its* project file, but the shared root manifest is what gets
re-resolved. Several commands accept a `--workspace` flag to widen their scope
from the active project to all members: `status`, `update`, `instantiate`,
`pin`, `free`, and `why`.

Workspaces can be nested: a member can itself declare a workspace, and the
outermost root's manifest is shared by all of them.

## Environment precompilation

After an operation changes an environment, the affected packages are
precompiled automatically, in parallel, so that the first `using` is fast:

```
(@v1.12) vpkg> add Images
    ...
Precompiling project...
  Progress [========================================>]  85/85
```

Precompilation can also be run explicitly:

```
(MyProject) vpkg> precompile
Precompiling project...
  23 dependencies successfully precompiled in 36 seconds
```

Automatic precompilation is skipped for `develop` and `resolve` (developed
code tends to be edited immediately anyway). It can be turned off entirely with
the environment variable `JULIA_PKG_PRECOMPILE_AUTO=0`, in which case packages
precompile on first load instead.

If a new version of a package is installed while an older one is loaded in the
session, the new version is still precompiled correctly against the loaded
world — but you need a fresh session to actually use it.
