# Threshold — Consolidation Architectural Review (2026-07-11)

Companion to [`../TECH_DEBT.md`](../TECH_DEBT.md), [`TECH_DEBT_AUDIT_2026-07-07.md`](TECH_DEBT_AUDIT_2026-07-07.md),
and [`CLEANUP_AUDIT.md`](CLEANUP_AUDIT.md). Method: five parallel subsystem reviews
(rendering, UI layer, parameters, audio/platform, formulas+gestures+animation) over the
current tree, cross-checked against the existing registers. Scope is **consolidation** —
duplication, parallel implementations, incomplete migrations — not bugs or perf.

## Executive summary

The dominant finding is not missing design — it's **incomplete migration to designs that
already exist in the tree**. Five convergence abstractions were built, proved out, and then
stopped partway:

| Abstraction | Where it's adopted | Where it's bypassed |
|---|---|---|
| `ControlCatalog`/`ControlSpec` (range/default SSOT) | 31/63 controls; ColoringTab grading sliders | UI re-types ~50 literal `range:` args (FractalTab sources 2/30 from catalog) |
| `.moduleCard()` / `ModuleSectionView` | 7 sites in EffectsTab | 31 hand-rolled card wrappers (SettingsTab 12, FractalTab 9, ColoringTab 5, Transform sections 5) |
| `UniformsBuilder.assembleUniforms` (done 2026-07-10) | all 3 render paths | ~8 sibling triplications left behind (horizon math, proxy mesh, function-constant indices, …) |
| `KeyframeLerp` statics (done) | both interpolation paths | the two ~35-field keyframe enumeration sites still hand-listed twice |
| Shared-Core-file pattern (`RendererMath` etc. compiled into QL targets) | RenderPrecompute, UniformsBuilder, CustomShaderCompiler | `HeadlessRenderer` keeps local `hr_*` copies of math that's already linked in |

The strategic constraint from TECH_DEBT #16 still holds: **big in-place architecture
refactors stay parked pending the rebuild go/no-go**. Everything in Tier 1–2 below is
deliberately *not* that — mechanical, seam-local consolidation that pays off on either path.
Tier 3 items are the rebuild-shaped ones; they're listed so they don't get done twice.

---

## Tier 1 — mechanical, behavior-preserving, single-sitting each

### 1.1 UI: finish the ControlCatalog + moduleCard migrations (highest leverage/risk ratio)
- Swap literal slider ranges for `ControlCatalog.X.range` wherever a spec exists.
  Evidence of live drift risk: `ControlCatalog.safetyBubbleRadius.range = 0.5...2.5`
  (`ControlSpec.swift:139`) vs the same literal re-typed at `ContentView+FractalTab.swift:387`;
  `spaceWarpOriginX` range re-declared at `TwistShapingSection.swift:23`. This is the exact
  fractalScale drift bug the catalog was created to kill (`ControlSpec.swift:11-15`).
- Replace the 31 raw `.padding(10).background(RoundedRectangle…)` wrappers with
  `.moduleCard(accent)` (`ModuleSectionView.swift:30` documents the box was "copy-pasted ~15×").
  Don't force-fit sections with bespoke inner controls (Safety-Bubble shape grid, platonic
  buttons) into `ModuleUISection` — those stay hand-rolled or get an `extraContent` escape hatch.

### 1.2 Rendering: extract the triplicated horizon/`maxViewDistance` derivation
The zoom-adaptive trace-horizon computation (Kleinian branch, `traceScaleFloor`, caps
420/80/880, divisor-floor guard) is hand-copied byte-identical into all three paths:
`RaymarchRenderView.swift:1675-1708`, `RendererGameState.swift:215-258`,
`HeadlessRenderer.swift:75-91` (~95 lines). Comments literally say "mirrors the Mac guard".
This is the same disease as Uniforms #2, which bit three times in three days before it was
unified. Move: `RenderPrecompute.horizonTargetDistance(settings:effectiveScale:smoothedScale:cameraWorldPos:)`
returning the pre-smoothing target; callers keep their own smoothers. `RenderPrecompute`
is already compiled into every target.

### 1.3 Rendering: shared proxy mesh + delete redundant QL math copies
- The radius-100 ellipsoid proxy + `MTLVertexDescriptor` are built three times byte-identical
  (`Renderer.swift:790-871`, `RaymarchRenderView.swift:1893-1934`, `HeadlessRenderer.swift:233-273`).
  One `RaymarchProxyMesh` enum in a dependency-free Core file.
