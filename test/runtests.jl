using FTransform
using NBDev
using Test

# `import`, not `using`, is required to actually extend encodes/decodes/
# setups! from outside the package -- see README.md's "A Julia gotcha".
import FTransform: encodes, decodes, setups!

# Deliberately *not* inside a notebook, and deliberately at file scope
# (not inside the @testset below -- struct/method definitions need real
# top-level scope): test_project() re-executes a notebook's own
# Transform-defining cells from scratch in a fresh sandbox each time, so
# a notebook test can't tell the difference between extending
# FTransform's real `encodes` and accidentally shadowing it with a new
# local one. Only a genuine `using FTransform` from outside the package
# (exactly what this file is) can catch that regression.
mutable struct ExternalNormalize <: Transform
    mean::Float64
    ExternalNormalize() = new(0.0)
end
setups!(t::ExternalNormalize, items) = (t.mean = sum(items) / length(items))
encodes(t::ExternalNormalize, x) = x - t.mean
decodes(t::ExternalNormalize, x) = x + t.mean

@testset "FTransform.jl" begin
    # The real tests live in the notebooks under nbs/ (nbdev-style
    # literate development) -- this runs every one of them as a test.
    @test NBDev.test_project()

    @testset "external consumer can extend encodes/decodes/setups!" begin
        t = setup!(ExternalNormalize(), [1, 2, 3, 4, 5])
        @test t.mean == 3.0
        @test encodes(t, 10) == 7.0
        @test decodes(t, encodes(t, 10)) == 10.0
        @test t(10) == 7.0  # the call wrapper dispatches to the same encodes method
    end
end
