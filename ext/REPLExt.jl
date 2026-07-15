# Interactive vpkg> mode. Loaded as a package
# extension when the REPL stdlib is present; installed explicitly with
# `VibePkg.REPLMode.install_repl!()` so it can coexist with Pkg's own mode.

module REPLExt

if Base.get_bool_env("JULIA_PKG_DISALLOW_PKG_PRECOMPILATION", false) == true
    error("Precompiling VibePkg extension REPLExt is disallowed. JULIA_PKG_DISALLOW_PKG_PRECOMPILATION=$(ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"])")
end

using REPL: REPL
using REPL.LineEdit: LineEdit
using REPL: TerminalMenus

import VibePkg
using VibePkg.Depots: depot_stack
using VibePkg.Environments: find_workspace_root, safe_realpath
using VibePkg.Environments: load_environment
using VibePkg.EnvFiles: read_project
using VibePkg.REPLMode: REPLMode, do_cmd
using VibePkg.Errors: PkgError
using VibePkg.Utils: unstableio, stderr_f, printpkgstyle, pathrepr
import VibePkg.Display
import VibePkg.Fetch
import VibePkg.Registries

# The prompt is recomputed at most once per change, not per keystroke:
# `promptf` serves the cache and `invalidate_prompt!` drops it after every
# command and on `]` entry (Pkg parity, #4683).
const CACHED_PROMPT = Ref{Union{Nothing, String}}(nothing)

invalidate_prompt!() = (CACHED_PROMPT[] = nothing; nothing)

function project_name(project_file::String)
    project = try
        read_project(project_file)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
    name = if project === nothing || project.name === nothing
        basename(dirname(project_file))
    else
        project.name::String
    end
    project_path = safe_realpath(project_file)
    for depot in Base.DEPOT_PATH
        environments = safe_realpath(joinpath(depot, "environments"))
        relative = try
            relpath(project_path, environments)
        catch
            continue
        end
        if !isabspath(relative) && first(splitpath(relative)) != ".."
            return "@" * name
        end
    end
    return name
end

function promptf()
    cached = CACHED_PROMPT[]
    cached === nothing || return cached
    project_file = Base.active_project()
    prefix = ""
    if project_file !== nothing
        root = find_workspace_root(project_file)
        root_name = project_name(root)
        if textwidth(root_name) > 30
            root_name = first(root_name, 27) * "..."
        end
        path_prefix = if root == project_file
            ""
        else
            relative = replace(relpath(dirname(project_file), dirname(root)), '\\' => '/')
            "/" * relative
        end
        prefix = "($(root_name)$(path_prefix)) "
    end
    VibePkg.API.OFFLINE_MODE[] && (prefix *= "[offline] ")
    prompt = "$(prefix)vpkg> "
    CACHED_PROMPT[] = prompt
    return prompt
end

struct VibeCompletionProvider <: LineEdit.CompletionProvider end

function LineEdit.complete_line(::VibeCompletionProvider, s; hint::Bool = false)
    partial = REPL.beforecursor(s.input_buffer)
    matches, word = REPLMode.completions_for(partial)
    named_completions = map(LineEdit.NamedCompletion, matches)
    # LineEdit's current interface uses a zero-based byte region. The core
    # completion API replaces the final word, so its bounds are determined
    # directly from the before-cursor string.
    stop = ncodeunits(partial)
    region = (stop - ncodeunits(word)) => stop
    return named_completions, region, !isempty(matches)
end

