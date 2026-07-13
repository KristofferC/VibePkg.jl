# Getting Started

This is a quick tour of the most common operations: installing packages, using
them, and keeping separate projects in separate environments. Everything here
uses the Pkg REPL mode, so start Julia, load VibePkg, and press `]`:

```julia-repl
julia> using VibePkg

julia> ] # press ] at an empty prompt

(@v1.12) vpkg>
```

The prompt shows the active environment — here the default `v1.12` environment.
To leave the Pkg REPL, press backspace on an empty line.

Each REPL command also exists as an ordinary function, which is what you want
in scripts: `VibePkg.add("Example")` does the same as `vpkg> add Example`.

## Installing the `vpkg` command

VibePkg also declares a Julia app named `vpkg`. Install the repository with
Julia's built-in Pkg app command:

```
(@v1.12) pkg> app add https://github.com/KristofferC/VibePkg.jl
```

For a source checkout, use `app develop /path/to/VibePkg.jl` instead. Once
`~/.julia/bin` is on `PATH`, every REPL-mode command is available directly
from the shell:

```sh
vpkg status
vpkg add Example
vpkg up
vpkg --help
```

`vpkg` operates on the nearest project in the current directory or one of its
parents. If there is no nearby project it uses Julia's versioned default
environment. Set `JULIA_PROJECT`, or pass a Julia project option before the
app separator (`vpkg --project=/path/to/env -- status`), to select one
explicitly.

!!! note
    Some output in the examples below is abbreviated for readability.

## Installing and using a package

To install a package, use `add`:

```
(@v1.12) vpkg> add Example
   Resolving package versions...
   Installed Example ─ v0.5.5
    Updating `~/.julia/environments/v1.12/Project.toml`
  [7876af07] + Example v0.5.5
    Updating `~/.julia/environments/v1.12/Manifest.toml`
  [7876af07] + Example v0.5.5
```

The package is now available to load:

```julia-repl
julia> import Example

julia> Example.hello("friend")
"Hello, friend"
```

Several packages can be added in one command:

```
(@v1.12) vpkg> add JSON StaticArrays
```

`status` (or the short form `st`) shows what is in the environment:

```
(@v1.12) vpkg> st
Status `~/.julia/environments/v1.12/Project.toml`
  [7876af07] Example v0.5.5
  [682c06a0] JSON v0.21.4
  [90137ffa] StaticArrays v1.9.7
```

The `[7876af07]` prefix is the first part of the package's UUID, which
identifies it uniquely even if two packages share a name.

Packages are removed with `rm` and updated with `up`:

```
(@v1.12) vpkg> rm JSON StaticArrays

(@v1.12) vpkg> up
```

If a package in your environment is not at its newest version, `status` marks
it with `⌃`, and `up` will move it forward as far as compatibility constraints
allow.

## Getting started with environments

So far everything went into the *default environment*. It is often better to
give each project its own environment, so that projects don't have to agree on
package versions. Create and switch to one with `activate`:

```
(@v1.12) vpkg> activate tutorial
  Activating new project at `~/tutorial`

(tutorial) vpkg> st
Status `~/tutorial/Project.toml` (empty project)
```

The new environment is empty — it knows nothing about the packages added to the
default environment. Add what the project needs:

```
(tutorial) vpkg> add Example JSON
```

This creates two files in `~/tutorial`: `Project.toml`, listing the direct
dependencies, and `Manifest.toml`, recording the exact version of everything in
the dependency graph. Together they make the environment reproducible — see
[Working with Environments](@ref Working-with-Environments).

`activate` with no argument brings you back to the default environment:

```
(tutorial) vpkg> activate
  Activating project at `~/.julia/environments/v1.12`

(@v1.12) vpkg>
```

!!! note
    Even with many environments, each package version is downloaded and stored
    only once on disk, so environments are cheap. Prefer small per-project
    environments over putting everything in the default one.

## Asking for help

Typing `?` in the Pkg REPL lists all commands with a one-line description, and
`? add` (for example) shows the full help for a single command:

```
(@v1.12) vpkg> ?

(@v1.12) vpkg> ? add
```
