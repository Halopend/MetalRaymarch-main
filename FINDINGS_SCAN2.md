# FINDINGS — Scan 2 (post-fix sweep)

Second defect-oriented pass over `Threshold`, run after the large fix batch that
followed `FINDINGS.md` (commits `374869d1` … `69c69b8f`). That batch maps almost
1:1 onto the original report — H1/H3/H5/H6/H7/H8/H9/H10 plus most of M1–M41 —
so **`FINDINGS.md` is now substantially stale**: treat its High/Medium lists as
"fixed, pending verification" rather than open.

This file records only what is **new or still open** after that batch.

**Severity**: `Critical` = crash/data-loss/security · `High` = visible malfunction
or freeze · `Medium` = degraded/stale/lost behavior · `Low` = minor or latent.
**Confidence**: `verified` = traced line-by-line · `likely` = mechanism
confirmed, trigger not reproduced.

Sources: a direct pass on the newest commits (`6e944732`, `9f6701f4`,
`69c69b8f`) plus three delegated regression reviews of the fix batch. Every
High/Medium below was re-checked against current file contents.

---

## HIGH

### N1. Async removal sweep can delete the newest same-id file ✓ verified
`Threshold/Parameters/PresetManager.swift:846-850` (`writePresetFile`) →
`:887-906` (`removePresetFiles`).

`writePresetFile` writes the replacement, then calls
`removePresetFiles(id:root:excluding:[writtenURL])`, which now spawns
`Task.detached` (`:892`). That sweep deletes **every** enumerated file decoding
to `id` except the single URL passed by *that* call. With overlapping writes
whose filename changes (rename, or `hasMusicReactiveMappings` toggling
`Scenes/` ↔ `Music Presets/`), save N's still-running sweep sees save N+1's
freshly written file, never finds it in N's `excluding` set, and `removeItem`s
it. `persist` already returned `.saved`, so the UI reports success while the
current file is gone; the next folder-truth scan drops the preset or keeps a
stale duplicate.

Fix: make the sweep ordering-safe — delete only files older than the kept URL
(compare `contentModificationDate`), serialize via an actor holding the current
path per id, or keep local removal synchronous (only decode needs off-main).

### N2. Delete skips iCloud placeholders → deleted presets resurrect ✓ verified
`PresetManager.swift:898` + `:918-924` (`isUnmaterializedPlaceholder`),
re-inserted by the scan reuse branches `:560-565` and `:602-606`.

When the store file is a dataless iCloud placeholder, `removePresetFiles`
`continue`s without deleting. On the next scan the file still
`requiresHydration`; with `canProbe` false, the
`if let cached { byID[...] = ... }` branch (`:602-606`) re-inserts the deleted id
from the request cache — the exact resurrection `06c11db0` set out to stop.

Fix: don't skip placeholders on the remove path (`removeItem` on a dataless file
is safe and propagates the iCloud delete), or match
`id.uuidString.prefix(8)` against `sanitizedFileName` (`:313-314`). Keep the
placeholder guard only for read/decode sweeps.

### N3. Spatial upscaler rebuilds the same key twice on every pool miss ✓ verified
`Threshold/Rendering/ViewportSpatialUpscaler.swift:157-165` (`prepare`) +
`:201-213` (`drainBuilds`).

On a miss, `prepare` sets `s.wanted = key` unconditionally. While the 0.2–2 s
`makeSpatialScaler` build for K is in flight, each render frame calls
`prepare(K)`, finds no entry, and re-sets `wanted = K` (`draining` is already
true, so no new drain starts). When the build publishes `entries[K]`, the drain
loop immediately re-locks, still sees `wanted == K`, and builds K a **second**
time. The temporal sibling has the missing guard
(`ViewportTemporalUpscaler.swift:218-226`: `if s.inFlight == key { s.wanted = nil }`),
which this port dropped. Trigger: any first-time/new size — every Render Quality
drag step, every resize. Effect: doubles blocking builds on the single private
queue, and the next size change queues behind the stale duplicate, so the
direct-full-resolution fallback lasts ~2× longer — exactly the hitch the commit
(`69517675`) set out to remove.

