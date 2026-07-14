# Pkg.build.
#
# Packages with a `deps/build.jl` are built deps-first in a julia
# subprocess; output goes to `scratchspaces/<uuid>/<treehash>/build.log`
# (dev'd packages: `deps/build.log`) and failures surface the log.

module BuildOps

using Base: UUID

using ..Errors: pkgerror
using ..Utils: stderr_f
using ..EnvFiles
using ..EnvFiles: ManifestEntry, entry_tree_hash, is_path_tracked, with_project
using ..Depots: DepotStack, depots1, scratchspaces_dir, log_usage
using ..Environments: Environment, write_environment
using ..Execution: entry_source_path, sandbox_manifest, sandbox_preferences,
    write_sandbox_preferences
using ..Utils: printpkgstyle, pathrepr

export build!

build_file(source::String) = joinpath(source, "deps", "build.jl")

function build_log_file(d::DepotStack, entry::ManifestEntry, source::String)
    if is_path_tracked(entry)
        return joinpath(source, "deps", "build.log")
    end
    hash = entry_tree_hash(entry)
    key = hash === nothing ? "unknown" : string(hash)
    dir = mkpath(joinpath(scratchspaces_dir(depots1(d)), string(entry.uuid), key))
    return joinpath(dir, "build.log")
end

# deps-first order over the manifest slice `uuids` (top-level recursion to
# avoid a boxed self-referential closure)
function topo_visit!(order, seen, manifest, uuids, uuid)
    uuid in seen && return
    push!(seen, uuid)
    entry = get(manifest, uuid, nothing)
    entry === nothing && return
    for dep in values(entry.deps)
        topo_visit!(order, seen, manifest, uuids, dep)
    end
    uuid in uuids && push!(order, uuid)
    return
end
function topo_order(env::Environment, uuids::Vector{UUID})
    order = UUID[]
    seen = Set{UUID}()
    for uuid in uuids
        topo_visit!(order, seen, env.manifest, uuids, uuid)
    end
    return order
end

function run_build(
        env::Environment, entry::ManifestEntry, source::String, log_file::String,
        depots::DepotStack; io::IO, verbose::Bool = false,
    )
    printpkgstyle(io, :Building, verbose ? entry.name : "$(entry.name) → $(pathrepr(log_file))")
    # isolated build sandbox: the package plus its dependency closure
    sandbox = mktempdir()
    project = with_project(EnvFiles.Project(); deps = Dict{String, UUID}(entry.name => entry.uuid))
    manifest = sandbox_manifest(env, depots, entry.uuid)
    sandbox_env = Environment(
        joinpath(sandbox, "Project.toml"), joinpath(sandbox, "Manifest.toml"),
        project, manifest,
    )
    empty_env = Environment(
        sandbox_env.project_file, sandbox_env.manifest_file,
        EnvFiles.Project(), EnvFiles.Manifest(),
    )
    write_environment(empty_env, sandbox_env)
    # preferences travel into the build sandbox pre-merged (Pkg parity):
    # anchored at deps/ if it has its own project, else at the package's
    # project, with the parent environment behind it
    deps_project = EnvFiles.projectfile_path(joinpath(source, "deps"); strict = true)
    prefs_primary = something(deps_project, EnvFiles.projectfile_path(source))
    write_sandbox_preferences(sandbox, sandbox_preferences(env, prefs_primary))
    code = """
    using Pkg
    cd($(repr(source)))
    include($(repr(build_file(source))))
    """
    cmd = addenv(
        `$(joinpath(Sys.BINDIR, "julia")) -O0 --color=no --history-file=no --startup-file=no --project=$sandbox --eval $code`,
        "JULIA_LOAD_PATH" => "@$(Sys.iswindows() ? ';' : ':')@stdlib",
        "JULIA_PROJECT" => nothing,
    )
    ok = if verbose
        # `verbose`: build output goes to the callers streams, not the log
        success(pipeline(cmd; stdout = stdout, stderr = stderr))
    else
        open(log_file, "w") do log
            success(pipeline(cmd; stdout = log, stderr = log))
        end
    end
    if !ok && verbose
        pkgerror("Error building `$(entry.name)`")
    elseif !ok
        tail = isfile(log_file) ? last(readlines(log_file), min(50, countlines(log_file))) : String[]
        pkgerror(
            "Error building `$(entry.name)`" *
                (isempty(tail) ? "" : ": \n" * join(tail, "\n"))
        )
    end
    return
end

"""
    build!(env, depots, uuids; verbose, io)

Build the given packages (deps-first) if they have a `deps/build.jl`.
With an empty `uuids`, builds the project's direct dependencies that need it.
`verbose` sends build output to `stdout`/`stderr` instead of the log file.
"""
function build!(
        env::Environment, depots::DepotStack, uuids::Vector{UUID} = UUID[];
        verbose::Bool = false, io::IO = stderr_f(),
    )
    if isempty(uuids)
        uuids = collect(values(env.project.deps))
    end
    for uuid in topo_order(env, uuids)
        entry = get(env.manifest, uuid, nothing)
        entry === nothing && continue
        source = entry_source_path(env.manifest_file, entry, depots)
        (source === nothing || !isdir(source)) && continue
        isfile(build_file(source)) || continue
        log_file = build_log_file(depots, entry, source)
        run_build(env, entry, source, log_file, depots; io, verbose)
        # scratch-usage entry so gc keeps the build log's scratchspace
        log_usage(depots, env.manifest_file, "scratch_usage.toml")
    end
    return
end

end # module
