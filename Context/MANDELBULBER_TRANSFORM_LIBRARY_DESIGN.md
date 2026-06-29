# Composable Analytic-DE Transforms for Threshold — Final Enhancement Report

**Porting Mandelbulber2's `transf_*` operator vocabulary into a single, ad-hoc composable transform pipeline**

## Executive summary

Threshold today builds every fractal as a hand-written monolith: each `Formulas/<Name>/<Name>.h` re-declares its own point variable, its own running derivative (`dr`/`w`/`scale`), and re-implements box fold, sphere fold, abs fold, rotation and scale from scratch — twice (an orbit-tracking `DE_<Name>` and a near-duplicate `DE_<Name>_Dist`). There is no shared transform library; the only genuinely composable seam is `applySpaceTransforms` (Shaders.metal:777), which chains domain warps as `(point, deScale)` pairs. Mandelbulber2 solves exactly this with ~250 `transf_*` operators that all mutate one shared `aux` state in place and update one analytic derivative `aux.DE` by a tiny set of rules. The core architectural shift this report recommends: **introduce one `TransformContext` aux struct and a uniform `FORCE_INLINE` operator signature in MSL, implement the ~8 cross-family primitives that every shipped formula and the whole Mandelbox/Amazing/Kleinian/Menger lineage reduce to, and let a fractal become a thin straight-line "recipe" of inlined operator calls** — reachable identically by the static built-in path and the embedded `.threshfx` path (via the compiler prefix). This is a rename-and-extract of math Threshold already has, not new math. It unlocks, in order: drift-free deduplicated folds, DE-correctness by construction, a DIFS shaping layer (booleans/clipping/framing), structural orbit-trap coloring, and eventually zero-cost analytic normals for *all* formulas (today only unwarped Mandelbox gets them).

---

## 1. The core idea — what Mandelbulber does that we don't

Five things Mandelbulber has and Threshold lacks:

1. **A uniform operator shape.** Every `transf_*` takes `(CVector4 &z, sExtendedAux &aux)` plus its own params and mutates them in place. Threshold re-declares `float3 p; float dr=1;` in every header and hand-threads the derivative differently each time.
2. **One analytic derivative with a tiny rule set.** `aux.DE` is the running scalar Jacobian magnitude `|z'|`. Isometries leave it alone; scale does `DE=DE*|s|+1`; sphere fold does `DE*=factor`; trig power does `DE=pow(r,p-1)*p*DE+1`; non-conformal warps fall back to `DE*=|z_new|/|z_old|+1`. Threshold's existing `dr`/`w` *is* this — it's just not centralized.
3. **A color side-channel (`aux.color`)** threaded through iteration, written by folds (which axis folded, which shell, which swap). Threshold has only a scalar min-r² trap computed after the fact.
4. **`transformCommon` param sharing** — a shared vocabulary of param fields reused across all operators. Threshold's `FormulaParams.params[16]` is per-formula-by-index with no convention.
5. **Iteration-window gating** (`startIterations`/`stopIterations`) as a universal decorator on every op — cheap (one compare) and high-variety.

The unifying observation across the entire inventory (8 families, ~250 files): the `topPicks` of *every* family collapse to the **same ~8 primitives** — box/Tglad fold, sphere fold, abs+constant, scale, rotation, add-cpixel, trig-power, and diagonal/menger sort. Everything else is those primitives plus optional decorators (per-axis masks, iteration windows, param ramps).

---

## 2. Recommended architecture

### 2.1 The spine: one aux struct + one operator signature

Add **one new header `Threshold/Formulas/ThresholdTransforms.h`**, `#include`d by `FractalFormulaCommon.h` (so it reaches the static path) and concatenated into `CustomShaderCompiler.synthesizedSourcePrefix` right after `FractalFormulaCommon.h` (so it reaches embedded DEs, which cannot `#include`). Every operator mutates a thread-local `TransformContext& T` in place and touches only `T` plus its own scalar/vector args.

