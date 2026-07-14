# [`Project.toml` and `Manifest.toml`](@id Project-and-Manifest)

Every environment is described by up to two TOML files. `Project.toml` is the
high-level, hand-editable description: dependencies, compatibility, package
metadata. `Manifest.toml` is the machine-generated record of an exact
resolution: every package in the dependency graph with its version and origin.
Both are written deterministically (sorted, stable formatting), so they diff
well under version control.

If a `JuliaProject.toml` exists it takes precedence over `Project.toml`
(useful when another tool claims the name `Project.toml`), and pairs with
`JuliaManifest.toml`.

## `Project.toml`

### `name`

The name of the package. Must be a valid Julia identifier. Required for a
package (together with `uuid`); optional for a plain environment. For
choosing a good one, see [Package naming rules](@ref).

### `uuid`

A UUID identifying the package independent of its name. Required for a
package; `generate` creates one, or produce one manually with
`using UUIDs; uuid4()`. Never change it after registration — identity, not
the name, is what the rest of the ecosystem depends on.

### `version`

The package's version, e.g. `version = "1.2.5"`. Interpreted by semantic
versioning, with the pre-1.0 rules described in [Compatibility](@ref).

### `authors`

A TOML array whose entries are either `"NAME"` / `"NAME <EMAIL>"` strings or
tables following the Citation File Format person/entity schema. Tables are
useful for structured names and identifiers:

```toml
authors = [
    "Some One <someone@example.com>",
    {given-names = "Ada", family-names = "Lovelace", orcid = "https://orcid.org/0000-0000-0000-0000"},
]
```

### `readonly`

Setting `readonly = true` marks the environment as immutable: operations that
would modify it error instead, and `status` shows a `(readonly)` suffix.
Useful for environments that are deployed or shared and must not drift.

### `[deps]`

The direct dependencies, as `Name = "UUID"` pairs:

```toml
[deps]
Example = "7876af07-990d-54b4-ab0e-23690620f79a"
```

### `[sources]`

Where to get specific dependencies from, when it isn't a registry: a path, or
a url with an optional revision and subdirectory.

```toml
[sources]
Example = {url = "https://github.com/JuliaLang/Example.jl", rev = "master"}
WithinMonorepo = {url = "https://example.com/BigProject.git", subdir = "packages/WithinMonorepo"}
SomeDependency = {path = "deps/SomeDependency.jl"}
```

`url` and `path` are mutually exclusive; `rev` and `subdir` refine a URL
source. Sources override registry information for the direct dependencies of
the active project. They are a development convenience, not metadata that
ordinary consumers of a registered package inherit.

There is one intentional exception: when a package itself is added by URL or
path, VibePkg recursively follows that package's own `[sources]` entries. This
allows a chain of unregistered or private packages to describe where its
dependencies come from without a registry. See [Private dependency trees with
`[sources]`](@ref recursive-sources) for a complete example. Sources are
written automatically when you add a URL/local repository or `develop` a
package.

### `[compat]`

Version requirements for the entries in `[deps]`, `[weakdeps]`, and
`[extras]`, plus `julia`. See [Compatibility](@ref) for the syntax.

### `[weakdeps]` and `[extensions]`

Weak dependencies are packages your package can cooperate with without
requiring; extensions are the modules that load when they appear. See
[Weak dependencies and extensions](@ref) in Creating Packages.

```toml
[weakdeps]
Contour = "d38c429a-6771-53c6-b99e-75d170b6e991"

[extensions]
ContourExt = "Contour"
```

### `[workspace]`

Declares a workspace by listing the member projects (relative paths):

```toml
[workspace]
projects = ["test", "docs"]
```

All members share the manifest of the workspace root. See
[Workspaces](@ref).

### `[extras]` and `[targets]` (legacy)

The older mechanism for test-only dependencies:

```toml
[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
```

Supported, but the workspace-based test project is preferred — see
[Adding tests](@ref).

Any other top-level keys are preserved verbatim across operations, so tools may
store their own configuration in the project file.

## `Manifest.toml`

The manifest is machine-generated; editing it by hand is not advised. Its
top-level fields:

```toml
julia_version = "1.12.0"
manifest_format = "2.1"
project_hash = "2ca1c6c58cb30e79e021fb54e5626c96d05d5fdc"
```

- `julia_version` — the Julia that produced the resolution. `instantiate`
  warns (or errors with `--julia_version_strict`) when it doesn't match the
  running Julia at minor-version granularity.
- `manifest_format` — the file format version. VibePkg writes `2.1`; format
  `1` manifests (pre-Julia-1.7, flat layout) are still read, with a warning,
  and are upgraded the next time the environment is resolved.
- `project_hash` — a hash of the project file contents the manifest was
  resolved against; how VibePkg detects that project and manifest are out of
  sync.

A `[registries]` table records which registries provided the resolution
(format 2.1):

```toml
[registries.General]
uuid = "23338594-aafe-5451-b93e-139f81909106"
url = "https://github.com/JuliaRegistries/General.git"
```

The UUID is required; the optional URL records where the registry came from.

### Package entries

Each package in the graph gets one entry under `[[deps.Name]]`. Which fields
appear depends on how the package is tracked:

```toml
# Registered package at a released version
[[deps.Example]]
git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
registries = "General"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.5"

# Tracking a git branch (or commit — repo-rev is then the SHA)
[[deps.Example]]
git-tree-sha1 = "..."
repo-rev = "master"
repo-url = "https://github.com/JuliaLang/Example.jl.git"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.6"

# With dependencies of its own
[[deps.Foo]]
deps = ["Example"]
git-tree-sha1 = "..."
uuid = "..."
version = "1.0.0"

# Developed (tracking a path)
[[deps.Example]]
path = "/home/user/.julia/dev/Example"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.6"

# Pinned
[[deps.Example]]
git-tree-sha1 = "..."
pinned = true
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.5"
```

`deps` lists the entry's own dependencies by name (as a nested table with
UUIDs in the rare case that two packages in the manifest share a name), and
`git-tree-sha1` is the content hash the installation is verified against.
For registry-tracked entries, `registries` names the `[registries]` records
that supplied that version; it is an array when several registries contain it.

### Packages with the same name

Package identity is the UUID, not the name, so one manifest can contain two
different packages both called `B`. In that case `[[deps.B]]` appears twice,
and a package depending on one of them expands its dependency list to a
name-to-UUID table:

```toml
[[deps.A]]
uuid = "ead4f63c-334e-11e9-00e6-e7f0a5f21b60"

    [deps.A.deps]
    B = "f41f7b98-334e-11e9-1257-49272045fb24"

[[deps.B]]
uuid = "f41f7b98-334e-11e9-1257-49272045fb24"

[[deps.B]]
uuid = "edca9bc6-334e-11e9-3554-9595dbb4349c"
```

### Versioned manifests

A file named `Manifest-v1.12.toml` (for example) is preferred over
`Manifest.toml` when running Julia 1.12, letting one project carry resolutions
for several Julia versions side by side. VibePkg honors such files when they
exist but never creates them itself.
