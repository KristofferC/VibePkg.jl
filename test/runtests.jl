using VibePkg
using Testosterone: set_history_file, history_file, find_tests, runtests

# HistoricalStdlibVersions provides the cross-julia-version stdlib tables that
# test/historical_stdlib_version.jl bridges into VibePkg.Stdlibs. It (and its
# Pkg dep) live in the user depot, so — like REPL below — it must be loaded on
# the loose boot stack, before ensure!()/isolate!() drops the user depot. Its
# auto-register writes into Pkg.Types (unused here), so turn it off.
ENV["HISTORICAL_STDLIB_VERSIONS_AUTO_REGISTER"] = "false"
using HistoricalStdlibVersions

# Test duration history lives in a scratch space resolved against the depot
# stack at load/save time; pin it to the real depot now, before ensure!()
# swaps in the per-run temp depot, or every run starts unscheduled.
set_history_file(history_file(VibePkg))

# All network-shaped tests go through a local package server over generated
# fixtures; ensure!() also points http(s)_proxy at a dead port so that any
# stray real-internet request fails loudly. The server is started once here
# and shared with worker processes via VIBEPKG_TEST_FIXTURES. It also
# installs the strict test depot stack (a per-run temp depot plus the julia
# install's bundled depots — never ~/.julia). See test/local_pkg_server.jl.
include("local_pkg_server.jl")
LocalPkgServer.ensure!()

# every test file is standalone; these are support files, not tests
const NOT_TESTS = ("explicit_imports", "jet", "aqua", "local_pkg_server", "testhelpers", "resolve_utils", "NastyGenerator")

testsuite = find_tests(@__DIR__)
filter!(tc -> tc.name ∉ NOT_TESTS, testsuite)

# Workers boot on the loose stack (test depot first, then the defaults) so
# VibePkg's dependency sources — which live in the user depot — resolve
# while loading; each test file's prelude re-tightens to the strict stack
# via isolate!() inside the worker. REPL loads at boot too: it triggers the
# REPLExt precompile, which must happen while the loose stack is still in
# place — isolate!() is process-wide, so a later `using REPL` inside a
# worker that already ran an isolated test file would precompile against
# the strict stack and fail to find VibePkg's dependency sources.
# HistoricalStdlibVersions loads at boot for the same reason (see above).
ENV["JULIA_DEPOT_PATH"] = LocalPkgServer.worker_depot_path()
runtests(VibePkg, ARGS; testsuite, init_worker_code = :(using VibePkg, REPL, HistoricalStdlibVersions))
