# The vpkg> command language.
#
# Same architecture as Pkg's: the command table is *data*, every command
# bottoms out in exactly one API call, and `TEST_MODE[]` makes `do_cmd`
# return `(api, args, opts)` instead of executing — the introspection hook
# the whole REPL test technique builds on.
#
# This is the headless core: string → dispatch. The interactive extension
# (prompt, keymap) builds on it in ext/REPLExt.jl. Escape sequences inside
# quotes are intentionally *not* honored (Pkg parity: a backslash is a plain
# character so Windows paths lex correctly).

module REPLMode

using Base: UUID

using ..Errors: pkgerror
using ..Utils: stderr_f, unstableio, URL_SCHEME_RE, expanduser_path
using ..Configs: UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER,
    PRESERVE_NONE, PRESERVE_TIERED_INSTALLED, PRESERVE_TIERED
using ..Depots: depot_stack
import ..Environments
import ..Fetch
import ..Registries
import ..Stdlibs
import ..API
using ..API: PackageSpec

export pkgstr, do_cmd, TEST_MODE, completions_for

const TEST_MODE = Ref(false)

# Installed by the REPL extension. Keeping the headless parser independent of
# REPL lets `compat` retain its non-interactive API behavior when the stdlib is
# unavailable, while a real `vpkg>` session gets the interactive editor.
const INTERACTIVE_COMPAT_HOOK = Ref{Union{Nothing, Function}}(nothing)

function compat_repl(args...; io::IO = stderr_f(), kwargs...)
    hook = INTERACTIVE_COMPAT_HOOK[]
    if isempty(args) && isempty(kwargs) && hook !== nothing
        return hook(; io)
    end
    return API.compat(args...; io, kwargs...)
end

#################
# Command table #
#################

# `--preserve=<opt>` values (Pkg's `do_preserve` table)
const PRESERVE_VALUES = "installed, all, direct, semver, none, tiered_installed, or tiered"
function do_preserve(x::Union{Nothing, String})
    x === nothing && pkgerror("Option --preserve requires a value; expected $PRESERVE_VALUES")
    x == "installed" && return PRESERVE_ALL_INSTALLED
    x == "all" && return PRESERVE_ALL
    x == "direct" && return PRESERVE_DIRECT
    x == "semver" && return PRESERVE_SEMVER
    x == "none" && return PRESERVE_NONE
    x == "tiered_installed" && return PRESERVE_TIERED_INSTALLED
    x == "tiered" && return PRESERVE_TIERED
    pkgerror("Invalid --preserve value $(repr(x)); expected $PRESERVE_VALUES")
end

# How positional words are interpreted before reaching the API function.
#   :requests — package specs (name/@ver/#rev/=uuid/:subdir) → Vector{PackageRequest}
#   :strings  — one Vector{String} argument
#   :splat    — each positional word becomes its own String argument
#   :none     — no positional arguments allowed
struct CommandSpec
    canonical::String
    short::Union{Nothing, String}
    api::Function
    arg_kind::Symbol
    arg_count::UnitRange{Int}
    # option name => kwarg => value; a `nothing` value takes the raw `=value`
    # string, a Function value converts it (and may reject `nothing`)
    opts::Dict{String, Pair{Symbol, Any}}
    shorts::Dict{String, String}            # short option letter => option name
    help::String
end

# built on demand: the table is small, and this keeps it Revise-friendly
command_specs() = build_command_table()