Fix: add `State.inFlight: Key?`, set it when the drain takes `wanted`, clear it
after publish; in `prepare`'s miss branch, if `s.inFlight == key` clear `wanted`
instead of re-setting it.

---

## MEDIUM

### N4. Browse-tab prewarm double-compiles the formula being prewarmed ✓ verified
`Threshold/Rendering/Core/CustomShaderCompiler.swift:156-199` (the `library(...)`
cache) + `:216-223`, reached by the new prewarm path
(`RaymarchRenderView.swift:120-130`, `RendererCustomShader.swift:185-194`,
driven by `FractalGridView.swift:304-317`).

`library(...)` only populates `libraryCache` **after** the Metal compile's
continuation resumes. The compiler is an `actor`, so while a prewarm compile is
suspended at `withCheckedThrowingContinuation` (`:174-188`) the actor is free —
a second caller with the **same key** re-enters, finds `libraryCache[key] == nil`,
and starts a second full compile of the ~400 KB source.

Trigger: the browse `.task` is serially prewarming formula A (~26–33 s) and the
user taps A. The activation path calls the same key; prewarm has not cached yet,
so the tap pays a *fresh* compile **and** both run concurrently (doubling peak
Metal work). The stated guarantee — "tapping a prewarmed scene skips the
~10–40 s compile" — fails in exactly the case it was built for, and the `.task`
comment "Serial on purpose (one compile at a time)" is false. On Mac the same key
can also be prewarmed by two browse surfaces (`ContentView` is instantiated
twice — slide-over + detached window, `ThresholdMacApp.swift:136/795`).

Fix: keep an in-flight `[String: Task<MTLLibrary, Error>]` in
`CustomShaderCompiler`; on a cache miss join an existing task for `key` instead
of starting a new compile, and clear the entry in a `defer`.

### N5. visionOS hides the Mixed browse section from the primary navigation rail ✓ verified
`Threshold/App/ContentView.swift:65-66` + `:227-232`.

`ContentView` holds the gate as
`@AppStorage(MixedRealitySceneCatalogSettings.defaultsKey) var includesMixedRealityScenes = false`
and passes that raw value into `NavigationAvailability.resolve(...)`, which drops
the `.mixed` rail section when false (`NavigationHierarchy.swift:136-147`). On
visionOS the Settings toggle that writes this key is compiled out
(`#if !os(visionOS)`, `ContentView+SettingsTab.swift:249-296`) and nothing else
writes it, so the value is **always false** there. visionOS uses `ContentView`
(`MetalProjectApp.swift:120`), so Mixed disappears from the rail on the exact
platform it is authored for. Every other consumer already handles visionOS:
`MixedRealitySceneCatalogSettings.includesScenes` returns `true`
(`SceneTags.swift:23-29`) and drives the catalog (`PresetManager.swift:414/438`),
animation lists (`AnimationManager.swift:553`), the radial menu
(`RadialMenuProjectionFactory.swift:32`), the spatial menu
(`SpatialRadialMenuView.swift:16/68`), the renderer (`Renderer.swift:728`), and
the browse tab (`FractalGridView.swift:403`); `NavigationStore.canonical`
retains `.explore(.mixed)` (`NavigationStore.swift:379/453`). A persisted Mixed
route is therefore offered everywhere *except* the rail.

Fix: pass `MixedRealitySceneCatalogSettings.includesScenes` at
`ContentView.swift:231`, or force it true in `NavigationAvailability.resolve`
when `profile.platform == .visionOS`.

### N6. Radial projection memo key omits the Mixed-scene opt-in → stale menu ✓ verified
`Threshold/App/ThresholdMacApp.swift:1079-1086` (key) + `:1110-1117` (struct).

