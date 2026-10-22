# FTransform

[![Build Status](https://github.com/MichaelAnokye56/FTransform.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/MichaelAnokye56/FTransform.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/MichaelAnokye56/FTransform.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/MichaelAnokye56/FTransform.jl)

Reusable, reversible data transformations and pipelines — a Julia port of
AnswerDotAI's [fasttransform](https://github.com/AnswerDotAI/fasttransform),
built notebook-first with [NBDev](https://github.com/MichaelAnokye56/NBDev.jl)
(ported from the real source, not just the README — see
[`ARCHITECTURE.md`](https://github.com/MichaelAnokye56/NBDev.jl) in this
project's reverse-engineering notes for the full study).

A `Transform` wraps one or more functions with: type-based dispatch (which
function runs depends on the runtime type of the argument), reversibility
(`encode`/`decode`), dataset-dependent setup, and automatic return-type
preservation. A `Pipeline` composes an ordered sequence of `Transform`s,
applying them forward and undoing them in reverse.

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/MichaelAnokye56/FTransform.jl")
```

(Not yet registered in the Julia General registry.)

## Quickstart

```julia
using FTransform
# Defining your own encodes/decodes/setups! methods below needs `import`,
# not just `using` -- see "A Julia gotcha" below for why.
import FTransform: encodes, decodes, setups!

# Wrap a plain function
add_one(x::Int) = x + 1
t1 = transform(add_one)
t1(2)                      # 3
t1(2.0)                     # 2.0 -- no matching method for Float64 -> passthrough

# Reversible
t2 = transform(x -> x * 2; dec = x -> x ÷ 2)
t2(2)                       # 4
decode(t2, t2(2))           # 2

# Type-based dispatch -- just a named function with multiple methods;
# Julia's own multiple dispatch does the work fasttransform needs the
# third-party `plum` library for in Python (see "Where Julia wins" below)
incdisp(x::Int) = x + 1
incdisp(x::AbstractString) = x * "a"
t3 = transform(incdisp)
t3(5)                       # 6
t3("b")                     # "ba"

# Setup from a dataset
mutable struct NormalizeMean <: Transform
    mean::Float64
    std::Float64
    NormalizeMean() = new(0.0, 1.0)
end
setups!(t::NormalizeMean, items) = (t.mean = sum(items)/length(items))
encodes(t::NormalizeMean, x) = (x - t.mean) / t.std
decodes(t::NormalizeMean, x) = x * t.std + t.mean
normalize = setup!(NormalizeMean(), [1, 2, 3, 4, 5])

# Pipeline: compose, then decode undoes in reverse order
p = Pipeline([t2, normalize])
v = p(5)
decode(p, v)
```

## Design notes (Julia-specific — see `ARCHITECTURE.md` for the full reasoning)

- **Where Julia wins**: fasttransform's `_TfmMeta`/`_TfmDict` metaclass
  machinery, plus the third-party `plum` dispatch library, exist only to
  fake "define several same-named methods with different type
  annotations, resolved at runtime" — exactly what Julia's own multiple
  dispatch already does natively, for free. A `Transform` subtype just
  defines ordinary `encodes`/`decodes` methods; no metaclass needed.
- **Type preservation is construct-only, never mutate-in-place**: Python's
  `cast`/`retain_type` can reassign an existing object's `__class__`; a
  Julia value's concrete type is fixed forever once constructed, so
  `cast` here always builds a new value via the target type's own
  constructor.
- **A Julia gotcha, not a port decision**: defining your own
  `encodes`/`decodes`/`setups!` method for a new `Transform` subtype
  needs `import FTransform: encodes, decodes, setups!` first (or fully
  qualifying as `FTransform.encodes(...)  = ...`) — plain `using
  FTransform` brings those names into scope for *calling*, but a bare
  `encodes(t::MyType, x) = ...` after that silently creates a brand new,
  separate local function instead of adding a dispatch method to the
  real one, with no error or warning. Easy to miss, since the failure
  mode is silent (your method is just never called) rather than loud.
- **`split_idx`/`inplace`/`itemwise` are independent traits, not a
  subclass hierarchy**: fasttransform has `InplaceTransform` and
  `ItemTransform` as separate base classes (pick at most one via single
  inheritance); a Julia `Transform` subtype overrides whichever trait
  functions (`split_idx_of`, `inplace`, `itemwise`, `autoretain`, `order`)
  it needs, freely combinable. `DisplayedTransform` needs no port at all
  — overriding `Base.show` already does that job for any Julia type.

## Status

Ported directly from the real `AnswerDotAI/fasttransform` source
(`cast.py`, `transform.py`), not just its README — every quickstart
example above is a real test, run via `Pkg.test()` (which runs every
notebook under `nbs/` through
[NBDev](https://github.com/MichaelAnokye56/NBDev.jl)'s `test_project()`).

## Releasing

Same convention as this project's own tooling (NBDev): `prep_release()`
does the local half of a release (version bump, changelog, a tested
commit) and stops there; publishing is `@JuliaRegistrator register` on a
GitHub remote once this repo has one.

## License

MIT — see [LICENSE](LICENSE).
