using Aqua
using VibePkg

# Full Aqua quality suite. The 10 pure-stdlib dependencies (Artifacts, Dates,
# …) are pinned by the `julia` compat bound and carry no independent versions,
# so they're excluded from the [compat] completeness check; every other
# dependency is still verified.
Aqua.test_all(
    VibePkg;
    deps_compat = (
        ignore = [
            :Artifacts, :Dates, :Downloads, :FileWatching, :LibGit2,
            :Printf, :Random, :SHA, :TOML, :UUIDs,
        ],
    ),
)
