@preconcurrency import CompositorServices
import Foundation
import Metal

private let maxPendingRenderPipelineBuilds = 3
private let maxPendingComputePipelineBuilds = 3
private let initialPipelineBuildRetryDelay: TimeInterval = 0.25
private let maxPipelineBuildRetryDelay: TimeInterval = 4.0

struct PipelineBuildRetryState {
    let failures: Int
    let retryAfter: TimeInterval
}

private struct RenderPipelineKeyContext {
    let exactStem: String
    let sharedStem: String
    let suffix: String

    init(prefix: String,
         fractalTypeRawValue: Int,
         iterations: Int,
         raySteps: Int,
         qualityMode: Int,
         colorIterations: Int32,
         powerKey: String,
         sceneKey: String = "") {
        // sceneKey carries scene-stable feature bakes (e.g. "_B0" safety bubble).
        // Exact-only: shared/startup pipelines leave those FCs undefined so the
        // shader falls back to runtime uniforms, keeping fallbacks correct.
        exactStem = prefix + "FT\(fractalTypeRawValue)_FI\(iterations)_RS\(raySteps)\(sceneKey)_N"
        sharedStem = prefix + "FI\(iterations)_RS\(raySteps)_N"
        suffix = "_Q\(qualityMode)_CI\(colorIterations)\(powerKey)"
    }

    @inline(__always)
    func exactKey(neonEnabled: Bool) -> String {
        exactStem + (neonEnabled ? "1" : "0") + suffix
    }

    @inline(__always)
    func sharedKey(neonEnabled: Bool) -> String {
        sharedStem + (neonEnabled ? "1" : "0") + suffix
    }
}

private struct ComputePipelineKeyContext {
    let exactKey: String
    let sharedKey: String

    init(prefix: String,
         fractalTypeRawValue: Int,
         fractalIterations: Int,
         maxRaySteps: Int,
         powerKey: String,
         sceneKey: String = "") {
        // sceneKey carries scene-stable feature bakes (e.g. "_B0_CP0"); exact-only
        // so shared/startup pipelines keep runtime-uniform fallback behavior.
        exactKey = prefix + "FT\(fractalTypeRawValue)_FI\(fractalIterations)_RS\(maxRaySteps)\(powerKey)\(sceneKey)"
        sharedKey = prefix + "FI\(fractalIterations)_RS\(maxRaySteps)\(powerKey)"
    }
}

struct RenderPipelineRequest {
    let fractalType: FractalModelType
    let formulaParams: FormulaParams
    let colorIterations: Float
}

struct ComputePipelineRequest {
    let fractalType: FractalModelType
    let formulaParams: FormulaParams
}

extension Renderer {
    /// Effective safety-bubble state for exact-pipeline specialization. Mirrors
    /// the uniform derivation in Renderer (mandelbulb force-disables the bubble),
    /// so the baked FC always matches what the uniform would have said.
    @inline(__always)
    fileprivate func effectiveSafetyBubbleEnabled(for fractalType: FractalModelType) -> Bool {
        fractalType != .mandelbulb && appModel.renderSettings.safetyBubbleEnabled
    }

    /// Selects a fragment pipeline that bakes FC_COARSE_WARM_START=true (the
    /// conservative cone coarse-prepass consumer). Mirrors selectPipeline's exact
    /// specialization for the current config, but lives in its OWN cache so the
    /// main pipeline cache stays byte-identical (always FC_COARSE_WARM_START off).
    /// Built synchronously on a cache miss — this is an opt-in feature, so the
    /// one-time compile per config only happens while the user has the toggle on.
    /// Returns nil on build failure; the caller then keeps the base (FC-off)
    /// pipeline and the cone texture is simply never sampled.
    func selectCoarseWarmStartPipeline(forIterations iterations: Int, raySteps: Int,
                                       neonMode: Bool = false,
                                       request: RenderPipelineRequest? = nil) -> MTLRenderPipelineState? {
        let fractalType = request?.fractalType ?? appModel.renderSettings.fractalType
        // Custom formulas need a separately-compiled library + the FractalTypeCustom
        // dispatch arm; the cone family gate excludes them anyway. Keep it simple.
        guard fractalType != .custom else { return nil }
        let formulaParams = request?.formulaParams ?? appModel.renderSettings.formulaParams
        let mandelbulbPower = FormulaCatalog.specializedMandelbulbPower(
            fractalType: fractalType,
            formulaParams: formulaParams
        )
        let colorIterations = Int32(request?.colorIterations ?? appModel.renderSettings.colorIterations)
        let bubbleEnabled = effectiveSafetyBubbleEnabled(for: fractalType)
        let qualityMode: Int = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let powerKey = mandelbulbPower.map { "_P\($0)" } ?? ""

        let cacheKey = "CWS_FT\(fractalType.rawValue)_FI\(iterations)_RS\(raySteps)_Q\(qualityMode)_CI\(colorIterations)\(powerKey)_N\(neonMode ? 1 : 0)_B\(bubbleEnabled ? 1 : 0)"
        if let cached = coarseWarmStartPipelineCache[cacheKey] {
            return cached
        }

        let config = FunctionConstantConfig(
            fractalIterations: Int32(iterations),
            shadowIterations: Int32(max(iterations - 2, 2)),
            safetyBubbleEnabled: bubbleEnabled,
            qualityMode: Int32(qualityMode),
            debugHierarchical: false,
            maxRaySteps: Int32(raySteps),
            fractalType: fractalType.rawValue,
            neonModeEnabled: neonMode,
            colorIterations: colorIterations,
            mandelbulbPower: mandelbulbPower
        )
        do {
            let pipeline = try Renderer.buildSpecializedPipeline(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                config: config,
                fragmentFunctionName: "fragmentShader",
                coarseWarmStart: true,
                library: nil,
                archive: renderPipelineArchive
            )
            coarseWarmStartPipelineCache[cacheKey] = pipeline
            return pipeline
        } catch {
            if RENDERER_DEBUG { print("⚠️ [ConeWarmStart] pipeline build failed: \(error)") }
            return nil
        }
    }

    /// Scene-stable feature bakes for exact compute-pipeline keys
    /// (safety bubble + coherent-packet experiment), read from live settings.
    @inline(__always)
    fileprivate func computeSceneKey(for fractalType: FractalModelType) -> String {
        let bubble = effectiveSafetyBubbleEnabled(for: fractalType)
        let packet = appModel.renderSettings.coherentPacketEnabled
        return "_B\(bubble ? 1 : 0)_CP\(packet ? 1 : 0)"
    }

    @inline(__always)
    fileprivate func recordPipelineTelemetry(renderHit: Bool? = nil,
                                             computeHit: Bool? = nil,
                                             renderMissKey: String? = nil,
                                             computeMissKey: String? = nil,
                                             renderSource: String? = nil,
                                             computeSource: String? = nil) {
        guard RENDERER_DEBUG else { return }

        if let renderHit {
            if renderHit { renderPipelineCacheHits += 1 } else { renderPipelineCacheMisses += 1 }
        }
        if let computeHit {
            if computeHit { computePipelineCacheHits += 1 } else { computePipelineCacheMisses += 1 }
        }
        if let renderMissKey {
            renderPipelineMissKeyCounts[renderMissKey, default: 0] += 1
        }
        if let computeMissKey {
            computePipelineMissKeyCounts[computeMissKey, default: 0] += 1
        }
        if let renderSource {
            renderPipelineSelectionCounts[renderSource, default: 0] += 1
        }
        if let computeSource {
            computePipelineSelectionCounts[computeSource, default: 0] += 1
        }

        let now = CFAbsoluteTimeGetCurrent()

        if now - lastPipelineTelemetryLogTime >= 5.0 {
            lastPipelineTelemetryLogTime = now

            let renderTotal = renderPipelineCacheHits + renderPipelineCacheMisses
            let computeTotal = computePipelineCacheHits + computePipelineCacheMisses
            let renderHitRate = renderTotal > 0 ? (Double(renderPipelineCacheHits) / Double(renderTotal)) * 100.0 : 0.0
            let computeHitRate = computeTotal > 0 ? (Double(computePipelineCacheHits) / Double(computeTotal)) * 100.0 : 0.0
            let topRenderSources = renderPipelineSelectionCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ", ")
            let topComputeSources = computePipelineSelectionCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ", ")

