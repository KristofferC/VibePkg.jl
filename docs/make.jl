using Documenter
using VibePkg

makedocs(
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
    modules = [VibePkg],
    sitename = "VibePkg.jl",
    warnonly = [:missing_docs, :cross_references],
    pages = [
        "index.md",
        "getting-started.md",
        "managing-packages.md",
        "environments.md",
        "creating-packages.md",
        "apps.md",
        "compatibility.md",
        "registries.md",
        "artifacts.md",
        "glossary.md",
        "toml-files.md",
        "repl.md",
        "api.md",
        "protocol.md",
        "depots.md",
        "environment-variables.md",
        "Developer Documentation" => [
            "devdocs/architecture.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/KristofferC/VibePkg.jl.git",
)
