# Threshold Renderer: Cache, Divergence & Memory Design Document

*Audit synthesis — Metal raymarching fractal-art app (visionOS compute + macOS/iOS fragment, `actor Renderer` / `final class ThresholdMacRenderer`). All findings grounded in file:line; impact weighted by GPU-cost / launch-hitch / memory-footprint per the project's "GPU cost is the lever, not buffer count" reality. Load-bearing correctness claims were re-verified against the code at synthesis time.*

---

## 1. Executive summary

The five highest-leverage moves, each one line:

1. **Persist pipeline binaries across launches via `MTLBinaryArchive`** — today every cold start recompiles the init-path pipelines from `default.metallib` (`Renderer.swift:316–512`) *plus* the per-preset set from `precompilePresetPipelines` (`RendererPipelineCache.swift:336`), none cached cross-launch; this is the single biggest launch-hitch + battery lever for a GPU-bound app. *(high impact, medium risk)*
2. **Persist compiled `.threshfx` libraries to disk** — `CustomShaderCompiler.libraryCache` is in-memory only (`CustomShaderCompiler.swift:114`), so every returning custom scene re-pays a documented 0.5–5s `makeLibrary(source:)` recompile on relaunch (`RaymarchRenderView.swift:56–57`); key by `combinedHash` **plus a header-ABI version** (the embedded headers are not in `combinedHash`). *(high impact, medium risk)*
3. **Tear down the ~38MB Buddhabrot working set on mode-exit** — `buddhabrotRenderer` is lazy-inited and *never* released (`Renderer.swift:1022`, single assignment site), pinning tens of MB resident for the whole session on a memory-pressured Vision Pro. *(high impact — but GPU-lifetime fence required, see §4.1)*
4. **Fix the single-buffered `tileUniformBuffer` CPU/GPU race** — the active visionOS compute path allocates `stride*2` (two eyes, no in-flight slots) while `maxBuffersInFlight=2` (`Renderer.swift:516–518`); fixing it requires both the allocation change *and* threading the buffer index through every tile-uniform write site. *(medium impact, low risk)*
5. **Fix the dead "shared quality" compute fallback for mandelbulb-with-baked-power** — the headline heavy fractal silently falls through to the generic kernel because the shared key carries `powerKey`+`sceneKey` the startup keys never built (`Renderer.swift:492` vs `RendererPipelineCache.swift:855`), and the per-frame fast-path (`:858–864`) then *pins* that generic fallback across many frames. *(medium impact, low risk)*

Secondary structural work (de-duplicate the hand-copied `Uniforms` assembly, the `CX{hash}_` custom-shader machinery, and the triplicated mandelbulb-power helper) reduces drift risk but is maintainability, not GPU cost — sequenced after the caching wins.

---

## 2. Cache more

### 2.1 `MTLBinaryArchive` for built-in pipelines (HIGH)

**What/why.** `MTLBinaryArchive` appears nowhere in the repo (grep returns zero hits). `Renderer.init` synchronously builds the init batch before the first frame: base render (`Renderer.swift:316`), quad-shared (`:328`), 3 MetalFX resolve (`:343/352/363`), 8 quality-preset render variants (`:425/438` × 4 `QualityPreset.allCases`), 4 specialized compute + 1 generic compute (`:494/510–511`). **Separately**, `precompilePresetPipelines` (`RendererPipelineCache.swift:336`) builds one pipeline *per saved user preset* asynchronously after init — an unbounded, user-data-driven count that competes with first-frame readiness and is the launch cost the archive most needs to cover. Each `makeRenderPipelineState` / `makeComputePipelineState` (`RendererPipelineHelpers.swift:72`, `RendererPipelineCache.swift:804`) drives the Metal back-end compiler with **no `descriptor.binaryArchives` attached**, so the GPU-compile result is discarded at process exit and recomputed every cold launch.

**How.** Own an `MTLBinaryArchive` on the device wrapper, lazily loaded from Application Support (NOT the repo). Concrete API and call sites:
- Load at setup, alongside `precompilePresetPipelines` (`RendererPipelineCache.swift:336`): build an `MTLBinaryArchiveDescriptor`, set `.url` to the persisted archive if present, `device.makeBinaryArchive(descriptor:)`.
- In `buildRenderPipelineWithDevice` / the compute builder, set `descriptor.binaryArchives = [archive]` **before** the `make*` call.
- After the init batch **and** after `precompilePresetPipelines`, call `archive.addRenderPipelineFunctions(descriptor:)` / `archive.addComputePipelineFunctions(descriptor:)` for **both** the enumerable init descriptors *and every preset descriptor*, then `archive.serialize(to:)` on a low-priority `Task`.
- Wrap all archive calls in `try?`.

**Impact.** Eliminates a deterministic GPU-compiler hitch paid on *every* launch (init batch + preset set), plus battery cost. Because the preset count is user-data-driven and uncapped, covering it is what makes the archive worth the effort — measure both separately (B0).

**Risk (medium).** The compute paths currently use the function-only `makeComputePipelineState(function:)` overload (`Renderer.swift:511`) — attaching an archive requires switching to `MTLComputePipelineDescriptor` + `makeComputePipelineState(descriptor:options:)`, a larger edit than the render path (which already uses a descriptor — a clean drop-in). Archive miss falls back transparently to today's compile, so it is purely additive. Function-constant specialization is part of the `MTLFunction` identity, so each baked variant archives and matches separately — exactly what the cache keys enumerate. **Caveat:** `buildRenderPipelineWithDevice` bakes stereo / vertex-amplification + CompositorServices color/depth formats from the `layerRenderer`, so the archive is implicitly keyed to that foveation/amplification descriptor and must invalidate if it changes across launches/devices (handled by §2.3 keying + Metal's own validation).

