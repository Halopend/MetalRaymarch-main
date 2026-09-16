# MEMORY — Threshold (Metal ray-marching fractal app)

Derived from a full code scan (Swift/Metal/scripts; README used for orientation only).
Everything below is verified against code unless marked UNCERTAIN. Repo root: this directory.
Live Xcode project: **`Threshold.xcodeproj`** (the `MetalRaymarch.xcodeproj/` on disk is a vestigial
untracked `project.xcworkspace` with no `project.pbxproj`; the legacy project left git at "Major Refactor").

---

## 1. What this is

Real-time Metal ray marcher for **macOS, iPadOS, visionOS** (deployment target 26.0, Swift 6).
GPL-3.0-or-later app code; imported formulas/shaders keep their own attribution headers
(e.g. `Sources/HybridPKFraments/*.frag` = attributed community sources, **not referenced by app code** — reference material only).
Core workflow: portable scenes/formulas (`.threshscene` / `.threshfx`) that embed a validated Metal distance estimator,
compiled at runtime and grafted into the renderer. Unofficial bundle IDs say `com.puppypower.Threshold`.

## 2. Targets & build (all verified)

| Target | Platform | Role |
|---|---|---|
| `Threshold` | visionOS (`SDKROOT=xros` is the **project default**) | CompositorServices immersive app; stale `productName = "MetalProject"` |
| `ThresholdMac` | macOS | fragment render path; hosts QL appex; test host for ThresholdTests |
| `ThresholdiOS` | iPhone+iPad | MTKView path |
| `ThresholdQLPreview` / `ThresholdQLThumbnail` | macOS appex | Quick Look for the 5 `.thresh*` UTIs |
| `ThresholdTests` | macOS bundle | hosted in ThresholdMac.app |

- Build/test: `Scripts/build.sh mac|vision|ios|test|testfast|embeds|all`. Pins `DEVELOPER_DIR`
  (Xcode-beta → Xcode → xcode-select), requires macOS 26+ SDK, always `CODE_SIGNING_ALLOWED=NO`,
  passes `THRESHOLD_GIT_SHA`/`THRESHOLD_GIT_DIRTY`. DerivedData at `.build/DerivedData`.
- **Build numbers: ONE shared counter for all targets** (`CURRENT_PROJECT_VERSION`; the QL appexes
  inherit it from project defaults, so Mac/iOS/visionOS uploads always match — ASC requires the
  appex number == host app number). `Scripts/version.sh`: `bump` **before every App Store upload**
  (writes all 14 pbxproj configs atomically), `set N` if ASC rejects "build N already exists",
  `marketing x.y.z`, `show`, `check` (CI drift gate). History: build 24 was committed while ASC
  already had 28 → project re-synced to 29 on 2026-09-15. Every bump resets the PSO pipeline cache
  (see `PipelineBinaryArchive` below — keys on `CFBundleVersion`), costing one cold Metal compile.
- **`test` = clean + `-parallel-testing-enabled NO`, the ONLY trustworthy run.** Incremental builds have
  linked a stale `.swiftmodule` (false "TEST SUCCEEDED"); parallel MTLDevice hosts crash into phantom failures.
  `testfast` is explicitly untrusted.
- **Edited a shader? Clear the PSO archive:**
  `rm -rf "$HOME/Library/Application Support/ThresholdPipelineArchive"` — `PipelineBinaryArchive` keys its
  file on `CFBundleVersion`, so a shader rebuild without a bundle bump costs one cold compile or a stale PSO.
- Shader embeds are **automatic**: a Run-script phase ("Generate Metal Embeds", all 5 non-test targets) runs
  `Scripts/generate_metal_embeds.sh --output $(DERIVED_FILE_DIR)/EmbeddedMetalSources.swift`, inputs from
  `Scripts/metal_embed_inputs.xcfilelist` (ShaderTypes.h + FractalFormulaCommon.h + 8 formula headers + Shaders.metal).
  Emits `enum EmbeddedMetalSources` raw-string blocks consumed by the runtime compiler. Not checked in.
  `EmbedFreshnessTests` byte-pins embeds vs disk. `build.sh embeds` = manual inspection copy under `.build/Generated`.
- `Scripts/stamp_git_sha.sh` ("Stamp Git SHA" phase, `alwaysOutOfDate=1`) writes `GitStamp.plist`;
  `BuildStamp` (PerfLog.swift) reads it — Info.plist fallback keys don't exist, so bypassing it yields "unknown".
- Targets are Xcode-16 `PBXFileSystemSynchronizedRootGroup` on `Threshold/`; per-target `membershipExceptions`
  list **excluded** files (visionOS-only `RendererCoreTypes.swift`, per-platform `AppleMusicManager*`).
  `wire_quicklook.rb` is load-bearing: the CI QL gate parses its `SHARED_SOURCES` (<30 files = fail).
