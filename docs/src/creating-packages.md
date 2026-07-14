# Creating Packages

A package is a project with a `name`, a `uuid`, and a `version` in its
`Project.toml`, and a `src/PackageName.jl` that defines the module
`PackageName`. Packages are the unit of code that can be depended on,
versioned, and registered.

## Generating a package skeleton

`generate` creates the minimal structure:

```
(@v1.12) vpkg> generate HelloWorld
  Generating  project HelloWorld:
    HelloWorld/Project.toml
    HelloWorld/src/HelloWorld.jl
```

giving

```
HelloWorld/
├── Project.toml
└── src
    └── HelloWorld.jl
```

The project file has the three package-defining fields (the author is taken
from your git configuration):

```toml
name = "HelloWorld"
uuid = "b4cd1eb8-1e24-11e8-3319-93036a3eb9f3"
version = "0.1.0"
authors = ["Some One <someone@email.com>"]
```

and the source file defines the module:

```julia
module HelloWorld

greet() = print("Hello World!")

end # module
```

Activate the package's environment to use and work on it:

```
(@v1.12) vpkg> activate ./HelloWorld

julia> import HelloWorld

julia> HelloWorld.greet()
Hello World!
```

!!! note
    `generate` is intentionally minimal. For registered packages you will also
    want tests, CI configuration, licensing, and documentation —
    [PkgTemplates.jl](https://github.com/JuliaCI/PkgTemplates.jl) generates all
    of that.

## Adding dependencies

With the package's environment active, `add` records dependencies in the
package's own `[deps]` table:

```
(HelloWorld) vpkg> add Random JSON
```

Because `HelloWorld` is a package project (its `Project.toml` has both a name
and UUID), `add` also creates a `[compat]` entry for each newly added direct
dependency, beginning at the version that was resolved. Existing compat
entries are left unchanged. Treat the generated entry as a useful starting
point: before publishing, adjust it to describe the full range your package
actually supports. See [Compatibility entries created by `add`](@ref
compat-on-add).

They are then loadable from the package:

```julia
module HelloWorld

import Random
import JSON

greet() = print("Hello World!")
greet_alien() = print("Hello ", Random.randstring(8))

end # module
```

## Defining a public API

Names that are part of your package's supported surface should be marked, so
users can tell API from internals:

- `export greet` makes `greet` available with `using HelloWorld` **and** marks
  it public;
- `public greet_alien` marks it public without exporting it (users call
  `HelloWorld.greet_alien()`).

Everything else is internal by convention, and may change in any release.
Changes to the public API are what drive your version number: breaking changes
require a new major version (or a new minor version while below 1.0) — see
[Compatibility](@ref).

## Adding tests

Tests live in `test/runtests.jl` and run with `vpkg> test` in a sandboxed
environment. Test-only dependencies are best declared with a *workspace*: give
the test directory its own project that develops the package by path.
This is one application of the general workspace model; see [Workspaces](@ref)
for monorepos, sibling packages, and guidance on choosing a shared versus an
independent resolution.

`HelloWorld/Project.toml` declares the workspace:

```toml
name = "HelloWorld"
uuid = "b4cd1eb8-1e24-11e8-3319-93036a3eb9f3"
version = "0.1.0"

[workspace]
projects = ["test"]
```

and `test/Project.toml` holds the test dependencies plus the package itself via
`[sources]`:

```toml
[deps]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
HelloWorld = "b4cd1eb8-1e24-11e8-3319-93036a3eb9f3"

[sources]
HelloWorld = {path = ".."}
```

That file is created for you by activating the test project and adding to it:

```
(HelloWorld) vpkg> activate ./test

(test) vpkg> dev .

(test) vpkg> add Test
```

Since the workspace shares one manifest, the package and its tests always agree
on dependency versions. The same pattern extends to docs and benchmarks:
`projects = ["test", "docs", "benchmarks"]`.

Any package imported directly by the tests must appear in `test/Project.toml`;
the parent package's dependencies are not implicitly inherited by the test
project.

### Separate test environments

A `test/Project.toml` can also be used without putting `test` in the root
workspace. Give it the same `[deps]` and `[sources]` entry shown above. It then
has its own `test/Manifest.toml`, resolved independently from the package's
environment:

```
$ julia --project=test

julia> using HelloWorld, Test

julia> include("test/runtests.jl")
```

This is useful when the test environment deliberately needs a different
resolution. A workspace is usually preferable because its one manifest makes
incompatibilities between the package and its tests visible immediately.

### Legacy: target-based test dependencies

Older packages declare test dependencies in `[extras]` with a `test` target:

```toml
[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
```

This still works, but the workspace setup above is preferred — it gives the
tests a real project file and a shared, committed resolution.

`vpkg> add --extra Test` adds the `[extras]` entry; the target still needs to
be declared in the file.

## Adding a build step

A `deps/build.jl` script runs automatically the first time the package is
installed, and on `vpkg> build`:

```julia
# deps/build.jl
println("I am being built...")
```

```
(HelloWorld) vpkg> build
    Building HelloWorld → `.../scratchspaces/.../build.log`
```

A failing build prints the log and errors the install. Build steps are the
legacy mechanism for fetching binaries; new packages should almost always use
[Artifacts](@ref) instead, and per-user configuration should use
[Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl).

!!! warning
    The build step must not modify the package's own directory: installed
    packages are read-only and shared between environments. Write to a
    scratchspace ([Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl))
    instead.

The same immutability rule applies to tests: they may run against an installed,
read-only source tree. Put temporary output in a temporary directory or a
scratchspace, not under the package directory.

## Compatibility on dependencies

Every dependency of a package should have a `[compat]` entry — registries
require it, and it is what makes resolution reproducible and safe:

```toml
[compat]
JSON = "0.21"
julia = "1.12"
```

See [Compatibility](@ref) for the specifier syntax.

## Weak dependencies and extensions

A package can ship code that only activates when some *other* package is
loaded, without depending on it unconditionally. The optional package is
declared as a weak dependency, and the conditional code as an extension module:

```
(Plotting) vpkg> add --weak Contour
```

```toml
name = "Plotting"
version = "0.1.0"
uuid = "..."

[weakdeps]
Contour = "d38c429a-6771-53c6-b99e-75d170b6e991"

[extensions]
# name of the extension => weak dependencies it needs
ContourExt = "Contour"

[compat]
Contour = "0.6.2"
```

The extension lives in `ext/ContourExt.jl`:

```julia
module ContourExt # Same name as declared in Project.toml

using Plotting, Contour

function Plotting.plot(c::Contour.ContourCollection)
    # plotting a contour
end

end # module
```

An extension with more than one file uses a directory instead:
`ext/ContourExt/ContourExt.jl` plus whatever it includes. The name is free to
choose (output always shows it together with its parent package), and an
extension can require several weak dependencies at once:
`ExtName = ["PkgA", "PkgB"]`.

### How extensions behave

`ContourExt` loads automatically — in the background, like precompilation —
once both `Plotting` and `Contour` are loaded into the same session, and it
precompiles like a package. Users who never load `Contour` pay nothing for
the extension's existence. Weak dependencies need `[compat]` entries like
regular ones, but are not installed unless something else brings them in.

The archetypal extension adds *methods* to functions of its parent package,
as `Plotting.plot(c::Contour.ContourCollection)` does above. The parent can
even declare the function with zero methods — `function plot end` — leaving
all implementations to extensions. (Strictly speaking the extension owns
neither `Plotting.plot` nor `Contour.ContourCollection`, which would normally
be type piracy; an extension is considered part of its parent, so extending
the parent's functions is fine.)

An extension can also define new names — types, functions — but those live in
the extension module, not in the parent. When the parent needs them, it can
fetch the module once the extension has loaded:

```julia
ext = Base.get_extension(@__MODULE__, :ContourExt)
if ext !== nothing
    ContourPlotType = ext.ContourPlotType
end
```

Third-party packages should not reach into someone else's extension this way
— anything meant for external consumption belongs in the parent package's
public API.

`vpkg> status --extensions` shows the extensions of the environment and
whether each is loaded.

!!! note "Manifests from older Julia versions"
    A manifest generated by a Julia version that predates extensions does not
    contain the metadata needed to load them. Regenerate the manifest with a
    Julia version that supports extensions before relying on them.

### Testing extensions

The package's own tests usually want the extensions active. With the
workspace test setup from [Adding tests](@ref) that is just a matter of
adding the weak dependencies to `test/Project.toml` — loading them in the
test session triggers the extensions like anywhere else.

Extensions replaced the callback-based
[Requires.jl](https://github.com/JuliaPackaging/Requires.jl) pattern, with
the advantage that extension code precompiles and participates in resolution
via `[compat]`.

### Supporting Julia versions without extensions

If the package must also run on Julia versions older than 1.9, keep the modern
`[weakdeps]`/`[extensions]` declaration and provide an old-Julia bridge. A
package migrating from Requires.jl can keep `Requires` in both `[deps]` and
`[weakdeps]`, then install its `@require` callback only when
`Base.get_extension` is not defined. Another migration path is to list the
optional package in both `[deps]` and `[weakdeps]` and include the extension
file directly on old Julia versions. New Julia versions treat the overlapping
dependency as weak and use the extension normally.

Keep these branches guarded with `@static` checks so unsupported code is not
lowered on the wrong Julia version, and test both paths. Packages that merely
support old Julia without providing the optional feature there need no bridge;
they can leave the extension unavailable on those releases.

## Best practices

An installed package is read-only, shared by every environment that resolves
to that version, and possibly bundled into a system image or a system-wide
depot — so a package should never assume its own directory is writable, or
even that its location is stable. Concretely:

- **Data files**: ship or download them as [Artifacts](@ref) rather than
  opening paths relative to `@__DIR__`. Precompilation bakes `@__DIR__` in,
  so path-relative loading breaks when the package is relocated.
- **Caches and other mutable state**: use a scratchspace via
  [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl) — per-package
  mutable storage that is garbage-collected when the package goes away.
  Important user-created data should instead go to a user-chosen path that
  VibePkg does not manage.
- **Configuration**: record it with
  [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl), which
  stores per-project preferences readable at load time, instead of writing
  config files into the package directory.

## Package naming rules

For a package you intend to register: use a descriptive `UpperCamelCase` name
that says what the package does rather than a joke or an acronym, avoid
putting "Julia" or "Ju" in the name, and keep it distinct enough from existing
package names not to be confused with them (the General registry enforces a
similarity check). Packages wrapping an external library conventionally take
its name — `CPLEX.jl` wraps CPLEX — and pure-binary packages generated from
build recipes end in `_jll`.

## Registering and releasing

Registering a package in the General registry, and releasing new versions of
it, is done from the package's repository with
[Registrator.jl](https://github.com/JuliaRegistries/Registrator.jl); most
packages also use [TagBot](https://github.com/JuliaRegistries/TagBot) to tag
releases. Bump `version` in `Project.toml` according to the public-API rules
above, and register. Once the registry PR merges, the new version is available
to `add` everywhere.
