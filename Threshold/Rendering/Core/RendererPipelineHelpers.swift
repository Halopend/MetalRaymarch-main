@preconcurrency import CompositorServices
import Metal

extension Renderer {
    static func buildRenderPipelineWithDevice(device: MTLDevice,
                                              layerRenderer: LayerRenderer,
                                              rasterSampleCount: Int,
                                              mtlVertexDescriptor: MTLVertexDescriptor,
                                              colorFormat: MTLPixelFormat? = nil,
                                              vertexFunctionName: String = "vertexShader",
                                              fragmentFunctionName: String = "fragmentShader",
                                              usesVertexAmplification: Bool = true,
                                              functionConstants: MTLFunctionConstantValues? = nil) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = _cachedLibrary ?? device.makeDefaultLibrary()
        if _cachedLibrary == nil { _cachedLibrary = library }

        let vertexFunction = library?.makeFunction(name: vertexFunctionName)

        // IMPORTANT: Once a shader declares function constants, Metal requires using
        // makeFunction(name:constantValues:) even if no values are being set.
        // Always provide function constants (empty if nil) for fragment shaders that use them.
        let fragmentFunction: MTLFunction?
        let constants = functionConstants ?? MTLFunctionConstantValues()
        if fragmentFunctionName == "fragmentShaderQuadShared" {
            // FC_SHARE_SHADOWS (index 10) is declared in shader code but not part
            // of FunctionConstantIndex because it is quad-shared-path-specific.
            // Forcing it on here makes the quad-shared mode materially faster
            // instead of depending on runtime lighting softness heuristics.
            var shareShadows = true
            constants.setConstantValue(&shareShadows, type: .bool, index: 10)
        }
        fragmentFunction = try library?.makeFunction(name: fragmentFunctionName, constantValues: constants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = functionConstants != nil ? "RenderPipeline_Specialized" : "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.rasterSampleCount = rasterSampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat ?? layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = usesVertexAmplification ? layerRenderer.properties.viewCount : 1

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    /// Function constant configuration for shader specialization
    struct FunctionConstantConfig {
        static let disableHighQualityPipeline = true

        var fractalIterations: Int32?      // FC index 0
        var shadowIterations: Int32?       // FC index 1
        var safetyBubbleEnabled: Bool?     // FC index 2
        var qualityMode: Int32?            // FC index 4 (0=high, 1=medium, 2=low)
        var debugHierarchical: Bool?       // FC index 5
        var maxRaySteps: Int32?            // FC index 6 - max ray marching steps
        var fractalType: Int32?            // FC index 7 - devirtualizes FractalDE_Dispatch
        var neonModeEnabled: Bool?         // FC index 8 - eliminates neon orbit tracking
        var colorIterations: Int32?        // FC index 9 - enables loop unrolling in color
        var shadowsEnabled: Bool?          // FC index 11 - GMT-fractals: compile-out shadows entirely
        var mandelbulbPower: Int32?        // FC index 12 - bakes integer power for fastPowR optimization

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

            return constants
        }

        /// Creates a config optimized for high performance (Low quality preset: FI=6, RI=32)
        /// All optional features compiled out for maximum speed.
        static var highPerformance: FunctionConstantConfig {
            return FunctionConstantConfig(
                fractalIterations: 6,
                shadowIterations: 4,
                safetyBubbleEnabled: false,
                qualityMode: 2,  // Low quality
                debugHierarchical: false,
                maxRaySteps: 32,
                neonModeEnabled: false,  // Compile out neon
                colorIterations: 6       // Match fractal iterations
            )
        }

        /// Creates a config for high quality rendering (Ultra quality preset: FI=12, RS=100)
        /// All optional features available.
        static var highQuality: FunctionConstantConfig {
            if disableHighQualityPipeline {
                return .highPerformance
            }

            return FunctionConstantConfig(
                fractalIterations: 12,
                shadowIterations: 10,
                safetyBubbleEnabled: nil,  // Runtime: respects user toggle
                qualityMode: 0,  // High quality
                debugHierarchical: false,
                maxRaySteps: 100,
                neonModeEnabled: nil,    // Runtime (not specialized)
                colorIterations: 12      // Match fractal iterations
            )
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
                fractalIterations: fc.fractalIterations,
                shadowIterations: fc.shadowIterations,
                safetyBubbleEnabled: nil,  // Runtime: respects live safety bubble toggle/radius changes
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
                                         colorFormat: MTLPixelFormat? = nil,
                                         fragmentFunctionName: String = "fragmentShader") throws -> MTLRenderPipelineState {
        return try buildRenderPipelineWithDevice(
            device: device,
            layerRenderer: layerRenderer,
            rasterSampleCount: rasterSampleCount,
            mtlVertexDescriptor: mtlVertexDescriptor,
            colorFormat: colorFormat,
            fragmentFunctionName: fragmentFunctionName,
            functionConstants: config.toMTLConstants()
        )
    }
}
