module MiniProgressBars

export MiniProgressBar, start_progress, end_progress, show_progress, ProgressLogger

using Printf: @sprintf

import Base.CoreLogging as CoreLogging

# Until Base.format_bytes supports a digits keyword
# (`digits` is decimal places — what Ryu.writefixed takes — not sigdigits)
function pkg_format_bytes(bytes; binary = true, digits::Integer = 3)
    units = binary ? Base._mem_units : Base._cnt_units
    factor = binary ? 1024 : 1000
    bytes, mb = Base.prettyprint_getunits(bytes, length(units), Int64(factor))
    if mb == 1
        return string(Int(bytes), " ", Base._mem_units[mb], bytes == 1 ? "" : "s")
    else
        return string(Base.Ryu.writefixed(Float64(bytes), digits), binary ? " $(units[mb])" : "$(units[mb])B")
    end
end

Base.@kwdef mutable struct MiniProgressBar
    max::Int = 1
    header::String = ""
    color::Union{Int, Symbol} = :nothing   # Base.info_color() can be an Int
    width::Int = 40
    current::Int = 0
    status::String = "" # If not empty this string replaces the bar
    below::Vector{String} = String[] # Extra (dimmed) lines rendered under the bar
    prev::Int = 0
    prev_status::String = ""
    prev_header::String = ""
    prev_below::Vector{String} = String[]
    prev_lines::Int = 1 # height of the last drawn block (bar + below lines)
    has_shown::Bool = false
    time_shown::Float64 = 0.0
    mode::Symbol = :percentage # :percentage :int :data
    always_reprint::Bool = false
    indent::Int = 4
    main::Bool = true
end

const PROGRESS_BAR_TIME_GRANULARITY = Ref(1 / 30.0) # 30 fps
const PROGRESS_BAR_PERCENTAGE_GRANULARITY = Ref(0.1)

function start_progress(io::IO, _::MiniProgressBar)
    ansi_disablecursor = "\e[?25l"
    return print(io, ansi_disablecursor)
end