            print("📊 [PipelineTelemetry] render hitRate=\(String(format: "%.1f", renderHitRate))% (H:\(renderPipelineCacheHits) M:\(renderPipelineCacheMisses)) sources=[\(topRenderSources.isEmpty ? "none" : topRenderSources)] | compute hitRate=\(String(format: "%.1f", computeHitRate))% (H:\(computePipelineCacheHits) M:\(computePipelineCacheMisses)) sources=[\(topComputeSources.isEmpty ? "none" : topComputeSources)]")
        }

        if now - lastPipelineMissHistogramLogTime >= 10.0 {
            lastPipelineMissHistogramLogTime = now

            let topRenderMisses = renderPipelineMissKeyCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ", ")
            let topComputeMisses = computePipelineMissKeyCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ", ")

            if !topRenderMisses.isEmpty || !topComputeMisses.isEmpty {
                print("🧪 [PipelineMissTop] render=[\(topRenderMisses.isEmpty ? "none" : topRenderMisses)] | compute=[\(topComputeMisses.isEmpty ? "none" : topComputeMisses)]")
            }
        }
    }

    @inline(__always)
    fileprivate func cacheSelectedRenderPipeline(
        _ pipeline: MTLRenderPipelineState,
        iterations: Int,
        raySteps: Int,
        neonMode: Bool,
        colorIterations: Int32,
        fractalTypeRawValue: Int32,
        mandelbulbPower: Int32?,
        activeCustomHash: String?,
        bubbleEnabled: Bool,
        isSpecialized: Bool
    ) -> MTLRenderPipelineState {
        lastSelectBubble = bubbleEnabled
        lastSelectIter = iterations
        lastSelectRS = raySteps
        lastSelectNeon = neonMode
        lastSelectColorIterations = colorIterations
        lastSelectFT = fractalTypeRawValue
        lastSelectPower = mandelbulbPower
        lastSelectCustomHash = activeCustomHash
        lastSelectedPipeline = pipeline
        lastSelectedIsSpecialized = isSpecialized
        appModel.isUsingSpecializedPipeline = isSpecialized
        return pipeline
    }

    @inline(__always)
    fileprivate func cacheSelectedComputePipeline(
        _ pipeline: MTLComputePipelineState?,
        fractalTypeRawValue: Int32,
        fractalIterations: Int,
        maxRaySteps: Int,
        mandelbulbPower: Int32?,
        activeCustomHash: String?,
        bubbleEnabled: Bool,
        packetEnabled: Bool
    ) -> MTLComputePipelineState? {
        lastComputeBubble = bubbleEnabled
        lastComputePacket = packetEnabled
        lastComputeFT = fractalTypeRawValue
        lastComputeFI = fractalIterations
        lastComputeRS = maxRaySteps
        lastComputePower = mandelbulbPower
        lastComputeCustomHash = activeCustomHash
        lastSelectedComputePipeline = pipeline
        return pipeline
    }

    // MARK: - Unified Pipeline Management

    /// Gets or builds a specialized pipeline for a given preset.
    /// Uses the unified pipelineCache to avoid redundant compilation.
    func getPipeline(forPreset preset: FractalPreset) -> MTLRenderPipelineState {
        let prefix = customCacheKeyPrefix()
        let cacheKey = prefix + preset.pipelineCacheKey
        let library = renderingLibrary()

        if preset.fractalType == .custom {
            customSceneDiagnostic("🔬 [CSDiag] getPipeline(forPreset) FT=custom name='\(preset.name)' libraryPresent=\(library != nil) hash=\(customShaderHash ?? "nil") key=\(cacheKey) cacheHit=\(pipelineCache[cacheKey] != nil)")
        }

        if preset.fractalType == .custom, library == nil {
            customSceneDiagnostic("🔬 [CSDiag] ⚠️ getPipeline(forPreset) returning DEFAULT pipelineState — custom library missing — key=\(cacheKey)")
            return pipelineState
        }

        // Check unified cache first
        if let cached = pipelineCache[cacheKey] {
            return cached
        }

        // Build new specialized pipeline
        let config = FunctionConstantConfig.fromPreset(preset)
        if RENDERER_DEBUG { print("🔧 [ShaderCompilation] Building NEW pipeline for: \(preset.name) [\(cacheKey)]") }

        do {
            let pipeline = try Renderer.buildSpecializedPipeline(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                config: config,
                fragmentFunctionName: "fragmentShader",
                library: library,
                archive: renderPipelineArchive
            )
            pipelineCache[cacheKey] = pipeline  // Store in unified cache
            if RENDERER_DEBUG { print("✅ [ShaderCompilation] SUCCESS: Built pipeline [\(cacheKey)]") }
            return pipeline
        } catch {
            if RENDERER_DEBUG { print("❌ [ShaderCompilation] FAILED to build preset pipeline [\(cacheKey)]: \(error)") }
            return pipelineState
        }
    }

    /// Gets or builds a specialized pipeline for specific iteration/ray step values.
    /// Call this when slider values change to pre-compile the needed pipeline.
    func getPipeline(forIterations iterations: Int, raySteps: Int) -> MTLRenderPipelineState {
        // Build cache key matching the preset format
        let colorIterations = Int32(appModel.renderSettings.colorIterations)  // Direct read (own lock) — avoids full snapshot
        let fractalType = appModel.renderSettings.fractalType
        let library = renderingLibrary()

        if fractalType == .custom, library == nil {
            return pipelineState
        }

        let mandelbulbPower = FormulaCatalog.specializedMandelbulbPower(
            fractalType: fractalType,
            formulaParams: appModel.renderSettings.formulaParams
        )
        let neon = (appModel.renderSettings.gradientPreset?.isNeonMode ?? false) ? 1 : 0
        let qualityMode: Int32 = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let powerKey = mandelbulbPower.map { "_P\($0)" } ?? ""
        let bubbleEnabled = effectiveSafetyBubbleEnabled(for: fractalType)
        let keyContext = RenderPipelineKeyContext(
            prefix: customCacheKeyPrefix(),
            fractalTypeRawValue: Int(fractalType.rawValue),
            iterations: iterations,
            raySteps: raySteps,
            qualityMode: Int(qualityMode),
            colorIterations: colorIterations,
            powerKey: powerKey,
            sceneKey: "_B\(bubbleEnabled ? 1 : 0)"
        )
        let cacheKey = keyContext.exactKey(neonEnabled: neon == 1)

        // Check unified cache first
        if let cached = pipelineCache[cacheKey] {
            return cached
        }

        // Build new specialized pipeline
        let config = FunctionConstantConfig(
            fractalIterations: Int32(iterations),
            shadowIterations: Int32(max(iterations - 2, 2)),
            safetyBubbleEnabled: bubbleEnabled,  // Baked; toggle changes the cache key and rebuilds async
            qualityMode: qualityMode,
            debugHierarchical: false,
            maxRaySteps: Int32(raySteps),
            fractalType: fractalType.rawValue,
            neonModeEnabled: neon == 1,
            colorIterations: colorIterations,
            mandelbulbPower: mandelbulbPower
        )

        if RENDERER_DEBUG { print("🔧 [ShaderCompilation] Building pipeline for FT=\(fractalType.rawValue) FI=\(iterations) RS=\(raySteps)...") }

        do {
            let pipeline = try Renderer.buildSpecializedPipeline(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                config: config,
                fragmentFunctionName: "fragmentShader",
                library: library,
                archive: renderPipelineArchive
            )
            pipelineCache[cacheKey] = pipeline
            if RENDERER_DEBUG { print("✅ [ShaderCompilation] Ready: FT=\(fractalType.rawValue) FI=\(iterations) RS=\(raySteps)") }
            return pipeline
        } catch {
            if RENDERER_DEBUG { print("❌ [ShaderCompilation] FAILED for FT=\(fractalType.rawValue) FI=\(iterations) RS=\(raySteps): \(error)") }
            return pipelineState
        }
    }

    /// Precompiles pipelines for all saved presets on app launch.
    /// Runs asynchronously to avoid blocking the main thread.
    func precompilePresetPipelines() async {
        // Access presets from AppModel on main actor
        let presets = await MainActor.run {
            appModel.presetManager.presets
        }

        guard !presets.isEmpty else {
            if RENDERER_DEBUG { print("🔧 [ShaderCompilation] No saved presets to precompile") }
            return
        }

        // Build pipelines for unique configurations only
        var compiledKeys = Set<String>()
        var prewarmedComputeKeys = Set<String>()
        var compiledCount = 0
        var computePrewarmCount = 0

        if RENDERER_DEBUG { print("🔧 [ShaderCompilation] Starting preset pipeline precompilation for \(presets.count) presets...") }

        for preset in presets {
            if preset.fractalType == .custom {
                if RENDERER_DEBUG {
                    print("  ⏭️  Skipping \(preset.name) - custom presets require an activated embedded formula")
                }
                continue
            }
            let key = preset.pipelineCacheKey
            guard !compiledKeys.contains(key) else {
                if RENDERER_DEBUG { print("  ⏭️  Skipping \(preset.name) - duplicate config [\(key)]") }
                continue  // Skip duplicate configurations
            }
            compiledKeys.insert(key)

            if RENDERER_DEBUG {
                let fc = preset.deriveFunctionConstants()
                print("  🔨 Compiling: \(preset.name)")
                print("      Key: \(key)")
                print("      FractalIters=\(fc.fractalIterations), RaySteps=\(fc.maxRaySteps), Shadow=\(fc.shadowIterations)")
                print("      Neon=\(fc.neonModeEnabled), Quality=\(fc.qualityMode)")
            }

            _ = getPipeline(forPreset: preset)

            let functionConstants = preset.deriveFunctionConstants()
            let powerKey = functionConstants.mandelbulbPower.map { "P\($0)" } ?? ""
            let computeKey = ComputePipelineKeyContext(
                prefix: customCacheKeyPrefix(),
                fractalTypeRawValue: Int(preset.fractalType.rawValue),
                fractalIterations: Int(functionConstants.fractalIterations),
                maxRaySteps: Int(functionConstants.maxRaySteps),
                powerKey: powerKey,
                sceneKey: computeSceneKey(for: preset.fractalType)
            ).exactKey
            if prewarmedComputeKeys.insert(computeKey).inserted {
                await prewarmComputePipelineDuringStartup(forPreset: preset)
                computePrewarmCount += 1
            }

            compiledCount += 1
        }

        if RENDERER_DEBUG {
            print("✅ [ShaderCompilation] Precompiled \(compiledCount) unique preset pipelines (from \(presets.count) presets)")
            print("   Prewarmed \(computePrewarmCount) unique compute pipelines")
            print("   Unified cache now contains \(pipelineCache.count) pipelines")
        }
    }

    private func prewarmComputePipelineDuringStartup(forPreset preset: FractalPreset) async {
        while pendingComputePipelineBuildKeys.count >= maxPendingComputePipelineBuilds {
            guard !Task.isCancelled else { return }
            await Task.yield()
        }
        prewarmComputePipeline(forPreset: preset)
    }

    /// Select the best specialized pipeline for the current render settings.
    /// Uses the unified pipelineCache for all lookups - no separate cache tiers.
    ///
    /// OPTIMIZATION: Fast-path returns cached result when parameters haven't changed,
    /// avoiding String interpolation + Dictionary lookup on every frame.
    ///
    /// Pipeline lookup order:
    /// 1. Fast-path: same params as last frame → return cached result
    /// 2. FT-specific exact match in unified cache
    /// 3. FT-specific neon-off fallback
    /// 4. Shared quality key fallback (startup-prebuilt, no FC_FRACTAL_TYPE)
    /// 5. Generic pipeline fallback
    func selectPipeline(forIterations iterations: Int, raySteps: Int,
                        neonMode: Bool = false,
                        request: RenderPipelineRequest? = nil) -> MTLRenderPipelineState {
        let fractalType = request?.fractalType ?? appModel.renderSettings.fractalType
        let formulaParams = request?.formulaParams ?? appModel.renderSettings.formulaParams
        let activeCustomHash = fractalType == .custom ? customShaderHash : nil
        let mandelbulbPower = FormulaCatalog.specializedMandelbulbPower(
            fractalType: fractalType,
            formulaParams: formulaParams
        )
        if RENDERER_DEBUG,
           fractalType == .mandelbulb,
           mandelbulbPower != lastSelectPower {
            let previousPower = lastSelectPower.map { String($0) } ?? "runtime"
            let nextPower = mandelbulbPower.map { String($0) } ?? "runtime"
            print("🔀 [Pipeline] Mandelbulb power changed: \(previousPower) → \(nextPower)")
        }
                let colorIterations = Int32(request?.colorIterations ?? appModel.renderSettings.colorIterations)
        let bubbleEnabled = effectiveSafetyBubbleEnabled(for: fractalType)
        // Live, authoritative per-frame derivation of whether the space-warp seam is
        // needed. Conservative: an active custom library (custom fractal OR a
        // `.threshfx` warp) keeps it ON. Only a pure built-in with an empty stack
        // bakes it OFF (FC_HAS_SPACEWARP=false → the whole warp path DCEs). Because
        // this reads the LIVE stack, adding the first transform flips it to true the
        // same frame — so a `_SW0` pipeline can never be served for a warped scene.
        let hasSpaceWarp = !appModel.renderSettings.spaceWarpStack.isEmpty || activeCustomHash != nil

        // Fast-path: parameters unchanged since last call — skip string alloc + dict lookup
        if iterations == lastSelectIter && raySteps == lastSelectRS &&
           neonMode == lastSelectNeon &&
              colorIterations == lastSelectColorIterations &&
           fractalType.rawValue == lastSelectFT &&
           activeCustomHash == lastSelectCustomHash &&
           bubbleEnabled == lastSelectBubble &&
           hasSpaceWarp == lastSelectSpaceWarp &&
           mandelbulbPower == lastSelectPower, let cached = lastSelectedPipeline {
            recordPipelineTelemetry(renderHit: true, renderSource: "fast-path")
            if fractalType == .custom, !lastSelectedIsSpecialized {
                customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectPipeline FAST-PATH on .custom returning NON-SPECIALIZED pipeline — hash=\(activeCustomHash ?? "nil")")
            }
            appModel.isUsingSpecializedPipeline = lastSelectedIsSpecialized
            return cached
        }

        // Past the fast-path: record this frame's space-warp presence for next frame's
        // guard. Set here (not in cacheSelectedRenderPipeline) so every non-fast-path
        // return reflects the current frame; a fast-path HIT above already had it equal.
        lastSelectSpaceWarp = hasSpaceWarp

        // Build unified cache key (only on parameter change). The `_SW` segment must
        // stay in lockstep with `FractalPreset.pipelineCacheKey`'s scene segment so a
        // prewarmed/preset pipeline is found once its scene is applied.
        let qualityMode: Int = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let powerKey = mandelbulbPower.map { "_P\($0)" } ?? ""
        let keyContext = RenderPipelineKeyContext(
            prefix: customCacheKeyPrefix(),
            fractalTypeRawValue: Int(fractalType.rawValue),
            iterations: iterations,
            raySteps: raySteps,
            qualityMode: qualityMode,
            colorIterations: colorIterations,
            powerKey: powerKey,
            sceneKey: "_B\(bubbleEnabled ? 1 : 0)_SW\(hasSpaceWarp ? 1 : 0)"
        )
        let cacheKey = keyContext.exactKey(neonEnabled: neonMode)
        if RENDERER_DEBUG,
           fractalType == .mandelbulb,
           mandelbulbPower != lastSelectPower {
            print("🔀 [Pipeline] Mandelbulb requested key: \(cacheKey)")
        }

        let result: MTLRenderPipelineState
        var isSpecialized = true

        // 1. Check unified cache (includes both quality presets and saved presets)
        if let pipeline = pipelineCache[cacheKey] {
            recordPipelineTelemetry(renderHit: true, renderSource: "exact")
            if RENDERER_DEBUG && lastLoggedPipelineKey != cacheKey {
                print("🎯 [Pipeline] Using cached pipeline: \(cacheKey)")
                lastLoggedPipelineKey = cacheKey
            }
            if fractalType == .custom, lastLoggedPipelineKey != cacheKey + "_csdiag" {
                customSceneDiagnostic("🔬 [CSDiag] ✅ selectPipeline FT=custom CACHE HIT — key=\(cacheKey)")
                lastLoggedPipelineKey = cacheKey + "_csdiag"
            }
            result = pipeline
        }
        // 2. Cache miss: kick off a background build for the exact config and
        //    serve this frame from the best available fallback below. Prior
        //    revisions compiled the specialized pipeline **synchronously** here,
        //    which could stall the render actor for 50–500 ms the first time a
        //    new preset / fractal type / slider value was seen. Metal pipeline
        //    compilation is thread-safe; we build off-actor and hop back to the
        //    Renderer actor to insert into `pipelineCache` so next frame hits.
        else {
            recordPipelineTelemetry(renderHit: false, renderMissKey: cacheKey)

            let exactConfig = FunctionConstantConfig(
                fractalIterations: Int32(iterations),
                shadowIterations: Int32(max(iterations - 2, 2)),
                safetyBubbleEnabled: bubbleEnabled,
                hasSpaceWarp: hasSpaceWarp,   // pair the baked FC with cacheKey's _SW segment
                qualityMode: Int32(qualityMode),
                debugHierarchical: false,
                maxRaySteps: Int32(raySteps),
                fractalType: fractalType.rawValue,
                neonModeEnabled: neonMode,
                colorIterations: colorIterations,
                mandelbulbPower: mandelbulbPower
            )

            if fractalType == .custom {
                customSceneDiagnostic("🔬 [CSDiag] selectPipeline FT=custom CACHE MISS — hash=\(activeCustomHash ?? "nil") libraryPresent=\(renderingLibrary() != nil) key=\(cacheKey)")
                guard let library = renderingLibrary() else {
                    recordPipelineTelemetry(renderSource: "custom-missing-library")
                    print("⚠️ [CustomScene] Missing active custom shader library for render pipeline build")
                    customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectPipeline FT=custom → returning DEFAULT pipelineState (library == nil) — this WILL render as fog/sky only because FractalDE_Dispatch lacks FractalTypeCustom arm in default library")
                    // Self-heal: re-activate the registered formula so this
                    // sky-only state lasts frames, not forever (any ordering
                    // race between preset apply and activation lands here).
                    scheduleCustomLibrarySelfHeal()
                    isSpecialized = false
                    result = pipelineState
                    return cacheSelectedRenderPipeline(
                        result,
                        iterations: iterations,
                        raySteps: raySteps,
                        neonMode: neonMode,
                        colorIterations: colorIterations,
                        fractalTypeRawValue: fractalType.rawValue,
                        mandelbulbPower: mandelbulbPower,
                        activeCustomHash: activeCustomHash,
                        bubbleEnabled: bubbleEnabled,
                        isSpecialized: false
                    )
                }
                // A pipeline already cached for THIS formula (same hash, possibly
                // different FI/RS) is a near-perfect visual match — same fractal,
                // just a slightly different iteration/step count. When one exists,
                // build the exact specialization OFF the render thread and serve the
                // near-match this frame: no 50–500 ms render-thread stall, and —
                // unlike the default-library fallback chain below, which renders
                // sky-only for custom because it lacks the FractalTypeCustom arm —
                // the fractal stays correct on screen. `insertBuiltRenderPipeline`
                // clears the fast-path when the async build lands, so the exact
                // pipeline is picked up within a frame of completion.
                //
                // Hashes are fixed-length, so the "CX<hash>_" prefix can't
                // cross-match a different formula.
                let nearMatchCustomPipeline: MTLRenderPipelineState? = customShaderHash.flatMap { hash in
                    let prefix = "CX\(hash)_"
                    guard let key = pipelineCache.keys.first(where: {
                        $0.hasPrefix(prefix)
                    }) else {
                        return nil
                    }
                    return pipelineCache[key]
                }

                if let nearMatch = nearMatchCustomPipeline {
                    enqueueBackgroundPipelineBuild(
                        cacheKey: cacheKey,
                        config: exactConfig
                    )
                    recordPipelineTelemetry(renderSource: "custom-async-near-match")
                    lastLoggedPipelineKey = cacheKey
                    customSceneDiagnostic("🔬 [CSDiag] selectPipeline FT=custom ASYNC enqueued, serving same-formula near-match — key=\(cacheKey)")
                    return cacheSelectedRenderPipeline(
                        nearMatch,
                        iterations: iterations,
                        raySteps: raySteps,
                        neonMode: neonMode,
                        colorIterations: colorIterations,
                        fractalTypeRawValue: fractalType.rawValue,
                        mandelbulbPower: mandelbulbPower,
                        activeCustomHash: activeCustomHash,
                        bubbleEnabled: bubbleEnabled,
                        isSpecialized: true
                    )
                }

                // No pipeline cached for this formula yet — build the FIRST one
                // synchronously so the first frame after activation is correct (a
                // one-time cost per formula switch, not per slider tick).
                do {
                    let pipeline = try Renderer.buildSpecializedPipeline(
                        device: device,
                        layerRenderer: layerRenderer,
                        rasterSampleCount: rasterSampleCount,
                        mtlVertexDescriptor: mtlVertexDescriptor,
                        config: exactConfig,
                        fragmentFunctionName: "fragmentShader",
                        library: library,
                        archive: renderPipelineArchive
                    )
                    pipelineCache[cacheKey] = pipeline
                    lastLoggedPipelineKey = cacheKey
                    result = pipeline
                    recordPipelineTelemetry(renderSource: "custom-exact-build-sync-first")
                    customSceneDiagnostic("🔬 [CSDiag] ✅ selectPipeline FT=custom built specialized pipeline (sync, first build) — key=\(cacheKey)")
                    return cacheSelectedRenderPipeline(
                        result,
                        iterations: iterations,
                        raySteps: raySteps,
                        neonMode: neonMode,
                        colorIterations: colorIterations,
                        fractalTypeRawValue: fractalType.rawValue,
                        mandelbulbPower: mandelbulbPower,
                        activeCustomHash: activeCustomHash,
                        bubbleEnabled: bubbleEnabled,
                        isSpecialized: true
                    )
                } catch {
                    print("❌ [CustomScene] Exact render pipeline build failed: \(error)")
                    customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectPipeline FT=custom build FAILED → falling through to default-library fallback chain (will render fog/sky only) — error=\(error)")
                }
            } else {
                enqueueBackgroundPipelineBuild(
                    cacheKey: cacheKey,
                    config: exactConfig
                )
            }

            // 3. Try FT-specific neon=off quality-preset fallback.
            let fallbackKey = keyContext.exactKey(neonEnabled: false)
            if let pipeline = pipelineCache[fallbackKey] {
                recordPipelineTelemetry(renderSource: "exact-neon-off")
                if RENDERER_DEBUG && lastLoggedPipelineKey != fallbackKey {
                    print("🎯 [Pipeline] Using quality-preset fallback: \(fallbackKey) (requested: \(cacheKey))")
                    lastLoggedPipelineKey = fallbackKey
                }
                if fractalType == .custom {
                    customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectPipeline FT=custom served via exact-neon-off fallback — key=\(fallbackKey) (DEFAULT-library pipeline, no FractalTypeCustom dispatch)")
                }
                result = pipeline
            }
            else {
                // 4. Try shared quality key (built at startup without FC_FRACTAL_TYPE)
                let sharedExactKey = keyContext.sharedKey(neonEnabled: neonMode)
                if let pipeline = pipelineCache[sharedExactKey] {
                    recordPipelineTelemetry(renderSource: "shared-exact")
                    if RENDERER_DEBUG && lastLoggedPipelineKey != sharedExactKey {
                        print("🎯 [Pipeline] Using shared quality pipeline: \(sharedExactKey) for FT=\(fractalType.rawValue)")
                        lastLoggedPipelineKey = sharedExactKey
                    }
                    if fractalType == .custom {
                        customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectPipeline FT=custom served via shared-exact fallback — key=\(sharedExactKey) (DEFAULT-library)")
                    }
                    result = pipeline
                }
                // 5. Try shared neon=off quality key
                else {
                    let sharedFallbackKey = keyContext.sharedKey(neonEnabled: false)
                    if sharedFallbackKey != sharedExactKey, let pipeline = pipelineCache[sharedFallbackKey] {
                        recordPipelineTelemetry(renderSource: "shared-neon-off")
                        if RENDERER_DEBUG && lastLoggedPipelineKey != sharedFallbackKey {
                            print("🎯 [Pipeline] Using shared neon-off quality pipeline: \(sharedFallbackKey) for FT=\(fractalType.rawValue)")
                            lastLoggedPipelineKey = sharedFallbackKey
                        }
                        if fractalType == .custom {
                            customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectPipeline FT=custom served via shared-neon-off fallback — key=\(sharedFallbackKey) (DEFAULT-library)")
                        }
                        result = pipeline
                    }
                    // 6. Ultimate fallback to generic pipeline
                    else {
                        recordPipelineTelemetry(renderSource: "generic-fallback")
                        if RENDERER_DEBUG && lastLoggedPipelineKey != "fallback" {
                            print("⚠️ [Pipeline] Using FALLBACK generic pipeline (no cache hit for FT=\(fractalType.rawValue) FI=\(iterations) RS=\(raySteps))")
                            lastLoggedPipelineKey = "fallback"
                        }
                        if fractalType == .custom {
                            customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectPipeline FT=custom served via generic-fallback — DEFAULT pipelineState (fog/sky only)")
                        }
                        isSpecialized = false
                        result = pipelineState
                    }
                }
            }
        }

        // Cache for next frame's fast-path
        return cacheSelectedRenderPipeline(
            result,
            iterations: iterations,
            raySteps: raySteps,
            neonMode: neonMode,
            colorIterations: colorIterations,
            fractalTypeRawValue: fractalType.rawValue,
            mandelbulbPower: mandelbulbPower,
            activeCustomHash: activeCustomHash,
            bubbleEnabled: bubbleEnabled,
            isSpecialized: isSpecialized
        )
    }

    // MARK: - Compute Pipeline Cache

    /// Prewarms the exact adaptive-compute pipeline for a preset without using
    /// the bundled generic fallback as the selected frame-time pipeline.
    func prewarmComputePipeline(forPreset preset: FractalPreset) {
        let library = renderingLibrary()

        if preset.fractalType == .custom, library == nil {
            return
        }

        let functionConstants = preset.deriveFunctionConstants()
        let powerKey = functionConstants.mandelbulbPower.map { "P\($0)" } ?? ""
        let bubbleEnabled = effectiveSafetyBubbleEnabled(for: preset.fractalType)
        let packetEnabled = appModel.renderSettings.coherentPacketEnabled
        let keyContext = ComputePipelineKeyContext(
            prefix: customCacheKeyPrefix(),
            fractalTypeRawValue: Int(preset.fractalType.rawValue),
            fractalIterations: Int(functionConstants.fractalIterations),
            maxRaySteps: Int(functionConstants.maxRaySteps),
            powerKey: powerKey,
            sceneKey: computeSceneKey(for: preset.fractalType)
        )
        let exactKey = keyContext.exactKey

        if computePipelineCache[exactKey] != nil { return }

        enqueueBackgroundComputePipelineBuild(
            cacheKey: exactKey,
            fractalType: Int32(preset.fractalType.rawValue),
            fractalIterations: functionConstants.fractalIterations,
            shadowIterations: functionConstants.shadowIterations,
            maxRaySteps: functionConstants.maxRaySteps,
            mandelbulbPower: functionConstants.mandelbulbPower,
            safetyBubbleEnabled: bubbleEnabled,
            coherentPacketEnabled: packetEnabled
        )
    }

    /// Builds a specialized compute pipeline with function constants baked in.
    /// The Metal compiler fully unrolls Map()/Shadow loops for the given iteration counts.
    ///
    /// - Parameters:
    ///   - library: The default Metal library
    ///   - kernelName: Compute kernel function name
    ///   - fractalType: Optional FC_FRACTAL_TYPE value to bake in (devirtualizes fractal dispatch)
    ///   - fractalIterations: FC_FRACTAL_ITERATIONS value to bake in
    ///   - shadowIterations: FC_SHADOW_ITERATIONS value to bake in
    ///   - maxRaySteps: FC_MAX_RAY_STEPS value to bake in
    /// - Returns: Specialized compute pipeline, or nil on failure
    static func buildComputePipeline(device: MTLDevice, library: MTLLibrary, kernelName: String,
                                     fractalType: Int32? = nil,
                                     fractalIterations: Int32, shadowIterations: Int32, maxRaySteps: Int32,
                                     mandelbulbPower: Int32? = nil,
                                     safetyBubbleEnabled: Bool? = nil,
                                     coherentPacketEnabled: Bool? = nil,
                                     archive: PipelineBinaryArchive? = nil) -> MTLComputePipelineState? {
        let constants = MTLFunctionConstantValues()
        var fi = fractalIterations
        var si = shadowIterations
        var rs = maxRaySteps
        var debug: Bool = false
        var neon: Bool = false

        if var type = fractalType {
            constants.setConstantValue(&type, type: .int, index: FunctionConstantIndex.fractalType.rawValue)
        }
        if var power = mandelbulbPower {
            constants.setConstantValue(&power, type: .int, index: FunctionConstantIndex.mandelbulbPower.rawValue)
        }
        if var bubble = safetyBubbleEnabled {
            constants.setConstantValue(&bubble, type: .bool, index: FunctionConstantIndex.safetyBubbleEnabled.rawValue)
        }
        if var packet = coherentPacketEnabled {
            constants.setConstantValue(&packet, type: .bool, index: FunctionConstantIndex.coherentPacketEnabled.rawValue)
        }
        constants.setConstantValue(&fi, type: .int, index: FunctionConstantIndex.fractalIterations.rawValue)
        constants.setConstantValue(&si, type: .int, index: FunctionConstantIndex.shadowIterations.rawValue)
        constants.setConstantValue(&rs, type: .int, index: FunctionConstantIndex.maxRaySteps.rawValue)
        constants.setConstantValue(&debug, type: .bool, index: FunctionConstantIndex.debugHierarchical.rawValue)
        constants.setConstantValue(&neon, type: .bool, index: FunctionConstantIndex.neonModeEnabled.rawValue)

        guard let function = try? library.makeFunction(name: kernelName, constantValues: constants) else {
            if RENDERER_DEBUG { print("⚠️ [ComputeCache] Failed to specialize \(kernelName) with FI=\(fi) RS=\(rs)") }
            return nil
        }

        // Descriptor form (not makeComputePipelineState(function:)) so a persisted
        // MTLBinaryArchive can supply this PSO's binary on a hit, and capture it on
        // a miss. Lookup + build + capture run together under the archive lock (see
        // PipelineBinaryArchive.makeComputePipeline) so the in-Metal archive read
        // can't race a concurrent capture. Archive absent/miss → Metal compiles
        // exactly as before.
        let pipelineDescriptor = MTLComputePipelineDescriptor()
        pipelineDescriptor.computeFunction = function
        pipelineDescriptor.label = "Compute_\(kernelName)_FI\(fi)_RS\(rs)"
        do {
            if let archive {
                return try archive.makeComputePipeline(device: device, descriptor: pipelineDescriptor)
            }
            return try device.makeComputePipelineState(descriptor: pipelineDescriptor,
                                                       options: [],
                                                       reflection: nil)
        } catch {
            if RENDERER_DEBUG { print("⚠️ [ComputeCache] Failed to build compute pipeline: \(error)") }
            return nil
        }
    }

    /// Selects the best compute pipeline for the given iteration/ray-step settings.
    ///
    /// OPTIMIZATION: Fast-path returns cached result when FI/RS haven't changed,
    /// avoiding String interpolation + Dictionary lookup on every frame.
    ///
    /// CRITICAL: The selected pipeline's baked FC_FRACTAL_ITERATIONS MUST match the
    /// iteration count used to precompute absScalePow on CPU. If there's a mismatch,
    /// the distance estimator produces wrong values (p.w accumulates over FC iterations
    /// but absScalePow was computed for settings.iterations), causing visual artifacts.
    ///
    /// Lookup order:
    /// 1. Fast-path: same params as last frame → return cached result
    /// 2. Exact match in computePipelineCache (FT-specific)
    /// 3. Shared quality key match (startup-prebuilt, no FC_FRACTAL_TYPE)
    /// 4. Builds on-demand for exact configuration (cached for future frames)
    /// 5. Falls back to generic (no function constants) pipeline — shader uses runtime params
    func selectComputePipeline(fractalIterations: Int,
                               maxRaySteps: Int,
                               request: ComputePipelineRequest? = nil) -> MTLComputePipelineState? {
        let fractalType = request?.fractalType ?? appModel.renderSettings.fractalType
        let formulaParams = request?.formulaParams ?? appModel.renderSettings.formulaParams
        let activeCustomHash = fractalType == .custom ? customShaderHash : nil
        let mbPowerInt = FormulaCatalog.specializedMandelbulbPower(
            fractalType: fractalType,
            formulaParams: formulaParams
        )
        let powerKey = mbPowerInt.map { "P\($0)" } ?? ""
        let bubbleEnabled = effectiveSafetyBubbleEnabled(for: fractalType)
        let packetEnabled = appModel.renderSettings.coherentPacketEnabled
        let cacheKeyPrefix = customCacheKeyPrefix()
        let keyContext = ComputePipelineKeyContext(
            prefix: cacheKeyPrefix,
            fractalTypeRawValue: Int(fractalType.rawValue),
            fractalIterations: fractalIterations,
            maxRaySteps: maxRaySteps,
            powerKey: powerKey,
            sceneKey: "_B\(bubbleEnabled ? 1 : 0)_CP\(packetEnabled ? 1 : 0)"
        )

        let recreateLegacyBug = appModel.renderSettings.recreateLegacyComputeCacheBug

        // Fast-path: parameters unchanged since last call
        if fractalIterations == lastComputeFI && maxRaySteps == lastComputeRS && fractalType.rawValue == lastComputeFT && activeCustomHash == lastComputeCustomHash && mbPowerInt == lastComputePower,
           bubbleEnabled == lastComputeBubble, packetEnabled == lastComputePacket,
           recreateLegacyBug == lastComputeLegacyBugMode,
           let cached = lastSelectedComputePipeline {
            recordPipelineTelemetry(computeHit: true, computeSource: "fast-path")
            return cached
        }
        lastComputeLegacyBugMode = recreateLegacyBug

        let exactKey = keyContext.exactKey

        // 1. Exact match — FC values match precomputed absScalePow
        if let pipeline = computePipelineCache[exactKey] {
            recordPipelineTelemetry(computeHit: true, computeSource: "exact")
            if RENDERER_DEBUG && lastComputePipelineKey != exactKey {
                print("🎯 [ComputeCache] Exact hit: \(exactKey)")
                lastComputePipelineKey = exactKey
            }
            return cacheSelectedComputePipeline(
                pipeline,
                fractalTypeRawValue: fractalType.rawValue,
                fractalIterations: fractalIterations,
                maxRaySteps: maxRaySteps,
                mandelbulbPower: mbPowerInt,
                activeCustomHash: activeCustomHash,
                bubbleEnabled: bubbleEnabled,
                packetEnabled: packetEnabled
            )
        }

        let sharedKey = keyContext.sharedKey
        if let pipeline = computePipelineCache[sharedKey] {
            recordPipelineTelemetry(computeHit: true, computeSource: "shared")
            if RENDERER_DEBUG && lastComputePipelineKey != sharedKey {
                print("🎯 [ComputeCache] Shared quality hit: \(sharedKey) for FT=\(fractalType.rawValue)")
                lastComputePipelineKey = sharedKey
            }
            return cacheSelectedComputePipeline(
                pipeline,
                fractalTypeRawValue: fractalType.rawValue,
                fractalIterations: fractalIterations,
                maxRaySteps: maxRaySteps,
                mandelbulbPower: mbPowerInt,
                activeCustomHash: activeCustomHash,
                bubbleEnabled: bubbleEnabled,
                packetEnabled: packetEnabled
            )
        }

        // Legacy bug mode ("Accidental Sphere Projection"): serve the NEAREST
        // cached FI/RS pipeline even though its baked FC_FRACTAL_ITERATIONS
        // mismatches the CPU-precomputed absScalePow — intentionally recreating
        // the historical artifact look. Built-ins only; a custom library's
        // pipelines aren't interchangeable.
        if recreateLegacyBug, fractalType != .custom {
            let nearest = computePipelineCache
                .compactMap { entry -> (key: String, pipeline: MTLComputePipelineState, score: Int)? in
                    let key = entry.key
                    guard let fiRange = key.range(of: "FI"),
                          let rsRange = key.range(of: "_RS", range: fiRange.upperBound..<key.endIndex) else { return nil }
                    let fiText = String(key[fiRange.upperBound..<rsRange.lowerBound])
                    let rsSuffix = key[rsRange.upperBound...]
                    let rsText = rsSuffix.prefix { $0.isNumber }
                    guard let fi = Int(fiText), let rs = Int(rsText) else { return nil }
                    let score = abs(fi - fractalIterations) * 1000 + abs(rs - maxRaySteps)
                    return (key: key, pipeline: entry.value, score: score)
                }
                .min { $0.score < $1.score }

            if let nearest {
                recordPipelineTelemetry(computeHit: true, computeSource: "legacy-nearest")
                if RENDERER_DEBUG && lastComputePipelineKey != "legacyNearest_\(nearest.key)" {
                    print("🪲 [ComputeCache] Legacy bug mode: nearest fallback \(nearest.key) for requested FT=\(fractalType.rawValue) FI=\(fractalIterations) RS=\(maxRaySteps)")
                    lastComputePipelineKey = "legacyNearest_\(nearest.key)"
                }
                return cacheSelectedComputePipeline(
                    nearest.pipeline,
                    fractalTypeRawValue: fractalType.rawValue,
                    fractalIterations: fractalIterations,
                    maxRaySteps: maxRaySteps,
                    mandelbulbPower: mbPowerInt,
                    activeCustomHash: activeCustomHash,
                    bubbleEnabled: bubbleEnabled,
                    packetEnabled: packetEnabled
                )
            }
        }

        // 3. Kick off a background build for this exact configuration. Built-in
        //    fractals can serve the current frame from the bundled generic
        //    compute pipeline; custom formulas cannot, because their dispatch arm
        //    exists only in the runtime-compiled library. For custom misses,
        //    decline adaptive compute for this frame so the fragment path can run.
        if fractalType == .custom {
            customSceneDiagnostic("🔬 [CSDiag] selectComputePipeline FT=custom miss — libraryPresent=\(renderingLibrary() != nil) hash=\(activeCustomHash ?? "nil") key=\(exactKey)")
            if renderingLibrary() != nil {
                enqueueBackgroundComputePipelineBuild(
                    cacheKey: exactKey,
                    fractalType: Int32(fractalType.rawValue),
                    fractalIterations: Int32(fractalIterations),
                    shadowIterations: Int32(max(fractalIterations - 2, 2)),
                    maxRaySteps: Int32(maxRaySteps),
                    mandelbulbPower: mbPowerInt,
                    safetyBubbleEnabled: bubbleEnabled,
                    coherentPacketEnabled: packetEnabled
                )
                recordPipelineTelemetry(computeHit: false, computeMissKey: exactKey, computeSource: "custom-background-build")
                customSceneDiagnostic("🔬 [CSDiag] selectComputePipeline FT=custom → enqueued background build, returning NIL (compute prepass declined this frame)")
            } else {
                recordPipelineTelemetry(computeHit: false, computeMissKey: exactKey, computeSource: "custom-missing-library")
                customSceneDiagnostic("🔬 [CSDiag] ⚠️ selectComputePipeline FT=custom → library MISSING, compute prepass disabled")
            }
            return cacheSelectedComputePipeline(
                nil,
                fractalTypeRawValue: fractalType.rawValue,
                fractalIterations: fractalIterations,
                maxRaySteps: maxRaySteps,
                mandelbulbPower: mbPowerInt,
                activeCustomHash: activeCustomHash,
                bubbleEnabled: bubbleEnabled,
                packetEnabled: packetEnabled
            )
        }

        enqueueBackgroundComputePipelineBuild(
            cacheKey: exactKey,
            fractalType: Int32(fractalType.rawValue),
            fractalIterations: Int32(fractalIterations),
            shadowIterations: Int32(max(fractalIterations - 2, 2)),
            maxRaySteps: Int32(maxRaySteps),
            mandelbulbPower: mbPowerInt,
            safetyBubbleEnabled: bubbleEnabled,
            coherentPacketEnabled: packetEnabled
        )

        // 4. Powerless shared fallback — serve the FI/RS-specialized startup
        //    pipeline THIS frame while the exact build (enqueued above) runs.
        //    A baked Mandelbulb power makes `sharedKey` carry "P{n}", but the
        //    startup shared tier is keyed plain "FI{fi}_RS{rs}" with power /
        //    bubble / packet left as *undefined* function constants (built with
        //    an empty MTLFunctionConstantValues — Renderer.init ~:492/:509, read
        //    from uniforms at runtime). So the shared lookup at step 2 is dead for
        //    every common integer power, and without this we'd drop straight to
        //    the fully-generic kernel during interaction with the heaviest
        //    fractal. Stripping `powerKey` reproduces exactly the startup key;
        //    serving it is correct for any power/bubble/packet because the shader
        //    reads those from uniforms. The exact (power-baked) pipeline still
        //    builds in the background and takes over in steady state.
        //
        //    DEFAULT-LIBRARY ONLY. The startup shared tier is keyed plain
        //    "FI{fi}_RS{rs}" with NO custom prefix, so it can only ever serve a
        //    built-in with no active custom library. A custom space warp riding a
        //    built-in carries a non-empty "CX{hash}_" prefix (and Mandelbulb is
        //    exactly when powerKey is non-empty) — serving the default pipeline
        //    there would silently drop the warp, so that case must wait for its
        //    exact custom-library build. Gating on cacheKeyPrefix.isEmpty also
        //    keeps the dropLast suffix-strip honest: with no prefix, sharedKey is
        //    "FI{fi}_RS{rs}" + powerKey, so dropLast(powerKey.count) is exact.
        //
        //    VALID ONLY while the shared tier leaves power/bubble/packet undefined.
        //    If a future edit bakes any of them into the startup pipelines, this
        //    probe would serve a wrong-scene pipeline — the debug assert guards
        //    the key grammar this assumption depends on.
        if !powerKey.isEmpty, cacheKeyPrefix.isEmpty {
            let powerlessSharedKey = String(sharedKey.dropLast(powerKey.count))
            assert(powerlessSharedKey == "FI\(fractalIterations)_RS\(maxRaySteps)",
                   "Powerless shared probe drifted from the startup compute key format (Renderer.init ~:492); re-check that the shared tier still omits power/scene bakes before trusting this fallback.")
            if let shared = computePipelineCache[powerlessSharedKey] {
                recordPipelineTelemetry(computeHit: false, computeMissKey: exactKey, computeSource: "shared-powerless")
                if RENDERER_DEBUG && lastComputePipelineKey != powerlessSharedKey {
                    print("🎯 [ComputeCache] Powerless shared fallback: \(powerlessSharedKey) (exact \(exactKey) building)")
                    lastComputePipelineKey = powerlessSharedKey
                }
                return cacheSelectedComputePipeline(
                    shared,
                    fractalTypeRawValue: fractalType.rawValue,
                    fractalIterations: fractalIterations,
                    maxRaySteps: maxRaySteps,
                    mandelbulbPower: mbPowerInt,
                    activeCustomHash: activeCustomHash,
                    bubbleEnabled: bubbleEnabled,
                    packetEnabled: packetEnabled
                )
            }
        }

        // 5. Ultimate fallback — generic pipeline with NO function constants.
        //    Shader reads iterations from uniforms at runtime, matching absScalePow.
        if RENDERER_DEBUG && lastComputePipelineKey != "fallback" {
            print("⚠️ [ComputeCache] Using fallback generic compute pipeline")
            lastComputePipelineKey = "fallback"
        }
        recordPipelineTelemetry(computeHit: false, computeMissKey: exactKey, computeSource: "generic-fallback")
        let fallback = adaptiveHierarchicalPipeline8x8
        return cacheSelectedComputePipeline(
            fallback,
            fractalTypeRawValue: fractalType.rawValue,
            fractalIterations: fractalIterations,
            maxRaySteps: maxRaySteps,
            mandelbulbPower: mbPowerInt,
            activeCustomHash: activeCustomHash,
            bubbleEnabled: bubbleEnabled,
            packetEnabled: packetEnabled
        )
    }

    private func acceptsCompletedCustomPipelineBuild(forKey key: String) -> Bool {
        guard key.hasPrefix("CX") else { return true }
        guard let activeHash = customShaderHash else { return false }
        return key.hasPrefix("CX\(activeHash)_")
    }

    private func shouldDelayRenderPipelineBuild(forKey key: String, now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Bool {
        guard let retryState = renderPipelineBuildRetryStates[key] else { return false }
        return now < retryState.retryAfter
    }

    private func shouldDelayComputePipelineBuild(forKey key: String, now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Bool {
        guard let retryState = computePipelineBuildRetryStates[key] else { return false }
        return now < retryState.retryAfter
    }

    // MARK: - Background Pipeline Builds

    /// Inserts a built render pipeline into the cache. Callable from the
    /// Renderer actor only; the background-build helper hops back here once
    /// compilation finishes.
    func insertBuiltRenderPipeline(_ pipeline: MTLRenderPipelineState, forKey key: String) {
        pendingPipelineBuildKeys.remove(key)
        backgroundRenderPipelineBuildTasks.removeValue(forKey: key)
        renderPipelineBuildRetryStates.removeValue(forKey: key)
        guard acceptsCompletedCustomPipelineBuild(forKey: key) else {
            if RENDERER_DEBUG { print("⏭️ [Pipeline] Dropped stale async custom render pipeline: \(key)") }
            return
        }
        pipelineCache[key] = pipeline
        // Nudge the fast-path so the next frame picks the specialized pipeline
        // immediately instead of remembering the previous fallback.
        lastSelectedPipeline = nil
        if RENDERER_DEBUG { print("✅ [Pipeline] Async-built and cached: \(key)") }
        // The render PSO was captured into the archive inside buildSpecializedPipeline;
        // persist it once this burst of interaction-driven builds settles.
        scheduleArchiveSerialize()
    }

    /// Marks a background build as failed so the pending set doesn't leak.
    func markPipelineBuildFailed(forKey key: String) {
        pendingPipelineBuildKeys.remove(key)
        backgroundRenderPipelineBuildTasks.removeValue(forKey: key)
        let nextFailureCount = (renderPipelineBuildRetryStates[key]?.failures ?? 0) + 1
        let delay = min(maxPipelineBuildRetryDelay, initialPipelineBuildRetryDelay * pow(2.0, Double(nextFailureCount - 1)))
        renderPipelineBuildRetryStates[key] = PipelineBuildRetryState(
            failures: nextFailureCount,
            retryAfter: Date.timeIntervalSinceReferenceDate + delay
        )
    }

    /// Inserts a built compute pipeline into the cache and clears its pending marker.
    func insertBuiltComputePipeline(_ pipeline: MTLComputePipelineState, forKey key: String) {
        pendingComputePipelineBuildKeys.remove(key)
        backgroundComputePipelineBuildTasks.removeValue(forKey: key)
        computePipelineBuildRetryStates.removeValue(forKey: key)
        guard acceptsCompletedCustomPipelineBuild(forKey: key) else {
            if RENDERER_DEBUG { print("⏭️ [Compute] Dropped stale async custom compute pipeline: \(key)") }
            return
        }
        computePipelineCache[key] = pipeline
        lastSelectedComputePipeline = nil
        if RENDERER_DEBUG { print("✅ [Compute] Async-built and cached: \(key)") }
        // The just-built PSO was added to the archive inside buildComputePipeline;
        // persist it once this burst of interaction-driven builds settles.
        scheduleArchiveSerialize()
    }

    /// Coalesce archive writes: reschedule a single background serialize a few
    /// seconds after the most recent lazy build, so a burst of pipeline builds
    /// during interaction produces one disk write, off the render loop.
    func scheduleArchiveSerialize() {
        let compute = pipelineArchive
        let render = renderPipelineArchive
        guard compute != nil || render != nil else { return }
        archiveSerializeTask?.cancel()
        archiveSerializeTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // A cancelled sleep throws, which `try?` swallows — so without this
            // guard a superseded (cancelled) task would still serialize, firing a
            // disk write per build instead of one after the burst settles. Skip
            // when cancelled; only the final, un-cancelled task persists.
            guard !Task.isCancelled else { return }
            compute?.serializeIfDirty()   // each is a no-op unless its own dirty flag is set
            render?.serializeIfDirty()
        }
    }

    func markComputePipelineBuildFailed(forKey key: String) {
        pendingComputePipelineBuildKeys.remove(key)
        backgroundComputePipelineBuildTasks.removeValue(forKey: key)
        let nextFailureCount = (computePipelineBuildRetryStates[key]?.failures ?? 0) + 1
        let delay = min(maxPipelineBuildRetryDelay, initialPipelineBuildRetryDelay * pow(2.0, Double(nextFailureCount - 1)))
        computePipelineBuildRetryStates[key] = PipelineBuildRetryState(
            failures: nextFailureCount,
            retryAfter: Date.timeIntervalSinceReferenceDate + delay
        )
    }

    /// Enqueues a detached task to build a specialized render pipeline off-actor,
    /// then hops back to insert it into `pipelineCache`. Duplicate requests for a
    /// key already in flight are silently dropped. Runs at low priority so it
    /// never preempts the render loop.
    fileprivate func enqueueBackgroundPipelineBuild(
        cacheKey: String,
        config: FunctionConstantConfig
    ) {
        if pendingPipelineBuildKeys.contains(cacheKey) { return }
        if shouldDelayRenderPipelineBuild(forKey: cacheKey) { return }
        if pendingPipelineBuildKeys.count >= maxPendingRenderPipelineBuilds { return }
        pendingPipelineBuildKeys.insert(cacheKey)

        // Capture only Sendable values / references we know are Metal-thread-safe.
        // MTLVertexDescriptor and LayerRenderer are not marked Sendable by the SDK,
        // but Metal pipeline construction is thread-safe and we never mutate these
        // descriptors after renderer init — so we escape via nonisolated(unsafe).
        let device = self.device
        nonisolated(unsafe) let layerRenderer = self.layerRenderer
        let rasterSampleCount = self.rasterSampleCount
        nonisolated(unsafe) let vertexDescriptor = self.mtlVertexDescriptor
        let fragmentName = "fragmentShader"
        // Snapshot the active custom library at enqueue time so the eventual
        // build matches the cache key prefix. `MTLLibrary` is thread-safe.
        let customLibrary: MTLLibrary? =
            cacheKey.hasPrefix("CX") ? customShaderLibrary : nil
        // PipelineBinaryArchive is Sendable + internally locked, so it crosses
        // safely into the detached build.
        let archiveRef = renderPipelineArchive

        let buildTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let pipeline = try Renderer.buildSpecializedPipeline(
                    device: device,
                    layerRenderer: layerRenderer,
                    rasterSampleCount: rasterSampleCount,
                    mtlVertexDescriptor: vertexDescriptor,
                    config: config,
                    fragmentFunctionName: fragmentName,
                    library: customLibrary,
                    archive: archiveRef
                )
                await self?.insertBuiltRenderPipeline(pipeline, forKey: cacheKey)
            } catch {
                if RENDERER_DEBUG {
                    print("❌ [Pipeline] Background build failed for \(cacheKey): \(error)")
                }
                await self?.markPipelineBuildFailed(forKey: cacheKey)
            }
        }
        backgroundRenderPipelineBuildTasks[cacheKey] = buildTask
    }

    /// Compute-path counterpart to `enqueueBackgroundPipelineBuild`. Builds the
    /// specialized adaptive 8x8 compute kernel off-actor and inserts into
    /// `computePipelineCache` on completion.
    fileprivate func enqueueBackgroundComputePipelineBuild(
        cacheKey: String,
        fractalType: Int32,
        fractalIterations: Int32,
        shadowIterations: Int32,
        maxRaySteps: Int32,
        mandelbulbPower: Int32?,
        safetyBubbleEnabled: Bool? = nil,
        coherentPacketEnabled: Bool? = nil
    ) {
        if pendingComputePipelineBuildKeys.contains(cacheKey) { return }
        if shouldDelayComputePipelineBuild(forKey: cacheKey) { return }
        if pendingComputePipelineBuildKeys.count >= maxPendingComputePipelineBuilds { return }
        pendingComputePipelineBuildKeys.insert(cacheKey)

        let device = self.device
        // Resolve the appropriate library: custom library for `.custom`, else default.
        let library: MTLLibrary?
        if cacheKey.hasPrefix("CX"), let custom = customShaderLibrary {
            library = custom
        } else {
            library = Renderer.bundledDefaultLibrary(device: device)
        }

        guard let metalLibrary = library else {
            pendingComputePipelineBuildKeys.remove(cacheKey)
            return
        }

        let buildTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if let pipeline = Renderer.buildComputePipeline(
                device: device,
                library: metalLibrary,
                kernelName: "adaptiveHierarchical8x8",
                fractalType: fractalType,
                fractalIterations: fractalIterations,
                shadowIterations: shadowIterations,
                maxRaySteps: maxRaySteps,
                mandelbulbPower: mandelbulbPower,
                safetyBubbleEnabled: safetyBubbleEnabled,
                coherentPacketEnabled: coherentPacketEnabled,
                archive: self.pipelineArchive
            ) {
                await self.insertBuiltComputePipeline(pipeline, forKey: cacheKey)
            } else {
                await self.markComputePipelineBuildFailed(forKey: cacheKey)
            }
        }
        backgroundComputePipelineBuildTasks[cacheKey] = buildTask
    }

}
