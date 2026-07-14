using Test
using VibePkg

# Pkg.jl#4617 — no `Core.Box` closures in the package (a boxed-variable closure
# is usually an accidental performance/correctness trap). `detect_closure_boxes`
# only exists on recent Julia, so this is a no-op elsewhere.
@testset "no Core.Box closures" begin
    if isdefined(Test, :detect_closure_boxes)
        @test isempty(Test.detect_closure_boxes(VibePkg))
    else
        @test_skip "Test.detect_closure_boxes requires a newer Julia"
    end
end
