# Artifacts

Artifacts are how packages ship data that isn't Julia code: compiled libraries,
datasets, fonts, models. An artifact is an immutable directory tree, identified
by the git tree hash of its contents and stored content-addressed in the depot
(`~/.julia/artifacts/<treehash>`), so identical artifacts are stored once no
matter how many packages or versions reference them.

Packages declare their artifacts in an `Artifacts.toml` file at the package
root, and access them with the `artifact"name"` string macro from the
`Artifacts` standard library. VibePkg's role is the management side:
downloading and installing the right artifacts when a package is installed,
verifying them by hash, honoring overrides, and garbage-collecting unused
trees.

## `Artifacts.toml`

A minimal entry binds a name to a tree hash and tells where a tarball of the
content can be downloaded:

```toml
[socrates]
git-tree-sha1 = "43563e7631a7eafae1f9f8d9d332e3de44ad7239"

    [[socrates.download]]
    url = "https://github.com/staticfloat/small_bin/raw/master/socrates.tar.gz"
    sha256 = "e65d2f13f2085f2c279830e863292312a72930fee5ba3c792b14c33ce5c5cc58"
```

The package can then do:

```julia
using Artifacts

function load_socrates()
    rootpath = artifact"socrates"
    return open(joinpath(rootpath, "bin", "socrates")) do io
        read(io, String)
    end
end
```

The `git-tree-sha1` identifies the *unpacked content* and is what gets
verified after download; the `sha256` verifies the tarball itself. Multiple
`[[name.download]]` stanzas give mirror URLs.

Two attributes and one structural variation extend the format:

- **`lazy = true`** — the artifact is not downloaded when the package is
  installed, only on first use (`artifact"..."` triggers the download).
- **Platform-specific artifacts** — instead of a single table, an array of
  tables keyed by platform properties; the entry matching the host is
  selected:

```toml
[[c_simple]]
arch = "x86_64"
git-tree-sha1 = "4bdf4556050cb55b67b211d4e78009aaec378cbc"
libc = "musl"
os = "linux"

    [[c_simple.download]]
    sha256 = "411d6befd49942826ea1e59041bddf7dbb72fb871bb03165bf4e164b13ab5130"
    url = "https://github.com/JuliaBinaryWrappers/c_simple_jll.jl/releases/download/c_simple%2Bv1.2.3%2B7/c_simple.v1.2.3.x86_64-linux-musl.tar.gz"

[[c_simple]]
arch = "x86_64"
git-tree-sha1 = "51264dbc770cd38aeb15f93536c29dc38c727e4c"
os = "macos"

    [[c_simple.download]]
    sha256 = "6c17d9e1dc95ba86ec7462637824afe7a25b8509cc51453f0eb86eda03ed4dc3"
    url = "https://github.com/JuliaBinaryWrappers/c_simple_jll.jl/releases/download/c_simple%2Bv1.2.3%2B7/c_simple.v1.2.3.x86_64-apple-darwin14.tar.gz"
```

- **No download stanza** — an entry with only a hash names content that is
  produced locally (or provided some other way); nothing is downloaded for it.

To compute the `git-tree-sha1` and `sha256` for a tarball you are binding by
hand:

```julia
using Tar, Inflate, SHA
filename = "socrates.tar.gz"
println("sha256: ", bytes2hex(open(sha256, filename)))
println("git-tree-sha1: ", Tar.tree_hash(IOBuffer(inflate_gzip(filename)), algorithm = "git-sha1"))
```

