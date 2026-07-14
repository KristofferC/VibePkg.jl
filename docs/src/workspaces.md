# [Workspaces](@id Workspaces)

A workspace groups several projects into one development environment. Every
member keeps its own `Project.toml`, dependencies, and compatibility bounds,
while the workspace has one shared resolution recorded in the root
`Manifest.toml`.

Workspaces are most useful when the projects need to work together as one
checkout: sibling packages in a monorepo, a package plus its tests and
documentation, or several applications and libraries developed in lockstep.
They are not merely a way to organize directories—the resolver considers the
dependencies and compatibility requirements of every member together.

## When to use a workspace

Use a workspace when:

- several packages in one repository should be developed and tested against
  one another's current source trees;
- CI should verify that all members have a mutually compatible dependency
  resolution;
- tests, documentation, examples, or benchmarks should use the same versions
  as the package they exercise; or
- you want one reproducible development manifest for the whole repository.

Prefer separate environments when:

- projects intentionally need different versions of the same dependency or
  different Julia versions;
- each project must have an independently reproducible manifest;
- you are testing several compatibility combinations, such as lower bounds
  and latest dependencies; or
- resolving every project together would couple otherwise unrelated work.

A workspace gives each dependency one version in the shared manifest. This is
its main benefit and its main constraint: incompatibilities between members
are found immediately, but intentionally different resolutions require
separate environments.

## A monorepo workspace

Here is a repository with an umbrella root, two packages, and separate test
and documentation projects:

```text
MyRepository/
├── Project.toml
├── Manifest.toml
├── packages/
│   ├── CorePkg/
│   │   ├── Project.toml
│   │   └── src/CorePkg.jl
│   └── WebPkg/
│       ├── Project.toml
│       └── src/WebPkg.jl
├── test/
│   ├── Project.toml
│   └── runtests.jl
└── docs/
    ├── Project.toml
    └── make.jl
```

The root `Project.toml` declares paths relative to itself:

```toml
[workspace]
projects = ["packages/CorePkg", "packages/WebPkg", "test", "docs"]
```

The root may be an ordinary package or an umbrella project containing only the
`[workspace]` table. Each member is still a complete project. For example, if
`WebPkg` imports `CorePkg`, its own `Project.toml` declares that dependency:

```toml
name = "WebPkg"
uuid = "22222222-2222-2222-2222-222222222222"
version = "0.1.0"

[deps]
CorePkg = "11111111-1111-1111-1111-111111111111"
```

Workspace membership makes `CorePkg` path-tracked from its local member
directory, so a sibling dependency does not need a `[sources]` entry. Membership
does not make every package visible to every other package: each member must
declare every package it imports in its own `[deps]`.

!!! important "Code loading remains project-local"
    A workspace shares a manifest, not a dependency list or load path. At the
    REPL, `using` and `import` can directly load only packages declared in the
    currently active project's `[deps]`. A package being a dependency of some
    other workspace member—or merely appearing in the shared manifest—does not
    make it loadable from the active project.

    In the example above, `using CorePkg` works while `WebPkg` is active because
    `WebPkg/Project.toml` declares it. An umbrella root with no `[deps]` cannot
    directly load either member. Activate the project that owns the dependency,
    or add the dependency to the active member when it should be available
    there.

## The shared manifest

There is exactly one workspace manifest, next to the root `Project.toml` (or at
the root's explicitly configured manifest path). Members do not get their own
manifests. Resolution takes the union of member dependencies and intersects
their compatibility requirements, then records the result in that root
manifest.

If the repository commits a development manifest, commit the root manifest;
member manifests are neither needed nor used as the workspace resolution.
Repositories that do not normally commit manifests for libraries can make the
same policy choice for the workspace root.

You may activate the root or any member:

```
(@v1.12) vpkg> activate MyRepository/packages/WebPkg

(WebPkg) vpkg> resolve
```

An operation started from a member edits that member's `Project.toml`, while
resolution and installation update the root manifest. Activating a different
member changes which project is considered active, not which manifest the
workspace uses.

## Command scope and `--workspace`

Workspace resolution always accounts for all members. The `--workspace` flag
does not enable that behavior; instead, on commands that offer it, the flag
widens the command's visible or selected package set from the active member to
the whole workspace.

For example:

```text
vpkg> status                # direct dependencies of the active member
vpkg> status --workspace    # direct dependencies of every member
vpkg> up --workspace        # update with every member's dependencies in scope
vpkg> why --workspace JSON  # search paths starting from every member
```

`instantiate`, `precompile`, `pin`, and `free` also accept `--workspace` where
their operation needs an all-members scope. See the [REPL reference](@ref
REPL-mode) or [API Reference](@ref) for each command's exact options.

## Nested workspaces

A member may declare a `[workspace]` of its own. VibePkg discovers members
recursively and merges the entire tree into the outermost root's manifest.
Cycles and duplicate member paths are ignored safely, but a flat member list is
usually easier for readers unless the repository itself has a meaningful
nested structure.

## Workspaces, sources, and shared environments

These related features solve different problems:

- A **workspace** combines several projects' dependency requirements into one
  resolution and automatically path-tracks its package members.
- A **`[sources]` entry** tells one project where to find a particular direct
  dependency. The dependency is resolved normally, but the source project is
  not added as a workspace member with its own top-level requirements.
- A **shared environment** such as `@v1.12` or `@tools` is a named environment
  in the depot, useful for packages you want available across unrelated
  directories. It does not group repository projects together.

For the package-plus-tests pattern, including how `test/Project.toml` refers
back to the package, see [Adding tests](@ref). The `[workspace]` file format is
summarized in [`Project.toml` and `Manifest.toml`](@ref Project-and-Manifest).
