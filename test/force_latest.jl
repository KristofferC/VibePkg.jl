# End-to-end `Pkg.test(force_latest_compatible_version=…)` — ported from Pkg.jl
# (test/force_latest_compatible_version.jl). Pkg uses real registered packages;
# VibePkg is hermetic, so we build a local "SomePkg" whose 0.1.0 is installable
# (a git repo) while its higher versions declare an unsatisfiable dependency
# (Example = "99"), so forcing the latest compatible version makes the sandbox
# resolve fail exactly like the reference fixtures.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using Base: UUID, SHA1
import LibGit2
using VibePkg
using VibePkg.Depots: depot_stack
using VibePkg.Resolve: ResolverError

const SOME_UUID = "50e11ece-0000-0000-0000-000000000001"
const EX_UUID_STR = "7876af07-990d-54b4-ab0e-23690620f79a"
const TEST_UUID_STR = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
const UNSATISFIABLE_REQUIREMENTS = "Unsatisfiable requirements detected for package"

function test_unsatisfiable(f::Function)
    err = try
        f()
        nothing
    catch err
        err
    end
    @test err isa ResolverError
    msg = err isa Exception ? sprint(showerror, err) : ""
    @test occursin(UNSATISFIABLE_REQUIREMENTS, msg)
    return nothing
end

git_tree_hash(repo, rev) = LibGit2.with(LibGit2.GitRepo(repo)) do r
    LibGit2.with(LibGit2.GitObject(r, rev)) do o
        LibGit2.with(LibGit2.peel(LibGit2.GitTree, o)) do t
            SHA1(string(LibGit2.GitHash(t)))
        end
    end
end

# a depot holding a registry whose SomePkg has an installable 0.1.0 (from a
# local git repo) and unsatisfiable 0.1.5 / 0.2.0 (they require Example = "99").
function setup_flc(dir)
    depot = mkpath(joinpath(dir, "depot"))
    some = joinpath(dir, "SomePkg")
    mkpath(joinpath(some, "src"))
    write(joinpath(some, "Project.toml"), "name = \"SomePkg\"\nuuid = \"$SOME_UUID\"\nversion = \"0.1.0\"\n")
    write(joinpath(some, "src", "SomePkg.jl"), "module SomePkg\nend\n")
    repo = LibGit2.init(some)
    LibGit2.add!(repo, ".")
    sig = LibGit2.Signature("tester", "t@example.com")
    LibGit2.commit(repo, "v0.1.0"; author = sig, committer = sig)
    LibGit2.close(repo)
    h0 = string(git_tree_hash(some, "HEAD"))

    reg = mkpath(joinpath(depot, "registries", "FLC"))
    sdir = mkpath(joinpath(reg, "S", "SomePkg"))
    edir = mkpath(joinpath(reg, "E", "Example"))
    write(
        joinpath(reg, "Registry.toml"), """
        name = "FLC"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "https://example.com/FLC.git"

        [packages]
        $SOME_UUID = { name = "SomePkg", path = "S/SomePkg" }
        $EX_UUID_STR = { name = "Example", path = "E/Example" }
        """
    )
    # forward slashes: a raw Windows path would put invalid `\U`-style escapes
    # in the TOML string
    some_url = replace(some, '\\' => '/')
    write(joinpath(sdir, "Package.toml"), "name = \"SomePkg\"\nuuid = \"$SOME_UUID\"\nrepo = \"$some_url\"\n")
    write(
        joinpath(sdir, "Versions.toml"), """
        ["0.1.0"]
        git-tree-sha1 = "$h0"

        ["0.1.5"]
        git-tree-sha1 = "$("a"^40)"

        ["0.2.0"]
        git-tree-sha1 = "$("b"^40)"
        """
    )
    # the higher versions pull in an impossible Example version
    write(joinpath(sdir, "Deps.toml"), "[\"0.1.5-0.2\"]\nExample = \"$EX_UUID_STR\"\n")
    write(joinpath(sdir, "Compat.toml"), "[\"0.1.5-0.2\"]\nExample = \"99\"\n")
    write(joinpath(edir, "Package.toml"), "name = \"Example\"\nuuid = \"$EX_UUID_STR\"\nrepo = \"https://example.com/Example.jl.git\"\n")
    write(joinpath(edir, "Versions.toml"), "[\"0.5.0\"]\ngit-tree-sha1 = \"$("1"^40)\"\n")
    return depot
