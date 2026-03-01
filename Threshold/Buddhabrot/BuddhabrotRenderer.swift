//
//  BuddhabrotRenderer.swift
//  Threshold
//
//  Manages the 3D Buddhabrot volume rendering pipeline for Vision Pro.
//
//  Architecture:
//    Phase 1: Async compute pass accumulates Mandelbulb orbit density into a 3D uint32 buffer
//             using atomics. Runs on a background command queue at low priority.
//    Phase 2: Per-frame normalize density → 3D float texture, then stereo volume ray march
//             via the existing CompositorLayer render pass.
//
//  This class owns all GPU resources for the Buddhabrot mode and is intended to be
//  created and held by the main Renderer actor. It can be swapped in when
//  AppModel.runtimeViewMode == .buddhabrot.
//

import Metal
import simd
import CompositorServices

// MARK: - Buddhabrot Settings

/// User-adjustable parameters for the Buddhabrot volume renderer.
/// Thread-safe for cross-thread access (render loop reads, UI writes).
final class BuddhabrotSettings: @unchecked Sendable {
    // Volume resolution (per axis). 128^3 = 8 MB density buffer.
    var resolution: Int = 128

    // Mandelbulb parameters
    var power: Float = 8.0
    var maxIterations: Int = 100
    var bailoutRadius: Float = 4.0
    
    // Iteration bands for RGB Nebulabrot mode
    var useRGBMode: Bool = false
    var shortEscapeMax: Int = 20
    var mediumEscapeMax: Int = 100
    
    // Accumulation control
    var batchSize: Int = 65536         // Seeds per compute dispatch
    var batchesPerFrame: Int = 2       // Dispatches per frame (throttle for thermals)
    var normalizationInterval: Int = 4 // Normalize every N frames
    
    // Transfer function
    var densityScale: Float = 1.0
    var gamma: Float = 0.4
    var alphaScale: Float = 8.0
    
    // Palette colors
    var colorLow:  SIMD3<Float> = SIMD3<Float>(0.02, 0.02, 0.12)  // Deep blue
    var colorMid:  SIMD3<Float> = SIMD3<Float>(0.6, 0.2, 0.8)     // Purple
    var colorHigh: SIMD3<Float> = SIMD3<Float>(1.0, 0.95, 0.8)    // Warm white
    
    // Ray march quality
    var maxRaySteps: Int = 80
    var earlyExitAlpha: Float = 0.95
    
    // Volume placement (meters from origin, in front of user)
    var volumeDistance: Float = 1.5
    var volumeScale: Float = 0.6 // Size of volume cube in meters
    var autoRotate: Bool = true
    var rotationSpeed: Float = 0.1

    // World extent for orbit accumulation bounding cube
    var worldExtent: Float = 2.0
    
    // State
    var totalSamplesAccumulated: UInt64 = 0
    var needsClear: Bool = false
}

// MARK: - BuddhabrotRenderer

/// Manages all GPU resources and passes for 3D Buddhabrot volume rendering.
/// Designed to be owned by the main Renderer actor and called from the render loop.
final class BuddhabrotRenderer {
    
    // MARK: - GPU Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue          // Low-priority queue for accumulation
    private let settings: BuddhabrotSettings
    
    // Compute pipelines
    private var accumulatePipeline: MTLComputePipelineState?
    private var accumulateRGBPipeline: MTLComputePipelineState?
    private var normalizePipeline: MTLComputePipelineState?
    private var normalizeRGBPipeline: MTLComputePipelineState?
    private var clearDensityPipeline: MTLComputePipelineState?
    
    // Render pipeline (volume ray march)
    private var rayMarchPipeline: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?
    
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
    
    // State tracking
    private var currentResolution: Int = 0
    private var seedOffset: UInt32 = 0
    private var maxDensityValue: UInt32 = 0
    private var frameCounter: Int = 0
    private var accumulationTime: Float = 0
    private var warnedAboutMissingPipelines = false
    
    // MARK: - Initialization
    
