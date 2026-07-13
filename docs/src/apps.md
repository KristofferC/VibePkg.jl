# Apps

An *app* is a Julia package installed so that its entry point becomes an
executable on your `PATH` — you run it from the terminal like any other
program:

```
$ reverse some input string
emos tupni gnirts
```

Installing an app gives it a dedicated, isolated environment in the depot, so
apps never conflict with your projects or with each other, plus a small
executable *shim* in `~/.julia/bin` that starts Julia with the right
environment and main module.

!!! warning
    Apps are experimental — functionality and API may change.

## Creating a Julia app

An app is an ordinary package whose module defines an entry point with
`@main`, and whose `Project.toml` declares the executables in an `[apps]`
table:

```julia
module MyReverseApp

function (@main)(ARGS)
    for arg in ARGS
        print(stdout, reverse(arg), " ")
    end
    return
end

end # module
```

```toml
name = "MyReverseApp"
uuid = "..."
version = "0.1.0"

[apps]
reverse = {}
```

After `app add`, the command `reverse` is available in the terminal.

### Multiple apps per package

One package can provide several executables by putting the extra entry points
in submodules:

```toml
[apps]
main-app = {}
cli-app = { submodule = "CLI" }
```

`main-app` runs `julia -m MyMultiApp`; `cli-app` runs
`julia -m MyMultiApp.CLI`, i.e. the `@main` defined in the `CLI` submodule
(dotted names like `CLI.Nested` work too).

### Julia flags

Each app can declare the Julia flags it should run under:

```toml
[apps]
myapp = { julia_flags = ["--threads=4", "--optimize=2"] }
debug-app = { submodule = "Debug", julia_flags = ["--check-bounds=yes", "--optimize=0"] }
```

At run time, flags can be overridden per invocation: arguments before a `--`
separator go to Julia, the rest to the app.

```
$ myapp --threads=8 -- input.txt output.txt
```

The environment variable `JULIA_APPS_JULIA_CMD` overrides which `julia`
executable the shims use (by default, the one that installed the app).

## Installing apps

Apps are managed with the `app` REPL commands (or `VibePkg.Apps.*`):

```
(@v1.12) vpkg> app add Runic                                  # from a registry
(@v1.12) vpkg> app add Runic@1.5                              # specific version
(@v1.12) vpkg> app add https://github.com/fredrikekre/Runic.jl # from a repo
(@v1.12) vpkg> app add path/to/Package                        # from a local git repo
```

`app add` builds the app's private environment under
`~/.julia/environments/apps/<PkgName>`, resolves and precompiles it, and
writes the shims. For working on an app, `app develop` points the shims
directly at a source tree instead, so edits take effect on the next run
without reinstalling:

```
(@v1.12) vpkg> app develop path/to/Package
```

`app status` lists installed app packages and their executables, and `app rm`
removes a package with all its apps (or a single named app):

```
(@v1.12) vpkg> app status
[abc12345] MyReverseApp v0.1.0
  reverse

(@v1.12) vpkg> app rm MyReverseApp
```

!!! note
    VibePkg never modifies your shell configuration. If `~/.julia/bin` is not
    on your `PATH`, a warning reminds you to add it:

    ```
    export PATH="$HOME/.julia/bin:$PATH"
    ```
