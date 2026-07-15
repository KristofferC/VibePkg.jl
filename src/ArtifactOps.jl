# Artifact installation.
#
# Division of labor (same as Pkg's): the Artifacts *stdlib* owns lookup —
# Artifacts.toml parsing, platform selection, `@artifact_str` — while this
# module owns everything networked and mutating: downloading, verifying and
# installing artifact trees into `<depot>/artifacts/<treehash>`, and logging
# usage for GC.
#
# Sources per artifact, in order: the package server's `/artifact/<hash>`
# (verified by tree hash only), then the Artifacts.toml `download` entries
# (verified by sha256, then tree hash).

module ArtifactOps

using Base: UUID, SHA1
using Base.BinaryPlatforms: AbstractPlatform, HostPlatform
import Artifacts as ArtifactsStdlib
using SHA: sha256
using TOML: TOML

using ..Errors: pkgerror
using ..Utils: stderr_f, mv_temp_dir_retries, create_cachedir_tag,
    sanitize_url, sanitize_external_error
using ..TreeHash
using ..Depots: DepotStack, depots, depots1, artifacts_dir, log_usage
import ..Fetch
using FileWatching: mkpidlock

export ensure_artifact_installed!, ensure_artifacts_installed!, artifact_tree_path

#############
# Overrides #
#############
# `<depot>/artifacts/Overrides.toml`: hash-form (`"<hex>" = path|hex`) and
# uuid-form (`[uuid] name = path|hex`) overrides, reverse-depot precedence
# (the first depot's entries win). An overridden artifact is never
# downloaded — this deliberately fixes Pkg's quirk where uuid/name overrides
# did not suppress downloads during add/instantiate.

const HEX40 = r"^[0-9a-f]{40}$"i

parse_override(v::String) = occursin(HEX40, v) ? SHA1(v) : v

function load_overrides(d::DepotStack)
    hash_overrides = Dict{SHA1, Union{String, SHA1}}()
    uuid_overrides = Dict{UUID, Dict{String, Union{String, SHA1}}}()
    for depot in reverse(depots(d))         # first depot applied last = wins
        f = joinpath(artifacts_dir(depot), "Overrides.toml")
        isfile(f) || continue
        raw = TOML.tryparsefile(f)
        raw isa TOML.ParserError && continue
        for (k, v) in raw
            if occursin(HEX40, k)
                if v == ""
                    delete!(hash_overrides, SHA1(k))            # un-override
                elseif v isa String
                    hash_overrides[SHA1(k)] = parse_override(v)
                end
            elseif v isa Dict
                pkg_uuid = tryparse(UUID, k)
                if pkg_uuid === nothing
                    @warn "ignoring invalid key `$k` in Overrides.toml at `$f`" maxlog = 1
                    continue
                end
                per_pkg = get!(() -> Dict{String, Union{String, SHA1}}(), uuid_overrides, pkg_uuid)
                for (name, ov) in v
                    if ov == ""
                        delete!(per_pkg, name)
                    elseif ov isa String
                        per_pkg[name] = parse_override(ov)
                    end
                end
            end
        end
    end
    return (; hash_overrides, uuid_overrides)
end

function override_for(overrides, pkg_uuid::Union{Nothing, UUID}, name::String, hash::SHA1)
    if pkg_uuid !== nothing
        per_pkg = get(overrides.uuid_overrides, pkg_uuid, nothing)
        per_pkg !== nothing && haskey(per_pkg, name) && return per_pkg[name]
    end
    return get(overrides.hash_overrides, hash, nothing)
end

"Locate an artifact tree across the depot stack; default install path first depot."
function artifact_tree_path(d::DepotStack, hash::SHA1)
    hex = string(hash)
    for depot in depots(d)
        path = joinpath(artifacts_dir(depot), hex)
        isdir(path) && return path, true
    end
    return joinpath(artifacts_dir(depots1(d)), hex), false
end

