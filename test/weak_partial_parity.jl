# Public, hermetic ports of the remaining extensions/weakdeps and nested
# preferences integration cases from Pkg's extensions.jl and sandbox.jl.
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()
LocalPkgServer.ensure!()

using Test
using Base: UUID
import TOML
using VibePkg

const WP_TRIGGER_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000001")
const WP_HOST_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000002")
const WP_WRAPPER_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000003")
const WP_INCOMPAT_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000004")
const WP_GHOST_HOST_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000005")
const WP_GHOST_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000006")
const WP_NESTED_DEP_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000007")
const WP_NESTED_ROOT_UUID = UUID("c101d2a0-73f1-4e1f-9011-000000000008")
const WP_EXAMPLE_UUID = UUID(LocalPkgServer.EXAMPLE_UUID)

function wp_with_active_env(f::Function)
    return mktempdir() do root
        # macOS exposes temporary directories through /var -> /private/var.
        # Coverage selectors compare source paths, so keep the fixture's
        # spelling canonical from the beginning.
        root = realpath(root)
        envdir = mkpath(joinpath(root, "env"))
        old_project = Base.ACTIVE_PROJECT[]
        try
            VibePkg.activate(envdir; io = devnull)
            return f(root, envdir)
        finally
            Base.ACTIVE_PROJECT[] = old_project
        end
    end
end

function wp_cov_files(root::String)
    files = String[]
    isdir(root) || return files
    for (dir, _, names) in walkdir(root), name in names
        endswith(name, ".cov") && push!(files, joinpath(dir, name))
    end
    return sort!(files)
end

function wp_clear_cov!(roots::String...)
    for root in roots, file in wp_cov_files(root)
        Base.rm(file; force = true)
    end
    return
end

function wp_test_with_coverage(name::String, coverage::Bool)
    # The suite-wide isolation disables automatic precompilation for speed.
    # Coverage scoping specifically needs Pkg's normal cache-flag-aware test
    # precompile so a preceding non-coverage run cannot mask instrumentation.
    return withenv("JULIA_PKG_PRECOMPILE_AUTO" => "true") do
        VibePkg.test(name; coverage, io = devnull)
    end
end

function wp_write_extension_fixture(root::String)
    trigger = mkpath(joinpath(root, "WeakPartialTrigger"))
    host = mkpath(joinpath(root, "WeakPartialExtHost"))
    wrapper = mkpath(joinpath(root, "WeakPartialExtWrapper"))
    mkpath(joinpath(trigger, "src"))
    mkpath(joinpath(host, "src"))
    mkpath(joinpath(host, "ext"))
    mkpath(joinpath(host, "test"))
    mkpath(joinpath(wrapper, "src"))
    mkpath(joinpath(wrapper, "test"))

    write(
        joinpath(trigger, "Project.toml"),
        """
        name = "WeakPartialTrigger"
        uuid = "$WP_TRIGGER_UUID"
        version = "1.0.0"
        """,
    )
    write(
        joinpath(trigger, "src", "WeakPartialTrigger.jl"),
        "module WeakPartialTrigger\nstruct Token end\nend\n",
    )

    write(
        joinpath(host, "Project.toml"),
        """
        name = "WeakPartialExtHost"
        uuid = "$WP_HOST_UUID"
        version = "1.0.0"

        [weakdeps]
        WeakPartialTrigger = "$WP_TRIGGER_UUID"

        [extensions]
        WeakPartialTriggerExt = "WeakPartialTrigger"

        [compat]
        WeakPartialTrigger = "1"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        WeakPartialTrigger = "$WP_TRIGGER_UUID"

        [targets]
        test = ["Test", "WeakPartialTrigger"]

        [sources]
        WeakPartialTrigger = {path = "../WeakPartialTrigger"}
        """,
    )
    write(
        joinpath(host, "src", "WeakPartialExtHost.jl"),
        """
        module WeakPartialExtHost
        value(x) = x === nothing ? :unused : :host
        end
        """,
    )
    write(
        joinpath(host, "ext", "WeakPartialTriggerExt.jl"),
        """
        module WeakPartialTriggerExt
        using WeakPartialExtHost, WeakPartialTrigger
        WeakPartialExtHost.value(x::WeakPartialTrigger.Token) =
            x isa WeakPartialTrigger.Token ? :extension : :unused
        end
        """,
    )
    write(
        joinpath(host, "test", "runtests.jl"),
        """
        using Test, WeakPartialExtHost
        @test WeakPartialExtHost.value(:plain) === :host
        using WeakPartialTrigger
        @test Base.get_extension(WeakPartialExtHost, :WeakPartialTriggerExt) !== nothing
        @test WeakPartialExtHost.value(WeakPartialTrigger.Token()) === :extension
        """,
    )

    write(
        joinpath(wrapper, "Project.toml"),
        """
        name = "WeakPartialExtWrapper"
        uuid = "$WP_WRAPPER_UUID"
        version = "1.0.0"

        [deps]
        WeakPartialExtHost = "$WP_HOST_UUID"
        WeakPartialTrigger = "$WP_TRIGGER_UUID"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]

        [sources]
        WeakPartialExtHost = {path = "../WeakPartialExtHost"}
        WeakPartialTrigger = {path = "../WeakPartialTrigger"}
        """,
    )
    write(
        joinpath(wrapper, "src", "WeakPartialExtWrapper.jl"),
        """
        module WeakPartialExtWrapper
        using WeakPartialExtHost, WeakPartialTrigger
        value() = WeakPartialExtHost.value(WeakPartialTrigger.Token())
        end
        """,
    )
    write(
        joinpath(wrapper, "test", "runtests.jl"),
        """
        using Test, WeakPartialExtWrapper
        @test WeakPartialExtWrapper.value() === :extension
        """,
    )
    return (; trigger, host, wrapper)