`RadialProjectionCacheKey` does not include
`MixedRealitySceneCatalogSettings.includesScenes`, but the factory feeds it into
the hierarchy (`RadialMenuProjectionFactory.swift:32`) where it changes tree
structure (`NavigationHierarchy.swift:140`), and the setting is documented as
reading `UserDefaults` live precisely so projections stay current after the
toggle flips. On macOS, flipping Settings → Display → "Vision Pro Mixed Scenes"
leaves the key unchanged, so the cached projection is served and the Mixed
Explore entries never appear/disappear until route/fractal/`transformRevision`/
profile changes. Before `032147c1` every body eval rebuilt, so this is a
regression. Fix: add the flag to the key (and struct).

### N7. Normals still run the full baked iteration count (M10 half-fixed) ✓ verified
`Threshold/Rendering/Shaders.metal:1964` (`Map`) and `:2170` (`MapUnified`),
called with the reduced count from `:2702`, `:2747`, `:2769`.

Both `Map` and `MapUnified` override their `iterations` argument with
`is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations`.
`136397c8` fixed the shadow/AO path by baking a reduced **`FC_SHADOW_ITERATIONS`**
(honored at `:2185` and in `MapDistOnly`), but there is no `FC_NORMAL_ITERATIONS`,
so on every specialized pipeline (where `FC_FRACTAL_ITERATIONS` is always set) the
normal probes march full iterations and the
`normalIters = ReducedSecondaryIterations(..., forShadow: false)` argument is dead.
Corroboration: the helper's `forShadow: false` branch
(`RenderPrecompute.swift:21`) has no callers — all six call sites pass `true`.
Trigger: every shaded hit pixel (only fully avoided when the analytic-Jacobian
normal path is available). So ~2.5× the designed normal cost of `FINDINGS.md` M10
survives. Fix: bake `FC_NORMAL_ITERATIONS` from
`reducedSecondaryIterationsForShader(..., forShadow: false)` and honor it in the
normal path, or add a forced-runtime-count variant of `Map`/`MapUnified`.

### N8. A finishing hand-tracking dispatch can nil its successor's slot ✓ verified
`Threshold/Rendering/Core/RendererFrameLoopHelpers.swift:134-137` + `:196-198`;
`Renderer.swift:328-332`, `:706`.

The detached task's `defer` runs `finishHandTrackingDispatch()` (sets
`inFlight = false`, `:190-194`) and then `clearHandTrackingDispatchTask()` (sets
`handTrackingDispatchTask = nil`, `:196-198`) *unconditionally*. The render thread
starts a new dispatch whenever it observes `inFlight == false` (`:106-115`) and
assigns at `:186`. Between the two defer calls the render thread can start
dispatch N+1 and assign its task; N's clear then wipes N+1's slot, so `deinit`'s
`handTrackingDispatchTask?.cancel()` (`Renderer.swift:706`) misses N+1 — which
strongly retains `appModel`/`gestureProcessor` (`:127-130`) and can still hop to
the MainActor and mutate UI state after teardown. The Mutex fix (`094fa8d4`) made
M9 memory-safe but not logic-safe. Fix: clear the slot only if it still holds the
finishing task (task identity or a generation token).

### N9. Prewarm keys ignore the `deIterationMismatch` bias → cache miss on visionOS ✓ verified
`FractalPreset.swift:1080` (`pipelineCacheKey`: `FI\(fc.fractalIterations)`),
`RendererPipelineCache.swift:317-358` / `:812+`, `Renderer.swift:773-782`
(the prewarm paths) versus the live lookups at `Renderer.swift:1559/1567` and
`:2644`.

