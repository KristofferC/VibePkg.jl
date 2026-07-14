# [Package server protocols](@id Pkg-Server-Protocols)

By default VibePkg downloads registries, packages, and artifacts from a
*package server* over plain HTTPS instead of git-cloning each package's
repository. Two protocols are involved: the **Pkg protocol**, spoken between
the client (VibePkg) and a package server, and the **storage protocol**,
spoken between package servers and the storage services behind them. This
page describes both from the client's point of view — for day-to-day
configuration see [Package servers](@ref) and the
[environment variables](@ref env-vars) reference.

The package-server design fixes several problems with fetching packages
straight from their hosting:

- **Permanence.** Authors delete repositories, and artifacts often live on
  plain web servers with no versioning at all. A storage service keeps every
  version it has ever served, so old manifests stay instantiable.
- **Firewalls.** All traffic is HTTPS GET/HEAD against one host, instead of
  git plus assorted protocols against an unbounded set of hosts.
- **No git dependency.** git is only needed for unregistered packages,
  repo-tracked (`add --url`) packages, and git-form registries.
- **Ecosystem insight.** The public servers give the Julia community
  aggregate download statistics that proprietary code hosts do not share.

## Architecture

```
client ──Pkg protocol──▶ package server ──storage protocol──▶ storage services ──▶ GitHub, …
```