```metal
// ThresholdTransforms.h — register-light; keep ~12 floats unless wantJ
struct TransformContext {
    float3 p;        // sample point (Mandelbulber z)
    float  dr;       // analytic DE accumulator  (== Mandelbulber aux.DE / Threshold w)
    float  r2;       // cached dot(p,p); ops that mutate p must invalidate or recompute
    float3 c;        // per-pixel seed (const_c)
    int    i;        // iteration index (for gating)
    float  trap;     // min-r2 orbit trap
    int    trapIter;
    float3 trapPos;
    float4 colorAux; // RGB + accumulated fold magnitude (see §6)
};

// --- the 3 (and only 3) ways an op may touch the derivative (see §4) ---
FORCE_INLINE void deScale     (thread TransformContext& T, float s){ T.p*=s; T.dr=T.dr*fabs(s)+1.0f; }   // closing scale, re-injects +1
FORCE_INLINE void deScaleNoAdd(thread TransformContext& T, float k){ T.p*=k; T.dr*=k; }                  // sphere-fold / radial factor
FORCE_INLINE void deScaleRatio(thread TransformContext& T, float oldLen){ T.dr=T.dr*(length(T.p)/max(oldLen,1e-12f))+1.0f; } // non-conformal fallback
// isometries (rotate/reflect/fold/translate) call neither — |J|=1
```

### 2.2 A fractal is an INLINED recipe, not a bytecode VM

Metal has no recursion and Threshold's perf model depends on full inlining + function-constant dead-code elimination (Map is called 50–100×/pixel). **Do not build an opcode interpreter** — a per-iteration `switch`/program-counter defeats unrolling and tanks the hot loop. A recipe is plain straight-line MSL the compiler fully unrolls. This also matches the embedded path, which can only concatenate flat source. Template the body on `bool ORBIT` so the `_Dist` twin shares one source and can never drift (verify the compiler DCEs `ORBIT=false` — open question §9):

```metal
template<bool ORBIT>
FORCE_INLINE float DE_BoxSphereFolder_R(float3 pos, FormulaParams fp, float3x3 rot,
                                        int iters, int colorIters, thread OrbitData* o) {
    TransformContext T;
    T.p = pos - float3(fp.params[0],fp.params[1],fp.params[2]);
    T.dr = 1.0f; T.trap = 1e20f; T.colorAux = 0.0f;
    for (T.i = 0; T.i < iters; ++T.i) {
        if (hasRot1Precomputed(fp)) T.p = rot * T.p;     // isometry: no dr write
        boxFold(T, fp.params[3]);                         // |J|=1
        sphereFold(T, fp.params[4], fp.params[5]);        // deScaleNoAdd
        deScale(T, fp.params[6]);                          // closing scale +1
        if (ORBIT) trapUpdate(T, colorIters);
    }
    if (ORBIT) { o->trap=T.trap; o->finalP=T.p; o->iterationsUsed=T.i; o->colorAux=T.colorAux; }
    return (length(T.p.zy) - fp.params[7]) / max(fabs(T.dr), 1e-6f);
}
// thin shims keep FractalFormulas.h dispatch + injection markers byte-identical:
float DE_BoxSphereFolder     (...) { return DE_BoxSphereFolder_R<true >(...); }
float DE_BoxSphereFolder_Dist(...) { return DE_BoxSphereFolder_R<false>(...); }
```

### 2.3 Reaching both paths

