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

## The import-vs-using gotcha (read this first)

Plain `using FTransform` brings every exported name into scope for
*calling*, but doesn't let you *add a method* to one of them — Julia
creates a brand-new, disconnected local function with the same name
instead. General Julia behavior (the same reason you're taught to write
`Base.show(io, x::T) = ...`, not a bare `show(io, x::T) = ...`, after
`using Base`), not a bug — but it's sharp here specifically because
defining your own methods is this package's central usage pattern. Fix:
`import` every name you intend to add a method to, before defining it:

```julia
using FTransform
import FTransform: encodes, decodes, setups!, order, autoretain, split_idx_of, inplace, itemwise
```

That's the full list — not just `encodes`/`decodes`/`setups!`. Overriding
any of `order`/`autoretain`/`split_idx_of`/`inplace`/`itemwise` on your
own `Transform` subtype (exactly what "Design notes" below tells you to
do) needs the identical `import` — confirmed to silently shadow the same
way if you skip it.

**The failure mode is not always silent.** It depends on what else
happens to be in scope:

- Usually: your method is silently never called; the library's default
  (passthrough, `order=0`, etc.) runs instead, with no error at all.
- If the shadowed name is later called elsewhere expecting the
  *library's* own methods — most plausibly `transform` itself — you
  instead get a confusing `MethodError` that gives no hint the real
  cause is a missing `import`.

Two more names reach beyond the obvious list above:

- **`transform()` itself.** It's meant to be called, not extended — but
  the shadowing mechanism is purely name-based, not role-based. Defining
  *any* unqualified method for `transform` (even for a type that has
  nothing to do with this package) converts the whole function into a
  near-empty one, breaking every other call to `transform()` in that
  module with a `MethodError` that doesn't look related at all.
- **`camel2snake`**, used internally by `Pipeline`'s
  `getproperty`/`propertynames`. An unqualified override "works" when
  called directly — the shadow is fully functional in isolation — while
  `Pipeline` silently keeps using the real one underneath, ignoring your
  override entirely with no error.

**A second, different mechanism — naming collisions, not method
shadowing.** Naming your own `Transform` subtype the same as an existing
FTransform export (`Pipeline` is an easy, generic name to reach for) also
silently shadows, but via Julia's *type* binding rather than a generic
function's method table: `struct Pipeline <: Transform end` after `using
FTransform` succeeds with no error at definition time, and the real
`Pipeline([...])` constructor call then fails with a `MethodError` that
gives no indication the cause is a name collision with the package.
`FTransform.Pipeline(...)`, fully qualified, works around it.

**A genuinely dangerous half-working state.** Importing only *some* of a
transform's needed names (`encodes` but forgetting `decodes`, say)
extends the one you imported correctly and silently shadows the other —
`encodes` looks completely correct, `decodes` looks like it works (no
error, just wrong), and only an explicit round-trip check (`decode(t,
t(x)) == x`) reveals the break.

**A `Pipeline`-specific adjacent footgun**, same silent character but a
different cause: a `Transform` subtype named `Fs` or `SplitIdx` (whose
`camel2snake`'d name collides with `Pipeline`'s own two real fields) is
*never* reachable by name through `p.fs`/`p.split_idx` — `getproperty`
checks real fields first, unconditionally, so the contained transform is
permanently shadowed with no warning regardless of `import`.

## Transform features

Beyond the quickstart above, each `Transform` can opt into a few
independent behaviors — "independent" meaning each is its own trait
function, freely combinable, rather than a family of subclasses to pick
one of (see "`split_idx`/`inplace`/`itemwise` are independent traits,
not a subclass hierarchy" below for why).

### `split_idx` — gate a transform to one split

Pass `split_idx` when *building* a transform to restrict it to a
specific split (commonly 0 for train, 1 for valid — the numbering is
entirely up to you, FTransform just compares values). Pass `split_idx`
when *calling* a transform (or a `Pipeline`, which forwards its own
`split_idx` to every transform it contains) to say which split is
currently active. A mismatch makes the call a no-op passthrough; calling
with no `split_idx` at all always runs, regardless of how the transform
was built:

```julia
# Only ever active for split_idx == 0 ("train")
augment = transform(x -> x * 10; split_idx = 0)

augment(5; split_idx = 0)   # 50 -- matches, runs
augment(5; split_idx = 1)   # 5  -- "valid" -- wrong split, passthrough
augment(5)                  # 50 -- no split given, always runs
```

### `inplace` — side-effecting transforms

By default, a `Transform`'s result is whatever `encodes`/`decodes` (or
the wrapped function) returns. `inplace = true` instead discards that
return value and hands back the *original* argument — for a transform
whose job is a side effect (typically mutating a passed-in mutable
container) rather than producing a replacement value:

```julia
function shift!(v)
    v[1] += 100
    return "ignored"  # this return value never surfaces