function build_command_table()
    specs = Dict{String, CommandSpec}()
    function register!(canonical, short, api, arg_kind, arg_count, opts = Dict{String, Pair{Symbol, Any}}(); shorts = Dict{String, String}(), help = "")
        spec = CommandSpec(canonical, short, api, arg_kind, arg_count, opts, shorts, help)
        specs[canonical] = spec
        short === nothing || (specs[short] = spec)
        return
    end

    register!(
        "add", nothing, API.add, :requests, 1:typemax(Int),
        Dict{String, Pair{Symbol, Any}}(
            "preserve" => (:preserve => do_preserve),
            "weak" => (:target => :weakdeps), "extra" => (:target => :extras),
        );
        shorts = Dict("w" => "weak", "e" => "extra"),
        help = "add [--preserve=<opt>] [-w|--weak] [-e|--extra] pkg[=uuid] [@version] [#rev] | url [#rev] [:subdir] | path ...\n\nAdd packages to the project. Registered names may carry a version (`@0.5`), a uuid (`=uuid`), or a git revision (`#master`); urls and local paths are tracked as git sources, optionally at a repository subdirectory (`:sub/dir`). GitHub tree/commit/pull urls select the revision automatically. `--preserve` picks the resolve tier: installed|all|direct|semver|none|tiered_installed|tiered (default). `--weak`/`--extra` record the packages under [weakdeps]/[extras] instead, without installing anything."
    )
    register!(
        "develop", "dev", API.develop, :requests, 1:typemax(Int),
        Dict{String, Pair{Symbol, Any}}(
            "preserve" => (:preserve => do_preserve),
            "shared" => (:shared => true), "local" => (:shared => false),
        );
        help = "develop [--preserve=<opt>] [--shared|--local] pkg|path\n\nTrack a package by source path: a registered name is cloned into the dev dir (`--shared`, default) or into the project's `dev/` folder (`--local`); a path is used as-is. Changes to the source take effect immediately."
    )
    register!(
        "remove", "rm", API.rm, :strings, 0:typemax(Int),
        Dict(
            "manifest" => (:mode => :manifest), "project" => (:mode => :project),
            "all" => (:all_pkgs => true),
        );
        shorts = Dict("m" => "manifest", "p" => "project"),
        help = "rm [-p|--project] [-m|--manifest] pkg ...\nrm [-p|--project] [-m|--manifest] --all\n\nRemove packages. Project mode (default) removes direct dependencies; manifest mode removes packages and everything depending on them. `--all` removes all packages in scope."
    )
    register!(
        "update", "up", API.up, :strings, 0:typemax(Int),
        Dict{String, Pair{Symbol, Any}}(
            "major" => (:level => UPLEVEL_MAJOR), "minor" => (:level => UPLEVEL_MINOR),
            "patch" => (:level => UPLEVEL_PATCH), "fixed" => (:level => UPLEVEL_FIXED),
            "project" => (:mode => :project), "manifest" => (:mode => :manifest),
            "preserve" => (:preserve => do_preserve), "workspace" => (:workspace => true),
        );
        shorts = Dict("p" => "project", "m" => "manifest"),
        help = "up [-p|--project] [-m|--manifest] [--major|--minor|--patch|--fixed] [--preserve=<all|direct|none>] [--workspace] [pkg ...]\n\nUpgrade packages within the given level. With no arguments the whole environment updates (`--manifest`: seed every manifest package, `--workspace`: include workspace members); with names only those packages move while the rest holds at `--preserve`."
    )
    register!(
        "pin", nothing, API.pin, :requests, 0:typemax(Int),
        Dict("all" => (:all_pkgs => true), "workspace" => (:workspace => true));
        help = "pin pkg[@version] ...\npin [--workspace] --all\n\nPin packages at their current (or the given) version; pinned packages never move until freed. `--all` pins every package."
    )
    register!(
        "free", nothing, API.free, :strings, 0:typemax(Int),
        Dict("all" => (:all_pkgs => true), "workspace" => (:workspace => true));
        help = "free pkg ...\nfree [--workspace] --all\n\nUndo a pin, develop, or repo-tracking: return packages to registry tracking. `--all` frees everything freeable."
    )
    register!(
        "status", "st", API.status, :requests, 0:typemax(Int),
        Dict(
            "manifest" => (:mode => :manifest), "project" => (:mode => :project),
            "outdated" => (:outdated => true), "workspace" => (:workspace => true),
            "compat" => (:compat => true), "extensions" => (:extensions => true),
            "diff" => (:diff => true), "deprecated" => (:deprecated => true),
        );
        shorts = Dict(
            "m" => "manifest", "p" => "project", "o" => "outdated",
            "c" => "compat", "e" => "extensions", "d" => "diff",
        ),
        help = "status [-p|--project] [-m|--manifest] [-d|--diff] [-o|--outdated] [--deprecated] [-c|--compat] [-e|--extensions] [--workspace] [pkg ...]\n\nShow the environment (`--workspace`: every member's dependencies); with package names only matching lines show. `⌃` marks upgradable packages, `⌅` packages held back by compat."
    )
    register!("undo", nothing, API.undo, :none, 0:0; help = "undo\n\nRevert the environment to the previous state.")
    register!("redo", nothing, API.redo, :none, 0:0; help = "redo\n\nReapply an undone change.")
    register!(
        "instantiate", nothing, API.instantiate, :none, 0:0,
        Dict(
            "julia_version_strict" => (:julia_version_strict => true),
            "project" => (:manifest => false), "manifest" => (:manifest => true),
            "verbose" => (:verbose => true), "workspace" => (:workspace => true),
            "update_on_mismatch" => (:update_on_mismatch => true),
        );
        shorts = Dict("p" => "project", "m" => "manifest", "v" => "verbose", "u" => "update_on_mismatch"),
        help = "instantiate [-p|--project] [-m|--manifest] [-v|--verbose] [--workspace] [--julia_version_strict] [-u|--update_on_mismatch]\n\nMake the environment ready to use: download everything the manifest records. `--project` resolves from the project instead of using the manifest; `--verbose` shows build output; `--julia_version_strict` errors instead of warning on manifest version check failures; `--update_on_mismatch` falls back to `up` when the manifest does not match the project."
    )
    register!("resolve", nothing, API.resolve, :none, 0:0; help = "resolve\n\nReconcile the manifest with the project without moving installed versions. Never modifies Project.toml.")
    register!(
        "precompile", nothing, API.precompile, :strings, 0:typemax(Int),
        Dict(
            "strict" => (:strict => true), "timing" => (:timing => true),
            "workspace" => (:workspace => true),
        );
        help = "precompile [--strict] [--timing] [--workspace] [pkg ...]\n\nPrecompile the environment (all packages, or only the given ones and their dependencies). Errors only throw for direct dependencies unless `--strict`; `--timing` reports per-package compile time; `--workspace` covers all workspace members."
    )
    register!(
        "test", nothing, API.test, :strings, 0:typemax(Int),
        Dict("coverage" => (:coverage => true));
        help = "test [--coverage] [pkg ...]\n\nRun package tests in a sandbox (default: the active project). `--coverage` enables coverage statistics collection."
    )
    register!(
        "build", nothing, API.build, :strings, 0:typemax(Int),
        Dict("verbose" => (:verbose => true));
        shorts = Dict("v" => "verbose"),
        help = "build [-v|--verbose] [pkg ...]\n\nRun deps/build.jl of the given packages (dependencies first). `--verbose` shows build output instead of logging it."
    )
    register!(
        "gc", nothing, API.gc, :none, 0:0,
        Dict("verbose" => (:verbose => true), "all" => (:force => true));
        shorts = Dict("v" => "verbose"),
        help = "gc [-v|--verbose] [--all]\n\nDelete unreachable packages, artifacts, repo caches, and scratchspaces."
    )
    register!(
        "activate", nothing, API.activate, :splat, 0:1,
        Dict("temp" => (:temp => true), "shared" => (:shared => true));
        help = "activate [path]\nactivate --shared name\nactivate --temp\n\nSet the active project (no argument: the default environment). `--shared` activates the named environment from the depots' `environments` folders (creating it in the first depot if needed). `--temp` creates and activates a temporary environment removed when the julia process exits."
    )
    register!("generate", nothing, API.generate, :splat, 1:1; help = "generate path\n\nCreate a new package skeleton.")
    register!(
        "compat", nothing, compat_repl, :splat, 0:2,
        Dict("current" => (:current => true));
        help = "compat [pkg] [version]\n\nNo arguments in vpkg mode: interactively edit the [compat] table. One argument: remove the entry. Two: set it and re-check the environment. `--current` fills missing entries from resolved versions."
    )
    register!(
        "why", nothing, API.why, :strings, 1:1,
        Dict("workspace" => (:workspace => true));
        help = "why [--workspace] pkg\n\nShow the dependency paths leading to a package as a tree; `(*)` marks an already-printed sub-tree (`--workspace`: from any workspace member's dependencies)."
    )
    return specs