> **✅ IMPLEMENTED (compute path) — 2026-06-26.** Added `PipelineBinaryArchive`
> (`Threshold/Rendering/Core/PipelineBinaryArchive.swift`): a `@unchecked Sendable`
> wrapper around an `MTLBinaryArchive` persisted to `Application Support/ThresholdPipelineArchive/`,
> keyed `compute-r{registryID}-{os}-v{CFBundleVersion}.metallib` (per-GPU, per-OS,
> per-app-build; stale same-purpose files pruned on launch — the §2.3 key). Wired
> into the visionOS **compute** path only (the GPU-bound one): `buildComputePipeline`
> gained an `archive:` param and now builds via `MTLComputePipelineDescriptor` +
> `makeComputePipelineState(descriptor:options:reflection:)` so it can `attach`
> (lookup) then `record` (capture); the startup batch (`Renderer.swift` init), the
> generic fallback, and the lazy `enqueueBackgroundComputePipelineBuild` all pass
> `self.pipelineArchive`. Serialization is off-actor/low-priority: once after
> `precompilePresetPipelines`, and coalesced (`scheduleArchiveSerialize`, 4 s
> debounce) after bursts of interaction-driven lazy builds. Every archive call is
> `try?`-guarded and miss is silent (no `failOnBinaryArchiveMiss`), so it is purely
> additive — corrupt/stale/wrong-GPU files fall back to today's compile. Both
> visionOS and macOS targets build clean.
> **Not yet wired:** the render path (visionOS `buildRenderPipelineWithDevice` init
> batch + Mac `RaymarchRenderView` pipelines) — `record(_ MTLRenderPipelineDescriptor)`
> already exists on the helper as the drop-in seam; no render site attaches it yet.

### 2.2 Persist compiled `.threshfx` libraries (HIGH)

**What/why.** `CustomShaderCompiler` holds `private var libraryCache: [String: MTLLibrary]` (`CustomShaderCompiler.swift:114`), populated by `device.makeLibrary(source:options:)` (`:152`) with no on-disk persistence. The synthesized source concatenates a prefix + the user's DE source + ~headers + a suffix (`synthesizeSource`, `:190–219`). On relaunch the in-memory cache starts empty, so a returning custom scene re-pays the full 0.5–5s compile (`RaymarchRenderView.swift:56–57` doc comment confirms the magnitude) — rendering fog-only until the library lands.

**How.** Two separable costs:
- **(a) Pipeline-state half** — route the `CX{hash}_` custom pipelines (`RendererPipelineCache.swift:566–613`, `RaymarchRenderView.swift:842`) through the §2.1 archive with the sub-key including the source hash. *Contingent on §2.1 existing first.*
- **(b) Source-compile half** — `MTLBinaryArchive` **cannot** reconstruct an `MTLLibrary`, so `device.makeLibrary(source:)` still runs every relaunch. **⚠️ CORRECTION (verified against Apple docs 2026-06-26):** the original plan here — "persist a precompiled `.metallib` … reload via `device.makeLibrary(URL:)`" — is **not buildable as written**. `device.makeLibrary(URL:)` is the *load* half, but Metal has **no `MTLLibrary.write(to:)`/serialize API**: you cannot turn a runtime `makeLibrary(source:)` result into a `.metallib` on disk. The `.metallib` files `makeLibrary(URL:)` reads are produced by the *offline* `metal`/`metallib` toolchain, which isn't available on-device. The **only** supported runtime persistence for a compiled library is `MTLDynamicLibrary.serialize(to:)` → reload via `device.makeDynamicLibrary(url:)` — but a dynamic library exposes *linked, visible functions*, not standalone kernel/fragment entry points, so adopting it means **restructuring the splice**: factor the custom DE into a `[[visible]]`-function dynamic lib and compile a thin host that links it (via `MTLCompileOptions.libraries` / `MTLComputePipelineDescriptor.preloadedLibraries`). That host still front-end-compiles every launch, so the win is partial and the complexity is high. **Net:** B1-as-originally-scoped is deferred pending a real magnitude measurement (B0) and a decision on the dynamic-library restructure; the §2.1 archive already covers the *pipeline-state* half of the custom path (route `CX{hash}_` PSOs through it, item (a)) which is the tractable piece.

**Keying — must include the headers, not just the DE source.** `combinedHash` embeds `fractal.shortHash` / `spaceWarp.shortHash`, each a SHA-256 of `functionStem|metalSource` (`EmbeddedFormula.swift:124–131`) — i.e. **only the user DE source**. The synthesized source also concatenates `synthesizedSourcePrefix`, the stripped dispatch template, and `synthesizedSourceSuffix` (`CustomShaderCompiler.swift:197/214/218`), which are **not** in `combinedHash`. An app update that edits an embedded header therefore does *not* change `combinedHash`, so a stale persisted `.metallib` with mismatched function signatures could be reloaded and only fail later at pipeline creation (off the compile site, hard to attribute). **Fix:** key the persisted `.metallib` filename on `combinedHash` **+ a header-ABI version constant** (bump it whenever the prefix/suffix/dispatch template changes) **+ device/OS guard.** A `try?` around `makeLibrary(URL:)` covers the throw case; the header-ABI version covers the silently-incompatible-signature case.

**Impact.** Turns a multi-second black/fog-only gap on custom-scene re-entry into a near-instant load.

**Risk (medium).** A persisted `.metallib` is GPU/OS-version specific — key/guard by Metal device + OS version, or accept `makeLibrary(URL:)` failure and fall back to source compile. `CustomShaderCompiler` is an actor (`:50`), so disk I/O stays serialized on its executor, off the render/main thread — same place the 0.5–5s compile already blocks. The app is sandboxed, so its Application Support container is outside the FileProvider-synced repo folder (the build-artifact xattr constraint does not touch on-device caches). Both render paths consume the same compiled library (`Renderer` actor and `MacCustomShaderBox.activate`, `RaymarchRenderView.swift:59–79`), so a disk-loaded library serves both identically. **Note:** the `EmbeddedFormula.swift:123` comment calling `sourceHash` "the on-disk metallib filename" is stale/aspirational — no such write path exists today, corroborating the gap.

### 2.3 Archive / metallib invalidation strategy (LOW, enabler)

Compose the on-disk path/filename from (1) `device.registryID` (per-GPU scope), (2) `operatingSystemVersion` build string (already used in `PerfLog.swift:46`), (3) `CFBundleVersion` or a hash of bundled `default.metallib` mtime/size (app-update invalidation), (4) per-entry source hash for custom pipelines, and — for §2.2b only — (5) the header-ABI version. On version mismatch, delete the old directory and start fresh (one cold compile after update, then steady-state cached). Guard every load/serialize in `try?`. **Caveat:** `operatingSystemVersion` does not capture intra-OS GPU-driver revisions, so the key only *reduces* rejection churn — it does not replace Metal's internal archive compatibility validation, which is the actual correctness backstop. Archive/metallib serialize/load is blocking disk I/O and must run at setup/precompile time (near `precompilePresetPipelines`, `RendererPipelineCache.swift:336`), **never** on the compositor render loop.

### 2.4 Fix the dead "shared quality" compute fallback (MEDIUM) — ✅ IMPLEMENTED