end

@testset "extension tests scope coverage to the tested package" begin
    wp_with_active_env() do root, _
        fixture = wp_write_extension_fixture(root)
        VibePkg.develop(VibePkg.PackageSpec(path = fixture.host); io = devnull)

        wp_clear_cov!(fixture.host, fixture.trigger)
        wp_test_with_coverage("WeakPartialExtHost", false)
        @test isempty(wp_cov_files(fixture.host))
        @test isempty(wp_cov_files(fixture.trigger))

        wp_test_with_coverage("WeakPartialExtHost", true)
        @test !isempty(wp_cov_files(joinpath(fixture.host, "src")))
        @test !isempty(wp_cov_files(joinpath(fixture.host, "ext")))
        @test isempty(wp_cov_files(fixture.trigger))
    end

    wp_with_active_env() do root, _
        fixture = wp_write_extension_fixture(root)
        VibePkg.develop(VibePkg.PackageSpec(path = fixture.wrapper); io = devnull)

        wp_clear_cov!(fixture.wrapper, fixture.host, fixture.trigger)
        wp_test_with_coverage("WeakPartialExtWrapper", false)
        @test isempty(wp_cov_files(fixture.wrapper))
        @test isempty(wp_cov_files(fixture.host))
        @test isempty(wp_cov_files(fixture.trigger))

        wp_test_with_coverage("WeakPartialExtWrapper", true)
        @test !isempty(wp_cov_files(joinpath(fixture.wrapper, "src")))
        @test isempty(wp_cov_files(fixture.host))
        @test isempty(wp_cov_files(fixture.trigger))
    end
end

@testset "precompile output names extension modules" begin
    wp_with_active_env() do root, _
        fixture = wp_write_extension_fixture(root)
        VibePkg.develop(VibePkg.PackageSpec(path = fixture.wrapper); io = devnull)

        # Coverage tests above may have compiled these process-unique fixture
        # names. Remove only their cache directories so explicit precompile
        # must report the full extension graph without disturbing other tests.
        compiled = joinpath(first(Base.DEPOT_PATH), "compiled")
        if isdir(compiled)
            for version_dir in readdir(compiled; join = true)
                for name in ("WeakPartialTrigger", "WeakPartialExtHost", "WeakPartialExtWrapper")
                    Base.rm(joinpath(version_dir, name); recursive = true, force = true)
                end
            end
        end

        io = IOBuffer()
        VibePkg.precompile("WeakPartialExtWrapper"; io)
        output = String(take!(io))
        @test occursin("Precompiling", output)
        @test occursin("WeakPartialTriggerExt", output)
        @test occursin("WeakPartialExtHost", output)
        @test occursin("WeakPartialExtWrapper", output)
    end
end

