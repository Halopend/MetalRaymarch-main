//
//  BuddhabrotRenderer.swift
//  Threshold
//
//  Manages the 3D Buddhabrot volume rendering pipeline for Vision Pro.
//
//  Architecture:
//    Phase 1: Compute pass accumulates Mandelbulb orbit density into a 3D uint32 buffer
//             using atomics. Encoded in-order onto the per-frame command buffer.
//    Phase 2: Per-frame normalize density → 3D float texture, then stereo volume ray march
//             via the existing CompositorLayer render pass.
//
//  This class owns all GPU resources for the Buddhabrot mode and is intended to be
//  created and held by the main Renderer actor. It can be swapped in when
//  AppModel.runtimeViewMode == .buddhabrot.
//

import Metal
import simd
#if os(visionOS)
import CompositorServices
#endif
import os

// MARK: - Render Mode

/// Selects between the original volume ray march pipeline and the new Gaussian splat pipeline.
enum BuddhabrotRenderMode: String, CaseIterable, Identifiable {
    case gaussianSplats = "Gaussian Splats"
    case volumeRayMarch = "Volume Ray March"
    var id: String { rawValue }
}

// MARK: - Buddhabrot Settings

/// User-adjustable parameters for the Buddhabrot volume renderer.
/// Thread-safe for cross-thread access (render loop reads, UI writes).
/// Protected by os_unfair_lock — all property access is synchronized.
final class BuddhabrotSettings: @unchecked Sendable {
    private var _lock = os_unfair_lock()

    @inline(__always)
    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }

    // Volume resolution (per axis). 128^3 = 8 MB density buffer.
    private var _resolution: Int = 128
    var resolution: Int {
        get { withLock { _resolution } }
        set { withLock { _resolution = newValue } }
    }

    // Mandelbulb parameters
    private var _power: Float = 8.0
    var power: Float {
        get { withLock { _power } }
        set { withLock { _power = newValue } }
    }

    private var _maxIterations: Int = 100
    var maxIterations: Int {
        get { withLock { _maxIterations } }
        set { withLock { _maxIterations = newValue } }
    }

    private var _bailoutRadius: Float = 4.0
    var bailoutRadius: Float {
        get { withLock { _bailoutRadius } }
        set { withLock { _bailoutRadius = newValue } }
    }
    
    // Iteration bands for RGB Nebulabrot mode
    private var _useRGBMode: Bool = false
    var useRGBMode: Bool {
        get { withLock { _useRGBMode } }
        set { withLock { _useRGBMode = newValue } }
    }

    // Accumulation control
    private var _batchSize: Int = 65536         // Seeds per compute dispatch
    var batchSize: Int {
        get { withLock { _batchSize } }
        set { withLock { _batchSize = newValue } }
    }

    private var _batchesPerFrame: Int = 2       // Dispatches per frame (throttle for thermals)
    var batchesPerFrame: Int {
        get { withLock { _batchesPerFrame } }
        set { withLock { _batchesPerFrame = newValue } }
    }

    private var _normalizationInterval: Int = 4 // Normalize every N frames
    var normalizationInterval: Int {
        get { withLock { _normalizationInterval } }
        set { withLock { _normalizationInterval = newValue } }
    }
    
    // Transfer function
    private var _densityScale: Float = 1.0
    var densityScale: Float {
        get { withLock { _densityScale } }
        set { withLock { _densityScale = newValue } }
    }

    private var _gamma: Float = 0.4
    var gamma: Float {
        get { withLock { _gamma } }
        set { withLock { _gamma = newValue } }
    }

    private var _alphaScale: Float = 8.0
    var alphaScale: Float {
        get { withLock { _alphaScale } }
        set { withLock { _alphaScale = newValue } }
    }
    
    // Palette colors
    private var _colorLow: SIMD3<Float> = SIMD3<Float>(0.02, 0.02, 0.12)  // Deep blue
    var colorLow: SIMD3<Float> {
        get { withLock { _colorLow } }
        set { withLock { _colorLow = newValue } }
    }

    private var _colorMid: SIMD3<Float> = SIMD3<Float>(0.6, 0.2, 0.8)     // Purple
    var colorMid: SIMD3<Float> {
        get { withLock { _colorMid } }
        set { withLock { _colorMid = newValue } }
    }

    private var _colorHigh: SIMD3<Float> = SIMD3<Float>(1.0, 0.95, 0.8)    // Warm white
    var colorHigh: SIMD3<Float> {
        get { withLock { _colorHigh } }
        set { withLock { _colorHigh = newValue } }
    }
    
    // Ray march quality
    private var _maxRaySteps: Int = 80
    var maxRaySteps: Int {
        get { withLock { _maxRaySteps } }
        set { withLock { _maxRaySteps = newValue } }
    }

    private var _earlyExitAlpha: Float = 0.95
    var earlyExitAlpha: Float {
        get { withLock { _earlyExitAlpha } }
        set { withLock { _earlyExitAlpha = newValue } }
    }
    
    // Volume placement (meters from origin, in front of user)
    private var _volumeDistance: Float = 1.5
    var volumeDistance: Float {
        get { withLock { _volumeDistance } }
        set { withLock { _volumeDistance = newValue } }
    }

    private var _volumeScale: Float = 0.6 // Size of volume cube in meters
    var volumeScale: Float {
        get { withLock { _volumeScale } }
        set { withLock { _volumeScale = newValue } }
    }

    private var _autoRotate: Bool = true
    var autoRotate: Bool {
        get { withLock { _autoRotate } }
        set { withLock { _autoRotate = newValue } }
    }

    private var _rotationSpeed: Float = 0.1
    var rotationSpeed: Float {
        get { withLock { _rotationSpeed } }
        set { withLock { _rotationSpeed = newValue } }
    }

    // World extent for orbit accumulation bounding cube
    private var _worldExtent: Float = 2.0
    var worldExtent: Float {
        get { withLock { _worldExtent } }
        set { withLock { _worldExtent = newValue } }
    }
    
    // Render mode
    private var _renderMode: BuddhabrotRenderMode = .gaussianSplats
    var renderMode: BuddhabrotRenderMode {
        get { withLock { _renderMode } }
        set { withLock { _renderMode = newValue } }
    }
    
    // 3D Gaussian splat settings
    private var _maxSplatCount: Int = 524_288    // Ring-buffer capacity (512K, power-of-2 for radix sort)
    var maxSplatCount: Int {
        get { withLock { _maxSplatCount } }
        set { withLock { _maxSplatCount = newValue } }
    }

    private var _splatScaleAlongTangent: Float = 0.04  // Scale along orbit tangent direction
    var splatScaleAlongTangent: Float {
        get { withLock { _splatScaleAlongTangent } }
        set { withLock { _splatScaleAlongTangent = newValue } }
    }

    private var _splatScalePerp: Float = 0.02          // Scale perpendicular to orbit tangent
    var splatScalePerp: Float {
        get { withLock { _splatScalePerp } }
        set { withLock { _splatScalePerp = newValue } }
    }

    private var _splatOpacity: Float = 0.6             // Global opacity multiplier (0–1)
    var splatOpacity: Float {
        get { withLock { _splatOpacity } }
        set { withLock { _splatOpacity = newValue } }
    }

    private var _brightnessScale: Float = 1.0          // Global brightness multiplier
    var brightnessScale: Float {
        get { withLock { _brightnessScale } }
        set { withLock { _brightnessScale = newValue } }
    }
    
    // State
    private var _totalSamplesAccumulated: UInt64 = 0
    var totalSamplesAccumulated: UInt64 {
        get { withLock { _totalSamplesAccumulated } }
        set { withLock { _totalSamplesAccumulated = newValue } }
    }

    private var _needsClear: Bool = false
    private var _clearGeneration: UInt64 = 0
    var needsClear: Bool {
        get { withLock { _needsClear } }
        set {
            withLock {
                if newValue {
                    _clearGeneration &+= 1
                }
                _needsClear = newValue
            }
        }
    }

    func resetAccumulationState() {
        withLock {
            _totalSamplesAccumulated = 0
        }
    }

    func addSamplesAccumulated(_ sampleCount: UInt64) {
        withLock {
            _totalSamplesAccumulated &+= sampleCount
        }
    }

    func clearNeedsClear(ifGeneration generation: UInt64) {
        withLock {
            if _clearGeneration == generation {
                _needsClear = false
            }
        }
    }

    /// Takes a consistent snapshot of all settings under the lock.
    /// Call once per frame from the render thread to avoid per-property locking.
    func snapshot() -> BuddhabrotSettingsSnapshot {
        withLock {
            BuddhabrotSettingsSnapshot(
                resolution: _resolution, power: _power, maxIterations: _maxIterations,
                bailoutRadius: _bailoutRadius, useRGBMode: _useRGBMode,
                batchSize: _batchSize, batchesPerFrame: _batchesPerFrame,
                normalizationInterval: _normalizationInterval,
                densityScale: _densityScale, gamma: _gamma, alphaScale: _alphaScale,
                colorLow: _colorLow, colorMid: _colorMid, colorHigh: _colorHigh,
                maxRaySteps: _maxRaySteps, earlyExitAlpha: _earlyExitAlpha,
                volumeDistance: _volumeDistance, volumeScale: _volumeScale,
                autoRotate: _autoRotate, rotationSpeed: _rotationSpeed,
                worldExtent: _worldExtent,
                totalSamplesAccumulated: _totalSamplesAccumulated,
                needsClear: _needsClear,
                clearGeneration: _clearGeneration,
                renderMode: _renderMode,
                maxSplatCount: _maxSplatCount,
                splatScaleAlongTangent: _splatScaleAlongTangent,
                splatScalePerp: _splatScalePerp,
                splatOpacity: _splatOpacity,
                brightnessScale: _brightnessScale
            )
        }
    }
}