> **Implemented (compute path) + two synthesis claims corrected after re-reading the code:**
> 1. **The fast-path is NOT pinned across the steady-state window.** `insertBuiltComputePipeline` already sets `lastSelectedComputePipeline = nil` on completion (`RendererPipelineCache.swift:1031`), exactly like the render path's `:1005`, and `acceptsCompletedCustomPipelineBuild` returns `true` for built-in keys (`:974`). So the exact power-baked pipeline IS picked up a few frames after it builds. The real (bounded) cost is the **cold-miss / active-interaction window** — every time the exact key is absent (startup, or while dragging power/iteration/ray-step on a baked-power Mandelbulb) the path served the *fully-generic* kernel instead of the FI/RS-specialized one.
> 2. **The render path is NOT affected** — its shared key is `prefix + "FI{fi}_RS{rs}_N…"` with **no `powerKey`** (`RendererPipelineCache.swift:33`), so it already hits the startup tier for baked powers. No `selectPipeline`/`Renderer.swift:422` change needed. The bug is compute-path-only — which is the visionOS GPU path, so it is the one that matters.
>
> **Fix as landed:** after the powered `sharedKey` miss, the exact build is still enqueued (steady state keeps the power-bake), and the *powerless* key (`String(sharedKey.dropLast(powerKey.count))`, equal to the startup `"FI{fi}_RS{rs}"`) is probed as the this-frame fallback — serving the FI/RS-specialized pipeline instead of the generic kernel. Guarded by a debug `assert` on the key grammar. Telemetry source `"shared-powerless"`. visionOS build verified.

**What/why.** Startup builds shared compute pipelines with key `"FI\(fi)_RS\(rs)"` — no `powerKey`, no `sceneKey`, no prefix (`Renderer.swift:492`). But the runtime `sharedKey` is `prefix + "FI..._RS...\(powerKey)\(sceneKey)"` where `powerKey="P{n}"` for any mandelbulb power in `{2,3,4,5,6,8,10,12,16}` and `sceneKey="_B{0|1}_CP{0|1}"` (`RendererPipelineCache.swift:846/855`, verified). So a power-8 mandelbulb's `sharedKey` is something like `"…FI…_RS…P8_B0_CP0"` — **never in the cache**. The exact key also misses on a fresh config, so the lookup falls through (`:942–970`) to enqueue a background build and serve the *un-specialized* generic kernel `adaptiveHierarchicalPipeline8x8` (`:960`).

**Worse: the fast-path pins the generic fallback.** The per-frame fast-path at `:858–864` caches `lastSelectedComputePipeline` keyed on FI/RS/FT/customHash/power/bubble/packet. When the shared+exact miss serves the generic fallback, `cacheSelectedComputePipeline` (`:961`) stores it as `lastSelectedComputePipeline`. So on subsequent frames with unchanged params, the fast-path **returns the generic pipeline directly** — and keeps doing so *even after the background-built specialized pipeline lands in `computePipelineCache`* — until the next FI/RS/power/bubble/packet change invalidates the fast-path. The failure mode is therefore "generic kernel for the whole steady-state window on the headline heavy fractal," not a transient one-frame dip. **(See §A3 for the related completion-retrigger gap.)**

**How.** After the powered `sharedKey` miss, try a second shared lookup with `powerKey == ""` **and** `sceneKey == ""` — probe `computePipelineCache["FI\(fractalIterations)_RS\(maxRaySteps)"]` directly. This is valid **only because** the startup shared pipelines leave power, bubble, and packet as *undefined function constants* that the shader reads from uniforms at runtime (confirmed by the empty-`MTLFunctionConstantValues` build at `Renderer.swift:509–511` and the inline NOTE there). **Document this probe as "powerless AND sceneKey-less, valid only while the shared tier leaves power/bubble/packet as runtime-uniform FCs," and add a debug assert** — if a future edit *bakes* bubble or packet into the shared tier, this probe would silently serve a wrong-scene pipeline. Apply the parallel fix in `selectPipeline` for the render shared tier against the startup keys at `Renderer.swift:422`.

**Impact.** Yields a specialized-iteration pipeline instead of the generic kernel for the most common heavy fractal, across the entire steady-state window (not just one frame). One extra dictionary probe on the already-cold miss path.

**Risk (low).** Miss-path-only, no new mutable state, runs on-actor. The generic fallback is functionally *correct* today (FCs fall back to uniforms), so this is a quality/perf dip, not a correctness bug. **Render-path caveat:** startup render pipelines bake `colorIterations = preset.fractalIterations`; a user-overridden `colorIterations` still misses on `CI` even with a powerless key (pre-existing — the compute key has no `CI`, so the compute benefit is broader than the render benefit).

### 2.5 Mac fragment cache warms nothing at startup (MEDIUM — prewarm is the valuable half)

**What/why.** `resolveActivePipeline` runs every frame but `MacSpecializedPipelineCache` is cold at launch — nothing prewarmed — so the first frames after launch / fractal-switch always render via the unspecialized generic `pipelineState` until the async build lands (`RaymarchRenderView.swift:758–889`). The Mac path also re-implements specialization logic the visionOS path already has (see §3.3/§3.4).

**How.** Add a Mac startup warm: on launch and on fractal-type change, call a `resolveActivePipeline`-equivalent build for the current/default settings *off the render thread*, mirroring `precompilePresetPipelines`. `MacSpecializedPipelineCache` is a `Mutex`-protected `Sendable` (synchronous reads, async completion-handler stores), and the warm just calls the existing async `makeRenderPipelineState(descriptor:completionHandler:)` — safe.

**Impact.** Eliminates the first-frame generic-pipeline render after launch / fractal-switch on Mac/iOS. (The de-dup half is §3; the prewarm is the higher-value, independent part.)

**Risk (low).** No actor concern (Mac is a `final class`); no compositor; no build-artifact interaction.

### 2.6 Custom-formula near-match O(n) linear scan (LOW)

**What/why.** On a `.custom` cache miss with an active formula, `selectPipeline` computes `nearMatchCustomPipeline` by scanning `pipelineCache.keys.first(where: { $0.hasPrefix("CX{hash}_") && $0.hasSuffix("_QS")==useQuadShared })` (`RendererPipelineCache.swift:566–574`). This linear scan over the entire unified dict runs **every frame the exact key is absent** — i.e. continuously while dragging a slider on a custom formula (every FI/RS tick is a new exact key → miss → re-scan until the async build lands).