@testset "incompatible registered weakdep add throws ResolverError" begin
    wp_with_active_env() do root, _
        host = mkpath(joinpath(root, "WeakPartialIncompat"))
        mkpath(joinpath(host, "src"))
        write(
            joinpath(host, "Project.toml"),
            """
            name = "WeakPartialIncompat"
            uuid = "$WP_INCOMPAT_UUID"
            version = "1.0.0"

            [weakdeps]
            Example = "$WP_EXAMPLE_UUID"

            [compat]
            Example = "=0.5.4"
            """,
        )
        write(joinpath(host, "src", "WeakPartialIncompat.jl"), "module WeakPartialIncompat\nend\n")
        VibePkg.develop(VibePkg.PackageSpec(path = host); io = devnull)
        @test_throws VibePkg.Resolve.ResolverError VibePkg.add(
            VibePkg.PackageSpec(name = "Example", version = v"0.5.0"); io = devnull,
        )
    end
end

@testset "develop tolerates weakdep UUID absent from registries (Pkg #3766)" begin
    wp_with_active_env() do root, _
        host = mkpath(joinpath(root, "WeakPartialGhostHost"))
        mkpath(joinpath(host, "src"))
        write(
            joinpath(host, "Project.toml"),
            """
            name = "WeakPartialGhostHost"
            uuid = "$WP_GHOST_HOST_UUID"
            version = "1.0.0"

            [weakdeps]
            WeakPartialGhost = "$WP_GHOST_UUID"

            [extensions]
            WeakPartialGhostExt = "WeakPartialGhost"
            """,
        )
        write(joinpath(host, "src", "WeakPartialGhostHost.jl"), "module WeakPartialGhostHost\nend\n")

        VibePkg.develop(VibePkg.PackageSpec(path = host); io = devnull)
        deps = VibePkg.dependencies()
        @test haskey(deps, WP_GHOST_HOST_UUID)
        @test !haskey(deps, WP_GHOST_UUID)
    end
end

function wp_write_nested_preferences_fixture(root::String)
    dep = mkpath(joinpath(root, "WeakPartialNestedDep"))
    package = mkpath(joinpath(root, "WeakPartialNestedRoot"))
    mkpath(joinpath(dep, "src"))
    mkpath(joinpath(package, "src"))
    mkpath(joinpath(package, "test"))
    write(
        joinpath(dep, "Project.toml"),
        """
        name = "WeakPartialNestedDep"
        uuid = "$WP_NESTED_DEP_UUID"
        version = "1.0.0"
        """,
    )
    write(
        joinpath(dep, "src", "WeakPartialNestedDep.jl"),
        """
        module WeakPartialNestedDep
        preferences() = get(Base.get_preferences(), "WeakPartialNestedDep", Dict{String, Any}())
        end
        """,
    )
    write(
        joinpath(package, "Project.toml"),
        """
        name = "WeakPartialNestedRoot"
        uuid = "$WP_NESTED_ROOT_UUID"
        version = "1.0.0"

        [deps]
        WeakPartialNestedDep = "$WP_NESTED_DEP_UUID"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]

        [sources]
        WeakPartialNestedDep = {path = "../WeakPartialNestedDep"}
        """,
    )
    write(
        joinpath(package, "src", "WeakPartialNestedRoot.jl"),
        """
        module WeakPartialNestedRoot
        using WeakPartialNestedDep
        preferences() = WeakPartialNestedDep.preferences()
        end
        """,
    )
    write(
        joinpath(package, "test", "runtests.jl"),
        """
        using Test, WeakPartialNestedRoot
        prefs = WeakPartialNestedRoot.preferences()
        @test get(prefs, "toy", "") == "car"
        @test get(prefs, "tree", "") == "birch"
        @test get(prefs, "defaulted", "fallback") == "fallback"
        @test !haskey(prefs, "nonexistent")
        """,
    )
    return (; dep, package)
end

@testset "nested preferences reach a transitive dependency in Pkg.test" begin
    wp_with_active_env() do root, envdir
        fixture = wp_write_nested_preferences_fixture(root)
        VibePkg.develop(VibePkg.PackageSpec(path = fixture.package); io = devnull)
        project_file = joinpath(envdir, "Project.toml")
        project = TOML.parsefile(project_file)
        project["preferences"] = Dict(
            "WeakPartialNestedDep" => Dict("toy" => "car", "tree" => "birch"),
        )
        open(project_file, "w") do io
            TOML.print(io, project)
        end

        io = IOBuffer()
        VibePkg.test("WeakPartialNestedRoot"; io)
        @test occursin("WeakPartialNestedRoot tests passed", String(take!(io)))
    end
end