- CI (`.github/workflows/ci.yml`): hygiene (ubuntu; `check_no_duplicate_suffix.sh`, `check_no_large_files.sh`,
  `mark_mixed_scenes.py --check`) → `build.sh test` on macos-26 → matrix ios+vision builds → `Scripts/ql_render_check.sh`.
  `perf-gate.sh` is **not** in CI (device-only; PR-template gate). Opt-in pre-commit hook: `git config core.hooksPath .githooks`.

## 3. Render architecture (two host paths)

- **visionOS**: `actor Renderer` (Rendering/Renderer.swift, 2.8K lines) on a custom `TaskExecutor`
  (`RendererTaskExecutor`, dedicated "RenderThread"). Loop in `Core/RendererLoopSupport`: `LayerRenderer.queryNextFrame`
  → `predictTiming` → `LayerRenderer.Clock().wait(until:)` → CPU phase (`updateHandTracking`,
  `settings.interpolateToTargets`, AudioHub snapshot, `settings.snapshot()`, `updateGameState`) →
  `startSubmission`/`beginDrawableRenderContext` (visionOS 26 portal stencil) → encode → `encodePresent`.
  `maxBuffersInFlight = 2` + in-flight semaphore (100 ms timeout → empty-frame stall). Immersive space is a
  `CompositorLayer(configuration: ContentStageConfiguration())`; foveation, `stencil8` render context, HDR `rgba16Float`.
- **macOS/iPadOS**: `ThresholdMacRenderView` / `ThresholdiOSRenderView` → MTKView `Coordinator` →
  `ViewportRenderer.draw(appModel:)` (Rendering/RaymarchRenderView.swift, ~2.8K lines; NSView + UIView both).
  iPad extras: `NonBlockingDrawableProvider`, `IOSViewportRenderConfiguration` (fixed `rgba16Float` + `depth32Float`).
- **visionOS path select** (`selectFramePath` → `RenderFramePath`, Core/FramePath.swift):
  `.adaptiveCompute` (kernel `adaptiveHierarchical8x8`, 8×8 tiles, temporal reprojection, foveated step ramp,
  optional `edgeDetectSlidingWindow`, blit of rate-map region) or `.fragment` (rasterized proxy mesh march).
  Mixed-immersion passthrough forces `.fragment` (miss alpha needs `fragmentMain`).
- **Shaders.metal** (5.7K lines) entry points: `vertexShader`/`screenshotVertexShader` (proxy ellipsoid r=100, inflate 1.05),
  `fragmentShader` (stereo: Halton jitter, warm-start reprobe `computeWarmStartT`, cone min-over-2×2 coarse read) +
  `fragmentShaderMono` (Mac/iOS) both → `inline fragmentMain` (l.4682; `SceneWithCache`/`SceneWithCacheFromStart` marches);
  kernels `coneCoarsePrepass8x8` (lower-bound warmT per 8×8 block, cold sentinel 0.05), `edgeDetectSlidingWindow`,
  `distanceCacheBake`/`distanceCacheValidate` (128³ conservative DE cache); utilities `formatConversion*Stereo`
  (MetalFX resolve + `rcasSharpen`), `macBlit*`, `macMotionFragment`, `spatialRadial*`;
  `diagnosticKernel` (ProgressiveShaders.metal) for `profilePipelineComponents`.
- **Mac/iOS pass plan**: temporal = offscreen raymarch → motion pass (`macMotionFragment`) →
  `ViewportTemporalUpscaler` (MTLFXTemporalScaler) → `macBlitFragment`; spatial = raymarch →
  `ViewportSpatialUpscaler` (`.perceptual`/`.hdr`) → blit; native single-pass; Halton jitter only on temporal.
  iOS disables temporal upscaling (private-history alloc failure). **visionOS MetalFX spatial is hard-disabled**
  (`Renderer.visionMetalFXSpatialEnabled = false`) — compositor Render Quality replaces it.
- **Uniforms**: `Uniforms` ≤2336 B (static_assert), `TileUniforms` ≤2336 (assembled inline in `encodeAdaptiveCompute`,
  NOT via `UniformsBuilder` — duplicated math), `UniformsArray` = 2 views, `FormulaParams` ≤176 B (16 floats + 2 rot matrices
  + `rotationFlags` bitmask). `UniformsBuilder.assembleUniforms` is the single fragment-path assembler;
  `RenderPrecompute` bakes Precomputed* blocks + cone params. Bindless grids ride raw `gridAddress`:
  `EnvScrunchParams` (64³ + 8 `ScenePrimitiveGPU`), `DistanceCacheParams` (128³).
- **Function constants**: 19 FCs (ShaderTypes.h ↔ `FunctionConstantIndices.swift`), incl. `fractalType`(7),
  `mandelbulbPower`(12, powers {2,3,4,5,6,8,10,12,16}), DE-tail bakes FC16/18 **macOS-only** (`_ES/_HF` key segments nil
  elsewhere → shader defaults-ON). String pipeline cache keys (`RenderPipelineKeyContext`/`ComputePipelineKeyContext`)
  include scene segments `_B{bubble}_SW{warp}_ES/_HF…` that **must stay in lockstep with `FractalPreset.pipelineCacheKey`**.