end

########
# Help #
########

function show_help(io::IO, cmd::Union{Nothing, String} = nothing)
    specs = command_specs()
    if cmd === nothing
        seen = Set{String}()
        printstyled(io, "  VibePkg commands:\n"; bold = true)
        for name in sort!(collect(keys(specs)))
            spec = specs[name]
            spec.canonical in seen && continue
            push!(seen, spec.canonical)
            summary = first(split(spec.help, '\n'))
            label = spec.short === nothing ? spec.canonical : "$(spec.canonical), $(spec.short)"
            println(io, "  ", rpad(label, 14), isempty(summary) ? "" : summary)
        end
        println(io, "  ", rpad("registry", 14), "registry add|remove|update|status")
        println(io, "  ", rpad("app", 14), "app add|develop|rm|update|status")
    else
        spec = get(specs, cmd, nothing)
        spec === nothing && pkgerror("Unknown command $(repr(cmd)). Type ? to list available commands")
        println(io, "  ", replace(spec.help, "\n" => "\n  "))
        if !isempty(spec.opts)
            println(io, "\n  options: ", join(sort!(["--" * k for k in keys(spec.opts)]), " "))
        end
    end
    return
end

#############
# Tokenizer #
#############

# A word plus whether it came quoted: quoted words are exempt from package
# micro-syntax extraction (Pkg's QString). A quote is always a word
# delimiter, so `"a b"#rev` lexes as a quoted `a b` plus a bare `#rev`.
struct Word
    raw::String
    isquoted::Bool
end

# Split a statement into words, honoring single/double quotes (no escapes,
# like Pkg's lexer). With `comma_break`, an unquoted `,` is also a word
# delimiter (the comma-sugar of `add A, B`, decided per line in `do_cmd`).
function tokenize_words(s::AbstractString; comma_break::Bool = false)
    words = Word[]
    buf = IOBuffer()
    quote_char = nothing
    quote_position = 0
    flush_word!(isquoted) = begin
        w = String(take!(buf))
        isempty(w) || push!(words, Word(w, isquoted))
        return
    end
    for (char_position, c) in enumerate(s)
        if quote_char !== nothing
            if c == quote_char
                quote_char = nothing
                flush_word!(true)
            else
                write(buf, c)
            end
        elseif c == '"' || c == '\''
            flush_word!(false)
            quote_char = c
            quote_position = char_position
        elseif isspace(c) || (comma_break && c == ',')
            flush_word!(false)
        else
            write(buf, c)
        end
    end
    quote_char === nothing || pkgerror("Unterminated quote beginning at character $quote_position")
    flush_word!(false)
    return words
end

# Comma-sugar is keyed off the *start of the whole input line* (Pkg parity):
# only `add`/`dev`/`develop`/`rm`/`remove`/`status`/`precompile` treat `,` as
# a separator, and the first command's choice applies to every `;`-chained
# statement (so `up A, B` still errors on the stray `A,`).
const COMMA_SUGAR_RE = r"^(add|dev|develop|rm|remove|status|precompile)\s"
uses_comma_sugar(input::AbstractString) = occursin(COMMA_SUGAR_RE, lstrip(input))

######################
# Package micro-syntax
######################

const UUID_RE = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

is_path_like(word) =
    occursin('/', word) || occursin('\\', word) || word in (".", "..") ||
    startswith(word, '~') || occursin(r"^[A-Za-z]:", word)

