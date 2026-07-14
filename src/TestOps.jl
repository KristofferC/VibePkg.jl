# Pkg.test.
#
# A test project that is itself a workspace member skips all sandboxing:
# the workspace manifest already pins everything, so the test project is
# instantiated and run in place.
#
# Otherwise a sandbox environment is constructed in a temp directory:
#   - project: the package's `test/Project.toml` (modern path) or a
#     generated project from the legacy `[targets]`/`[extras]` sections;
#     the tested package is always force-added as a dependency
#   - manifest: the parent manifest sliced to the package's dependency
#     closure, with relative paths absolutized
#   - preferences: the load-path cascade seen from the test project
#     (test-level over parent over default environments), flattened into
#     the sandbox's JuliaLocalPreferences.toml
#   - test-only dependencies are then resolved and installed through the
#     ordinary planning/execution pipeline
# and `test/runtests.jl` runs in a julia subprocess with `--project` set to
# the sandbox and the load path isolated from the user's environments. The
# subprocess mirrors the parent's flags (Pkg parity): optimize/debug/
# cpu-target/sysimage/check-bounds come from `Base.julia_cmd()`, the rest
# (depwarn, inline, startup-file, track-allocation, color, threads) from
# `test_subprocess_flags`/`test_threads_spec`.

module TestOps

using Base: UUID

using ..Errors: pkgerror
using ..Utils: stderr_f, precompile_io, precompile_detach_kwargs
using ..Versions: VersionSpec, semver_spec
using ..EnvFiles
using ..EnvFiles: ManifestEntry, PathTracked, SourceSpec, with_project,
    with_manifest, entry_path, with_entry
using ..Configs: Config
import ..Registries
using ..Registries: RegistryInstance
using ..Environments
using ..Environments: Environment
using ..Planning
import ..Resolve
using ..Execution
using ..Execution: entry_source_path
import ..BuildOps
using ..Utils: printpkgstyle

export test!

# Merge the package's own test/Manifest.toml (if any) under the parent
# slice: the parent's entries win on conflict, with a warning.
function merge_test_manifest(manifest::Manifest, pkg_source::String)
    test_manifest_file = joinpath(pkg_source, "test", "Manifest.toml")
    isfile(test_manifest_file) || return manifest
    test_manifest = try
        read_manifest(test_manifest_file)
    catch err
        @warn "failed to read test/Manifest.toml, ignoring it" err
        return manifest
    end
    entries = Dict{UUID, ManifestEntry}(manifest.deps)
    for (uuid, entry) in test_manifest
        if haskey(entries, uuid)
            if entries[uuid] != entry
                @warn "the parent environment's version of $(entry.name) overrides the one in test/Manifest.toml"
            end
        else
            # its paths are relative to test/, but the merged manifest is
            # written into the sandbox — absolutize them
            path = entry_path(entry)
            if path !== nothing && !isabspath(path)
                abs = normpath(joinpath(dirname(test_manifest_file), path))
                entry = with_entry(entry; tracking = PathTracked(abs, EnvFiles.entry_version(entry)))
            end
            entries[uuid] = entry
        end
    end
    return with_manifest(manifest; deps = entries)
end