The client talks to one package server: `https://pkg.julialang.org` (public,
unauthenticated, community-run) unless `JULIA_PKG_SERVER` names another.
Anyone can run one — servers are stateless caches and scale horizontally; a
reference implementation is
[PkgServer.jl](https://github.com/JuliaPackaging/PkgServer.jl).

A package server is backed by one or more *storage services*, which fetch
resources from the original hosts (GitHub, GitLab, …) and persist everything
they have ever served to durable storage. Multiple independent storage
services can back the same package server, for redundancy and so that no
single operator controls the ecosystem's package supply. The storage protocol
is server-to-server only — clients never speak it — and uses mutually
authenticated TLS, in contrast to the Pkg protocol, whose authentication is
optional and token-based (below). Storage services promise *persistence*
(anything served once can be served forever) and aim for *completeness*
(a served registry's packages, and a served package's artifacts, are fetched
and kept as well).

## Resources

The client issues GET requests for four kinds of resource:

| Resource | Contents |
|:-------- |:-------- |
| `/registries` | one line per registry: `/registry/$uuid/$hash` for the current version of each registry the server offers |
| `/registry/$uuid/$hash` | tarball of that registry snapshot |
| `/package/$uuid/$hash` | tarball of a package source tree |
| `/artifact/$hash` | tarball of an artifact tree |

Everything except `/registries` is addressed by content hash and therefore
immutable — servers and clients cache those forever. Updating a registry
means fetching `/registries` and comparing hashes against the installed
snapshot (this is what `registry update` does with a package server).

Tarballs may be zstd- or gzip-compressed. VibePkg checks the downloaded file's
magic bytes rather than trusting its filename or response headers before
decompressing it.

Every request to the package server (and only to it) carries a set of
identifying headers: the protocol version, the client's Julia version and
platform triplet, whether the session is interactive, and a summary of
CI-related environment variables — this is the basis of the public download
statistics. Any `JULIA_PKG_SERVER_*` environment variable is forwarded as a
`Julia-*` header (`JULIA_PKG_SERVER_REGISTRY_PREFERENCE` →
`Julia-Registry-Preference`), which is how server-side options like
[registry flavors](@ref Registry-flavors) are selected.

## Verification and fallback

All resources are content-addressed by git tree hash. After download and
extraction, VibePkg recomputes the tree hash and refuses content that does
not match — a corrupt or tampered source is skipped, not installed. For
packages, candidate sources are tried in order: the package server, then a
GitHub archive URL synthesized from the package's repository, then a full
git clone. `JULIA_PKG_SERVER=""` disables the package server entirely, and
[offline mode](@ref Offline-mode) skips downloads altogether.

## Authentication

The public server is anonymous, but a private package server can require
authorization. The Pkg protocol uses RFC 6750 bearer tokens: authenticated
requests carry an `Authorization: Bearer $access_token` header. How tokens
are issued and what they contain is entirely the server operator's business;
the client only stores, sends, and refreshes them.

### `auth.toml`

Credentials live in the first depot at

```
~/.julia/servers/<host>/auth.toml
```

(one directory per server host; characters that are invalid in directory
names, such as the `:` in `host:port`, become `_`). The user or a user agent
(IDE, company tooling) is responsible for putting the initial file there.
VibePkg reads these fields:

- `access_token` (required) — the bearer token sent with requests
- `expires_at` (optional) — absolute expiry, seconds since epoch
- `expires_in` (optional) — relative expiry, seconds
- `refresh_token` (optional) — token authorizing refresh requests
- `refresh_url` (optional) — where to fetch a fresh `auth.toml`

Other fields are preserved but ignored. The effective expiry is the minimum
of `expires_at` and `mtime(auth.toml) + expires_in`; keeping the relative
form tied to the file's modification time makes expiry robust against
clock skew between server and client.

### Token refresh

Bearer tokens are typically short-lived, so VibePkg refreshes them
automatically. Starting ten minutes before expiry, each package-server
request first performs a refresh: a GET of `refresh_url` with
`Authorization: Bearer $refresh_token`, whose response must be a new
`auth.toml` (at minimum an `access_token`). The new file is written back
atomically with owner-only permissions, converting a relative `expires_in`
into an absolute `expires_at` based on the client clock. `refresh_url` must
be HTTPS (plain HTTP is accepted only for `localhost` development); an expired
token that cannot be refreshed is simply not sent, so the request proceeds
anonymously.

If the server answers **401 Unauthorized** anyway (a token revoked
server-side, say), VibePkg forces one refresh and retries the request once.
A second 401 raises an error that includes the response body, so a server
can explain — in plain text — what the user should do.

### Authentication hooks

A user agent can register a handler to run whenever VibePkg fails to produce
a usable token, and for example open a login flow that writes a fresh
`auth.toml`:

```julia
dispose = VibePkg.Fetch.register_auth_error_handler(
    "https://pkg.company.com"
) do url, server, err
    MyAuthTool.login(server)      # acquire and write auth.toml
    return true, true             # handled; retry the token lookup
end

# ... later ...
dispose()
```

The first argument selects which URLs the handler applies to (a substring or
`Regex`, matched with `occursin`). The handler receives the failing URL, the
configured package server, and an error code — one of `"no-auth-file"`,
`"malformed-file"`, `"no-access-token"`, `"no-refresh-key"`, or
`"insecure-refresh-url"` — and returns `(handled, should_retry)`: when
`handled` is true no further handlers run, and `should_retry` re-runs the
token lookup once, picking up whatever the handler wrote. Handlers are tried
most-recently-registered first. `register_auth_error_handler` returns a
zero-argument deregistration function; the same effect is available as
`VibePkg.Fetch.deregister_auth_error_handler(urlscheme, f)`.

## Storage-service interaction

For a content-addressed resource, a package server first sends `HEAD` requests
to its configured storage services and downloads with `GET` from one that
reports the resource. A successful `HEAD` response is itself a commitment by
that storage service to retain the resource, even if another service supplies
the bytes for this particular request.

The changing `/registries` endpoint needs one extra rule because tree hashes
have no natural ordering. When storage services report different current
hashes, the package server asks each service whether it knows the others'
hashes. A service that knows another snapshot and also reports a different one
has the later snapshot; genuinely divergent snapshots can be broken as a tie.

A storage service's hard guarantee is persistence: after successfully serving
a registry, package, or artifact tree, it must continue to serve that exact
tree. Completeness is best effort rather than absolute — a registry can contain
an erroneous or already-vanished package hash — but storage services should
eagerly fetch all newly referenced package trees and artifacts so the stored
ecosystem is as closed and reproducible as possible.