- **Static path:** `FractalFormulaCommon.h` `#include`s `ThresholdTransforms.h`; built-in headers call the ops.
- **Embedded path:** add `EmbeddedMetalSources.transformsH` (regenerate via `Scripts/generate_metal_embeds.sh` — **mandatory** or the runtime concat won't see it), append it in the `CustomShaderCompiler` prefix builder right after the `FractalFormulaCommon.h` concat site. `.threshfx` authors then call `boxFold`/`sphereFold`/`trigPower` by name; a 15-line recipe is well under the 64 KB cap. Ship a `SampleRecipe.threshfx` building a mandelbox from `boxFold+sphereFold+deScale` as the worked example. Ops must contain no token the validator forbids (`#include`/`#import`/`@import`).

---

## 3. Catalog of centralized transforms to ship (tiered)

DE column uses the §4 helpers. Source = Mandelbulber `internalName`.

### Tier 1 — must-have cross-family primitives (ship first)

| Op | one-line math | params | DE update | source |
|---|---|---|---|---|
| `boxFold` (Tglad) | `p = abs(p+c) - abs(p-c) - p` | limit `c` (vec3) | none (`|J|=1`) | `transf_abs_add_tglad_fold` / `transf_box_fold` |
| `sphereFold` | `k=clamp(fixedR2/r2, .., maxMin); p*=k` (3-region) | minR², maxR² | `deScaleNoAdd(T,k)` | `transf_spherical_fold` |
| `deScale` | `p*=s` | scale `s` | `dr=dr*|s|+1` | `transf_scale` / `scale_with_de` |
| `rotate` | `p = R*p` | precomputed mat3 | none (isometry) | `transf_rotation` |
| `absAddConstant` | `p+=c0; p=abs(p); p+=c1` | c0, c1, axis mask | none | `transf_abs_add_constant` |
| `addCpixel` | `p += permute(c)*w` | weight vec, orderXYZ | none (translate) | `op_add_cpixel` / `transf_add_cpixel` |
| `trigPower` (bulb) | spherical power-p, `asin/atan2` | power p | `dr=pow(r,p-1)*p*dr+1` | `op_bulb_power` / `mandelbulb` |
| `diagonalSort` (menger) | branchless swap `t=0.5*(a-b-|a-b|)` | weight | none (`|J|=1`) | `transf_abs_sym3` / `transf_menger_fold` |

### Tier 2 — high-value

| Op | one-line math | params | DE update | source |
|---|---|---|---|---|
| `scale3D` | `p*=s_xyz` (anisotropic) | vec3 scale | `deScaleRatio(T,oldLen)` | `transf_scale3d` |
| `boxTiling` (domain repeat) | `p -= round(p/size)*size` | cell size, bounds | none | `transf_box_tiling4d` |
| `boxOffset` | `p = sign(p)*c + p` (axis gaps) | offset c | `deScaleRatio` | `transf_box_offset` |
| `dotFold` (Householder) | `p -= 2*max(dot(p,n),0)*n` | plane normal n | none | `transf_dot_fold` |
| `polyFoldAtan2` (kaleido) | wrap angle into `2π/N` wedge | N per plane | none | `transf_poly_fold_atan2` |
| `rotateAboutVec3` | Rodrigues, dynamic axis | axis, angle | none | `transf_rotate_about_vec3` |
| `paramRamp` (decorator) | lerp any param over `[startIter,stopIter]` | knots | n/a (feeds host op) | `transf_*_vary_v1` / `scale_vary_vcl` |
| `scaleVary` (state) | `actualScale += vary*(|actualScale|-target)` | vary, target | feeds `deScale` | `op_scale_vary` |

### Tier 3 — exotic / optional

| Op | one-line math | params | DE | source |
|---|---|---|---|---|
| `sphereFoldSmooth` | sigmoid-blended fold (crease-free) | sharpness | `deScaleNoAdd(T,t)` | `transf_spherical_fold_smooth` |
| `pNormFold` | Lp radius → superellipsoid core | exponent p | `deScaleNoAdd` | `transf_spherical_inv_pnorm` |
| `cubeSphere` | square↔circle radial warp | (fwd/inv flag) | `deScaleRatio` | `transf_benesi_cube_sphere` |
| `expFold` (soft) | `p += sign(p)*(exp2(-k|p|)-1)` | k | optional | `transf_add_exp2_z` |
| `generalizedFoldBox` | polyhedral mirror group (tet/cube/oct/dodeca/icosa) via normal tables | type + Nv tables | `deScaleNoAdd`+`deScale` | `generalized_fold_box` |
| `quaternionSquare` | `(x²-y²-z², 2xy, 2xz)`, w carried | — | `dr*=2*r` | `op_quat_square` |
| `magicFrame` fwd/back | tetrahedral basis change, fold in between | — | isometry | `transf_benesi_mag_forward/backward` |
| `scatorAdd` | non-distributive cross-coupled seed | limit | `deScaleRatio` | `transf_add_cpixel_scator` |

---

## 4. Analytic DE — per-operator rules + coexistence with numeric normals

### 4.1 The contract (centralize as exactly 3 + 1 helpers)

The whole inventory reduces every derivative update to:

- **Isometry** (rotate, reflect, abs, box/Tglad fold, diagonal swap, translate, tiling): `|J|=1` → **do not write `dr`**. This is the load-bearing simplification — most ops need zero DE code.
- **Uniform scale by s** (closing scale, re-injects the additive c-term): `deScale(T,s)` → `dr = dr*|s| + 1`.
- **Radial/sphere factor k applied to p**: `deScaleNoAdd(T,k)` → `dr *= k`.
- **Non-conformal warp** (no closed-form Jacobian): `deScaleRatio(T,oldLen)` → `dr = dr*(|p_new|/|p_old|) + 1` (Mandelbulber's `avgScale`/`box_offset` idiom).
- **Trig power** (the one op with a non-trivial dr): `dr = pow(r,p-1)*p*dr + 1`, finalize `de = 0.5*r*log(r)/dr`.

Finalize uniformly: `d = (norm(p) - shapeR) / max(dr*deScale + deOffset, 1e-6)` with `norm` selectable (Euclid / Chebyshev / cylindrical `p.zy`), per `transf_de_linear_cube`. Reserve **`fp.params[14]=deScale` (default 1.0)** and **`fp.params[15]=deOffset` (default 0.0)** as a hidden, universal Lipschitz-fudge + stepping-safety epsilon (subsumes Mandelbulb's `dBias` and the scattered hardcoded `1e-6`/`kEpsLen` guards). Default values DCE to no-ops so migration is byte-for-byte.

This shares vocabulary with the existing space-warp seam (`Shaders.metal:777`), which already multiplies a `deScale` (max singular value) — `deScaleRatio` is the in-loop analogue, so warp-DE and fold-DE finally speak one language.

### 4.2 Coexistence with current normals

Today: unwarped Mandelbox gets analytic normals via the accumulated 3×3 Jacobian in `MapWithOrbitCache` → `GetNormal` analytic branch (`Shaders.metal:1338`); **every other formula pays 3 finite-difference `_Dist` re-evals** (`GetNormal:1369`). Keep the finite-difference branch as the universal fallback. **Phase the Jacobian in later, opt-in only:**

- Add `float3x3 J; bool wantJ;` to `TransformContext`, gated behind a function-constant/template flag so the `_Dist`/shadow/AO path never allocates 9 registers.
- Each Tier-1 op contributes its local linear map: box fold = per-axis sign diagonal where folded; sphere fold = scalar `k`; rotate = `R`; scale = `s`. `normal = normalize(transpose(J) * normalize(p))`.
- Deposit into the existing `OrbitCache.jacobian/hasJacobian` slot (`Shaders.metal:1047`), which the non-Mandelbox branch currently hard-sets to identity/false (`~1263`). Widen the `GetNormal` analytic guard from `type==Mandelbox` to `cache.hasJacobian`.
- Ops with no closed-form J (trig bulb, scator, coord remaps) and any active sphere-projection/space-warp must set `hasJacobian=false` and fall through to finite diff — **never emit a wrong J**. Do this only after on-device profiling shows finite-diff normals are a real cost, and visually verify analytic == finite-diff before defaulting on.

---

## 5. DIFS primitives & hybridization (ad-hoc shaping)

A **world-space SDF-combine seam** is the cleanest insertion given that Threshold formulas are monoliths with no exposed per-iteration `aux.DE` on the dist-only path. Mandelbulber's DIFS divides `sdf/aux.DE` *inside* the loop; we instead combine **after** the DE returns, in world space. This stays Lipschitz-valid (analytic primitive SDFs are true distances, `deScale=1`; min/max of two valid DEs is a valid DE) and touches no formula.

**Seam:** add `applyShaping(d, worldP, sp)` at the tail of every `MapUnified`/`MapDistOnlyUnified`/`MapContinuousUnified` (`Shaders.metal:~790–835`), right after `applySafetyBubble` — mirror that call site.

```metal
FORCE_INLINE float sdBox(float3 p, float3 b){ float3 q=abs(p)-b; return length(max(q,0.f))+min(max(q.x,max(q.y,q.z)),0.f); }
FORCE_INLINE float sdTorus(float3 p,float R,float r){ return length(float2(length(p.xy)-R,p.z))-r; }
FORCE_INLINE float sminClamped(float a,float b,float k){ k=min(k,0.5f*max(abs(a),abs(b))+1e-4f); // keep ≤1-Lipschitz
    float h=saturate(0.5f+0.5f*(b-a)/k); return mix(b,a,h)-k*h*(1.f-h); }
FORCE_INLINE float applyShaping(float d, float3 p, ShapingParams sp){
    if(sp.mode==SHAPE_OFF) return d;
    float prim = primitiveSDF(p, sp);
    switch(sp.op){
        case OP_UNION:     return min(d, prim);
        case OP_INTERSECT: return max(d, prim);     // clip to primitive
        case OP_SUBTRACT:  return max(d, -prim);    // carve out
        case OP_SMIN:      return sminClamped(d, prim, sp.k);
        case OP_CLIP:      return max(d, dot(p-sp.planePoint, sp.planeN)); // half-space
    }
}
```

**Ship set (S-effort, exact, off-by-default-safe):** box, sphere, capped cylinder, round/square torus, box-frame (`transf_difs_box/_sphere/_cylinder/_torus/_box_frame`); the four booleans + clamped smooth-min; clipping plane / framing window (`transf_difs_clip_plane`) as a dedicated one-dot-product mode (the "cutaway" artists reach for first). **Displacement** (`d -= amp*pattern(p)`, `transf_difs` group B) ships **last, off by default, hard amp clamp + enforced march step penalty** — it is the one non-exact op that breaks the Lipschitz bound; defer until on-device-verified.

**Plumbing:** carry shaping in `FractalParams` (room exists, it's the per-frame domain-transform struct) **not** in the capped `FormulaParams[16]`. Mirror the proven space-warp ABI: a `// __CUSTOM_SHAPING__` marker + `#ifndef THRESHOLD_CUSTOM_SHAPING` so `.threshfx` authors can supply their own `primitiveSDF`. Update both `ShaderTypes.h` struct copies, add `injectCustomShaping` mirroring `injectCustomSpaceWarp` (`CustomShaderCompiler.swift:~279`), and round-trip the fields in `FractalPreset.swift` with a `FractalPresetPersistenceTests` case.

---

## 6. Coloring & orbit-trap upgrades

The carrier for everything is the `float4 colorAux` (RGB + accumulated fold magnitude) already placed in `TransformContext`/`OrbitData`/`OrbitCache` (§2). This is the single structural change that unblocks the rest, and `colorAux.w` is a natural per-pixel music tap.

1. **Carrier (S, impact 5):** add `float4 colorAux` to `OrbitData` (`FractalFormulaCommon.h:114`) and `OrbitCache` (`Shaders.metal:1032`); init in `makeEmptyOrbitCache`; copy across the bridge (`MapWithOrbitCacheUnified:1271`). GPU-only — no Swift change. Lives on the orbit path only, never `_Dist`.
2. **`foldColor()` helper, 3 modes (M, impact 5):** binary (which axis folded → `+factor.rgb`), proximity ramp `1-(limit-|z|)/limit` (banding-free), signed penetration `(|z|-limit)/(value-limit)`. Wire into `boxFold` and the Mandelbox `MAP_ITERATION_*` macros first. Source: `transf_box_fold` tri-mode color. Mode select as a function constant to DCE unused branches.
3. **Shell tag + closest-approach trap (M, impact 4):** in `sphereFold`, `+factorSp1` (inner ball) vs `+factorSp2` (annulus); a global `min(colorAux.w, dist-to-anchor)` over all iterations gives the classic smooth filament look. Anchors in `ColorSchemeParams` (CPU-animatable → music). N≤3, function-constant gated. Source: `transf_spherical_fold` / `transf_hybrid_color2`.
4. **Read seam (S, impact 4):** thread `colorAux` into `computeColorMapping` (`Shaders.metal:920`, called `1130`). Add modes: fold-RGB-as-hue, fold-magnitude, plus a `round()` posterize/contour toggle and a SET-vs-ACCUMULATE switch. Keep existing modes 0–5 byte-identical; guard new modes to fall back to trap when `colorAux.w==0`.
5. **Iteration-window gating + music hook (S, impact 3):** `[startColorIter,stopColorIter]` band; expose `colorAux.w` via a `colorMusicGain` in `ColorSchemeParams`. **Drive gain through the existing phase-accumulation/damping** (per the color-cycle-flashing memory) — never a raw per-frame audio value; default so audio-off looks identical to today.

---

## 7. Integration plan into Threshold

### Files & seams

- **New:** `Threshold/Formulas/ThresholdTransforms.h` (ops + DE helpers + `foldColor`), `Threshold/Formulas/ShapingPrimitives.h` (DIFS SDFs). Both: `#include` from `FractalFormulaCommon.h`, add `EmbeddedMetalSources.*H` entries, regenerate via `Scripts/generate_metal_embeds.sh`, append in `CustomShaderCompiler.synthesizedSourcePrefix`.
- **`FractalFormulaCommon.h:114`** — extend `OrbitData` (+`colorAux`, later +`J`/`hasJacobian`).
- **`Shaders.metal`** — `OrbitCache` (1032) +`colorAux`; bridge copy (1271); `applyShaping` tail in the three `MapUnified` variants (~790–835); `computeColorMapping` (920) `colorAux` param; widen `GetNormal` analytic guard (1338) to `cache.hasJacobian`; `// __CUSTOM_SHAPING__` marker (~330).
- **`ShaderTypes.h`** — `ShapingParams` into both `FractalParams` copies; reserve `params[14]/[15]` as hidden DE knobs.
- **`CustomShaderCompiler.swift`** — prefix-builder gains the two new header concats; add `injectCustomShaping` (~279).
- **`FractalFormulas.h:48/76`** — dispatch unchanged; thin `DE_<Name>`/`_Dist` shims preserve `// __CUSTOM_DISPATCH_*__` markers byte-for-byte.
- **`FractalPreset.swift` / `FormulaCatalog.swift`** — persist shaping fields, document slots 14–15 (`isHidden:true`).

### Migration order (strangler-fig, measure at each step)

1. Land `ThresholdTransforms.h` + DE helpers (additive, nothing migrated). Build-green.
2. Rewrite **one** formula (`BoxSphereFolder.h`) as a templated recipe; measure perf parity vs the hand-written monolith on device (Mac + Vision Pro). Confirm the compiler DCEs `ORBIT=false`.
3. If neutral, convert the remaining built-ins one at a time; otherwise stop and keep the library as embedded-path-only.
4. Add `colorAux` carrier + `foldColor` (§6.1–6.2).
5. Land `ShapingPrimitives.h` + `applyShaping` world-space booleans/clip (§5).
6. Phase-in opt-in analytic Jacobian normals (§4.2) — last, profile-gated.

### Constraints / risks the implementer must respect

- **`FormulaParams` is a fixed 16-float struct** (16-byte aligned, embedded by value in `Uniforms`/`TileUniforms`). A multi-op recipe consumes `params[]` by index with **no namespacing** — needs an offset convention before multi-op recipes collide. Do **not** grow it for shaping (use `FractalParams`).
- **No recursion in Metal** — recipes must be straight-line/unrolled; loop bounds want function constants for full unroll.
- **Inlining + function-constant DCE is load-bearing.** No opcode VM. `TransformContext` must stay register-light (~12 floats); Jacobian is opt-in only.
- **Two DE variants must stay in sync** — the template-on-`ORBIT` approach unifies them, but `_Dist` must remain literally free of trap/color writes for the shadow/AO/normal hot path.
- **Embedded path:** forbidden tokens (`#include`/`#import`/`@import`), 64 KB cap; reusable ops reach authors **only** via the compiler prefix; **regenerating `EmbeddedMetalSources.swift` is mandatory** (known repo footgun); markers must survive strip/concat (`missingDispatchMarker`).
- **Preset persistence has silently dropped fields before** — any new persisted shaping/recipe field needs a round-trip test. Recompiled custom-recipe PSOs can't serialize to the binary archive (no `MTLLibrary.write`) — they recompile each launch; accept that.
- **Param-node system:** per-stage music/gesture binding multiplies param-node count against the `ParameterCatalog` addressable budget — verify before exposing a multi-stage UI.
- **Perf:** per repo policy, cite **no** repo perf numbers as evidence; every claim ("removes 3 normal evals", "neutral recipe perf") requires a fresh on-device measurement.

---

## 8. Prioritized roadmap

| Item | Effort | Impact | Depends-on |
|---|---|---|---|
| **Quick wins** | | | |
| `ThresholdTransforms.h` spine: `TransformContext` + signature | S | 5 | — |
| 3+1 DE helpers (`deScale`/`deScaleNoAdd`/`deScaleRatio` + finalize) | S | 4 | spine |
| Ship 8 Tier-1 ops as `FORCE_INLINE` | M | 5 | spine, DE helpers |
| Inlined recipe rewrite of `BoxSphereFolder` (proof + perf gate) | S | 4 | Tier-1 ops |
| Library as embedded-DE prefix + `SampleRecipe.threshfx` | S | 4 | spine, generate_metal_embeds |
| Reserve `params[14]/[15]` deScale/deOffset knobs | S | 3 | DE helpers |
| `colorAux` carrier in OrbitData/OrbitCache + bridge | S | 5 | — |
| `computeColorMapping` read seam (+posterize, SET/ADD) | S | 4 | colorAux carrier |
| **Medium** | | | |
| `foldColor()` 3-mode helper, wired into box/sphere folds | M | 5 | colorAux, Tier-1 ops |
| Shell tag + closest-approach trap | M | 4 | colorAux |
| `applyShaping` world-space seam + 5 exact DIFS primitives + booleans/clip | S | 5 | — |
| `ShapingParams` plumbing (FractalParams + `__CUSTOM_SHAPING__` + persistence test) | M | 4 | applyShaping |
| Tier-2 ops (scale3D, tiling, dotFold, polyFold, paramRamp, scaleVary) | M | 4 | Tier-1 ops |
| Iteration-window color gating + damped `colorMusicGain` | S | 3 | foldColor |
| Migrate remaining built-ins to recipes (one at a time, perf-gated) | M | 4 | BoxSphereFolder proof |
| **Big bets** | | | |
| Opt-in analytic Jacobian → analytic normals for all recipe formulas | L | 4 | recipes, profile evidence |
| Tier-3 exotic ops (generalizedFoldBox, magicFrame, pNorm, smooth fold, scator) | L | 3 | Tier-1/2 ops |
| Declarative `.recipe` EffectKind + reorderable operator-stack UI | L | 4 | recipes, param-node budget |
| Displacement shaping (off-by-default, step-penalty, device-verified) | M | 3 | applyShaping, on-device QA |

---

## 9. Risks & open questions

1. **Param-slot allocation/namespacing.** Recipes index `fp.params[16]` with no convention; the 16-float cap is the binding constraint. Need an operator-declares-base-offset scheme before multi-op recipes collide. **Recommend:** ship single-op-per-formula recipes first; design the offset convention before any UI stack.
2. **Does Metal fully DCE the `ORBIT=false` template branch?** The whole "`_Dist` stays literally free of trap/color writes" guarantee rests on this — verify generated assembly / on-device perf before converting beyond BoxSphereFolder.
3. **Migrate all built-ins at once or strangler-fig?** Recommend one (BoxSphereFolder) as proof, measure parity, convert the rest **only if neutral**.
4. **Fixed per-iteration op sequence vs per-iteration variation?** Mandelbulber gates each op by `[startIter,stopIter]` (cheap, one compare, high-variety). Decide whether to bake iteration-window gating into the recipe loop now or defer.
5. **Normals at boolean/clip seams.** Finite-difference normals on a flat cut face are noisy; when a primitive or clip plane wins the combine, special-case `GetNormal` to return the analytic primitive/plane gradient. Needs a per-pixel "which term won" flag threaded out of `applyShaping`. Recommend yes for clip planes.
6. **Coloring of carved/clipped regions.** Subtract/clip exposes interior with no orbit-trap history — tag primitive-won pixels with a dedicated material (DIFS "winner-take-all color"), or reuse the fractal trap at the cut point.
7. **World-space vs folded-space shaping.** World-space single-solid shaping (primitives don't inherit fractal fold symmetry) is the deliberate S-effort artist model; folded-space DIFS is a much larger change needing per-formula `aux.DE` exposure. Ship world-space; document the choice.
8. **smin / safetyBubble / sphere-projection interaction.** Verify the clamped-`k` smin doesn't overstep at grazing angles when stacked with the existing safety-bubble + projection deScale chain; run `applySafetyBubble` before shaping so a carved region isn't re-inflated.
9. **Per-stage music/gesture binding** may push total param-node count past what `ParameterCatalog` projections can address without a registry change — budget before building the stack UI.
10. **Repo perf numbers are fabricated** (per memory) — do not cite any existing number as evidence for any item above; demand fresh on-device measurement for every perf-sensitive decision (recipe parity, normal-eval savings, displacement step penalty, struct-size/alignment on Mac + Vision Pro).