# `force_latest_compatible_version`: tighten every sandbox compat entry so
# only versions no older than the latest compatible one (or its
# backwards-compatible floor) resolve.
function force_latest_compat(
        project::Project, pkg_uuid::UUID, registries::Vector{RegistryInstance};
        allow_earlier_backwards_compatible_versions::Bool = true,
    )
    compat = Dict{String, EnvFiles.Compat}(project.compat)
    for (name, uuid) in project.deps
        uuid == pkg_uuid && continue
        existing = haskey(compat, name) ? compat[name].val : VersionSpec()
        latest_compatible = nothing
        for reg in registries
            pkg = get(reg, uuid, nothing)
            pkg === nothing && continue
            info = Registries.registry_info(reg, pkg)
            for (v, vinfo) in info.version_info
                vinfo.yanked && continue
                v in existing || continue
                (latest_compatible === nothing || v > latest_compatible) || continue
                # a version whose julia compat excludes the running julia can
                # never resolve, so it must not floor the compat entry
                julia_compat = Registries.query_compat_for_version(info, v, Registries.JULIA_UUID)
                julia_compat !== nothing && !(VERSION in julia_compat) && continue
                latest_compatible = v
            end
        end
        latest_compatible === nothing && continue
        floor = if allow_earlier_backwards_compatible_versions
            lc = latest_compatible
            lc.major > 0 ? VersionNumber(lc.major, 0, 0) :
                lc.minor > 0 ? VersionNumber(0, lc.minor, 0) : lc
        else
            latest_compatible
        end
        spec = intersect(existing, semver_spec(">= $(floor.major).$(floor.minor).$(floor.patch)"))
        isempty(spec) && continue
        # build the compat from the spec's own string so value and string stay
        # consistent (the single-arg constructor derives the value from the
        # string — see destructure_project's consistency check)
        compat[name] = EnvFiles.Compat(string(spec))
    end
    return with_project(project; compat)
end

# the manifest slice lives in Execution (`sandbox_manifest`), shared with
# the build sandbox
const sliced_manifest = Execution.sandbox_manifest

# the sandbox project: test/Project.toml if present, else generated from
# the legacy [targets]/[extras] sections; the tested package is force-added
function sandbox_project(pkg_source::String, pkg_name::String, pkg_uuid::UUID, parent::Project)
    test_project_file = joinpath(pkg_source, "test", "Project.toml")
    has_test_project = isfile(test_project_file)
    project = if has_test_project
        read_project(test_project_file)
    else
        pkg_project = read_project(EnvFiles.projectfile_path(pkg_source))
        # The legacy targets-based test environment contains both the
        # package's regular dependencies and its targeted test dependencies.
        # Tests are allowed to import regular dependencies directly, so
        # keeping them only as transitive dependencies of the tested package
        # is not sufficient for Julia's environment loader.
        deps = Dict{String, UUID}(pkg_project.deps)
        for target_dep in get(pkg_project.targets, "test", String[])
            uuid = get(pkg_project.extras, target_dep, nothing)
            uuid === nothing && (uuid = get(pkg_project.weakdeps, target_dep, nothing))
            uuid === nothing && pkgerror("target dependency `$target_dep` not found in [extras] or [weakdeps]")
            deps[target_dep] = uuid
        end
        compat = Dict{String, EnvFiles.Compat}(
            name => pkg_project.compat[name]
                for name in keys(deps) if haskey(pkg_project.compat, name)
        )
        with_project(Project(); deps, sources = pkg_project.sources, compat)
    end
    # [sources] paths from an explicit test project are relative to test/;
    # paths copied by the legacy compatibility shim are relative to the
    # package root. The sandbox project is written elsewhere, so absolutize
    # both against their original base directory.
    source_base = has_test_project ? dirname(test_project_file) : pkg_source
    sources = Dict{String, SourceSpec}(project.sources)
    for (name, source) in sources
        (source.path === nothing || isabspath(source.path)) && continue
        abs = normpath(joinpath(source_base, source.path))
        sources[name] = SourceSpec(abs, source.url, source.rev, source.subdir)
    end
    deps = Dict{String, UUID}(project.deps)
    deps[pkg_name] = pkg_uuid
    return with_project(project; deps, sources)
end

