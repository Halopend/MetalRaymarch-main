# Tier-2 "Effect Plugin" Feasibility Analysis

_Grounded analysis (multi-agent, code-cited) of what it takes to load **new GPU
visual effects** as modules — not just param values. Focus: a **space-domain**
vertical slice as the cheapest proof. Verified against the codebase, June 2026._

---

## TL;DR

- **Runtime shader compilation works on visionOS ONLY today.** `CustomShaderCompiler`
  + `Renderer.swift` are build-excluded from the Mac and iOS targets
  (`project.pbxproj` membershipExceptions). The single runtime
  `device.makeLibrary(source:)` is `CustomShaderCompiler.swift:140`, reachable only
  from the visionOS compute renderer. **Consequence: a `.threshfx` custom *fractal*
  loaded on Mac/iPad renders as empty sky** (dispatch falls through to
  `default: return 1e10f`).
- **But for SPACE effects you don't need runtime compilation at all.** The space
  seam I already shipped (`applySphereProjectionDomain` in `Shaders.metal`) lives in
  the **shared** `Shaders.metal` that *both* render paths execute (Mac/iPad
  `fragmentMain` and visionOS `adaptiveHierarchical8x8` both call `MapUnified`). So a
  **baked** new space warp = new GPU behavior, **cross-platform, no compiler**.
- **The reframe:** "load an effect from a file" is the expensive, visionOS-only path.
  "Ship a richer palette of new GPU effects" is cheap and cross-platform. These are
  different products. **Pick one before building.**

---

## The cost ladder

| Phase | What it delivers | LOC | Platforms | Risk |
|---|---|---|---|---|
| **0 — Baked space effect** | A genuinely new GPU space warp (e.g. whirl/twist), uniform-gated, scene-persisted, tunable | **~250–300** | Mac + iPad + visionOS | **Low** |
| **1 — Multi-warp + UI** | 2–3 baked warps selectable + Space-module UI + capability gating | ~150–300 | all 3 | Low |
| **2 — Runtime `.threshspace` loading** | Load a warp from an external file at runtime | ~300–500 | **visionOS only** (Mac/iPad fall back to baked) | Medium |
| **3 — Cross-platform runtime compiler** | File-loaded effects on Mac/iPad too | **~300–600** (corrected ↓ from 2–3k) | all 3 | **Medium** (library swap + async-compile UX, not a rewrite) |

> **CORRECTION (verified at source).** The first pass estimated Phase 3 at ~2,000–3,000 LOC by assuming a parallel compiler must be built. That's wrong. `CustomShaderCompiler.synthesizeSource` emits the **entire** `Shaders.metal` (preamble lands in the prefix, the post-include body in the suffix), so the compiled custom `MTLLibrary` is a **drop-in replacement for `default.metallib`** with the same `fragmentShaderMono` / `screenshotVertexShader` entry points and the same function-constant specialization (compiler doc, `CustomShaderCompiler.swift:123-125`). The Mac fragment path **already** specializes via those function constants — including `fractalType` at index 7 (`RaymarchRenderView.swift:712-718`). So cross-platforming is: (1) remove the Mac/iOS **build exclusion** on `CustomShaderCompiler` (portable `import Metal` actor — no visionOS deps); (2) hold a `var activeCustomLibrary: MTLLibrary?` on `ThresholdMacRenderer`, set by a Mac activation handler (compile async on the actor); (3) at the 2 specialized-pipeline build sites swap `let library = activeCustomLibrary ?? device.makeDefaultLibrary()` (RaymarchRenderView.swift:702, 1258); (4) prefix the pipeline-cache key with the custom source hash; (5) async-compile UX (`makeLibrary(source:)` is synchronous/slow → compile off the render thread, show a "compiling" state — the visionOS path already has this pattern). Remaining real risks: async-compile hitch, pipeline-cache growth, the single-`.custom`-slot semantics, and 3-platform testing — **not** a renderer rewrite.