- `HeadlessRenderer.swift:28-54` `hr_translation`/`hr_scale`/`hr_matrix4x4` duplicate
  `RendererMath` functions **that are already compiled into the QuickLook targets**
  (pbxproj verified). Delete the local trio.

### 1.4 Rendering: un-trap `FunctionConstantIndex` (genuine drift hazard)
The function-constant index map is an enum on visionOS (`RendererCoreTypes.swift:16-36`) but
that file starts with `import CompositorServices`, so the Mac path re-encodes indices
`0,2,3,6,7,9,11,12,16,17,18` as bare literals with a keep-in-sync comment
(`RaymarchRenderView.swift:1154-1191`). Indices 16 (`hasEnvScrunch`) and 18 (`hasHandField`)
are days old — this is the #19 comment-lockstep disease at higher blast radius. Move the
enum (plus `FragmentTextureIndex`/`BufferIndex` if similarly trapped) into a
dependency-free shared file; Mac uses `.rawValue`.

### 1.5 Parameters: three deletions
- **`ParameterPipeline` is a 47-line pass-through** (`ParameterPipeline.swift:5-47`) — holds
  one dispatcher, forwards 1:1, stores no state (the comment claiming it holds layer-stack
  state is wrong; that's the dispatcher's `_state` Mutex). Callers already reach past it in
  3 places. Either delete it or make it the only entry point — the half-facade is the worst option.
- **`ParameterRoute` is fully vestigial**: `route: nil` at all 16 descriptors, zero non-nil
  (`ParameterCatalog.swift:81-93`). This is parked Slice 8 (#11); delete the field until the
  rebuild call rather than keeping an always-nil trap.
- **Redundant re-clamps in the 9 config projections**: e.g. the `qualityConfig` setter calls
  `newValue.clamp()` at `RenderSettings.swift:4274` then re-clamps per-field at
  `:4280-4299` duplicating `QualityConfig.clamp()` verbatim. Keep the single `clamp()` call.

### 1.6 Formulas: collapse the dual default-value sources
Per-param defaults live in **both** `catalog.json` and each descriptor's hardcoded
`defaultFormulaParams()` (e.g. `MandelbulbDescriptor`, `FractalTypeDescriptor.swift:328-333`)
— and the two are read by *different* code paths (`FractalModelType.swift:47-52` prefers
catalog; `RenderSettings.swift:1088` calls the descriptor directly). Verify equality
per-type, then delete the descriptor overrides for catalog-backed types and route all
callers through `FormulaCatalog.buildParams`. A silent mismatch here changes a preset's look.

### 1.7 Small shared helpers (batch into one sitting)
- `fps → Color` implemented 3× with divergent bands (`ContentView.swift:404`,
  `ContentViewComponents.swift:452`, `:556`) → one `PerfColor.forFPS(_:)`.
- The `.onChange(of: scenePhase)` lifecycle block copy-pasted into all three app entry
  points (`MetalProjectApp.swift:212-232`, `ThresholdMacApp.swift:36-47`,
  `ThresholdiOSApp.swift:17-26`) → one modifier with a `keepActiveInBackground` flag.
  (The rest of the entry points is intentionally platform-specific — `MenuChrome.swift:7-12`
  documents that decision; leave it.)
- `Divider().padding(.leading, 159)` ×12 hand-derived from `EffectSliderRow`'s internal
  geometry → fold the inset into the row component.
- `MetalFXManager.minimumInputShortEdge = 128` (`MetalFXManager.swift:47`) duplicates
  `MetalFXTextureSupport.minimumInputShortEdge` → reference the shared constant.
- reduceMotion animation helper ×2 (`ContentView.swift:411`, `ThresholdMacApp.swift:337`).
- Euler↔quaternion math living in a view file (`ContentView+FractalTab.swift:1310-1341`)
  → move beside `GeometryConfig`'s quaternion handling; becomes testable.

---

## Tier 2 — structural but self-contained (1–3 days each)

### 2.1 Merge the Apple Music adapter pair (the CLEANUP_AUDIT headline theme — still open)
`AppleMusicServiceAdapter.swift` (182 ln) vs `…Mac.swift` (162 ln): ~65-70% identical;
only 4 methods genuinely diverge (`nowPlaying`, `seek`, `playSongByNativeID`, `searchTrack`).
Two enabling normalizations delete the rest of the divergence: make the iOS
`AppleMusicManager` methods `async` (it's already `@MainActor`; callers all go through the
async protocol) and expose `String` IDs at its boundary. Result: one file, ~200 lines, ~30
platform-conditional. Bonus: kills the pbxproj-membership fragility — today the non-Mac
files are excluded from the Mac target *only* by the membership list
(`project.pbxproj:295-296,317-318`), and the class body is `#if`-unguarded; one accidental
re-add breaks the Mac build. Follow-up: shrink `AppleMusicManagerMac` (122 ln of
protocol-shaped stub duplicating struct shapes) behind a small backend protocol.

### 2.2 Generic coalesced-dispatch: `ParameterUpdateCoordinator` + `UIUpdateCoordinator`
Two parallel implementations of "rate-limited, coalesced, batched MainActor dispatch"
(~60% structural overlap: `State` + `Mutex` + `shouldDispatch` + drain). Extract
`CoalescedMainActorDispatcher<Work: Sendable>`; each coordinator supplies payload,
intervals, and apply-handler.

### 2.3 Gestures: one engine contract, one menu-toggle owner
- Two conventions coexist: engines that own their logic (`PerFingerTapGestureEngine`,
  `MenuToggleGestureEngine` — `process(context:) -> [GestureOperation]`) vs dumb state bags
  (`ModeGestureEngines.swift`, 28 lines) whose math lives in `GestureController`, reached
  through bridge properties (`GestureController.swift:101-114`); a sixth gesture is a bare
  struct on the controller. Define one `GestureEngine` protocol, move the mode-engine math
  out of the controller, drive from one loop — directly shrinks the 1161-line controller.
- Menu toggle is owned by two engines with dedup glue (`GestureController.swift:216-243`
  `didToggleMenu`; `PerFingerTapGestureEngine.swift:216-224` strips `.toggleMenu` so it
  "does not compete"). Fold the three `MenuToggleGestureMode` detections into the
  per-finger engine as composite tap sources, then delete `MenuToggleGestureEngine`
  (~200+ lines). ⚠️ This is the primary menu-recovery path with tuned
  thresholds/deadzones — preserve them exactly; it needs manual on-device verification.

### 2.4 Animation: table-drive the two keyframe interpolators
`AnimationKeyframe.interpolated(to:t:)` (`AnimationTypes.swift:340-399`) and
`KeyframeLerp.interpolateKeyframes` (`:1064-1144`) each hand-enumerate ~35 fields; adding
an animatable field means editing both, and they've already drifted (`musicReactiveConfig`
assigned twice in the spline path at `:1122`/`:1142` — fix regardless). Extract a per-field
policy table (linear/slerp/discrete@0.5/optLerp) folded by both entry points with the
scalar interpolator injected.

