# Code optimization and refactoring review — 2026-10-06

## Scope and confidence

Static review of the current working tree, including the 17 already-modified files. No application code was changed. Inspected scene evaluation, settings transactions, pipeline selection/build/cache ownership, shader normal/shadow paths, audio ingestion, library indexing, animation responsibilities, and existing audit/performance documents. This is a focused architectural and hot-path review, not an exhaustive proof of every platform path. No builds, tests, GPU benchmarks, or device traces were run; performance opportunities below have no newly measured speedup.

## Recommended order

| Priority | Work | Reason | Relative effort |
|---|---|---|---|
| 1 | Derive specialization entirely from the evaluated frame | Prevent baked shader features disagreeing with uniforms | Medium |
| 2 | Add generation checks to asynchronous pipeline publication | Eviction currently cannot invalidate a running build | Small–medium |
| 3 | Harden library scan invalidation and cancellation | Avoid stale publication and redundant filesystem work | Small |
| 4 | Share shadow-contribution predicates between render paths | Compute fallback still performs work fragment skips | Small–medium |
| 5 | Bound specialization caches and add retry policy | Control session memory and repeat compilation failures | Medium |
| 6 | Separate settings state from mutation/persistence/effects | Reduce synchronization and maintenance complexity | Large; incremental |
| 7 | Split animation transport, evaluation, recording, storage | Make playback behavior independently testable | Medium–large |
| 8 | Refresh debt records and remove verified unused helpers | Stop stale recommendations driving implementation | Small |

## 1. Complete the frame snapshot boundary

Evidence: `Threshold/Rendering/Renderer.swift:1367` and `:2286` pass evaluated-frame formula/count information to pipeline selection. But `Threshold/Rendering/Core/RendererPipelineCache.swift:79`, `:88`, `:459`, and `:924–939` independently read safety bubble, coherent packets, warp stack, environment scrunch, and hand attraction from live RenderSettings. RenderPipelineRequest and ComputePipelineRequest carry only part of the inputs.

The evaluator intentionally returns the last completed frame, so live settings may legitimately be newer. A compute pipeline can therefore bake a feature off while the corresponding frame uniforms still enable it, or vice versa. Scene generation checks on frame retrieval do not make subsequent live reads match that frame. This is a code-supported consistency risk, not a reproduced visual failure.

Introduce a value type such as PipelineSpecialization derived from RenderSettingsSnapshot plus the activated shader library identity. Use it for key construction, last-selection comparison, and function-constant population. Include every baked feature. Pass it explicitly through both selection paths; reserve live settings reads for scheduling future work. Track custom-library activation identity so a frame cannot silently select a library for a different scene.

Validation: capture a frame, mutate feature toggles, then prove key and constants still match the captured frame. Cover safety bubble, packet mode, warp stack, environment, hand attraction, and custom-library transitions. Build all platforms and visually check scene switching.

## 2. Make pipeline eviction invalidate in-flight publication

Evidence: `Threshold/Rendering/Core/ViewportSpecializedPipelineCache.swift:46` evicts cached and pending entries by prefix. `ViewportSpecializedPipelineBuilder.drainBuilds`, around line 160, calls cache.store after compilation without an invalidation token. store unconditionally inserts its result.

If eviction happens while a build is running, completion can reinsert the retired custom pipeline. Removing a pending key does not cancel compiler work. This undermines resource retirement; hash-prefixed lookup reduces the likelihood of choosing an unrelated shader, but does not prevent stale memory retention.

Have beginBuild return a build ticket containing an epoch/token. Publish or fail only if the ticket is still current. Invalidate matching tickets on eviction. Ensure a stale failure cannot clear a newer build's pending marker for the same key. A prefix-specific token avoids invalidating unrelated built-in requests.

Validation: delay a build, evict its prefix, complete it, and assert it was discarded; also cover evict/rebuild of the same key and stale failure completion. Test with a fake builder rather than a real Metal compile.

## 3. Harden LibraryStore reload lifecycle

Evidence: `Threshold/Parameters/LibraryStore.swift:49–77`. Both reload methods return with index empty when activeRoot is nil before advancing scanGeneration. A previously started scan still has the current generation and may subsequently publish its old root. This depends on the storage root becoming unavailable during an active scan; reproduce that lifecycle before treating it as an observed user defect.

Advance the generation before every early return and include the captured root in publication validation. Retain and cancel the scan task; add cancellation checkpoints to LibraryIndex.scan. Current detached scans are discarded by generation on normal root changes, but still finish their filesystem work. Coalesce repeated reload notifications.

PresetManager already implements debounce, worker cancellation, generation checks, and file-signature reuse around lines 1110–1160. Borrow that lifecycle pattern without prematurely merging two stores with different data needs.

Validation: old-root scan followed by nil root, root A to root B, repeated notifications, and deinitialization while scanning.

