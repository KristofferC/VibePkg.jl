# Glossary

**Project:** a source tree with a standard layout: `src` for the Julia code,
`docs` for documentation, `test` for tests, and — the part VibePkg cares
about — a project file and usually a manifest file. A project may be a
package, an application, or just an environment.

**Project file:** `Project.toml` (or `JuliaProject.toml`) at the root of a
project: metadata (name, UUID, version, authors), the direct dependencies with
their UUIDs, and compatibility constraints. Hand-editable. See
[Project and Manifest files](@ref Project-and-Manifest).

**Manifest file:** `Manifest.toml` next to a project file: the exact resolved
state of the full dependency graph — every package, its version or source, and
its dependencies. Machine-generated. A project plus its manifest is
reproducible with `instantiate`. A `Manifest-v1.12.toml` variant is preferred
by Julia 1.12 over the plain name, letting one project carry resolutions for
several Julia versions — see [Versioned manifests](@ref).

**Package:** a project with a name, UUID, and version that provides a Julia
module other projects can depend on and load. Packages are the reusable unit;
they are usually registered so they can be added by name. (A package is not
the same thing as a *module*: the module is the language-level namespace,
the package is the installable source tree that carries it — conventionally
one module of the same name.)

**Application:** a project that provides standalone functionality rather than a
reusable module — something you run, not something you depend on. Applications
that declare an `[apps]` table can be installed as command-line executables;
see [Apps](@ref). An application may choose global configuration for its
dependencies because it owns the process. A reusable package should not do so:
the application embedding it owns that policy, and sibling packages may need a
different setting.

**Environment:** what determines the meaning of `using`/`import` in a session:
a project file's dependencies together with the manifest's exact resolution.
Different environments can hold different — even incompatible — versions of the
same packages. See [Working with Environments](@ref Working-with-Environments).
Julia's code loading also accepts *implicit* environments — a bare directory
of packages, no project or manifest — but everything VibePkg manages is an
explicit project-file environment.

**Workspace:** a group of projects declared by a root project's `[workspace]`
table, resolved together into one shared manifest. See [Workspaces](@ref).

**Registry:** an index mapping package names and UUIDs to repository locations,
released versions, dependencies, and compat information. The public default is
the General registry. See [Registries](@ref).

**Depot:** the per-user directory tree (by default `~/.julia`) holding
everything the package manager stores: installed package versions, artifacts,
registries, clones, shared environments, logs, and app shims. See
[Depots](@ref).

**Depot path:** the stack of depots in use, from `JULIA_DEPOT_PATH` /
`Base.DEPOT_PATH`. All depots are searched when loading; the first depot is
where new content is written. Later entries often hold read-only system-wide
content.

**Load path:** the stack of environments (from `JULIA_LOAD_PATH` /
`Base.LOAD_PATH`) visible to `using`/`import` in a session; the active
environment is its first entry.

**Instantiate (materialize):** install everything a manifest records, exactly,
recreating the environment on any machine. This is what makes a committed
project-plus-manifest pair reproducible.

**Content-addressed storage:** each package version and artifact is stored in
the depot once, at a location derived from its content hash, and every
environment that resolves to it references that single canonical copy — disk
usage does not grow with the number of environments.

**Pinned package:** a package fixed at a specific version; no operation moves
it until it is freed.

**Developed package:** a package loaded from a local source tree, whose current
state is always used, bypassing versions and resolution for that package.
