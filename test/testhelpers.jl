# Shared test fixtures (used by registries.jl, planning.jl, ops.jl); each
# consumer includes this behind an `@isdefined(make_test_registry)` guard so
# every file stays standalone-runnable and parallel-safe.

using Base: UUID

const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
const TEST_UUID = UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")
const SHA_UUID = UUID("ea8e919c-243c-51af-8825-aaa63cd721ce")

function make_test_registry(depot)
    reg = joinpath(depot, "registries", "TestRegistry")
    pkg = joinpath(reg, "E", "Example")
    mkpath(pkg)
    write(
        joinpath(reg, "Registry.toml"), """
        name = "TestRegistry"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "https://example.com/TestRegistry.git"

        [packages]
        7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
        """
    )
    write(
        joinpath(pkg, "Package.toml"), """
        name = "Example"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        repo = "https://example.com/Example.jl.git"
        """
    )
    write(
        joinpath(pkg, "Versions.toml"), """
        ["0.5.0"]
        git-tree-sha1 = "1111111111111111111111111111111111111111"

        ["0.5.1"]
        git-tree-sha1 = "2222222222222222222222222222222222222222"

        ["1.0.0"]
        git-tree-sha1 = "3333333333333333333333333333333333333333"
        yanked = true
        """
    )
    write(
        joinpath(pkg, "Deps.toml"), """
        ["0.5-1"]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        """
    )
    write(
        joinpath(pkg, "Compat.toml"), """
        ["0.5"]
        Test = "1"

        ["0.5.1-1"]
        julia = "1.6.0-1"
        """
    )
    write(
        joinpath(pkg, "WeakDeps.toml"), """
        ["1"]
        SHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"
        """
    )
    write(
        joinpath(pkg, "WeakCompat.toml"), """
        ["1"]
        SHA = "0.7-1"
        """
    )
    return reg
end