### 2.5 Rendering: pipeline-descriptor + readback helpers
- The `screenshotVertexShader`+`fragmentShaderMono` render-pipeline descriptor is built at
  5 sites (`RaymarchRenderView.swift:1831,1201`; `HeadlessRenderer.swift:246,353`;
  `RendererScreenshot.swift:40` — that one stereo). One parameterized factory.
- The proxy-draw encode (×3) and "alloc + encode + readback BGRA" (×3, ~120 lines) share a
  core; consolidate the encode + `getBytes` only — the commit/wait policy genuinely differs
  (visionOS async handler vs blocking Mac/QL).

### 2.6 Shaders: one `deFamily(type)` classification
Per-type classification lists are hand-synced in 3–4 parallel switches
(`relaxedOmegaCap` `Shaders.metal:2392-2408`, `coneSafetyForFamily` `:3830`,
`ReducedSecondaryIterations` `:2385`) and `validateRegistry` explicitly doesn't cover them
(`FractalTypeDescriptor.swift:226-249`). Derive membership from a single family function
keyed off a catalog field — first slice of formula codegen that doesn't need the rebuild.

### 2.7 RenderSettings: shrink without splitting (`@Locked` wrapper + generated projections)
The god object (4,592 lines) is ~249 hand-written `var x { get { withLock { _x } } set … }`
triples plus 9 ~35-line mechanical config-projection pairs. A property wrapper (or
lock-borrowing `LockedBox`) + code-genning the projections off the Config structs would cut
the file ~30-40% **without** the parked #12 split. ⚠️ Constraint: must preserve the single
shared `os_unfair_lock` (not per-field locks) or `snapshot()`'s all-fields-consistent read
breaks; sequence with the #6 concurrency audit.

---

## Tier 3 — rebuild-gated (do NOT do in place; per TECH_DEBT #16 parking rule)

