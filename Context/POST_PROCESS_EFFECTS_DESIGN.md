# Generalized Post-Process Effects and `.threshfx`

## Goal

Make built-in and embedded post-processing effects use one ordered, scene-owned
effect stack with these invariants:

- `amount == 0` is a guaranteed identity/bypass.
- Effects run at output resolution after native rendering, adaptive compute, and
  MetalFX reconstruction.
- A custom fractal, custom space warp, and multiple post effects can coexist.
- Existing version-1 `.threshfx`, `.threshscene`, and `.threshanim` files keep
  decoding as they do today.

The current edge detector is not yet that generalized pass. It has three host
implementations: native fragment derivatives, a visionOS compute kernel, and a
Mac/iPad post-MetalFX resolve. Adding a `postProcess` enum case alone would only
reach some render paths and would create inconsistent output.

## Scene and file model

Keep the legacy `embeddedFormula` field as a compatibility projection, then add
an additive ordered collection:

```swift
struct EmbeddedEffectInstance: Codable {
    var definition: EmbeddedEffectDefinition
    var amount: Float               // clamped 0...1; 0 = host bypass
    var values: [Float]             // maximum 16, separate from FormulaParams
    var stage: PostProcessStage     // linearPreTonemap or displayPostTonemap
}

struct ActiveEffectSet {
    var fractal: EmbeddedEffectInstance?
    var spaceWarp: EmbeddedEffectInstance?
    var post: [EmbeddedEffectInstance]
}
```

`EmbeddedEffectDefinition` can initially be an internal rename/alias of the
current `EmbeddedFormula` wire shape. Schema v2 adds `kind: "postProcess"`; a
missing `kind` remains `.fractal`. New writers should emit `embeddedEffects` and
may continue emitting `embeddedFormula` only for the base custom fractal so old
apps degrade by ignoring post effects instead of rejecting the scene.

Do not reuse `FormulaParams[16]` for post effects. Those slots belong to fractal
geometry. Add a dedicated, tightly bounded `PostProcessParams` GPU block.

## Post-process ABI v1: pixel-local

The first ABI should deliberately cover effects that need only the current
pixel: vignette, exposure, tint, monochrome/sepia/invert blends, posterize,
grain, and scanlines.

```metal
float3 post_MyEffect(
    float3 color,
    float2 uv,
    float time,
    float2 resolution,
    constant PostProcessParams& params
);
```

The host owns the bypass and blending contract:

```metal
color = mix(color, post_MyEffect(color, uv, time, resolution, params), amount);
```

This guarantees identity at zero even when plugin code is imperfect. Symbols
are stemmed so multiple embedded effects can coexist and execute in authored
order. `stage` must participate in validation and cache hashing.

## Unified output stage

Route every platform through a host-controlled post-resolve stage:

```text
raymarch / adaptive compute -> optional MetalFX -> ordered post stack -> drawable
```

The native path may use the same output pass even when no upscale occurs. When
the stack is empty or every amount is zero, bypass it entirely. This removes the
current need to maintain separate edge semantics in fragment, compute, and blit
code and makes effect width/response independent of render scale.

## ABI v2: sampled neighborhood effects

Edge detection, blur, chromatic aberration, true spatial bloom, and arbitrary
convolution require a source texture and ping-pong destinations. Add those only
after the unified output pass exists. The host should own dispatch size,
resource binding, and bounds checks; embedded effects provide a constrained
pixel function, not an arbitrary kernel entry point. Depth/history inputs can
be later opt-in capabilities with explicit ABI revisions.

## Compiler and cache requirements

- Compile one `ActiveEffectSet`, not one overloaded `activeEmbeddedFormula`.
- Hash the full source hashes, effect kind, order, stage, parameter ABI, and a
  host shader ABI revision. The current 12-character source-only key is not
  sufficient for an ordered effect set.
- Validate container version separately from payload/ABI version.
- Preserve async Metal compilation and namespace all pipelines by the complete
  effect-set hash.

## Delivery slices

1. Introduce `ActiveEffectSet` and migrate the legacy single-effect lifecycle
   without adding a new effect kind.
2. Add scene/animation `embeddedEffects` migration and dedicated parameter
   storage.
3. Add the unified, bypassable output pass and move the built-in edge detector
   onto it.
4. Add pixel-local `.postProcess` schema/validation plus a compiled sample.
5. Add sampled ABI v2 only after native/compute/MetalFX parity tests pass.

Required regression coverage includes legacy no-kind decoding, ordered instance
round-trips, amount-zero pixel identity, full effect-set hash sensitivity,
runtime Metal compilation, Quick Look rendering, and native-versus-MetalFX
output parity.
