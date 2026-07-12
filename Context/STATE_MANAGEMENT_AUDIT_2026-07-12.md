# State Management and Restore Audit

Date: 2026-07-12

## Outcome

Threshold now has an explicit ownership model for state instead of treating every live `RenderSettings` value as interchangeable:

- **Scene state** describes an authored visual/interactive scene and travels in scene and animation documents.
- **Device/user state** describes preferences and hardware tuning that must survive scene changes.
- **Session state** restores the exact app mode and current work after relaunch or preview cancellation.
- **Transient/derived state** is rebuilt at runtime and is intentionally never serialized.

The canonical scene carrier is `SceneState` (schema 1), embedded in `FractalPreset` schema 3 and optionally in `AnimationScene.baseline`. New files are dual-written with the older flat fields so older Threshold builds can still read the portions they understand. Existing scene, music-preset, and animation documents continue to decode without migration in place.

## Corpus studied

The audit covered the complete application state surface, all configuration domains, every scene/animation load path, UI caches and lifecycle hooks, storage and iCloud mirroring, SharePlay, Quick Look, and the alternate Buddhabrot renderer.

The shipped compatibility corpus currently contains:

- 45 `.threshscene` documents, including 7 Mixed scenes and 1 embedded custom-formula example.
- 2 `.threshmp` music-reactive preset documents.
- 12 `.threshanim` animation documents.
- 47 unique preset documents and 12 unique animations after bundle deduplication.

All of these decode in the clean test run. Every embedded custom distance estimator also compiles through the production Metal compiler path.

## Ownership model

| Ownership | Lifetime | Canonical carrier | Restore policy |
| --- | --- | --- | --- |
| Scene | Save, share, reset, animate | `SceneState`; embedded formula beside it | Authoritative for scene lanes; merged over destination device settings |
| Device/user | Across scenes and launches on that installation | Typed `SettingsPersistence` domains plus a few deliberately local `UserDefaults` keys | Restored before the session scene; never rewritten by scene playback |
| Session | Relaunch, preview rollback, current renderer mode | Last-state `FractalPreset`, `RuntimeViewMode`, `BuddhabrotConfig` | Exact restore (`SceneRestoreScope.session`) |
| Transient/derived | Frame, gesture, playback, GPU-resource lifetime | Memory only | Cleared or recomputed at transition boundaries |

Two restore scopes encode the only intentional exception to exact scene replay:

- `.scene` is used for ordinary shared/authored scenes. It may enable a comfort bubble but cannot disable the user's already-enabled bubble.
- `.session` is used for relaunch checkpoints and preview rollback. It reproduces the captured safety state exactly.

## Scene-owned state now covered

### Geometry and formula

- Fractal model type and all 16 formula parameter slots.
- Mandelbox-compatible minimum distance, folding limit, sphere radius, and fractal scale.
- Base scale, position, world rotation, and detail scale.
- Typed module blocks and an optional embedded distance estimator remain beside the canonical envelope for formula installation and old-reader compatibility.

### Color and lighting

- Color scheme, full gradient state, mapping, repeat/offset/smoothing, grading, lighting softness, toon shading, ambient occlusion, tone mapping, and automatic color transitions.
- Lighting preset and mode, play state, variation rate, hue, pulse, glow, bloom, edge, fog, gradient-cycle, linear-rail, beat-flash, polar-rotation, and Julia-drift effects.
- Runtime effect clocks are excluded and reset when a new authored scene starts.

### Space, motion, and presentation

- Spherical inversion, sphere projection, DE iteration mismatch, platform visibility/radius, direct custom-warp strength/origin/axis, and the ordered composable warp stack.
- Infinite-zoom enabled state and rate.
- All three visionOS presentation intents (`window`, `mixed`, and `immersive`), replacing the old two-state `mixedModeScene` representation while retaining that field for old readers.

### Containment and scene-quality intent

- Base fractal iterations and ray-step budget.
- Shadows, bounding-shape enable/radius/type/fog/shadow-depth, environment-scrunch parameters, and zoom-fog compensation.
- Per-scene cone-march compatibility and recommended-quality hints. These can suppress an incompatible optimization or request a sharper floor; they do not enable a destination device's acceleration features.
- Resolution scale and tile size remain optional compatibility fields. Normal scene switching passes `includePerformance: false`; an exact session checkpoint can restore them.
- The removed assumed-room bounding feature is decoded for compatibility but is never re-enabled.

