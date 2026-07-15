module VibePkg

if Base.get_bool_env("JULIA_PKG_DISALLOW_PKG_PRECOMPILATION", false) == true
    error("Precompiling VibePkg is disallowed. JULIA_PKG_DISALLOW_PKG_PRECOMPILATION=$(ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"])")
end

# Modules in strict layer order: each file may depend only on
# files included before it.
include("Errors.jl")
include("Utils.jl")
include("Timing.jl")
include("MiniProgressBars.jl")
include("FuzzySorting.jl")
include("Versions.jl")
include("EnvFiles.jl")
include("Depots.jl")
include("Configs.jl")
include("Stdlibs.jl")
include("TreeHash.jl")
include("Git.jl")
include("Fetch.jl")
include("ArtifactOps.jl")
include("Registries.jl")
include("Resolve/Resolve.jl")
include("Environments.jl")
include("Planning.jl")
include("Execution.jl")
include("GCOps.jl")
include("BuildOps.jl")
include("TestOps.jl")
include("AppsOps.jl")
include("Display.jl")
include("API.jl")

using .Errors: PkgError
using .API: PackageSpec
using .Configs: UpgradeLevel, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PreserveLevel, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT,
    PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_TIERED_INSTALLED, PRESERVE_NONE,
    PackageMode, PKGMODE_PROJECT, PKGMODE_MANIFEST

# Pkg-compatible namespaces (Pkg.Artifacts, Pkg.Registry, Pkg.Apps)
include("compat/Artifacts.jl")
include("compat/Registry.jl")
include("compat/Apps.jl")

include("REPLMode.jl")

# Public operation surface (Pkg-compatible aliases of API functions)
const add = API.add
const develop = API.develop
const dev = API.develop
const rm = API.rm
const up = API.up
const update = API.up
const pin = API.pin
const free = API.free
const resolve = API.resolve
const instantiate = API.instantiate
const status = API.status
const compat = API.compat
const activate = API.activate
const generate = API.generate
const why = API.why
const offline = API.offline
const respect_sysimage_versions = API.respect_sysimage_versions
const precompile = API.precompile
const gc = API.gc
const build = API.build
const test = API.test
const undo = API.undo
const redo = API.redo
const dependencies = API.dependencies
const project = API.project
const readonly = API.readonly
const setprotocol! = Git.setprotocol!
const PackageInfo = API.PackageInfo
const ProjectInfo = API.ProjectInfo

"""
    @pkg_str

`pkg"add Example"`: run a `pkg>` REPL command from Julia code.
"""
macro pkg_str(str::String)
    return :(REPLMode.pkgstr($str))
end

# exported names mirror Pkg's export list; the remaining Pkg-`public` verbs
# are marked public below
export @pkg_str
export add, develop, dev, rm, up, update, pin, free, resolve, instantiate,
    status, compat, activate, generate, why, build, test, PackageSpec
export PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT
export UpgradeLevel, UPLEVEL_MAJOR, UPLEVEL_MINOR, UPLEVEL_PATCH
export PreserveLevel, PRESERVE_TIERED_INSTALLED, PRESERVE_TIERED, PRESERVE_ALL_INSTALLED,
    PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_NONE
export Registry, Apps

public gc, precompile, readonly, redo, undo, offline, dependencies, project,
    respect_sysimage_versions, setprotocol!, PackageInfo, ProjectInfo

"""
    vpkg command [arguments...]

Run a VibePkg REPL-mode command from the terminal. The `vpkg` executable is
installed with `pkg> app add VibePkg` (or `app develop` for a source checkout).
"""
function select_cli_project!()
    # The app shim puts VibePkg's installation environment on LOAD_PATH so
    # `julia -m VibePkg` can load. With no explicit --project/JULIA_PROJECT,
    # Base.active_project() would therefore target VibePkg itself. Select the
    # caller's nearest project instead, matching `--project=@.`, and use the
    # normal versioned environment when the working tree has no project.
    Base.active_project(false) === nothing || return nothing
    project = something(Base.current_project(), "@v#.#")
    Base.set_active_project(project)
    return nothing
end

function (@main)(args)
    argv = collect(String, args)
    if isempty(argv) || argv == ["-h"] || argv == ["--help"]
        REPLMode.show_help(Utils.stdout_f())
        return 0
    end
    select_cli_project!()
    try
        REPLMode.do_cmd(argv)
    catch err
        err isa PkgError || rethrow()
        io = Utils.stderr_f()
        printstyled(io, "ERROR: "; bold = true, color = Base.error_color())
        showerror(io, err)
        println(io)
        return 1
    end
    return 0
end

include("precompile_workload.jl")

end # module