function create_mode(repl::REPL.AbstractREPL, main::LineEdit.Prompt)
    pkg_mode = LineEdit.Prompt(
        promptf;
        prompt_prefix = repl.options.hascolor ? Base.text_colors[:blue] : "",
        prompt_suffix = "",
        complete = VibeCompletionProvider(),
        sticky = true,
    )
    pkg_mode.repl = repl
    hp = main.hist
    hp.mode_mapping[:vibepkg] = pkg_mode
    pkg_mode.hist = hp

    prefix_prompt, prefix_keymap = LineEdit.setup_prefix_keymap(hp, pkg_mode)

    pkg_mode.on_done = function (s, buf, ok)
        ok || return REPL.transition(s, :abort)
        input = String(take!(buf))
        REPL.reset(repl)
        try
            # unstableio: hand do_cmd the IOContext{IO} type the precompile
            # workload compiled for, not this terminal's concrete stream type
            do_cmd(input; io = unstableio(repl.t.out_stream))
        catch err
            if err isa PkgError || err isa VibePkg.Resolve.ResolverError
                printstyled(repl.t.err_stream, "ERROR: "; color = :red, bold = true)
                println(repl.t.err_stream, sprint(showerror, err))
            else
                Base.invokelatest(Base.display_error, repl.t.err_stream, Base.current_exceptions())
            end
        end
        invalidate_prompt!()
        REPL.prepare_next(repl)
        REPL.reset_state(s)
        return s.current_mode.sticky ? true : REPL.transition(s, main)
    end

    mk = REPL.mode_keymap(main)
    keymaps = Dict{Any, Any}[]
    # Julia 1.13's new REPL.History search is wired through history_keymap;
    # older Julia versions require the separate search-mode keymap.
    if !isdefined(REPL, :History)
        push!(keymaps, last(LineEdit.setup_search_keymap(hp)))
    end
    append!(
        keymaps, Dict{Any, Any}[
            mk, prefix_keymap, LineEdit.history_keymap,
            LineEdit.default_keymap, LineEdit.escape_defaults,
        ]
    )
    pkg_mode.keymap_dict = LineEdit.keymap(keymaps)
    return pkg_mode
end

const INSTALLED = Ref(false)

function install_in(repl::REPL.AbstractREPL; key::Char = ']')
    INSTALLED[] && return
    isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
    main = repl.interface.modes[1]
    pkg_mode = create_mode(repl, main)
    push!(repl.interface.modes, pkg_mode)
    keymap = Dict{Any, Any}(
        key => function (s, args...)
            return if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                invalidate_prompt!()
                LineEdit.transition(s, pkg_mode) do
                    LineEdit.state(s, pkg_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, key)
            end
        end
    )
    main.keymap_dict = LineEdit.keymap_merge(main.keymap_dict, keymap)
    INSTALLED[] = true
    return nothing
end

function REPLMode.install_repl!(; key::Char = ']')
    isdefined(Base, :active_repl) && Base.active_repl !== nothing ||
        VibePkg.Errors.pkgerror("no active REPL to install into")
    return install_in(Base.active_repl; key)
end

############################
# Missing-package add hook #
############################

function registered_missing_packages(pkgs::Vector{Symbol})
    registries = Registries.reachable_registries(
        depot_stack(); read_from_tarball = Fetch.pkg_server() !== nothing,
    )
    available = Symbol[]
    for pkg in pkgs
        name = String(pkg)
        found = false
        for registry in registries, (uuid, entry) in Registries.registry_pkgs(registry)
            if entry.name == name && uuid != Registries.JULIA_UUID
                found = true
                break
            end
        end
        found && push!(available, pkg)
    end
    return available
end

"Prompt to install names that Julia's loader could not find."
function try_prompt_pkg_add(
        pkgs::Vector{Symbol}; input_io::IO = stdin, io::IO = stderr_f(),
    )
    available = registered_missing_packages(pkgs)
    isempty(available) && return false
    shown = length(available) == 1 ? String(only(available)) : "[$(join(available, ", "))]"
    plural = length(available) == 1 ? "package" : "packages"
    println(io, "Missing $plural $shown available from a registry.")
    print(io, "Install $plural? [y/n]: ")
    flush(io)
    response = try
        readline(input_io)
    catch err
        err isa EOFError || rethrow()
        return false
    end
    answer = lowercase(strip(response))
    (isempty(answer) || answer in ("y", "yes")) || return false
    VibePkg.add(string.(available); io)
    return length(available) == length(pkgs)
end

#############################
# Interactive compat editor #
#############################

