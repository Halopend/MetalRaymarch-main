# FINDINGS — Bug, inefficiency & risk scan of Threshold

Produced from a full defect-oriented sweep of the codebase (7 parallel subsystem hunts over
all Swift/Metal/scripts + a personal verification pass on every Critical/High claim).
**Scope**: correctness bugs, races, data-loss paths, GPU/DE contract violations, privacy/trust
boundaries, hot-path inefficiencies, and misleading dead code. Known gotchas already listed in
`MEMORY.md §12` are excluded (or only extended with new evidence).

**Severity**: `Critical` = crash/data-loss/security · `High` = visible malfunction or freeze
· `Medium` = degraded/stale/lost behavior · `Low` = minor or latent.
**Confidence**: `verified` = traced line-by-line in this repo (personally re-checked where marked ✓)
· `likely` = mechanism confirmed, trigger conditions not reproduced · `hypothesis`.

**Totals: 10 High · 30 Medium · 27 Low** (plus verified-clean notes at the end).

---

## HIGH

### H1. Ambient occlusion is inverted (returns occlusion, not visibility) ✓ verified
`Threshold/Rendering/Shaders.metal:3628-3641` → consumed at `ShadeSurface` :3677.
```metal
float ao = 1.0f;
… ao -= (h - d) * sca;            // ao = 1 − Σ(h−d)·sca
return clamp(1.0f - ao, 0.0f, 1.0f);   // ← returns the raw occlusion sum
```
Canonical AO returns `1 − occlusion`; this returns `occlusion`. With Coloring → Ambient
Occlusion > 0 (default 0 hides it), open surfaces lose all ambient (near-black) while creases
stay lit — inverted shading for every scene/preset that enables AO. Fix: `return clamp(ao, 0, 1);`
(`ao` is already the visibility term).

### H2. Installing a space-warp `.threshfx` clobbers the active custom fractal DE ✓ verified
`Threshold/App/AppModel.swift:1119-1131` + `Threshold/Rendering/Core/RendererCustomShader.swift:121-124`.
`installSpaceWarp` sets `activeEmbeddedFormula = warp` unconditionally; the renderer maps a warp
to `fractalEffect = nil`, so the custom DE library is replaced by a warp-only library whose
dispatch keeps `FractalTypeCustom → 1e10` → **fog/sky forever** (library present ⇒ self-heal
never fires; slot now holds the warp). Every external-import branch calls it unguarded
(`AppModel+ExternalImport.swift:236-240/329-341/449-457`, `AppModel+SceneLoading.swift:50-52`).
Inverse leak: loading a custom-fractal scene after a warp leaves `spaceWarpStrength = 0.6`
engaged on the built-in loop. Fix: guard/replace with uninstall + strength reset on kind switch.

### H3. Compile failure AND benign staleness both uninstall the ACTIVE formula ✓ verified
`Threshold/App/AppModel+EmbeddedFormula.swift:132-139`; amplifier at
`Threshold/Rendering/RaymarchRenderView.swift:101-102`
(`try Task.checkCancellation(); guard isCurrentActivation(activation) else { throw CancellationError() }`).
The catch runs `uninstallEmbeddedFormula()` for **any** thrown error, including `CancellationError`
raised by a superseded activation. Loading scene B whose compile fails (or is merely superseded)
destroys scene A's working registration, nils `activeEmbeddedFormulaHash`, fires `handler(nil)` →
detach → fog/sky with self-heal dead (self-heal exists only in the visionOS path,
`RendererPipelineCache.swift:632`). Fix: no-op on `CancellationError`; uninstall only when the
failing formula is still the active one.

### H4. Deferred custom-scene import poller is unstructured: stale scene applies after cancel/supersede ✓ verified
`Threshold/App/AppModel+SceneLoading.swift:144-186` + `AppModel+ExternalImport.swift:474-486`.
The 10 s poll Task is never stored/cancelled and has no generation check; on handler bind it
unconditionally calls `handler(formula)` for its captured preset. Two deferred imports race
(double compile, last-writer-wins); **Cancel** clears `pendingSceneApplyAfterActivation` but not
`pendingPresetForActivation`, so the cancelled scene still applies on the next bind — and the
10 s timeout then posts a bogus "Custom scene is queued…" banner after cancel. Fix: store +
cancel the poll task, generation-check inside the loop, clear both pending slots in `clearExternalPreview`.

