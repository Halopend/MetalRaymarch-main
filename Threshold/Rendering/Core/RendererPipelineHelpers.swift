@preconcurrency import CompositorServices
import Metal

extension Renderer {
    static func bundledDefaultLibrary(device: MTLDevice) -> MTLLibrary? {
        if let cached = _cachedLibrary { return cached }
        let library = device.makeDefaultLibrary()
        _cachedLibrary = library
        return library
    }

    static func buildRenderPipelineWithDevice(device: MTLDevice,
                                              layerRenderer: LayerRenderer,
                                              rasterSampleCount: Int,
                                              mtlVertexDescriptor: MTLVertexDescriptor,
                                              colorFormat: MTLPixelFormat? = nil,
                                              depthFormat: MTLPixelFormat? = nil,
                                              vertexFunctionName: String = "vertexShader",
                                              fragmentFunctionName: String = "fragmentShader",
                                              usesVertexAmplification: Bool = true,
                                              functionConstants: MTLFunctionConstantValues? = nil,
                                              coarseWarmStart: Bool = false,
                                              library: MTLLibrary? = nil,
                                              archive: PipelineBinaryArchive? = nil) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object. When `library` is non-nil, all
        /// `makeFunction` calls target it (used for runtime-compiled `.threshfx`
        /// formulas). Otherwise the bundled `default.metallib` is used and cached.

        let resolvedLibrary: MTLLibrary?
        if let library {
            resolvedLibrary = library
        } else {
            resolvedLibrary = bundledDefaultLibrary(device: device)
        }
        let library = resolvedLibrary

        let vertexFunction = library?.makeFunction(name: vertexFunctionName)

