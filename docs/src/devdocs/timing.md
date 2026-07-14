# Timing instrumentation

VibePkg's hot paths are instrumented with
[TimerOutputs](https://github.com/KristofferC/TimerOutputs.jl) through the
`Timing` module (`src/Timing.jl`).

## Enabling

Timing is disabled by default: TimerOutputs is not a dependency of VibePkg
and its load in `src/Timing.jl` is commented out — `@timeit` and
`@operation` are no-op fallbacks and every instrumentation site compiles
unchanged with zero overhead. To enable it:

1. Add TimerOutputs to the VibePkg project explicitly
   (`pkg> add TimerOutputs` with the VibePkg environment active).
2. Uncomment the `using TimerOutputs: ...` line at the top of
   `src/Timing.jl`.

## Usage

`Timing.TIMER` is the global timer. Every public entry point in `API.jl` is
wrapped in `Timing.@operation`: the outermost operation of a call tree resets
and starts the timer on entry and stops it (`disable_timer!`) on exit, so
after any operation `TIMER` holds exactly that operation's timings and
instrumented code running outside an operation records nothing:

```julia-repl
julia> VibePkg.up();

julia> VibePkg.Timing.TIMER
──────────────────────────────────────────────────────────────────────────────
                                    Time                    Allocations
                           ───────────────────────   ────────────────────────
     Tot / % measured:          1.52s /  98.1%           98.3MiB /  95.4%
 ...
```

To print the report automatically when an operation returns, call
`VibePkg.Timing.print_timings(true)` or set `JULIA_PKG_TIMING=true`.

## Instrumenting more code

- Annotate a function whose cost is significant or interesting with
  `@timeit TIMER "label" function foo(...) ... end` (import both names with
  `using ..Timing: @timeit, TIMER`), or wrap an individual call site.
- Wrap a new public entry point with `Timing.@operation` so it participates
  in the reset-on-entry/print-on-exit protocol. Nested operations only open
  a timer section; a label can be passed explicitly
  (`@operation "rm" function _rm_requests(...)`) and defaults to the
  function name.
- TimerOutputs is not task-safe: never put `@timeit` inside the concurrent
  download tasks (the `@async` batches in `Execution.jl`) — instrument the
  function that owns the `@sync` instead.