end

# a path test package depending on SomePkg with the given compat and a trivial
# test target that loads it.
function make_testpkg(dir, name, somecompat::Union{Nothing, String})
    pkg = joinpath(dir, name)
    mkpath(joinpath(pkg, "src"))
    mkpath(joinpath(pkg, "test"))
    compat_block = somecompat === nothing ? "" : """
        [compat]
        SomePkg = "$somecompat"
        """
    write(
        joinpath(pkg, "Project.toml"), """
        name = "$name"
        uuid = "abcabcab-0000-0000-0000-0000000000$(lpad(hash(name) % 100, 2, '0'))"
        version = "0.1.0"

        [deps]
        SomePkg = "$SOME_UUID"

        $compat_block

        [extras]
        Test = "$TEST_UUID_STR"

        [targets]
        test = ["Test"]
        """
    )
    write(joinpath(pkg, "src", "$name.jl"), "module $name\nimport SomePkg\nend\n")
    write(joinpath(pkg, "test", "runtests.jl"), "using $name, Test\n@test true\n")
    return pkg
end

# run Pkg.test with `pkg` as the active project against the FLC depot. The test
# sandbox is a subprocess that reads JULIA_DEPOT_PATH from the environment, so
# both Base.DEPOT_PATH and the env var must point at the FLC depot (plus the
# bundled stdlib depots, for Test).
function run_flc_test(depot, pkg; kwargs...)
    old = Base.ACTIVE_PROJECT[]
    olddp = copy(Base.DEPOT_PATH)
    stack = [depot; Base.append_bundled_depot_path!(String[])]
    sep = Sys.iswindows() ? ';' : ':'
    try
        Base.ACTIVE_PROJECT[] = joinpath(pkg, "Project.toml")
        copy!(Base.DEPOT_PATH, stack)
        return withenv("JULIA_DEPOT_PATH" => join(stack, sep)) do
            VibePkg.test(; io = devnull, kwargs...)
        end
    finally
        Base.ACTIVE_PROJECT[] = old
        copy!(Base.DEPOT_PATH, olddp)
    end
end