- **Pipeline caches**: `selectPipeline`/`selectComputePipeline` (fast-path mirrors `lastSelect*` — call
  `resetPipelineFastPaths()` on any eviction or a stale pointer survives), detached single-flight builds (≤3 pending,
  exponential retry), `ViewportSpecializedPipelineCache` (Mac/iOS `fragmentShaderMono`), cross-launch
  `PipelineBinaryArchive` at `~/Library/Application Support/ThresholdPipelineArchive/{purpose}-r{registryID}-{OS}-{CFBundleVersion}.metallib`.
  The archive never caches `makeLibrary(source:)` runtime compiles.
- **Quality**: `AdaptiveRenderQualityController` (visionOS-only governor; lowFPS 72 / recover 84 / critical 50,
  floor `QualityConfig.visionMinRenderQuality`, user slider = ceiling). `QualityPreset` tiers
  low(6 iters/68 steps) → ultra(12/150). `FramePacingTracker` (240-sample, hitch >33.3 ms, Mac/iOS via
  `addPresentedHandler`). `RenderModes.swift` holds scene enums (`GeometryState` → compute `blendFactor` 1.0/0.5/0.1).

## 4. Formulas & the embedded DE contract

- **Built-in registry**: one C header per formula under `Threshold/Formulas/<Name>/<Name>.h` (Mandelbulb, Menger,
  QuaternionJulia, Octahedron, MengerSphere, TheliPseudoKleinian, Kleinian, BoxFoldMandelbulb), included by
  `FractalFormulas.h` after `FractalFormulaCommon.h` (helpers + `struct OrbitData`). Every formula implements
  `DE_<Stem>_Dist(...)` (lean march) and `DE_<Stem>(... , thread OrbitData&)` (orbit coloring).
  Dispatch switches `FractalDE_Dispatch` / `FractalDE_WithOrbit` carry marker comments
  `// __CUSTOM_DISPATCH_DIST__` / `// __CUSTOM_DISPATCH_ORBIT__`; default arm → 1e10.
  4 construction SDFs (pyramid/tetrahedron/icosahedron/dodecahedron) via `DE_ConstructionPrimitive` (kind = `fp.params[0]`).
- **FractalModelType** raw values are stable IDs: mandelbox=0, mandelbulb=1, menger=2, mandelbulbJulia=5,
  quaternionJulia=6, octahedron=11, mengerSphere=14, theliPseudoKleinian=15, kleinian=17, boxFoldMandelbulb=18,
  constructionPrimitive=23, **custom=1000**. Source of truth `Threshold/Formulas/catalog.json` (v1) loaded by
  `FormulaCatalog`; parallel registry `FractalTypeRegistry` with lock-protected overlay for the dynamic `.custom` descriptor.
- **`EmbeddedFormula`** payload (also embedded in `.threshscene`/`.threshanim` under key `embeddedFormula`;
  standalone wrapper `EmbeddedFormulaContainer{version:1, formula}`): `schemaVersion(=1)`, `kind` (fractal|spaceWarp),
  id/name/category/author, `functionStem`, `metalSource`, `params: [FormulaParamDescriptor]`, defaults.
  `sourceHash` = SHA256("stem|metalSource"); `==` compares id+sourceHash only. `validate()` enforces: schema ≤1,
  stem regex `[A-Za-z_][A-Za-z0-9_]*`, **source ≤64 KiB**, forbidden tokens `#import`/`#include`/`@import`,
  required `DE_*` definitions present, **16 params max** (indices 0…15, unique). SpaceWarp kind requires
  `customSpaceWarp` + `customSpaceWarpDEScale`.
- **Pragmas** (`FormulaSourcePragmas.swift`, UI-only, never render data): `// @param 0 "Scale" default=2.0 min=0.5 max=4.0 step=0.01 [bool] [hidden]`.
  Parsed per keystroke; duplicate index = error; out-of-range default = warn+clamp.
- **Runtime compile**: `CustomShaderCompiler` (actor) synthesizes one self-contained source (prelude + Shaders.metal
  preamble + ShaderTypes.h + all formula headers + user DE + dispatch-injected `FractalFormulas.h` + Shaders.metal body)
  and compiles via **async completion-handler** `device.makeLibrary(source:)` (sync variant starved the cooperative
  pool on visionOS). Local quoted includes stripped. Library cached LRU-8 keyed `combinedHash = "f{hash}w{hash}s0"`.
  `mathMode = .fast` on visionOS 2.0+, else `fastMathEnabled`. No per-formula iteration cap beyond the settings clamp
  **2…24** (`ControlSpec.iterations`) — safety rests on each DE's own bailout.
