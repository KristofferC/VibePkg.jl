# Compatibility

The `[compat]` table in a `Project.toml` declares which versions of your
dependencies (and of Julia itself) the project is known to work with. The
resolver never selects a version outside the declared ranges:

```toml
[deps]
Example = "7876af07-990d-54b4-ab0e-23690620f79a"

[compat]
Example = "0.5"
julia = "1.12"
```

Compat entries apply to `[deps]`, `[weakdeps]`, and `[extras]`; `julia` may
always be given even though it is not a listed dependency.

With no compat entry, every version is allowed. That is convenient while
exploring, but published packages should state the versions they have actually
tested: a missing upper bound lets a future breaking release enter the
resolution.

## [Compatibility entries created by `add`](@id compat-on-add)

When the active project is a package — its `Project.toml` has both a `name` and
`uuid` — adding a direct dependency automatically creates a compat entry
beginning at the version selected by the resolver:

```
(MyPackage) vpkg> add Example
   Resolving package versions...
     Compat entries added for Example
```

An existing entry is never overwritten, including when the dependency is
re-added. Plain environments without a package name and UUID do not get an
automatic entry. The generated constraint is a safe starting point, not a
claim that every allowed version has been tested; package authors should still
review their bounds before publishing.

The easiest way to maintain the table is the `compat` command:

```
(@v1.12) vpkg> compat                # show the table
(@v1.12) vpkg> compat Example 0.5    # set an entry (and re-check the env)
(@v1.12) vpkg> compat Example        # remove an entry
(@v1.12) vpkg> compat --current      # fill missing entries from resolved versions
```

Setting an entry that conflicts with the currently resolved versions keeps the
entry and suggests running `update` — the environment is never silently
downgraded.

!!! info
    Packages registered in the General registry are required to have
    upper-bounded compat entries for all their dependencies.

    The syntax on this page is for a project's `Project.toml`. Registry
    `Compat.toml` files use a different range syntax described in
    [Registry format](@ref).

## Version specifiers

Compat entries use [semantic versioning](https://semver.org/), with one
adjustment for pre-1.0 versions described below. A bare version number is a
*caret* specifier: it allows changes that semver considers compatible.

### Caret specifiers

`Example = "1.2.3"` is equivalent to `Example = "^1.2.3"`. A caret specifier
allows everything up to the next change of the left-most **non-zero** digit:

```toml
PkgA = "^1.2.3" # [1.2.3, 2.0.0)
PkgB = "^1.2"   # [1.2.0, 2.0.0)
PkgC = "^1"     # [1.0.0, 2.0.0)
PkgD = "^0.2.3" # [0.2.3, 0.3.0)
PkgE = "^0.0.3" # [0.0.3, 0.0.4)
PkgF = "^0.0"   # [0.0.0, 0.1.0)
PkgG = "^0"     # [0.0.0, 1.0.0)
```

The pre-1.0 rows follow from semver's convention that `0.x` minor bumps (and
`0.0.x` patch bumps) may break things: `0.2.3` is *not* assumed compatible with
`0.3.0`, and `0.0.3` not with `0.0.4`.

### Tilde specifiers

A tilde allows only patch-level changes (when at least a minor version is
given):

```toml
PkgA = "~1.2.3" # [1.2.3, 1.3.0)
PkgB = "~1.2"   # [1.2.0, 1.3.0)
PkgC = "~1"     # [1.0.0, 2.0.0)
PkgD = "~0.2.3" # [0.2.3, 0.3.0)
PkgE = "~0.0.3" # [0.0.3, 0.1.0)
PkgF = "~0.0"   # [0.0.0, 0.1.0)
PkgG = "~0"     # [0.0.0, 1.0.0)
```

### Equality and inequality specifiers

An exact version is selected with `=`, and one-sided ranges with `<`, `>=` (or
`≥`):

```toml
PkgA = "=1.2.3"   # exactly 1.2.3
PkgB = ">= 1.2.3" # [1.2.3, ∞)
PkgC = "< 1.2.3"  # [0.0.0, 1.2.3)
```

### Hyphen ranges

A hyphen with spaces around it gives an inclusive range:

```toml
PkgA = "1.2.3 - 4.5.6" # [1.2.3, 4.5.6]
```

Digits left unspecified in the *first* endpoint count as zero; in the *second*
endpoint they act as a wildcard:

```toml
PkgA = "1.2 - 4.5.6" # [1.2.0, 4.5.6]
PkgB = "1 - 4.5.6"   # [1.0.0, 4.5.6]
PkgC = "1.2.3 - 4.5" # [1.2.3, 4.6.0)
PkgD = "1.2.3 - 4"   # [1.2.3, 5.0.0)
PkgE = "0.2 - 0.5.6" # [0.2.0, 0.5.6]
PkgF = "0.2 - 0"     # [0.2.0, 1.0.0)
```

### Unions

Several specifiers separated by commas are allowed as a union:

```toml
Example = "1.2, 2"     # [1.2.0, 3.0.0)
Other   = "0.2, 1"     # [0.2.0, 0.3.0) ∪ [1.0.0, 2.0.0)
Exact   = "=0.10.1, =0.10.3"
```

## [Fixing conflicts](@id compat-fixing-conflicts)

Suppose your project depends on `B` and you want to add `C`, but `B` declares
`D = "0.1"` while `C` needs `D` at `0.2` — the resolver reports an
unsatisfiable requirement (see
[Interpreting and resolving version conflicts](@ref)). If you believe `B`
actually works fine with `D` 0.2, the constraint is just stale, and the fix is
to widen it:

```
(@v1.12) vpkg> dev B
```

Then edit the `[compat]` entry in `~/.julia/dev/B/Project.toml`:

```toml
[compat]
D = "0.1, 0.2"
```

re-resolve and verify:

```
(@v1.12) vpkg> up

(@v1.12) vpkg> test B
```

Your environment now uses the widened copy of `B`. Finish by contributing the
compat change back to `B`'s repository so a released version carries it — then
you can `free B` and return to registered releases.