### Interaction and audio that affect the authored result

- Full safety-bubble shape/radius/blend/fade and Mixed-mode comfort behavior, subject to the shared-scene safety rule above.
- Full hand-attraction configuration.
- Full audio-reactive configuration: master state, amount, sensitivities, beat behavior, triplet gains, and target mappings.
- Music provider credentials, selected service, and application chrome are not scene state.

## Device/user state deliberately not placed in scenes

These settings remain on the destination installation when a scene is loaded:

- Adaptive render quality and the visionOS render-quality ceiling.
- Foveation, coherent packets, temporal reprojection, coarse warm-start, smart advance, cone-march strength, cone-coverage AA, over-relaxation, distance LOD, debug hierarchy, and other hardware/path tuning.
- Gesture bindings, relative gesture mode, menu gesture behavior, per-finger tap behavior, handedness, and Mac tilt control. A small number of named scenes still install deliberate gesture overrides at runtime without persisting them.
- Music service preference/priority, UI navigation state, music shortcut visibility, storage location, hidden/default-library metadata, and analytics.

`SceneState.apply` merges only the authored slice of the quality and display domains over the current destination configs, which is what keeps these values intact.

## Session state beyond raymarch scenes

The alternate Buddhabrot application mode was previously outside the restore system. It now has a tolerant `BuddhabrotConfig` checkpoint for all user-authored controls: volume resolution and orbit parameters, RGB/density/transfer colors, batching, ray-march controls, transform/rotation, renderer choice, and Gaussian-splat budget/shape/opacity/brightness. GPU buffers, counters, clear generations, and accumulated density remain transient.

`RuntimeViewMode` is now persisted independently, so relaunch restores whether the user was in raymarch or Buddhabrot mode. The Buddhabrot config is restored before rendering and saved with the normal app checkpoint.

## Transient and derived state intentionally excluded

- Live FFT/band/onset values and per-target audio offsets.
- Gesture/manual offsets, animation-base overlays, transition velocities, and keyframe playhead state.
- Hue/pulse/fog/gradient/polar/Julia effect clocks and accumulators.
- Adaptive-quality controller history and live render metrics.
- Scanned-room meshes/SDF grids, hand poses, tracking state, renderer warmup state, specialized pipelines, texture/buffer caches, and Buddhabrot accumulation.

Scene application clears the relevant manual/audio overlays, resets effect phases for a new authored scene, and lets the renderer rebuild the derived pieces.

## Restore and mutation flow

Startup now applies layers in this order:

1. Code defaults and narrowly scoped legacy-key initialization.
2. Typed device/user configuration domains.
3. Buddhabrot configuration and renderer-mode preference.
4. Last-state scene with exact session scope.
5. Embedded formula/space-warp installation when required.

Previously, step 4 ran before step 2. The later domain restore could stomp the scene, while persisting setters fired during the scene apply and wrote intermediate hybrids. Scene, session, preview, and animation mutations now run through `RenderSettings.withPersistenceSuppressed`, establishing a mutation-origin boundary: the live renderer changes, but those changes do not feed back into device preference blobs.

Continuous user edits now use a 300 ms trailing debounce. The previous leading-only one-second throttle commonly persisted the first slider sample and lost the user's final value. An explicit save cancels the pending domain task and writes the latest complete config. Lifecycle checkpointing flushes only pending user-origin payloads; it no longer blanket-serializes the live renderer after a scene or animation has changed it.

## Entry-point coverage