# Parent-process flags reflected into the test subprocess (Pkg's
# `gen_subprocess_flags`). Coverage, color, warn-overwrite, depwarn, inline,
# startup-file and track-allocation are mirrored from `Base.JLOptions()`;
# `julia_args` (whatever the caller passed) go last so they win.
function test_subprocess_flags(
        source::String;
        coverage::Union{Bool, String},
        julia_args::Union{Cmd, AbstractVector{<:AbstractString}},
    )
    coverage_arg = coverage isa Bool ? (coverage ? "@$(source)" : "none") : coverage
    return ```
        --code-coverage=$(coverage_arg)
        --color=$(Base.have_color === nothing ? "auto" : Base.have_color ? "yes" : "no")
        --warn-overwrite=yes
        --depwarn=$(Base.JLOptions().depwarn == 2 ? "error" : "yes")
        --inline=$(Bool(Base.JLOptions().can_inline) ? "yes" : "no")
        --startup-file=$(Base.JLOptions().startupfile == 1 ? "yes" : "no")
        --track-allocation=$(("none", "user", "all")[Base.JLOptions().malloc_log + 1])
        $(julia_args)
    ```
end

# The `--threads` spec for the subprocess: `JULIA_NUM_THREADS` wins when set
# (the worker reads it directly), otherwise the parent's default(,interactive)
# counts are mirrored.
function test_threads_spec()
    n = get(ENV, "JULIA_NUM_THREADS", "")
    isempty(n) || return n
    return Threads.nthreads(:interactive) > 0 ?
        "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))" :
        "$(Threads.nthreads(:default))"
end

"""
    test!(env, registries, config, uuid; test_args, julia_args, io)
        -> Union{Nothing, Tuple{String, Base.Process}}

Test one package from the environment in a fresh sandbox. Returns nothing
on success, `(name, process)` on failure — the caller reports (Pkg runs all
requested packages before erroring with the collected failures).
"""
# run `runtests` in a subprocess against the environment at `project_dir`;
# returns `(name, process)` on failure, `nothing` on success
function run_test_process(
        name::String, project_dir::String, runtests::String, source::String;
        coverage, julia_args, test_args, autoprecompile::Bool, io,
    )
    flags = test_subprocess_flags(source; coverage, julia_args)
    if autoprecompile
        # precompile the test environment with the subprocess' own cache
        # flags so the caches it builds are the ones the tests will load
        # (Pkg parity); loaded-package warnings are pointless here since
        # the tests run in a fresh process. The flags are probed as their
        # packed-UInt8 form (`parse(CacheFlags, ...)` needs julia 1.13);
        # `--startup-file=no` last keeps the probe's output clean and does
        # not affect any cache flag.
        probe = `$(Base.julia_cmd()) $flags --startup-file=no --eval 'print(Base._cacheflag_to_uint8(Base.CacheFlags()))'`
        cacheflags = Base.CacheFlags(parse(UInt8, read(probe, String)))
        old_project = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = project_dir
        try
            Base.Precompilation.precompilepkgs(
                ; configs = flags => cacheflags, warn_loaded = false,
                io = precompile_io(io), precompile_detach_kwargs()...
            )
        finally
            Base.ACTIVE_PROJECT[] = old_project
        end
    end
    sep = Sys.iswindows() ? ';' : ':'
    cmd = addenv(
        `$(Base.julia_cmd()) --threads=$(test_threads_spec()) $flags --project=$project_dir $runtests $test_args`,
        "JULIA_LOAD_PATH" => "@$(sep)@stdlib",
        "JULIA_PROJECT" => nothing,
    )
    printpkgstyle(io, :Testing, "Running tests...")
    p, interrupted = subprocess_handler(cmd, io, "Testing of $name interrupted")
    interrupted && throw(InterruptException())
    success(p) || return (name, p)
    printpkgstyle(io, :Testing, "$name tests passed")
    return nothing
end