        // IMPORTANT: Once a shader declares function constants, Metal requires using
        // makeFunction(name:constantValues:) even if no values are being set.
        // Always provide function constants (empty if nil) for fragment shaders that use them.
        let fragmentFunction: MTLFunction?
        let constants = functionConstants ?? MTLFunctionConstantValues()
        if fragmentFunctionName == "fragmentShader" {
            // FC_WARM_START (index 13): compile in the temporal-depth march
            // warm-start (prev-depth texture argument + reprojection). Runtime
            // engagement is still gated per frame via uniforms.warmStartEnabled.
            // Screenshot and Mac pipelines bypass this helper and compile it out.
            var warmStart = true
            constants.setConstantValue(&warmStart, type: .bool, index: FunctionConstantIndex.warmStart.rawValue)
            // FC_COARSE_WARM_START (index 15): compile in the conservative cone
            // coarse-prepass warm-start (coarse texture argument + min-over-2x2 read
            // + full-march seed). Default false → dead-code-eliminated; only the
            // dedicated cone-enabled pipeline variant sets it true.
            var coarse = coarseWarmStart
            constants.setConstantValue(&coarse, type: .bool, index: FunctionConstantIndex.coarseWarmStart.rawValue)
        }
        fragmentFunction = try library?.makeFunction(name: fragmentFunctionName, constantValues: constants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = functionConstants != nil ? "RenderPipeline_Specialized" : "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.rasterSampleCount = rasterSampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat ?? layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat ?? layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = usesVertexAmplification ? layerRenderer.properties.viewCount : 1

        // Route through the binary archive (lookup + capture under one lock) when
        // present, so this PSO's GPU compile is loaded from / saved to disk across
        // launches. Archive absent/miss → Metal compiles exactly as before.
        if let archive {
            return try archive.makeRenderPipeline(device: device, descriptor: pipelineDescriptor)
        }
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    /// Function constant configuration for shader specialization
    struct FunctionConstantConfig {
        var fractalIterations: Int32?      // FC index 0
        var shadowIterations: Int32?       // FC index 1
        var safetyBubbleEnabled: Bool?     // FC index 2
        var hasSpaceWarp: Bool?            // FC index 3 — nil leaves it undefined (shader defaults ON = full stack)
        var qualityMode: Int32?            // FC index 4 (0=high, 1=medium, 2=low)
        var debugHierarchical: Bool?       // FC index 5
        var maxRaySteps: Int32?            // FC index 6 - max ray marching steps
        var fractalType: Int32?            // FC index 7 - devirtualizes FractalDE_Dispatch
        var neonModeEnabled: Bool?         // FC index 8 - eliminates neon orbit tracking
        var colorIterations: Int32?        // FC index 9 - enables loop unrolling in color
        var shadowsEnabled: Bool?          // FC index 11 - GMT-fractals: compile-out shadows entirely
        var mandelbulbPower: Int32?        // FC index 12 - bakes integer power for fastPowR optimization
        var coherentPacketEnabled: Bool?   // FC index 14 - compute kernel only; compiles out packet experiment

            static func specializedMandelbulbPower(fractalType: FractalModelType,
                                   formulaParams: FormulaParams) -> Int32? {
                guard fractalType == .mandelbulb else { return nil }
                let rawPower = FormulaCatalog.getParam(formulaParams, index: 0)
                let rounded = roundf(rawPower)
                guard abs(rawPower - rounded) < 0.01,
                  [2, 3, 4, 5, 6, 8, 10, 12, 16].contains(Int(rounded)) else {
                return nil
                }
                return Int32(rounded)
            }

        /// Creates MTLFunctionConstantValues from this config
        func toMTLConstants() -> MTLFunctionConstantValues {
            let constants = MTLFunctionConstantValues()

            if var iterations = fractalIterations {
                constants.setConstantValue(&iterations, type: .int, index: FunctionConstantIndex.fractalIterations.rawValue)
            }
            if var shadowIters = shadowIterations {
                constants.setConstantValue(&shadowIters, type: .int, index: FunctionConstantIndex.shadowIterations.rawValue)
            }
            if var bubble = safetyBubbleEnabled {
                constants.setConstantValue(&bubble, type: .bool, index: FunctionConstantIndex.safetyBubbleEnabled.rawValue)
            }
            if var sw = hasSpaceWarp {
                constants.setConstantValue(&sw, type: .bool, index: FunctionConstantIndex.hasSpaceWarp.rawValue)
            }
            if var quality = qualityMode {
                constants.setConstantValue(&quality, type: .int, index: FunctionConstantIndex.qualityMode.rawValue)
            }
            if var debug = debugHierarchical {
                constants.setConstantValue(&debug, type: .bool, index: FunctionConstantIndex.debugHierarchical.rawValue)
            }
            if var raySteps = maxRaySteps {
                constants.setConstantValue(&raySteps, type: .int, index: FunctionConstantIndex.maxRaySteps.rawValue)
            }
            if var fType = fractalType {
                constants.setConstantValue(&fType, type: .int, index: FunctionConstantIndex.fractalType.rawValue)
            }
            if var neon = neonModeEnabled {
                constants.setConstantValue(&neon, type: .bool, index: FunctionConstantIndex.neonModeEnabled.rawValue)
            }
            if var colorIters = colorIterations {
                constants.setConstantValue(&colorIters, type: .int, index: FunctionConstantIndex.colorIterations.rawValue)
            }
            if var shadows = shadowsEnabled {
                constants.setConstantValue(&shadows, type: .bool, index: FunctionConstantIndex.shadowsEnabled.rawValue)
            }
            if var power = mandelbulbPower {
                constants.setConstantValue(&power, type: .int, index: FunctionConstantIndex.mandelbulbPower.rawValue)
            }
            if var packet = coherentPacketEnabled {
                constants.setConstantValue(&packet, type: .bool, index: FunctionConstantIndex.coherentPacketEnabled.rawValue)
            }

            return constants
        }

        /// Creates a config for each quality preset.
        /// These pipelines compile out neon code for maximum performance.
        /// Low quality also compiles out shadows entirely (Shadow() returns ambient constant).
        /// For presets that need neon, use fromPreset() instead.
        static func forQualityPreset(_ preset: QualityPreset) -> FunctionConstantConfig {
            let qualityMode: Int32
            switch preset {
            case .low: qualityMode = 2
            case .medium: qualityMode = 1
            case .high: qualityMode = 1
            case .ultra: qualityMode = 0
            }
            return FunctionConstantConfig(
                fractalIterations: Int32(preset.fractalIterations),
                shadowIterations: Int32(max(preset.fractalIterations - 2, 2)),
                safetyBubbleEnabled: nil,    // Runtime: respects user toggle
                qualityMode: qualityMode,
                debugHierarchical: false,
                maxRaySteps: Int32(preset.raySteps),
                neonModeEnabled: false,      // Compile out neon orbit tracking
                colorIterations: Int32(preset.fractalIterations),  // Match fractal iterations
                shadowsEnabled: preset == .low ? false : nil  // Low: compile out Shadow() entirely; others: runtime
            )
        }

        /// Creates a fully-specialized config from a saved FractalPreset.
        /// This enables maximum shader optimization by providing all known constants.
        ///
        /// Example usage:
        /// ```swift
        /// let preset = presetManager.presets.first!
        /// let config = FunctionConstantConfig.fromPreset(preset)
        /// let pipeline = try Renderer.buildSpecializedPipeline(config: config, ...)
        /// ```
        static func fromPreset(_ preset: FractalPreset) -> FunctionConstantConfig {
            let fc = preset.deriveFunctionConstants()
            return FunctionConstantConfig(
                // Bake the same effective bubble state encoded in the preset's
                // pipelineCacheKey so the prewarmed pipeline matches what
                // selectPipeline looks up (and bakes) once the preset is applied.
                fractalIterations: fc.fractalIterations,
                shadowIterations: fc.shadowIterations,
                safetyBubbleEnabled: preset.effectiveSafetyBubbleEnabled,
                hasSpaceWarp: preset.effectiveHasSpaceWarp,
                qualityMode: fc.qualityMode,
                debugHierarchical: false,
                maxRaySteps: fc.maxRaySteps,
                fractalType: preset.fractalType.rawValue,
                neonModeEnabled: fc.neonModeEnabled,
                colorIterations: fc.colorIterations,
                mandelbulbPower: fc.mandelbulbPower
            )
        }
    }

    /// Build a specialized pipeline with function constants for compile-time optimization
    static func buildSpecializedPipeline(device: MTLDevice,
                                         layerRenderer: LayerRenderer,
                                         rasterSampleCount: Int,
                                         mtlVertexDescriptor: MTLVertexDescriptor,
                                         config: FunctionConstantConfig,
                                         fragmentFunctionName: String = "fragmentShader",
                                         coarseWarmStart: Bool = false,
                                         library: MTLLibrary? = nil,
                                         archive: PipelineBinaryArchive? = nil) throws -> MTLRenderPipelineState {
        return try buildRenderPipelineWithDevice(
            device: device,
            layerRenderer: layerRenderer,
            rasterSampleCount: rasterSampleCount,
            mtlVertexDescriptor: mtlVertexDescriptor,
            fragmentFunctionName: fragmentFunctionName,
            functionConstants: config.toMTLConstants(),
            coarseWarmStart: coarseWarmStart,
            library: library,
            archive: archive
        )
    }
}