| Entry point | Current behavior |
| --- | --- |
| Static scene/browser/keyboard/import | Installs embedded effect, applies canonical scene state without preference writes, clears transient offsets, preserves device tuning |
| App relaunch | Restores device base first, then exact last scene and alternate-renderer session state |
| External preview cancellation | Exact session-scope rollback, including safety state |
| Reset point | Stores canonical `SceneState`; updating it immediately recaptures the active baseline while preserving scene identity |
| New animation | Captures a full `SceneState` baseline, then keyframes animate focused lanes over it |
| Legacy animation | Uses existing scene fields and authoritative defaults; remains decodable |
| Live recording | Captures the non-animated baseline at record start and includes base scale in interpolation/simplification |
| UI cache/lifecycle | View appearance no longer forces gesture preferences or mutates containment; platform toggles write through to `RenderSettings`; live stats refresh on active Mac/iOS windows and active visionOS immersion |
| Preset/animation file replacement | Writes the new atomic file before removing renamed/recategorized old copies |
| Root/iCloud discovery | Queues writes made before the active root resolves, then flushes them before folder-as-truth reload |

Migration and seed markers are now committed only after their writes succeed. A corrupt legacy aggregate is left retryable instead of being marked migrated and silently abandoned.

Local preset/animation writes also invalidate any detached folder scan that began before the edit. Animation library saves batch all successful writes and perform one duplicate-cleanup scan, avoiding stale-scan replacement and the former per-scene repeated folder decode.

## Compatibility behavior

- `FractalPreset` continues to encode legacy flat fields alongside schema-3 `sceneState`.
- Canonical-only schema-3 documents are valid: required legacy render keys are optional when `sceneState` exists, and a decode/re-encode cycle retains canonical-only apply semantics.
- `AnimationScene.baseline` is optional; all existing animation documents decode through the old path.
- Geometry and color domain decoders now tolerate absent keys, matching the already-tolerant domain configs.
- A legacy scene authoritatively clears state it could not represent (direct warp, infinite zoom, lighting playback, and related new lanes) rather than inheriting it from the previously loaded scene.
- Embedded space-warp payloads no longer force the fractal model to `.custom`; only embedded fractal distance estimators do.
- Music-preset folder classification consults canonical audio mappings as well as legacy mappings.
- Persisted Buddhabrot allocation controls are validated against the same ranges/options as the UI before texture or buffer sizing.

## Verification

The clean macOS test target rebuilt the app, Quick Look extensions, and test bundle and passed **151 tests in 28 suites**. Coverage includes canonical capture/encode/decode/apply, canonical-only documents, scene-versus-session safety policy, legacy-animation authoritative defaults, user-origin persistence flushing, SharePlay comfort policy, device-preference preservation, validated Buddhabrot checkpoints, animation baselines and scale interpolation, iCloud deletion safety, all bundled document decoding, and embedded Metal formula compilation.

Generic iOS and visionOS builds are also part of the final platform verification.

## Remaining work and deliberate limits

These are not blockers for the new schema, but they are the next useful state-system investments:

1. **One-lock authored snapshots.** Each domain snapshot is internally consistent, but `SceneState(capturing:)` currently reads several domains in sequence. A single renderer-wide authored-state snapshot would eliminate the small chance of a cross-domain hybrid if capture happens during active modulation.
2. **Embedded-formula activation from the animation library.** Imported custom animations install their formula, but selecting a saved embedded-formula animation directly in `AnimationViews` still needs an async install/activation hook before playback.
3. **SharePlay protocol v2.** The low-latency `FractalSyncMessage` intentionally carries only a small legacy subset. Remote applies now use the same mutation-origin and comfort policies, but the protocol should eventually separate a one-time `SceneState` baseline message from compact per-frame camera/parameter deltas.
4. **Two legacy MSP fidelity outliers.** `Disguise` and `Vampire` used the removed Mandelbox Sphere Projection estimator with negative minimum-distance behavior that the base Mandelbox estimator cannot reproduce exactly. They decode and render, but exact visual equivalence requires retaining or reintroducing that estimator behavior.
5. **Forward unknown-field preservation.** Unknown JSON fields are ignored safely, but an older build that reads and then re-saves a newer document cannot preserve fields it does not understand. A raw extension bag would be needed for lossless down-level editing.
6. **Default-library overlay consolidation.** Bundled documents, hidden-default IDs, edited-default overrides, and user files are still separate persistence mechanisms. A single explicit overlay/tombstone model would simplify multi-device conflict rules.
7. **Quick Look animation parity.** Static scenes use the production preset apply path, but animation documents still render an information card rather than their canonical baseline/first keyframe.
