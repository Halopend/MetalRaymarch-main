# Threshold — Tech Debt Register (updated 2026-08-17)

> **2026-08-17 refresh** (full re-verify of every open item + delta scan of the **44
> commits since 07-18** — live formula editor, audio overhaul, EDR/HDR grading,
> distance-cache atlas, spatial radial menu, music-cue scene switching, MetricKit
> reporting — plus the uncommitted recording-mode working tree and an
> infrastructure/hygiene sweep):
>
> **Metrics:** `RenderSettings.swift` is **5,117 lines / 502 `withLock` sites**
> (+461/+7 in a month — #12 keeps growing); tests are **52 files / 407 `@Test`
> cases** (33/219 → nearly doubled; the month's features landed heavily tested;
> `RenderCheckMain.swift` is compiled ad hoc by the QL gate, not a pbxproj member);
> concurrency markers **57 `nonisolated(unsafe)`** (−12) **+ 65 `@unchecked
> Sendable`** (+5); still **zero** TODO/FIXME/HACK, zero third-party deps.
>
> **The register's top prediction came true.** #21's function-constant drift is no
> longer hypothetical: `MacBenchmarkHarness.swift:308` sets index **17** under a
> `FC_HAS_HANDFIELD` label, but 17 is `FC_SPHERE_PROJECTION_ENABLED`
> (`Shaders.metal:158`; the hand field is 18 and is never set there), so
> harness-specialized pipelines bake the wrong feature pair. The literal-mirror
> count also went **1 → 3 sites** (`ViewportSpecializedPipelineCache.swift:170-198`
> is new) and a **stale C-enum copy** of the map sits in `ShaderTypes.h:62-79`,
> stopped at 15. #21 re-scored **P 40**; it is the top item and its fix now
> includes a live bug fix.
>
> **Closed since 07-18:** **#8a** (the "freshness check" disjunct landed:
> `Scripts/ql_render_check.sh:66-79` parses `SHARED_SOURCES` out of
> `wire_quicklook.rb` and compiles that exact closure with a ≥30-file parse guard,
> on CI every push — the list is still hand-maintained, but drift now fails the
> gate instead of breaking a session). **#3 SHRANK** (`AnimationKeyframeBatchTests`
> landed 07-25, header names this register; pins the three stomp regressions;
> remaining: the **recenter** path — `ParameterPipeline.recenterMusicBase:374`,
> `ParameterNodeSystem.recenterBase:230`, zero refs — and the new fact that the
> offset-around-animation invariant now lives in **two implementations**,
> `RaymarchRenderView.swift:1601-1615` "must match GestureProcessor").
> **#8 SHRANK sharply** (literal `range:` sites **63 → 16** — 8 in App/Views
> cited in the table, 8 in Audio; 76 `ControlSpec`s; `ControlCatalogConvergenceTests`
> + the `ParameterCatalogTests:29` exact-coverage assertion landed in `d8f5b1b7`).
>
> **New items #25–#44**, three sources: the committed-delta scan (**#25–#36**),
> the uncommitted recording-mode tree (**#37–#39** — note #39: the 4 untracked
> `.threshmp` presets are **already read by two test suites** via `#filePath`, so
> local runs exercise 23 presets while CI exercises 19 — a silent local-green ≠
> CI-green divergence that also inflates the ~226 s formula-compile test), and the
> infra sweep (**#40–#44** — incl. ~600 MB of reclaimable `.git` and a
> `CONTRIBUTING.md` claim that routes contributors to a scheme that runs **zero
> tests** and reports green).
>
> **Standing-rules compliance in the window was otherwise strong:** both new
> persisted fields (scene tags in `FractalPreset` + `AnimationScene`, mic-on-launch)
> shipped same-commit round-trips; formula-editor input is validated (64 KB cap,
> `#include` rejection) and opt-in gated behind `allowCustomScenes` default-false;
> benchmark/ablation affordances are env-gated default-off; music-cue gating is
> pure and covered (270-line suite); the macOS audio-input crash fix is root-cause
> with same-commit tests; input/nav unification genuinely **deleted** the legacy
> paths (440+/621−). `ROADMAP.md` predated this whole window — refreshed alongside
> this file.
>
> **#16 note:** still PROPOSED, but its decision inputs are aging while the month's
> work executes rebuild concepts *in place* (live formula editor ≈ a Shader IR
> seed; ControlCatalog convergence ≈ ParameterCatalog). Record the go/no-go or
> retire the document — the register keeps #10–13 parked either way.
>
> **Watch-list:** second-tier god objects forming behind #12 —
> `AnimationManager.swift` **2,632** (+517 in one commit), `RadialMenu.swift`
> **2,069**, `MusicTabView.swift` **2,048**.

> **2026-07-18 progression refresh:** #5 (CI) and #8c (Mixed-scene resource
> validation) are closed. The active order now lives in [`ROADMAP.md`](ROADMAP.md),
> while this file remains the evidence-backed debt register. Current branch metrics:
> `RenderSettings.swift` is **4,656 lines / 495 `withLock` sites**; tests are **33
> files / 219 passing tests**; concurrency markers are **69 `nonisolated(unsafe)`**
> + 60 `@unchecked Sendable`**. The next regression leverage is #3, #20, then
> the #21/#22 lockstep seams.