`094fa8d4` biased the **live** iteration count for both fragment and compute
(`fractalIterations + deIterationMismatch`) so the control is no longer a no-op on
Vision Pro, but `pipelineCacheKey`, `getPipeline(forIterations:)`, and
`prewarmComputePipeline(forPreset:)` still key on the raw count. Before that
commit both sides were raw and agreed. Trigger: applying or slider-prewarming any
preset with a nonzero Sphere Projection Mismatch (range −8…8, default 0, exposed
on visionOS). Effect: the prewarmed pipeline is never hit (wasted compile and
memory) and the correctly biased one compiles on demand → generic-pipeline frames
and a possible hitch. Fix: share one `effectiveGeometryIterations` helper (as at
`RaymarchRenderView.swift:1431`) across the live and prewarm key paths.

### N10. Deletes are no longer durable across quit ✓ verified
`PresetManager.swift:1311-1313`, `:1335`.

Removal is a detached, un-awaited `.utility` task and nothing flushes it in
`AppModel.saveLastState` (`AppModel.swift:921-933`, which flushes
`SettingsPersistence` and `AnimationManager` only). A quit/kill — or any visionOS
SIGKILL — right after a delete leaves the file behind, and the next launch scan
resurrects it. Same for rename cleanup. Fix: delete synchronously at the delete
site, or flush/await the removal task from `saveLastState`.

### N11. `pendingRootDeletions` poisons a re-added id ✓ verified
`PresetManager.swift:1317`, `:1337` (insert); `:985-987` (filter); `:946-965`
(flush).

No save/import path ever removes an id from `pendingRootDeletions`. If the id is
re-created while the root is unresolved (`importPreset` → `persist` stores
`pendingRootWrites[id]`, `:929`), the unresolved branch filters it out of the UI,
and on `rootResolved` `flushPendingRootWrites` writes the file and then runs the
deletion sweep that deletes it. Fix: clear the id in
`persist`/`importPreset`/`replaceAll`.

### N12. Same-id import silently clobbers a newer local edit (M20 fix incomplete) ✓ verified
`PresetManager.swift:1388-1419`.

Keeping the file's `updatedAt` fixes cross-device propagation, but a same-id
import still unconditionally does `presets[existingIndex] = preset` +
`persist(preset)`. The comment's "the local edit wins the merge" is false: after
persist the newer local value no longer exists on this device, so unless iCloud
holds a newer copy the edit is lost. `FINDINGS.md` M20's `max(existing, file)` /
prompt behavior is not implemented. Fix: skip or prompt when
`existing.updatedAt > preset.updatedAt`.

### N13. Gesture-sensitivity debounce has no lifecycle flush → last edit lost ✓ verified
`Threshold/Parameters/GestureSensitivityStore.swift:78-87` defers the only
`save()` (`:89-94`) by 300 ms; `setSensitivity`/`resetSensitivity` (`:63`, `:71`)
no longer persist synchronously, and the store exposes no flush API —
`AppModel.saveLastState` (`AppModel.swift:921-933`) has no hook for it. Trigger:
drag a per-parameter sensitivity slider (`FormulaParamsEditor.swift:354/364`) and
quit/kill within 300 ms. The coalescing commit's "final value always persists"
does not hold. Fix: add `flushPendingSave()` (cancel task, `save()`) and call it
from `saveLastState()`.

### N14. GPU-cap truncation counts disabled ops, dropping enabled transforms ✓ verified
`RenderSettings.swift:798` applies `spaceWarpOpsFittingGPUCap(newValue)` to the
raw authored stack, but the GPU packer caps only **enabled + simplified** ops
(`SpaceWarpStackModel.swift:891`). `spaceWarpOpsFittingGPUCap` itself does not
filter (`:864-881`). Trigger: import a scene with more than `kMaxSpaceWarpOps`
ops where trailing ops are enabled and leading ones disabled (e.g. 8 disabled + 2
enabled). The setter keeps the first 8 (all disabled) and drops the 2 enabled
ops, so the model loses authored data and the renderer executes zero transforms
where it previously executed two. Fix: apply the cap to
`newValue.filter { $0.isEnabled }` (simplified), or keep truncation only at
`cSpaceWarpStack`.

