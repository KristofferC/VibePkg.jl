# Precompile workload for the interactive surface (Pkg parity:
# ext/REPLExt/precompile.jl): mode installation, the prompt, and completion
# run against a fake terminal at ext-precompile time so `]` and the first
# keystrokes hit compiled code. Command execution is covered by the parent
# package's workload; `do_cmd` here runs in TEST_MODE (parse-only, no depot
# access) purely to compile the io-kwarg entry point the `on_done` callback
# uses.

using PrecompileTools: @compile_workload

struct FakeTerminal <: REPL.Terminals.UnixTerminal
    in_stream::IOBuffer
    out_stream::IOBuffer
    err_stream::IOBuffer
    hascolor::Bool
    raw::Bool
end
FakeTerminal() = FakeTerminal(IOBuffer(), IOBuffer(), IOBuffer(), false, true)
REPL.Terminals.raw!(::FakeTerminal, raw::Bool) = raw

function precompile_ext()
    term = FakeTerminal()
    repl = REPL.LineEditREPL(term, false)
    install_in(repl)
    pkg_mode = last(repl.interface.modes)
    promptf()
    state = LineEdit.init_state(term, pkg_mode)
    LineEdit.edit_insert(state, "ad")
    LineEdit.complete_line(VibeCompletionProvider(), state)
    LineEdit.complete_line(VibeCompletionProvider(), state; hint = true)
    REPLMode.TEST_MODE[] = true
    try
        do_cmd("st"; io = unstableio(term.out_stream))
    finally
        REPLMode.TEST_MODE[] = false
    end
    # the on_done closure can't be invoked without a live MIState; give its
    # body a compiled instance for the argument types LineEdit passes
    Base.precompile(pkg_mode.on_done, (LineEdit.MIState, IOBuffer, Bool))
    # scrub: nothing from the fake REPL may bake into the image
    INSTALLED[] = false
    invalidate_prompt!()
    return
end

@compile_workload precompile_ext()