**How.** Maintain a `[String: MTLRenderPipelineState]` representative map keyed by `"CX{hash}_{QS?}"`, populated in `insertBuiltRenderPipeline` (`:1002`) **and** the sync first-build branch (`:613`), and cleared at **three** sites: `evictCustomShaderPipelines(forHash:)` (`RendererCustomShader.swift:220–228`), `forceRecompileShaders`' `pipelineCache.removeAll()` (`:169`), and `resetPipelineFastPaths` (`:242`) — otherwise the representative can dangle to an evicted pipeline. Replace the scan with an O(1) lookup.

**Impact.** Pure performance on the custom-formula miss path; built-ins unaffected. **This is the fragment render-pipeline path, not the compute raymarch kernel that is the visionOS GPU bottleneck — zero GPU-cost effect**, so low priority.

**Risk (low).** All sites are isolated on `actor Renderer`; eviction removes all keys for a hash atomically, so a per-(hash,variant) representative stays consistent if cleared there.

### 2.7 Per-frame lock re-reads on the pipeline hot path (LOW)

`selectComputePipeline` reads `effectiveSafetyBubbleEnabled` and `coherentPacketEnabled` via the `renderSettings` lock on every call before the fast-path guard (`RendererPipelineCache.swift:847–848`); `selectPipeline` does the same for bubble (`:443–444`). The frame loop already builds a `settingsSnapshot` (`Renderer.swift:1001`) that holds these values and that the uniform writes consume (`:1402/1450`) — so the pipeline key is computed from a *different lock instant* than the uniforms. Thread the already-snapshotted `bubbleEnabled`/`packetEnabled` into the existing `RenderPipelineRequest`/`ComputePipelineRequest` structs (populate from the snapshot at the call sites; keep the live-read fallback for `nil`). **`colorIterations` is already threaded** (`RendererPipelineCache.swift:67`, read as `request?.colorIterations ?? …` at `:443` — verified) — only bubble/packet need it. The real benefit is single-instant key/uniform agreement, not measurable CPU savings (`os_unfair_lock` is an uncontended spinlock) — a correctness tidy, low priority.

---

## 3. Remove divergence

The two renderers already share their heavy math via the cross-platform `RenderPrecompute` namespace (`RendererPrecomputeHelpers.swift` is a thin forwarding shim — the established "one source of truth" pattern, `RenderPrecompute.swift:14`). The remaining divergence is concentrated in hand-copied logic where the two copies have **already drifted** and will silently diverge again on the next edit.

### 3.1 `Uniforms` struct assembled field-by-field in two renderers (MEDIUM — already drifting)

**Current.** The Mac path builds frame `Uniforms` in `makeUniforms` (`RaymarchRenderView.swift:1289–1449`); the visionOS path builds the same ~60-field struct in `uniforms(forViewIndex:)` (`RendererGameState.swift:194–295`). Both repeat identical surrounding blocks: the Kleinian `traceScaleFloor`/`maxViewDistanceCap`/`smoothedMaxViewDistance` ramp (`RaymarchRenderView.swift:1300–1321` vs `RendererGameState.swift:102–122`), the Kleinian fog rescale (`:1357–1365` vs `:170–182`), the `lightingWave`/`animatedColorMix`/`animatedGlow` block (`:1367–1370` vs `:185–189`), the scale-corrected safety-bubble radius, and the mandelbulb bubble force-off (`:1395/1399` vs `:247/251`).

**Already diverged:** Mac bakes Halton jitter into the projection and uses a clamped divisor `viewDistanceScale = max(min(effectiveScale, smoothedScale), floor)` (`:1316`) that the visionOS copy lacks (`:118` divides by `traceScale` directly).

**Unification.** Move the byte-identical blocks (Kleinian ramp, fog rescale, glow/colorMix, scale-corrected bubble radius, mandelbulb force-off) into `RenderPrecompute` static helpers consumed by both. Have each renderer build `Uniforms` via a shared builder taking the precomputed pieces + per-platform matrices, so the field list exists once. **Deletes** ~150 lines of duplicated math.

**Risk/churn (medium).** The shared helper **must** be a pure static func (`makeUniforms` is on the non-actor `final class`; `uniforms(forViewIndex:)` is a closure inside `actor Renderer.updateGameState`). Caller-patched per-platform fields the builder must leave alone: `projectionMatrix` (Mac bakes Halton jitter `:1335–1337`, visionOS passes raw per-eye), `floorCircle`/`deviceAnchor` (visionOS-only), and `benchCollectSteps` (Mac hardcodes 0). The viewDistance ramp **mutates `smoothedMaxViewDistance` instance state**, so the helper must *return* the new smoothed value, not mutate inside.

> **Do NOT blindly unify the `viewDistanceScale` divisor.** The Mac clamp is a *deliberate, commented* zoom-in center-hole fix (`:1309–1315`; corroborated by project memory `desktop-zoom-mechanism` / `zoom-proxy-geometry-farclip`). The visionOS path uses a different zoom model (model-scale + `deviceAnchor` + per-eye), so its divide-by-`traceScale` may be intentionally distinct. Treat the ramp as a parameterized helper whose **divisor is a per-platform argument**, not a single "correct" value. The safe subset (fog/glow/colorMix/bubble/mandelbulb) is low-risk; the divisor is the sole medium-risk piece.

### 3.2 `CX{hash}_` custom-shader cache + state holder implemented twice (MEDIUM)

**Current.** `MacCustomShaderBox` (`RaymarchRenderView.swift:24–103`) is an `NSLock`-guarded `(library, hash, compiler)` holder with an atomic `snapshot()`; `Renderer.CustomShaderState` (`RendererCustomShader.swift:262–300`) is the **field-for-field identical** holder (`MacCustomShaderBox:21` doc comment literally says "mirrors the visionOS CustomShaderState"). The `"CX\(h)_"` prefix is duplicated at **6 sites across 3 files** (`RaymarchRenderView.swift:76,800`; `RendererCustomShader.swift:84,221`; `RendererPipelineCache.swift:567,976`). `CustomShaderCompiler.combinedHash` is already shared.

**Unification.** Promote the holder to one shared `@unchecked Sendable` type (no visionOS-only dependency — both use only `MTLDevice`/`MTLLibrary`/`NSLock`/`String`) plus a single free key-prefix helper. **Name the helper distinctly** — e.g. `customPipelineKeyPrefix(hash:)` — to avoid colliding with the existing instance method `customCacheKeyPrefix(for:)` (`RendererPipelineCache.swift:850`, which keys on `FractalModelType`, a different thing). Collapsing the 6 string sites to one guarantees the Mac inline key can never drift from the visionOS `keyContext` prefix.