# Run `cmd` and forward a ^C to the child. At the REPL the terminal is in raw
# mode, so ^C only raises an `InterruptException` in this process and the child
# never sees a signal — without forwarding it would be SIGKILLed by process
# cleanup and never get to report. Returns `(process, interrupted::Bool)`.
function subprocess_handler(cmd::Cmd, io::IO, error_msg::String)
    # the subprocess writes through the op's io so `io = devnull` silences the
    # whole run; unwrapping the IOContext hands an interactive child the real
    # terminal handle
    out = io isa IOContext ? io.io : io
    p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out), wait = false)
    interrupted = false
    try
        wait(p)
    catch e
        e isa InterruptException || rethrow()
        interrupted = true
        printpkgstyle(io, :Testing, "$error_msg\n", color = Base.error_color())
        # Windows `kill` cannot deliver SIGINT (it terminates immediately)
        Sys.iswindows() || kill(p, Base.SIGINT)
        # give the child's handler time to report + exit, then force-kill
        if timedwait(() -> !process_running(p), 4) == :timed_out
            kill(p, Base.SIGKILL)
        end
    end
    return p, interrupted
end

function test!(
        env::Environment, registries::Vector{RegistryInstance}, config::Config,
        pkg_uuid::UUID;
        test_args::Union{Cmd, AbstractVector{<:AbstractString}} = String[],
        julia_args::Union{Cmd, AbstractVector{<:AbstractString}} = String[],
        coverage::Union{Bool, String} = false,
        allow_reresolve::Bool = true,
        force_latest_compatible_version::Bool = false,
        allow_earlier_backwards_compatible_versions::Bool = true,
        # the caller decides (API.test passes `should_autoprecompile()`);
        # the gate lives above this module
        autoprecompile::Bool = false,
        io::IO = stderr_f(),
    )
    depots = config.depots
    entry = get(env.manifest, pkg_uuid, nothing)
    name, source = if entry !== nothing
        source = entry_source_path(env.manifest_file, entry, depots)
        entry.name, source
    elseif env.project.uuid == pkg_uuid
        something(env.project.name, "unnamed project"), dirname(env.project_file)
    else
        pkgerror("package with uuid $pkg_uuid not found in the environment")
    end
    (source === nothing || !isdir(source)) && pkgerror("package $name is not installed")
    runtests = joinpath(source, "test", "runtests.jl")
    isfile(runtests) || pkgerror("testing $name requires a `test/runtests.jl` file")

    printpkgstyle(io, :Testing, name)

    # a test project that is a member of the enclosing workspace shares the
    # workspace manifest: nothing to sandbox, instantiate the test project
    # and run against it in place (Pkg parity)
    test_dir = dirname(runtests)
    member = findfirst(m -> Environments.samefile_or_equal(dirname(m.first), test_dir), env.workspace)
    if member !== nothing
        test_env = Environments.load_environment_from(env.workspace[member].first; depots)
        # Pkg parity: resolve the shared workspace manifest first so the test
        # project's dependencies are present, then run it in place.
        if Environments.is_manifest_current(test_env) !== true
            resolved = Planning.plan_resolve(test_env, registries, config)
            write_environment(test_env, resolved)
            test_env = Environments.load_environment_from(env.workspace[member].first; depots)
        end
        installed = Execution.instantiate!(test_env, registries, config; io)
        isempty(installed) || BuildOps.build!(test_env, depots, [i.uuid for i in installed]; io)
        return run_test_process(name, test_dir, runtests, source; coverage, julia_args, test_args, autoprecompile, io)
    end

    sandbox = mktempdir()
    project = sandbox_project(source, name, pkg_uuid, env.project)
    # preferences travel into the sandbox pre-merged (Pkg parity): the
    # cascade is anchored at the test project (the package's own project
    # for the legacy [targets] path), so test-level preferences win over
    # the parent environment's
    prefs_primary = isfile(joinpath(source, "test", "Project.toml")) ?
        joinpath(source, "test") : EnvFiles.projectfile_path(source)
    Execution.write_sandbox_preferences(sandbox, Execution.sandbox_preferences(env, prefs_primary))
    if force_latest_compatible_version
        project = force_latest_compat(
            project, pkg_uuid, registries;
            allow_earlier_backwards_compatible_versions,
        )
    end
    # the slice must keep the test project's own deps too (Pkg's
    # `sandbox_preserve`): a repo-tracked test dep needs its manifest pin
    # to resolve without fetching
    manifest = sliced_manifest(env, depots, [pkg_uuid; collect(values(project.deps))])
    manifest = merge_test_manifest(manifest, source)
    # the tested package tracks its source tree
    version = entry === nothing ? env.project.version : EnvFiles.entry_version(entry)
    manifest = with_manifest(
        manifest;
        deps = merge(
            manifest.deps, Dict(
                pkg_uuid => ManifestEntry(
                    name, pkg_uuid, PathTracked(source, version), false,
                    haskey(manifest, pkg_uuid) ? manifest[pkg_uuid].deps : Dict{String, UUID}(),
                    Dict{String, UUID}(), Dict{String, Union{String, Vector{String}}}(),
                    Dict{String, EnvFiles.AppInfo}(), nothing, nothing, Dict{String, Any}(),
                )
            )
        ),
    )
    sandbox_env = Environment(
        joinpath(sandbox, "Project.toml"), joinpath(sandbox, "Manifest.toml"),
        project, manifest,
    )
    empty_env = Environment(
        sandbox_env.project_file, sandbox_env.manifest_file, Project(), Manifest(),
    )
    write_environment(empty_env, sandbox_env)
    # resolve + install the test-only dependencies through the normal pipeline
    loaded = Environments.load_environment_from(sandbox_env.project_file; depots)
    printpkgstyle(io, :Resolving, "package versions...")
    planned = try
        plan_resolve(loaded, registries, config)
    catch err
        (err isa Resolve.ResolverError && allow_reresolve) || rethrow()
        printpkgstyle(
            io, :Test,
            string(
                "Could not use exact versions of packages in manifest, re-resolving. ",
                "Note: if you do not check your manifest file into source control, ",
                "then you can probably ignore this message. ",
                "However, if you do check your manifest file into source control, ",
                "then you probably want to pass the `allow_reresolve = false` kwarg ",
                "when calling the `Pkg.test` function.",
            ),
            color = Base.warn_color(),
        )
        reresolved = plan_up(loaded, registries, config, PackageRequest[])
        printpkgstyle(io, :Test, "Successfully re-resolved")
        reresolved
    end
    Execution.apply!(loaded, planned, registries, config; io)
    return run_test_process(name, sandbox, runtests, source; coverage, julia_args, test_args, autoprecompile, io)