> **2026-07-16 refresh** (full item re-verify + scan of the input-menu, iPad, formula,
> construction-primitive, and persistence commits since 07-09:
> input-menu overhaul, scene-state persistence overhaul, temporal starts; supersedes the
> 07-09 numbers below): `RenderSettings.swift` is **4,654 lines / 495 `withLock` sites**;
> tests are **28 files** (16 → 28 — the persistence/menu work landed heavily tested);
> concurrency markers **66 `nonisolated(unsafe)` (flat) + 57 `@unchecked Sendable`** (+10;
> only one inside the audited window — `BoxFoldMandelbulbDescriptor`, covered by the
> documented class-level immutability rationale). **Closed since:** #15
> (`recreateLegacyComputeCacheBug` — 0 hits, removed), #18 (`EnvironmentSDFTests` landed),
> #19 (`farClampModel` carried in `EnvScrunchParams`; comment-contract deleted). **#8b is
> near-done** (all 9 domain configs have tolerant decoders; the `{}` pin covers 3/9).
> **#16 still PROPOSED** — no go/no-go recorded; #10–13 stay parked. **New items #20–#24**
> from two sources: the new-work scan (#20 `WarmStartGate` untested-but-default-on, #22
> `boxFoldMandelbulb` lockstep) and
> [`Context/CONSOLIDATION_REVIEW_2026-07-11.md`](Context/CONSOLIDATION_REVIEW_2026-07-11.md)
> — a tiered consolidation backlog tracked as one entry (#24) with its two hottest items
> promoted (#21 `FunctionConstantIndex` lockstep, #23 horizon triplication). The recent
> feature work otherwise followed the standing rules: new controls are catalog-backed with
> range tests (the #8 tail did NOT grow), legacy nav enums were canonicalized under new
> tests rather than left dead, and persisted fields shipped with same-commit round-trips.
> Below itemization threshold, noted only: `EdgeDetectionEffect.normalize()`'s
> legacy-migration branch is untested (`LightingTypes.swift:220-229`) and the
> `vignetteStrength` default literal appears at 3 sites (house convention; range/clamp do
> read the shared spec). Smart advance is now an explicit opt-in (commit `4f53414`);
> validated temporal reprojection remains default-on, so #20 stays focused on
> `WarmStartGate` coverage.

> **2026-07-09 refresh** (counts re-verified against the tree; supersedes the
> 2026-07-04 numbers below): `RenderSettings.swift` is **4,571 lines / 489 lock
> sites**; **16** test files; concurrency markers **66 `nonisolated(unsafe)` +
> 47 `@unchecked Sendable`**. **Closed since:** #17 (`handEffectsBeta` fully
> removed — 0 code hits) and #2 (a shared `Uniforms` builder landed —
> `Threshold/Rendering/Core/UniformsBuilder.swift`, all three call sites now call
> `assembleUniforms`; verified 2026-07-10 by the clean 94-test run, all three app
> builds, and the 37-scene Quick Look render check). **#8d superseded:** the by-value occupancy concern was
> resolved by moving the hand field, space-warp stack, and Env Scrunch behind
> pointers — the `static_assert`s are now `FractalParams ≤ 160`, `Uniforms` /
> `TileUniforms ≤ 2048` (`Shaders.metal:628`, `ShaderTypes.h`). All 304/320/1936 B
> figures below are historical. The 2026-07-07 audit in
> [`Context/TECH_DEBT_AUDIT_2026-07-07.md`](Context/TECH_DEBT_AUDIT_2026-07-07.md)
> is the more current companion.


Companion to [`PERF_PUSH.md`](PERF_PUSH.md) (ALL performance debt lives there — not
duplicated here) and [`Context/CLEANUP_AUDIT.md`](Context/CLEANUP_AUDIT.md) (132
verified dead-code/duplication items — referenced as one backlog entry here).
Scored with the same formula: **Priority = (Impact + Risk) × (6 − Effort)**, each 1–5.

Ground truth: repo-wide scan 2026-07-01 + session incidents 2026-07-01/02, re-verified
2026-07-04/07-09/07-13/07-16/07-18, **fully re-verified against the tree 2026-08-17**
(every open item re-located and re-checked; counts refreshed; new items #25–#44 from a
three-way scan: committed delta 07-18→08-17, uncommitted working tree, infrastructure).

## Health summary

Still unusually clean for its size: **zero TODO/FIXME/HACK markers**, no `try!`, no
third-party dependencies, and the standing rules held through a heavy feature month
(persisted fields shipped with round-trips; measurement affordances env-gated
default-off; legacy paths deleted, not shadowed). Refreshed counts (**2026-08-17**):
`RenderSettings` is **5,117 lines / 502 `withLock` sites**; tests **52 files / 407
`@Test` cases**; concurrency markers **57 `nonisolated(unsafe)` + 65 `@unchecked
Sendable`**.

The debt concentrates in four places now: **Swift↔Metal identity seams held by
comments** (#21 — drift already realized — plus its new siblings #27/#29 and the
long-standing #22/#23); **missing pure-logic tests on default-on or persistence
paths** (#20, #3-remainder, #26, #30, #37); **the RenderSettings god object and its
forming second tier** (#12 parked; AnimationManager/RadialMenu/MusicTabView on watch);
and **operational envelope that exists only as tribal knowledge** (#43 — including one
flatly false `CONTRIBUTING.md` claim). The rebuild fact stands:
[`Context/REBUILD_ARCHITECTURE.md`](Context/REBUILD_ARCHITECTURE.md) is still PROPOSED
(#16) — big in-place arch refactors stay off the table, seam-hardening remains correct
on either path, and the month's formula-editor/ControlCatalog work suggests the rebuild
is quietly happening incrementally anyway. Record the call.

## Register — scored

| # | Item | Type | I | R | E | P | Status / evidence |
|---|------|------|---|---|---|---|----------------|
| 21 | **`FunctionConstantIndex` lockstep — drift REALIZED**: enum still visionOS-locked (`RendererCoreTypes.swift:16-38` behind `import CompositorServices`); literal mirrors now at **3 sites** — `ViewportSpecializedPipelineCache.swift:170-198` (new, all 11 indices), `RaymarchRenderView.swift:1975,1977`, `MacBenchmarkHarness.swift:289-312` — plus a stale C enum at `ShaderTypes.h:62-79` (stops at 15). **Live bug:** `MacBenchmarkHarness.swift:308` sets index 17 labelled `FC_HAS_HANDFIELD`; 17 is `FC_SPHERE_PROJECTION_ENABLED` (`Shaders.metal:158`), 18 (the real hand field) is never set — harness pipelines specialize the wrong features. Fix: one dependency-free shared enum (Core file compiled into every target), all callers use `.rawValue`, correct the harness pair, delete/regenerate the stale C copy | Code | 4 | 4 | 1 | **40** | **GROWN 2026-08-17** — the failure mode this item predicted ("wrong feature toggle baked into specialized pipelines, no error anywhere") has occurred, in the benchmark harness. Single sitting, highest priority on the register. |
| 27 | **Mac motion/blit param structs comment-mirrored outside `ShaderTypes.h`**: `ViewportMotionParams`/`ViewportBlitParams` (`RaymarchRenderView.swift:301-317`) hand-mirror `MacMotionParams` (`Shaders.metal:5399`) and `MacBlitParams` (`Shaders.metal:5349`), which are declared inline in the shader instead of the shared bridging header. Held together by a "Mirrors…" comment only. Fix: move both into `ShaderTypes.h` + `static_assert` sizes, the house pattern | Code | 3 | 4 | 1 | **35** | **NEW 2026-08-17** (delta scan). A field add/reorder silently mis-binds the motion-vector or edge-detect pass (ghosting/wrong outlines), no compile error — the exact disease `ShaderTypes.h` exists to prevent. |
| 29 | **`AtlasKey` → seed-file identity hand-enumerated ×3, zero tests**: 14 fields listed independently in `init(settings:gridDimension:)`, `label`, and `fileName` (different orders) at `FractalDistanceCache.swift:49-124`; `fileName` IS the persisted `.mbseed` identity. No test references `AtlasKey`. Fix: derive label/fileName from one field list + a completeness pin + a golden-filename test | Code/Test | 3 | 4 | 1 | **35** | **NEW 2026-08-17** (delta scan, `52d807d9`). Forgetting `fileName` when adding a DE-shaping field makes two parameter states share one baked distance field — wrong renders persisted across launches, indistinguishable from a shader bug. |
| 26 | **Band-level sensitivity mapping implemented ×3, untested**: `clamp01(feature × sensitivity)` + inactive/non-finite zeroing for bass/mid/treble/beat re-implemented at `Renderer.swift:1244-1253` (visionOS), `RaymarchRenderView.swift:1623-1660` (Mac/iPad), `MusicTabView.swift:1697-1706` (the UI meter meant to show what the renderer sees). Fix: one shared pure helper + tests; drop the redundant outer clamp (`RenderSettings.swift:905-925` already clamps on set) | Code/Test | 3 | 3 | 1 | **30** | **NEW 2026-08-17** (delta scan, audio overhaul). Same shape as the pre-`UniformsBuilder` #2 that bit three times in three days; the meter silently desyncs from the render when a lane/curve changes. |
| 33 | **Analytics CloudKit record: no enforced size cap, silent failure, public DB**: `UsageAnalytics.swift:580-610` writes the compressed archive incl. up to 5 raw `MXDiagnosticPayload` JSONs (crash/hang stacks) into `reportArchiveBase64` on the **public** database (`:312`), gated by `analyticsEnabled` which **defaults true** (`:145`); the size bound exists only as a comment and an over-limit save is swallowed as `.failed` (`:608`). `PRIVACY_POLICY.md:36-41` does disclose the collection — the debt is the missing enforced cap, the silent failure, and the unrecorded public-scope decision | Arch | 2 | 4 | 1 | **30** | **NEW 2026-08-17** (delta scan, `f16144a9`). Enforce the byte cap + surface failures (single sitting); record or revisit default-ON/public-DB as an explicit decision. |
| 43 | **Operational envelope is tribal knowledge + one false doc claim**: `CONTRIBUTING.md:33` says the visionOS `Threshold` scheme "owns the test action" — its `<TestAction>` is **empty**; a contributor following it gets a green run with **zero executed tests** (`ThresholdMac.xcscheme` holds the only `TestableReference`). Also undocumented anywhere in-repo: the shared DerivedData path = **one `xcodebuild` at a time** (`build.sh:90`; `THRESHOLD_DERIVED_DATA_PATH` escape hatch documented nowhere), and `ThresholdTests` **boots the full GUI app** (`TEST_HOST`, `project.pbxproj:1897`) so `build.sh test` (a `clean test`) costs 4–8 min with ~226 s in one formula-compile test cold; `testfast` and the `ios` subcommand are absent from `CONTRIBUTING.md`/`README.md`; `CONTRIBUTING.md:14` omits iOS from `all`; `:54-56`'s raw command omits the three flags that make runs trustworthy. Fix: one "Local build constraints" section + correct the table row + note that visionOS/iOS schemes are compile-only by design | Docs | 3 | 3 | 1 | **30** | **NEW 2026-08-17** (infra sweep). The false claim fails silently in the passing direction — the most dangerous doc error; the missing envelope facts are the two that most degrade agent/contributor effectiveness (parallel builds into a shared lock; timeouts against an unknown GUI test host). |
| 20 | **`WarmStartGate` tolerance math untested while default-ON**: `GeometryKey.matches` 3%-relative tolerance now at `RendererCoreTypes.swift:116-131`; default-on ×3 (`RenderSettings.swift:259`, `QualityConfig.swift:213,396`), consumed `Renderer.swift:1867-1868`; still **0 test hits** for `warmstart|geometrykey` — `QualityConfigCodableTests` pins only the bools' persistence. Pure and host-testable | Test | 3 | 4 | 2 | 28 | **OPEN** (unchanged 2026-08-17; re-located). Too-loose = stale warm starts (ghost geometry) on the DEFAULT path; too-tight = the accelerator silently does nothing. |
| 22 | **`boxFoldMandelbulb` triple-site lockstep + missing round-trip**: rawValue `18` at `ShaderTypes.h:93`, `FractalModelType.swift:21`, `FractalTypeDescriptor.swift:532`, comment-synced; family predicate inlined at 6 sites (`Shaders.metal:2151,2623,2780,3007,3253,3972`), no `isMandelbulbFamily()`; no persistence suite round-trips `.boxFoldMandelbulb`. One sitting: shared family helper + rawValue-agreement test + one round-trip assertion | Code | 2 | 3 | 1 | 25 | **OPEN** (re-verified 2026-08-17; `f55dd8f4`'s new DE is `FractalTypeCustom = 1000` — added **no** new lockstep site; `AppIntents.swift:374,388` maps by `codableString`, safe). |
| 25 | **Live-editor `MTLLibrary` cache unbounded; its eviction API is never called**: every debounced compile (0.9 s cadence, `FormulaEditorModel.swift:77`) mints a fresh full-superset library retained for the session (`CustomShaderCompiler.swift:113`); `evict(combinedHash:)` (`:207`) has **zero call sites**, and the two doc comments contradict (`CustomShaderCompiler.swift:203-206` "the editor uses this" vs `FormulaEditorModel.swift:24-26` "left in cache for the session"). Pipelines ARE bounded (MRU-4, `RendererCustomShader.swift:225`) | Code | 2 | 3 | 1 | 25 | **NEW 2026-08-17** (delta scan, formula editor). Long editing session accumulates hundreds of multi-MB libraries; opt-in path, but the fix is wiring a call that already exists + reconciling the comments. |
| 31 | **QL render gate's non-black allowlist stale: 18 names / 56 bundled scenes**: `RenderCheckMain.swift:31-38` hardcodes `wellFramed`; 19 scenes added this window, none listed — they are only asserted non-nil. `f55dd8f4`'s message claims the new scene is "covered by the QL render gate (renders non-black)" — it is not | Test/Infra | 2 | 3 | 1 | 25 | **NEW 2026-08-17** (delta scan). CI runs this gate every push; a camera/scale regression blacking out the new catalog passes green. Single sitting to add names; 1–3 days to derive the list instead. |
| 34 | **SCK scratch-buffer reuse invariant is comment-only on an `@unchecked Sendable` sink**: `SystemAudioTapCapture.swift:409-419` — mutable `scratchPCM`/`scratchASBD` justified by "consumed synchronously inside `ingest`" / "audioQueue-confined", with no `dispatchPrecondition` in the file | Code | 2 | 3 | 1 | 25 | **NEW 2026-08-17** (delta scan, audio overhaul). One line converts the comment into a runtime check; any future consumer that retains/async-hops the buffer gets silently overwritten samples. |
| 37 | **Recording-mode window/chrome state machine has zero tests** (uncommitted): `AppModel.swift:161-171` (5 fields) + `:906-946` (5 methods) — a monotonic wrapping generation counter + four interacting booleans whose whole purpose is correctness under out-of-order window callbacks; pure, synchronous, UI-free; 0 test hits. House precedent exists (`ViewportInputTests` covers the analogous accumulator). Pin: request→appear→disappear ordering, stale `onDisappear` after a newer request, `generation: nil` no-op (`:941`) | Test | 2 | 3 | 1 | 25 | **NEW 2026-08-17** (working-tree scan). Cheapest now, while the code is fresh and uncommitted; also the `DispatchQueue.main.async` reopen trampoline (`ThresholdMacApp.swift:543`) is exactly the ping-pong the counter was added to prevent — name its terminating condition. |
| 39 | **4 untracked `.threshmp` presets are already read by two test suites**: `ExampleSceneDecodeTests.swift:40` + `EmbeddedFormulaCompileTests.swift:62` enumerate the working-tree directory via `#filePath` — local runs decode/compile **23** presets, CI **19**; a preset can only fail on this machine, and local green certifies files no reviewer has. All Threshold/ files ship via the synchronized root group, so these WILL ship from this machine only. 2 of 4 are mode 0600 (app-written scratch saves?) | Infra | 2 | 3 | 1 | 25 | **NEW 2026-08-17** (working-tree scan). Decide today — commit the intended ones, delete the scratch; they also silently inflate the ~226 s cold compile suite. |
| 3 | **Parameter-layering tests — remainder**: `AnimationKeyframeBatchTests.swift` (landed `30420c0c`, header cites this item) pins immediates-fold-audio, grab-composes-not-stomps, zoom floor, glow layering. Remaining: **recenter** (`ParameterPipeline.recenterMusicBase:374`, `ParameterNodeSystem.recenterBase:230` — zero refs) and the offset-around-animation invariant now implemented **twice** (`RaymarchRenderView.swift:1601-1615` "must match GestureProcessor") — pin both or unify | Test | 3 | 3 | 2 | 24 | **SHRUNK 2026-08-17** (was the most re-broken math with zero coverage; now 5 cases pinned). Finish the recenter case + twin-implementation pin in one sitting; still the rebuild's Modulation Engine behavior pin. |
| 23 | **Trace-horizon derivation triplicated** (~95 lines): `RaymarchRenderView.swift:1804-1836`, `RendererGameState.swift:228-265`, `HeadlessRenderer.swift:77-92` — all carry `traceScaleFloor` 0.02/0.15, caps 420/80/880, divisor-floor guard, "mirrors the Mac guard" comments. Extract `RenderPrecompute.horizonTargetDistance(...)` (`RenderPrecompute.swift` has 8 statics, none horizon-related); callers keep their smoothers | Code | 3 | 3 | 2 | 24 | **OPEN** (re-verified 2026-08-17, exactly 3 copies, none drifted yet). Same disease #2 had before `UniformsBuilder`; extract BEFORE the next horizon change, not after the third copy drifts. |
| 6 | **Concurrency-safety pass**: 57 `nonisolated(unsafe)` + 65 `@unchecked Sendable`. Spot-check: newest are mostly documented (`AudioAnalyzer.swift:525`, `SystemAudioTapCapture.swift:370`, `FormulaLibraryStore.swift:41`, `FractalDistanceCache.swift:148`), but bare/underdocumented sites exist — sharpest: **`AppModel.handTrackingEnabledForRenderer` (`AppModel.swift:349`)**, a new plain `nonisolated(unsafe) var` written from MainActor (`:340,:600`), read from the render thread (`RendererFrameLoopHelpers.swift:126`), unguarded while neighbours use `Mutex`; also `Renderer.swift:388` (`roomUpdatesTask`), `AudioHub.swift:25` (`AudioFeatureStore`, no comment), `AudioAnalyzer.swift:117,120,124`, `ViewportSpecializedPipelineCache.swift:73,89`, `MetalFXUnavailableUpscalers.swift:29`, `BuddhabrotRenderer.swift:533` | Code | 3 | 4 | 3 | 21 | **OPEN, risk raised** 2026-08-17 (unguarded cross-thread mutable on the frame loop). Swift-6 strict concurrency forces this eventually; sequence with #24's 2.7 `@Locked` shrink. Fix the `handTrackingEnabledForRenderer` site ahead of the full pass. |
| 8 | **ControlSpec tail — finish line visible**: literal `range:` sites **63 → 16** (8 in App/Views: `ContentView+FractalTab.swift:146,596,617,630,643`, `TransformationsSection.swift:2022`, `ContentView+EffectsTab.swift:224`, `RadialNavigation.swift:409`; 8 in Audio); **76** `ControlSpec`s / 79 catalog symbols / 341 refs; convergence + exact-coverage tests landed (`d8f5b1b7`) | Code | 2 | 2 | 1 | 20 | **SHRUNK sharply 2026-08-17.** Mechanical finish, one sitting. Fully subsumed by the rebuild's ParameterCatalog if #16 = go — but at 16 sites, cheaper to just finish. |
| 8b | **Config Codable-tolerance `{}` pins — still 3/9**: `GeometryConfig`+`ColorConfig` (`SceneStatePersistenceTests.swift:148-151`), `QualityConfig` (`QualityConfigCodableTests.swift:35,89`). Missing: `AudioReactiveConfig`, `DisplayConfig`, `GestureConfig`, `HandAttractionConfig`, `LightingConfig`, `SafetyBubbleConfig` — six lines in the existing test | Test | 2 | 2 | 1 | 20 | **OPEN** (unchanged 2026-08-17). All 9 decoders are already tolerant; only the pins are missing. Fold into any sitting. |
| 28 | **`edrHeadroom` doubles as a float-format boolean, contract comment-held across 4 stamp sites**: `Shaders.metal:3784-3790` uses `edrHeadroom > 1.001f` as an exact proxy for "drawable is linear rgba16Float, skip `linearToSRGB`"; stamped independently at `RaymarchRenderView.swift:1899-1903`, `Renderer.swift:1742,2477`, `RendererGameState.swift:384-386` (default `RenderSettings.swift:3129`). Exact today only because the compute kernel is visionOS-only with fixed 2.0 headroom. Fix: explicit `isLinearFloatTarget` flag (or function constant) | Code | 2 | 3 | 2 | 20 | **NEW 2026-08-17** (delta scan, EDR/HDR grading `891c83ca`). A float-format path whose display reports headroom exactly 1.0 double-applies the sRGB transfer. |
| 30 | **`SceneTagging` normalization untested on the default-on persistence write path**: `SceneTags.swift:6-34` (whitespace collapse, case-insensitive dedupe, max 12 tags / 28 chars) gates every tag write (`AnimationManager.swift:1524`, `PresetManager.swift:1173`, `FractalGridView.swift:495`, `TransitionTabContent.swift:307`); zero test refs. Pin while there: over-long tags are silently **dropped**, not truncated | Test | 2 | 2 | 1 | 20 | **NEW 2026-08-17** (delta scan, `52a6a7b1`; the tags' round-trips DID land per the standing rule — this is the normalizer itself). |
| 35 | **Spatial radial menu: ~2.2k lines behind `static let = false`**: gate `AppModel.swift:410`, sole consumer `Renderer.swift:795`; `SpatialRadialMenuRenderer.swift` (758) + `SpatialRadialMenuView.swift` (717) reachable only through it; tests cover only the pure nav state machine. Not env-flippable (rule: measurement/experimental affordances are env-gated), no enable/removal decision or date recorded. Per-frame cost verified zero (early-outs) | Arch | 2 | 2 | 1 | 20 | **NEW 2026-08-17** (delta scan, `48d24230` "gate off for now"). Single sitting: env-gate + record an expiry/decision in the design doc; finishing or deleting is week+ and stays a product call. |
| 38 | **Recording-mode seam batch** (uncommitted, one sitting total): (a) `shouldShowControls` reorder falsified the comment below it (`ThresholdMacApp.swift:293-296` — pending-import early-return now DOES mount a second copy in separate-window mode; restore the why-first rationale); (b) spring literal `response: 0.28/0.82` now ×5 across 3 files (`ThresholdMacApp.swift:789,972,1063`, `ThresholdiOSApp.swift:138`, `FirstLaunchWindowView.swift:107`) while `MenuChrome.panelSpring` is a *different* spring — name it next to `panelSpring`; (c) dual live `NSEvent` monitors: the `event.window === hostWindow` guard (`:208`) is the only thing preventing double-toggle and nothing says the type is multiply-instantiated — 3-line type comment; (d) min-size/background literals moved into the extracted view away from the scene-level policy that consumes them (`:134-135`); (e) Info.plist termination-keys rationale lives only as a plist XML comment (`ThresholdMacInfo.plist:112-117`) — Xcode's plist editor destroys comments; move to `CONTRIBUTING.md`, leave a pointer | Code | 2 | 2 | 1 | 20 | **NEW 2026-08-17** (working-tree scan). Everything else in the diff is CLEAN and above the house bar (no new persisted fields, no new concurrency markers, gated diagnostics, correct test-skip semantics); land these five with the commit. |
| 7 | **Execute CLEANUP_AUDIT backlog** (132 verified items) | Code | 2 | 2 | 2 | 16 | **OPEN** (file untouched since 07-10). Opportunistic rule stands: re-verify an item's 0-hit status before spending a sitting. |
| 24 | **Execute CONSOLIDATION_REVIEW backlog**: re-verified 2026-08-17 — 2.4 `musicReactiveConfig` double-assign STILL PRESENT (now `AnimationTypes.swift:1251/1271` + `:1303/1320`); 1.6 dual formula-default sources STILL PRESENT but narrowed (`RenderSettings.swift:1245-1249` now checks the catalog first; 12 descriptor overrides remain); 2.1 Apple Music adapter merge NOT DONE (adapters still 182/162 lines). Tier-1 items remain the "file is open anyway" default | Code | 3 | 2 | 3 | 15 | **OPEN** (backlog file untouched since 07-12). Its two hottest were promoted long ago (#21, #23); 2.6 `deFamily` still pairs with #22. |
| 32 | **PGO configuration is a hand-cloned third sibling**: two consecutive repair commits (`0d41dd14`, `52318e05`) because the iOS `PGO` config had only `PRODUCT_NAME`; zero `.xcconfig` files in the repo; CI never builds PGO (`build.sh:71` pins Debug) so nothing catches the next drift; `CLANG_USE_OPTIMIZATION_PROFILE = YES` on **15** configurations including Debug; no `CLANG_OPTIMIZATION_PROFILE_FILE`/`SWIFT_USE_PROFILE` anywhere; one tracked 3.3 MB `.profdata` that plausibly optimizes only the 18-line shim | Infra | 2 | 3 | 3 | 15 | **NEW 2026-08-17** (delta scan). 1–3 days: extract shared `.xcconfig` layers, scope the profile flag to Release/PGO, add a CI compile of one PGO config — or decide PGO isn't paying rent and delete the configs. |
| 36 | **`AudioIngestBenchmark` runs 2,000 iterations unconditionally in the default suite**: `AudioIngestBenchmark.swift:19-24`, no assertion, not env-gated — the standing rule says measurement affordances are env-gated default-off. Cheap today (~0.25 s); it's the template the next benchmark copies | Test | 1 | 2 | 1 | 15 | **NEW 2026-08-17** (delta scan). Gate on `THRESHOLD_BENCHMARK` like its siblings. |
| 40 | **`.git` is 1.0 GB; ~600 MB is unreachable pack overlap**: 4 packs (761 MB Aug-13 + 304 MB Aug-17 overlap heavily — the 08-13 "clean repository data" commit left the old pack resident, held by 120 reflog entries); reachable content is ~420 MB. `git reflog expire --expire=now --all && git gc --prune=now` reclaims it — no history rewrite, no force-push (cost: loses reflog recovery points) | Infra | 1 | 2 | 1 | 15 | **NEW 2026-08-17** (infra sweep). Highest value-per-effort in the audit. The remaining ~90 MB of history whales (repeated icon-source `.pxd` revisions ~35 MB; the deleted `MetalRaymarch/` predecessor ~53 MB) need a rewrite — register-and-accept. |
| 42 | **`build.sh` never probes `/Applications/Xcode.app`**: probes Xcode-beta paths then falls to `xcode-select` (`build.sh:39-43`), which on this machine points at CommandLineTools → manual `DEVELOPER_DIR` every run; `ql_render_check.sh:24-29` already probes `Xcode.app` and works unattended. One line deletes the most-hit local friction | Infra | 2 | 1 | 1 | 15 | **NEW 2026-08-17** (infra sweep). CI unaffected (runners resolve via `xcode-select` correctly; SDK-major hard-fail already guards). |
| 44 | **Project-level `XROS_DEPLOYMENT_TARGET = 2.1` latent trap**: `project.pbxproj:1522,1586,1734` (PBXProject configs) vs 26.0 on every target. Any NEW visionOS target silently inherits 2.1 against a 26-only codebase | Infra | 1 | 2 | 1 | 15 | **NEW 2026-08-17** (infra sweep). Three-line fix; harmless until the day it isn't. |
| 41 | **Tracked-vs-ignored half-states + root clutter** (one decision sitting): `Sources/*` is gitignored yet **57 files remain tracked** (279 MB on disk, 60 MB in history, incl. the repo's largest tracked files — 5.7 MB `.pxd` icon sources; `.gitignore:40`'s one-off `.mov` line shows the symptom being patched) — either drop the ignore or `git rm --cached`; `MetalRaymarch.xcodeproj` is an **empty husk** (no pbxproj, untracked) — delete; `SpaceTransformationsExplorer.html` (65 KB, tracked) has zero inbound references — link from `CUSTOM_SCENES.md` or drop; `skills/` + `skills-lock.json` (49 files, vendored third-party agent skills) wired to nothing and unexplained — README line or remove; stale self-metric `check_no_large_files.sh:7` says "~766 MB" (now 1.05 GB) | Infra | 1 | 1 | 1 | 10 | **NEW 2026-08-17** (infra sweep). Decisions, not work; none block anything. |
| 8a | ~~**QL source-closure drift**~~ | Infra | – | – | – | – | **DONE 2026-08-17** (the item's "or add a freshness check" disjunct): `Scripts/ql_render_check.sh:66-79` parses `SHARED_SOURCES` from `wire_quicklook.rb:26-70` and compiles that exact closure (≥30-file parse guard `:79`); `.github/workflows/ci.yml:76-85` runs it every push/PR. List is still hand-maintained — a missing file now fails the CI gate instead of breaking a session. |
| 1 | ~~**Automatic embed generation + freshness test**~~ | Infra | – | – | – | – | **DONE 2026-07-10**: every app/Quick Look target generates `EmbeddedMetalSources.swift` into its own Derived Sources directory from an input file list, deleting the 6,506-line checked-in copy and making stale runtime shader input impossible. `EmbedFreshnessTests` still pins every block byte-for-byte and checks generator coverage. |
| 2 | ~~**Single `Uniforms` builder**~~ | Code | – | – | – | – | **DONE + VERIFIED 2026-07-10**: `Threshold/Rendering/Core/UniformsBuilder.swift` holds one `assembleUniforms(...)`; all three sites assemble via it. Verified by the clean 94-test run, all three app builds, and the 37-scene Quick Look render check. |
| 18 | ~~**`EnvironmentSDF` geometry math has zero tests**~~ | Test | – | – | – | – | **DONE (verified 2026-07-13)**: `EnvironmentSDFTests.swift` covers `pointTriangleDistance`, `parseSynthetic`, `bakeSynthetic`, mesh `bake`, and `makeEnvScrunchParams`. |
| 19 | ~~**`clampFar` comment-enforced lockstep**~~ | Code | – | – | – | – | **DONE (verified 2026-07-13)**: `EnvScrunchParams` carries `farClampModel`; comment-contract gone; pinned by the "#19 pin" test. |
| 14 | ~~**`objectCutout*` preset persistence asymmetry**~~ | Test | – | – | – | – | **DECIDED + PINNED 2026-07-04**: cutouts are device-local by design; pinned by `objectCutoutsStayDeviceLocal`. |
| 8d | ~~**`FractalParams`/`Uniforms` size watch**~~ | Perf-adjacent | – | – | – | – | **RESOLVED 2026-07-09**: hand field, space-warp stack, Env Scrunch moved behind pointers; `static_assert`s now `FractalParams ≤ 160`, `Uniforms`/`TileUniforms ≤ 2048`. |
| 16 | ~~**Rebuild go/no-go record**~~ | Arch | – | – | – | – | **Record exists; decision still PROPOSED** (`Context/REBUILD_ARCHITECTURE.md:3`, unchanged since 07-04). ⚠️ 2026-08-17: inputs are aging while in-place work executes rebuild seeds (formula editor ≈ Shader IR; ControlCatalog convergence ≈ ParameterCatalog) — make the call or retire the doc. |
| 5 | ~~**CI skeleton**~~ | Infra | – | – | – | – | **DONE 2026-07-18**; re-verified 2026-08-17: all referenced scripts/schemes still resolve, new test files auto-covered via the synchronized root group, no pinned-Xcode rot (SDK-major hard-fail guards), `macos-26` runners. |
| 4 | ~~**Benchmark persistence isolation**~~ | Infra | – | – | – | – | **ALREADY DONE**: `SettingsPersistence.benchmarkHermetic` gates save AND load on `THRESHOLD_BENCHMARK`. |
| 8c | ~~**Bundled-resource flattening workaround**~~ | Infra | – | – | – | – | **DONE 2026-07-18**: `Scripts/mark_mixed_scenes.py --check` in CI; re-verified 2026-08-17 (exit 0, all mixed scenes marked — the 19 new scenes comply). |
| 15 | ~~**Legacy compute-cache toggle is trap code**~~ | Code | – | – | – | – | **DONE (verified 2026-07-13)**: 0 hits, removed. |
| 17 | ~~**`handEffectsBeta` gate scatter**~~ | Code | – | – | – | – | **DONE (verified 2026-07-09)**: 0 code hits. |
| 9 | ~~**Untrack `default.profraw`**~~ | Infra | – | – | – | – | **DONE** (verified 2026-07-04); re-verified 2026-08-17: 0 tracked `profraw`/`DS_Store`. |
| 10 | **Sphere-system unification** (3 parallel systems) | Arch | 2 | 2 | 4 | 8 | **PARKED pending #16.** |
| 11 | **Param-catalog Slice 8** (route-driven UI) | Arch | 2 | 2 | 4 | 8 | **PARKED pending #16** — though #8's convergence (76 specs, exact-coverage tests) has quietly built most of the runway. |
| 12 | **`RenderSettings` god-object split** (now **5,117 lines / 502 lock sites**, +461/+7 in a month) | Arch | 4 | 3 | 5 | 7 | **PARKED pending #16**; still growing. Watch-list behind it: `AnimationManager` 2,632 (+517), `RadialMenu` 2,069, `MusicTabView` 2,048. If no-go: opportunistic extraction only, never a big bang. |
| 13 | **Module architecture stages 3+5** | Arch | 2 | 1 | 4 | 6 | **PARKED pending #16.** |

Not-debt, deliberately kept: gated experimental features (custom scenes opt-in — verified
gating 2026-08-17), SharePlay backend, Buddhabrot (keeper), racy-by-design benchmark
gates (documented), zero third-party deps, `Backup/` scene backups tracked in git
(5.5 MB — watch, name invites growth), `metal-raymarch-demo.gif` (5.1 MB, under the
10 MB gate, README-referenced).

**Scanned CLEAN 2026-08-17** (recorded so the next refresh needn't re-derive): formula
editor injection/threading/gating/persistence (64 KB cap + `#include` rejection on both
paths; async compiles, latest-wins generations, keep-last-good; `allowCustomScenes`
default-false; `FormulaLibraryStoreTests` ×6); scene-tag + mic-preference round-trips;
music-cue gate suite; distance-cache growth bounded both sides (96 MB budget, LRU, disk
prune); MetricKit collection bounded/local with user-initiated share (the CloudKit cap
is #33); benchmark/ablation env-gating incl. shader `benchAblate` inert-at-0;
input/nav unification deleted legacy paths (no coexistence); `build/` never committed,
ignore file healthy; CI matches tree; README fresh — 4/4 claims verified, zero numeric
perf figures (exact compliance with the perf-claims policy); `CUSTOM_SCENES.md` and
`PERF_PUSH.md` current-and-correct (PERF_PUSH self-corrects in place; healthiest doc in
the repo).

Below itemization threshold, noted only: `THRESHOLD_BENCHMARK` env literal ×3
(`BenchmarkMode.swift:21`, `SettingsPersistence.swift:138`,
`RenderSettings.swift:2955-2957` — behind a "Mirrors" comment; tiny shared constant in
a target-neutral file when touched); stale comment `Shaders.metal:4795` (says
`debugHierarchical >= 10`, code reads `benchAblate`); `README.md:13` unclosed `**`;
`PERF_LOG.jsonl` still empty (the perf protocol has never run on device — PERF_PUSH's
domain, noted for cross-reference); commit-message hygiene in the window (`a5f3c54d`
"check it", `17abd0b0` "commit", `52a6a7b1` shipping 2,010 insertions marked "Not built
or tested as of this commit") — a CONTRIBUTING line if it recurs; the visionOS/iOS
schemes run zero tests by design (macOS-hosted only) — document inside #43's sitting.

## Phased plan (alongside feature work)

**Phases A + B — ✅ COMPLETE** (see 07-04/07-13 notes above). **Phase B′ — partially
overtaken 2026-08-17:** its step 3 (#3) landed by itself (`AnimationKeyframeBatchTests`);
its steps 1–2 (#21/#22, #20) did NOT get their sittings and #21 has since realized its
predicted failure. Superseded by Phase D below.

**Phase D — 2026-08-17 (2–3 sessions, ordered):**

1. **D0 — before the recording-mode tree is committed:** #37 (state-machine tests
   while the code is fresh), #38 (five-seam batch), #39 (presets: commit the intended,
   delete the 0600 scratch — they're already read by two suites *today*).
2. **D1 — lockstep killers (one sitting each; all E=1, all (I+R)≥7):** **#21 first**
   (shared dependency-free enum + `.rawValue` at all 3 mirror sites + **fix the
   harness 17/18 pair** + delete/regenerate the stale `ShaderTypes.h` copy), then
   **#27** (move motion/blit structs into `ShaderTypes.h` + `static_assert`s), then
   **#29** (single field list → label/fileName + completeness pin + golden filename).
   This is the same playbook that killed #19 and #2 — cheapest on days-old code.
3. **D2 — test batch:** #20 (WarmStartGate tolerance cases), #3-remainder (recenter +
   pin/unify the twin composition), #26 (extract shared band-sensitivity helper +
   tests; delete the redundant clamps). Also fix #6's sharpest site
   (`handTrackingEnabledForRenderer` → `Mutex` or atomic) ahead of the full pass.
4. **D3 — one-liner safety batch:** #33 (enforce the CK record byte cap + surface
   failure), #34 (`dispatchPrecondition`), #25 (call the existing `evict` on
   supersede + reconcile the two comments), #36 (env-gate the micro-benchmark).
5. **D4 — docs sitting:** #43 (fix the false test-action row; add "Local build
   constraints": DerivedData lock + `THRESHOLD_DERIVED_DATA_PATH`, hosted-GUI test
   cost + `testfast` + `ios`, the three trust flags; note compile-only vision/iOS
   schemes; absorb #38e's plist rationale).

**Phase E — opportunistic (ongoing, no dedicated sessions):** #8 finish (16 sites),
#8b (six lines in the existing test), #28, #30, #31 (names now; derivation later),
#35 (env-gate + expiry note), #40/#41/#42/#44 (hygiene decisions; #40 is one command),
#32 (or a decision to delete PGO), #7/#24 under the standing when-the-file-is-open
rule.

**Parked pending the #16 decision** (inputs aging — make the call): #10, #11, #12,
#13, #24's Tier 3. The month's evidence cuts both ways: in-place work is successfully
executing rebuild seeds (argues no-go), and #12 grew another 461 lines (argues go).
Either answer beats no answer — the parked set only re-activates on a recorded no-go.

## Standing rules

- Perf debt goes to `PERF_PUSH.md`, never here — one register per concern.
- Dead code found during work: add to `CLEANUP_AUDIT.md` if uncertain, delete if verified.
- Every "temporary" measurement affordance (benchmark gates, ablation switches)
  must be env/flag-gated and default-off — same rule as perf toggles.
- New persisted field ⇒ same-commit round-trip test (or an explicit device-local
  exclusion noted in the test) — #14 is what skipping this looks like.
- Swift↔Metal identity (indices, struct layouts, rawValues) lives in ONE shared
  declaration with a compile- or test-time agreement check, never a "mirrors…"
  comment — #19 → #21 → #27/#29 is what the comment version costs. *(Added
  2026-08-17 after #21's drift realized.)*