## 4. Bring compute shadow fallback up to fragment parity

Evidence: `Threshold/Rendering/Shaders.metal:4837–4852` checks whether each light contributes before Shadow. The adaptive-compute noncoherent and unshared fallback paths around `:4535–4550` invoke both Shadow calls without those predicates.

Extract a small shared helper for the contribution condition and use it in fragment and per-lane compute fallback paths. Preserve threadgroup synchronization and tile-anchor semantics; skipping an anchor shadow solely from the anchor's normal is not automatically valid for neighboring lanes. The safe first change targets independent per-lane shadow calculations.

Validate against ShadeSurface's actual use of the shadow factors, including cel lighting, zero-intensity lights, and surface terminators. Compare images and GPU timing on the active compute path with coherent packets both enabled and disabled. The fragment optimization's historical results do not quantify this compute change.

## 5. Bound pipeline caches and handle compilation failure consistently

Evidence: the viewport cache State stores a dictionary without a capacity policy. The builder correctly coalesces queued requests, but completed distinct configurations remain retained until explicit custom-prefix eviction. failBuild only removes pending status, so a repeatedly requested failing key can be retried immediately. The vision renderer already has capped pending builds and retry-delay state in RendererPipelineCache.

Add a bounded recency policy for completed specializations, preserve generic fallback pipelines, and retire obsolete custom generations. Instrument entry count, builds, failures, and evictions. Reuse a small retry-policy value rather than copying the entire vision renderer cache. Choose capacity after a long editing/scene-switching trace; pipeline entry count is not a reliable byte-memory measure.

Also replace manually formatted string identities and parallel last-selection fields with Hashable specialization values. A single key definition should drive all three operations: lookup, equality/fast path, and constants. Keep platform pipeline descriptors separate where their attachment and stereo requirements differ.

## 6. Refactor RenderSettings around ownership and behavior

Current size: 5,249 lines and 510 withLock references. snapshot already captures backing fields under one lock; it should not be replaced with hundreds of individually locking property reads. Scene transactions correctly protect multi-property commits using a recursive lock.

The larger problem is that configuration storage, parameter composition, effect advancement, smoothing, persistence policy, and snapshot assembly share one class. SceneFrameEvaluator.evaluate holds a scene transaction across music processing, animation updates, interpolation, effects, and capture. This is a correctness boundary, but also a potential contention boundary; measure lock wait/hold durations before claiming it is a performance bottleneck.

Start with private typed backing-state domains while preserving the public API and the single transaction lock. Extract pure effect/derived-snapshot calculations into functions with explicit inputs. Keep mutation origin and scene replacement as explicit commands. Longer term, evaluate next-frame values locally and commit them in a short transaction, with clear handling of edits arriving during evaluation.

Do not replace the transaction with independent domain locks or a wholesale actor conversion: cross-domain atomicity and synchronous renderer reads are existing requirements. Moving methods to extension files alone improves navigation but does not reduce coupling.

## 7. Separate AnimationManager responsibilities

Current size: 2,779 lines. The class handles playback transport, keyframe interpolation/application, song fade/cues, file loading/saving, bundled overrides, recording, and sample simplification. These responsibilities have different lifetimes and testing needs.

Extract in steps: a pure timeline evaluator; a transport state machine with explicit clock/song inputs; a recording accumulator and simplifier; a scene repository. Leave a thin observable coordinator for UI publication and existing integration. Preserve base/manual/audio composition and persistence suppression throughout.

Validate pause/resume, jumps, scene replacement, cue transitions, recording timestamps, and manual edits during animated playback with explicit clocks. Existing keyframe and frame-evaluator tests are useful regression anchors.

## 8. Cleanup and documentation freshness

The older debt register cannot be treated as today's findings. FunctionConstantIndices now wraps the shared ShaderTypes.h enum; CustomShaderCompiler already has an eight-library LRU; snapshots and scene commits already have an atomic transaction boundary; preset scans already have debounce/signature caching/cancellation. The current uncommitted change also removes substantial renderer/shader code. Recommending those same fixes again would duplicate completed work.

`ParameterNodeSystem.swift:202` recenterBase has no other references in the inspected Threshold sources. Verify tests and intended API use, then remove it or document the actual planned consumer. Avoid sweeping deletion of platform code based only on a macOS compile.

Refresh TECH_DEBT and PERF_PUSH item-by-item, preserving historical measurements with their date/platform and marking superseded claims. PERF_LOG.jsonl is currently empty, so there is no recorded Vision Pro sweep there to substantiate new device performance claims.

## Lower-priority experiments

AudioAnalyzer already preallocates FFT buffers and compacts pending samples once per ingest, rather than once per window. A ring buffer could remove the remaining removeFirst compaction around line 946, but the remaining tail is bounded by the analysis window. Measure ingest latency and allocations first; this is lower priority than shader work.