function verify_sha256(file::String, expected::String)
    computed = bytes2hex(open(sha256, file))
    return computed == lowercase(expected)
end

function can_symlink(dir::String)
    link = joinpath(dir, "link")
    return try
        symlink("target", link)
        true
    catch err
        err isa Base.IOError || rethrow()
        false
    finally
        Base.rm(link; force = true)
    end
end

# `JULIA_PKG_IGNORE_HASHES=1` downgrades a tree-hash mismatch to a warning
# and installs the artifact anyway. With the variable unset this defaults to
# on only for Windows users who cannot create symlinks, where hashes of
# symlink-containing artifacts cannot reproduce.
function ignore_hashes(artifacts_dir::String)
    if get(ENV, "JULIA_PKG_IGNORE_HASHES", "") != ""
        ignore = Base.get_bool_env("JULIA_PKG_IGNORE_HASHES", false)
        ignore === nothing &&
            @error "Invalid JULIA_PKG_IGNORE_HASHES value $(repr(ENV["JULIA_PKG_IGNORE_HASHES"])); expected true/false or 1/0. Hash mismatches will not be ignored"
        return something(ignore, false)
    end
    return Sys.iswindows() && !mktempdir(can_symlink, artifacts_dir)
end

# Download from one source and unpack+verify into place. Returns success.
function try_install_from(
        url::String, sha256_str::Union{Nothing, String}, hash::SHA1, dest::String;
        depots::Union{Nothing, DepotStack} = nothing,
        io::IO = stderr_f(),
        progress_header::Union{Nothing, String} = nothing,
        failures::Union{Nothing, Vector{String}} = nothing,
    )
    tarball = tempname()
    return try
        try
            Fetch.download(url, tarball; io, depots, progress_header)
        catch err
            err isa InterruptException && rethrow()
            failures === nothing || push!(failures, "$(repr(sanitize_url(url))): download failed: $(sanitize_external_error(err))")
            return false
        end
        if sha256_str !== nothing && !verify_sha256(tarball, sha256_str)
            failures === nothing || push!(failures, "$(repr(sanitize_url(url))): SHA-256 mismatch (expected $sha256_str)")
            @warn "Downloaded artifact does not match the expected SHA-256; skipping this source" url = sanitize_url(url) expected = sha256_str
            return false
        end
        # unpack on the same filesystem as the destination for atomic rename
        temp_root = mkpath(joinpath(dirname(dest), "temp"))
        temp = mktempdir(temp_root)
        # own `temp` with try/finally: interrupts, hashing failures, and rename
        # failures must not leave partial trees in the GC-exempt temp directory
        # (after a successful rename `temp` is gone and the rm is a no-op)
        try
            try
                Fetch.unpack(tarball, temp)
            catch err
                err isa InterruptException && rethrow()
                failures === nothing || push!(failures, "$(repr(sanitize_url(url))): extraction failed: $(sanitize_external_error(err))")
                @warn "Failed to extract artifact archive; skipping this source" url = sanitize_url(url) exception = err
                return false
            end
            # tree_hash throws on unreadable content; treat that like any
            # other bad download and fall through to the next source
            computed, legacy_matches = try
                c = SHA1(TreeHash.tree_hash(temp))
                lm = c != hash &&
                    SHA1(TreeHash.tree_hash(temp; legacy_symlink_size = true)) == hash
                c, lm
            catch err
                err isa InterruptException && rethrow()
                failures === nothing || push!(failures, "$(repr(sanitize_url(url))): tree-hash verification failed: $(sanitize_external_error(err))")
                @warn "Failed to verify unpacked artifact; skipping this source" url = sanitize_url(url) exception = err
                return false
            end
            if computed != hash && !legacy_matches
                if ignore_hashes(dirname(dest))
                    @error "Artifact content does not match its Git tree SHA-1; ignoring the mismatch and installing anyway" url = sanitize_url(url) expected = hash computed
                else
                    failures === nothing || push!(failures, "$(repr(sanitize_url(url))): Git tree SHA-1 mismatch (expected $hash, computed $computed)")
                    @warn "Artifact content does not match its Git tree SHA-1; skipping this source" url = sanitize_url(url) expected = hash computed
                    return false
                end
            end
            mv_temp_dir_retries(temp, dest; set_permissions = true)   # artifacts are read-only
            return true
        finally
            Base.rm(temp; force = true, recursive = true)
        end
    finally
        Base.rm(tarball; force = true)
    end
