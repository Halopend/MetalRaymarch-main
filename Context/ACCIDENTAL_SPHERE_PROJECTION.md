# Accidental Sphere Projection — root cause, the lost look, and how to rebuild it

**Update (2026-07-30):** a standalone recreation now exists as a custom DE —
[`Threshold/Examples/Formulas/AccidentalSphereProjection.threshfx`](../Threshold/Examples/Formulas/AccidentalSphereProjection.threshfx)
plus a bundled scene
[`Threshold/Examples/Scenes/Accidental Sphere Projection.threshscene`](../Threshold/Examples/Scenes/Accidental%20Sphere%20Projection.threshscene)
(branch `thrsh/accidental-sphere-projection`). Instead of the `FC_ITER_BIAS` recipe below
(which biases the shared Mandelbox pipeline), it bakes the mismatch into its own formula:
the geometry loop runs a `Geometry Folds` param (era: 2, the `f58cc5ea` "sphere mode"
pinned count) regardless of the scene iteration count, the DE tail subtracts
`pow(scale, 1 − Norm Iterations)` (era: the full runtime count, ≈ 0), and the orbit
variant keeps folding to full depth so orbit-trap coloring is projected onto the
under-folded surface. Era-exact fold math from `MAP_ITERATION_BASIC`; parameter defaults
taken from the After-Sphere reference recording HUD (Scale 3.32, Box Folding Limit 1.04,
Sphere Radius 0.75 → Min R² 0.5625, Max Steps 144). Reference capture: image + screen
recording from the era build, 2026-07-30. Only the user can confirm the exact match; the
mechanism below remains the reference.

**Status (2026-07-07):** the original distinct look is **NOT reproducible** in the current
build. The `deIterationMismatch` control is a **failed recreation** — right plumbing, wrong
mechanism (see below). The only surviving artifact of the real effect is branch
**`After-Sphere`** (origin ✓; commits `f50fe1f9` "Accidental Sphere Projection" +
`f58cc5ea` "sphere debug"; notes in `After-Sphere:DEBUG_SPHERE_FLICKERING.md`). That branch
is against the **retired `MetalRaymarch/` layout** (pre-`Threshold/` rename) and **cannot be
merged**. This doc exists so the look can be rebuilt on the current tree even if the branch is
ever lost.

## What the effect was
A fractal that rendered as a distinct, partially-folded **sphere** — found by accident, "very
distinct," never reproduced since. Per `DEBUG_SPHERE_FLICKERING.md`, the root cause was a
**dual-iteration system**: the geometry fold loop and the shading/DE-normalization ran
*different* iteration counts.

## Root cause (the real mechanism)
A **structural** iteration-count mismatch between the geometry `Map()` fold loop and the
color / DE-normalization — two changes in `f50fe1f9` acting together:
- `Renderer.swift`: `colorIterations: Int32(preset.fractalIterations)` → **`colorIterations: nil`**
  (color/orbit-trap loop decoupled from the geometry count).
- `Shaders.metal`: `Map()` forced to run **only** the compile-time `FC_FRACTAL_ITERATIONS`; in
  fallback pipelines that count collapsed low, so the fold loop genuinely **under-folds** →
  `d ≈ length(pos) − k` (a sphere) — while the full color/lighting machinery kept painting it.

The distinctness came from the **geometry loop actually running a different (low) count than the
DE/shading assumed** — an emergent structural state, not any single smooth parameter.

