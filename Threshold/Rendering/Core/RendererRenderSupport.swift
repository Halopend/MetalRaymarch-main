@preconcurrency import CompositorServices
import Foundation
import Metal

extension Renderer {
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
        let frameMs = frameTimeSeconds * 1000.0

        if frameMs < perfLogFrameMsThreshold { return }
        if nowTime - lastPerfLogTime < 0.5 { return }
        lastPerfLogTime = nowTime

        let gpuText = gpuMs.map { String(format: "%.2f", $0) } ?? "n/a"

        let pathText = useAdaptiveCompute ? "compute" : "fragment"
        let fps = frameTimeSeconds > 0 ? (1.0 / frameTimeSeconds) : 0
        if RENDERER_DEBUG { print("⚠️ Slow frame: ft=\(String(format: "%.2f", frameMs))ms fps=\(String(format: "%.1f", fps)) gpu=\(gpuText)ms cpu=\(String(format: "%.2f", cpuEncodeMs))ms path=\(pathText) tile=\(settingsSnapshot.tileSize) iters=\(settingsSnapshot.fractalIterations) steps=\(settingsSnapshot.maxRaySteps) views=\(viewCount)") }
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

        lastMetalFXInputSize = SIMD2(inputWidth, inputHeight)
        lastMetalFXOutputSize = SIMD2(outputWidth, outputHeight)

        if metalFXFence == nil {
            metalFXFence = device.makeFence()
        }

        guard let manager = metalFXManager else { return nil }
        return (manager, inputWidth, inputHeight)
    }
}
#endif