Phase 0 already satisfies the literal goal ("new GPU behavior, not just param
values, on all platforms"). Phases 2–3 only add **loading from a file** — and that's
where cost and platform-restriction explode.

---

## What's reusable (≈70% already exists)

- **The seam**: `applySphereProjectionDomain` + `sphereProjectionDEScale`
  (`Shaders.metal:290/303`), spliced into all 4 march variants + `GetNormal`. A new
  warp is a copy of this shape (point transform + Jacobian scale, no-op when off).
- **Dedicated GPU param channel that avoids the collision**: space params ride
  `FractalParams.sphereProjBlend/Radius` + `Uniforms.*` — **separate** from the
  contended `FormulaParams[0..15]` (which the fractal DE owns). New space params add
  fields the same way → a space effect can coexist with a custom fractal.
- **Param routing/persistence**: `ModuleRegistry.space` → `RenderSettings` setters →
  snapshot → `Uniforms` → `FractalParams`. New params register here for free
  scene save/load via `FractalPreset.modules`.
- **The runtime machinery (for Phase 2)**: `EmbeddedFormula` validation (64 KB cap,
  forbidden `#include/#import`, stem regex, SHA-256 cache key) + the marker-injection
  pattern (`injectCustomDispatch`) generalize to a `.threshspace` with a new
  `// __CUSTOM_SPACE_WARP__` marker.

## What must be built (Phase 0)

- A warp pair in `Shaders.metal`: `customSpaceWarp(p, fp) -> float3` and
  `customSpaceWarpDEScale(p, fp) -> float` (Jacobian max-singular-value; **both
  required** or the march over/understeps).
- Splice **after** `applySphereProjectionDomain` in `MapUnified`,
  `MapDistOnlyUnified`, `MapContinuousUnified`, `MapWithOrbitCacheUnified`, **and
  mirror in `GetNormal`** (cached-center path + finite-diff fallback). _(The critic
  flagged GetNormal has 4 paths — getting this wrong = wrong normals/lighting.)_
- 2–4 new `FractalParams`/`Uniforms` fields + `makeFractalParamsFromPrecomputed` +
  packing at **3** CPU call sites (`RaymarchRenderView:1230`, `Renderer:1301`,
  `RendererGameState:255`).
- `RenderSettings` get/set + `ModuleRegistry.applySpaceParam` cases + a
  `SpaceTransform` enum variant.

---

## The irreversible decisions (get these right once)

1. **ABI**: `customSpaceWarp(float3 p, FractalParams fp)` + `…DEScale(...)`. Pass the
   **whole `FractalParams` struct** (not loose floats) so fields can grow without
   breaking saved `.threshspace` files later.
2. **Seam order**: custom warp runs **after** sphere projection (warps compose
   left-to-right). Flipping it later changes every scene that uses both.
3. **Param home**: dedicated `FractalParams`/`Uniforms` fields, **never**
   `FormulaParams[0..15]`. This is what lets a space effect coexist with a custom
   fractal.
4. **Selection mechanism**: **uniform branch**, not a function constant. A function
   constant multiplies the specialized-pipeline cache (warp × fractalType ×
   iterations × raySteps) and adds first-use compile hitches. _(Critic agreed.)_
5. **Mandelbox**: the seam is the **non-Mandelbox** branch (Mandelbox uses its own
   `Map()`). Decide up front whether a new baked warp also applies to Mandelbox — if
   yes, it needs an extra splice inside `Map()`/`MapDistOnly()`/`MapContinuous()`.

---

## Costs & honest caveats

- **Perf**: the warp runs in the per-pixel march loop (~100–200 `Map` calls/pixel at
  high quality). ~20–50 float ops/warp when active; **0 when off** (branch/DCE). Est.
  <1 ms/tile on Apple Silicon — **but unmeasured**, and Vision Pro is already
  GPU-bound <45 fps, so keep v1 to a single transform with no extra `Map` calls.
- **Runtime compile (Phase 2)** is synchronous and blocks the calling thread; large
  sources stall the renderer unless queued (the existing background-build pattern
  helps). One `// __CUSTOM_SPACE_WARP__` marker = one runtime warp at a time.
- **Single `.custom` slot**: `FractalModelType.custom` + the ephemeral catalog hold
  one custom *fractal*. A runtime space warp must use its **own** parallel registry
  slot, not the fractal's, to stay composable.

---

## Generalized effect-plugin format — implementation plan (recon-verified)

Goal: one format (`.threshfx`/`EmbeddedFormula`) carries a `kind` (fractal | spaceWarp);
a loaded space warp applies to fractals on all 3 platforms. Recon found:

- **5 Metal warp seams, not 4** — `MapWithOrbitCacheUnified` (the coloring/normal-cache
  path) was missed; omitting it warps geometry but not color/normals.
- **`EmbeddedFormula` uses synthesized Codable** — a non-optional `kind` (even with a
  default) breaks decode of every existing file. MUST add explicit `init(from:)`/`encode`
  with `decodeIfPresent ?? .fractal`.
- **Warp-on-built-in requires de-coupling the pipeline cache from `fractalType == .custom`** —
  library selection + cache-key prefix gate on `.custom` at ~3 choke points per render path
  (`RaymarchRenderView.resolveActivePipeline`, visionOS `customCacheKeyPrefix` + `renderingLibrary`).
  This is the one part that touches the **hot, just-stabilized cache subsystem on both platforms**.
- Per-stem ABI: `customSpaceWarp_<stem>` / `customSpaceWarpDEScale_<stem>`.

**Staging (lowest-risk first, each build-verified, revert by commit):**
1. **Foundation (low risk, no-op when off, back-compat):** Metal seam (`__CUSTOM_SPACE_WARP__`
   marker + no-op default + 5 splices + Mandelbulb normal-gate) + `FractalParams`/`Uniforms`/
   `TileUniforms`/`RenderSettings` warp params + packing + `EmbeddedFormula.kind`. Dead at
   `spaceWarpStrength == 0`.
2. **File-loading (higher risk):** compiler combined `synthesizeSource(fractal:spaceWarp:)` +
   marker injection + combined hash; `AppModel.activeSpaceWarp` + dual-effect handler; both
   renderers' activation; the 3-function cache de-coupling; `FractalPreset.spaceWarpEffect`
   persistence; proof whirl `.threshfx`. Adversarially reviewed; the cache de-coupling lands
   **last** so it can be reverted alone.

Proof artifact: a "whirl" warp `.threshfx` (twist about Y; pure rotation → `DEScale = 1`,
zero overstep risk) — visibly twists any fractal, identical to no-warp at strength 0.

## Recommendation (updated for "multiplatform file-loaded effects")

User requirement (confirmed): **effects loaded from files must work on Mac + iPad +
visionOS.** With the Phase-3 correction above, that is now a **~1–2 week, Medium-risk**
effort, not a multi-week rewrite — because the compiler already produces a drop-in
library.

**Recommended sequence:**

1. **Keystone — cross-platform the existing custom-shader swap** (Phase 3 mechanics,
   applied first). Wire `ThresholdMacRenderer` to compile + swap to the custom library.
   This single step (a) unlocks runtime-loaded GPU code on all platforms and (b) **fixes
   a latent bug**: `.threshfx` custom *fractals* currently render as empty sky on Mac/iPad.
   Best proven with the custom-fractal path that already exists end-to-end on visionOS.
2. **Space-warp seam + `.threshspace`** (Phases 0→2, now cross-platform for free). Add the
   `// __CUSTOM_SPACE_WARP__` marker + the `customSpaceWarp`/`…DEScale` ABI + the
   `.threshspace` format. Because the library is shared by both render paths, a loaded
   space warp runs everywhere once the keystone lands.

Rationale: the keystone is the highest-leverage, most-reusable, bug-fixing step, and it
de-risks the async-compile + pipeline-cache integration that every later phase depends on.
The baked Phase-0 slice becomes optional (a fast win for curated effects) rather than the
starting point, since the user explicitly needs file-loaded, not just curated.