**Do NOT merge the two cache *containers* or the full activation methods.** `MacSpecializedPipelineCache` is `Mutex`-guarded (synchronous hot-path read by design); the visionOS caches are plain dicts inside the actor — genuinely different concurrency models. The activation *logic* also diverges materially: visionOS uses an MRU retention scheme (`retainCustomShaderPipelines`, `customPipelineRetentionLimit=4`, `RendererCustomShader.swift:203–217`) while Mac uses blanket single-formula eviction (`cache.evict(prefix:)`, `:76`). Only the bare guard (`if hash == newHash, library != nil { return }`) is identical. **Share the holder + prefix string only.**

**Risk (medium).** The shared holder must keep `snapshot()` atomic — Mac's render thread reads `(library,hash)` every frame *off-actor* and relies on a single-lock read to avoid pairing a library-B pipeline with hash-A (`:39–41,795`); the visionOS side serializes via the actor and uses separate getters. The unified type must vend both patterns, and preserve that the actor remains sole owner of its `nonisolated(unsafe) static var` instance (`:300`). Pure in-memory dedup — no GPU-cost or on-disk effect.

### 3.3 `specializedMandelbulbPower` helper triplicated (LOW)

The exact integer-power gate (`round`, `abs(raw-rounded)<0.01`, member of `[2,3,4,5,6,8,10,12,16]`) is written **three times**: `FunctionConstantConfig.specializedMandelbulbPower` (`RendererPipelineHelpers.swift:90–100`), `ThresholdMacRenderer.specializedMandelbulbPower` (`RaymarchRenderView.swift:761–771`, doc-comment admits it "Mirrors the visionOS…"), and the inline `mbPowerInt` closure in `selectComputePipeline` (`RendererPipelineCache.swift:837–845`, verified). It is a pure static func over `(FractalModelType, FormulaParams)` with no platform dependency. Move it to a platform-neutral file (`FractalModelType.swift` or `FormulaCatalog.swift`, both Foundation+simd only) and delete the other two. **Implementer note:** the `RendererPipelineCache` copy is a structural variant (precomputes `mbPowerRaw` for non-mandelbulb then runs unconditionally) — route through the helper's `.mandelbulb` guard, which is behavior-equivalent. The supported-power set must stay in lockstep with `fastPowR`'s shader fast-paths, so three copies are a latent correctness trap. Maintainability, not GPU cost.

### 3.4 Mac pipeline build hardcodes FC magic indices (LOW)

`buildSpecializedPipeline` sets function constants by **raw integer index** — 0/6/7/9/12 — with a comment (`RaymarchRenderView.swift:848–851`) explaining it cannot use the visionOS `FunctionConstantIndex` enum. The enum lives in `RendererCoreTypes.swift:16` (a bare `Int` enum, **no CompositorServices dependency of its own**), but that file's line 1 is `@preconcurrency import CompositorServices` and `project.pbxproj` lists it as a synchronized-folder membership *exception* for the Mac/iOS targets — that's the real barrier (not an `os()` gate). Relocate the bare enum to an all-targets-neutral file and have the Mac builder use symbolic indices; compile-time source organization only, no runtime/format change. If FC slots ever renumber, the Mac magic numbers silently bind the wrong constants. **Caveat:** the proposal's secondary "route Mac through `toMTLConstants`" is more involved — that method sets a *superset* (shadowIterations, qualityMode, debugHierarchical…) the Mac `fragmentShaderMono` path doesn't use, and lives in the Mac-excluded helpers file; the primary enum-relocation is the clean, low-risk move.

### 3.5 Desktop MetalFX managers — keep separate

Mac/iOS retain separate spatial and temporal upscalers because their inputs differ: temporal additionally owns motion/history state. Shared texture allocation remains centralized in `MetalFXTextureSupport`. The removed visionOS stereo manager is no longer part of this comparison.

---

## 4. Right kinds of memory

**Baseline is already disciplined:** a repo-wide grep for `.managed`/`storageModeManaged` returns **zero hits** (correct for Apple-Silicon-only targets); all per-frame CPU-written buffers are `.shared`; GPU-only compute textures/depths are `.private`; the iOS `.memoryless` transient-depth rule is centralized in `MetalFXTextureSupport`. The wins below are narrow.

| Resource | File:line | Current | Recommended | Rationale / footprint |
|---|---|---|---|---|
| Buddhabrot `splatBuffer` | `BuddhabrotRenderer.swift:629` | `.shared` | **`.private`** | GPU-only (emission kernel → radix sort → splat render); never CPU-read. ~16MB (524 288 × 32B). Mislabel; `.private` frees coherency bookkeeping. Footprint unchanged on unified memory. |
| Buddhabrot `sortKeysA`/`sortKeysB` | `:634`, `:636` | `.shared` | **`.private`** | GPU radix-sort ping-pong, never CPU-touched. ~4MB each. |
| Buddhabrot `histogramBuffer` | `:643` | `.shared` | **`.private`** | GPU-only radix histogram. ~2MB. |
| Buddhabrot density / `atomicCounter` | `:588/592–596`, `:556` | `.shared` | **keep `.shared`** | Legitimately CPU-read: density max-scan (`:1364/1381`), count readback (`:1250`). Do NOT change. |
| Buddhabrot whole working set (dormant) | `Renderer.swift:1022` | resident forever | **`= nil` on mode-exit, after GPU fence** | See §4.1 — the real footprint win (~38MB). |
| visionOS render targets / depths | `Renderer.swift:1528/1570` | `.private` | **keep** | Correct GPU-only. |
| MetalFX temporal depth | `MacTemporalUpscaler.swift:197` | `.private` (`.shaderRead`) | **keep — must NOT force memoryless** | MetalFX/ASW *samples* depth, so `.shaderRead` is mandatory and incompatible with tile-only `.memoryless`. Document inline. |
| Mac/iOS fragment depth | `RaymarchRenderView.swift:948` | `.memoryless` (iOS) / `.private` + `storeAction=.dontCare` | **keep** | Reference-correct TBDR transient-depth. |
| Mac spatial depth | `MacSpatialUpscaler.swift:81–85` | `[.renderTarget]` only → memoryless on iOS | **keep** | Correct — the model to preserve. |
| Screenshot color/depth (512²) | `RendererScreenshot.swift:7–30` | `.shared` / `.private`, session-resident | **lazy-alloc + free in completion handler** | ~2MB, dormant >99%. See §4.3. |
| Per-frame uniform/tile/rate-map buffers | `Renderer.swift:295/517/1374`, `RaymarchRenderView.swift:458` | `.shared` | **keep** (but tile buffer under-sized, §A2) | Correct on unified memory. |