## Why `deIterationMismatch` (the current recreation) can't land it
`deIterationMismatch` (δ, clamp ±8, scene-persisted, Settings slider) applies δ to the **DE
normalization term only** — [`RenderPrecompute.swift:93-97`](../Threshold/Rendering/Core/RenderPrecompute.swift#L93):
```
absScalePow = pow(|fractalScale|, (1 - fractalIterations) - δ)
```
which is consumed at [`Shaders.metal:1428`](../Threshold/Rendering/Shaders.metal#L1428):
`d = (length(p.xyz) - absScalem1)/p.w - absScalePow`.

So δ smoothly inflates/deflates the **distance normalization** while **every loop still runs the
same synced `FC_FRACTAL_ITERATIONS`** ([`Shaders.metal:1415`](../Threshold/Rendering/Shaders.metal#L1415)).
It perturbs the surface's DE continuously but never recreates the structural under-folding.
**Wrong application point → cannot reach the look at any δ.**

## How to rebuild it (recipe)
The plumbing already exists — reuse it, change only the application point.

- The tree already has three decoupled iteration function constants:
  `FC_FRACTAL_ITERATIONS` (0), `FC_SHADOW_ITERATIONS` (1), `FC_COLOR_ITERATIONS` (9)
  ([`Shaders.metal:91,94,117`](../Threshold/Rendering/Shaders.metal#L91)).
- `deIterationMismatch` already round-trips end-to-end: `FractalPreset` field + encode/decode,
  `RenderSettings` accessor (clamp ±8), `DisplayConfig`, Settings slider
  ([`ContentView+SettingsTab.swift:620`](../Threshold/App/ContentView+SettingsTab.swift#L620)),
  snapshot, benchmark harness.

**Recommended implementation — a `FC_ITER_BIAS` function constant (cleanest):**
1. Add `constant int FC_ITER_BIAS [[function_constant(N)]];` and compute the geometry loop as
   `loopCount = FC_FRACTAL_ITERATIONS + FC_ITER_BIAS` in `Map()`
   ([`Shaders.metal:1406-1425`](../Threshold/Rendering/Shaders.metal#L1406)). Because both are
   **compile-time constants, the loop stays fully unrolled — no hot-path perf regression**, and
   **no `FractalParams` change** (avoids the `FractalParams ≤ 320 B` size gate, already 48 B over
   the 272 B occupancy-collapse size — see TECH_DEBT item J / #8d).
2. Keep `absScalePow` normalized to the **unbiased** `fractalIterations` (i.e. leave
   `RenderPrecompute.swift:97` as-is, or explicitly drop the δ term there) so the geometry
   under-folds **relative to its normalization** — that IS the original mismatch.
3. Wire δ → `FC_ITER_BIAS = round(deIterationMismatch)` at pipeline creation, alongside the other
   iteration constants in the pipeline-cache specialization (`RendererPipelineCache`). The cache
   already keys on iteration constants, so this adds ≤17 variants (δ ∈ −8…8) — acceptable.
4. `EmbeddedMetalSources.swift` regenerates automatically from `Shaders.metal`; **clear the PSO archive**
   (`rm -rf ~/Library/Application\ Support/ThresholdPipelineArchive`) before testing, or the old
   pipeline is reused and the change appears to "do nothing."
5. **Only the user can confirm the look** — dial the (now loop-affecting) slider on a Mandelbox
   and compare against the `After-Sphere` reference. Expect a *negative* bias (fewer folds) to
   approach the sphere.

*Alternative (avoid if possible):* carry `iterBias` as a runtime `int` in `FractalParams` — but
that bumps the size-gated struct and makes the loop bound runtime (defeats unrolling unless
gated on `iterBias == 0`). The function-constant route is strictly better here.

## Pointers
- Lost-look artifact: branch `After-Sphere` — `f50fe1f9`, `f58cc5ea`, `DEBUG_SPHERE_FLICKERING.md`.
- Failed recreation: [`RenderPrecompute.swift:93-97`](../Threshold/Rendering/Core/RenderPrecompute.swift#L93) → [`Shaders.metal:1428`](../Threshold/Rendering/Shaders.metal#L1428); slider at [`ContentView+SettingsTab.swift:620`](../Threshold/App/ContentView+SettingsTab.swift#L620).
- Geometry loop to change: [`Shaders.metal:1406-1425`](../Threshold/Rendering/Shaders.metal#L1406).
- Distinct from the shipped **Sphere Projection** feature (`sphereProjectionEnabled/Blend/Radius`) — that is a real, working, separate effect; this is the *bug's* form, which it does not reproduce.