@testset "force_latest_compatible_version end-to-end" begin
    # OldOnly1: `SomePkg = "=0.1.0"` — only one version, so forcing latest is a
    # no-op and every combination succeeds (the test runs and returns nothing).
    @testset "OldOnly1 (=0.1.0): always succeeds" begin
        mktempdir() do dir
            depot = setup_flc(dir)
            pkg = make_testpkg(dir, "OldOnly1", "=0.1.0")
            for flc in (false, true)
                @test run_flc_test(
                    depot, pkg;
                    force_latest_compatible_version = flc,
                ) === nothing
            end
            for flc in (false, true), allow_earlier in (false, true)
                @test run_flc_test(
                    depot, pkg;
                    force_latest_compatible_version = flc,
                    allow_earlier_backwards_compatible_versions = allow_earlier,
                ) === nothing
            end
        end
    end

    # OldOnly2: `SomePkg = "0.1"` — default resolves to the usable 0.1.0, but
    # forcing the latest 0.1.x (0.1.5, which is unsatisfiable) throws unless
    # earlier backwards-compatible versions are allowed.
    @testset "OldOnly2 (0.1): forcing the newest 0.1.x is unsatisfiable" begin
        mktempdir() do dir
            depot = setup_flc(dir)
            pkg = make_testpkg(dir, "OldOnly2", "0.1")
            for flc in (false, true)
                @test run_flc_test(
                    depot, pkg;
                    force_latest_compatible_version = flc,
                ) === nothing
            end
            for allow_earlier in (false, true), flc in (false, true)
                if flc && !allow_earlier
                    test_unsatisfiable() do
                        run_flc_test(
                            depot, pkg;
                            force_latest_compatible_version = flc,
                            allow_earlier_backwards_compatible_versions = allow_earlier,
                        )
                    end
                else
                    @test run_flc_test(
                        depot, pkg;
                        force_latest_compatible_version = flc,
                        allow_earlier_backwards_compatible_versions = allow_earlier,
                    ) === nothing
                end
            end
        end
    end

    # BothOldAndNew: `SomePkg = "0.1, 0.2"` — default resolves to 0.1.0, but
    # forcing the latest (0.2.0, unsatisfiable) throws for any allow_earlier.
    @testset "BothOldAndNew (0.1, 0.2): forcing the newest throws" begin
        mktempdir() do dir
            depot = setup_flc(dir)
            pkg = make_testpkg(dir, "BothOldAndNew", "0.1, 0.2")
            for flc in (false, true)
                if flc
                    test_unsatisfiable() do
                        run_flc_test(
                            depot, pkg;
                            force_latest_compatible_version = flc,
                        )
                    end
                else
                    @test run_flc_test(
                        depot, pkg;
                        force_latest_compatible_version = flc,
                    ) === nothing
                end
            end
            for allow_earlier in (false, true), flc in (false, true)
                if flc
                    test_unsatisfiable() do
                        run_flc_test(
                            depot, pkg;
                            force_latest_compatible_version = flc,
                            allow_earlier_backwards_compatible_versions = allow_earlier,
                        )
                    end
                else
                    @test run_flc_test(
                        depot, pkg;
                        force_latest_compatible_version = flc,
                        allow_earlier_backwards_compatible_versions = allow_earlier,
                    ) === nothing
                end
            end
        end
    end

    # NewOnly: `SomePkg = "0.2"` — the only allowed version (0.2.0) is
    # unsatisfiable, so every combination throws.
    @testset "NewOnly (0.2): always unsatisfiable" begin
        mktempdir() do dir
            depot = setup_flc(dir)
            pkg = make_testpkg(dir, "NewOnly", "0.2")
            for flc in (false, true)
                test_unsatisfiable() do
                    run_flc_test(
                        depot, pkg;
                        force_latest_compatible_version = flc,
                    )
                end
            end
            for flc in (false, true), allow_earlier in (false, true)
                test_unsatisfiable() do
                    run_flc_test(
                        depot, pkg;
                        force_latest_compatible_version = flc,
                        allow_earlier_backwards_compatible_versions = allow_earlier,
                    )
                end
            end
        end
    end
end

# A registered direct dependency without [compat] is unbounded. Forcing latest
# remains successful, but warns so package authors know the test is not
# constrained; force_latest=false stays silent. This ports upstream's
# DirectDepWithoutCompatEntry matrix without a pinned General checkout.
@testset "DirectDepWithoutCompatEntry warns only when forcing latest" begin
    mktempdir() do dir
        depot = setup_flc(dir)
        pkg = make_testpkg(dir, "DirectDepWithoutCompatEntry", nothing)

        @test_logs min_level = Base.CoreLogging.Warn begin
            @test run_flc_test(
                depot, pkg; force_latest_compatible_version = false,
            ) === nothing
        end
        for allow_earlier in (nothing, false, true)
            result = Ref{Any}()
            kwargs = allow_earlier === nothing ?
                (; force_latest_compatible_version = true) :
                (;
                    force_latest_compatible_version = true,
                    allow_earlier_backwards_compatible_versions = allow_earlier,
                )
            @test_logs (:warn, r"Dependency does not have a \[compat\] entry") match_mode = :any begin
                result[] = run_flc_test(depot, pkg; kwargs...)
            end
            @test result[] === nothing
        end
    end
end
