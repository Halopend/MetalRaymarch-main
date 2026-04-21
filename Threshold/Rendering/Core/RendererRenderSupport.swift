@preconcurrency import CompositorServices
import Foundation
import Metal

enum RenderFramePath {
    case adaptiveCompute
    case fragment(useQuadShared: Bool)
}

struct FramePhaseBreakdown {
    var backgroundCpuMs: Double = 0
    var dynamicQualityMs: Double = 0
    var handTrackingMs: Double = 0
    var settingsUpdateMs: Double = 0
    var snapshotMs: Double = 0
    var updateGameStateMs: Double = 0
    var renderPathEncodeMs: Double = 0
    var mainActorDispatchCount: Int = 0

    static let zero = FramePhaseBreakdown()
}

extension Renderer {
    func selectFramePath(settingsSnapshot: RenderSettingsSnapshot) -> RenderFramePath {
        if settingsSnapshot.prefersAdaptiveComputePath,
           adaptiveHierarchicalPipeline8x8 != nil {
            return .adaptiveCompute
        }
        return .fragment(useQuadShared: settingsSnapshot.tileSize == 2)
    }

    /// Actor-isolated throttle gate for slow-frame logging.
    /// Evaluate on the render loop thread before command buffer commit.
    func consumeSlowFrameLogPermit(nowTime: TimeInterval, frameTimeSeconds: Double) -> Bool {
        let frameMs = frameTimeSeconds * 1000.0
        guard frameMs >= perfLogFrameMsThreshold else { return false }
        guard nowTime - lastPerfLogTime >= 0.5 else { return false }
        lastPerfLogTime = nowTime
        return true
    }

    func configureDirectRenderTargets(renderPassDescriptor: MTLRenderPassDescriptor, drawable: LayerRenderer.Drawable) {
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]

        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.storeAction = .store

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        if let systemMap = drawable.rasterizationRateMaps.first {
            renderPassDescriptor.rasterizationRateMap = systemMap
            if RENDERER_DEBUG && !hasLoggedFoveationAvailability {
                print("✓ Using system gaze-tracked rasterization rate map")
                hasLoggedFoveationAvailability = true
            }
        } else {
            renderPassDescriptor.rasterizationRateMap = nil
        }
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
    }

    func recordFramePerf(
        nowTime: TimeInterval,
        frameTimeSeconds: Double,
        cpuEncodeMs: Double,
        gpuMs: Double?,
        settingsSnapshot: RenderSettingsSnapshot,
        useAdaptiveCompute: Bool,
        viewCount: Int
    ) {
        let shouldLogSlowFrame = consumeSlowFrameLogPermit(nowTime: nowTime, frameTimeSeconds: frameTimeSeconds)
        Self.recordFramePerf(
            frameTimeSeconds: frameTimeSeconds,
            cpuEncodeMs: cpuEncodeMs,
            gpuMs: gpuMs,
            frameBreakdown: .zero,
            shouldLogSlowFrame: shouldLogSlowFrame,
            settingsSnapshot: settingsSnapshot,
            useAdaptiveCompute: useAdaptiveCompute,
            viewCount: viewCount
        )
    }

    nonisolated static func recordFramePerf(
        frameTimeSeconds: Double,
        cpuEncodeMs: Double,
        gpuMs: Double?,
        frameBreakdown: FramePhaseBreakdown,
        shouldLogSlowFrame: Bool,
        settingsSnapshot: RenderSettingsSnapshot,
        useAdaptiveCompute: Bool,
        viewCount: Int
    ) {
        let frameMs = frameTimeSeconds * 1000.0

#if DEBUG
        let benchFractalType: Int = Int(settingsSnapshot.fractalType.rawValue)
        let benchFractalName: String = settingsSnapshot.fractalType.displayName
        BenchmarkManager.shared.recordSample(
            fractalType: benchFractalType,
            fractalName: benchFractalName,
            gpuMs: gpuMs,
            cpuMs: cpuEncodeMs,
            frameTimeMs: frameMs
        )
#endif

        guard shouldLogSlowFrame else { return }

        let gpuText = gpuMs.map { String(format: "%.2f", $0) } ?? "n/a"
        let backgroundCpuText = String(format: "%.2f", frameBreakdown.backgroundCpuMs)
        let dynamicQualityText = String(format: "%.2f", frameBreakdown.dynamicQualityMs)
        let handTrackingText = String(format: "%.2f", frameBreakdown.handTrackingMs)
        let settingsUpdateText = String(format: "%.2f", frameBreakdown.settingsUpdateMs)
        let snapshotText = String(format: "%.2f", frameBreakdown.snapshotMs)
        let gameStateText = String(format: "%.2f", frameBreakdown.updateGameStateMs)
        let renderEncodeText = String(format: "%.2f", frameBreakdown.renderPathEncodeMs)

        let pathText = useAdaptiveCompute ? "compute" : "fragment"
        let fps = frameTimeSeconds > 0 ? (1.0 / frameTimeSeconds) : 0
        print("⚠️ Slow frame: ft=\(String(format: "%.2f", frameMs))ms fps=\(String(format: "%.1f", fps)) gpu=\(gpuText)ms cpu=\(String(format: "%.2f", cpuEncodeMs))ms bg=\(backgroundCpuText)ms dq=\(dynamicQualityText)ms hand=\(handTrackingText)ms settings=\(settingsUpdateText)ms snap=\(snapshotText)ms game=\(gameStateText)ms encode=\(renderEncodeText)ms tasks=\(frameBreakdown.mainActorDispatchCount) path=\(pathText) tile=\(settingsSnapshot.tileSize) iters=\(settingsSnapshot.fractalIterations) steps=\(settingsSnapshot.maxRaySteps) views=\(viewCount)")
    }

    /// Returns true when the fragment render path should render at low-res into
    /// MetalFX's input texture and spatially upscale to the drawable.
    ///
    /// On visionOS MetalFX provides **spatial** upscaling only (temporal is
    /// unsupported), so this path only applies to the fragment render path.
    /// The compute/Buddhabrot paths are deliberately excluded for now — they can
    /// be routed through MetalFX in a future phase once depth ownership and
    /// tile-shared history semantics are designed.
    ///
    /// Minimum scale is clamped to 0.5 by `RenderSettings.resolutionScale`.
    func isMetalFXActive(for settingsSnapshot: RenderSettingsSnapshot, framePath: RenderFramePath) -> Bool {
        #if canImport(MetalFX)
        switch framePath {
        case .adaptiveCompute:
            return false
        case .fragment:
            break
        }
        // Treat anything within 0.1% of native as "disabled" to avoid pointless
        // rebuilds at 0.999 due to float rounding.
        return settingsSnapshot.resolutionScale < 0.999
        #else
        _ = (settingsSnapshot, framePath)
        return false
        #endif
    }
}