function show_progress(io::IO, p::MiniProgressBar; termwidth = nothing, carriagereturn = true, force = false)
    # clamp: a server can understate the total (`current > max`), which must
    # not draw past the bar width
    if p.max == 0
        perc = 0.0
        prev_perc = 0.0
    else
        perc = clamp(p.current / p.max * 100, 0.0, 100.0)
        prev_perc = clamp(p.prev / p.max * 100, 0.0, 100.0)
    end
    # Bail early if we are not updating the progress bar,
    # Saves printing to the terminal. `abs`: progress can go backwards
    # (e.g. git switching from object counts to delta counts).
    changed = abs(perc - prev_perc) > PROGRESS_BAR_PERCENTAGE_GRANULARITY[] ||
        p.status != p.prev_status || p.header != p.prev_header || p.below != p.prev_below
    if !force && !p.always_reprint && p.has_shown && !changed
        return
    end
    t = time()
    if !force && !p.always_reprint && p.has_shown && (t - p.time_shown) < PROGRESS_BAR_TIME_GRANULARITY[]
        return
    end
    p.time_shown = t
    p.prev = p.current
    p.prev_status = p.status
    p.prev_header = p.header
    p.prev_below = copy(p.below)
    p.has_shown = true

    progress_text = if p.mode == :percentage
        @sprintf "%5.1f %%" perc
    elseif p.mode == :int
        string(p.current, "/", p.max)
    elseif p.mode == :data
        lpad(string(pkg_format_bytes(p.current; digits = 1), "/", pkg_format_bytes(p.max; digits = 1)), 20)
    else
        error("Unsupported progress-bar mode $(repr(p.mode)); expected :percentage, :int, or :data")
    end
    termwidth = @something termwidth displaysize(io)[2]
    max_progress_width = max(0, min(termwidth - textwidth(p.header) - textwidth(progress_text) - 10, p.width))
    n_filled = floor(Int, max_progress_width * perc / 100)
    partial_filled = (max_progress_width * perc / 100) - n_filled
    n_left = max_progress_width - n_filled
    below = [truncate_to_width(s, termwidth - p.indent - 2) for s in p.below]
    headers = split(p.header)
    to_print = sprint(; context = io) do io
        # the cursor rests on the last line of the previously drawn block:
        # move up to the bar line and rewrite every line in place
        p.prev_lines > 1 && print(io, "\e[", p.prev_lines - 1, "A")
        print(io, "\e[2K", " "^p.indent)
        if p.main
            # an empty header (the `MiniProgressBar()` default) splits to
            # no words at all — print nothing rather than index headers[1]
            if !isempty(headers)
                printstyled(io, headers[1], " "; color = :green, bold = true)
                length(headers) > 1 && printstyled(io, join(headers[2:end], ' '), " ")
            end
        else
            print(io, p.header, " ")
        end
        if !isempty(p.status)
            print(io, p.status)
        else
            hascolor = get(io, :color, false)::Bool
            printstyled(io, "━"^n_filled; color = p.color)
            if n_left > 0
                if hascolor
                    if partial_filled > 0.5
                        printstyled(io, "╸"; color = p.color) # More filled, use ╸
                    else
                        printstyled(io, "╺"; color = :light_black) # Less filled, use ╺
                    end
                end
                c = hascolor ? "━" : " "
                printstyled(io, c^(n_left - 1 + !hascolor); color = :light_black)
            end
            printstyled(io, " "; color = :light_black)
            print(io, progress_text)
        end
        for s in below
            print(io, "\n\e[2K", " "^(p.indent + 2))
            printstyled(io, s; color = :light_black)
        end
        # wipe lines left over from a taller previous block
        shrink = p.prev_lines - 1 - length(below)
        if shrink > 0
            print(io, "\n\e[2K"^shrink, "\e[", shrink, "A")
        end
        carriagereturn && print(io, "\r")
    end
    p.prev_lines = 1 + length(below)
    # Print everything in one call
    return print(io, to_print)
end

function truncate_to_width(s::String, w::Int)
    textwidth(s) <= w && return s
    w <= 1 && return ""
    out = IOBuffer()
    tw = 0
    for c in s
        cw = textwidth(c)
        tw + cw > w - 1 && break
        print(out, c)
        tw += cw
    end
    return String(take!(out)) * "…"
end

# Erase the drawn block (the cursor rests on its last line), leaving the
# cursor at column 1 of what was the bar line.
function clear_progress(io::IO, p::MiniProgressBar)
    print(io, "\e[1G\e[2K", "\e[1A\e[2K"^(p.prev_lines - 1))
    p.prev_lines = 1
    return
end

function end_progress(io, p::MiniProgressBar)
    clear_progress(io, p)
    ansi_enablecursor = "\e[?25h"
    return print(io, ansi_enablecursor)
end

# Routes log records above a live progress bar: the block is erased, the
# record printed in its place (may be multi-line), and the block redrawn
# below. Without this, worker `@warn`s land on top of the bar and garble it.
struct ProgressLogger <: CoreLogging.AbstractLogger
    parent::CoreLogging.AbstractLogger
    io::IO
    bar::MiniProgressBar
end

CoreLogging.min_enabled_level(l::ProgressLogger) = CoreLogging.min_enabled_level(l.parent)
CoreLogging.shouldlog(l::ProgressLogger, args...) = CoreLogging.shouldlog(l.parent, args...)
CoreLogging.catch_exceptions(l::ProgressLogger) = CoreLogging.catch_exceptions(l.parent)
function CoreLogging.handle_message(l::ProgressLogger, args...; kwargs...)
    @lock l.io begin
        clear_progress(l.io, l.bar)
        CoreLogging.handle_message(l.parent, args...; kwargs...)
        show_progress(l.io, l.bar; force = true)
    end
    return nothing
end

end