/// Immutable copy of BuddhabrotSettings for use on the render thread.
/// Eliminates per-property locking — one lock acquisition per frame.
struct BuddhabrotSettingsSnapshot {
    let resolution: Int
    let power: Float
    let maxIterations: Int
    let bailoutRadius: Float
    let useRGBMode: Bool
    let batchSize: Int
    let batchesPerFrame: Int
    let normalizationInterval: Int
    let densityScale: Float
    let gamma: Float
    let alphaScale: Float
    let colorLow: SIMD3<Float>
    let colorMid: SIMD3<Float>
    let colorHigh: SIMD3<Float>
    let maxRaySteps: Int
    let earlyExitAlpha: Float
    let volumeDistance: Float
    let volumeScale: Float
    let autoRotate: Bool
    let rotationSpeed: Float
    let worldExtent: Float
    let totalSamplesAccumulated: UInt64
    let needsClear: Bool
    let clearGeneration: UInt64
    let renderMode: BuddhabrotRenderMode
    let maxSplatCount: Int
    let splatScaleAlongTangent: Float
    let splatScalePerp: Float
    let splatOpacity: Float
    let brightnessScale: Float
}

// MARK: - BuddhabrotRenderer

#if os(visionOS)
/// Manages all GPU resources and passes for 3D Buddhabrot volume rendering.
/// Designed to be owned by the main Renderer actor and called from the render loop.
final class BuddhabrotRenderer: @unchecked Sendable {
    
    // MARK: - GPU Resources
    
    private let device: MTLDevice
    private let settings: BuddhabrotSettings
    private let usesLayeredLayout: Bool
    
    // Compute pipelines
    private var accumulatePipeline: MTLComputePipelineState?
    private var accumulateRGBPipeline: MTLComputePipelineState?
    private var normalizePipeline: MTLComputePipelineState?
    private var normalizeRGBPipeline: MTLComputePipelineState?
    private var clearDensityPipeline: MTLComputePipelineState?
    
    // Render pipeline (volume ray march)
    private var rayMarchPipeline: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?
    private var splatDepthStencilState: MTLDepthStencilState?
    
    // Density buffers (Phase 1 output)
    private var densityBuffer: MTLBuffer?              // Single-channel mode
    private var densityBufferR: MTLBuffer?             // RGB mode (short escapes)
    private var densityBufferG: MTLBuffer?             // RGB mode (medium escapes)
    private var densityBufferB: MTLBuffer?             // RGB mode (long escapes)
    
    // 3D volume texture (Phase 2 input)
    private var volumeTexture: MTLTexture?
    
    // Uniform buffers
    private var accumulationUniformBuffer: MTLBuffer?
    private var normalizationUniformBuffer: MTLBuffer?
    private var rayMarchUniformBuffer: MTLBuffer?
    
    // Gaussian splat resources
    private var splatEmitPipeline: MTLComputePipelineState?
    private var clearSplatCounterPipeline: MTLComputePipelineState?
    private var splatRenderPipeline: MTLRenderPipelineState?
    private var splatBuffer: MTLBuffer?                // BuddhabrotSplat array (ring buffer)
    private var atomicCounterBuffer: MTLBuffer?        // Single uint32 atomic counter
    private var splatRenderUniformBuffer: MTLBuffer?   // Per-eye splat render uniforms
    private var currentMaxSplatCount: Int = 0
    
    // 3DGS sort resources
    private var depthKeyPipeline: MTLComputePipelineState?
    private var radixHistogramPipeline: MTLComputePipelineState?
    private var radixPrefixSumPipeline: MTLComputePipelineState?
    private var radixScatterPipeline: MTLComputePipelineState?
    private var sortKeysA: MTLBuffer?                  // RadixSortEntry ping buffer
    private var sortKeysB: MTLBuffer?                  // RadixSortEntry pong buffer
    private var histogramBuffer: MTLBuffer?            // Per-threadgroup histograms
    private var depthKeyUniformBuffer: MTLBuffer?
    private var radixSortUniformBuffer: MTLBuffer?
    
    // State tracking
    private var currentResolution: Int = 0
    private var seedOffset: UInt32 = 0
    private var maxDensityValue: UInt32 = 0
    private var frameCounter: Int = 0
    private var warnedAboutMissingPipelines = false
    private var currentUseRGBMode: Bool = false
    private var volumePlacementAnchorTransform: matrix_float4x4?
    private var volumePlacementAnchorUserPosition: SIMD3<Float>?
    private var volumePlacementAnchorWorldRotation: simd_quatf?
    private var volumePlacementAnchorDetailScale: Float?
    
