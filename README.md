# VibePkg.jl

[![CI](https://github.com/KristofferC/VibePkg.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/KristofferC/VibePkg.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/KristofferC/VibePkg.jl/graph/badge.svg)](https://codecov.io/gh/KristofferC/VibePkg.jl)
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://kristofferc.github.io/VibePkg.jl/dev/)

An **agentic port of [Pkg.jl](https://github.com/JuliaLang/Pkg.jl)** — a
ground-up rewrite of Julia's package manager carried out by AI agents, as an
experiment to evaluate the strength of current models on a large, real-world
software task.

Requires Julia 1.12+.

## Installation

As a package:

```julia
pkg> add https://github.com/KristofferC/VibePkg.jl
```

As an app, which installs a `vpkg` executable into `~/.julia/bin`:

```julia
pkg> app add https://github.com/KristofferC/VibePkg.jl
```

(or `pkg> app develop <path>` from a source checkout). With `~/.julia/bin` on
your `PATH`, `vpkg` runs REPL-mode commands from the terminal against the
nearest enclosing project (like `--project=@.`):

```
$ vpkg add Example
$ vpkg st --outdated
$ vpkg test
```

## Usage

VibePkg mirrors Pkg's two interfaces.

**REPL mode** — press `]` at the Julia prompt:

```
(@v1.12) vpkg> add Example
(@v1.12) vpkg> st
```

Commands: `add`, `develop`/`dev`, `rm`/`remove`, `up`/`update`, `pin`, `free`,
`status`/`st`, `instantiate`, `resolve`, `precompile`, `test`, `build`, `gc`,
`activate`, `generate`, `compat`, `why`, `undo`, `redo`, `registry
add|remove|update|status`, `app add|develop|rm|update|status`, and `help`.

**Functional API** — the same operations as functions:

```julia
using VibePkg

VibePkg.add("Example")
VibePkg.add(name = "Example", version = "0.5")
VibePkg.develop(path = "path/to/Package")
VibePkg.up()
VibePkg.rm("Example")
VibePkg.status()
VibePkg.activate("path/to/project")
VibePkg.instantiate()
VibePkg.test("Example")
```

Pkg-compatible namespaces `VibePkg.Registry`, `VibePkg.Apps`, and
`VibePkg.Artifacts` are also provided, along with `PackageSpec` and the
`PreserveLevel`/`UpgradeLevel`/`PackageMode` enums.

## Documentation

[Read the full documentation](https://kristofferc.github.io/VibePkg.jl/dev/).