end
shifter = transform(shift!; inplace = true)

arr = [1, 2, 3]
shifter(arr)   # [101, 2, 3] -- the same, mutated array, not "ignored"
```

### `itemwise` — treat a tuple as one item

By default, calling a `Transform` with a `Tuple` argument unpacks it and
transforms each element independently (then re-packs the results as a
tuple). `itemwise = true` instead passes the whole tuple to the wrapped
function as a single, opaque argument:

```julia
default_add = transform(x -> x + 1)
default_add((1, 2))    # (2, 3) -- each element incremented independently

sum_pair = transform(t -> (t[1] + t[2], 0); itemwise = true)
sum_pair((1, 2))        # (3, 0) -- the whole tuple handled at once
```

### Accessing a `Pipeline`'s contained transforms by name

A `Pipeline` auto-exposes each contained transform under a
`camel2snake`'d attribute built from its type name — matching
fasttransform's own Python-reflection convenience (ported here via
`Base.getproperty` overloading). The real fields (`fs`, `split_idx`)
still resolve normally:

```julia
p = Pipeline([t2, normalize])   # normalize :: NormalizeMean

p.normalize_mean === normalize  # true -- found by snake-cased type name
p.fs                            # the real underlying field still works
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
- **A Julia gotcha, not a port decision**: see "The import-vs-using
  gotcha" above — it's load-bearing enough to earn its own section
  rather than a Design notes bullet.
- **`split_idx`/`inplace`/`itemwise` are independent traits, not a
  subclass hierarchy**: fasttransform has `InplaceTransform` and
  `ItemTransform` as separate base classes (pick at most one via single
  inheritance); a Julia `Transform` subtype overrides whichever trait
  functions (`split_idx_of`, `inplace`, `itemwise`, `autoretain`, `order`)
  it needs, freely combinable. `DisplayedTransform` needs no port at all
  — overriding `Base.show` already does that job for any Julia type.

## Known limitations

Found during an adversarial stress test, confirmed empirically, and left
as documented behavior rather than code-fixed — see
`fasttransform_files/ARCHITECTURE.md`'s "An 11-agent adversarial stress
test" section for the full detail and why each one is harder to fix than
it looks:

- `has_meta`/`get_meta`/`set_meta!` only restore automatically through a
  `Transform`'s call (not just via calling `retain_meta` directly) for a
  type that explicitly defines `Base.convert` to it — a `Number` subtype
  gets this for free, an ordinary `struct` does not, even with its own
  outer constructor.
- A custom `Number` subtype that defines its own `promote_rule` (for
  ordinary arithmetic, unrelated to this package) silently loses
  automatic type-preservation against whichever type that rule targets.
- Define your own `encodes`/`decodes`/`setups!`/trait-function methods
  on your own `Transform` subtype, never on the abstract `Transform` type
  itself — doing so applies globally and can hit a genuine Julia dispatch
  ambiguity against `FuncTransform`.
- `add!`/`setup!` called with `items=nothing` against a transform whose
  `setups!` needs real data fails with whatever unhelpful error the
  user's own `setups!` body happens to produce.
- A non-`Bool` trait-function override fails with a generic `TypeError`
  that doesn't mention FTransform or the actual override responsible.
- Pathologically deep nested-tuple inputs (100+ levels) cause
  catastrophic compile-time slowdown, not a clean error — avoid passing
  deeply-nested tuple structures through a `Transform`/`Pipeline`.

## Status

Ported directly from the real `AnswerDotAI/fasttransform` source
(`cast.py`, `transform.py`), not just its README — every quickstart
example above is a real test, run via `Pkg.test()` (which runs every
notebook under `nbs/` through
[NBDev](https://github.com/MichaelAnokye56/NBDev.jl)'s `test_project()`).
Stress-tested by 11 independent agents trying to break it from different
angles (core mechanics, every trait, malformed input, a from-scratch
realistic usage scenario, and a line-by-line re-run of every doc example)
before this release — see "Known limitations" above and
`fasttransform_files/ARCHITECTURE.md` for everything that was found and
fixed.

## Releasing

Same convention as this project's own tooling (NBDev): `prep_release()`
does the local half of a release (version bump, changelog, a tested
commit) and stops there; publishing is `@JuliaRegistrator register` on a
GitHub remote once this repo has one.

## License

MIT — see [LICENSE](LICENSE).
