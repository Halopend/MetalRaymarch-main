@preconcurrency import CompositorServices
import Metal

private struct RenderPipelineKeyContext {
    let exactStem: String
    let sharedStem: String
    let suffix: String

    init(prefix: String,
         fractalTypeRawValue: Int,
         iterations: Int,
         raySteps: Int,
         qualityMode: Int,
         powerKey: String,
         useQuadShared: Bool) {
        exactStem = prefix + "FT\(fractalTypeRawValue)_FI\(iterations)_RS\(raySteps)_N"
        sharedStem = prefix + "FI\(iterations)_RS\(raySteps)_N"
        suffix = "_Q\(qualityMode)\(powerKey)" + (useQuadShared ? "_QS" : "")
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
         powerKey: String) {
        exactKey = prefix + "FT\(fractalTypeRawValue)_FI\(fractalIterations)_RS\(maxRaySteps)\(powerKey)"
        sharedKey = prefix + "FI\(fractalIterations)_RS\(maxRaySteps)\(powerKey)"
    }
}

extension Renderer {
    @inline(__always)
    fileprivate func recordPipelineTelemetry(renderHit: Bool? = nil,
                                             computeHit: Bool? = nil,
                                             renderMissKey: String? = nil,
                                             computeMissKey: String? = nil) {
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

        guard RENDERER_DEBUG else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if now - lastPipelineTelemetryLogTime >= 5.0 {
            lastPipelineTelemetryLogTime = now

            let renderTotal = renderPipelineCacheHits + renderPipelineCacheMisses
            let computeTotal = computePipelineCacheHits + computePipelineCacheMisses
            let renderHitRate = renderTotal > 0 ? (Double(renderPipelineCacheHits) / Double(renderTotal)) * 100.0 : 0.0
            let computeHitRate = computeTotal > 0 ? (Double(computePipelineCacheHits) / Double(computeTotal)) * 100.0 : 0.0

            print("📊 [PipelineTelemetry] render hitRate=\(String(format: "%.1f", renderHitRate))% (H:\(renderPipelineCacheHits) M:\(renderPipelineCacheMisses)) | compute hitRate=\(String(format: "%.1f", computeHitRate))% (H:\(computePipelineCacheHits) M:\(computePipelineCacheMisses))")
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

    // MARK: - Unified Pipeline Management

    /// Gets or builds a specialized pipeline for a given preset.
    /// Uses the unified pipelineCache to avoid redundant compilation.
    func getPipeline(forPreset preset: FractalPreset, useQuadShared: Bool = false) -> MTLRenderPipelineState {
        let prefix = customCacheKeyPrefix(for: preset.fractalType)
        let cacheKey = prefix + preset.pipelineCacheKey + (useQuadShared ? "_QS" : "")
        let library = preset.fractalType == .custom ? renderingLibrary(for: preset.fractalType) : nil

        if preset.fractalType == .custom, library == nil {
            return useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
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
                fragmentFunctionName: useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader",
                library: library
            )
            pipelineCache[cacheKey] = pipeline  // Store in unified cache
            if RENDERER_DEBUG { print("✅ [ShaderCompilation] SUCCESS: Built pipeline [\(cacheKey)]") }
            return pipeline
        } catch {
            if RENDERER_DEBUG { print("❌ [ShaderCompilation] FAILED to build preset pipeline [\(cacheKey)]: \(error)") }
            return useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
        }
    }

    /// Gets or builds a specialized pipeline for specific iteration/ray step values.
    /// Call this when slider values change to pre-compile the needed pipeline.
    func getPipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool = false) -> MTLRenderPipelineState {
        // Build cache key matching the preset format
        let colorIters = appModel.renderSettings.colorIterations  // Direct read (own lock) — avoids full snapshot
        let fractalType = appModel.renderSettings.fractalType
        let library = fractalType == .custom ? renderingLibrary(for: fractalType) : nil

        if fractalType == .custom, library == nil {
            return useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
        }

        let mandelbulbPower = FunctionConstantConfig.specializedMandelbulbPower(
            fractalType: fractalType,
            formulaParams: appModel.renderSettings.formulaParams
        )
        let neon = (appModel.renderSettings.gradientPreset?.isNeonMode ?? false) ? 1 : 0
        let qualityMode: Int32 = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let powerKey = mandelbulbPower.map { "_P\($0)" } ?? ""
        let keyContext = RenderPipelineKeyContext(
            prefix: customCacheKeyPrefix(for: fractalType),
            fractalTypeRawValue: Int(fractalType.rawValue),
            iterations: iterations,
            raySteps: raySteps,
            qualityMode: Int(qualityMode),
            powerKey: powerKey,
            useQuadShared: useQuadShared
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
            safetyBubbleEnabled: nil,  // Runtime: respects user toggle
            qualityMode: qualityMode,
            debugHierarchical: false,
            maxRaySteps: Int32(raySteps),
            fractalType: fractalType.rawValue,
            neonModeEnabled: neon == 1,
            colorIterations: Int32(colorIters),  // Use actual color iterations, not fractal iterations
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
                fragmentFunctionName: useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader",
                library: library
            )
            pipelineCache[cacheKey] = pipeline
            if RENDERER_DEBUG { print("✅ [ShaderCompilation] Ready: FT=\(fractalType.rawValue) FI=\(iterations) RS=\(raySteps)") }
            return pipeline
        } catch {
            if RENDERER_DEBUG { print("❌ [ShaderCompilation] FAILED for FT=\(fractalType.rawValue) FI=\(iterations) RS=\(raySteps): \(error)") }
            return useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
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
        var compiledCount = 0

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

            // Build both standard and quad-shared variants
            _ = getPipeline(forPreset: preset, useQuadShared: false)
            _ = getPipeline(forPreset: preset, useQuadShared: true)
            compiledCount += 1
        }