end

"""
    ensure_artifact_installed!(depots, name, meta; server, io) -> (path, new)

Install one artifact (a `select_downloadable_artifacts` meta entry) if no
depot has it. Verified by git tree hash; `download` entries additionally by
sha256. Logs artifact usage (the GC liveness contract).
"""
function ensure_artifact_installed!(
        d::DepotStack, name::String, meta::Dict;
        server::Union{Nothing, String} = Fetch.pkg_server(),
        io::IO = stderr_f(),
    )
    hash = SHA1(meta["git-tree-sha1"]::String)
    path, installed = artifact_tree_path(d, hash)
    if !installed
        sources = Tuple{String, Union{Nothing, String}}[]
        server === nothing || push!(sources, ("$server/artifact/$hash", nothing))
        dl = get(meta, "download", nothing)
        if dl !== nothing
            dl isa Vector || pkgerror("Artifact $name field download must be an array of tables; got $(repr(dl))")
            for entry in dl
                entry isa AbstractDict || pkgerror("Artifact $name contains a malformed download source; expected a table, got $(repr(entry))")
                url = get(entry, "url", nothing)
                url isa String || pkgerror("Artifact $name download field url must be a string; got $(repr(url))")
                sha = get(entry, "sha256", nothing)
                sha isa Union{Nothing, String} || pkgerror("Artifact $name download field sha256, if present, must be a string; got $(repr(sha))")
                push!(sources, (url, sha))
            end
        end
        isempty(sources) && pkgerror("Artifact $name has no download sources")

        adir = mkpath(artifacts_dir(depots1(d)))
        create_cachedir_tag(adir)
        failures = String[]
        already = Ref(false)
        success = mkpidlock(path * ".pid", stale_age = 20) do
            isdir(path) && (already[] = true; return true)
            for (url, sha) in sources
                try_install_from(
                    url, sha, hash, path;
                    depots = d, io, progress_header = "Downloading artifact: $(name)", failures,
                ) && return true
            end
            false
        end
        success || pkgerror(
            "Failed to install artifact $name [$hash]. Attempted sources:\n" *
                join(("  - " * failure for failure in failures), "\n")
        )
        installed = already[]
    end
    new = !installed
    new && @debug "Installed artifact $name $hash"
    return path, new
end