### H5. Keyframed animation plays at ~0.5× real speed on 120 Hz displays ✓ verified
`Threshold/Rendering/ParameterUpdateCoordinator.swift:36,78`; call sites pass per-frame dt
(`RaymarchRenderView.swift:1621-1631` clamps 1/240…1/15; visionOS twin `Renderer.swift:1220`).
The 90 Hz gate passes only when `currentTime - lastAnimationUpdate >= 1/90`, but line 78 stores
`pendingDeltaTime = deltaTime` — **the single frame's dt, not the elapsed time since the last
update**. At 120 fps (iPad Pro / ProMotion Mac, `preferredFramesPerSecond = 120`) the gate passes
every other frame: 60 updates/s × 8.3 ms = **0.5 s of animation per real second** — scenes take
2× their authored duration and drift out of sync with attached songs. The 60 Hz audio gate
halves music-reactive envelope timing the same way on 120 Hz. Any visionOS rate ≠ 90 Hz ditto.
Fix: accumulate skipped deltas (`pendingDeltaTime += deltaTime` when the gate declines) or pass
`now - lastAnimationUpdate` as dt.

### H6. Deleting a keyframe during playback can crash out-of-bounds ✓ verified
`Threshold/Animation/AnimationManager.swift:1573` (`removeKeyframe` never touches `playhead`)
→ `update()` :1975-2010: guarded only by `keyframes.count >= 2`, then
`var fromKeyframe = keyframes[fromIndex]` with `fromIndex = playhead.currentKeyframeIndex` —
**no clamp** (contrast the clamped site at :2272). A looping scene sitting at the final index +
`.onDelete` in the keyframe list (`AnimationViews.swift:1077`, no isPlaying guard) ⇒
`keyframes[count]` crash next frame; multi-select deletes also shift indices (wrong frames
removed). Fix: clamp index + re-validate `elapsedInSegment` after any keyframe mutation on the
playing scene.

### H7. SharePlay peer state applied with zero clamps / isFinite guards ✓ verified
`Threshold/Collaboration/FractalShareActivity.swift:90-124` (`apply(to:)`) →
`Threshold/Parameters/RenderSettings.swift:652-655` (`maxRaySteps` setter is **unclamped** while
its `baseMaxRaySteps` twin :671-681 clamps; also unclamped: `scale`, `position`, `fractalScale`,
`colorMix`, `minDistance`, `foldingLimit`, `sphereRadius`, `detailScale`) and
`setTargets` :4585-4592 (no clamp/isFinite). `GroupSessionMessenger` delivers any participant's
message verbatim: a malicious/buggy peer can send `maxRaySteps = 1e9` (GPU marches effectively
forever → watchdog kill; each distinct RS also mints a new pipeline = cache-key churn DoS), or
NaN/Inf position/scale that poisons smooth-damp camera state session-wide. Iterations/bubble
happen to clamp; everything else doesn't. Fix: in `apply`, mirror the file-decode contract
(isFinite guards + ControlCatalog clamps) before any write.

### H8. Quick Look preview compiles the custom-DE pipeline on the MAIN thread ✓ verified
`ThresholdQuickLook/Preview/PreviewViewController.swift:21-31`. `NSViewController` is
`@MainActor`, so the whole `preparePreviewOfFile` body — file read + JSON decode
(`interactiveScene`) + `prewarm` → `device.makeLibrary(source:)` ("can take a second or two") —
runs on the appex main thread; the comment claims "off the main actor" but the `await
MainActor.run` hop is a no-op. Beachballed previews, watchdog risk on slow hosts. Fix:
`Task.detached` (or a background helper) for decode+prewarm, then hop in to install UI.

### H9. Twist/Bend warp DE-divisor = 1 violates the max-singular-value march ABI — holes/slices at default strength
`Threshold/Rendering/Shaders.metal:459-461` (built-in twist returns `1.0`), `:687-703`,
`:1023-1033` (warp `deScale` default arm). A rotation by θ = k·(p·axis) has Jacobian
σmax = √(1+(k·|p⊥|)²) ≥ 1; with strength 0–2 (default 0.6) the march oversteps up to ~3× at
r ≈ 2 → **sliced/holed surfaces off-axis** for Transformations Twist/Bend, and the distance
cache (eligible under warps) compounds it. Fix: `warpTwist/BendDEScale = √(1+(1.5·s·r)²)`
(likely — math verified, visual confirmation on-device pending).

### H10. Music→space-warp mappings silently misbind after a Transformations reorder
`Threshold/App/TransformationsSection.swift:2227` (`replaceSpaceWarpStack` — no remap) +
`Threshold/Audio/MusicReactiveTypes.swift:216-222` + `MusicReactiveEngine.swift:420`
(slot-index resolution). Mappings address warp ops by **slot index**; dragging a new op above a
mapped slot repoints the audio (and the ♪ badge, :2407) at a different transform with no error.
Fix: remap `spaceWarpN` slot targets on reorder/delete, or key mappings by op UUID.