        if RENDERER_DEBUG {
            print("✅ [ShaderCompilation] Precompiled \(compiledCount) unique preset pipelines (from \(presets.count) presets)")
            print("   Unified cache now contains \(pipelineCache.count) pipelines")
        }
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
    func selectPipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool,
                        neonMode: Bool = false) -> MTLRenderPipelineState {
        let fractalType = appModel.renderSettings.fractalType
        let activeCustomHash = fractalType == .custom ? customShaderHash : nil
        let mandelbulbPower = FunctionConstantConfig.specializedMandelbulbPower(
            fractalType: fractalType,
            formulaParams: appModel.renderSettings.formulaParams
        )
        if RENDERER_DEBUG,
           fractalType == .mandelbulb,
           mandelbulbPower != lastSelectPower {
            let previousPower = lastSelectPower.map { String($0) } ?? "runtime"
            let nextPower = mandelbulbPower.map { String($0) } ?? "runtime"
            print("🔀 [Pipeline] Mandelbulb power changed: \(previousPower) → \(nextPower)")
        }

        // Fast-path: parameters unchanged since last call — skip string alloc + dict lookup
        if iterations == lastSelectIter && raySteps == lastSelectRS &&
           useQuadShared == lastSelectQS &&
           neonMode == lastSelectNeon &&
           fractalType.rawValue == lastSelectFT &&
           activeCustomHash == lastSelectCustomHash &&
           mandelbulbPower == lastSelectPower, let cached = lastSelectedPipeline {
            recordPipelineTelemetry(renderHit: true)
            appModel.isUsingSpecializedPipeline = lastSelectedIsSpecialized
            return cached
        }

        // Build unified cache key (only on parameter change)
        let qualityMode: Int = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let powerKey = mandelbulbPower.map { "_P\($0)" } ?? ""
        let keyContext = RenderPipelineKeyContext(
            prefix: customCacheKeyPrefix(for: fractalType),
            fractalTypeRawValue: Int(fractalType.rawValue),
            iterations: iterations,
            raySteps: raySteps,
            qualityMode: qualityMode,
            powerKey: powerKey,
            useQuadShared: useQuadShared
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
            recordPipelineTelemetry(renderHit: true)
            if RENDERER_DEBUG && lastLoggedPipelineKey != cacheKey {
                print("🎯 [Pipeline] Using cached pipeline: \(cacheKey)")
                lastLoggedPipelineKey = cacheKey
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

            let colorIters = appModel.renderSettings.colorIterations
            let exactConfig = FunctionConstantConfig(
                fractalIterations: Int32(iterations),
                shadowIterations: Int32(max(iterations - 2, 2)),
                safetyBubbleEnabled: nil,
                qualityMode: Int32(qualityMode),
                debugHierarchical: false,
                maxRaySteps: Int32(raySteps),
                fractalType: fractalType.rawValue,
                neonModeEnabled: neonMode,
                colorIterations: Int32(colorIters),
                mandelbulbPower: mandelbulbPower
            )

            if fractalType == .custom {
                guard let library = renderingLibrary(for: fractalType) else {
                    print("⚠️ [CustomScene] Missing active custom shader library for render pipeline build")
                    isSpecialized = false
                    result = useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
                    lastSelectIter = iterations
                    lastSelectRS = raySteps
                    lastSelectQS = useQuadShared
                    lastSelectNeon = neonMode
                    lastSelectFT = fractalType.rawValue
                    lastSelectPower = mandelbulbPower
                    lastSelectCustomHash = activeCustomHash
                    lastSelectedPipeline = result
                    lastSelectedIsSpecialized = false
                    appModel.isUsingSpecializedPipeline = false
                    return result
                }
                do {
                    let pipeline = try Renderer.buildSpecializedPipeline(
                        device: device,
                        layerRenderer: layerRenderer,
                        rasterSampleCount: rasterSampleCount,
                        mtlVertexDescriptor: mtlVertexDescriptor,
                        config: exactConfig,
                        fragmentFunctionName: useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader",
                        library: library
                    )
                    pipelineCache[cacheKey] = pipeline
                    lastLoggedPipelineKey = cacheKey
                    result = pipeline
                    lastSelectIter = iterations
                    lastSelectRS = raySteps
                    lastSelectQS = useQuadShared
                    lastSelectNeon = neonMode
                    lastSelectFT = fractalType.rawValue
                    lastSelectPower = mandelbulbPower
                    lastSelectCustomHash = activeCustomHash
                    lastSelectedPipeline = result
                    lastSelectedIsSpecialized = true
                    appModel.isUsingSpecializedPipeline = true
                    return result
                } catch {
                    print("❌ [CustomScene] Exact render pipeline build failed: \(error)")
                }
            } else {
                enqueueBackgroundPipelineBuild(
                    cacheKey: cacheKey,
                    config: exactConfig,
                    useQuadShared: useQuadShared
                )
            }

            // 3. Try FT-specific neon=off quality-preset fallback.
            let fallbackKey = keyContext.exactKey(neonEnabled: false)
            if let pipeline = pipelineCache[fallbackKey] {
                if RENDERER_DEBUG && lastLoggedPipelineKey != fallbackKey {
                    print("🎯 [Pipeline] Using quality-preset fallback: \(fallbackKey) (requested: \(cacheKey))")
                    lastLoggedPipelineKey = fallbackKey
                }
                result = pipeline
            }
            else {
                // 4. Try shared quality key (built at startup without FC_FRACTAL_TYPE)
                let sharedExactKey = keyContext.sharedKey(neonEnabled: neonMode)
                if let pipeline = pipelineCache[sharedExactKey] {
                    if RENDERER_DEBUG && lastLoggedPipelineKey != sharedExactKey {
                        print("🎯 [Pipeline] Using shared quality pipeline: \(sharedExactKey) for FT=\(fractalType.rawValue)")
                        lastLoggedPipelineKey = sharedExactKey
                    }
                    result = pipeline
                }
                // 5. Try shared neon=off quality key
                else {
                    let sharedFallbackKey = keyContext.sharedKey(neonEnabled: false)
                    if sharedFallbackKey != sharedExactKey, let pipeline = pipelineCache[sharedFallbackKey] {
                        if RENDERER_DEBUG && lastLoggedPipelineKey != sharedFallbackKey {
                            print("🎯 [Pipeline] Using shared neon-off quality pipeline: \(sharedFallbackKey) for FT=\(fractalType.rawValue)")
                            lastLoggedPipelineKey = sharedFallbackKey
                        }
                        result = pipeline
                    }
                    // 6. Ultimate fallback to generic pipeline
                    else {
                        if RENDERER_DEBUG && lastLoggedPipelineKey != "fallback" {
                            print("⚠️ [Pipeline] Using FALLBACK generic pipeline (no cache hit for FT=\(fractalType.rawValue) FI=\(iterations) RS=\(raySteps))")
                            lastLoggedPipelineKey = "fallback"
                        }
                        isSpecialized = false
                        result = useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
                    }
                }
            }
        }

        // Cache for next frame's fast-path
        lastSelectIter = iterations
        lastSelectRS = raySteps
        lastSelectQS = useQuadShared
        lastSelectNeon = neonMode
        lastSelectFT = fractalType.rawValue
        lastSelectPower = mandelbulbPower
        lastSelectCustomHash = activeCustomHash
        lastSelectedPipeline = result
        lastSelectedIsSpecialized = isSpecialized
        appModel.isUsingSpecializedPipeline = isSpecialized
        return result
    }

    /// Ensures a pipeline exists for the given configuration.
    /// Builds on-demand if not found in cache. Call this when loading a preset
    /// to avoid frame hitches during rendering.
    func ensurePipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool,
                        neonMode: Bool) {
        let fractalType = appModel.renderSettings.fractalType
        if fractalType == .custom, renderingLibrary(for: fractalType) == nil {
            return
        }
        let mandelbulbPower = FunctionConstantConfig.specializedMandelbulbPower(
            fractalType: fractalType,
            formulaParams: appModel.renderSettings.formulaParams
        )
        let qualityMode: Int = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let powerKey = mandelbulbPower.map { "_P\($0)" } ?? ""
        let keyContext = RenderPipelineKeyContext(
            prefix: customCacheKeyPrefix(for: fractalType),
            fractalTypeRawValue: Int(fractalType.rawValue),
            iterations: iterations,
            raySteps: raySteps,
            qualityMode: qualityMode,
            powerKey: powerKey,
            useQuadShared: useQuadShared
        )
        let cacheKey = keyContext.exactKey(neonEnabled: neonMode)

        // Already cached
        if pipelineCache[cacheKey] != nil { return }

        // Build on-demand
        if RENDERER_DEBUG { print("🔧 [Pipeline] Building on-demand pipeline: \(cacheKey)") }

        let config = FunctionConstantConfig(
            fractalIterations: Int32(iterations),
            shadowIterations: Int32(max(iterations - 2, 2)),
            safetyBubbleEnabled: nil,  // Runtime: respects user toggle
            qualityMode: Int32(qualityMode),
            debugHierarchical: false,
            maxRaySteps: Int32(raySteps),
            fractalType: fractalType.rawValue,
            neonModeEnabled: neonMode,
            colorIterations: 8,  // Color iterations are fixed for consistent coloring
            mandelbulbPower: mandelbulbPower
        )
        let library = fractalType == .custom ? renderingLibrary(for: fractalType) : nil

        if fractalType == .custom, library == nil {
            return
        }

        do {
            let pipeline = try Renderer.buildSpecializedPipeline(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                config: config,
                fragmentFunctionName: useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader",
                library: library
            )
            pipelineCache[cacheKey] = pipeline
            if RENDERER_DEBUG { print("✅ [Pipeline] Built on-demand: \(cacheKey)") }
        } catch {
            if RENDERER_DEBUG { print("❌ [Pipeline] Failed to build on-demand: \(cacheKey): \(error)") }
        }
    }

    // MARK: - Compute Pipeline Cache

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
                                     mandelbulbPower: Int32? = nil) -> MTLComputePipelineState? {
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
        constants.setConstantValue(&fi, type: .int, index: FunctionConstantIndex.fractalIterations.rawValue)
        constants.setConstantValue(&si, type: .int, index: FunctionConstantIndex.shadowIterations.rawValue)
        constants.setConstantValue(&rs, type: .int, index: FunctionConstantIndex.maxRaySteps.rawValue)
        constants.setConstantValue(&debug, type: .bool, index: FunctionConstantIndex.debugHierarchical.rawValue)
        constants.setConstantValue(&neon, type: .bool, index: FunctionConstantIndex.neonModeEnabled.rawValue)

        guard let function = try? library.makeFunction(name: kernelName, constantValues: constants) else {
            if RENDERER_DEBUG { print("⚠️ [ComputeCache] Failed to specialize \(kernelName) with FI=\(fi) RS=\(rs)") }
            return nil
        }

        do {
            return try device.makeComputePipelineState(function: function)
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
    func selectComputePipeline(fractalIterations: Int, maxRaySteps: Int) -> MTLComputePipelineState? {
        let fractalType = appModel.renderSettings.fractalType
        let activeCustomHash = fractalType == .custom ? customShaderHash : nil
        // Extract Mandelbulb integer power for compile-time specialization
        let mbPowerRaw = fractalType == .mandelbulb
            ? FormulaCatalog.getParam(appModel.renderSettings.formulaParams, index: 0)
            : Float(0)
        let mbPowerInt: Int32? = {
            let rounded = roundf(mbPowerRaw)
            // Only bake integer powers that fastPowR has explicit fast paths for
            if abs(mbPowerRaw - rounded) < 0.01,
               [2,3,4,5,6,8,10,12,16].contains(Int(rounded)) {
                return Int32(rounded)
            }
            return nil
        }()
        let powerKey = mbPowerInt.map { "P\($0)" } ?? ""
        let keyContext = ComputePipelineKeyContext(
            prefix: customCacheKeyPrefix(for: fractalType),
            fractalTypeRawValue: Int(fractalType.rawValue),
            fractalIterations: fractalIterations,
            maxRaySteps: maxRaySteps,
            powerKey: powerKey
        )

        // Fast-path: parameters unchanged since last call
        if fractalIterations == lastComputeFI && maxRaySteps == lastComputeRS && fractalType.rawValue == lastComputeFT && activeCustomHash == lastComputeCustomHash && mbPowerInt == lastComputePower,
           let cached = lastSelectedComputePipeline {
            recordPipelineTelemetry(computeHit: true)
            return cached
        }

        let exactKey = keyContext.exactKey

        // 1. Exact match — FC values match precomputed absScalePow
        if let pipeline = computePipelineCache[exactKey] {
            recordPipelineTelemetry(computeHit: true)
            if RENDERER_DEBUG && lastComputePipelineKey != exactKey {
                print("🎯 [ComputeCache] Exact hit: \(exactKey)")
                lastComputePipelineKey = exactKey
            }
            lastComputeFT = fractalType.rawValue
            lastComputeFI = fractalIterations
            lastComputeRS = maxRaySteps
            lastComputePower = mbPowerInt
            lastComputeCustomHash = activeCustomHash
            lastSelectedComputePipeline = pipeline
            return pipeline
        }

        let sharedKey = keyContext.sharedKey
        if let pipeline = computePipelineCache[sharedKey] {
            recordPipelineTelemetry(computeHit: true)
            if RENDERER_DEBUG && lastComputePipelineKey != sharedKey {
                print("🎯 [ComputeCache] Shared quality hit: \(sharedKey) for FT=\(fractalType.rawValue)")
                lastComputePipelineKey = sharedKey
            }
            lastComputeFT = fractalType.rawValue
            lastComputeFI = fractalIterations
            lastComputeRS = maxRaySteps
            lastComputePower = mbPowerInt
            lastComputeCustomHash = activeCustomHash
            lastSelectedComputePipeline = pipeline
            return pipeline
        }

        // 3. Kick off a background build for this exact configuration and serve
        //    the frame from the generic fallback below. Previously this branch
        //    called `buildComputePipeline` synchronously, which can block the
        //    render actor when the user picks a new fractal type or iteration
        //    count. Metal compute-pipeline construction is thread-safe, so we
        //    hop off the actor to build and back on to insert.
        if fractalType == .custom,
           let library = renderingLibrary(for: fractalType),
           let pipeline = Renderer.buildComputePipeline(
                device: device,
                library: library,
                kernelName: "adaptiveHierarchical8x8",
                fractalType: Int32(fractalType.rawValue),
                fractalIterations: Int32(fractalIterations),
                shadowIterations: Int32(max(fractalIterations - 2, 2)),
                maxRaySteps: Int32(maxRaySteps),
                mandelbulbPower: mbPowerInt
           ) {
            computePipelineCache[exactKey] = pipeline
            lastComputeFT = fractalType.rawValue
            lastComputeFI = fractalIterations
            lastComputeRS = maxRaySteps
            lastComputePower = mbPowerInt
            lastComputeCustomHash = activeCustomHash
            lastSelectedComputePipeline = pipeline
            lastComputePipelineKey = exactKey
            return pipeline
        }

        enqueueBackgroundComputePipelineBuild(
            cacheKey: exactKey,
            fractalType: Int32(fractalType.rawValue),
            fractalIterations: Int32(fractalIterations),
            shadowIterations: Int32(max(fractalIterations - 2, 2)),
            maxRaySteps: Int32(maxRaySteps),
            mandelbulbPower: mbPowerInt
        )

        // 4. Ultimate fallback — generic pipeline with NO function constants.
        //    Shader reads iterations from uniforms at runtime, matching absScalePow.
        if RENDERER_DEBUG && lastComputePipelineKey != "fallback" {
            print("⚠️ [ComputeCache] Using fallback generic compute pipeline")
            lastComputePipelineKey = "fallback"
        }
        recordPipelineTelemetry(computeHit: false, computeMissKey: exactKey)
        let fallback = adaptiveHierarchicalPipeline8x8
        lastComputeFT = fractalType.rawValue
        lastComputeFI = fractalIterations
        lastComputeRS = maxRaySteps
        lastComputePower = mbPowerInt
        lastComputeCustomHash = activeCustomHash
        lastSelectedComputePipeline = fallback
        return fallback
    }

    /// Returns the number of pipelines currently in the unified cache.
    var pipelineCacheCount: Int {
        return pipelineCache.count
    }

    // MARK: - Background Pipeline Builds

    /// Inserts a built render pipeline into the cache. Callable from the
    /// Renderer actor only; the background-build helper hops back here once
    /// compilation finishes.
    func insertBuiltRenderPipeline(_ pipeline: MTLRenderPipelineState, forKey key: String) {
        pipelineCache[key] = pipeline
        pendingPipelineBuildKeys.remove(key)
        // Nudge the fast-path so the next frame picks the specialized pipeline
        // immediately instead of remembering the previous fallback.
        lastSelectedPipeline = nil
        if RENDERER_DEBUG { print("✅ [Pipeline] Async-built and cached: \(key)") }
    }

    /// Marks a background build as failed so the pending set doesn't leak.
    func markPipelineBuildFailed(forKey key: String) {
        pendingPipelineBuildKeys.remove(key)
    }

    /// Inserts a built compute pipeline into the cache and clears its pending marker.
    func insertBuiltComputePipeline(_ pipeline: MTLComputePipelineState, forKey key: String) {
        computePipelineCache[key] = pipeline
        pendingComputePipelineBuildKeys.remove(key)
        lastSelectedComputePipeline = nil
        if RENDERER_DEBUG { print("✅ [Compute] Async-built and cached: \(key)") }
    }

    func markComputePipelineBuildFailed(forKey key: String) {
        pendingComputePipelineBuildKeys.remove(key)
    }

    /// Enqueues a detached task to build a specialized render pipeline off-actor,
    /// then hops back to insert it into `pipelineCache`. Duplicate requests for a
    /// key already in flight are silently dropped. Runs at low priority so it
    /// never preempts the render loop.
    fileprivate func enqueueBackgroundPipelineBuild(
        cacheKey: String,
        config: FunctionConstantConfig,
        useQuadShared: Bool
    ) {
        if pendingPipelineBuildKeys.contains(cacheKey) { return }
        pendingPipelineBuildKeys.insert(cacheKey)

        // Capture only Sendable values / references we know are Metal-thread-safe.
        // MTLVertexDescriptor and LayerRenderer are not marked Sendable by the SDK,
        // but Metal pipeline construction is thread-safe and we never mutate these
        // descriptors after renderer init — so we escape via nonisolated(unsafe).
        let device = self.device
        nonisolated(unsafe) let layerRenderer = self.layerRenderer
        let rasterSampleCount = self.rasterSampleCount
        nonisolated(unsafe) let vertexDescriptor = self.mtlVertexDescriptor
        let fragmentName = useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader"
        // Snapshot the active custom library at enqueue time so the eventual
        // build matches the cache key prefix. `MTLLibrary` is thread-safe.
        let customLibrary: MTLLibrary? =
            cacheKey.hasPrefix("CX") ? customShaderLibrary : nil

        Task.detached(priority: .utility) { [weak self] in
            do {
                let pipeline = try Renderer.buildSpecializedPipeline(
                    device: device,
                    layerRenderer: layerRenderer,
                    rasterSampleCount: rasterSampleCount,
                    mtlVertexDescriptor: vertexDescriptor,
                    config: config,
                    fragmentFunctionName: fragmentName,
                    library: customLibrary
                )
                await self?.insertBuiltRenderPipeline(pipeline, forKey: cacheKey)
            } catch {
                if RENDERER_DEBUG {
                    print("❌ [Pipeline] Background build failed for \(cacheKey): \(error)")
                }
                await self?.markPipelineBuildFailed(forKey: cacheKey)
            }
        }
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
        mandelbulbPower: Int32?
    ) {
        if pendingComputePipelineBuildKeys.contains(cacheKey) { return }
        pendingComputePipelineBuildKeys.insert(cacheKey)

        let device = self.device
        // Resolve the appropriate library: custom library for `.custom`, else default.
        let library: MTLLibrary?
        if cacheKey.hasPrefix("CX"), let custom = customShaderLibrary {
            library = custom
        } else if let cached = cachedDefaultLibrary {
            library = cached
        } else if let fresh = device.makeDefaultLibrary() {
            cachedDefaultLibrary = fresh
            library = fresh
        } else {
            library = nil
        }

        guard let metalLibrary = library else {
            pendingComputePipelineBuildKeys.remove(cacheKey)
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            if let pipeline = Renderer.buildComputePipeline(
                device: device,
                library: metalLibrary,
                kernelName: "adaptiveHierarchical8x8",
                fractalType: fractalType,
                fractalIterations: fractalIterations,
                shadowIterations: shadowIterations,
                maxRaySteps: maxRaySteps,
                mandelbulbPower: mandelbulbPower
            ) {
                await self?.insertBuiltComputePipeline(pipeline, forKey: cacheKey)
            } else {
                await self?.markComputePipelineBuildFailed(forKey: cacheKey)
            }
        }
    }

}
