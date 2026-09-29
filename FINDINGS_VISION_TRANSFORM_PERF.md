# Findings: why the Transformations engine is much slower on Vision Pro than on Mac

Date: 2026-09-21
Scope: static read of the shared Metal transform/DE path plus both platform pipeline
configurations. **No Vision Pro run exists in the repo yet** (`PERF_LOG.jsonl` is empty),
so every magnitude here is either quoted from an in-repo measurement note or an
arithmetic estimate from code constants — never presented as a device measurement.

## Headline

There is **no visionOS-specific transform engine**. Both platforms run the exact same
`Shaders.metal` source (`spaceWarpStackTransform`, `applySpaceTransforms`, the op-code
switch). The gap comes from three stacked things:

1. **Vision Pro shades ~1–2 orders of magnitude more fragments per frame** than the Mac
   viewport does interactively. Any fixed per-DE cost — and the transform sweep is paid
   per DE evaluation — is multiplied by that.
2. **The default visionOS *fragment* pipeline keeps three transform/DE tails compiled in
   that the Mac pipeline dead-code-eliminates** (Environment Scrunch, Hand Field, Sphere
   Projection). That inflates the march megakernel's register footprint for *all* work,
   the transform loop included.
3. **Enabling a transform knocks the normal estimator off its cheap paths** onto 3–4 extra
   full transform+DE evaluations *per hit pixel* (Mandelbox loses the zero-extra-Map
   analytic Jacobian; Mandelbulb loses its 2-probe fast path).

Everything in (2) and (3) is amplified by (1). The Mac result "works pretty good" largely
because (1) makes the same shader run on ~0.1–0.25 M fragments instead of ~6–11 M.

---

## 1. Workload size (dominant, and not transform-specific)