end

# TODO: Should be included in Base
function signal_name(signal::Integer)
    return if signal == Base.SIGHUP
        "HUP"
    elseif signal == Base.SIGINT
        "INT"
    elseif signal == Base.SIGQUIT
        "QUIT"
    elseif signal == Base.SIGKILL
        "KILL"
    elseif signal == Base.SIGPIPE
        "PIPE"
    elseif signal == Base.SIGTERM
        "TERM"
    else
        string(signal)
    end
end

# a failure suffix only when it says something: plain `exit 1` is the
# ordinary test-failure exit and gets no annotation (pinned strings)
function failure_reason(p::Base.Process)
    return if Base.process_signaled(p)
        " (received signal: " * signal_name(p.termsignal) * ")"
    elseif Base.process_exited(p) && p.exitcode != 1
        " (exit code: " * string(p.exitcode) * ")"
    else
        ""
    end
end

"the pinned single/bulleted test-failure report"
function report_test_failures(pkgs_errored::Vector{Tuple{String, Base.Process}})
    isempty(pkgs_errored) && return
    if length(pkgs_errored) == 1
        pkg_name, p = first(pkgs_errored)
        pkgerror("Package $pkg_name errored during testing$(failure_reason(p))")
    else
        failures = ["• $pkg_name$(failure_reason(p))" for (pkg_name, p) in pkgs_errored]
        pkgerror("Packages errored during testing:\n", join(failures, "\n"))
    end
    return
end

end # module