In practice most `Artifacts.toml` files are machine-generated:
binary-providing `_jll` packages by [BinaryBuilder.jl](https://binarybuilder.org),
and hand-bound data artifacts conveniently with
[ArtifactUtils.jl](https://github.com/JuliaPackaging/ArtifactUtils.jl).

## Installation and verification

When a package is installed or an environment is instantiated, VibePkg walks
each package's `Artifacts.toml`, selects the entries matching the host platform,
and downloads all non-lazy artifacts (from the package server when configured,
otherwise from the listed URLs), unpacking each and verifying the tree hash
before the artifact becomes visible. Artifact trees are installed read-only.

Tree-hash computation depends on the file system: on Windows without symlink
permissions the hash of a symlink-containing artifact cannot reproduce, and the
mismatch is automatically downgraded to a warning there. Setting the
environment variable `JULIA_PKG_IGNORE_HASHES=1` forces that lenient behavior
everywhere (and `JULIA_PKG_IGNORE_HASHES=0` disables it even on Windows) —
use with care, since it accepts content whose hash does not match what the
package declared.

Lazy artifacts can be pre-installed programmatically, which is useful in
deployment images:

```julia
using VibePkg.Artifacts
ensure_artifact_installed("socrates", find_artifacts_toml(pathof(MyPkg)))
```

## Querying and managing artifacts from code

`VibePkg.Artifacts` re-exports the query functions of the `Artifacts` standard
library — `artifact_meta`, `artifact_hash`, `artifact_exists`, `artifact_path`,
`find_artifacts_toml`, `select_downloadable_artifacts` — and adds the
management side:

- `ensure_artifact_installed(name, artifacts_toml; platform = HostPlatform()) -> path`
  — install the named artifact if it is missing (lazy or not) and return its
  path.
- `verify_artifact(hash) -> Bool` — whether the artifact tree for `hash`
  exists and its content matches the hash.
- `remove_artifact(hash)` — delete the artifact tree (normally you let
  `gc` do this: it removes artifacts no `Artifacts.toml` in use references
  anymore).

## Creating artifacts from code

Artifacts can also be produced programmatically — the typical use is a script
in a package's repository that regenerates a dataset artifact.
`create_artifact` materializes a new artifact tree: it hands your callback a
fresh directory to fill in, then hashes the result and moves it into the
depot. `bind_artifact!` records the resulting hash under a name in an
`Artifacts.toml`. Querying before creating makes the script idempotent:

```julia
using VibePkg.Artifacts

artifacts_toml = joinpath(@__DIR__, "Artifacts.toml")

hash = artifact_hash("dataset", artifacts_toml)
if hash === nothing || !artifact_exists(hash)
    hash = create_artifact() do dir
        # fill `dir` with the artifact's content
        write(joinpath(dir, "data.csv"), fetch_the_data())
    end
    bind_artifact!(artifacts_toml, "dataset", hash)
end

artifact_path(hash)
```

`bind_artifact!` accepts the same variations the file format has: a
`platform` keyword for platform-specific bindings (one entry per platform),
`download_info` — a vector of `(url, sha256)` tuples — to write the download
stanzas that let others install the artifact, `lazy = true`, and
`force = true` to replace an existing binding. `unbind_artifact!` removes a
binding from the file.

## Overriding artifact locations

Sometimes an artifact should come from somewhere else — a system library
instead of the shipped one, a locally built binary, a shared network copy. A
depot-wide `~/.julia/artifacts/Overrides.toml` redirects artifacts, either by
hash or per package and name:

```toml
# Override by content hash: to a path, or to another artifact's hash
78f35e74ff113f02274ce60dab6e92b4546ef806 = "/path/to/replacement"
c76f8cda85f83a06d17de6c57aabf9e294eb2537 = "fb886e813a4aed4147d5979fcdf27457d20aa35d"

# Override by package UUID and artifact name
[d57dbccd-ca19-4d82-b9b8-9d660942965b]
c_simple = "/path/to/c_simple_dir"
libfoo = "fb886e813a4aed4147d5979fcdf27457d20aa35d"
```

Overridden artifacts are never downloaded; `artifact_path` and `artifact"..."`
resolve to the override target. An empty string removes an override.

## Extending platform selection

For artifacts whose correct variant depends on more than the base platform
triplet (CUDA version, CPU microarchitecture, …), a package can augment the
platform used for selection by shipping a `.pkg/select_artifacts.jl` hook next
to its `Artifacts.toml`. VibePkg runs it at install time to ask the package
which artifacts to download; at runtime the package passes the same augmented
platform to `@artifact_str`. See the Julia manual on `Base.BinaryPlatforms`
for how platform augmentation is written.