# Pkg's `looks_like_url`: every scheme the Git layer accepts (`http(s)://`,
# `git://`, `ssh://`, `file://` — Utils.URL_SCHEME_RE), anything with `.git`,
# and scp-style `user@host:path` where the host looks like a hostname or an
# IP — but not like a version number, so `Example@1.0:sub` stays name
# micro-syntax.
function looks_like_url(str::String)
    if occursin(URL_SCHEME_RE, str) || startswith(str, "git@") || occursin(".git", str)
        return true
    end
    at_pos = findfirst('@', str)
    at_pos === nothing && return false
    colon_pos = findnext(':', str, nextind(str, at_pos))
    colon_pos === nothing && return false
    host = str[nextind(str, at_pos):prevind(str, colon_pos)]
    (isempty(host) || occursin('/', host) || occursin(' ', host)) && return false
    if all(c -> isdigit(c) || c == '.', host)
        return count(==('.'), host) >= 3    # an IP (X.X.X.X), not a version
    end
    return true
end

looks_like_complete_url(str::String) =
    (occursin(URL_SCHEME_RE, str) || startswith(str, "git@")) &&
    (occursin('.', str) || occursin('/', str))

# `C:` at the start of a word is a Windows drive, not a subdir separator
is_windows_drive_colon(str::String, colon_pos::Int) =
    colon_pos == 2 && occursin(r"^[A-Za-z]:", str)

# The extractors return `(remaining, part-or-nothing)`.
function extract_subdir(input::String)      # rightmost `:` (names & paths)
    i = findlast(':', input)
    (i === nothing || is_windows_drive_colon(input, i)) && return input, nothing
    return input[1:prevind(input, i)], input[nextind(input, i):end]
end

function extract_revision(input::String)    # first `#` (names & paths)
    i = findfirst('#', input)
    i === nothing && return input, nothing
    return input[1:prevind(input, i)], input[nextind(input, i):end]
end

function extract_version(input::String)     # rightmost `@` (names only)
    i = findlast('@', input)
    i === nothing && return input, nothing
    return input[1:prevind(input, i)], input[nextind(input, i):end]
end

# Is the `:` at colon_pos part of the URL itself (scp-style host separator,
# `://`, `user:password@`, or a port) rather than a subdir separator?
function is_url_structure_colon(input::String, colon_pos::Int)
    after = input[nextind(input, colon_pos):end]
    at_pos = findfirst('@', input)
    if at_pos !== nothing && at_pos < colon_pos
        occursin('/', input[nextind(input, at_pos):prevind(input, colon_pos)]) || return true
    end
    startswith(after, "//") && return true
    if (i = findfirst('@', after)) !== nothing
        occursin('/', after[1:prevind(after, i)]) || return true
    end
    occursin(r"^\d+(/|$)", after) && return true
    return false
end

function extract_url_subdir(input::String)
    i = findlast(':', input)
    (i === nothing || is_url_structure_colon(input, i)) && return input, nothing
    before = input[1:prevind(input, i)]
    after = input[nextind(input, i):end]
    looks_like_base = occursin("://", before) || occursin(".git", before) || occursin('@', before)
    looks_like_sub = occursin('/', after) || (!occursin('@', after) && !occursin('#', after))
    return looks_like_base && looks_like_sub ? (before, after) : (input, nothing)
end

function extract_url_revision(input::String)    # first `#` after a complete url
    i = findfirst('#', input)
    i === nothing && return input, nothing
    before = input[1:prevind(input, i)]
    looks_like_complete_url(before) || return input, nothing
    return before, input[nextind(input, i):end]
end

# Micro-syntax token stream (Pkg's PackageToken): an identifier starts a
# package, modifier tokens attach to the one before them.
struct PkgId
    val::String
end
struct VerTok
    val::String
end
struct RevTok
    val::String
end
struct SubdirTok
    val::String
end
const PkgTok = Union{PkgId, VerTok, RevTok, SubdirTok}

# GitHub tree/commit/pull urls carry their rev in the path
function github_url_tokens(input::String)
    if (m = match(r"^https://github\.com/(.*?)/(.*?)/(?:tree|commit)/(.*?)$", input)) !== nothing
        return PkgTok[PkgId("https://github.com/$(m[1])/$(m[2])"), RevTok(String(m[3]::SubString{String}))]
    elseif (m = match(r"^https://github\.com/(.*?)/(.*?)/pull/(\d+)$", input)) !== nothing
        return PkgTok[PkgId("https://github.com/$(m[1])/$(m[2])"), RevTok("pull/$(m[3])/head")]
    end
    return nothing
end

function package_word_tokens(w::Word)
    w.isquoted && return PkgTok[PkgId(w.raw)]   # quoted words are literal
    word = w.raw
    # standalone modifier words (`add Example @0.5 #master :sub`)
    startswith(word, '#') && return PkgTok[RevTok(word[2:end])]
    startswith(word, '@') && return PkgTok[VerTok(word[2:end])]
    startswith(word, ':') && return PkgTok[SubdirTok(word[2:end])]
    gh = github_url_tokens(word)
    gh === nothing || return gh
    # `name=uuid` is a single identifier, never carrying specifiers
    if (i = findfirst('=', word)) !== nothing
        occursin(UUID_RE, strip(word[nextind(word, i):end])) && return PkgTok[PkgId(word)]
    end
    version = nothing
    if looks_like_url(word)     # urls take `#rev` and `:subdir`, never `@version`
        remaining, subdir = extract_url_subdir(word)
        remaining, rev = extract_url_revision(remaining)
    elseif is_path_like(word)
        remaining, subdir = extract_subdir(word)
        remaining, rev = extract_revision(remaining)
    else
        remaining, subdir = extract_subdir(word)
        remaining, version = extract_version(remaining)
        remaining, rev = extract_revision(remaining)
    end
    tokens = PkgTok[PkgId(remaining)]
    rev === nothing || push!(tokens, RevTok(rev))
    version === nothing || push!(tokens, VerTok(version))
    subdir === nothing || push!(tokens, SubdirTok(subdir))
    return tokens