These are exactly the seams `REBUILD_ARCHITECTURE.md`'s ParameterCatalog + Modulation
Engine + Shader IR dissolve. Recorded here so effort isn't spent twice:

- **Parameter-system convergence.** Current reality: a **5-hop value pipeline**
  (Config struct → UISettingsCache → dispatcher/node stack → RenderSettings locked field →
  snapshot), **3 serialization shapes** (Config JSON, FractalPreset's 105 flat fields,
  Module blocks), and **4 range authorities** (ControlCatalog, FormulaCatalog,
  `GestureParamRanges`, per-setter literals). `Module`/`ModuleRegistry` is a third
  per-parameter write-path declaration adopted for only 2 of 7 domains, consumed only by
  FractalPreset. Merging Module writers into ParameterCatalog and embedding Config structs
  in FractalPreset are on-disk-format-sensitive — gate behind round-trip tests (#3).
- **Animation per-parameter registry.** One animatable field = ~46 sites across 9 files
  (measured for `colorSchemeSaturation`). This is the rebuild's Modulation Engine pitch.
- **Full formula codegen.** Adding a static formula touches ~7 files/~10 sites; the
  `.threshfx` path already proves the injection-marker approach
  (`FractalFormulas.h:64,92`). 2.6 is the safe first slice; the rest is rebuild-shaped.
- **AppModel decomposition.** Second god object (~1,850 lines with extensions, ~67 stored
  props): service locator + windowing + import state machine + lifecycle. The extension
  seams (`+ExternalImport`, `+SceneLoading`, menu-window state) are the natural
  coordinator boundaries when the time comes.
- **True RenderSettings split** (#12) and **sphere-system unification** (#10) — unchanged,
  parked.

One quick Tier-1-adjacent guard worth doing now: add `GestureParamRanges.fractalScale` to
the startup routing `precondition` drift check (`ParameterTargetID.swift:56-101`) — same
bug class ControlSpec already solved once, one line of validation.

---

## Product decisions (not cleanup)

- **SharePlay backend** (`Collaboration/`, ~380 lines + GroupActivities dep): confirmed
  half-inert — it can receive/apply sessions, but `startSharing`/`sendStateUpdate` are
  never called and no view exposes it. Documented as intentionally dormant
  (`ContentViewHelpers.swift:31-33`). Keep or delete is an owner call; deletion is fully
  recoverable from git.
- **Buddhabrot** is a genuinely independent second render stack (zero shared symbols with
  the main renderer — verified). Keeper per TECH_DEBT. Only worthwhile shared seam: a tiny
  `makeComputePipeline(device:library:name:)` helper (duplicated at
  `RendererPipelineCache.swift:890`), plus optionally generating
  `BuddhabrotSettingsSnapshot` from `BuddhabrotSettings` (same 30 fields declared twice).

## Register reconciliation (stale entries found this review)

- `CLEANUP_AUDIT.md` Tier 1 gestures block is **done**: `GestureFeatureFlags`, the dead
  controller menu-toggle path, `GestureContext.ranges`/`.frameIndex`, vestigial
  `GestureOperation` cases, `legacyPersistenceKey`/`legacySlots` — all 0 hits in the tree.
  What remains in menu-toggle is the *live* two-engine overlap (Tier 2.3), a different item.
- `KeyframeLerp` consolidation (CLEANUP_AUDIT Tier 2 theme): **done**; the residual is the
  two field-enumeration sites (Tier 2.4).
- TECH_DEBT #18 (EnvironmentSDF tests): the 07-07 audit already recorded it done;
  the main register still lists it OPEN — fold the closure in.
- No new dead rendering code found; the previously-flagged "dead motion-vector proxy block"
  is confirmed live (feeds `t_pred`).

## What NOT to consolidate (verified intentional)

- The three app entry points' window/scene structures (documented, `MenuChrome.swift:7-12`).
- Large single-branch `#if os(X)` blocks (measured: the big forks are platform-exclusive
  implementations, not duplicated near-twins — e.g. `RaymarchRenderView.swift:1937-2143`
  iOS-only host, `MusicTabView.swift:812-940` macOS-only capture UI).
- `RenderKitStubs.swift` (deliberate QL dependency-avoidance, self-documented).
- The Mac vs Vision Pro benchmark systems (offscreen matrix vs on-device sweep — different
  measurements sharing `BenchmarkManager` primitives).
- Analytics/: all six files live, no dead weight.
- `UniformsBuilder.warmStartEnabled: 0` is not vestigial (visionOS overwrites post-assembly).