    // MARK: - Initialization
    
    init?(device: MTLDevice, layerRenderer: LayerRenderer, settings: BuddhabrotSettings) {
        self.device = device
        self.settings = settings
        self.usesLayeredLayout = layerRenderer.configuration.layout == .layered

        // Build compute pipelines
        guard let library = device.makeDefaultLibrary() else {
            print("❌ BuddhabrotRenderer: Failed to load default library")
            return nil
        }
        
        do {
            guard let accumulateFn = library.makeFunction(name: "buddhabrotAccumulate"),
                  let accumulateRGBFn = library.makeFunction(name: "buddhabrotAccumulateRGB"),
                  let normalizeFn = library.makeFunction(name: "buddhabrotNormalize"),
                  let normalizeRGBFn = library.makeFunction(name: "buddhabrotNormalizeRGB"),
                  let clearFn = library.makeFunction(name: "buddhabrotClearDensity") else {
                print("❌ BuddhabrotRenderer: Missing one or more required shader functions in default Metal library")
                return nil
            }

            // Accumulation kernels
            accumulatePipeline = try device.makeComputePipelineState(function: accumulateFn)
            accumulateRGBPipeline = try device.makeComputePipelineState(function: accumulateRGBFn)

            // Normalization kernels
            normalizePipeline = try device.makeComputePipelineState(function: normalizeFn)
            normalizeRGBPipeline = try device.makeComputePipelineState(function: normalizeRGBFn)

            // Clear kernel
            clearDensityPipeline = try device.makeComputePipelineState(function: clearFn)
            
            // Gaussian splat compute kernels
            guard let emitFn = library.makeFunction(name: "buddhabrotEmitSplats"),
                  let clearCounterFn = library.makeFunction(name: "buddhabrotClearSplatCounter") else {
                print("❌ BuddhabrotRenderer: Missing splat emit/clear shader functions")
                return nil
            }
            splatEmitPipeline = try device.makeComputePipelineState(function: emitFn)
            clearSplatCounterPipeline = try device.makeComputePipelineState(function: clearCounterFn)
            
            // 3DGS sort compute kernels
            guard let depthKeyFn = library.makeFunction(name: "buddhabrotComputeDepthKeys"),
                  let histogramFn = library.makeFunction(name: "radixHistogram"),
                  let prefixSumFn = library.makeFunction(name: "radixPrefixSum"),
                  let scatterFn = library.makeFunction(name: "radixScatter") else {
                print("❌ BuddhabrotRenderer: Missing 3DGS sort shader functions")
                return nil
            }
            depthKeyPipeline = try device.makeComputePipelineState(function: depthKeyFn)
            radixHistogramPipeline = try device.makeComputePipelineState(function: histogramFn)
            radixPrefixSumPipeline = try device.makeComputePipelineState(function: prefixSumFn)
            radixScatterPipeline = try device.makeComputePipelineState(function: scatterFn)
        } catch {
            print("❌ BuddhabrotRenderer: Failed to build compute pipelines: \(error)")
            return nil
        }
        
        // Build ray march render pipeline
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Buddhabrot Volume Ray March"
                        guard let vertexFn = library.makeFunction(name: "buddhabrotVertex"),
                                    let fragmentFn = library.makeFunction(name: "buddhabrotFragment") else {
                                print("❌ BuddhabrotRenderer: Missing buddhabrotVertex or buddhabrotFragment shader")
                                return nil
                        }
                        desc.vertexFunction = vertexFn
                        desc.fragmentFunction = fragmentFn

                        // Match compositor layer formats exactly.
                        desc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
            // Premultiplied alpha blending over the pass-through / background
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

                        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
            
            // Stereo support via vertex amplification
            desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
            desc.inputPrimitiveTopology = .triangle
            
            // Input assembly: full-screen triangle uses vertex_id, no vertex buffer
            // so no vertex descriptor needed.
            
            rayMarchPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("❌ BuddhabrotRenderer: Failed to build ray march pipeline: \(error)")
            return nil
        }
        
        // Build 3DGS render pipeline (alpha-over compositing, depth-sorted)
        do {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Buddhabrot 3D Gaussian Splat"
            guard let splatVertexFn = library.makeFunction(name: "buddhabrotSplatVertex"),
                  let splatFragmentFn = library.makeFunction(name: "buddhabrotSplatFragment") else {
                print("❌ BuddhabrotRenderer: Missing buddhabrotSplatVertex or buddhabrotSplatFragment shader")
                return nil
            }
            desc.vertexFunction = splatVertexFn
            desc.fragmentFunction = splatFragmentFn
            desc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
            
            // Alpha-over (premultiplied): proper back-to-front compositing
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
            desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
            desc.inputPrimitiveTopology = .triangle
            
            splatRenderPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("❌ BuddhabrotRenderer: Failed to build splat render pipeline: \(error)")
            return nil
        }
        