# Artifact selection: a `.pkg/select_artifacts.jl` hook (run in a minimal
# subprocess printing TOML) overrides the static platform selection.
function selected_artifacts(pkg_root::String, artifacts_toml::String, platform::AbstractPlatform; include_lazy::Bool = false)
    selector = joinpath(pkg_root, ".pkg", "select_artifacts.jl")
    if isfile(selector)
        triplet = Base.BinaryPlatforms.triplet(platform)
        sep = Sys.iswindows() ? ';' : ':'
        active_project = Base.active_project()
        project_arg = active_project === nothing ? `` : `--project=$active_project`
        cmd = addenv(
            `$(joinpath(Sys.BINDIR, "julia")) -O0 --compile=min -t1 --startup-file=no $project_arg $selector $triplet`,
            "JULIA_LOAD_PATH" => "@$(sep)@stdlib",
        )
        out = try
            read(cmd, String)
        catch err
            err isa InterruptException && rethrow()
            pkgerror("Artifact selector $(repr(selector)) failed: $(sanitize_external_error(err))")
        end
        artifacts = try
            TOML.parse(out)
        catch err
            err isa InterruptException && rethrow()
            pkgerror("Failed to parse TOML output from artifact selector $(repr(selector)): $(sanitize_external_error(err))")
        end
        for (name, meta) in artifacts
            meta isa AbstractDict && get(meta, "git-tree-sha1", nothing) isa String || pkgerror(
                "Artifact selector $(repr(selector)) entry $(repr(name)) must be a TOML table containing a string git-tree-sha1"
            )
        end
        return artifacts
    end
    # A platform-specific entry missing a required key (`os`/`arch`) makes the
    # Artifacts stdlib's `unpack_platform` return `nothing`, which it then
    # typeasserts to `Platform` — a raw `TypeError` that would otherwise leak
    # out uncaught. Surface it as a graceful PkgError naming the bad file.
    return try
        ArtifactsStdlib.select_downloadable_artifacts(artifacts_toml; platform, include_lazy)
    catch err
        err isa InterruptException && rethrow()
        err isa TypeError && err.expected === Base.BinaryPlatforms.Platform || rethrow()
        pkgerror("Malformed platform entry in $(repr(artifacts_toml)); platform tables require string os and arch keys")
    end
end

"""
    collect_artifact_installs(depots, pkg_root; pkg_uuid, platform) -> Vector

The (non-lazy, non-overridden) artifacts a package's (Julia)Artifacts.toml
selects for `platform`, as `(name, meta)` pairs ready to install. Applies
`Overrides.toml` (overridden artifacts are never downloaded), runs the
`.pkg/select_artifacts.jl` hook, and logs artifact usage for GC.
"""
function collect_artifact_installs(
        d::DepotStack, pkg_root::String;
        pkg_uuid::Union{Nothing, UUID} = nothing,
        platform::AbstractPlatform = HostPlatform(),
        include_lazy::Bool = false,
        usage_out::Union{Nothing, Vector{String}} = nothing,
    )
    out = Tuple{String, Dict}[]
    for f in ArtifactsStdlib.artifact_names
        artifacts_toml = joinpath(pkg_root, f)
        isfile(artifacts_toml) || continue
        overrides = load_overrides(d)
        metas = selected_artifacts(pkg_root, artifacts_toml, platform; include_lazy)
        for (name, meta) in metas
            hash = SHA1(meta["git-tree-sha1"]::String)
            ov = override_for(overrides, pkg_uuid, name, hash)
            if ov !== nothing
                ov isa String && !isdir(ov) &&
                    @warn "Artifact override does not exist; correct or remove the override" artifact = name override = ov
                continue    # overridden artifacts are never downloaded
            end
            push!(out, (name, meta))
        end
        # GC marks artifacts through the Artifacts.toml files recorded here;
        # a caller looping many packages passes `usage_out` and writes ONE
        # batched log entry instead of a read-rewrite cycle per package
        if usage_out === nothing
            log_usage(d, artifacts_toml, "artifact_usage.toml")
        else
            push!(usage_out, artifacts_toml)
        end
        break   # first matching Artifacts.toml wins
    end
    return out
end

"""
    ensure_artifacts_installed!(depots, pkg_root; pkg_uuid, platform, io) -> Vector{String}

Serial convenience wrapper over [`collect_artifact_installs`](@ref) +
[`ensure_artifact_installed!`](@ref); the execution layer runs the installs
concurrently instead.
"""
function ensure_artifacts_installed!(
        d::DepotStack, pkg_root::String;
        pkg_uuid::Union{Nothing, UUID} = nothing,
        platform::AbstractPlatform = HostPlatform(),
        server::Union{Nothing, String} = Fetch.pkg_server(),
        io::IO = stderr_f(),
    )
    new_names = String[]
    for (name, meta) in collect_artifact_installs(d, pkg_root; pkg_uuid, platform)
        _, new = ensure_artifact_installed!(d, name, meta; server, io)
        new && push!(new_names, name)
    end
    return new_names
end

end # module
