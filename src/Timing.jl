# Optional timing instrumentation.
#
# `TIMER` is the package-global TimerOutput. Functions on the hot paths
# carry `@timeit TIMER "label" ...` sections and every public entry point
# in API.jl is wrapped in `@operation`: the outermost operation of a call
# tree resets and starts `TIMER` on entry and stops it on exit, so after
# any operation `TIMER` holds exactly that operation's timings and stray
# instrumented calls between operations record nothing.
# `Timing.print_timings(true)` (or `JULIA_PKG_TIMING=true`) additionally
# prints the report when the operation returns.
#
# Disabled by default: TimerOutputs is not a dependency of VibePkg and its
# load below is commented out — the fallback definitions turn `@timeit`
# and `@operation` into no-ops and every instrumentation site compiles
# unchanged. To enable, `pkg> add TimerOutputs` to the VibePkg project and
# uncomment the `using TimerOutputs` line.
#
# TimerOutputs is not task-safe: `@timeit` must never run inside the
# concurrent download tasks (the `@async` batches in Execution.jl) —
# instrument the function that owns the `@sync` instead.

module Timing

# using TimerOutputs: TimerOutputs, TimerOutput, @timeit, reset_timer!, print_timer, enable_timer!, disable_timer!

using ..Utils: stderr_f

const PRINT_TIMINGS = Ref(false)

"`print_timings(true)`: print `TIMER` after every top-level operation."
print_timings(on::Bool = true) = (PRINT_TIMINGS[] = on; nothing)

should_print_timings() =
    PRINT_TIMINGS[] || Base.get_bool_env("JULIA_PKG_TIMING", false) == true

@static if @isdefined(TimerOutputs)

    const TIMER = TimerOutput()
    disable_timer!(TIMER)   # only running while an operation is in flight

    # operations never cross task boundaries, so a depth counter suffices
    const OP_DEPTH = Ref(0)

    function maybe_print_timings()
        should_print_timings() || return
        io = stderr_f()
        println(io)
        print_timer(io, TIMER)
        println(io)
        return
    end

    function op_label(fdef::Expr)
        sig = fdef.args[1]
        while sig isa Expr && (sig.head === :where || sig.head === Symbol("::"))
            sig = sig.args[1]
        end
        Meta.isexpr(sig, :call) && sig.args[1] isa Symbol ||
            error("@operation could not infer a label; pass one explicitly")
        return String(sig.args[1])
    end

    function operation_expr(label::String, fdef::Expr)
        Meta.isexpr(fdef, :function) && length(fdef.args) == 2 ||
            error("@operation expects a `function ... end` definition")
        body = quote
            local outermost = OP_DEPTH[] == 0
            if outermost
                reset_timer!(TIMER)
                enable_timer!(TIMER)
            end
            OP_DEPTH[] += 1
            try
                @timeit TIMER $label $(esc(fdef.args[2]))
            finally
                OP_DEPTH[] -= 1
                if outermost
                    disable_timer!(TIMER)
                    maybe_print_timings()
                end
            end
        end
        return Expr(:function, esc(fdef.args[1]), body)
    end

    """
        @operation function add(...) ... end
        @operation "rm" function _rm_requests(...) ... end

    Mark a public entry point: the outermost operation of a call tree resets
    and starts `TIMER` on entry and stops (and, when printing is enabled,
    prints) it on exit; nested operations only open a timer section. The
    label defaults to the function name.
    """
    macro operation(fdef::Expr)
        return operation_expr(op_label(fdef), fdef)
    end
    macro operation(label::String, fdef::Expr)
        return operation_expr(label, fdef)
    end

else # fallback: TimerOutputs load commented out above

    const TIMER = nothing

    macro timeit(args...)
        return esc(args[end])
    end
    macro operation(fdef::Expr)
        return esc(fdef)
    end
    macro operation(label::String, fdef::Expr)
        return esc(fdef)
    end

end # @static if

end # module
