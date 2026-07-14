# VibePkg.jl

Welcome to the documentation for VibePkg, a package manager for the Julia
programming language. VibePkg is a ground-up rewrite of
[Pkg.jl](https://github.com/JuliaLang/Pkg.jl) that keeps Pkg's user-facing
behavior, file formats, and public API, while rebuilding the internals around
immutable values and a strict separation between planning and execution.

## What VibePkg does

VibePkg is built around **environments**: independent sets of packages that can
be local to a single project or shared between projects. The set of packages in
an environment is recorded in two TOML files — a *project file* with your
direct dependencies and their compatibility constraints, and a *manifest file*
with the exact version of every package in the full dependency graph. A
manifest makes an environment reproducible: checking out a project and running
`instantiate` gives you exactly the package versions its author used.

Because environments are just files, different projects can use different — and
even incompatible — versions of the same packages without interfering with each
other. The actual package installations live in a shared *depot* on disk and
are reused between environments, so having many environments is cheap.

VibePkg can be used in two ways:

- through a dedicated **REPL mode**, entered by pressing `]` at the Julia
  prompt — the most convenient way to use it interactively:

  ```
  (@v1.12) vpkg> add Example
  ```

- through a normal **functional API**, which is the better fit for scripts and
  programmatic use:

  ```julia
  julia > using VibePkg

  julia > VibePkg.add("Example")
  ```

Nearly every REPL command corresponds to one API function, and the two are
documented together throughout.

## Notable capabilities

Beyond the usual add, update, and remove workflow, VibePkg includes:

- [workspaces](@ref Workspaces), which give monorepos and related projects one
  shared resolution while keeping each member's dependencies project-local;
- recursive [`[sources]`](@ref recursive-sources), so private or unregistered
  packages can describe where their own unregistered dependencies come from;
- package-author conveniences such as [compat entries created by `add`](@ref
  compat-on-add), weak dependencies, and extensions;
- a rich [`status`](@ref inspecting-status) view for finding outdated,
  constrained, deprecated, changed, and extension-providing packages; and
- transactional environment changes with `undo` and `redo`, plus isolated
  installation of command-line programs through [Apps](@ref).

## Relation to Pkg.jl

VibePkg deliberately behaves like Pkg: the same commands, the same
`Project.toml`/`Manifest.toml` formats (written byte-identically), the same
registries, package servers, and depot layout. If you know Pkg, you know
VibePkg. The differences are internal architecture, a number of fixed bugs, and
a few sharpened behaviors.

## Where to go from here

- [Getting Started](@ref) — a quick tour: installing packages, using them,
  and working with environments.
- [Managing Packages](@ref Managing-Packages) — adding, updating, pinning,
  developing, and removing packages in depth.
- [Working with Environments](@ref Working-with-Environments) — project-local
  environments, shared environments, and temporary environments.
- [Workspaces](@ref) — one shared resolution for monorepos, sibling packages,
  tests, documentation, and other projects developed together.
- [Compatibility](@ref) — declaring which versions of your dependencies your
  project works with.
- [Registries](registries.md) and [Artifacts](artifacts.md) — where packages
  come from and how binary data is handled.
- [Apps](@ref) — installing packages as command-line executables.
- [Glossary](@ref), [Project and Manifest files](@ref Project-and-Manifest),
  [REPL mode reference](@ref REPL-mode), and the [API Reference](@ref) — the
  reference material.