#if canImport(MetalFX)
extension Renderer {
    func scaledViewports(for drawable: LayerRenderer.Drawable, targetWidth: Int, targetHeight: Int) -> [MTLViewport] {
        let outputWidth = max(1, drawable.colorTextures[0].width)
        let outputHeight = max(1, drawable.colorTextures[0].height)
        let scaleX = Double(targetWidth) / Double(outputWidth)
        let scaleY = Double(targetHeight) / Double(outputHeight)
        return drawable.views.map { view in
            let vp = view.textureMap.viewport
            return MTLViewport(
                originX: vp.originX * scaleX,
                originY: vp.originY * scaleY,
                width: vp.width * scaleX,
                height: vp.height * scaleY,
                znear: vp.znear,
                zfar: vp.zfar
            )
        }
    }

    func configureMetalFXRenderTargets(
        renderPassDescriptor: MTLRenderPassDescriptor,
        metalFX: MetalFXManager,
        drawable: LayerRenderer.Drawable,
        rasterizationRateMap: MTLRasterizationRateMap?
    ) {
        guard let inputTexture = metalFX.inputTexture,
              let depthTexture = metalFX.depthTexture else {
            return
        }

        renderPassDescriptor.colorAttachments[0].texture = inputTexture
        renderPassDescriptor.depthAttachment.texture = depthTexture

        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.storeAction = .store

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        if let map = rasterizationRateMap {
            let physical = map.physicalSize(layer: 0)
            if physical.width == inputTexture.width && physical.height == inputTexture.height {
                renderPassDescriptor.rasterizationRateMap = map
                if RENDERER_DEBUG && !hasLoggedFoveationAvailability {
                    print("✓ Using system gaze-tracked rasterization rate map (MetalFX input)")
                    hasLoggedFoveationAvailability = true
                }
            } else {
                renderPassDescriptor.rasterizationRateMap = nil
            }
        } else {
            renderPassDescriptor.rasterizationRateMap = nil
        }

        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
    }

