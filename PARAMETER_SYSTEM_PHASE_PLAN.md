# Parameter System Next Phase Plan

## Goal
Create a **single parameter runtime** that can accept changes from many sources while remaining deterministic, performant, and consistent across fractal types.

This phase is specifically designed to support these contexts:
- gesture + window sliders
- music mods (centered `+/-` modulation around a user-selected base)
- animation playback
- precomputed CPU-side transforms shared across all pixels

---

## 1) Core Model: One Canonical Parameter Graph

Define one canonical graph for all tweakable values:

- `ParameterID` (stable string, e.g. `core.minDistance`, `formula.mandelbulb.power`)
- `ParameterKind` (`float`, `bool`, `int`, future: vector/color)
- `ParameterScope`
  - `global` (applies to all fractals)
  - `fractalCommon` (same semantic param, fractal-dependent range/default)
  - `fractalSpecific(fractalType)` (only valid for one formula family)
- `ParameterMetadata`
  - display name/group/icon
  - default value, min/max, step
  - smoothing/response hint
  - CPU precompute eligibility

### Why
- Prevents duplicate parameter wiring in gesture, slider, animation, and music paths.
- Makes fractal-specific vs common behavior explicit at the type level.

---

## 2) Layered Value Composition (Base + Offsets)

Each parameter should be resolved from composable layers rather than direct writes.

### Proposed value stack
1. **Base/User layer** (slider/manual control)
2. **Gesture layer** (interactive additive or absolute, depending on mapping)
3. **Animation layer** (timeline-driven override/offset)
4. **Music Mod layer** (centered bipolar modulation around user base)
5. **Safety/Clamp layer** (hard constraints, nonlinear guards)

Final resolved value each frame:

`resolved = clamp(combine(base, gesture, animation, music, policy), range)`

### Music mod specifics
Model music mods as normalized bipolar offsets:
- user selects a central value (`base`)
- music contributes `mod ∈ [-1, +1]`
- mapped by per-parameter intensity curve
- applied as additive offset or blend based on policy

This preserves user intent while keeping system reactivity.

---

## 3) Source Arbitration Policy

Create a source arbitration contract so all contexts can coexist predictably.

Per parameter, define:
- `blendMode`: `absolute`, `additive`, `multiplicative`, `override`
- `priority`: deterministic source precedence
- `lockWindow`: optional hold/decay after gesture interaction
- `conflictRule`: (`gestureWinsWhenActive`, `animationWins`, `weightedBlend`)

### Recommended default
- User base value is always preserved as canonical center.
- Gesture and music are additive deltas by default.
- Animation can be absolute or additive per track.

---

## 4) Unified Write Path: Parameter Operations

Replace scattered direct writes with a centralized operation queue:

```text
ParameterOperation {
  parameterID,
  source,              // slider/gesture/music/animation/system
  mode,                // absolute/additive/etc.
  value,
  timestamp,
  weight,
  duration(optional)
}
```

Frame pipeline:
1. Collect operations from all systems.
2. Group by `ParameterID`.
3. Resolve via arbitration policy.
4. Emit resolved values to runtime cache.
5. Publish change-set for renderer + UI.

This enables bundling, delegation, recording, playback, and debugging.

---

## 5) CPU Precompute Integration

Some resolved parameters should trigger shared CPU precomputes once per frame (not per pixel).

Introduce `PrecomputeNode`:
- declares required input parameters
- computes derived values used by shaders
- caches result by dirty token/version

Examples:
- transform matrices
- repeated trigonometric constants
- fold/rotation helper coefficients

### Contract
Any parameter marked `cpuPrecomputeEligible` can participate in precompute dependency graphs.

---

## 6) Fractal Commonality Strategy

Support both shared and formula-specific parameters with one API.

### Approach
- Maintain a **Common Parameter Set** (`minDistance`, `foldingLimit`, `scale`, etc.).
- Register **Formula Extensions** for each fractal type.
- Use the same `ParameterID` resolution API regardless of scope.

If a source targets an unsupported parameter for a fractal:
- policy can ignore, remap, or fallback.
- behavior is explicit and testable.

---

## 7) Performance Guardrails

To avoid runtime overhead regressions:
- O(1) lookup by `ParameterID` and by formula index where needed.
- No per-frame dynamic graph rebuilds.
- Dirty-bit/versioned updates only.
- Batch apply operations once per frame.
- Track telemetry:
  - operation count/frame
  - resolve time
  - precompute time
  - shader-uniform update count

---

## 8) Migration Plan

### Phase A — Foundation
- Introduce `ParameterID`, metadata registry, and operation queue.
- Route slider writes through operation pipeline.

### Phase B — Gestures + Animation
- Route gesture and animation writes through the same queue.
- Add arbitration and lock/decay policy.

### Phase C — Music Mods
- Add bipolar modulation layer around canonical user base.
- Expose per-parameter intensity/curve controls.

### Phase D — CPU Precompute
- Add precompute nodes with dirty dependency tracking.
- Route derived uniforms from precompute cache.

### Phase E — Cleanup
- Remove legacy direct-write paths.
- Consolidate old gesture/formula wiring into registry-backed bindings.

---

## 9) Expected Impact Areas

This architecture will impact:
- `RenderSettings` data flow and property setters.
- gesture assignment + dispatch logic.
- animation playback write path.
- formula parameter registry/batching.
- renderer uniform update timing.
- preset serialization (base values + modulation config).

---

## 10) Minimal First Deliverables

1. `ParameterID` + `ParameterMetadataRegistry` with scope support.
2. `ParameterOperationDispatcher` with source arbitration.
3. slider + gesture integration through dispatcher.
4. one music mod prototype path on a shared parameter.
5. one CPU precompute node proving per-frame shared compute reduction.

These five items are enough to validate centralization before full migration.