**Purgeability (`.volatile`) is unused anywhere**, but for the Buddhabrot case it is *more* hazardous than `= nil` (see §4.1) so it is **not** recommended. **Argument buffers / bindless are NOT justified** — `encodeAdaptiveCompute` binds ≤2 buffers + 3 textures (`Renderer.swift:1480–1489`); total bind sites are 12 (Renderer) / 6 (Mac). An `MTLResidencySet` already pre-validates buffers and batch-registers textures on (re)alloc. Recorded so it isn't revisited.

### 4.1 Buddhabrot working set never released (HIGH footprint — but GPU-lifetime fence required)

`buddhabrotRenderer` is lazy-inited on first `.buddhabrot` entry (`Renderer.swift:1022`) and there is **no path** anywhere setting it to `nil` or releasing resources on mode-change (grep confirms a single assignment site). It permanently holds (default `resolution=128`, `maxSplatCount=524 288`, mono): density 8MB + splat ring **16MB** + sortKeys A/B 8MB + histogram 2MB + r16Float volume 4MB = **~38MB** (more in RGB: 24MB density + rgba16Float volume ~16MB). On a memory-constrained Vision Pro these sit resident for the rest of the session even back in normal fractal rendering.

**Fix.** When `runtimeViewModeForRenderer` transitions away from `.buddhabrot`, set `buddhabrotRenderer = nil` (cheapest; rebuild on re-entry — it's already lazy).

**Risk — NOT "low" as the draft claimed; GPU lifetime, not just thread safety.** Actor isolation makes the *assignment* race-free, but it does **not** make the *GPU resource* release safe: the Buddhabrot buffers may still be referenced by an un-retired command buffer in flight (`maxBuffersInFlight=2`), and density buffers are `.shared` and CPU-read each frame for max-density readback (`Renderer.swift:1352–1382`). Releasing or reusing their backing while the GPU still reads them is undefined. **The teardown must occur after the last Buddhabrot command buffer has retired** — gate it on the existing in-flight semaphore / a `addCompletedHandler` fence on the final Buddhabrot frame, then `= nil` on the actor. This is mechanically simple but is the load-bearing correctness requirement; do not drop the resource synchronously at the mode-switch instant. (The earlier "purgeable `.volatile`" option is rejected: `setPurgeableState` on a buffer with in-flight GPU reads is *more* hazardous than a fenced `= nil`, and `markActive` would then need a reallocation-on-reclaim path anyway.) The Mac/iOS path has no Buddhabrot path, so this is visionOS-only and correctly scoped.

### 4.3 Screenshot scratch + residency capacity (LOW polish)

- **Screenshot textures** (`RendererScreenshot.swift:7–30`): 512² `.shared` color + `.private` depth, session-resident, written only in the rare capture flow. Lazy-alloc + free. **Caveat:** `renderScreenshot()` captures `screenshotTexture` into `addCompletedHandler` (`:140–145`) running post-commit, so a lazy-free must happen *in that handler*, not synchronously after commit. ~2MB — cheap cleanup, marginal next to §4.1.
- **`MTLResidencySet` `initialCapacity=8`** (`RendererSetupAndSession.swift:23`): steady-state max is 2 base buffers + 3 compute textures = **5** (not "past 8"). Whether `MTLResidencySet` reallocs *at* vs *above* capacity is unspecified by Apple, so "forces a grow" is not guaranteed. Keep modest headroom above five allocations — a single literal, zero risk.

---

## 5. Prioritized plan

Ordered by impact ÷ risk, grouped into landable slices. **Bold = high-leverage.**

### Slice A — Independent, high-leverage, land first
- **A1. Buddhabrot dormancy teardown** (§4.1, HIGH footprint). ~38MB reclaimed, self-contained, visionOS-only. **Must gate the `= nil` on a GPU-completion fence for the last Buddhabrot frame** — that fence is the load-bearing part, not the assignment. Highest footprint win in the document.
- **A2. `tileUniformBuffer` double-buffering** (§Move #4 / §4 table, MEDIUM / low). Two-part change: **(a)** enlarge the allocation from `stride*2` to `stride * 2 * maxBuffersInFlight` (`Renderer.swift:516`); **(b)** thread `uniformBufferIndex` into the per-eye offset at *every tile-uniform write site* and at the compute encoder bind. The allocation alone is a no-op if the writes don't offset by the in-flight index. **Pre-req for the implementer: locate the `TileUniforms` memcpy/write sites and the encoder `setBuffer(tileUniformBuffer, offset:…)` bind — these are NOT yet cited and must be enumerated before estimating; `updateDynamicBufferState()` (`:898`) advances the index for the *main* `dynamicUniformBuffer`, and it must be confirmed (or made) to also drive the tile buffer's offset.** Independent.
- **A3. Dead shared-compute fallback fix + fast-path/completion interaction** (§2.4, MEDIUM / low). Add the powerless+sceneKey-less shared probe (with the documented validity caveat + debug assert). **Additionally** confirm the generic-fallback path clears/repoints the fast-path (`lastSelectedComputePipeline`, `:961`) once the background-built specialized pipeline lands — `acceptsCompletedCustomPipelineBuild` (`:973`) only gates *custom* keys, so the built-in completion → cache-insert path must be checked for whether it invalidates the pinned fast-path. If it doesn't, add an invalidation on insert, or the specialized pipeline is never picked up until the next param change. Independent.
- **A4. `MacSpatialUpscaler` LRU pool** (MEDIUM / low). Port the `MacTemporalUpscaler` 4-entry pool so adaptive-resolution 0.05 steps stop reallocating 3 textures + rebuilding the scaler on the render thread. *Scope caveat: only helps on temporal-unsupported fallback hardware; safe regardless.* Independent.
- **A5. `initialCapacity` bump to ~10–12** (§4.3, trivial). One literal.

### Slice B — Cross-launch caching (the launch-hitch lever)
- **B0. Signpost the compile costs** — instrument **separately** the init batch (`Renderer.swift:408–512`) and `precompilePresetPipelines` (`RendererPipelineCache.swift:336`) via the existing `BenchmarkManager`/`PerfSweepRunner`, and record the preset *count*. Gates the effort and tells you whether the preset set (uncapped, user-data-driven) or the init batch dominates.
- **B2. `MTLBinaryArchive` for built-in init-path + preset pipelines** (§2.1/§2.3, HIGH / medium). ✅ **DONE for compute AND visionOS render paths (2026-06-26/27).** `PipelineBinaryArchive` wired into the visionOS compute builder + startup batch + lazy builds (compute file), and now the visionOS **render** path too: a separate `render-` archive threaded through `buildRenderPipelineWithDevice`/`buildSpecializedPipeline`, so the init render batch (base/quad-shared/MetalFX-resolve), the quality-preset render variants, the saved-preset render pipelines (`getPipeline`), and lazy render builds all attach+capture. The compute **preset** PSOs were already covered (the `prewarmComputePipeline` path runs through `buildComputePipeline`). The linter hardened both `make*Pipeline` helpers to probe with `.failOnBinaryArchiveMiss` (a warm-launch hit skips both recompile and a needless re-serialize). **This is the actual lead of Slice B** — promoted over B1 because B1-as-written turned out not to be a real API (see B1 below). **Remaining:** the Mac `RaymarchRenderView` pipelines (separate private builder, not the shared static one).
- **B1. Persist compiled `.threshfx` library** (§2.2b, HIGH / medium) — **DEFERRED / reframed.** The original "write `.metallib`, reload via `makeLibrary(URL:)`" plan is **not buildable** (no `MTLLibrary` serialize API; see the §2.2b ⚠️ correction). The real options are (a) route the custom `CX{hash}_` *pipeline states* through the §2.1 archive — tractable, folds into B3 — or (b) the `MTLDynamicLibrary.serialize` restructure for the *source-compile* half — high-complexity, partial win. Needs B0 magnitude + a restructure decision before any code.
- **B3. Route custom `CX{hash}_` pipelines through the archive** (§2.2a). *Depends on B2's helper (now exists).* The PSO half of the custom path; the highest-value remaining custom-shader item now that B1's source-compile half is blocked.

### Slice C — De-duplication (maintainability; after A/B so refactors don't collide with caching edits)
- **C1. Relocate `FunctionConstantIndex` enum to a neutral file** (§3.4, LOW). Unblocks C2; removes Mac magic numbers.
- **C2. Share `specializedMandelbulbPower`** (§3.3, LOW). Delete two of three copies.
- **C3. Share the `CustomShaderState` holder + key-prefix helper** (§3.2, MEDIUM / medium). Holder + prefix only — keep containers and activation methods split; name the helper distinctly from `customCacheKeyPrefix(for:)`.
- **C4. Extract the `Uniforms` shared builder** (§3.1, MEDIUM / medium). Land the **safe subset first** (fog/glow/colorMix/bubble/mandelbulb force-off); treat the viewDistance divisor as a per-platform argument in a separate, carefully-reviewed step.
- **C5. Mac startup pipeline warm** (§2.5, MEDIUM / low). Independent; can move into Slice A if Mac first-frame latency is a priority.

### Slice D — Polish (opportunistic)
- D1. Buddhabrot GPU-only buffers `.shared → .private` (§4, LOW).
- D2. Screenshot lazy-alloc/free (§4.3, LOW).
- D3. Custom-formula near-match O(1) map (§2.6, LOW — fragment path, zero GPU-cost).
- D4. Thread bubble/packet into pipeline requests (§2.7, LOW correctness tidy).

### Must NOT do (overkill / unsafe)
- **No argument buffers / bindless** — bind density is tiny and static.
- **Do not merge the MetalFX managers** (§3.5) — stereo-array vs 2D is a real API-shape split; shared allocation is already extracted.
- **Do not merge the two pipeline-cache *containers* or the full custom-shader activation methods** (§3.2) — `Mutex`-vs-actor and MRU-vs-blanket eviction genuinely differ.
- **Do not blindly unify the `viewDistanceScale` divisor** (§3.1) — the Mac clamp is a deliberate zoom center-hole fix; parameterize, don't collapse.
- **Do not force MetalFX/temporal depth to `.memoryless`** (§4) — it is sampled, so `.shaderRead` is mandatory.
- **Do not use `.volatile` for Buddhabrot teardown** (§4.1) — a fenced `= nil` is safer; `.volatile` with in-flight GPU reads is undefined.
- **Do not implement the render-target heap/aliasing speculatively** (§4.2) — premises are weak and it collides with the compression win; measure first.

---

## 6. Honest caveats

**Needs on-device measurement before committing effort:**
- The §2.1/B2 `MTLBinaryArchive` launch-hitch magnitude is *asserted* but unmeasured on Vision Pro — B0 must confirm it (and the preset count) before B2/B3 effort. Zero archive usage repo-wide and an uncapped, user-data-driven preset set make the win plausible, but its *size* is unverified. (B1's metallib cost, by contrast, is documented in-repo — hence B1 leads.)
- The §A2 `tileUniformBuffer` race is a genuine coherent CPU/GPU hazard on `.shared` memory, but the *visible symptom* (subtle one-frame torn pose/param read) is plausible and empirically unconfirmed; severity is bounded to a single torn frame.
- §4.2 (heap aliasing) is the **lowest-confidence finding** (~0.4): footprint figures partly wrong (MetalFX input/depth are reduced-res), the only dimension-matching alias collides with lossless compression, net reclaim uncertain. Measure memory pressure first; likely *not worth it*.

**Refuted / corrected from the raw audit:**
- The "Mac shared types are unreachable because of an `os()` gate" diagnosis was **wrong** — `FunctionConstantIndex`/`FunctionConstantConfig` are not `os()`-gated; the barrier is `@preconcurrency import CompositorServices` + synchronized-folder membership exceptions in `project.pbxproj`. Remedy: relocate to a CompositorServices-free file.
- `colorIterations` is **already threaded** through `RenderPipelineRequest` (`:443`, verified) — only bubble/packet remain live-read (§2.7).
- "~25MB Buddhabrot" was **understated** — ~38MB mono, more in RGB.
- "`initialCapacity=8` is exceeded" was **overstated** — steady-state max is *exactly* 8; whether that triggers a grow is Apple-unspecified.
- The §4.1 risk rating of "low" was **too generous** — actor isolation guarantees thread safety but not GPU-lifetime safety; the teardown needs a completion fence.
- The §2.4 fix value was **understated** — the per-frame fast-path *pins* the generic fallback across the steady-state window, not one frame (verified at `:858–864`/`:961`).
- The §3.5 MetalFX-manager merge and the §4 argument-buffer item are **verified non-opportunities**, recorded so they aren't revisited.
- The `EmbeddedFormula.swift:123` "on-disk metallib filename" comment is **stale/aspirational** — no metallib is written today; it corroborates the §2.2 gap.

**Inherent uncertainties:**
- `MTLBinaryArchive` and persisted `.metallib` compatibility is GPU/driver/OS-version sensitive; `operatingSystemVersion` does not capture intra-OS driver revisions, so keying *reduces* rejection churn but relies on Metal's own validation + `try?` fallback for correctness. Safe (degrades to today's live compile), but post-OS-update hit-rate is not guaranteed.
- The persisted-`.metallib` keying additionally relies on the **header-ABI version** because the embedded prefix/suffix/dispatch headers are *not* in `combinedHash` (verified at `CustomShaderCompiler.swift:197/214/218` vs `EmbeddedFormula.swift:124–131`) — without it, a header-only app update could reload a signature-mismatched library.
- All de-duplication slices (C) are correctness-neutral *if* the per-platform caller-patched fields and divergent activation logic are respected — the risk is in extraction discipline, not runtime behavior.

---

## Teaching note: the principle

Three abstractions sit under every fix in this document. Each is worth carrying to the next codebase.

**(1) Caching = trading space to avoid recomputation — and a cache is only as good as its three boundary questions.** Whenever you store a result so you don't recompute it, you have signed up for three obligations, and most cache bugs are a missed answer to one of them:

- *What are the cache-key inputs?* The key must include **every** input the stored value depends on — no more, no less. §2.4 is the textbook failure: the stored shared-compute pipeline keyed on `FI_RS` only, but the lookup key grew a `powerKey` and `sceneKey`, so the key the writer used and the key the reader used could never meet — a permanent miss disguised as a working cache. §2.2b is the same shape one level up: `combinedHash` keys the *user's* shader source but omits the *embedded headers* that are equally part of the compiled artifact, so a key can collide across genuinely different outputs. The discipline: list the artifact's true inputs, then make the key a function of exactly that set.
- *When is it invalid?* A cache that never invalidates serves stale data; one that over-invalidates never pays off. The persisted `.metallib` (§2.2/§2.3) must invalidate on DE-source change *and* header-ABI change *and* GPU/OS change — three independent invalidation axes folded into the filename. The Buddhabrot fast-path (§2.4/§A3) shows the dual hazard: it *pins* a value (`lastSelectedComputePipeline`) and forgets to invalidate it when a better one (the background-built specialized pipeline) arrives — so a correct cache entry sits unused because nothing told the fast-path to drop the stale one.
- *Where does the recompute hitch land?* Every cache miss costs *something somewhere*; the design question is *when and on which thread*. The whole point of Slice B is **moving the recompute out of the cold-launch first-frame path and the on-entry render path** into a persisted archive — same total work, relocated off the hitch-visible moment. The corollary: never let the recompute land on the compositor render loop (§2.3) — a cache that hides its miss cost on the hot path has just moved the stall, not removed it.

**(2) Divergent paths = every fork doubles the surface for bugs; aim for one source of truth with thin platform leaves.** The visionOS/macOS split is real (compute vs fragment, actor vs class, CompositorServices vs MTKView) — but most of the *divergence* in this code is accidental, not essential. §3.1 (the `Uniforms` struct assembled field-by-field in two places, **already** drifted on the warm-start fields and the viewDistance divisor) and §3.3 (the mandelbulb-power gate written **three** times, where the supported-power set must stay in lockstep with a shader fast-path) are the cautionary cases: two copies of "the same" logic are not the same the moment someone edits one. The repo already shows the cure — `RenderPrecompute` is the shared-math single source of truth, and the platform renderers are thin leaves that call into it. The design rule the de-dup slices apply: extract the *essential-shared* core into one pure function, and keep in the platform leaf **only** what is genuinely platform-specific (the Halton-jitter projection, the deliberate zoom clamp, the MRU-vs-blanket eviction policy). The skill is telling essential divergence (§3.5, stereo-array vs 2D — keep it forked) from accidental divergence (§3.2, a holder whose own comment says it "mirrors" the other — unify it).

**(3) The right kind of memory = match storage mode to real access pattern and lifetime.** On tiled, unified-memory Apple GPUs, the *wrong* storage mode does not crash — it silently wastes bandwidth or footprint, which is why these bugs survive. The mode is a declaration of how a resource is actually touched:

- *Memoryless* for transient TBDR render targets that live and die inside one tile pass and are never read back — the Mac fragment depth (§4 table) is the model: it exists only on-chip, never hits DRAM. The trap is forcing it onto a resource that *is* sampled later (the MetalFX depth, §4) — `.memoryless` and `.shaderRead` are mutually exclusive by definition.
- *Private* for GPU-only data the CPU never reads — the Buddhabrot sort/splat/histogram buffers (§4 table) are mislabeled `.shared`, paying CPU-coherency bookkeeping for buffers the CPU never touches; `.private` is the honest label.
- *Shared* for buffers the CPU writes (or reads) every frame — the per-frame uniforms, and the Buddhabrot density buffer that *is* read back each frame, correctly stay `.shared`. The discipline is per-resource honesty, not a blanket default.
- *Lifetime, not just mode:* a resource sized right but **never released** is its own waste — the Buddhabrot working set (§4.1) is correctly typed yet pins ~38MB for the whole session because nothing frees it on mode-exit. And lifetime management on a GPU has a second clock the CPU's doesn't: a resource is alive until its **last command buffer retires**, which is why the §4.1 teardown needs a completion fence, not just an actor-isolated `= nil`. Heaps + `makeAliasable` (§4.2) are the advanced move — reusing one backing store across resources whose lifetimes provably don't overlap — but the same analysis also tells you when *not* to (the only viable alias there collides with the compression optimization). Right-sizing memory is choosing the mode that matches the access pattern, the lifetime that matches real use, and the GPU-retirement fence that matches the hardware's actual timeline.

The thread tying all three together: **a cache key, a shared-vs-forked boundary, and a storage mode are all the same kind of decision — an explicit declaration of a resource's true inputs, true ownership, and true lifetime.** Get the declaration honest and the bugs in this document don't form.

---

Relevant files (all absolute):
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/Renderer.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/Core/RendererPipelineCache.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/Core/CustomShaderCompiler.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/RaymarchRenderView.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/Core/RendererPipelineHelpers.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/Core/RendererCustomShader.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/RendererGameState.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/MetalFXTextureSupport.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/MacSpatialUpscaler.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/MacTemporalUpscaler.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/RendererSetupAndSession.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/RendererScreenshot.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/RendererCoreTypes.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Rendering/Formulas/Buddhabrot/BuddhabrotRenderer.swift`
- `/Users/halopend/Documents/GitHub/Polinate/TEMP/MetalRaymarch-main/Threshold/Formulas/EmbeddedFormula.swift`
