using JET
using Test
using VibePkg
using REPL
using REPL.LineEdit: LineEdit

const REPLExt = Base.get_extension(VibePkg, :REPLExt)
REPLExt === nothing && error("the REPLExt extension did not load")

@testset "JET.jl" begin
    JET.test_package(VibePkg; target_modules = (VibePkg,), toplevel_logger = nothing)
end

@testset "JET REPLExt" begin
    JET.test_package(REPLExt; target_modules = (REPLExt, VibePkg), toplevel_logger = nothing)
end

@testset "JET REPLExt entry points" begin
    JET.test_call(REPLExt.promptf, (); target_modules = (REPLExt, VibePkg))
    JET.test_call(REPLExt.create_mode, (REPL.LineEditREPL, LineEdit.Prompt); target_modules = (REPLExt, VibePkg))
    JET.test_call(REPLExt.install_in, (REPL.LineEditREPL,); target_modules = (REPLExt, VibePkg))
    JET.test_call(VibePkg.REPLMode.install_repl!, (); target_modules = (REPLExt, VibePkg))
    # LineEdit dispatches provider completions as complete_line(provider, s::PromptState, mod)
    # which falls back to the two-argument method the extension defines.
    JET.test_call(LineEdit.complete_line, (REPLExt.VibeCompletionProvider, LineEdit.PromptState); target_modules = (REPLExt, VibePkg))
end

@testset "JET entry points" begin
    JET.test_call(VibePkg.add, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.rm, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.up, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.status, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.instantiate, (); target_modules = (VibePkg,))
end