function edit_compat_buffer(
        input_io::IO, io::IO, dep::String, initial::String,
    )
    prompt = "  Edit compat entry for $dep:"
    print(io, prompt)
    buffer = initial
    cursor = length(buffer)
    start_pos = length(prompt) + 2
    move_start = "\e[$(start_pos)G"
    clear_to_end = "\e[0J"
    tty = input_io isa Base.TTY
    tty && ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), input_io.handle, true)
    return try
        while true
            print(io, move_start, clear_to_end, buffer, "\e[$(start_pos + cursor)G")
            key = TerminalMenus._readkey(input_io)
            if key == '\r'
                println(io)
                return buffer
            elseif key == '\x03'
                println(io)
                return nothing
            elseif key == TerminalMenus.ARROW_RIGHT
                cursor = min(length(buffer), cursor + 1)
            elseif key == TerminalMenus.ARROW_LEFT
                cursor = max(0, cursor - 1)
            elseif key == TerminalMenus.HOME_KEY
                cursor = 0
            elseif key == TerminalMenus.END_KEY
                cursor = length(buffer)
            elseif key == TerminalMenus.DEL_KEY
                if cursor == 0 && !isempty(buffer)
                    buffer = buffer[2:end]
                elseif cursor < length(buffer)
                    buffer = buffer[1:cursor] * buffer[(cursor + 2):end]
                end
            elseif key isa TerminalMenus.Key
                # Other escaped multi-byte keys do not edit the entry.
            elseif key == '\x7f'
                # In particular, backspace at the start of an empty entry is
                # a no-op (Pkg.jl #3828), never a bounds error.
                if cursor > 0
                    buffer = cursor == 1 ? buffer[2:end] :
                        cursor == length(buffer) ? buffer[1:(end - 1)] :
                        buffer[1:(cursor - 1)] * buffer[(cursor + 1):end]
                    cursor -= 1
                end
            else
                buffer = cursor == 0 ? key * buffer :
                    cursor == length(buffer) ? buffer * key :
                    buffer[1:cursor] * key * buffer[(cursor + 1):end]
                cursor += 1
            end
        end
    finally
        tty && ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), input_io.handle, false)
    end
end

function interactive_compat(; io::IO = stderr_f(), input_io::IO = stdin)
    env = load_environment(; depots = depot_stack())
    printpkgstyle(io, :Compat, pathrepr(env.project_file))
    deps = sort!(collect(env.project.deps); by = first)
    longest = max(length("julia"), maximum(length(first(dep)) for dep in deps; init = 0))
    labels = String[
        Display.compat_line(
            io, "julia", nothing, Display.get_compat_str(env.project, "julia"),
            longest; indent = "",
        ),
    ]
    names = String["julia"]
    for (name, uuid) in deps
        push!(
            labels,
            Display.compat_line(
                io, name, uuid, Display.get_compat_str(env.project, name),
                longest; indent = "",
            ),
        )
        push!(names, name)
    end
    menu = TerminalMenus.RadioMenu(labels; pagesize = length(labels), charset = :ascii)
    terminal = TerminalMenus.default_terminal(in = input_io, out = io)
    choice = try
        TerminalMenus.request(terminal, "  Select an entry to edit:", menu)
    catch err
        err isa InterruptException || rethrow()
        println(io)
        return false
    end
    choice == -1 && return false
    dep = names[choice]
    initial = something(Display.get_compat_str(env.project, dep), "")
    edited = edit_compat_buffer(input_io, io, dep, initial)
    edited === nothing && return false
    VibePkg.compat(dep, strip(edited); io)
    return nothing
end

REPLMode.INTERACTIVE_COMPAT_HOOK[] = interactive_compat

# The mode installs itself: into a running REPL when the extension loads
# late, or via atreplinit when VibePkg is loaded from a startup file.
function __init__()
    if isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL
        try
            install_in(Base.active_repl)
        catch err
            @warn "Initial installation of the VibePkg REPL mode failed" exception = err
        end
    else
        atreplinit() do repl
            if isinteractive() && repl isa REPL.LineEditREPL
                try
                    install_in(repl)
                catch err
                    @warn "Deferred installation of the VibePkg REPL mode failed" exception = err
                end
            end
        end
    end
    if isdefined(REPL, :install_packages_hooks) &&
            !(try_prompt_pkg_add in REPL.install_packages_hooks)
        push!(REPL.install_packages_hooks, try_prompt_pkg_add)
    end
    REPLMode.INTERACTIVE_COMPAT_HOOK[] = interactive_compat
    return
end

include("precompile_workload.jl")

end # module