end

# Base identifier → PackageSpec fields (Pkg's parse_package_identifier).
# Names parse permissively: invalid ones are rejected downstream by
# `validate_specs` with the pinned diagnostics.
function identifier_fields(word::String)
    looks_like_url(word) && return (; url = word)
    if is_path_like(word)
        # Path expansion throws a bare ArgumentError for unsupported `~user`
        # forms; surface it as a clean pkgerror instead.
        path = try
            expanduser_path(word)
        catch err
            err isa ArgumentError || rethrow()
            pkgerror("Could not expand path $(repr(word)): $(sprint(showerror, err))")
        end
        return (; path)
    end
    occursin(UUID_RE, word) && return (; uuid = UUID(word))
    name = word
    uuid = nothing
    if (i = findfirst('=', name)) !== nothing
        uuid_str = String(strip(name[nextind(name, i):end]))
        occursin(UUID_RE, uuid_str) || pkgerror("Malformed package token $(repr(word)): expected NAME=UUID with a valid UUID")
        uuid = UUID(uuid_str)
        name = String(strip(name[1:prevind(name, i)]))
    end
    # `add Example.jl` means `add Example`
    endswith(name, ".jl") && (name = chop(name; tail = 3))
    return (; name, uuid)
end

modifier_desc(t::VerTok) = "version specifier `@$(t.val)`"
modifier_desc(t::RevTok) = "revision specifier `#$(t.val)`"
modifier_desc(t::SubdirTok) = "subdir specifier `:$(t.val)`"

function fold_package_tokens(tokens::Vector{PkgTok})
    specs = PackageSpec[]
    i = firstindex(tokens)
    while i <= lastindex(tokens)
        tok = tokens[i]
        tok isa PkgId || pkgerror("Package name or UUID must precede $(modifier_desc(tok))")
        version = rev = subdir = nothing
        i += 1
        while i <= lastindex(tokens) && !((m = tokens[i]) isa PkgId)
            if m isa VerTok
                version === nothing || pkgerror("Package $(repr(tok.val)) has multiple version specifiers")
                version = m.val
            elseif m isa RevTok
                rev === nothing || pkgerror("Package $(repr(tok.val)) has multiple revision specifiers")
                rev = m.val
            else
                subdir === nothing || pkgerror("Package $(repr(tok.val)) has multiple subdirectory specifiers")
                subdir = m.val
            end
            i += 1
        end
        push!(specs, PackageSpec(; identifier_fields(tok.val)..., version, rev, subdir))
    end
    return specs
end

"""
    parse_package_word(word) -> PackageSpec

Parse one micro-syntax word: `Name`, `Name@version`, `Name#rev`,
`Name=UUID`, `Name:subdir`, bare UUIDs, urls and paths (`#rev`/`:subdir`
suffixes). Unit-test hook — the statement parser goes through
`package_word_tokens`/`fold_package_tokens` so standalone modifier words
can attach to the previous package.
"""
parse_package_word(word::String) =
    only(fold_package_tokens(package_word_tokens(Word(word, false))))

############
# Dispatch #
############

struct ParsedCommand
    api::Function
    args::Vector{Any}
    opts::Dict{Symbol, Any}
end

help_command(cmd::String...; io::IO = stderr_f()) = show_help(io, isempty(cmd) ? nothing : cmd[1])