    init?(device: MTLDevice, layerRenderer: LayerRenderer, settings: BuddhabrotSettings) {
        self.device = device
        self.settings = settings
        
        // Create a dedicated command queue for accumulation (could be low priority)
        guard let queue = device.makeCommandQueue() else {
            print("❌ BuddhabrotRenderer: Failed to create command queue")
            return nil
        }
        self.commandQueue = queue
        
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
            
            // Input assembly: full-screen triangle uses vertex_id, no vertex buffer
            // so no vertex descriptor needed.
            
            rayMarchPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("❌ BuddhabrotRenderer: Failed to build ray march pipeline: \(error)")
            return nil
        }
        
        // Build depth stencil state
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .greaterEqual // visionOS uses reverse-Z
        depthDesc.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)
        
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
        
        // Allocate density buffers and volume texture at current resolution
        reallocateResources(resolution: settings.resolution)
    }
    
    // MARK: - Resource Management
    
    /// Reallocates the density buffer and 3D texture when resolution changes.
    func reallocateResources(resolution: Int) {
        guard resolution != currentResolution else { return }
        currentResolution = resolution
        
        let voxelCount = resolution * resolution * resolution
        let bufferSize = voxelCount * MemoryLayout<UInt32>.size
        
        // Density buffer(s) — storageModeShared for CPU readback of max density
        densityBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        densityBuffer?.label = "Buddhabrot Density"
        
        if settings.useRGBMode {
            densityBufferR = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            densityBufferR?.label = "Buddhabrot Density R"
            densityBufferG = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            densityBufferG?.label = "Buddhabrot Density G"
            densityBufferB = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            densityBufferB?.label = "Buddhabrot Density B"
        }
        
        // 3D float texture for normalized volume
        let texDesc = MTLTextureDescriptor()
        texDesc.textureType = .type3D
        texDesc.pixelFormat = settings.useRGBMode ? .rgba16Float : .r16Float
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
        settings.totalSamplesAccumulated = 0
        
        print("✓ Buddhabrot: Allocated \(resolution)^3 volume (\(bufferSize / 1024) KB density buffer)")
    }
    
    // MARK: - Phase 1: Orbit Accumulation
    
    /// Dispatches orbit accumulation compute passes.
    /// Call from the render loop; uses a separate command buffer to not block rendering.
    /// Returns the command buffer so the caller can track completion.
    @discardableResult
    func dispatchAccumulation() -> MTLCommandBuffer? {
        // Check if resolution changed
        if settings.resolution != currentResolution || settings.needsClear {
            reallocateResources(resolution: settings.resolution)
            clearDensityBuffers()
            settings.needsClear = false
        }
        
        guard let pipeline = settings.useRGBMode ? accumulateRGBPipeline : accumulatePipeline,
              let uniformBuffer = accumulationUniformBuffer else {
            return nil
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        commandBuffer.label = "Buddhabrot Accumulation"
        
        // Fill uniforms
        let uniforms = uniformBuffer.contents().bindMemory(to: BuddhabrotAccumulationUniforms.self, capacity: 1)
        uniforms.pointee.resolution = UInt32(currentResolution)
        uniforms.pointee.maxIterations = UInt32(settings.maxIterations)
        uniforms.pointee.minIterations = 0 // Accept all escapes for single-channel
        uniforms.pointee.batchSize = UInt32(settings.batchSize)
        uniforms.pointee.seedOffset = seedOffset
        uniforms.pointee.escapeRadius = settings.bailoutRadius * settings.bailoutRadius
        uniforms.pointee.worldExtent = settings.worldExtent
        uniforms.pointee.power = settings.power
        uniforms.pointee.bailoutRadius = settings.bailoutRadius
        
        for _ in 0..<settings.batchesPerFrame {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.label = "Buddhabrot Orbit Batch"
            encoder.setComputePipelineState(pipeline)
            
            encoder.setBuffer(uniformBuffer, offset: 0, index: 0) // BuddhabrotBufferIndexUniforms
            
            if settings.useRGBMode {
                encoder.setBuffer(densityBufferR, offset: 0, index: 1)
                encoder.setBuffer(densityBufferG, offset: 0, index: 2)
                encoder.setBuffer(densityBufferB, offset: 0, index: 3)
            } else {
                encoder.setBuffer(densityBuffer, offset: 0, index: 1)
            }
            
            let threadsPerGrid = MTLSize(width: settings.batchSize, height: 1, depth: 1)
            let threadgroupSize = MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadgroupSize)
            
            encoder.endEncoding()
            
            // Advance seed for next batch
            seedOffset &+= 1
            uniforms.pointee.seedOffset = seedOffset
        }
        
        settings.totalSamplesAccumulated += UInt64(settings.batchSize * settings.batchesPerFrame)
        
        commandBuffer.commit()
        return commandBuffer
    }
    
    // MARK: - Phase 2a: Normalization
    
    /// Normalizes the density buffer into the 3D float texture.
    /// Call every N frames (not every frame) to save GPU cycles.
    func encodeNormalization(commandBuffer: MTLCommandBuffer) {
        guard let normPipeline = settings.useRGBMode ? normalizeRGBPipeline : normalizePipeline,
              let uniformBuffer = normalizationUniformBuffer,
              let volumeTex = volumeTexture else {
            return
        }
        
        // Scan for max density on CPU (fast enough for 128^3 at normalization interval)
        updateMaxDensity()
        
        // Fill normalization uniforms
        let uniforms = uniformBuffer.contents().bindMemory(to: BuddhabrotNormalizationUniforms.self, capacity: 1)
        uniforms.pointee.resolution = UInt32(currentResolution)
        uniforms.pointee.densityScale = settings.densityScale
        uniforms.pointee.gamma = settings.gamma
        uniforms.pointee.logBase = 1.0
        uniforms.pointee.maxDensity = max(maxDensityValue, 1)
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Buddhabrot Normalize"
        encoder.setComputePipelineState(normPipeline)
        
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        
        if settings.useRGBMode {
            encoder.setBuffer(densityBufferR, offset: 0, index: 1)
            encoder.setBuffer(densityBufferG, offset: 0, index: 2)
            encoder.setBuffer(densityBufferB, offset: 0, index: 3)
        } else {
            encoder.setBuffer(densityBuffer, offset: 0, index: 1)
        }
        
        encoder.setTexture(volumeTex, index: 0)
        
        let res = currentResolution
        let threadgroupSize = MTLSize(width: 4, height: 4, depth: 4)
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
        time: Float
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
        
        accumulationTime = time
        
        // Build per-eye uniforms
        let uniformsPtr = uniformBuffer.contents().bindMemory(to: BuddhabrotRayMarchUniformsArray.self, capacity: 1)
        
        // Volume world transform (centered in front of user, optionally rotating)
        var volumeWorld = matrix_identity_float4x4
        
        // Place volume in front of the device anchor
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let forward = -SIMD3<Float>(deviceTransform.columns.2.x, deviceTransform.columns.2.y, deviceTransform.columns.2.z)
        let devicePos = SIMD3<Float>(deviceTransform.columns.3.x, deviceTransform.columns.3.y, deviceTransform.columns.3.z)
        let volumeCenter = devicePos + forward * settings.volumeDistance
        
        // Scale
        let s = settings.volumeScale
        volumeWorld.columns.0 = SIMD4<Float>(s, 0, 0, 0)
        volumeWorld.columns.1 = SIMD4<Float>(0, s, 0, 0)
        volumeWorld.columns.2 = SIMD4<Float>(0, 0, s, 0)
        volumeWorld.columns.3 = SIMD4<Float>(volumeCenter.x, volumeCenter.y, volumeCenter.z, 1)
        
        // Optional auto-rotation
        if settings.autoRotate {
            let angle = time * settings.rotationSpeed
            let cosA = cos(angle)
            let sinA = sin(angle)
            var rotation = matrix_identity_float4x4
            rotation.columns.0 = SIMD4<Float>(cosA, 0, sinA, 0)
            rotation.columns.2 = SIMD4<Float>(-sinA, 0, cosA, 0)
            volumeWorld = volumeWorld * rotation
        }
        
        let invVolumeWorld = volumeWorld.inverse
        let ext = settings.worldExtent
        
        for viewIndex in 0..<drawable.views.count {
            let view = drawable.views[viewIndex]
            let viewTransform = (deviceTransform * view.transform).inverse
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
            u.stepSize = (ext * 2.0) / Float(settings.maxRaySteps)
            u.colorLow = settings.colorLow
            u.densityScale = settings.densityScale
            u.colorMid = settings.colorMid
            u.alphaScale = settings.alphaScale
            u.colorHigh = settings.colorHigh
            u.gamma = settings.gamma
            u.maxSteps = UInt32(settings.maxRaySteps)
            u.earlyExitAlpha = settings.earlyExitAlpha
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
        
        // Use layered rendering for stereo
        if drawable.views.count > 1 {
            renderPassDesc.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDesc.colorAttachments[0].loadAction = .clear
            renderPassDesc.colorAttachments[0].storeAction = .store
            renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            renderPassDesc.depthAttachment.texture = drawable.depthTextures[0]
            renderPassDesc.depthAttachment.loadAction = .clear
            renderPassDesc.depthAttachment.storeAction = .store
            renderPassDesc.depthAttachment.clearDepth = 0.0 // Reverse-Z: near=1, far=0
            renderPassDesc.renderTargetArrayLength = drawable.views.count
        } else {
            renderPassDesc.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDesc.colorAttachments[0].loadAction = .clear
            renderPassDesc.colorAttachments[0].storeAction = .store
            renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            renderPassDesc.depthAttachment.texture = drawable.depthTextures[0]
            renderPassDesc.depthAttachment.loadAction = .clear
            renderPassDesc.depthAttachment.storeAction = .store
            renderPassDesc.depthAttachment.clearDepth = 0.0
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
    
    // MARK: - Full Frame (Accumulation + Normalize + Ray March)
    
    /// Convenience: runs the complete Buddhabrot pipeline for one frame.
    /// Returns true if rendering was successful.
    func renderFrame(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        time: Float
    ) -> Bool {
        frameCounter += 1
        
        // Phase 1: Dispatch accumulation (on separate command buffer, non-blocking)
        dispatchAccumulation()
        
        // Phase 2a: Normalize density buffer → 3D texture (every N frames)
        let normalizationEvery = max(1, settings.normalizationInterval)
        if frameCounter % normalizationEvery == 0 || frameCounter <= 2 {
            encodeNormalization(commandBuffer: commandBuffer)
        }
        
        // Phase 2b: Volume ray march
        let drewVolume = encodeRayMarch(commandBuffer: commandBuffer, drawable: drawable, time: time)

        return drewVolume
    }
    
    // MARK: - Density Buffer Utilities
    
    /// Clears the density buffer(s) to zero.
    func clearDensityBuffers() {
        guard let clearPipeline = clearDensityPipeline,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        let voxelCount = currentResolution * currentResolution * currentResolution
        let buffers: [MTLBuffer?] = settings.useRGBMode
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
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        seedOffset = 0
        maxDensityValue = 0
        settings.totalSamplesAccumulated = 0
        print("✓ Buddhabrot: Density buffers cleared")
    }
    
    /// Scans the density buffer to find the current maximum value.
    /// Used for adaptive normalization. Fast enough on CPU for 128^3 at low frequency.
    private func updateMaxDensity() {
        let primaryBuffer: MTLBuffer?
        if settings.useRGBMode {
            // For RGB, scan all three buffers and take the max
            primaryBuffer = densityBufferR // Just use R for now as representative
        } else {
            primaryBuffer = densityBuffer
        }
        
        guard let buffer = primaryBuffer else { return }
        
        let voxelCount = currentResolution * currentResolution * currentResolution
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: voxelCount)
        
        var maxVal: UInt32 = 0
        // Sample every 64th voxel for speed (good enough for normalization)
        let sampleStride = max(1, voxelCount / 4096)
        for i in Swift.stride(from: 0, to: voxelCount, by: sampleStride) {
            maxVal = max(maxVal, ptr[i])
        }
        
        // If RGB mode, also check G and B
        if settings.useRGBMode {
            for buf in [densityBufferG, densityBufferB] {
                guard let b = buf else { continue }
                let p = b.contents().bindMemory(to: UInt32.self, capacity: voxelCount)
                for i in Swift.stride(from: 0, to: voxelCount, by: sampleStride) {
                    maxVal = max(maxVal, p[i])
                }
            }
        }
        
        maxDensityValue = maxVal
    }
}
