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

If a dependency is developed at a local path, its package name is also an
activation shortcut:

```
(MyProject) vpkg> activate MyDevelopedDependency
```

This activates the dependency's project rather than a same-named path in the
current directory. The API spelling for the previous-environment shortcut is
`VibePkg.activate(; prev = true)`.

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

## Workspace overview

A workspace combines several projects into one development environment with a
shared root manifest. It is useful for monorepos whose packages are developed
together, and for keeping a package's tests, documentation, or benchmarks on
the same dependency resolution. Each member retains its own `Project.toml` and
declares its own dependencies.

The dedicated [Workspaces](@ref) chapter explains when to use a workspace,
when separate environments are a better fit, how to lay out a monorepo, how
sibling packages are path-tracked, and what `--workspace` changes.

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

To batch several operations without precompiling after each one, use the
do-block form. Automatic precompilation is suspended inside the block and one
explicit precompile happens at the end:

```julia
VibePkg.precompile() do
    VibePkg.add("Example")
    VibePkg.develop("JSON")
    VibePkg.up("HTTP")
end
```

The progress display distinguishes packages being compiled, successful
packages, packages which decline precompilation with `__precompile__(false)`,
and failures. A package that failed during automatic precompilation is skipped
on later automatic runs until its inputs change; an explicit `precompile`
retries it. Pass package names to the API (`VibePkg.precompile(["Example"])`)
to limit an explicit run to those packages and their dependency closure, or
use `strict = true` to make any failure throw.

On Julia versions whose precompiler supports background detaching, interactive
progress can be detached with `d`; compilation continues while the REPL
returns. Press `?` while the progress display is active to see the controls
provided by that Julia version.

If a new version of a package is installed while an older one is loaded in the
session, the new version is still precompiled correctly against the loaded
world — but you need a fresh session to actually use it.