function parse_statement(words::Vector{Word})
    isempty(words) && pkgerror("No command was provided; type ? to list available commands")
    cmdword = words[1].raw
    if cmdword == "?" || cmdword == "help" || startswith(cmdword, "?")
        cmd = if cmdword in ("?", "help")
            length(words) >= 2 ? words[2].raw : nothing
        else
            cmdword[2:end]      # `?add` without a space
        end
        return ParsedCommand(help_command, cmd === nothing ? Any[] : Any[cmd], Dict{Symbol, Any}())
    end
    if cmdword == "app"
        length(words) >= 2 || pkgerror("app requires a subcommand; expected add, develop, rm, update, or status")
        sub = words[2].raw
        rest = [w.raw for w in words[3:end]]
        Apps = getfield(parentmodule(API), :Apps)
        if sub in ("add",)
            length(rest) == 1 || pkgerror("app add expects exactly one package; usage: app add PACKAGE")
            return ParsedCommand(Apps.add, Any[rest[1]], Dict{Symbol, Any}())
        elseif sub in ("dev", "develop")
            length(rest) == 1 || pkgerror("app develop expects exactly one path; usage: app develop PATH")
            return ParsedCommand(Apps.develop, Any[rest[1]], Dict{Symbol, Any}())
        elseif sub in ("rm", "remove")
            length(rest) == 1 || pkgerror("app rm expects exactly one name; usage: app rm NAME")
            return ParsedCommand(Apps.rm, Any[rest[1]], Dict{Symbol, Any}())
        elseif sub in ("up", "update")
            length(rest) <= 1 || pkgerror("app update expects at most one name; usage: app update [NAME]")
            return ParsedCommand(Apps.update, Any[rest...], Dict{Symbol, Any}())
        elseif sub in ("st", "status")
            return ParsedCommand(Apps.status, Any[rest...], Dict{Symbol, Any}())
        else
            pkgerror("Unknown app subcommand $(repr(sub)); expected add, develop, rm, update, or status")
        end
    end
    if cmdword == "package"
        length(words) >= 2 || pkgerror(
            "package requires a subcommand; type ? to list available package commands"
        )
        # `package` is the explicit spelling of the ordinary command
        # namespace (`package add X` == `add X`). Re-enter the same parser so
        # options, aliases, and argument validation cannot drift.
        return parse_statement(words[2:end])
    end
    if cmdword == "registry"
        length(words) >= 2 || pkgerror("registry requires a subcommand; expected add, remove, update, or status")
        sub = words[2].raw
        rest = [w.raw for w in words[3:end]]
        fn = if sub in ("add",)
            VibePkgRegistryAdd
        elseif sub in ("rm", "remove")
            isempty(rest) && pkgerror("registry rm requires at least one registry; usage: registry rm NAME|UUID")
            VibePkgRegistryRm
        elseif sub in ("up", "update")
            VibePkgRegistryUpdate
        elseif sub in ("st", "status")
            isempty(rest) || pkgerror("registry status accepts no arguments; usage: registry status")
            VibePkgRegistryStatus
        else
            pkgerror("Unknown registry subcommand $(repr(sub)); expected add, remove, update, or status")
        end
        return ParsedCommand(fn, Any[rest...], Dict{Symbol, Any}())
    end
    spec = get(command_specs(), cmdword, nothing)
    spec === nothing && pkgerror("Unknown command $(repr(cmdword)). Type ? to list available commands")
    opts = Dict{Symbol, Any}()
    option_for_kwarg = Dict{Symbol, String}()
    positional = Word[]
    for w in words[2:end]
        word = w.raw
        if startswith(word, "--")
            body = word[3:end]
            key, val = if (i = findfirst('=', body)) !== nothing
                body[1:(i - 1)], body[(i + 1):end]
            else
                body, nothing
            end
            optspec = get(spec.opts, key, nothing)
            optspec === nothing && pkgerror(
                "Invalid option --$key for command $(spec.canonical); valid options are " *
                    (isempty(spec.opts) ? "none" : join(sort!(collect("--" * k for k in keys(spec.opts))), ", "))
            )
            kwarg, fixed_value = optspec
            if haskey(option_for_kwarg, kwarg)
                previous = option_for_kwarg[kwarg]
                pkgerror("Conflicting options $previous and --$key for command $(spec.canonical)")
            end
            option_for_kwarg[kwarg] = "--$key"
            opts[kwarg] = if fixed_value isa Function
                fixed_value(val)
            elseif fixed_value === nothing
                val
            else
                val === nothing || pkgerror("Option --$key does not accept a value")
                fixed_value
            end
        elseif startswith(word, "-") && length(word) == 2
            long = get(spec.shorts, word[2:end], nothing)
            long === nothing && pkgerror("Invalid option $word for command $(spec.canonical); type ?$(spec.canonical) for help")
            kwarg, fixed_value = spec.opts[long]
            if haskey(option_for_kwarg, kwarg)
                previous = option_for_kwarg[kwarg]
                pkgerror("Conflicting options $previous and $word for command $(spec.canonical)")
            end
            option_for_kwarg[kwarg] = word
            opts[kwarg] = fixed_value
        else
            push!(positional, w)
        end
    end
    length(positional) in spec.arg_count ||
        pkgerror("Wrong number of arguments for $(spec.canonical); usage: $(first(split(spec.help, '\n')))")

    args = if spec.arg_kind === :requests
        tokens = PkgTok[]
        for w in positional
            append!(tokens, package_word_tokens(w))
        end
        specs = fold_package_tokens(tokens)
        # A bare identifier remains a package name even when an exactly
        # case-matching directory exists in the cwd. Point the user at the
        # explicit `./Name` spelling without silently changing its meaning.
        if spec.canonical in ("add", "develop")
            for pkg in specs
                if pkg.name !== nothing && pkg.uuid === nothing &&
                        pkg.version === nothing && pkg.rev === nothing &&
                        pkg.subdir === nothing
                    local_path = abspath(pkg.name)
                    isdir(local_path) && @info(
                        "Use `./$(pkg.name)` to add or develop the local directory at `$local_path`."
                    )
                end
            end
        end
        if spec.canonical ∉ ("add", "develop")
            for s in specs
                (s.url === nothing && s.path === nothing) ||
                    pkgerror("URLs and paths are supported only by add and develop; command $(spec.canonical) received $(repr(something(s.url, s.path)))")
            end
        end
        Any[specs]
    elseif spec.arg_kind === :splat
        vals = String[w.raw for w in positional]
        if spec.canonical in ("activate", "generate")
            for i in eachindex(vals)
                vals[i] = try
                    expanduser_path(vals[i])
                catch err
                    err isa ArgumentError || rethrow()
                    pkgerror("Could not expand path $(repr(vals[i])): $(sprint(showerror, err))")
                end
            end
        end
        Any[vals...]
    elseif spec.arg_kind === :strings
        isempty(positional) ? Any[] : Any[String[w.raw for w in positional]]
    else
        Any[]
    end
    return ParsedCommand(spec.api, args, opts)
