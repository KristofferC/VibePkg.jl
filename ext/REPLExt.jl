# Interactive vpkg> mode. Loaded as a package
# extension when the REPL stdlib is present; installed explicitly with
# `VibePkg.REPLMode.install_repl!()` so it can coexist with Pkg's own mode.

module REPLExt

if Base.get_bool_env("JULIA_PKG_DISALLOW_PKG_PRECOMPILATION", false) == true
    error("Precompiling VibePkg extension REPLExt is disallowed. JULIA_PKG_DISALLOW_PKG_PRECOMPILATION=$(ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"])")
end

using REPL: REPL
using REPL.LineEdit: LineEdit

import VibePkg
using VibePkg.REPLMode: REPLMode, do_cmd
using VibePkg.Errors: PkgError
using VibePkg.Utils: unstableio

# The prompt is recomputed at most once per change, not per keystroke:
# `promptf` serves the cache and `invalidate_prompt!` drops it after every
# command and on `]` entry (Pkg parity, #4683).
const CACHED_PROMPT = Ref{Union{Nothing, String}}(nothing)

invalidate_prompt!() = (CACHED_PROMPT[] = nothing; nothing)

function promptf()
    cached = CACHED_PROMPT[]
    cached === nothing || return cached
    proj = Base.active_project()
    name = if proj === nothing
        "v$(VERSION.major).$(VERSION.minor)"
    else
        base = basename(dirname(proj))
        startswith(base, "v$(VERSION.major).") ? "@" * base : base
    end
    offline = VibePkg.API.OFFLINE_MODE[] ? "[offline] " : ""
    prompt = "($name) $(offline)vpkg> "
    CACHED_PROMPT[] = prompt
    return prompt
end

struct VibeCompletionProvider <: LineEdit.CompletionProvider end

function LineEdit.complete_line(::VibeCompletionProvider, s; hint::Bool = false)
    buf = LineEdit.buffer(s)
    partial = String(buf.data[1:(buf.ptr - 1)])
    matches, word = REPLMode.completions_for(partial)
    return matches, word, !isempty(matches)
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

# The mode installs itself: into a running REPL when the extension loads
# late, or via atreplinit when VibePkg is loaded from a startup file.
function __init__()
    if isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL
        try
            install_in(Base.active_repl)
        catch err
            @warn "failed to install the VibePkg REPL mode" err
        end
    else
        atreplinit() do repl
            if isinteractive() && repl isa REPL.LineEditREPL
                try
                    install_in(repl)
                catch err
                    @warn "failed to install the VibePkg REPL mode" err
                end
            end
        end
    end
    return
end

include("precompile_workload.jl")

end # module