### N15. Immersive auto-open latch not cleared when the space is open/in transition ✓ verified
`Threshold/Views/ImmersiveSpaceAutoOpener.swift:73`. `autoOpen()` early-returns
when `immersiveSpaceState != .closed` **without** clearing
`isImmersiveSpaceAutoOpenRequested` (set at `AppModel.swift:166-172`); only
`:74/:79/:82` clear it. The notification listener also skips non-`.closed`
(`:62`), so a request that lands mid-transition leaves the latch true. When the
menu window is later torn down and remounted, the mount drain (`:50-52`) opens
the immersive space unprompted. Callers only check `!= .open`
(`FractalGridView.swift:637`, `AppModel+SceneLoading.swift:140`). Fix: clear the
latch in the non-`.closed` early return.

---

## LOW

### N16. "Compiling custom shader" card flashes on instant activations (likely)
`AppModel+EmbeddedFormula.swift:139-141` sets `customFormulaCompileStatus`
immediately before awaiting the handler, but the handler can return without
compiling: unchanged effect set → renderer no-op
(`RendererCustomShader.swift:143-146`, `RaymarchRenderView.swift:100`);
prewarmed effect set → instant `libraryCache` hit
(`CustomShaderCompiler.swift:159-162`). Because the status is set on the
MainActor before an `await` that yields to the actor, the overlay can render one
frame of the spinner and animate back out
(`SceneNavigationFeedbackOverlay.swift:162-205`) — a misleading flicker on every
already-cached custom-scene tap, which prewarm makes the common case. Fix:
publish the status only when a compile actually happens.

### N17. Compile-progress card is never shown on visionOS ✓ verified
`customFormulaCompileStatus` is only rendered by
`SceneNavigationFeedbackOverlayModifier`, and `.sceneNavigationFeedbackOverlay(...)`
is applied only in `ThresholdMacApp.swift:590` and `ThresholdiOSApp.swift:218`.
`MetalProjectApp.swift` never applies it, so the tens-of-seconds custom-scene
compile shows no progress on visionOS — where a missing first frame risks a
compositor kill.

### N18. Live-edit compile treats a superseded activation as a failure ✓ verified
`AppModel+EmbeddedFormula.swift:185-192`. `installEmbeddedFormulaForLiveEdit`
has no `CancellationError` case, unlike the scene path (`:146-152`, added by the
H3 fix). `ViewportCustomShaderBox.activate` throws `CancellationError` when a
newer activation supersedes it (`RaymarchRenderView.swift:105-106`; the actor
does the same at `RendererCustomShader.swift:163-165`). `FormulaEditorModel`
discards stale results only when its own `generation` advanced or `pendingCompile`
is set (`FormulaEditorModel.swift:378-393`); a supersede caused by an *external*
activation leaves `generation` unchanged, so the editor shows a
`CancellationError` as a compile failure against source that is fine.

### N19. Keyframe decode fallbacks don't match the engine defaults ✓ verified
`Threshold/Animation/AnimationTypes.swift:440-445` falls back to `?? 9`
iterations / `?? 64` ray steps, but the engine defaults are now
`QualityConfig.defaultFractalIterations = QualityPreset.low.fractalIterations = 6`
and `defaultMaxRaySteps = QualityPreset.low.raySteps = 68`
(`QualityPreset.swift:14`, centralized by `12c3d3aa`). A `.threshanim` missing
those keys decodes at a different quality than a fresh keyframe/scene; the
comment claims it falls back to engine defaults. Fix: use the `QualityConfig`
constants.