end

# registry subcommand shims (bound late to avoid a load-order cycle)
VibePkgRegistryAdd(args::String...; io = stderr_f()) = Base.invokelatest(getfield(parentmodule(API), :Registry).add, args...; io)
VibePkgRegistryRm(args::String...; io = stderr_f()) = Base.invokelatest(getfield(parentmodule(API), :Registry).rm, args...; io)
VibePkgRegistryUpdate(args::String...; io = stderr_f()) = Base.invokelatest(getfield(parentmodule(API), :Registry).update, args...; io)
VibePkgRegistryStatus(; io = stderr_f()) = Base.invokelatest(getfield(parentmodule(API), :Registry).status; io)

"""
    do_cmd(input; io) -> nothing (or Vector when TEST_MODE)

Execute a vpkg> command string: statements split on `;`, each dispatched to
exactly one API call. With `TEST_MODE[] = true`, returns the would-be calls
as `(api, args, opts)` tuples instead of executing.
"""
function execute_commands(parsed_commands; io::IO = stderr_f())
    # Funnel every stream (REPL TTY, pipe, test buffer) through the one
    # IOContext{IO} wrapper the precompile workload compiles against, so a
    # real session's first command runs precompiled code instead of
    # re-inferring the whole display path for its concrete stream type.
    io = io isa IOContext{IO} ? io : unstableio(io)
    captured = Any[]
    for parsed in parsed_commands
        if TEST_MODE[]
            push!(captured, (parsed.api, parsed.args, parsed.opts))
        else
            opts = Dict{Symbol, Any}(parsed.opts)
            opts[:io] = io
            # vpkg> semantics differ from API calls in places (`add` prefers
            # already-loaded versions); the API checks this scope
            Base.ScopedValues.with(API.IN_REPL_MODE => true) do
                parsed.api(parsed.args...; opts...)
            end
        end
    end
    return TEST_MODE[] ? captured : nothing
end

# Split an input line into `;`-separated statements, honoring the same
# single/double quoting as `tokenize_words` (no escapes), so a quoted
# argument such as `activate "dir;name"` stays inside one statement. An
# unterminated quote keeps the rest of the line in one statement and is
# rejected by `tokenize_words`.
function split_statements(input::AbstractString)
    statements = String[]
    buf = IOBuffer()
    quote_char = nothing
    for c in input
        if quote_char !== nothing
            write(buf, c)
            c == quote_char && (quote_char = nothing)
        elseif c == '"' || c == '\''
            write(buf, c)
            quote_char = c
        elseif c == ';' || c == '\n' || c == '\r'
            push!(statements, String(take!(buf)))
        else
            write(buf, c)
        end
    end
    push!(statements, String(take!(buf)))
    return statements
end

function do_cmd(input::AbstractString; io::IO = stderr_f())
    # Pasting a command copied with the Julia-mode transition key is benign
    # inside package mode: strip one accidental leading `]`. A bare bracket is
    # therefore a no-op, matching Pkg's REPL behavior.
    input = lstrip(input)
    if startswith(input, ']')
        @warn "Removing leading `]`, which should only be used once to switch to pkg> mode"
        input = lstrip(input[nextind(input, firstindex(input)):end])
    end
    parsed_commands = ParsedCommand[]
    comma_break = uses_comma_sugar(input)
    for statement in split_statements(input)
        statement = strip(statement)
        isempty(statement) && continue
        push!(parsed_commands, parse_statement(tokenize_words(statement; comma_break)))
    end
    return execute_commands(parsed_commands; io)
end

"""
    do_cmd(args::AbstractVector{<:AbstractString}; io) -> nothing (or Vector when TEST_MODE)

Execute one command supplied as an argument vector. Unlike the string form,
argument boundaries have already been established by the shell, so whitespace
and semicolons inside an argument remain literal. This is the command-line app
entry point used by `vpkg`.
"""
function do_cmd(args::AbstractVector{<:AbstractString}; io::IO = stderr_f())
    words = Word[Word(String(arg), false) for arg in args]
    return execute_commands((parse_statement(words),); io)
end

pkgstr(str::AbstractString; io::IO = stderr_f()) = do_cmd(str; io)

###############
# Completions #
###############

function reachable_registries()
    return Registries.reachable_registries(
        depot_stack(); read_from_tarball = Fetch.pkg_server() !== nothing
    )
end

const REGISTERED_PACKAGE_NAMES = Ref{Union{Nothing, Vector{String}}}(nothing)
const DEPRECATED_PACKAGE_NAMES = Ref{Union{Nothing, Set{String}}}(nothing)

function reset_completion_cache!()
    REGISTERED_PACKAGE_NAMES[] = nothing
    DEPRECATED_PACKAGE_NAMES[] = nothing
    return
end

function registered_package_names()
    # callers get a copy so they cannot mutate the cache through it
    cached = REGISTERED_PACKAGE_NAMES[]
    cached === nothing || return copy(cached)
    names = String[]
    for registry in reachable_registries(), (_, package) in Registries.registry_pkgs(registry)
        info = Registries.registry_info(registry, package)
        compatible = any(keys(info.version_info)) do version
            Registries.isyanked(info, version) && return false
            julia_compat = Registries.query_compat_for_version(
                info, version, Registries.JULIA_UUID,
            )
            return julia_compat === nothing || VERSION in julia_compat
        end
        compatible && push!(names, package.name)
    end
    sort!(unique!(names))
    REGISTERED_PACKAGE_NAMES[] = names
    return copy(names)