        // Build depth stencil state
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .greaterEqual // visionOS uses reverse-Z
        depthDesc.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)

        let splatDepthDesc = MTLDepthStencilDescriptor()
        splatDepthDesc.depthCompareFunction = .always   // Manually sorted, no depth test
        splatDepthDesc.isDepthWriteEnabled = false       // Transparent splats don't write depth
        splatDepthStencilState = device.makeDepthStencilState(descriptor: splatDepthDesc)
        
        // Allocate uniform buffers
        let accUniSize = MemoryLayout<BuddhabrotAccumulationUniforms>.stride
        accumulationUniformBuffer = device.makeBuffer(length: accUniSize, options: .storageModeShared)
        accumulationUniformBuffer?.label = "Buddhabrot Accumulation Uniforms"
        
        let normUniSize = MemoryLayout<BuddhabrotNormalizationUniforms>.stride
        normalizationUniformBuffer = device.makeBuffer(length: normUniSize, options: .storageModeShared)
        normalizationUniformBuffer?.label = "Buddhabrot Normalization Uniforms"
        
        let rmUniSize = MemoryLayout<BuddhabrotRayMarchUniformsArray>.stride
        rayMarchUniformBuffer = device.makeBuffer(length: rmUniSize, options: .storageModeShared)
        rayMarchUniformBuffer?.label = "Buddhabrot Ray March Uniforms"
        
        // Splat uniform buffers
        let splatRenderUniSize = MemoryLayout<BuddhabrotSplatRenderUniformsArray>.stride
        splatRenderUniformBuffer = device.makeBuffer(length: splatRenderUniSize, options: .storageModeShared)
        splatRenderUniformBuffer?.label = "Buddhabrot Splat Render Uniforms"
        
        // Atomic counter for splat append (single uint32)
        atomicCounterBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
        atomicCounterBuffer?.label = "Buddhabrot Splat Counter"
        atomicCounterBuffer?.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        
        // 3DGS sort uniform buffers
        let depthKeyUniSize = MemoryLayout<DepthKeyUniforms>.stride
        depthKeyUniformBuffer = device.makeBuffer(length: depthKeyUniSize, options: .storageModeShared)
        depthKeyUniformBuffer?.label = "Buddhabrot Depth Key Uniforms"
        
        let radixUniSize = MemoryLayout<RadixSortUniforms>.stride
        radixSortUniformBuffer = device.makeBuffer(length: radixUniSize, options: .storageModeShared)
        radixSortUniformBuffer?.label = "Buddhabrot Radix Sort Uniforms"
        
        let initialSettings = settings.snapshot()

        // Allocate density buffers and volume texture at current resolution
        reallocateResources(resolution: initialSettings.resolution, useRGBMode: initialSettings.useRGBMode)

        // Allocate splat buffer at current capacity
        reallocateSplatResources(maxSplatCount: initialSettings.maxSplatCount)
    }
    
    // MARK: - Resource Management
    
    /// Reallocates the density buffer and 3D texture when resolution changes.
    func reallocateResources(resolution: Int, useRGBMode: Bool) {
        guard resolution != currentResolution || useRGBMode != currentUseRGBMode else { return }
        currentResolution = resolution
        currentUseRGBMode = useRGBMode
        
        let voxelCount = resolution * resolution * resolution
        let bufferSize = voxelCount * MemoryLayout<UInt32>.size
        
        // Density buffer(s) — storageModeShared for CPU readback of max density
        densityBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        densityBuffer?.label = "Buddhabrot Density"
        
        if useRGBMode {
            densityBufferR = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            densityBufferR?.label = "Buddhabrot Density R"
            densityBufferG = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            densityBufferG?.label = "Buddhabrot Density G"
            densityBufferB = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            densityBufferB?.label = "Buddhabrot Density B"
            densityBuffer = nil
        } else {
            densityBufferR = nil
            densityBufferG = nil
            densityBufferB = nil
        }
        
        // 3D float texture for normalized volume
        let texDesc = MTLTextureDescriptor()
        texDesc.textureType = .type3D
        texDesc.pixelFormat = useRGBMode ? .rgba16Float : .r16Float
        texDesc.width = resolution
        texDesc.height = resolution
        texDesc.depth = resolution
        texDesc.usage = [.shaderRead, .shaderWrite]
        texDesc.storageMode = .private  // GPU-only for best performance
        volumeTexture = device.makeTexture(descriptor: texDesc)
        volumeTexture?.label = "Buddhabrot Volume 3D"
        
        // Reset accumulation state
        seedOffset = 0
        maxDensityValue = 0
        settings.resetAccumulationState()
    }
    
    /// Reallocates the splat ring buffer and sort workspace when capacity changes.
    func reallocateSplatResources(maxSplatCount: Int) {
        guard maxSplatCount != currentMaxSplatCount else { return }
        currentMaxSplatCount = maxSplatCount
        
        let bufferSize = maxSplatCount * MemoryLayout<BuddhabrotSplat>.stride
        splatBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        splatBuffer?.label = "Buddhabrot Splat Buffer"
        
        // Sort key buffers (ping-pong): RadixSortEntry = 8 bytes each
        let sortEntrySize = maxSplatCount * MemoryLayout<RadixSortEntry>.stride
        sortKeysA = device.makeBuffer(length: sortEntrySize, options: .storageModeShared)
        sortKeysA?.label = "Buddhabrot Sort Keys A"
        sortKeysB = device.makeBuffer(length: sortEntrySize, options: .storageModeShared)
        sortKeysB?.label = "Buddhabrot Sort Keys B"
        
        // Histogram buffer: 256 bins × numThreadgroups × sizeof(uint32)
        // numThreadgroups = ceil(maxSplatCount / 256)
        let numTG = (maxSplatCount + 255) / 256
        let histSize = 256 * numTG * MemoryLayout<UInt32>.stride
        histogramBuffer = device.makeBuffer(length: histSize, options: .storageModeShared)
        histogramBuffer?.label = "Buddhabrot Radix Histogram"
        
        // Reset counter
        atomicCounterBuffer?.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        seedOffset = 0
        settings.resetAccumulationState()
        
    }
    
    // MARK: - Phase 1: Orbit Accumulation
    
    /// In-order accumulation encoded onto the frame command buffer.
    /// This guarantees normalization sees fresh density data in the same frame.
    func encodeAccumulation(commandBuffer: MTLCommandBuffer, buddhabrotSnapshot: BuddhabrotSettingsSnapshot) {
        let needsResourceReset = buddhabrotSnapshot.resolution != currentResolution || buddhabrotSnapshot.useRGBMode != currentUseRGBMode || buddhabrotSnapshot.needsClear

        if needsResourceReset {
            reallocateResources(resolution: buddhabrotSnapshot.resolution, useRGBMode: buddhabrotSnapshot.useRGBMode)
        }

        if needsResourceReset {
            guard encodeDensityClear(commandBuffer: commandBuffer) else { return }
            settings.clearNeedsClear(ifGeneration: buddhabrotSnapshot.clearGeneration)
        }

        guard let pipeline = buddhabrotSnapshot.useRGBMode ? accumulateRGBPipeline : accumulatePipeline else {
            return
        }

        let batchSize = max(1, buddhabrotSnapshot.batchSize)
        let batchesPerFrame = max(1, buddhabrotSnapshot.batchesPerFrame)

        for _ in 0..<batchesPerFrame {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.label = "Buddhabrot Orbit Batch (In-Frame)"
            encoder.setComputePipelineState(pipeline)

            var uniforms = BuddhabrotAccumulationUniforms()
            uniforms.resolution = UInt32(currentResolution)
            uniforms.maxIterations = UInt32(buddhabrotSnapshot.maxIterations)
            uniforms.minIterations = 0
            uniforms.batchSize = UInt32(batchSize)
            uniforms.seedOffset = seedOffset
            uniforms.escapeRadius = buddhabrotSnapshot.bailoutRadius * buddhabrotSnapshot.bailoutRadius
            uniforms.worldExtent = buddhabrotSnapshot.worldExtent
            uniforms.power = buddhabrotSnapshot.power
            uniforms.bailoutRadius = buddhabrotSnapshot.bailoutRadius

            encoder.setBytes(&uniforms, length: MemoryLayout<BuddhabrotAccumulationUniforms>.stride, index: 0)

            if buddhabrotSnapshot.useRGBMode {
                guard let r = densityBufferR, let g = densityBufferG, let b = densityBufferB else {
                    encoder.endEncoding()
                    continue
                }
                encoder.setBuffer(r, offset: 0, index: 1)
                encoder.setBuffer(g, offset: 0, index: 2)
                encoder.setBuffer(b, offset: 0, index: 3)
            } else {
                guard let density = densityBuffer else {
                    encoder.endEncoding()
                    continue
                }
                encoder.setBuffer(density, offset: 0, index: 1)
            }

            let threadsPerGrid = MTLSize(width: batchSize, height: 1, depth: 1)
            let threadgroupSize = MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()

            seedOffset &+= 1
        }

        settings.addSamplesAccumulated(UInt64(batchSize * batchesPerFrame))
    }
    
    // MARK: - Phase 2a: Normalization
    
    /// Normalizes the density buffer into the 3D float texture.
    /// Call every N frames (not every frame) to save GPU cycles.
    func encodeNormalization(commandBuffer: MTLCommandBuffer, buddhabrotSnapshot: BuddhabrotSettingsSnapshot) {
        guard let normPipeline = buddhabrotSnapshot.useRGBMode ? normalizeRGBPipeline : normalizePipeline,
              let uniformBuffer = normalizationUniformBuffer,
              let volumeTex = volumeTexture else {
            return
        }
        
        // Scan for max density on CPU (fast enough for 128^3 at normalization interval)
        updateMaxDensity(useRGBMode: buddhabrotSnapshot.useRGBMode)
        // Fill normalization uniforms
        let uniforms = uniformBuffer.contents().bindMemory(to: BuddhabrotNormalizationUniforms.self, capacity: 1)
        uniforms.pointee.resolution = UInt32(currentResolution)
        uniforms.pointee.densityScale = buddhabrotSnapshot.densityScale
        uniforms.pointee.gamma = buddhabrotSnapshot.gamma
        uniforms.pointee.logBase = 1.0
        uniforms.pointee.maxDensity = max(maxDensityValue, 1)
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Buddhabrot Normalize"
        encoder.setComputePipelineState(normPipeline)
        
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        
        if buddhabrotSnapshot.useRGBMode {
            encoder.setBuffer(densityBufferR, offset: 0, index: 1)
            encoder.setBuffer(densityBufferG, offset: 0, index: 2)
            encoder.setBuffer(densityBufferB, offset: 0, index: 3)
        } else {
            encoder.setBuffer(densityBuffer, offset: 0, index: 1)
        }
        
        encoder.setTexture(volumeTex, index: 0)
        
        let res = currentResolution
        let threadgroupSize = MTLSize(width: 8, height: 4, depth: 4)  // 128 threads — better Apple Silicon occupancy
        let gridSize = MTLSize(width: res, height: res, depth: res)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        
        encoder.endEncoding()
    }
    
    // MARK: - Phase 2b: Volume Ray March Rendering
    
    /// Encodes the stereo volume ray march render pass.
    /// Call this from the main render frame when in Buddhabrot mode.
    @discardableResult
    func encodeRayMarch(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        time: Float,
        settingsSnapshot: RenderSettingsSnapshot,
        buddhabrotSnapshot: BuddhabrotSettingsSnapshot
    ) -> Bool {
        guard let pipeline = rayMarchPipeline,
              let depthState = depthStencilState,
              let volumeTex = volumeTexture,
              let uniformBuffer = rayMarchUniformBuffer else {
            if !warnedAboutMissingPipelines {
                warnedAboutMissingPipelines = true
                print("⚠️ Buddhabrot: Missing render resources (pipeline/texture/uniforms)")
            }
            return false
        }

        // Build per-eye uniforms
        let uniformsPtr = uniformBuffer.contents().bindMemory(to: BuddhabrotRayMarchUniformsArray.self, capacity: 1)
        
        // Volume world transform (shared helper handles placement, gestures, auto-rotation)
        let volumeWorld = buildVolumeWorldMatrix(
            drawable: drawable,
            time: time,
            settingsSnapshot: settingsSnapshot,
            buddhabrotSnapshot: buddhabrotSnapshot
        )
        let invVolumeWorld = volumeWorld.inverse
        
        // Use live pose for per-eye view matrices (head-tracked rendering)
        let liveDeviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let ext = buddhabrotSnapshot.worldExtent
        
        for viewIndex in 0..<drawable.views.count {
            let view = drawable.views[viewIndex]
            let viewTransform = (liveDeviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            
            var u = BuddhabrotRayMarchUniforms()
            u.viewMatrix = viewTransform
            u.projectionMatrix = projection
            u.inverseViewMatrix = viewTransform.inverse
            u.inverseProjectionMatrix = projection.inverse
            u.volumeWorldMatrix = volumeWorld
            u.inverseVolumeWorldMatrix = invVolumeWorld
            u.volumeMin = SIMD3<Float>(-ext, -ext, -ext)
            u.worldExtent = ext
            u.volumeMax = SIMD3<Float>(ext, ext, ext)
            u.stepSize = (ext * 2.0) / Float(buddhabrotSnapshot.maxRaySteps)
            u.colorLow = buddhabrotSnapshot.colorLow
            u.densityScale = buddhabrotSnapshot.densityScale
            u.colorMid = buddhabrotSnapshot.colorMid
            u.alphaScale = buddhabrotSnapshot.alphaScale
            u.colorHigh = buddhabrotSnapshot.colorHigh
            u.gamma = buddhabrotSnapshot.gamma
            u.maxSteps = UInt32(buddhabrotSnapshot.maxRaySteps)
            u.earlyExitAlpha = buddhabrotSnapshot.earlyExitAlpha
            u.time = time
            u.pad = 0
            
            // C fixed-size array `uniforms[2]` imports as a tuple in Swift.
            // Use withUnsafeMutablePointer to index into it generically.
            withUnsafeMutablePointer(to: &uniformsPtr.pointee.uniforms) { tuplePtr in
                let base = UnsafeMutableRawPointer(tuplePtr)
                    .assumingMemoryBound(to: BuddhabrotRayMarchUniforms.self)
                base[viewIndex] = u
            }
        }
        
        // Configure render pass to draw into the drawable's color/depth textures
        let renderPassDesc = MTLRenderPassDescriptor()
        
        renderPassDesc.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDesc.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDesc.depthAttachment.loadAction = .clear
        renderPassDesc.depthAttachment.storeAction = .store
        renderPassDesc.depthAttachment.clearDepth = 0.0 // Reverse-Z: near=1, far=0
        
        // Apply the system foveated rasterization rate map so the compositor
        // correctly reconstructs the per-eye images. Without this the pixel
        // layout doesn't match what the compositor expects and stereo breaks.
        if let systemRateMap = drawable.rasterizationRateMaps.first {
            renderPassDesc.rasterizationRateMap = systemRateMap
        }
        
        // Use layered rendering for stereo
        if usesLayeredLayout {
            renderPassDesc.renderTargetArrayLength = drawable.views.count
        }
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return false
        }
        encoder.label = "Buddhabrot Volume Ray March"
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        
        // Set viewports for stereo
        let viewports: [MTLViewport] = drawable.views.map { $0.textureMap.viewport }
        encoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        // Bind uniforms and volume texture
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(volumeTex, index: 0)
        
        // Draw full-screen triangle (3 vertices, no index buffer)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        
        encoder.endEncoding()
        return true
    }
    
    // MARK: - Gaussian Splat: Orbit Emission
    
    /// Dispatches the splat emission compute kernel: runs Mandelbulb orbits and appends
    /// escaped orbit points to the splat ring buffer with GPU-side transfer function coloring.
    func encodeSplatEmission(commandBuffer: MTLCommandBuffer, buddhabrotSnapshot: BuddhabrotSettingsSnapshot) {
        // Reallocate if capacity changed
        if buddhabrotSnapshot.maxSplatCount != currentMaxSplatCount {
            reallocateSplatResources(maxSplatCount: buddhabrotSnapshot.maxSplatCount)
        }
        
        // Clear on parameter change
        if buddhabrotSnapshot.needsClear {
            encodeSplatClear(commandBuffer: commandBuffer)
            settings.clearNeedsClear(ifGeneration: buddhabrotSnapshot.clearGeneration)
        }
        
        guard let pipeline = splatEmitPipeline,
              let splatBuf = splatBuffer,
              let counterBuf = atomicCounterBuffer else { return }
        
        let batchSize = max(1, buddhabrotSnapshot.batchSize)
        let batchesPerFrame = max(1, buddhabrotSnapshot.batchesPerFrame)
        
        for _ in 0..<batchesPerFrame {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.label = "Buddhabrot Splat Emit"
            encoder.setComputePipelineState(pipeline)
            
            var uniforms = BuddhabrotEmitUniforms()
            uniforms.maxIterations = UInt32(buddhabrotSnapshot.maxIterations)
            uniforms.batchSize = UInt32(batchSize)
            uniforms.seedOffset = seedOffset
            uniforms.escapeRadius = buddhabrotSnapshot.bailoutRadius * buddhabrotSnapshot.bailoutRadius
            uniforms.worldExtent = buddhabrotSnapshot.worldExtent
            uniforms.power = buddhabrotSnapshot.power
            uniforms.bailoutRadius = buddhabrotSnapshot.bailoutRadius
            uniforms.maxSplatCount = UInt32(currentMaxSplatCount)
            uniforms.colorLow = buddhabrotSnapshot.colorLow
            uniforms.colorMid = buddhabrotSnapshot.colorMid
            uniforms.colorHigh = buddhabrotSnapshot.colorHigh
            
            encoder.setBytes(&uniforms, length: MemoryLayout<BuddhabrotEmitUniforms>.stride, index: 0)
            encoder.setBuffer(splatBuf, offset: 0, index: 1)
            encoder.setBuffer(counterBuf, offset: 0, index: 2)
            
            let threadsPerGrid = MTLSize(width: batchSize, height: 1, depth: 1)
            let threadgroupSize = MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
            
            seedOffset &+= 1
        }
        
        settings.addSamplesAccumulated(UInt64(batchSize * batchesPerFrame))
    }
    
    /// Resets the splat counter (and effectively the ring buffer).
    private func encodeSplatClear(commandBuffer: MTLCommandBuffer) {
        guard let pipeline = clearSplatCounterPipeline,
              let counterBuf = atomicCounterBuffer else { return }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Buddhabrot Clear Splat Counter"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(counterBuf, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        
        // Also zero the shared buffer on the CPU side so the direct read in
        // renderFrame sees 0 immediately (the GPU clear runs later).
        counterBuf.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        
        seedOffset = 0
        settings.resetAccumulationState()
    }
    
    // MARK: - 3DGS: Depth Key Computation
    
    /// Computes view-space depth keys for all active splats using the left-eye view matrix.
    /// The sort order is shared by both eyes — acceptable since eye separation is small.
    private func encodeDepthKeys(
        commandBuffer: MTLCommandBuffer,
        volumeWorldMatrix: matrix_float4x4,
        viewMatrix: matrix_float4x4,
        activeSplatCount: Int
    ) {
        guard let pipeline = depthKeyPipeline,
              let splatBuf = splatBuffer,
              let sortBuf = sortKeysA,
              let uniformBuf = depthKeyUniformBuffer else { return }
        
        let uniformsPtr = uniformBuf.contents().bindMemory(to: DepthKeyUniforms.self, capacity: 1)
        uniformsPtr.pointee.viewMatrix = viewMatrix
        uniformsPtr.pointee.volumeWorldMatrix = volumeWorldMatrix
        uniformsPtr.pointee.activeSplatCount = UInt32(activeSplatCount)
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Buddhabrot Depth Keys"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(splatBuf, offset: 0, index: 0)
        encoder.setBuffer(sortBuf, offset: 0, index: 1)
        encoder.setBuffer(uniformBuf, offset: 0, index: 2)
        
        let threadsPerGrid = MTLSize(width: activeSplatCount, height: 1, depth: 1)
        let tgSize = MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
    }
    
    // MARK: - 3DGS: GPU Radix Sort (4 passes)
    
    /// Performs a 4-pass GPU radix sort on the depth keys in sortKeysA.
    /// After completion, sorted entries are in sortKeysA (even pass count).
    private func encodeRadixSort(
        commandBuffer: MTLCommandBuffer,
        activeSplatCount: Int
    ) {
        guard let histPipeline = radixHistogramPipeline,
              let prefixPipeline = radixPrefixSumPipeline,
              let scatterPipeline = radixScatterPipeline,
              let histBuf = histogramBuffer,
              let uniformBuf = radixSortUniformBuffer,
              var bufA = sortKeysA,
              var bufB = sortKeysB else { return }
        
        let threadsPerGroup = min(256, histPipeline.maxTotalThreadsPerThreadgroup)
        let numThreadgroups = (activeSplatCount + threadsPerGroup - 1) / threadsPerGroup
        
        // 4 passes: process bits 0-7, 8-15, 16-23, 24-31
        for pass in 0..<4 {
            let bitOffset = UInt32(pass * 8)
            
            // Fill uniforms
            let uniformsPtr = uniformBuf.contents().bindMemory(to: RadixSortUniforms.self, capacity: 1)
            uniformsPtr.pointee.activeSplatCount = UInt32(activeSplatCount)
            uniformsPtr.pointee.bitOffset = bitOffset
            uniformsPtr.pointee.numThreadgroups = UInt32(numThreadgroups)
            
            // Pass 1: Histogram
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.label = "Radix Histogram Pass \(pass)"
                encoder.setComputePipelineState(histPipeline)
                encoder.setBuffer(bufA, offset: 0, index: 0)
                encoder.setBuffer(histBuf, offset: 0, index: 1)
                encoder.setBuffer(uniformBuf, offset: 0, index: 2)
                encoder.dispatchThreads(
                    MTLSize(width: activeSplatCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
                )
                encoder.endEncoding()
            }
            
            // Pass 2: Prefix Sum (single thread scans all histograms)
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.label = "Radix Prefix Sum Pass \(pass)"
                encoder.setComputePipelineState(prefixPipeline)
                encoder.setBuffer(histBuf, offset: 0, index: 0)
                encoder.setBuffer(uniformBuf, offset: 0, index: 1)
                encoder.dispatchThreads(
                    MTLSize(width: 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
                )
                encoder.endEncoding()
            }
            
            // Pass 3: Scatter (read from bufA, write to bufB)
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.label = "Radix Scatter Pass \(pass)"
                encoder.setComputePipelineState(scatterPipeline)
                encoder.setBuffer(bufA, offset: 0, index: 0)
                encoder.setBuffer(bufB, offset: 0, index: 1)
                encoder.setBuffer(histBuf, offset: 0, index: 2)
                encoder.setBuffer(uniformBuf, offset: 0, index: 3)
                encoder.dispatchThreads(
                    MTLSize(width: activeSplatCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
                )
                encoder.endEncoding()
            }
            
            // Ping-pong: swap buffers for next pass
            swap(&bufA, &bufB)
        }
        
        // After 4 passes (even), result is back in the original bufA.
        // Since we swapped after each pass, the final sorted data is in
        // whichever buffer bufA now points to. We need to ensure sortKeysA
        // holds the result. After 4 swaps, bufA == sortKeysA again.
        // (pass 0: A→B, swap → bufA=B,bufB=A; pass 1: B→A, swap → bufA=A,bufB=B;
        //  pass 2: A→B, swap → bufA=B,bufB=A; pass 3: B→A, swap → bufA=A,bufB=B)
        // Result: bufA == sortKeysA ✓
    }
    
    // MARK: - 3DGS: Sorted Gaussian Render
    
    /// Encodes the 3D Gaussian splat render pass with depth-sorted alpha-over compositing.
    @discardableResult
    func encode3DGSRender(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        time: Float,
        settingsSnapshot: RenderSettingsSnapshot,
        buddhabrotSnapshot: BuddhabrotSettingsSnapshot,
        volumeWorldMatrix: matrix_float4x4,
        activeSplatCount: Int
    ) -> Bool {
        guard let pipeline = splatRenderPipeline,
              let depthState = splatDepthStencilState,
              let splatBuf = splatBuffer,
              let sortBuf = sortKeysA,
              let uniformBuf = splatRenderUniformBuffer else {
            return false
        }

        let liveDeviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        // Fill per-eye uniforms
        let uniformsPtr = uniformBuf.contents().bindMemory(to: BuddhabrotSplatRenderUniformsArray.self, capacity: 1)
        
        for viewIndex in 0..<drawable.views.count {
            let view = drawable.views[viewIndex]
            let viewTransform = (liveDeviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            let viewport = view.textureMap.viewport
            
            var u = BuddhabrotSplatRenderUniforms()
            u.viewMatrix = viewTransform
            u.projectionMatrix = projection
            u.volumeWorldMatrix = volumeWorldMatrix
            u.splatScaleAlongTangent = buddhabrotSnapshot.splatScaleAlongTangent
            u.splatScalePerp = buddhabrotSnapshot.splatScalePerp
            u.opacity = buddhabrotSnapshot.splatOpacity
            u.activeSplatCount = UInt32(activeSplatCount)
            u.time = time
            u.brightnessScale = buddhabrotSnapshot.brightnessScale
            u.viewportWidth = Float(viewport.width)
            u.viewportHeight = Float(viewport.height)
            
            withUnsafeMutablePointer(to: &uniformsPtr.pointee.uniforms) { tuplePtr in
                let base = UnsafeMutableRawPointer(tuplePtr)
                    .assumingMemoryBound(to: BuddhabrotSplatRenderUniforms.self)
                base[viewIndex] = u
            }
        }
        
        // Configure render pass
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDesc.depthAttachment.texture = drawable.depthTextures[0]
        renderPassDesc.depthAttachment.loadAction = .clear
        renderPassDesc.depthAttachment.storeAction = .store
        renderPassDesc.depthAttachment.clearDepth = 0.0 // Reverse-Z: near=1, far=0
        
        if let systemRateMap = drawable.rasterizationRateMaps.first {
            renderPassDesc.rasterizationRateMap = systemRateMap
        }
        
        if usesLayeredLayout {
            renderPassDesc.renderTargetArrayLength = drawable.views.count
        }
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return false
        }
        encoder.label = "Buddhabrot 3DGS Render"
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        
        let viewports: [MTLViewport] = drawable.views.map { $0.textureMap.viewport }
        encoder.setViewports(viewports)
        
        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        // Bind uniforms, sorted index buffer, and splat data buffer
        encoder.setVertexBuffer(uniformBuf, offset: 0, index: 0)
        encoder.setVertexBuffer(sortBuf, offset: 0, index: 1)   // Sorted RadixSortEntry array
        encoder.setVertexBuffer(splatBuf, offset: 0, index: 2)   // Raw splat data
        
        // Instanced draw: 6 vertices per quad (2 triangles), one instance per splat
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: activeSplatCount)
        
        encoder.endEncoding()
        return true
    }

    // MARK: - Full Frame (Accumulation + Normalize + Ray March)
    
    /// Presents a transparent clear frame so the compositor shows passthrough
    /// without falling through to the fractal renderer.
    private func encodeClearFrame(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable
    ) -> Bool {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = drawable.colorTextures[0]
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        desc.depthAttachment.texture = drawable.depthTextures[0]
        desc.depthAttachment.loadAction = .clear
        desc.depthAttachment.storeAction = .store
        desc.depthAttachment.clearDepth = 0.0
        if let rateMap = drawable.rasterizationRateMaps.first {
            desc.rasterizationRateMap = rateMap
        }
        if usesLayeredLayout {
            desc.renderTargetArrayLength = drawable.views.count
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else {
            return false
        }
        encoder.label = "Buddhabrot Clear Frame"
        encoder.endEncoding()
        return true
    }
    
    /// Convenience: runs the complete Buddhabrot pipeline for one frame.
    /// Returns true if rendering was successful.
    func renderFrame(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        time: Float,
        settingsSnapshot: RenderSettingsSnapshot
    ) -> Bool {
        frameCounter += 1
        let buddhabrotSnapshot = settings.snapshot()
        
        switch buddhabrotSnapshot.renderMode {
        case .gaussianSplats:
            // 3DGS pipeline: emit → depth keys → radix sort → render sorted Gaussians
            encodeSplatEmission(commandBuffer: commandBuffer, buddhabrotSnapshot: buddhabrotSnapshot)
            
            // Read the splat count directly from the shared atomic counter buffer.
            // The counter was written by *previous* frame GPU work (already completed)
            // and is in a .storageModeShared buffer readable by the CPU,
            // which eliminates the 1-frame lag on startup.
            let activeSplatCount: Int
            if let counterBuf = atomicCounterBuffer {
                let gpuCount = Int(counterBuf.contents().load(as: UInt32.self))
                activeSplatCount = min(gpuCount, currentMaxSplatCount)
            } else {
                activeSplatCount = 0
            }
            
            // If no splats yet (first frame or just cleared), present a transparent
            // frame so the compositor doesn't fall through to the fractal renderer.
            guard activeSplatCount > 0 else {
                return encodeClearFrame(commandBuffer: commandBuffer, drawable: drawable)
            }
            
            // Compute volume world transform (shared across all passes)
            let volumeWorld = buildVolumeWorldMatrix(
                drawable: drawable,
                time: time,
                settingsSnapshot: settingsSnapshot,
                buddhabrotSnapshot: buddhabrotSnapshot
            )
            
            // Left-eye view matrix for depth sorting
            let liveDeviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            let leftEyeView = (liveDeviceTransform * drawable.views[0].transform).inverse
            
            // Depth keys + sort
            encodeDepthKeys(
                commandBuffer: commandBuffer,
                volumeWorldMatrix: volumeWorld,
                viewMatrix: leftEyeView,
                activeSplatCount: activeSplatCount
            )
            encodeRadixSort(commandBuffer: commandBuffer, activeSplatCount: activeSplatCount)
            
            // Render sorted Gaussians
            return encode3DGSRender(
                commandBuffer: commandBuffer,
                drawable: drawable,
                time: time,
                settingsSnapshot: settingsSnapshot,
                buddhabrotSnapshot: buddhabrotSnapshot,
                volumeWorldMatrix: volumeWorld,
                activeSplatCount: activeSplatCount
            )
            
        case .volumeRayMarch:
            // Original pipeline: accumulate → normalize → ray march
            encodeAccumulation(commandBuffer: commandBuffer, buddhabrotSnapshot: buddhabrotSnapshot)
            
            let normalizationEvery = max(1, buddhabrotSnapshot.normalizationInterval)
            if frameCounter <= 120 || frameCounter % normalizationEvery == 0 {
                encodeNormalization(commandBuffer: commandBuffer, buddhabrotSnapshot: buddhabrotSnapshot)
            }
            
            return encodeRayMarch(
                commandBuffer: commandBuffer,
                drawable: drawable,
                time: time,
                settingsSnapshot: settingsSnapshot,
                buddhabrotSnapshot: buddhabrotSnapshot
            )
        }
    }
    
    // MARK: - Density Buffer Utilities
    
    /// Encodes a density-buffer clear into the given command buffer.
    /// Keeping the clear on the same command buffer as subsequent accumulation
    /// preserves GPU ordering without a CPU-side wait.
    @discardableResult
    private func encodeDensityClear(commandBuffer: MTLCommandBuffer) -> Bool {
        guard let clearPipeline = clearDensityPipeline else { return false }
        let useRGBMode = currentUseRGBMode
        
        let voxelCount = currentResolution * currentResolution * currentResolution
        let buffers: [MTLBuffer?] = useRGBMode
            ? [densityBufferR, densityBufferG, densityBufferB]
            : [densityBuffer]
        
        for buffer in buffers {
            guard let buf = buffer,
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(clearPipeline)
            encoder.setBuffer(buf, offset: 0, index: 0)
            
            var size = UInt32(voxelCount)
            encoder.setBytes(&size, length: MemoryLayout<UInt32>.size, index: 1)
            
            let threads = MTLSize(width: voxelCount, height: 1, depth: 1)
            let tgSize = MTLSize(width: min(256, clearPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            encoder.dispatchThreads(threads, threadsPerThreadgroup: tgSize)
            encoder.endEncoding()
        }

        seedOffset = 0
        maxDensityValue = 0
        settings.resetAccumulationState()

        return true
    }
    
    /// Scans the density buffer to find the current maximum value.
    /// Used for adaptive normalization. Fast enough on CPU for 128^3 at low frequency.
    private func updateMaxDensity(useRGBMode: Bool) {
        let primaryBuffer: MTLBuffer?
        if useRGBMode {
            // For RGB, scan all three buffers and take the max
            primaryBuffer = densityBufferR // Just use R for now as representative
        } else {
            primaryBuffer = densityBuffer
        }
        
        guard let buffer = primaryBuffer else { return }
        
        let voxelCount = currentResolution * currentResolution * currentResolution
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: voxelCount)
        
        var maxVal: UInt32 = 0
        // In early frames, do a full scan so we can quickly detect real accumulation.
        // After warmup, fall back to sampling for lower CPU cost.
        let sampleStride = frameCounter <= 120 ? 1 : max(1, voxelCount / 4096)
        for i in Swift.stride(from: 0, to: voxelCount, by: sampleStride) {
            maxVal = max(maxVal, ptr[i])
        }
        if sampleStride > 1 {
            maxVal = max(maxVal, ptr[voxelCount - 1])
        }
        
        // If RGB mode, also check G and B
        if useRGBMode {
            for buf in [densityBufferG, densityBufferB] {
                guard let b = buf else { continue }
                let p = b.contents().bindMemory(to: UInt32.self, capacity: voxelCount)
                for i in Swift.stride(from: 0, to: voxelCount, by: sampleStride) {
                    maxVal = max(maxVal, p[i])
                }
                if sampleStride > 1 {
                    maxVal = max(maxVal, p[voxelCount - 1])
                }
            }
        }
        
        maxDensityValue = maxVal
    }
    
    // MARK: - Volume Placement
    
    /// Computes the volume-to-world matrix for placing the Buddhabrot volume in space.
    /// Shared by both the 3DGS pipeline (depth keys + render) and the ray march pipeline.
    private func buildVolumeWorldMatrix(
        drawable: LayerRenderer.Drawable,
        time: Float,
        settingsSnapshot: RenderSettingsSnapshot,
        buddhabrotSnapshot: BuddhabrotSettingsSnapshot
    ) -> matrix_float4x4 {
        let liveDeviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        // Anchor volume placement once in world space so it doesn't head-lock.
        if volumePlacementAnchorTransform == nil, let deviceAnchor = drawable.deviceAnchor {
            volumePlacementAnchorTransform = deviceAnchor.originFromAnchorTransform
            volumePlacementAnchorUserPosition = settingsSnapshot.position
            volumePlacementAnchorWorldRotation = settingsSnapshot.worldRotation
            volumePlacementAnchorDetailScale = max(settingsSnapshot.detailScale, 1e-6)
        }
        let placementAnchor = volumePlacementAnchorTransform ?? liveDeviceTransform
        
        let forward = -SIMD3<Float>(placementAnchor.columns.2.x, placementAnchor.columns.2.y, placementAnchor.columns.2.z)
        let devicePos = SIMD3<Float>(placementAnchor.columns.3.x, placementAnchor.columns.3.y, placementAnchor.columns.3.z)
        let baseCenter = devicePos + forward * buddhabrotSnapshot.volumeDistance
        
        let anchorPosition = volumePlacementAnchorUserPosition ?? settingsSnapshot.position
        let positionDelta = settingsSnapshot.position - anchorPosition
        let anchorRotation = volumePlacementAnchorWorldRotation ?? settingsSnapshot.worldRotation
        let rotationDelta = settingsSnapshot.worldRotation * anchorRotation.inverse
        let anchorDetailScale = volumePlacementAnchorDetailScale ?? max(settingsSnapshot.detailScale, 1e-6)
        let detailScaleDelta = max(0.05, min(20.0, settingsSnapshot.detailScale / max(anchorDetailScale, 1e-6)))
        
        let volumeCenter = baseCenter + positionDelta
        let userRotation = matrix4x4_from_quaternion(rotationDelta)
        
        let s = buddhabrotSnapshot.volumeScale * detailScaleDelta
        let translation = matrix4x4_translation(volumeCenter.x, volumeCenter.y, volumeCenter.z)
        let scale = matrix4x4_scale(s, s, s)
        var volumeWorld = translation * userRotation * scale
        
        if buddhabrotSnapshot.autoRotate {
            let angle = time * buddhabrotSnapshot.rotationSpeed
            let cosA = cos(angle)
            let sinA = sin(angle)
            var rotation = matrix_identity_float4x4
            rotation.columns.0 = SIMD4<Float>(cosA, 0, sinA, 0)
            rotation.columns.2 = SIMD4<Float>(-sinA, 0, cosA, 0)
            volumeWorld = volumeWorld * rotation
        }
        
        return volumeWorld
    }
}
#endif