### N20. `clearThumbnailCache(for:)` is a dead no-op ✓ verified
`FractalPreset.swift:1630-1632` removes `id.uuidString`, but cache keys are now
SHA-256 content hashes (`:1639-1656`), so no key ever matches. Callers:
`PresetManager.swift:1300, 1310, 1333, 1416`. Impact is bounded (changed bytes
mint a new key, so no stale image is served), but the per-preset invalidation
contract is silently broken and old entries survive to NSCache's 256-count
eviction. Fix: drop/repurpose the API, or track id → last digest.

### N21. Benchmark shadow-iteration constants no longer mirror production (note)
`MacBenchmarkHarness.swift:293` still bakes `max(iterations - 2, 2)` for
`FC_SHADOW_ITERATIONS`, so benchmark kernels don't mirror the production shadow
cost after `136397c8`. Benchmark-only; it does not affect the delta comparisons
the harness exists for. `RendererPipelineHelpers.swift:163` (`forQualityPreset`)
has the same stale formula but is dead code (no callers); only the comment in
`RenderPrecompute.swift:14-15` records it.

---

## Still open from `FINDINGS.md` (spot-checked, not re-audited)

- `NavigationStore` still encodes + writes `UserDefaults` synchronously on every
  select/pin (original LOW tail) — unchanged by the fix batch
  (`NavigationStore.swift:383-386`).
- No in-flight coalescing in `HeadlessRenderer.resolvePipeline`
  (`ThresholdQuickLook/Shared/HeadlessRenderer.swift:347-359`) is the same shape
  as N4; the QL fix moved decode/compile off the appex main thread (`b3caf80e`),
  so concurrent preview requests can now double-compile a key too. Bounded by
  `cacheLock` (no data race) — redundant work only.
- `containsFunctionDefinition`'s `(?!return|case)` guard still admits other
  call-site shapes such as `else DE_Foo(...)` (`EmbeddedFormula.swift:1036`) —
  incomplete, no realistic payload demonstrated.

## Verified clean by this pass

- **Animation dt** (`0fad58ac`, `ParameterUpdateCoordinator.swift`): deltas are
  banked on every playing frame including the gate-passing one, consumed and
  reset only in `applyParameterUpdates` when `pendingAnimationUpdate`, and reset
  when animation is off — elapsed time is conserved across delayed MainActor
  applies, so H5 is genuinely fixed.
- **Spatial upscaler pool/LRU/negative cache/mirror clearing** are otherwise
  correct apart from N3; no texture use-after-free (encode holds the `Pass`,
  eviction excludes `activeKey`, Metal retains encoded resources).
- **Persistence backups**: `maxBackupCount = 24` + `pruneBackups` bounded and
  Presets-scoped; `.atomic` write correct; the detached encoder mirrors
  `presetEncoder`, so restore decoding is unaffected.
- **Animation playhead**: `update()` clamp (`AnimationManager.swift:2048-2054`) +
  `revalidatePlayheadAfterKeyframeMutation` (`:1623-1636`) close the old
  out-of-range subscript; descending `.onDelete` correct; `flushPendingSavesNow`
  cancels and flushes both flags.
- `ControlCatalogProjection` LRU keeps its ≤64 invariant and dict/order
  consistency; `mutateFormulaParam` mirrors the `formulaParams` setter;
  `setTargets` finite rejection correct.
- `FormulaCatalog` locking has no re-entrant path under `ephemeralLock`;
  `FormulaLibraryStore` newest-wins dedup and editor re-arm correct.
- `MetalLibraryCache` Mutex (`RendererMath.swift`) and the `shouldRunProfiler`
  Mutex (single reader, test-and-clear) are sound.
- `worldRotation` is a live lock-backed getter, so the Detail-rotation axis
  compose is correct; `BottomPerformanceStripView` inherits `AppModel` from the
  environment at every `ContentView` site; the restored-view-mode sanitize and
  the `nonisolated` `Atomic<Bool>` mirror match the render-thread reader.
- The macOS double-click swallow exactly covers `shouldOpenFullControls == false`.