Deferred shading may reduce the march kernel's live register state, but adds intermediate targets, bandwidth, pass coordination, stereo/foveation requirements, and custom-formula compatibility work. Prototype behind a benchmark flag only after capturing a current device baseline. Do not equate splitting Shaders.metal into files with reducing GPU register pressure.

Retain current normal-field safeguards: GetNormal uses analytic/approximate paths only where field composition permits them, and recomputes a matching reduced-iteration center for Mandelbox finite differences. An old suggestion to reuse the full-iteration cached center can reintroduce biased normals.

## Implementation sequence

1. Snapshot-derived specialization and build-ticket invalidation, with targeted regression tests.
2. Library scan lifecycle fix and bounded cache/retry policy.
3. Compute shadow parity, gated by image comparison and device measurement.
4. Pure timeline/effect extraction and typed settings backing state, in small behavior-preserving changes.
5. A device baseline before larger GPU experiments.

## Top-five implementation follow-up

Implemented the first five recommendations in the working tree:

- Vision render/compute selection receives the complete evaluated settings snapshot. PipelineFeatureSnapshot derives feature bakes from that frame; custom-library identity participates in fast-path reuse for built-in warp scenes too.
- Viewport builds carry unique tickets. Eviction invalidates publication, and stale success/failure/cancellation cannot consume a newer build of the same key.
- Library reload advances generation before nil-root returns, cancels prior work, debounces notifications, checks root identity before publication, and checks cancellation during directory traversal.
- Fragment and independent compute fallback lanes share the light-contribution shadow predicate. Shared tile-anchor shadows and barriers are preserved.
- Viewport specializations use a 64-entry LRU; vision render and compute specializations each use a 128-entry LRU. Generic fallbacks remain separately owned. Viewport failure metadata is bounded, with retry delay doubling from 250 ms up to 4 s, and cache statistics expose builds/hits/failures/evictions/stale completions.

Added ten regression tests for cache tickets, eviction, retry, recency, captured shader features, and library scan lifecycle. Capacity values are conservative configurable defaults, not device-measured memory budgets. Device GPU timing and compute-path image comparisons still require hardware validation.

Verification so far: final macOS, iPadOS, and visionOS builds passed. All ten new regression tests and embedded-source freshness checks passed in the final clean macOS run. The broader suite still fails two pre-existing checks: ParameterCatalogTests.swift:48 (eleven Navier Strokes specs missing descriptors) and ShaderWorldFieldGateTests.swift:279 (expects the cone-prepass guard removed by the pre-existing staged shader cleanup). Those unrelated source/test changes were not modified in this implementation. The bundled-scene Quick Look render gate is being checked separately.

Validation boundary: concurrent workspace edits subsequently split Shaders.metal into header modules and changed embedded-source generation. The five fixes remain present, but the successful builds/tests above refer to the pre-split snapshot. The Quick Look render gate was sampled waiting in HeadlessRenderer.compileCustomPipeline → Metal newLibraryWithSource, then stopped because its source snapshot had been superseded. No successful render-gate result or device performance measurement is claimed. The new shader-module organization needs its own validation.


Final shader-module validation (supersedes the pre-split validation boundary above):

- Split the shader library into Common, Rendering, Temporal, Post, Cache, and Overlays headers assembled by Shaders.metal. Extracted adaptive ray setup, reprojection/probe validation, tile bounds/seeding, fine march, and shading into inline helpers; preserved all 17 entry points, three barriers, and edge-lane write masking.
- Shared vertex proxy math, removed the edge detector's duplicate center fetch, replaced Metal function-constant literals with the existing shared FCIndex enum, named the distance-cache slice binding, and shared the bake/validation DE parameter policy.
- Updated runtime source assembly, Xcode embed inputs, freshness/source checks, transform regression source lookup, and contributor/module documentation. Restricted custom near-match pipeline fallback to the same fractal type and scene feature gates.
- Final macOS and visionOS builds passed. All four target-local shader embeds matched the final assembly. The clean macOS suite passed 525 of 527 tests, including all 91 custom-formula compile cases, embed freshness, and Metal diagnostic checks. The remaining failures are the pre-existing parameter-catalog descriptor mismatch and obsolete cone-prepass source assertion.
- Quick Look rendered all 51 gate scenes successfully, with zero skips or failures. Twelve original/refactored adaptive GPU comparisons passed across regular and odd viewport sizes, history reuse, foveation, and bounds rejection; color/depth agreed within 0.0001 and edge/eye write masking was preserved (268 reference hits).
- The existing transform GPU check passed 90,112 cases with eight repetitions and zero relative point/DE error, plus custom hook dispatch and zero-strength bypass checks.

No device-specific speedup is claimed. Map macro replacement and radius specialization remain deferred until profiling; Vision Pro frame-time performance still requires on-device measurement.
