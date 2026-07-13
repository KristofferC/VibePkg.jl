using ExplicitImports: test_all_qualified_accesses_via_owners,
    test_no_implicit_imports, test_no_self_qualified_accesses,
    test_no_stale_explicit_imports
using Test
using VibePkg

@testset "ExplicitImports.jl" begin
    test_no_implicit_imports(VibePkg)
    test_no_stale_explicit_imports(VibePkg)
    test_all_qualified_accesses_via_owners(VibePkg)
    test_no_self_qualified_accesses(VibePkg)
end