| | Mac (interactive default) | Mac (perf harness) | Vision Pro |
|---|---|---|---|
| Views | 1 | 1 | **2** (vertex amplification, `RendererPipelineHelpers.swift:67`) |
| Render scale | `resolutionScale` 0.33 (`QualityConfig.swift:133`) + MetalFX upscale (`RaymarchRenderView.swift:994`) | 1.0 (`MacBenchmarkHarness.swift:513`) | compositor `renderQuality` 0.5 default, 0.7 ceiling (`QualityConfig.swift:159,184`) |
| MetalFX | temporal/spatial upscale | n/a | **disabled** (`RendererRenderSupport.swift:540`) |
| Native panel | window (~1460×820 default) | 1920×1080 | ~3660×3200 per eye (iFixit estimate, cited by [EveryMac](https://everymac.com/systems/apple/vision/specs/apple-vision-pro-original-a2117-specs.html)) |
| GPU | M1 Pro, 16-core | M1 Pro, 16-core | M2, 10-core |

Rough fragment count per frame (arithmetic from the constants above, **estimate**):

- Mac interactive at 1920×1080 × 0.33 → 634×356 ≈ **0.23 M**
- Vision Pro at renderQuality 0.5 → 1830×1600 ×2 eyes ≈ **5.9 M**
- Vision Pro at renderQuality 0.7 → 2562×2240 ×2 eyes ≈ **11.5 M**

Compositor foveation (always on, `MetalProjectApp.swift:19`) reduces the rasterized
peripheral fragment count via the rate map, so the effective multiple is lower than the
raw ratio — but still roughly **10–30×** Mac's interactive fragment budget. The adaptive
governor (`AdaptiveRenderQualityController.swift`) then sheds render quality to hold FPS,
which is why a transform-heavy scene reads as "slower *and* blurrier" on device.

The canonical Mac baseline (Stress test, 19.4 ms @ 1080p, `PERF_PUSH.md`) is **native**
1080p — the harness pins `resolutionScale = 1.0`. Interactive Mac use is the 0.33 case,
i.e. even further ahead of the headset.

## 2. visionOS fragment pipeline bakes far fewer transform/DE tails than Mac

This is the one difference that is genuinely *about the transform/DE engine*. Function
constants, and who sets them:

| FC | Meaning | Mac viewport (`ViewportSpecializedPipelineCache` + `RaymarchRenderView`) | visionOS fragment (`RendererPipelineCache.selectPipeline`) | visionOS compute (`selectComputePipeline`) |
|---|---|---|---|---|
| 3 `hasSpaceWarp` | compile out warp seam | live (`RaymarchRenderView.swift:1471`) | live (`RendererPipelineCache.swift:507,611`) | live (`:984`) |
| 16 `hasEnvScrunch` | compile out env-scrunch tail | **always false** (`RaymarchRenderView.swift:1475,2131`; `ViewportSpecializedPipelineCache.swift:190`) | **never set → defaults ON** (`RendererPipelineCache.swift:341`) | live (`:985`) |
| 18 `hasHandField` | compile out hand-field tail | **always false** (`:1476,2133`) | **never set → defaults ON** (`:342`) | live (`:986`) |
| 17 `sphereProjection` | compile out per-fold projection | live (`ViewportSpecializedPipelineCache.swift:186`) | **never set → defaults ON** (no field in `FunctionConstantConfig`, `RendererPipelineHelpers.swift:79-95`) | never set |
| 11 `shadowsEnabled` | compile out shadow march | live (`RaymarchRenderView.swift:1446`) | not set (not in the key/config) | not set |

Shader defaults are "ON when undefined" for all four (`Shaders.metal:171-186`), and the
tails run in **every** DE evaluation. The shader's own comments quantify the Mac cost of
compiling them in: Environment Scrunch "~12% GPU", Hand Field "~20% GPU"
(`Shaders.metal:178,184`). Sphere projection adds a branch + call in
`applySpaceTransforms` on every non-Mandelbox DE (`Shaders.metal:2147-2151`).

Consequences for the transform engine on Vision Pro:

- `applyHandAttraction` (which itself calls `applyEnvScrunch`) is invoked at the end of
  **every** `MapUnified` / `MapDistOnlyUnified` / `MapWithOrbitCacheUnified` call
  (`Shaders.metal:2168,2173,2183,2188,2198,2633,2655`). With the tails compiled in, each
  transform+DE evaluation carries their register cost even when the features are off.
- Env Scrunch defaults **off** (`RenderSettings.swift:328`) and sphere projection defaults
  **off** (`:193`), so on the visionOS fragment path both are pure waste.
- Hand Attraction defaults **on** (`RenderSettings.swift:405`) and is genuinely sampled
  when a hand is tracked, so that tail is doing real work by default — but it is also never
  removed when the user turns it off.
- The adaptive-compute path *does* gate all three correctly (`RendererPipelineCache.swift:984-997`),
  but the default mode is **fragment** (`tileSize` 0, `QualityConfig.swift:208`), and the
  in-app Performance Sweep explicitly forces `tileSize = 0` (`PerfSweepRunner.swift:61`).

The project is documented as ALU-bound (~68–70% ALU, `PERF_PUSH.md`). Compiling these
tails into an ALU-bound megakernel is exactly the wrong trade, and it slows the transform
sweep through lower occupancy.

*Note:* the comment at `Shaders.metal:167-170` says only the Mac `_SW0` variant bakes
`hasSpaceWarp` off — that is stale. `selectPipeline` does bake `_SW` on visionOS
(`RendererPipelineCache.swift:611`), so empty stacks are DCE'd on both platforms. Don't
chase that.

## 3. Enabling a transform forces the expensive normal path on both platforms

`MapWithOrbitCacheUnified` invalidates the cached analytic Jacobian whenever the stack is
non-empty (`Shaders.metal:2634-2641`). `GetNormal` then falls through its fast paths:

- **Mandelbox** — analytic Jacobian path (`Shaders.metal:2727`, *zero* extra Map calls)
  becomes the `cache.valid && type == Mandelbox` branch (`:2745-2764`): **four full
  `MapUnified` calls**, each re-running `applySpaceTransforms` (i.e. the whole op-chain
  sweep) at reduced iterations.
- **Mandelbulb** — the 2-probe `ApproximateMandelbulbNormal` fast path is explicitly
  gated out by `params.spaceWarpCount <= 0` (`:2736-2739`), so it drops to the 3-probe
  `applySpaceWarp` finite-difference path (`:2803-2812`).
- Separately, `warpOpDEScale` shrinks the reported distance (the Lipschitz divisor), so
  the march itself takes smaller steps and more iterations to converge
  (`Shaders.metal:1087-1092`).

So turning on one transform changes per-hit-pixel cost from "march only" to "march + 4
transform+DE evaluations" (Mandelbox). That is the same code on both platforms — but on
Vision Pro it runs on ~10–30× more stereo fragments.

## 4. Mac-only distance-cache shortcut

`FractalDistanceCache` is a Mac fragment-path prototype, inert on the visionOS compositor
path (`RendererGameState.swift:441-442`), opt-in even on Mac
(`THRESHOLD_DIST_CACHE=1`, `RaymarchRenderView.swift:548`). It is eligible only for a
stable Mandelbox with no sphere projection / env scrunch / hands / scene primitives
(`FractalDistanceCache.swift:828-840`), and it deliberately applies domain transforms to
the *lookup point* while reusing the canonical seed (`:826-827`). For an eligible
Mandelbox + transform scene this can bypass most of the warped DE on Mac. It explains part
of the gap on that family, not the general one.

## 5. Secondary rays

Shadows default on. The Mac viewport bakes `FC_SHADOWS_ENABLED` from the live toggle and
includes `_SH` in its pipeline key (`RaymarchRenderView.swift:1446,1477`), so turning
shadows off removes the shadow march entirely. The visionOS fragment lookup never sets it
and omits `_SH` from the key, so the shadow march stays compiled in. With a transform,
each shadow step also pays a transform sweep.

---

## What I could not determine from the repo

- Whether the specific scene being tested was on the fragment or compute path (default is
  fragment; scenes mostly ship `tileSize: 0`).
- Actual on-device drawable size + foveation decode for the run in question — these are
  reported live in the app's render diagnostics (`RendererRenderSupport.swift:335-377`).
- Which fractal the transform was applied to (the normal-path cost differs sharply:
  Mandelbox vs Mandelbulb vs custom).

## How to confirm it on device (per the repo's own protocol)

`PERF_PUSH.md` standing rules apply: one lever per measurement, no estimates, pin the
adaptive governor.

1. Same scene, stack empty vs one op, on device, `gpuMsAvg`/`gpuMsP95` both ways. This
   isolates the transform's true marginal cost.
2. Repeat with `tileSize` 0 vs 8 (fragment vs compute) — the compute path already gates
   the tails, so it is the natural upper bound for fix #1 below.
3. Repeat with Env Scrunch off / Hands off / Shadows off to size the DCE opportunity.
4. Append the device `perf-log.jsonl` rows to `PERF_LOG.jsonl` (it is currently empty).

## Recommended fixes, ranked

1. **Bake FC 16/18 on the visionOS fragment path from live toggles**, mirroring
   `selectComputePipeline` (`RendererPipelineCache.swift:984-997`), and add the
   `_ES/_HF` segments to the fragment key (`RendererPipelineCache.swift:519-573`). Low
   risk, purely restores Mac behavior; needs the `deTailCacheKey` pairing kept in lockstep
   with prewarm.
2. **Add `sphereProjection` (FC 17) to `FunctionConstantConfig`** and bake it in
   `selectPipeline`, keyed like Mac's `_SP`. Also low risk; recovers the DCE Mac already has.
3. **Bake `shadowsEnabled` (FC 11) in the visionOS fragment key** (Mac already does).
4. **Fuse `GetNormal`'s four transform sweeps** (the open item in `PERF_PUSH.md` #10): use
   the fused `applySpaceWarpTransform` / hoist `applySphereProjectionDomain` on the
   Mandelbox probe path. Helps Mac too, but the payoff is ~10–30× larger on device.
5. **Reconsider the default `handAttractionEnabled = true`** (`RenderSettings.swift:405`)
   now that its DE tail cannot be DCE'd on device.
6. **Measure the compute path as the default for transform scenes** — it already gates
   the tails, at the cost of a different march structure.

Items 1–3 are the low-risk, high-confidence wins and are the direct answer to "the Mac
bakes it out and Vision Pro doesn't".

## Evidence index

- Transform stack: `Threshold/Rendering/Shaders.metal:1087-1340`, `:2141-2159`
- FC declarations/defaults: `Threshold/Rendering/Shaders.metal:155-186`
- Mac FC bakes: `Threshold/Rendering/RaymarchRenderView.swift:1446,1471-1477,2131-2135`;
  `Threshold/Rendering/Core/ViewportSpecializedPipelineCache.swift:179-193`
- visionOS FC bakes: `Threshold/Rendering/Core/RendererPipelineCache.swift:507-573,984-997`
- visionOS fragment selection call site: `Threshold/Rendering/Renderer.swift:1490-1499`
- Stereo amplification: `Threshold/Rendering/Core/RendererPipelineHelpers.swift:67`
- Compositor config (foveation, HDR): `Threshold/App/MetalProjectApp.swift:14-99`
- Quality constants: `Threshold/Parameters/Config/QualityConfig.swift:133,159,184,208`
- Mac reduced-res + MetalFX: `Threshold/Rendering/RaymarchRenderView.swift:985-1012`
- visionOS MetalFX disabled: `Threshold/Rendering/Core/RendererRenderSupport.swift:540`
- Adaptive governor: `Threshold/Rendering/Core/AdaptiveRenderQualityController.swift`
- Distance cache: `Threshold/Rendering/FractalDistanceCache.swift:826-851`;
  `Threshold/Rendering/Core/RendererGameState.swift:441-442`
- Perf protocol: `PERF_PUSH.md`, `PERF_LOG.md`