---

## MEDIUM

### Formulas / custom DE
- **M1. Catalog reader/writer data race** — `FormulaCatalog.swift:208-219` writes `formulas`/`byType`
  under `ephemeralLock`, but `descriptor(for:)` (read by `RenderSettings._clampFormulaParamValue_locked`,
  render thread, `RenderSettings.swift:3820-3822`) takes **no lock** → Swift Dictionary read/write race
  on every live-editor keystroke (crash potential). Lock the readers too.
- **M2. Forbidden-token filter bypassed by `# include`** — `EmbeddedFormula.swift:940-966` substring
  scan + `CustomShaderCompiler.swift:351-362` exact-prefix strip miss `# include "x.h"` (valid C,
  reaches `makeLibrary` unstripped); a `#include` mention inside a comment also over-rejects. Use
  `^\s*#\s*(include|import)` in both.
- **M3. `// @param` matched by prefix → a prose comment bricks compile & wipes params; %g round-trip
  loses precision** — `FormulaSourcePragmas.swift:132-134, 321-339`. `// @params: see below` → hard
  parse error → `.blockedByParseIssues`; on legacy payloads it flips `hasPragmas` → params `[]` →
  slider UI wiped. `%g` (6 sig digits) silently re-rounds pragma round-trips and breaks on names
  containing `"`. Word-boundary the match; treat trailing text as warning; precision-preserving format.
