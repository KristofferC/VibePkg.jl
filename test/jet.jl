using JET
using Test
using VibePkg

@testset "JET.jl" begin
    JET.test_package(VibePkg; target_modules = (VibePkg,), toplevel_logger = nothing)
end

@testset "JET entry points" begin
    JET.test_call(VibePkg.add, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.rm, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.up, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.status, (Vector{VibePkg.PackageSpec},); target_modules = (VibePkg,))
    JET.test_call(VibePkg.instantiate, (); target_modules = (VibePkg,))
end