- **Live editor** (`FormulaEditorModel`): instant parse per keystroke (sliders regenerate same frame, values preserved
  by index); compile debounced 900 ms with monotonic `generation` discarding stale results; statuses
  idle/blockedByParseIssues/compiling/live/compileFailed/… `MetalCompileDiagnostics` rebases `program_source:LINE:COL`
  onto user lines via `fractalUserSourceStartLine` (derived from the same layout helper — can't drift).
  Built-in "Studio" drafts rename entry points to `Studio<Name>` to avoid symbol clashes.
- **Renderer hook** (`Core/RendererCustomShader`): `activateEmbeddedFormula` generation-guarded, pipeline keys prefixed
  `CX{shortHash}_`, MRU retention 4, warm-start gate invalidated on every switch, self-heal retry 1/s. A `.custom` frame
  with no library renders sky/fog forever (dispatch → 1e10). Trusted bundled construction primitives are **never**
  runtime-compiled (route to precompiled type 23; trusted by source-hash incl. `historicalBundledSourceHashes` ledger).
- **Buddhabrot** (`Formulas/Buddhabrot/`): separate progressive orbit-density renderer, own `.metal` + `BuddhabrotTypes.h`
  (128³ grid, 512K splats, Gaussian-splat mode), settings persisted as `cfg.buddhabrot`; controls shown when
  `runtimeViewMode == .buddhabrot`. UNCERTAIN: no construction site for `BuddhabrotRenderer` found — appears dormant.

## 5. Parameter system & settings

- `RenderSettings` (Rendering/…, 5.2K lines) is the live god-object: `os_unfair_lock`-backed, per-domain config
  projections (`GeometryConfig`, `ColorConfig`, `LightingConfig`, `DisplayConfig`, `QualityConfig`, `SafetyBubbleConfig`,
  `HandAttractionConfig`, `AudioReactiveConfig`, `GestureConfig`), per-domain persist helpers gated by
  `withPersistenceSuppressed` (scene/session restores must not rewrite device prefs). Immutable
  `RenderSettings.snapshot()` bakes animated polar rotation/Julia drift + packed space-warp stack; consumed only by render side.
- Three-layer routing: `ParameterCatalog` (authored descriptors = `ControlSpec` + `ControlPlacement` + dual
  `UIBinding`/`SettingsBinding`) → `ParameterNodeSystem` (Mutex'd `ParameterLayerStack` per node: ui/gesture/music;
  music additive + unclamped at input, clamped at resolve; smoothing 0.08 s, music bypasses) → `ParameterPipeline`
  (`ParameterOperation` winner by SourcePolicy: gesture 10 < slider 25 < audio 35). Target ids: `core.*`, `effect.*`,
  `space.*`, `spacewarp.<slot>.strength` (music-only, outside lockstep validation), `formula.<typeRaw>.<idx>.<name>`.
  `ParameterRoutingValidation.validateStartupRouting()` is a `precondition` tripwire (spec==node ids, ranges equal).
- `ControlCatalogProjectionCache` keyed by profile/route/presentation/fractalType/catalogRevision/transformRevision
  (live values excluded so slider drags never rebuild); **`catalogRevision` is hardcoded 1 in RadialMenuProjectionFactory**.
- `ControlStateStore` ("cache") duplicates RenderSettings for UI: 0.5 s sync timer (`.common` run-loop mode) +
  resnapshot on `fractalSettingsDidChangeNotification` + push-on-write; `startSync/stopSync` ref-counted.
- `Module`/`ModuleRegistry` are NOT scene-graph plugins — domain routers for `modules:` blocks in scene files;
  **only SpaceModule + LightingModule are registered**; the other 5 keys decode but are silently ignored at apply.
- **Space warp stack**: 20 `SpaceWarpKind`s (raw Int32 must match GPU `applyWarpOp`); `SpaceWarpOpValue` + repeat groups
  (`repeatOutput` | `mandelboxRecurrence`); packed to ≤8 ops (`kMaxSpaceWarpOps`, ShaderTypes.h) after
  `SpaceWarpStackSimplifier` (pure, adjacent-only, provable rewrites); consumed per march step by a uniform-driven loop
  (no recompile). Music offsets folded at snapshot, gated by Education-mode `setSpaceWarpInteractionAccess`.
- Persistence: `SettingsPersistence` (typed UserDefaults JSON per domain, keys `cfg.*`, 300 ms debounce,
  `THRESHOLD_BENCHMARK=1` = hermetic read/write-off), one-shot migration flags
  (`didMigrateSafetyBubbleDefaultOn` (visionOS), `didMigrateHandAttractionDefaultOn`,
  `didMigrateConeMarchStrengthDefaultTo84`, `didMigrateMacResolutionScaleToMetalFX`).
  `FractalPreset` schemaVersion is **diagnostic only**; compatibility = optional decode + `appliesLegacyFlatFields` marker;
  canonical envelope `sceneState: SceneState` v1 dual-written with legacy flat fields.

## 6. File formats & storage

- Canonical extension map (`ThresholdExportFormat`, PresetManager.swift): `.threshscene` = scenePreset (FractalPreset,
  no music mappings) · `.threshmp` = musicPreset (FractalPreset **with** audio mappings) · `.threshanim` = AnimationScene ·
  `.threshanimv` = AnimationScene with attachedSong · `.threshfx` = `EmbeddedFormulaContainer`. All JSON (ISO8601;
  store files prettyPrinted+sortedKeys; bundled assets also accepted as `*.json`).
  **README mentions `.threshlive` — no such format exists in code** (README/code discrepancy; "live" in
  AnimationManager means live-recording sessions of render settings).
- `StorageLocation` (@MainActor singleton): mode `local`/`iCloud` ("Storage.mode"); subdirs
  `Scenes/`, `Music Presets/`, `Animations/`, `Settings/`, `Formulas/`; local root `Documents/Threshold/`,
  iCloud root = ubiquity container Documents/; **`Backups/` always local** (Documents/Backups/, PresetManager
  writes `Backups/Presets/presets-<ISO8601>.json`, retention unlimited). `Settings/` subdir has no code reader found
  (likely vestigial). `contains(_:in:)` = symlink-resolved containment for open-file routing.
- `PresetManager`: folder store is source of truth; 350 ms debounced scan (size+mtime cache), `NSMetadataQuery` watcher,
  iCloud placeholder policy (un-hydrated files never participate in persistence/merge); `replaceAll` attributes deletions
  by in-memory ids, **never folder diff**; filenames `Sanitized_Name_<8-char-uuid>.<ext>`; bundled seeding via
  `.seeded-bundled.json` marker; `saveLastState` writes legacy `Documents/FractalPresets/lastState.json` (outside store,
  `__lastState__` sentinel, fallback = `mandelboxDefaultPreset()`). `BackupMerge.newestWins` (union by UUID, newer wins,
  local wins ties) only for local⇄iCloud mode switches.
- Restore scope contract: `.scene` = comfort-preserving — **a scene can enable a bubble but must never disable/reshape
  the user's safety bubble**; `.session` = exact rollback. v1/v2 files force warp strength 0 / infiniteZoom off so state
  can't inherit across scenes. Tolerant `init(from:)` with `decodeIfPresent` + clamps + `isFinite` guards is the pattern
  for adding fields (e.g. `DisplayConfig`, `AudioReactiveConfig`).

## 7. App layer, UI & navigation

- Three `@main` structs, whole-file `#if os(...)`: `ThresholdMacApp` (macOS; windows: render+slide-over
  `menuWindowID`, detached `controlsWindowID`, `animationEditorWindowID`, `onboardingWindowID`, `formulaEditorWindowID`;
  ⌘S/⌘K commands; `ViewportChromeShortcutMonitor` H, `ImportantSceneShortcutMonitor` P/F/R), `ThresholdiOSApp`
  (WindowGroup + `.inspector` hosting ContentView; phone/iPad branch on `UIDevice.userInterfaceIdiom`),
  `MetalProjectTestApp` (visionOS; struct name ≠ file name; `ImmersiveSpace` → `CompositorLayer` → `Renderer.startRenderLoop`).
  AppModel injected via `.environment(appModel)`; **`AppModel.shared` is a `static nonisolated(unsafe)` global** consumed by AppIntents.
- `AppModel` (@MainActor @Observable, ~1650 lines + 5 extensions): state root + ~20 closure seams installed by platform
  roots/renderer (`openMenuWindowHandler`, `viewportCommandHandler`, `activateEmbeddedFormulaHandler`,
  `preparePipelineHandler`, `presentSpatialMenuHandler`…). Extensions: +EmbeddedFormula (install/uninstall, keep-last-good
  live-edit), +ExternalImport (security-scoped preview/commit/restore), +SceneLoading (generation guards, 10 s poll
  `queuePresetApplyAfterFormulaActivation`), +RendererActivation (render-loop handshake), +PerformanceReporting.
  Render-loop mirrors are `@ObservationIgnored nonisolated(unsafe)` (`runtimeViewModeForRenderer`, `immersionStyleForRenderer`,
  `isAppActive`…); `handTrackingEnabledForRenderer` uses `Atomic<Bool>`.
- `ContentView` is the single shared control panel (Mac slide-over, Mac detached window, iOS inspector, visionOS menu
  window). Route→panel map in `contentPanel` (FractalTab / parameters / AnimateTab / ColoringTab / EffectsTab / MusicTab /
  TransitionTab / GesturesTab / quickToggles / SettingsTab). Layout variants: preImmersive (visionOS) / regular / compact / phone.
- Navigation: `NavigationStore` reducer persisting `NavigationState` JSON to UserDefaults "Navigation.state.v1" **synchronously
  on every select**; `AppRoute` canonicalization filtered by `PlatformProfile`; `NavigationHierarchy` node tree consumed by
  grid/keyboard/radial/spatial. Radial 2D: `RadialMenu` (2.5K lines) + `RadialMenuProjectionFactory` (decorates with live
  sliders from `controlProjectionCache`; dedup by `RadialNavigationProjection` — imported scene UUIDs can collide).
  Spatial (visionOS): `SpatialRadialMenuView` (RealityView) is **dormant** — `AppModel.spatialRadialMenuEnabled = false`,
  never instantiated. `ControlFinderView` = capability-filtered destination catalog (macOS ⌘K).
  `InputOwnershipStore` serializes claims of `.viewport/.radialMenu/.inspector/.spatialControls` (macOS Shift-peek
  passthrough special case).
- Platform: `PlatformProfile.current` is the only compile-time `#if`; everything else switches at runtime on
  `PlatformCapability` (iPhone shares the iPadOS profile). `PGOProfile` switches on instrumented build, not platform
  (periodic counter flush on visionOS because SIGKILL teardown skips `atexit`; `OptimizationProfiles/Threshold.profdata`).
  `DesignSystem` (`DS`) = numeric tokens + `dsGlass` (OS 26 `glassEffect` with `.ultraThinMaterial` fallback).
- visionOS immersive flow: `ToggleImmersiveSpaceButton` → `immersiveSpaceState` transitions; `.open` set only by
  ImmersiveView.onAppear; `.closed` → `cancelActiveRenderLoop()`, `PGOProfile.flush()`, re-open menu window after 100 ms.
  `immersionStyle` binding set `{ _ in }` — compositor writes deliberately ignored. `ImmersiveSpaceAutoOpener` auto-opens
  under `-ThresholdAutoOpenImmersive` (PGO) or `requestOpenImmersiveSpaceNotification`.
- App intents: live file is `App/AppIntents.swift`; **`App/Intents/ThresholdAppIntents.swift` is quarantined behind
  `#if ENABLE_WIP_APP_INTENTS`** (folder auto-included by synchronized groups, breaks builds if enabled).

## 8. Audio

- Shipped sources: mic (`MicrophoneCaptureSource` → `AudioAnalyzer`, AVAudioEngine tap, 2048-frame Hann windows,
  bass/mid/treble bins 20–250/250–2k/2–8k Hz, spectral-flux onset) and **synthetic** Apple Music bands
  (`AppleMusicManager` = **MediaPlayer**, not MusicKit; bands from BPM metadata × playback time; macOS variant is a
  full stub). **No system-output capture ships**: `SystemAudioTapCapture.swift` is an empty stub and
  `systemOutputCapturePolicy = .requiresExplicitApproval` blocks it everywhere; Spotify hard-blocked.
- Flow: capture thread → locked `AudioAnalysisCore` → MainActor envelopes → `AudioHub` (mixer freshness ≤0.35 s,
  exclusive-source priority) → `AudioFeatureStore` (Mutex; render reads `latestSnapshot()` directly) → per-renderer
  private `MusicReactiveEngine.process(bandLevels:…) → ParameterOperation`s (curves sinusoidal/pulse/drift/hybrid + LFO
  + damping; space-warp targets via `setSpaceWarpAudioOffsets`). `AudioBandMapping.scaledLevel` = clamp01(feature×sensitivity).
- Music service: `MusicServiceProvider` protocol + `MusicService` registry; `AppleMusicServiceAdapter` is the only
  provider; `MusicLibraryWindow` ("music-library") browser. Music authorization: 15 s timeout; `systemMusicPlayer`
  deliberately not initialized during launch/connect; simulator rejected.
- Session: iOS/visionOS `.playAndRecord` + route/interruption observers (debounced restart, max 3/10 s); macOS
  `MacMicrophonePreflight` probes CoreAudio **before** touching `AVAudioEngine.inputNode` (uncatchable ObjC exception otherwise).
- `.threshmp` = full `FractalPreset` JSON chosen by `PresetManager.exportPresetFile` when
  `hasMusicReactiveMappings`; in-tab saved presets are a different type (`MusicReactivePreset`, UserDefaults) — not the file format.

## 9. Animation & gestures

- `AnimationManager`: `AnimationScene` (keyframes, loop/forward/reverse/pingPong, `baseline: SceneState?`, attached song
  with fades, optional embeddedFormula, `playbackSpeedOverride`) + `AnimationKeyframe` (segment duration, `EasingFunction`
  or Catmull-Rom `.smooth`, shape params, effect overrides) + `AnimationPlayhead`; speed = playbackSpeed ×
  attachedSongFadeVelocityScale × animationActivityFactor; UI playhead throttled ~15 Hz.
  Music-cue scene switching: `MusicCueSceneSwitchGate` (edge-triggered onset, default threshold 0.25, cooldown 2 s) →
  `MusicCueSceneGroupSequence.stepMusicCueSceneGroup` (ordered/shuffleBag/random with history + non-repeat; stable
  storageID "kind:UUID").
- Gestures (visionOS only, ARKit `HandAnchor.handSkeleton`, `@available(visionOS 2.0,*)`; below that silently inert):
  `GestureProcessor` is an **actor**; `process(HandPoseSnapshot) -> GestureOutput` (parameterOperations + Sendable
  `GestureRenderMutation`s applied on the render worker + arbitrated AppCommands). Engines: `MenuToggleGestureEngine`
  (recovery-pose menu; modes middleAndRingToPalm=1 / wristTap=3 / middleOrRingToPalm=6), `PerFingerTapGestureEngine`
  (tap-to-palm actions, hysteresis 0.55/0.25, hold 0.08 s, cooldown 0.4 s), `ArmSliderGestureEngine` (index tip along
  opposite forearm → left `fractalAudioAmount`, right `fractalAudioDamping`), `TwoHandScalarGestureEngine` (pull-apart scalar),
  `TwoPointGrabGestureEngine` + `GrabZoomMapping` (1:1 scale, shortest-arc rotation, midpoint-grounded pivot; mapping
  captured at grab start), `SingleHandDragGestureEngine` (per `GestureSlot`: hand×finger×direction → translate/scalar/triplet).
  Per-finger bindings persisted in UserDefaults; left hand needs ≥30 tracked frames before two-hand gestures.
  `FractalDefaultsStore` (misfiled in Gestures/) = per-fractal-type defaults snapshots in UserDefaults.

## 10. Quick Look, analytics, collaboration

- QL appex (macOS) preview all 5 UTIs. `ThresholdPreviewRender`: scene/musicPreset → decode `FractalPreset` → live GPU
  render via `HeadlessRenderer` (offscreen mirror of the Mac screenshot path; custom-DE scenes compile through
  `CustomShaderCompiler.synthesizeSource` cached by `sourceHash`); animations/formulas → CG info cards;
  `PreviewViewController` adds `InteractiveFractalView` (MTKView drag=orbit, scroll=zoom). `RenderKitStubs` keeps appex SwiftUI-free.
  `ql_render_check.sh` builds a shaders.metallib + compiles `RenderCheckMain` (swiftc) and asserts: every bundled
  `.threshscene`/`.threshmp` renders non-nil; an 18-scene allowlist non-black (mean luminance ≥12); custom-DE nil renders
  SKIPPED (not failed) on GitHub's paravirtual GPU. Metal toolchain found under `~/Library/Developer/DVTDownloads/MetalToolchain/mounts`.
- Analytics: `UsageAnalytics` opt-in (default OFF); ~1 Hz sampling; aggregate feature distributions + avgFPS → CloudKit
  **public DB** "UsageSnapshot" every 300 s active use; explicit "Submit report" sends redacted PerformanceReport
  (formula name/hash nilled; custom-DE names collapsed to "Custom Formula"). Entitlement guard
  `UsageAnalytics.hasCloudKitEntitlement` (`SecTaskCopyValueForEntitlement`) prevents the unsigned-build CloudKit abort on macOS.
  `MetricKitPerformanceReporter` (macOS-only) retains last 5 metric + 5 diagnostic payloads, included in explicit reports.
  `PerformanceReport` (schemaVersion 1, findings thresholds gpuFrameMs≥16.67/25, stepsPerPixel≥80/140, p95≥24ms,
  hitches≥3, renderQuality<0.65); archive format "THRESH-PERF-1\0" + zlib JSON.
- Perf tooling: `PerfLog` appends `PerfRunRecord` (headline metric **iterationsAvg**) to Documents/PerfLog/perf-log.jsonl+md
  (repo-root `PERF_LOG.jsonl/md` are manually appended tracked copies). `BenchmarkMode` env `THRESHOLD_BENCHMARK=1`
  bypasses the power gate; `MacBenchmarkHarness` PLAN/ENV modes; `perf-gate.sh` compares vs `Baselines/mac-stress-1080p-accel-*.json`
  (5% gpuMs / 2% steps tolerance, `--rebaseline`). `RenderTrace` OSSignposter (`com.puppypower.Threshold`/Rendering) ships in Release.
- SharePlay: `FractalShareActivity` (GroupActivity) + `FractalShareSession` (GroupSessionMessenger; driver/viewer/collaborative,
  last-write-wins, 30 Hz cap, monotonic timestamp dedup; **peers may enable but never remotely disable a safety bubble**);
  needs `com.apple.developer.group-session`, present only in the visionOS entitlements.

## 11. Tests & CI

- **58 test files, 100% Swift Testing** (`@Suite`/`@Test`/`#expect`), hosted in the ThresholdMac app executable.
  Key suites: `EmbeddedFormulaCompileTests` (compiles every shipped embedded DE against a real MTLDevice through the
  production compiler path), `EmbedFreshnessTests` (byte-pins every embed block vs disk), `ThresholdExportFormatTests`,
  `UsageAnalyticsTests`, `MandelbulbPowerSpecializationTests`, `ShaderWorldFieldGateTests`, `GestureEngineReplayTests`,
  `SpaceWarpStackIntegrityTests`, `ControlCatalogTests`, `NavigationStoreTests`. `AudioIngestBenchmark` is informational only.
- Tests reach `EmbeddedMetalSources` only via `@testable import Threshold` (host app) — the tests target has no embed phase;
  `EmbedFreshnessTests` resolves the repo from `#filePath` (assumes running from the repo, as build.sh does).

## 12. Code-verified gotchas (muscle-memory list)

1. **Stale-state traps**: pipeline fast-path mirrors need `resetPipelineFastPaths()` on eviction; warm-start gates
   (`warmStartGate` fragment vs `computeWarmStartGate`) invalidate on custom-library activation, room-bounds change, and
   never record with envScrunch/handAttraction or spherical inversion; `FormulaCatalog.customRegistrationToken()` changes
   on every registration — compare the token, not the id; `ParameterPipeline.resetForSceneLoad()`/`clearMusicLayers` exist
   because stale layer stacks would write the previous scene's base back.
2. **Key-grammar lockstep**: pipeline cache key segments (`_SW`/`_ES`/`_HF`/power) must match `FractalPreset.pipelineCacheKey`;
   DE-tail bakes are macOS-only (nil elsewhere → shader defaults-ON); the "powerless shared" compute probe asserts key grammar.
   Cone-prepass trust gate is duplicated CPU (`coneAllowed`) + GPU (kernel guards) — keep in lockstep when adding warp sources.
3. **Uniform pitfalls**: `uniforms` is rebound per ring slot — patch via `uniforms[0]`, never index by `uniformBufferIndex`
   (walks past the allocation in Release). `Uniforms`/`TileUniforms`/`FormulaParams` size static_asserts (2336/2336/176)
   require conscious bumps. visionOS `TileUniforms` assembly is duplicated inline, not via `UniformsBuilder`.
4. **Handler-seam races**: `AppModel`'s ~20 handler closures are installed by whichever view/window mounts last
   (two ContentViews on Mac: slide-over + detached window); `onDisappear` nils only the Save-Preset/Animation-Editor
   handlers → the Mac app menu ⌘S disables when its handler is nil. `activateEmbeddedFormulaHandler` is a `didSet` with
   heavy async side effects — rebinding re-triggers activation.
5. **BenchmarkMode double-AppModel** in `ThresholdMacApp` (property initializer builds one, init() replaces it;
   `AppModel.shared` briefly points at the discarded one).
6. **iCloud/backups**: unsigned local builds lack the entitlement → CloudKit guarded by `UsageAnalytics.hasCloudKitEntitlement`;
   `PresetManager.replaceAll` must never diff the folder (un-hydrated iCloud placeholders would be deleted).
7. **Audio traps**: macOS mic preflight before `inputNode` (uncatchable ObjC exception); AVAudioEngine self-stops on route
   change (debounced restart, 3/10 s); backgrounding calls `audioHub.stopTransientSources()` which **only refreshes the
   snapshot — it never stops the mic** (doc comment contradicts behavior); Apple Music bands are synthetic (BPM×time) and
   inert until authorization.
8. **Simulator/CI limits**: parallel test hosts crash (serial mandatory); GH paravirtual GPU can't build runtime custom-DE
   pipelines (QL gate skips them); mic + Apple Music auth rejected in simulator; residency sets + depth clamp disabled in Simulator (C-level abort under validation).
9. **Startup precondition**: `ParameterRoutingValidation.validateStartupRouting()` crashes on any spec/node/range/music-target
   drift — intentional tripwire; changing a ControlSpec range means updating nodes + music allowedRanges together.
10. **Storage**: `Storage.mode` UserDefaults; lastState.json lives outside the store in legacy Documents/FractalPresets/;
    `flushPendingSaves` commits only user-edit writes; `THRESHOLD_BENCHMARK=1` makes settings hermetic (persisted state once faked a 4× "speedup").
11. **Mac perf**: slide-over uses opaque gradients, NOT NSVisualEffectView blur (blur re-sampled the live Metal view and halved FPS).
12. **ModuleRegistry** silently ignores `modules:` blocks for the 5 unregistered domains — adding one requires registering a `Module`.
13. `RENDERER_DEBUG` is shadowed: `private let` in AppModel+EmbeddedFormula (macOS/iOS) vs the global in Renderer.swift (visionOS).
14. Per-frame pipeline-key / prewarm paths (`getPipeline(forPreset:)`, `precompilePresetPipelines`) must mirror `selectPipeline`'s key grammar or prewarm silently misses (falls back to generic pipeline, fog/sky-only for custom types).
15. The `.threshfx` store dedupes by formula id; scene-embedded discovery dedupes by `shortHash` — different semantics.

---

**Defect registry**: `FINDINGS.md` holds the full bug/inefficiency scan (10 High / 30 Medium / 27 Low,
each with file:line, severity, confidence, and fix), including verified-clean notes so future
sessions don't re-hunt settled areas. Known gotchas above (§12) are excluded from that report.