- **M4. DE Studio cannot edit spaceWarp payloads** — `FormulaEditorModel.swift:297-311` hardcodes
  `kind: .fractal`; loading a warp `.threshfx` registers it as a fractal descriptor (corrupting the
  active custom descriptor's params) and wedges at `.blockedByParseIssues`. Derive kind from source
  or filter warps out of the editor.
- **M5. Editor wedge: `load()` never clears `isInvalidated`** — `FormulaEditorModel.swift:332-341`
  vs `:193-221`. A model surviving `onDisappear` (cover teardown / sidebar re-load) is invalidated
  forever: no publish, no compile, status frozen at `.idle` with no diagnostic. Reset the flag in `load()`.
- **M6. FormulaLibraryStore lacks PresetManager's iCloud placeholder policy; id-dedupe can resurrect a
  stale file** — `FormulaLibraryStore.swift:70-91, 111-119`. Un-hydrated placeholder → MainActor-blocked
  sync read, entry vanishes, `save()` writes a duplicate-id file; post-hydration `seenIDs` keeps the
  alphabetically-first file, possibly stale. Port the `isUbiquitousItem`/download-status probe.

### Rendering
- **M7. visionOS silently ignores `deIterationMismatch`** — `Renderer.swift:1523, 2605` +
  `UniformsBuilder.swift:258` use raw `fractalIterations`; Mac/iOS applies the bias
  (`RaymarchRenderView.swift:1408`), and `RenderPrecompute.swift:92-96` deliberately excludes it from
  `absScalePow`. The control renders on visionOS too (no capability gate, `ParameterCatalog.swift:1153`)
  → slider no-op on Vision Pro; scenes render different geometry cross-platform. Apply the bias or
  gate the control.
- **M8. Spatial MetalFX scaler rebuilds synchronously on the render thread (main thread on iPad)** —
  `ViewportSpatialUpscaler.swift:112` inline `makeSpatialScaler` + 3 texture allocations per new size;
  the temporal sibling documents 0.2–2 s builds and got an async builder (`ViewportTemporalUpscaler.swift:20-24`);
  iPad disables temporal (`RaymarchRenderView.swift:539-545`) so every Definition-drag step / resize
  can stall the main thread. Port the latest-wins private-queue drain pattern.
- **M9. Cross-thread `nonisolated(unsafe)` renderer state** — `RendererFrameLoopHelpers.swift:196`
  `clearHandTrackingDispatchTask()` (from the detached task's `defer`) races the actor write :186 →
  lost teardown cancel (dispatch N+1 survives into a dying actor); same pattern for
  `shouldRunProfiler` (`Renderer.swift:199/2731`) and `MetalLibraryCache.defaultLibrary`
  (`RendererMath.swift:5-12`, formally UB under Swift 6, can double-compile). Move into Mutex'd state.
- **M10. Baked `FC_FRACTAL_ITERATIONS`/`FC_SHADOW_ITERATIONS` defeat `ReducedSecondaryIterations`** —
  `Shaders.metal:1911, 1949` (FC wins over the runtime arg) + always-set at
  `RendererPipelineCache.swift:911-913` → normals/shadows run full iterations (~2.5× designed normal
  cost) on every specialized pipeline. Honor the lower runtime count or add a reduced-iter FC.
- **M11. Cone coarse-prepass ignores Hand Field in both trust gates and its own DE** — extends the
  known §12.2 gotcha: `Renderer.swift:1442-1454` (`coneAllowed` omits hands), `Shaders.metal:4526-4529`,
  `:4565-4568` (cone fp without handField) while the full march includes them → per-block pops with
  hand attraction enabled.
- **M12. All shadow marches omit the hand field** — `Shaders.metal:4820-4823, 4340-4345, 4384-4387,
  4397-4400` build shadow params without handField (the march passes it) → hand bulges cast no shadow.

### Persistence & files
- **M13. Preset backups unbounded + non-atomic + MainActor encode** — `PresetManager.swift:184`
  (`maxBackupCount = nil`, `pruneBackups` dead), `:1142` (no `.atomic`; animations do both,
  `AnimationManager.swift:1364/1383`), `:1096-1099` (whole-set pretty-JSON encode on MainActor).
  With ~30-80 KB base64 thumbnails per preset: hundreds of MB in `Documents/Backups/Presets/`
  after hours of editing. Finite retention + `.atomic` + off-main encode.
- **M14. `importPreset` discards persist failure** — `PresetManager.swift:1300` `_ = persist(preset)`
  after mutating `presets` → write failure leaves an in-memory ghost that the next folder-truth scan
  silently drops (user believes import succeeded). `savePreset`/`updatePreset` both roll back.
- **M15. Store scans/deletes on MainActor; no placeholder check on the delete path** —
  `PresetManager.swift:849-863` decodes EVERY store file on every save/rename/delete/replaceAll;
  an iCloud placeholder can synchronously materialize mid-read → multi-second stall
  (`AnimationManager.swift:253-256` already optimized this exact pattern — port it).
- **M16. Imported warp stacks >8 ops silently truncated** — `SpaceWarpStackModel.swift:866`
  (`.prefix(kMaxSpaceWarpOps)`) + `Shaders.metal:1131` (`groupLength = min(groupLength, n - i)`):
  a 3-op Mandelbox-recurrence group starting at index 7 runs as a 1-op group ×16 — **a different
  fractal than authored**, UI shows all cards, music offsets for slots ≥8 filtered. Truncate at
  decode with a warning or surface an over-capacity banner.
- **M17. `AnimationKeyframe` decode requires 12 non-optional keys** — `AnimationTypes.swift:427-442`
  `decode(...)` for minDistance/foldingLimit/sphereRadius/fractalScale/position/detailScale/
  worldRotation/baseFractalIterations — any missing key rejects the whole `.threshanim`; the header
  comment :866-873 documents this exact bug class fixed one level up. `decodeIfPresent` + defaults.
- **M18. AnimationManager 100 ms coalesced save has no lifecycle flush** — `AnimationManager.swift:2418-2432`
  (hidden-defaults/overrides live only in UserDefaults); `AppModel.saveLastState` (:848-857) never
  flushes them → quit/kill within 100 ms loses the edit (visionOS SIGKILL teardown may skip
  `.inactive` entirely). Flush in `saveLastState`.
- **M19. Deletes while the iCloud root is unresolved resurrect on next scan** —
  `PresetManager.swift:1222-1231` (delete becomes a no-op when `storeRoot == nil`; only
  `pendingRootWrites` is cleared). Queue deletions like writes.
- **M20. Same-id import stamps stale content `updatedAt = now`** — `PresetManager.swift:1291-1296`:
  re-importing an older export overwrites the local edit AND the inflated timestamp wins the
  newest-wins iCloud merge, propagating the regression cross-device. Keep `max(existing, file)` or prompt.
- **M21. `SettingsPersistence.saveDebounced` silently drops writes it cannot encode** —
  `SettingsPersistence.swift:154-155` (`guard … let data = encode(value) else { return }`) — a domain
  that ever fails JSONEncoder is unpersisted for the whole session with zero diagnostics. Log +
  fall back to the last-good blob.
- **M22. Pipeline formula-param read-modify-write races gesture vs audio threads** (likely) —
  `ParameterPipeline.swift:260-295` RMWs the shared 16-float `formulaParams` blob outside the state
  mutex; concurrent gesture + audio dispatch loses updates (parameter flicker under music+gesture).
  Move the RMW inside `_state.withLock`.

### App / UI
- **M23. Radial projection tree rebuilt per body evaluation and per scroll tick, with UserDefaults +
  JSON decode inside the factory** ✓ verified — `RadialMenuProjectionFactory.swift:213-222`
  (UserDefaults reads + JSON decode per build) called from a computed property read inside `body`
  (`ThresholdMacApp.swift:1070-1074`) and per scroll tick (`:1106-1107`). Cache in `@State` keyed on
  (fractalType, transformRevision, profile).
- **M24. External preview leaves the previous custom formula active (preview ≠ commit)** —
  `AppModel+ExternalImport.swift:324` `installEmbeddedFormulaIfNeeded(nil)` is a **no-op**
  (`AppModel+EmbeddedFormula.swift:73`), while commit paths call `uninstallEmbeddedFormula()` →
  visible visual jump preview→commit; the preview's install also runs before its id-guard (:340-363).
- **M25. `saveDebounced` encodes the ENTIRE domain config per slider tick on the main thread** —
  `SettingsPersistence.swift:154-157` (encode happens before the debounce; only the write is
  deferred) + convolution-kernel TextEditor commits per keystroke
  (`ContentView+ColoringTab.swift:558-564`, re-parse per body eval :573). Encode inside the commit task.
- **M26. Per-tick UserDefaults write storms amplified by the `didChangeNotification` re-decode** —
  `FormulaParamsEditor.swift:353` → `GestureSensitivityStore.save()` (full JSON encode + write per
  tick) each firing AppModel's observer that re-decodes transformation JSON (`AppModel.swift:798-807`);
  same pattern in AnimationManager music-cue sliders (:621-624, 714-726, 738-750). Debounce;
  persist on editing-end.
- **M27. `requestOpenImmersiveSpaceNotification` listener dies with the menu window** —
  `ImmersiveSpaceAutoOpener.swift:53-56` is mounted inside the dismissible menu window
  (`MetalProjectApp.swift:123`); after dismissal, importing a `.threshfx` posts to no listener →
  space never auto-opens → 10 s timeout message. Host the listener app-scoped.
- **M28. `ControlCatalogProjectionCache.invalidate()` has zero call sites; `catalogRevision: 1`
  hardcoded at 3 sites** — `ControlCatalogProjection.swift:24,60` + `RadialMenuProjectionFactory.swift:94`,
  `ContentView+SettingsTab.swift:114`, `SpatialRadialMenuView.swift:253` → unbounded growth keyed by
  `transformRevision` (long transform sessions leak) and future catalog bumps silently stale. LRU-cap;
  derive revision from the catalog.
- **M29. Double-click fires radial leaf/toggle actions twice on macOS** — `RadialMenu.swift:2100-2113`
  (Button fires per mouse-up; leaves run `onActivate()` for both clicks → `pushConstructionPrimitive`
  races two compile tasks, toggles net-zero). `RadialActivationPolicy.shouldToggle` exists, unused.
- **M30. `bottomPerformanceStrip` reads `renderMetrics` inline → 2 Hz whole-ContentView re-eval** —
  `ContentView.swift:1750-1753` vs the extracted `FPSIndicatorView` precedent
  (`ContentViewComponents.swift:467-471`). Extract the strip.
- **M31. Scene-card thumbnails re-decode per body evaluation; NSCache keyed on a fresh UUID always
  misses** — `FractalGridView.swift:766-767` (`FractalPreset(id: UUID(), …)`) vs
  `FractalPreset.swift:1622-1636` (cache key = id). Every card render ImageIO-decodes + inserts an
  orphaned cache entry. Key on the real id or data hash.
- **M32. Detail Pitch/Yaw/Roll sliders compose from a 0.5 s-stale euler snapshot** (likely) —
  `ContentView+FractalTab.swift:400, 638-641` (snapshot refreshed only by the 0.5 s sync timer);
  dragging after a grab rotation reverts the gesture's yaw/roll (visible snap-back). Sample
  `renderSettings.worldRotation` at set-time.

### Platform / tooling
- **M33. SharePlay wall-clock dedup lets one peer starve (or DoS) all sync** —
  `FractalShareSession.swift:253` (`timestamp > lastReceivedTimestamp`, one global watermark; sender
  clock skew or one big timestamp permanently drops later traffic). Dedup per-sender. (Also:
  `.error` state clobbered by `stopSharing()` :239/122 — end reason never shown.)
- **M34. QL `packUniforms` hardcodes scene-authorable bounding-shape fields** —
  `HeadlessRenderer.swift:155-164` vs `RaymarchRenderView.swift:2155-2168`: Bounding Shape fog/shadow/
  type/ambient + Bound-to-Space size are scene-authorable (`FractalPreset.swift:75,116,1485-1490`) —
  previews silently render without them, and `boundSpaceWorldToLocalMatrix` is built from settings
  while carrying the hardcoded 4/2.5/4 size. Pass the settings-backed values.
- **M35. `perf-gate.sh` passes on a degenerate run** — `perf-gate.sh:111-118`: `gpuMsAvg = 0`
  (harness returns 0 when no GPU samples, `MacBenchmarkHarness.swift:1008`) reads as −100%
  "improved" → gate passes on instrumentation loss; `--rebaseline` also resets timing baselines
  alongside PNGs. Fail on zero frames/gpuMs/iterationsAvg.
- **M36. Plan-mode benchmark: same-scene jobs inherit the previous job's overrides** —
  `MacBenchmarkHarness.swift:766-768, 815-816` (empty qc/params/shadows early-return, no reload) →
  job B silently measures with job A's overrides; downstream baselines wrong. Re-pin or force reload.
- **M37. Buddhabrot mode unreachable; a stale persisted value hijacks the whole panel** —
  `AppModel.swift:221-227` (only writer found sets `.raymarch`; the 1,648-line `BuddhabrotRenderer`
  is never constructed — the MEMORY §4 "dormant" note is now confirmed) — but a stale
  `runtimeViewMode = "buddhabrot"` from an older build boots into the Buddhabrot-only panel,
  replacing all navigation. Wire or delete; sanitize the restore.
- **M38. `build.sh` prefers a stale `Xcode-beta.app` over the newer `Xcode-beta 2.app`; QL gate
  doesn't know "Xcode-beta 2" at all** (likely) — `build.sh:40-43` + `ql_render_check.sh:22-25`:
  on machines where the " 2" suffix is the newer beta (the exact convention
  `check_no_duplicate_suffix.sh` exists to police), builds and the QL render gate can use
  **different toolchains**, and CI's "Report toolchain" step reports the un-pinned default. Order
  candidates newest-first; share one resolver.

### Audio
- **M39. Apple Music adapter touches `systemMusicPlayer` before authorization** —
  `AppleMusicServiceAdapter.swift:48-49` reads `nowPlayingItem` in `nowPlaying`; the manager's own
  contract defers all player access until authorized (prompt/account-backend init). MusicTabView
  reads `music.nowPlaying` (:156, 673) ahead of the connections section → first tab open can pop the
  permission prompt. Guard on `isAuthorized && isObservingPlayer`.
- **M40. Apple-Music-only sessions freeze when rendering pauses** (likely) — `AudioHub.swift:218-248`:
  the fallback timer is created only in `start(_:)` and its keep-alive guard checks
  `captureSources` (mic only). With Apple Music selected and the render loop paused,
  `latestSnapshot()` stays frozen at `isActive: true` with stale band levels; decay-to-zero never runs.
- **M41. Apple Music player state polled at 60 Hz on MainActor even when inert** (likely) —
  `AppleMusicManager.swift:301-309` (200 ms poll) + `advanceFrame()` inside every
  `AudioHub.updateFrame()` → MediaPlayer IPC reads per audio frame even when mic is the active
  source. Gate `advanceFrame` on active contribution; rate-limit to the poll cadence.

---

## LOW

**Formulas/custom DE**
- Required-function regex satisfied by call sites/comments (`EmbeddedFormula.swift:1013-1021` —
  `return DE_Foo(...)` matches); validation passes, compile fails with an unmapped scaffolding error.
- Retired warp-stack "s0" plumbing + stale doc promising per-stack hashing (`CustomShaderCompiler.swift:132-138`,
  `RendererCustomShader.swift:108-116`, `RenderSettings.swift:209-216`) — dead params; latent wrong-stack
  LRU hit if codegen is ever revived. Delete or restore a content-derived signature.
- Same id + same source but edited params/name skips re-registration (`AppModel+EmbeddedFormula.swift:107-116`).
- Editor can wedge in ".compiling" — no timeout on the Metal continuation (hypothesis;
  `CustomShaderCompiler.swift:174-188`).

**Rendering**
- Screenshot latch can leak/wedge a checked continuation (dormant API; `RendererScreenshot.swift:86`,
  consume at `RendererLoopSupport.swift:30-35`, no resume on `.invalidated`).
- Diagnostics string + key built every frame before the change gate (`RendererRenderSupport.swift:365`
  — ~10 String allocs/frame at ~90 Hz).
- macOS draw path blocks main thread on `nextDrawable()` (`RaymarchRenderView.swift:1047` — the
  documented iPad hazard, unmitigated on macOS).

**Shaders**
- `normalize(trapPos)` zero-vector NaN in gradient coloring (`Shaders.metal:2448`).
- `sphereRadius` decodes/set unclamped → 1/0 → NaN in sphere fold (`GeometryConfig.swift:180`,
  `RenderSettings.swift:1214`, `Shaders.metal:39/1907`).
- March can register a hit beyond `maxRayDistance` (`Shaders.metal:3192` vs break at `:3212`).
- `coarseRateMagMax` hardcoded 4.0 may under-bound extreme foveation (hypothesis; `Renderer.swift:2466`).
- Buddhabrot radix histogram corrupt on partial last threadgroup (dormant feature;
  `BuddhabrotShaders.metal:689-709`) + dead `minIterations` field (`BuddhabrotTypes.h:51`).

**Persistence**
- Backup write non-atomic (covered in M13 but distinct line: `PresetManager.swift:1142`).
- Unknown `SpaceWarpKind` silently becomes `.twist` instead of failing closed
  (`SpaceWarpStackModel.swift:679` — newer-build scenes render unplanned warps on older installs).

**App/UI (incl. one-line tails)**
- `ForEach(Array(enumerated()), id: \.offset)` across all scene grids → positional identity, wrong-row
  edit/delete under rename/reorder/filter (`FractalGridView.swift:216, 273, 320, 367, 414`).
- Mac `menuAdjustmentDepth` can latch (no reset on teardown; `ContentView.swift:602-606`).
- MenuChrome stale auto-hide can close a just-re-presented menu (`MenuChrome.swift:27-37`).
- `ToggleImmersiveSpaceButton` exit can leave `.inTransition` with no fallback (`:27-33`).
- Force-unwrap `URL(string:)` on Link destinations ×2 (safe literals today; `SettingsTab:591`,
  `FirstLaunchWindowView:360`).
- Gradient editor Save appends duplicate same-name entries; rename/delete resolves a
  context-menu-captured index later (`GradientEditorView.swift:136-137`, `ContentView+ColoringTab.swift:171-173`).
- `loadFromSettings` unconditionally reassigns `formulaParams` (no-op invalidation storm;
  `ControlStateStore.swift:232`).
- NavigationStore: synchronous JSON encode + UserDefaults write on **every** select/pin + re-persist
  after decode (31 call sites; `NavigationStore.swift:368-371, 280`).
- BenchmarkMode double-AppModel: full init work (registry validation, PresetManager seeding,
  settings restore) runs twice; `AppModel.shared` briefly points at the discarded instance
  (`ThresholdMacApp.swift:8, 25-27`).

**Platform / tooling**
- QL custom-DE pipeline cache unbounded (app LRU-8 counterpart; `HeadlessRenderer.swift:196-197`).
- RenderCheckMain allowlist drifts silently (no assertion that allowlisted scenes exist;
  `RenderCheckMain.swift:33-38, 107-112`).
- `mark_mixed_scenes.py` writes non-canonical JSON (`ensure_ascii=True` vs Swift raw UTF-8,
  `sort_keys=False`) + locale-dependent `read_text()` (`mark_mixed_scenes.py:33, 40`).
- `generate_metal_embeds.sh` claims a "unique" raw-string delimiter but hardcodes `"""#` with no
  collision check (latent build break; zero occurrences today; `EmbedFreshnessTests` pins output).
- `usedGradientColoring` set unconditionally every sample → always-true, meaningless aggregate
  (`UsageAnalytics.swift:433`).
- Pending-snapshot loss windows: pending list cleared before the upload loop (kill mid-loop loses the
  un-attempted rest) and `upload()` returns `true` when no iCloud account → snapshots silently dropped
  instead of queued (`UsageAnalytics.swift:553-557, 158`).
- Legacy mapping migration silently drops colliding mappings with no log
  (`MusicReactiveTypes.swift:596-607`).
- Force-unwrap on spotify capability lookup (`AudioHub.swift:308`).
- `MusicReactiveEngine.frameIndex` stalls while the op buffer is empty (stale ordering vs gesture ops;
  `MusicReactiveEngine.swift:345-348`).
- Legacy `Mandelbulb`… `.threshanim` external-open class fixed at scene level but not keyframe level
  (see M17); `MenuToggleGestureMode` decode fallbacks fine.

---

## HOT-PATH INEFFICIENCIES (renderer-frame & gesture paths)

1. **Single-hand drag hot path: ~18 lock-acquiring binding lookups + ~30 dictionary probes per frame**
   (`SingleHandDragGestureEngine.swift:48-93`, plus re-walks at :52-62/:143-162). Snapshot bindings per
   config-version change.
2. **Apple Music MediaPlayer IPC reads at audio-frame cadence** (M41) on the main actor.
3. **Per-frame diagnostics string/key construction** before the change gate (`RendererRenderSupport.swift:365`).
4. **Radial projection rebuild per body eval / scroll tick** (M23) incl. UserDefaults + JSON decode.
5. **Whole-config JSON encode per slider tick** (M25) + per-tick UserDefaults write storms (M26).
6. **Thumbnail re-decode + cache-miss per card render** (M31).
7. **2 Hz full-ContentView re-eval when the metrics strip is on** (M30).
8. **MainActor folder decode sweeps per save/rename/delete** (M15); **whole-set backup encode per ≥30 s**
   (M13); **sync NavigationStore persist per select** (LOW tail).
9. **Spatial MetalFX scaler + textures allocated inline per size step** (M8); **macOS `nextDrawable()`
   main-thread wait** (LOW tail).
10. **Normals/shadows run full iterations because baked FCs defeat the reduced-iteration path** (M10)
    — the largest standing GPU cost item.

## CROSS-CUTTING THEMES

1. **Clamp/validate at write boundaries, not per consumer** — the `maxRaySteps`/`scale`/`colorMix`
   setters and `setTargets` trust callers (H7), while `fractalIterations`/bubble setters clamp; scene
   decode clamps while SharePlay doesn't. A single "clamp all external input (files, peers, gestures)
   through ControlCatalog" pass would close H7, M22, and several Lows.
2. **Single-slot custom-effect state machine needs an ownership model** — H2/H3/H4 + M24 are all
   the same root: `activeEmbeddedFormula` is overwritten/uninstalled by whichever flow runs last,
   with cancellation indistinguishable from failure. A generation token + "only uninstall what you
   installed" rule fixes the family.
3. **Slot-index identity** for warp ops (H10, M16) vs UUID-keyed everything else.
4. **Main-actor I/O**: NavigationStore persist, PresetManager scans/encodes, SettingsPersistence
   encodes, QL decode/compile — all movable off-main with existing in-repo patterns to copy.
5. **The frame-delta plumbing assumes 90 Hz** (H5) — one accumulator fixes animation, audio, and
   any consumer of `pendingDeltaTime`.

## VERIFIED CLEAN (checked, don't re-hunt)

- In-flight semaphore vs 2-slot uniform/bench/rate-map rings; GPU-stall empty-frame token accounting.
- Pipeline key grammar ↔ FC sets (render/compute/cone/Mac-mono), warm-start parity, coarse sentinel,
  grid-dim constants single-sourced, distance-cache quantization + bake→march ordering, warp pack
  order = GPU apply order, simplifier rules exact; struct padding across FormulaParams/SpaceWarpOp/
  EnvScrunchParams/DistanceCacheParams.
- `catalog.json` ↔ `FractalModelType` raw values (12/12); shipped `.threshfx` examples + Polychora
  scene conform to the embedded-DE contract; `customRegistrationToken` consumers all compare the token.
- Analytics consent gated on every upload path (sample/endSession/submit/pending-flush); preset names
  discarded; `PrivacyInfo.xcprivacy` declarations match real usage; MetricKit retention bounded (5+5).
- `withPersistenceSuppressed` re-entrancy (depth counter under lock, all 9 persist helpers guarded);
  GPU `groupControl` bit layout matches CPU packing.
- AudioHub timer/render double-tick guarded; duplicate-mapping sanitizer covers all write paths;
  space-warp audio offsets don't accumulate; NaN paths into render params guarded end-to-end;
  BPM synthetic bands guarded (no ÷0); zero-duration keyframe segments clamp.
- No retain cycles in AppModel/UI closures; no missing NotificationCenter removals; startSync/stopSync
  balanced at all in-scope sites; MacRadialInputMonitor removed via dismantle; AppIntents nil-guard `AppModel.shared`.
- CI job graph sound (no secrets, `persist-credentials: false`); `stamp_git_sha.sh` handles detached
  HEAD/shallow clones; `check_no_large_files` threshold healthy vs largest tracked file (5.44 MB).
- ControlStateStore startSync/stopSync, InputOwnershipStore release matching, `AudioHub` timer
  skip-guard (50 ms), keyframe zero-duration clamp — all verified sound.