    func blitMetalFXOutputToDrawable(
        commandBuffer: MTLCommandBuffer,
        metalFX: MetalFXManager,
        drawable: LayerRenderer.Drawable
    ) {
        guard let outputTexture = metalFX.outputTexture else { return }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.label = "Copy MetalFX Output to Drawable"

        for eye in 0..<drawable.views.count {
            let destinationTexture: MTLTexture
            let destinationSlice: Int

            if drawable.colorTextures.count > eye {
                destinationTexture = drawable.colorTextures[eye]
                destinationSlice = 0
            } else {
                destinationTexture = drawable.colorTextures[0]
                destinationSlice = eye
            }

            blitEncoder.copy(
                from: outputTexture,
                sourceSlice: eye,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
                to: destinationTexture,
                destinationSlice: destinationSlice,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }

        if let depthTexture = metalFX.depthTexture {
            // Only copy depth when MetalFX depth matches the drawable depth
            // resolution. MTLFXSpatialScaler does NOT upscale depth, so when
            // resolutionScale < 1.0 our depth texture is smaller than the
            // drawable depth. A straight blit would leave the rest of the
            // drawable depth undefined, which causes visible late-reprojection
            // artifacts in the visionOS compositor. Skipping the depth copy in
            // that case is preferable — the compositor falls back to its own
            // late-latched pose for reprojection.
            let depthDestSample = drawable.depthTextures.first
            let sizeMatches = depthDestSample.map {
                $0.width == depthTexture.width && $0.height == depthTexture.height
            } ?? false

            if sizeMatches {
                for eye in 0..<drawable.views.count {
                    let destinationTexture: MTLTexture
                    let destinationSlice: Int

                    if drawable.depthTextures.count > eye {
                        destinationTexture = drawable.depthTextures[eye]
                        destinationSlice = 0
                    } else {
                        destinationTexture = drawable.depthTextures[0]
                        destinationSlice = eye
                    }

                    blitEncoder.copy(
                        from: depthTexture,
                        sourceSlice: eye,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: depthTexture.width, height: depthTexture.height, depth: 1),
                        to: destinationTexture,
                        destinationSlice: destinationSlice,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                }
            }
        }

        blitEncoder.endEncoding()
    }

    func updateMetalFXManager(
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        rasterizationRateMap: MTLRasterizationRateMap?
    ) -> (MetalFXManager, Int, Int)? {
        let outputWidth = drawable.colorTextures[0].width
        let outputHeight = drawable.colorTextures[0].height
        let viewCount = drawable.views.count

        var inputWidth = max(1, Int(Float(outputWidth) * settingsSnapshot.resolutionScale))
        var inputHeight = max(1, Int(Float(outputHeight) * settingsSnapshot.resolutionScale))

        if layerRenderer.configuration.isFoveationEnabled, let map = rasterizationRateMap {
            let physical = map.physicalSize(layer: 0)
            if physical.width > 0 && physical.height > 0 {
                inputWidth = max(inputWidth, physical.width)
                inputHeight = max(inputHeight, physical.height)
            }
        }

        let config = MetalFXManager.Configuration(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormat: drawable.colorTextures[0].pixelFormat,
            depthFormat: drawable.depthTextures[0].pixelFormat,
            scale: settingsSnapshot.resolutionScale
        )

        do {
            if metalFXManager == nil {
                metalFXManager = try MetalFXManager(device: device, configuration: config, viewCount: viewCount)
            } else {
                try metalFXManager?.update(configuration: config, viewCount: viewCount)
            }
        } catch {
            if RENDERER_DEBUG && !hasLoggedMetalFXFallback {
                print("⚠️ MetalFX init/update failed: \(error). Falling back to direct rendering.")
                hasLoggedMetalFXFallback = true
            }
            metalFXManager = nil
            return nil
        }

        let resolutionChanged =
            lastMetalFXInputSize.x != inputWidth ||
            lastMetalFXInputSize.y != inputHeight ||
            lastMetalFXOutputSize.x != outputWidth ||
            lastMetalFXOutputSize.y != outputHeight

        lastMetalFXInputSize = SIMD2(inputWidth, inputHeight)
        lastMetalFXOutputSize = SIMD2(outputWidth, outputHeight)

        if metalFXFence == nil {
            metalFXFence = device.makeFence()
        }

        guard let manager = metalFXManager else { return nil }

        // Register the (possibly new) MetalFX textures with the residency set
        // so the compositor can skip per-frame residency validation. Only needed
        // when textures were actually recreated (on first init or resize).
        if resolutionChanged {
            var newTextures: [MTLTexture] = []
            if let t = manager.inputTexture  { newTextures.append(t) }
            if let t = manager.depthTexture  { newTextures.append(t) }
            if let t = manager.outputTexture { newTextures.append(t) }
            if !newTextures.isEmpty {
                updateResidencySetForComputeTextures(newTextures)
            }
        }

        return (manager, inputWidth, inputHeight)
    }
}
#endif