end

# a name counts as deprecated when it is registered and every registered
# package carrying it is deprecated; computed in one registry sweep and
# cached — the per-candidate registry walk made every completion re-discover
# registries and reload package metadata
function deprecated_package_names()
    cached = DEPRECATED_PACKAGE_NAMES[]
    cached === nothing || return cached
    deprecated = Set{String}()
    live = Set{String}()
    for registry in reachable_registries(), (_, package) in Registries.registry_pkgs(registry)
        info = Registries.registry_info(registry, package)
        push!(Registries.isdeprecated(info) ? deprecated : live, package.name)
    end
    setdiff!(deprecated, live)
    DEPRECATED_PACKAGE_NAMES[] = deprecated
    return deprecated
end

is_deprecated_package_name(name::String) = name in deprecated_package_names()

function environment_dependency_names()
    env = Environments.load_environment(; depots = depot_stack())
    return sort!(collect(keys(env.project.deps)))
end

stdlib_names() = sort!([info.name for info in values(Stdlibs.stdlib_infos())])

function canonical_command_names()
    names = String[spec.canonical for spec in values(command_specs())]
    append!(names, ("registry", "app"))
    return sort!(unique!(names))
end

function specified_package_names(words::Vector{String})
    names = Set{String}()
    for word in words[2:end]
        startswith(word, '-') && continue
        name = first(split(word, ['@', '#', '=', ':']; limit = 2))
        isempty(name) || push!(names, name)
    end
    return names
end

function directory_completions(word::String; trailing_separator::Bool)
    # Keep the spelling the user typed (including `./` and `~/`) in the
    # replacement candidate while resolving the directory against the
    # filesystem. Only directories are candidates: add/develop accept package
    # roots, not arbitrary files.
    if word == "~"
        return [joinpath(homedir(), "")]
    end
    separator = findlast(c -> c == '/' || c == '\\', word)
    typed_dir = separator === nothing ? "" : word[firstindex(word):separator]
    prefix = separator === nothing ? word : word[nextind(word, separator):end]
    disk_dir = expanduser_path(isempty(typed_dir) ? "." : typed_dir)
    isdir(disk_dir) || return String[]
    candidates = String[]
    for entry in readdir(disk_dir)
        startswith(entry, prefix) || continue
        isdir(joinpath(disk_dir, entry)) || continue
        candidate = isempty(typed_dir) ? entry : typed_dir * entry
        trailing_separator && (candidate = joinpath(candidate, ""))
        push!(candidates, candidate)
    end
    return candidates
end

# registry add / remove / update invalidates the caches automatically,
# without every frontend having to remember reset_completion_cache!
push!(Registries.REGISTRY_CHANGE_HOOKS, reset_completion_cache!)

"""
    completions_for(partial) -> (candidates, word)

Completion candidates for a partial vpkg> input and the word being
completed: command names at the start, `--options` and package names after
a command. Never throws.
"""
function completions_for(partial::AbstractString)
    word = String(match(r"[^\s]*$", partial).match)
    before = strip(partial[1:(end - length(word))])
    words = isempty(before) ? String[] : String.(split(before))
    specs = command_specs()
    cands = try
        if isempty(words) && startswith(word, "?")
            prefix = word[nextind(word, firstindex(word)):end]
            ["?" * name for name in canonical_command_names() if startswith(name, prefix)]
        elseif isempty(words)
            sort!(unique!(vcat(collect(keys(specs)), ["registry", "app", "help"])))
        elseif words[1] in ("?", "help")
            canonical_command_names()
        elseif words[1] == "registry"
            ["add", "remove", "status", "update"]
        elseif words[1] == "app"
            ["add", "develop", "rm", "status", "update"]
        elseif startswith(word, "--")
            spec = get(specs, words[1], nothing)
            spec === nothing ? String[] : sort!(["--" * k for k in keys(spec.opts)])
        else
            spec = get(specs, words[1], nothing)
            if spec === nothing
                String[]
            elseif spec.canonical == "compat"
                # Compat's second position is still package-name completion,
                # not a version-string completion (#3562). Re-offering the
                # selected name is intentional; a following version prefix
                # naturally filters the name list to empty.
                environment_dependency_names()
            elseif spec.canonical in ("remove", "update", "pin", "free", "why", "build", "test")
                specified = specified_package_names(words)
                filter(name -> name ∉ specified, environment_dependency_names())
            elseif spec.canonical in ("add", "develop")
                paths = directory_completions(word; trailing_separator = true)
                names = vcat(registered_package_names(), stdlib_names())
                specified = specified_package_names(words)
                filter!(name -> name ∉ specified, names)
                filter!(name -> !startswith(name, word) || !is_deprecated_package_name(name), names)
                append!(names, paths)
                names
            elseif spec.canonical == "activate"
                directory_completions(word; trailing_separator = false)
            else
                String[]
            end
        end
    catch
        String[]
    end
    return sort!(filter(c -> startswith(c, word), cands)), word
end

"""
    install_repl!(; key = ']')

Install the interactive `pkg>` mode into the running REPL. Provided by the
REPL extension — load the REPL stdlib first (a MethodError here means it
isn't). Explicit opt-in so VibePkg can coexist with Pkg's own mode during
development.
"""
function install_repl! end

end # module
