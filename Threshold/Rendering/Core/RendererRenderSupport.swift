@preconcurrency import CompositorServices
import Foundation
import Metal

// RenderFramePath / RendererMetalFXBundle / RendererFragmentPassPlan /
// FramePhaseBreakdown now live in Rendering/Core/FramePath.swift.

extension Renderer {
    func applyVertexAmplificationIfNeeded(
        to renderEncoder: MTLRenderCommandEncoder,
        viewCount: Int
    ) {
        guard viewCount > 1 else { return }

        if viewCount != cachedViewMappingsCount {
            cachedViewMappings = (0..<viewCount).map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            cachedViewMappingsCount = viewCount
        }

        renderEncoder.setVertexAmplificationCount(viewCount, viewMappings: &cachedViewMappings)
    }

    func prepareFragmentPassPlan(
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        framePath: RenderFramePath
    ) -> RendererFragmentPassPlan {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        let directViewports = drawable.views.map { $0.textureMap.viewport }

#if canImport(MetalFX)
        let rasterizationRateMap = drawable.rasterizationRateMaps.first
        let metalFXActive = isMetalFXActive(for: settingsSnapshot, framePath: framePath)
        var metalFXBundle: RendererMetalFXBundle?

        if metalFXActive {
            if canAllocateVisionMetalFXTextures(
                drawable: drawable,
                settingsSnapshot: settingsSnapshot,
                framePath: framePath
            ), let updated = updateMetalFXManager(
                drawable: drawable,
                settingsSnapshot: settingsSnapshot,
                rasterizationRateMap: rasterizationRateMap
            ) {
                metalFXBundle = RendererMetalFXBundle(
                    manager: updated.0,
                    inputWidth: updated.1,
                    inputHeight: updated.2
                )
            }
        } else {
            metalFXManager = nil
        }

        if let metalFXBundle {
            configureMetalFXRenderTargets(
                renderPassDescriptor: renderPassDescriptor,
                metalFX: metalFXBundle.manager,
                drawable: drawable,
                rasterizationRateMap: rasterizationRateMap
            )
            let viewports = scaledViewports(
                for: drawable,
                targetWidth: metalFXBundle.inputWidth,
                targetHeight: metalFXBundle.inputHeight
            )
            return RendererFragmentPassPlan(
                renderPassDescriptor: renderPassDescriptor,
                viewports: viewports,
                resolutionScale: effectiveResolutionScale(settingsSnapshot),
                metalFXBundle: metalFXBundle
            )
        }
#endif

        configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)
#if canImport(MetalFX)
        return RendererFragmentPassPlan(
            renderPassDescriptor: renderPassDescriptor,
            viewports: directViewports,
            resolutionScale: settingsSnapshot.resolutionScale,
            metalFXBundle: nil
        )
#else
        return RendererFragmentPassPlan(
            renderPassDescriptor: renderPassDescriptor,
            viewports: directViewports,
            resolutionScale: settingsSnapshot.resolutionScale
        )
#endif
    }

    func finishFragmentPass(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        fragmentPassPlan: RendererFragmentPassPlan,
        framePreparation: RendererFramePreparation,
        settingsSnapshot: RenderSettingsSnapshot
    ) {
#if canImport(MetalFX)
        guard let bundle = fragmentPassPlan.metalFXBundle else {
            // Direct render: no MetalFX depth was written this frame, so the
            // next fragment frame must not warm-start from stale history.
            warmStartGate.invalidate()
            return
        }

        do {
            try bundle.manager.encodeSpatialUpscale(commandBuffer: commandBuffer, fence: metalFXFence)

            // Rotate per-eye view-proj history for the fragment depth warm-start
            // (consumed next frame to start each ray near last frame's surface).
            for viewIndex in 0..<min(drawable.views.count, previousViewProjMatrices.count) {
                let eye = framePreparation.perEye[viewIndex]
                previousViewProjMatrices[viewIndex] = eye.projection * eye.modelView
            }

            // Single spatial upscale → RCAS sharpen → drawable. No temporal blend.
            resolveMetalFXOutputToDrawable(
                commandBuffer: commandBuffer,
                metalFX: bundle.manager,
                drawable: drawable,
                resolutionScale: fragmentPassPlan.resolutionScale
            )

            // This frame's depth becomes next frame's warm-start history.
            bundle.manager.advanceDepthHistory()
            warmStartGate.recordDepthWritten(settingsSnapshot)
        } catch {
            if RENDERER_DEBUG && !hasLoggedMetalFXFallback {
                print("⚠️ MetalFX spatial upscale failed: \(error). Falling back to direct rendering next frame.")
                hasLoggedMetalFXFallback = true
            }
            metalFXManager = nil
            warmStartGate.invalidate()
        }
#else
        _ = (commandBuffer, drawable, fragmentPassPlan, framePreparation, settingsSnapshot)
#endif
    }

    // MARK: - Progressive Immersion Portal (visionOS 26+)

    /// True when the layer was configured with a render-context stencil format
    /// at startup (visionOS 26 + layered layout — see ContentStageConfiguration).
    /// Once configured, the compositor requires the drawable render-context
    /// pass before EVERY present, in every immersion style — skipping it
    /// aborts the frame ("need to use drawable render context when supporting
    /// progressive style"). Style-independent by design.
    var drawableRenderContextRequired: Bool {
        guard #available(visionOS 26.0, *) else { return false }
        guard layerRenderer.configuration.layout == .layered else { return false }
        return layerRenderer.configuration.drawableRenderContextStencilFormat != .invalid
    }

    /// True when the background should be transparent this frame — miss rays
    /// write alpha 0 and the pass clears transparent, so the compositor shows
    /// passthrough instead of black. Mixed style ONLY: in Immersive the frame
    /// renders opaque, because during fast head turns the compositor's late
    /// reprojection uncovers frame edges — with a transparent background those
    /// edges flash the (usually bright) room against the (usually dark) scene,
    /// which reads as clipping. Opaque frames reproject as black, like the old
    /// full-immersion mode.
    var passthroughBackgroundActive: Bool {
        guard drawableRenderContextRequired else { return false }
        switch appModel.immersionStyleForRenderer {
        case .immersive: return false
        case .mixed: return true
        }
    }

    /// Encodes the compositor's drawable render-context pass — REQUIRED before
    /// every present once the layer declares a render-context stencil format,
    /// in every immersion style. The context stamps the visible-pixel mask
    /// (the portal in Partial; the full texture in Full/Mixed) into an
    /// app-owned stencil texture, then draws the compositor's own effects
    /// (portal rim/fade) over the drawable. Runs as its own encoder after the
    /// scene pass so none of the cached scene pipelines need a stencil format —
    /// pixels hidden by the portal are shaded and then cropped by the
    /// compositor, which is correct-first; stencil-testing the scene pass is a
    /// later perf follow-up.
    ///
    /// Must be the last encoding before `drawable.encodePresent` — the render
    /// context takes ownership of the encoder and calls `endEncoding` itself.
    func encodeDrawableRenderContextPass(commandBuffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable) {
        guard #available(visionOS 26.0, *) else { return }
        let stencilFormat = layerRenderer.configuration.drawableRenderContextStencilFormat
        guard stencilFormat != .invalid,
              let stencil = ensurePortalStencilTexture(matching: drawable, format: stencilFormat) else { return }

        let renderContext = drawable.addRenderContext(commandBuffer: commandBuffer)

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.texture = drawable.depthTextures[0]
        descriptor.depthAttachment.loadAction = .load
        descriptor.depthAttachment.storeAction = .store
        descriptor.stencilAttachment.texture = stencil
        descriptor.stencilAttachment.loadAction = .clear
        descriptor.stencilAttachment.clearStencil = 0
        descriptor.stencilAttachment.storeAction = .dontCare
        descriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        descriptor.renderTargetArrayLength = drawable.views.count

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Progressive Immersion Portal"
        renderContext.drawMaskOnStencilAttachment(commandEncoder: encoder, value: 0xFF)
        renderContext.endEncoding(commandEncoder: encoder)

        if RENDERER_DEBUG && !hasLoggedProgressivePortal {
            hasLoggedProgressivePortal = true
            print("✓ Progressive immersion portal pass active (stencil format \(stencilFormat.rawValue))")
        }
    }

    /// Drawable-matched stencil texture for the portal mask. Memoryless — the
    /// mask is written and consumed within the single portal pass.
    private func ensurePortalStencilTexture(matching drawable: LayerRenderer.Drawable, format: MTLPixelFormat) -> MTLTexture? {
        let color = drawable.colorTextures[0]
        let arrayLength = max(1, drawable.views.count)
        if let existing = portalStencilTexture,
           existing.width == color.width,
           existing.height == color.height,
           existing.arrayLength == arrayLength,
           existing.pixelFormat == format {
            return existing
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = arrayLength > 1 ? .type2DArray : .type2D
        descriptor.pixelFormat = format
        descriptor.width = color.width
        descriptor.height = color.height
        descriptor.arrayLength = arrayLength
        descriptor.usage = .renderTarget
        descriptor.storageMode = .memoryless
        portalStencilTexture = device.makeTexture(descriptor: descriptor)
        return portalStencilTexture
    }

    func selectFramePath(settingsSnapshot: RenderSettingsSnapshot) -> RenderFramePath {
        // Resolution is now owned by the compositor's renderQuality (see
        // applyRenderQualityIfNeeded), independent of the render path, so the
        // path depends only on the tile mode. The compute path writes a
        // drawable-sized texture and blits 1:1, so it honours renderQuality too.
        if settingsSnapshot.prefersAdaptiveComputePath,
           adaptiveHierarchicalPipeline8x8 != nil {
            return .adaptiveCompute
        }
        return .fragment
    }

    /// visionOS 26+ runtime render-quality control. The compositor sizes the
    /// drawable's color texture from `layerRenderer.renderQuality` (clamped to
    /// the configuration's `maxRenderQuality`). If the app never sets it, it
    /// stays at `capabilities.defaultRenderQuality` — well below native — so the
    /// whole image is soft even at native render scale with MetalFX bypassed.
    /// Driven by the dedicated Render Quality setting (exposed in the Performance
    /// section): 1.0 = native (sharpest), lower = the compositor renders a
    /// smaller drawable and upscales it natively (foveation-aware, with a
    /// smoothed transition). Render-quality only takes effect when foveation is
    /// enabled.
    func applyRenderQualityIfNeeded(renderQuality: Float) {
        if #available(visionOS 26.0, *) {
            guard layerRenderer.configuration.isFoveationEnabled else { return }
            // maxRenderQuality is configured to 1.0; the system clamps to it.
            let target = max(0.0, min(renderQuality, 1.0))
            guard abs(target - lastAppliedRenderQuality) > 0.001 else { return }
            lastAppliedRenderQuality = target
            layerRenderer.renderQuality = LayerRenderer.RenderQuality(target)
            if RENDERER_DEBUG {
                print("🎯 renderQuality → \(String(format: "%.2f", target)) (drawable resizes over a smoothed ramp)")
            }
        }
    }

    /// Publishes the live render diagnostics (drawable resolution, applied
    /// render quality, path, foveation) to the control window. Only hops to the
    /// MainActor when a user-visible value changes; captures Sendable primitives
    /// only (never the non-Sendable drawable).
    func publishRenderDiagnostics(drawable: LayerRenderer.Drawable) {
        let w = drawable.colorTextures.first?.width ?? 0
        let h = drawable.colorTextures.first?.height ?? 0
        let foveation = layerRenderer.configuration.isFoveationEnabled
        let quality = lastAppliedRenderQuality
        let tile = appModel.renderSettings.tileSize
        let path = (tile == 8 && adaptiveHierarchicalPipeline8x8 != nil) ? "compute 8×8" : "fragment"

        // Foveation rate-map decode dims (eye 0) — the exact coordinate spaces the
        // compute path's ray reconstruction works in. Computed straight from the
        // drawable each frame (independent of the kernel's rate-map branch), so it
        // reports the truth even when the rate map is absent (→ linear path) or the
        // one-time console log already fired. This is what disambiguates whether the
        // distortion is the rate-map decode or a plain resolution mismatch.
        let rateMaps = drawable.rasterizationRateMaps
        let vp = drawable.views.first?.textureMap.viewport
        let vpW = Int((vp?.width ?? 0).rounded())
        let vpH = Int((vp?.height ?? 0).rounded())
        let vpOX = Int((vp?.originX ?? 0).rounded())
        let vpOY = Int((vp?.originY ?? 0).rounded())
        let decode: String
        if let map = rateMaps.first {
            let phys = map.physicalSize(layer: 0)
            let screen = map.screenSize
            let valid = (phys.width == w && phys.height == h)
            decode = "maps \(rateMaps.count)  phys \(phys.width)×\(phys.height)  screen \(screen.width)×\(screen.height)  vp \(vpW)×\(vpH)@\(vpOX),\(vpOY)  tex \(w)×\(h)  \(valid ? "valid" : "MISMATCH→linear")"
        } else {
            decode = "no rate map (linear path)  vp \(vpW)×\(vpH)@\(vpOX),\(vpOY)  tex \(w)×\(h)"
        }

        let key = "\(w)x\(h)|\(String(format: "%.2f", quality))|\(foveation)|\(path)|\(decode)"
        guard key != lastPublishedDiagnosticsKey else { return }
        lastPublishedDiagnosticsKey = key

        Task { @MainActor [weak appModel] in
            guard let appModel else { return }
            let metrics = appModel.renderMetrics
            metrics.drawableWidth = w
            metrics.drawableHeight = h
            metrics.renderQuality = quality
            metrics.foveationEnabled = foveation
            metrics.renderPath = path
            metrics.foveationDecode = decode
        }
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
        // Partial/Mixed immersion: clear transparent so pixels the proxy mesh
        // never covers show passthrough rather than opaque black (miss rays
        // inside the mesh go transparent in fragmentMain via
        // passthroughBackground).
        let clearAlpha: Double = passthroughBackgroundActive ? 0.0 : 1.0
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: clearAlpha)
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
        iterationsAvg: Double? = nil,
        frameBreakdown: FramePhaseBreakdown = .zero,
        settingsSnapshot: RenderSettingsSnapshot,
        useAdaptiveCompute: Bool,
        viewCount: Int,
        drawableWidth: Int,
        drawableHeight: Int
    ) {
        let shouldLogSlowFrame = consumeSlowFrameLogPermit(nowTime: nowTime, frameTimeSeconds: frameTimeSeconds)
        Self.recordFramePerf(
            frameTimeSeconds: frameTimeSeconds,
            cpuEncodeMs: cpuEncodeMs,
            gpuMs: gpuMs,
            iterationsAvg: iterationsAvg,
            frameBreakdown: frameBreakdown,
            shouldLogSlowFrame: shouldLogSlowFrame,
            settingsSnapshot: settingsSnapshot,
            useAdaptiveCompute: useAdaptiveCompute,
            viewCount: viewCount,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight
        )
    }

    // MARK: - visionOS 26+ Drawable Selection

    /// Select a drawable from `frame.queryDrawables()`.
    ///
    /// CompositorServices may return multiple drawables per frame. Use the highest
    /// resolution candidate here and let the app's own resolutionScale control
    /// low-res rendering. Picking the smallest drawable first double-dips quality
    /// loss before MetalFX ever sees the image.
    func selectDrawable(from drawables: [LayerRenderer.Drawable]) -> LayerRenderer.Drawable? {
        guard !drawables.isEmpty else { return nil }
        if drawables.count == 1 { return drawables[0] }

        struct Candidate {
            let drawable: LayerRenderer.Drawable
            let width: Double
            let height: Double
            let area: Double
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(drawables.count)
        for drawable in drawables {
            // Prefer physical render-target size (actual pixel workload). On visionOS,
            // viewports may be in rasterization-rate-map space and can exceed the
            // underlying texture dimensions.
            let tex = drawable.colorTextures.first
            let width = Double(max(1, tex?.width ?? 1))
            let height = Double(max(1, tex?.height ?? 1))
            candidates.append(Candidate(drawable: drawable, width: width, height: height, area: width * height))
        }

        var bestIndex = 0
        var bestArea = candidates[0].area
        for (index, candidate) in candidates.enumerated() {
            if candidate.area > bestArea {
                bestArea = candidate.area
                bestIndex = index
            }
        }

        if RENDERER_DEBUG && !hasLoggedDrawableQualityOptions {
            hasLoggedDrawableQualityOptions = true
            let maxTexWidth = Int(candidates.map(\.width).max() ?? 0)
            let maxTexHeight = Int(candidates.map(\.height).max() ?? 0)
            let maxVPWidth = Int(drawables.map { max(1.0, $0.views.first?.textureMap.viewport.width ?? 0) }.max() ?? 0)
            let maxVPHeight = Int(drawables.map { max(1.0, $0.views.first?.textureMap.viewport.height ?? 0) }.max() ?? 0)
            print("🔍 queryDrawables() returned \(drawables.count) candidates | maxTex=\(maxTexWidth)x\(maxTexHeight) maxVP=\(maxVPWidth)x\(maxVPHeight)")
            for (i, c) in candidates.enumerated() {
                let vp = c.drawable.views.first?.textureMap.viewport ?? MTLViewport()
                let vpW = Int(max(1.0, vp.width))
                let vpH = Int(max(1.0, vp.height))
                let q = sqrt(c.area / bestArea)
                print("   [\(i)] tex=\(Int(c.width))x\(Int(c.height)) vp=\(vpW)x\(vpH) q≈\(String(format: "%.2f", q))")
            }
            let chosen = candidates[bestIndex]
            let chosenVP = chosen.drawable.views.first?.textureMap.viewport ?? MTLViewport()
            let chosenQ = sqrt(chosen.area / bestArea)
            print("   → selected [\(bestIndex)] tex=\(Int(chosen.width))x\(Int(chosen.height)) vp=\(Int(max(1.0, chosenVP.width)))x\(Int(max(1.0, chosenVP.height))) q≈\(String(format: "%.2f", chosenQ))")
        }

        return candidates[bestIndex].drawable
    }


    nonisolated static func recordFramePerf(
        frameTimeSeconds: Double,
        cpuEncodeMs: Double,
        gpuMs: Double?,
        iterationsAvg: Double? = nil,
        frameBreakdown: FramePhaseBreakdown,
        shouldLogSlowFrame: Bool,
        settingsSnapshot: RenderSettingsSnapshot,
        useAdaptiveCompute: Bool,
        viewCount: Int,
        drawableWidth: Int,
        drawableHeight: Int
    ) {
        let frameMs = frameTimeSeconds * 1000.0

        // Feed the benchmark sweep when one is running. The `isCapturing` gate is
        // a lock-free bool read, so a normal frame pays almost nothing here.
        if BenchmarkManager.shared.isCapturing {
            BenchmarkManager.shared.recordSample(
                gpuMs: gpuMs,
                cpuMs: cpuEncodeMs,
                frameTimeMs: frameMs,
                iterationsAvg: iterationsAvg,
                renderPath: useAdaptiveCompute ? "compute 8x8" : "fragment",
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight,
                tileSize: settingsSnapshot.tileSize,
                iters: settingsSnapshot.fractalIterations,
                raySteps: settingsSnapshot.maxRaySteps,
                views: viewCount
            )
        }

        guard shouldLogSlowFrame else { return }

        let gpuText = gpuMs.map { String(format: "%.2f", $0) } ?? "n/a"
        let clockWaitText = String(format: "%.2f", frameBreakdown.clockWaitMs)
        let inFlightWaitText = String(format: "%.2f", frameBreakdown.inFlightWaitMs)
        let handTrackingText = String(format: "%.2f", frameBreakdown.handTrackingMs)
        let settingsUpdateText = String(format: "%.2f", frameBreakdown.settingsUpdateMs)
        let snapshotText = String(format: "%.2f", frameBreakdown.snapshotMs)
        let gameStateText = String(format: "%.2f", frameBreakdown.updateGameStateMs)
        let renderEncodeText = String(format: "%.2f", frameBreakdown.renderPathEncodeMs)

        let pathText = useAdaptiveCompute ? "compute" : "fragment"
        let fps = frameTimeSeconds > 0 ? (1.0 / frameTimeSeconds) : 0
        print("⚠️ Slow frame: ft=\(String(format: "%.2f", frameMs))ms fps=\(String(format: "%.1f", fps)) gpu=\(gpuText)ms cpu=\(String(format: "%.2f", cpuEncodeMs))ms wait=\(clockWaitText)ms inflight=\(inFlightWaitText)ms hand=\(handTrackingText)ms settings=\(settingsUpdateText)ms snap=\(snapshotText)ms game=\(gameStateText)ms encode=\(renderEncodeText)ms path=\(pathText) rt=\(drawableWidth)x\(drawableHeight) tile=\(settingsSnapshot.tileSize) iters=\(settingsSnapshot.fractalIterations) steps=\(settingsSnapshot.maxRaySteps) views=\(viewCount)")
    }

    /// Returns true when the fragment render path should render at low-res into
    /// MetalFX's input texture and spatially upscale to the drawable.
    ///
    /// On visionOS MetalFX provides **spatial** upscaling only (temporal is
    /// unsupported), so this path only applies to the fragment render path.
    /// The compute path is deliberately excluded for now — it can
    /// be routed through MetalFX in a future phase once depth ownership and
    /// tile-shared history semantics are designed.
    /// Minimum scale is clamped to 0.33 by `RenderSettings.resolutionScale`.
    /// Disabled on visionOS: MetalFX spatial upscaling has worse visual quality
    /// than compositor Render Quality here, adds extra offscreen texture memory,
    /// and has caused headset crashes under high settings.
    static let visionMetalFXSpatialEnabled = false

    func isMetalFXActive(for settingsSnapshot: RenderSettingsSnapshot, framePath: RenderFramePath) -> Bool {
        #if canImport(MetalFX)
        guard Renderer.visionMetalFXSpatialEnabled else { return false }
        switch framePath {
        case .adaptiveCompute:
            return false
        case .fragment:
            break
        }
        // Treat anything within 0.1% of native as "disabled" to avoid pointless
        // rebuilds at 0.999 due to float rounding. When the user's resolution
        // slider is at native (1.0), effective scale is 1.0 and MetalFX is
        // skipped — the image renders natively and is sharp. Below native, a
        // single MetalFX spatial upscale reconstructs the drawable.
        return effectiveResolutionScale(settingsSnapshot) < 0.999
        #else
        _ = (settingsSnapshot, framePath)
        return false
        #endif
    }

    #if canImport(MetalFX)
    /// visionOS upscale ceiling. At 1.0 the user's resolution slider drives the
    /// render scale directly: at 1.0 the fragment path renders natively and
    /// MetalFX is bypassed entirely (sharpest); below 1.0 a single MetalFX
    /// spatial upscale (+ RCAS sharpen) reconstructs the drawable. There is no
    /// closed-loop dynamic-resolution controller and no temporal accumulation —
    /// one predictable upscale the user controls.
    static let visionResolutionCeiling: Float = 1.0

    /// Per-frame render scale for the fragment+MetalFX path. The user's
    /// `resolutionScale` slider IS the scale (capped at the ceiling) — a single,
    /// predictable upscale rather than a closed-loop dynamic resolution.
    func effectiveResolutionScale(_ settingsSnapshot: RenderSettingsSnapshot) -> Float {
        min(settingsSnapshot.resolutionScale, Renderer.visionResolutionCeiling)
    }

    func estimatedVisionMetalFXBytes(drawable: LayerRenderer.Drawable, scale: Float) -> Int {
        let viewCount = max(1, drawable.views.count)
        let outWidth = max(1, drawable.colorTextures[0].width)
        let outHeight = max(1, drawable.colorTextures[0].height)
        let inputWidth = max(1, Int((Float(outWidth) * scale).rounded()))
        let inputHeight = max(1, Int((Float(outHeight) * scale).rounded()))

        // Input color + two input-depth history slices + output color.
        let colorBytes = MetalFXManager.estimatedBytesPerPixel(for: drawable.colorTextures[0].pixelFormat)
        let depthBytes = MetalFXManager.estimatedBytesPerPixel(for: drawable.depthTextures[0].pixelFormat)
        let inputPixels = inputWidth * inputHeight * viewCount
        let outputPixels = outWidth * outHeight * viewCount
        return inputPixels * (colorBytes + depthBytes + depthBytes) + outputPixels * colorBytes
    }

    func canAllocateVisionMetalFXTextures(
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        framePath: RenderFramePath
    ) -> Bool {
        guard Renderer.visionMetalFXSpatialEnabled else { return false }
        guard framePath == .fragment else { return false }
        let scale = effectiveResolutionScale(settingsSnapshot)
        guard scale < 0.999 else { return false }

        let estimatedBytes = estimatedVisionMetalFXBytes(drawable: drawable, scale: scale)
        let budgetBytes = 128 * 1024 * 1024
        if estimatedBytes <= budgetBytes { return true }

        if RENDERER_DEBUG {
            let mb = Double(estimatedBytes) / (1024.0 * 1024.0)
            print("⚠️ MetalFX spatial skipped: offscreen textures would use \(Int(mb.rounded())) MB")
        }
        metalFXManager = nil
        warmStartGate.invalidate()
        return false
    }
    #endif
}

#if canImport(MetalFX)
private struct MetalFXResolveParams {
    var aspectCorrection: Float = 1.0
    /// RCAS sharpening strength for the MetalFX resolve pass.
    /// 0.0 = no sharpening  1.0 = maximum adaptive sharpening
    /// Default 0.85 recovers most of the softness from the spatial upscale
    /// without producing visible haloing or ringing artifacts.
    var rcasStrength: Float = 0.85
    var pad0: Float = 0.0
    var pad1: Float = 0.0
}

extension Renderer {
    func scaledViewports(for drawable: LayerRenderer.Drawable, targetWidth: Int, targetHeight: Int) -> [MTLViewport] {
        let firstViewport = drawable.views.first?.textureMap.viewport ?? MTLViewport()
        // MetalFX renders each eye into its own dedicated offscreen texture slice.
        // Those slices have no drawable-style viewport padding, so preserving the
        // drawable viewport origin here compresses the image into a clipped subregion
        // and produces visible stretch/skew artifacts once MetalFX upscales it.
        // Render the full eye image into the full MetalFX input slice instead.
        let inputWidth = Double(max(1, targetWidth))
        let inputHeight = Double(max(1, targetHeight))
        let result: [MTLViewport] = drawable.views.map { view in
            let vp = view.textureMap.viewport
            return MTLViewport(
                originX: 0,
                originY: 0,
                width: inputWidth,
                height: inputHeight,
                znear: vp.znear,
                zfar: vp.zfar
            )
        }
        if RENDERER_DEBUG && !hasLoggedMetalFXLayout {
            hasLoggedMetalFXLayout = true
            let layoutName: String = {
                switch layerRenderer.configuration.layout {
                case .layered:   return "layered"
                case .dedicated: return "dedicated"
                case .shared:    return "shared"
                @unknown default: return "unknown"
                }
            }()
            print("🔍 MetalFX layout=\(layoutName) drawable.colorTextures.count=\(drawable.colorTextures.count) views=\(drawable.views.count) drawableEye=\(Int(firstViewport.width))x\(Int(firstViewport.height)) input=\(targetWidth)x\(targetHeight) offscreenViewport=(0,0,\(targetWidth)x\(targetHeight))")
            for (i, vp) in drawable.views.enumerated() {
                let src = vp.textureMap.viewport
                let dst = result[i]
                print("   view[\(i)] drawableVP=(\(src.originX),\(src.originY),\(src.width)x\(src.height)) scaledVP=(\(dst.originX),\(dst.originY),\(dst.width)x\(dst.height))")
            }
        }
        return result
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
                // NOTE: Synthesizing a downscaled rate map per scale bucket was
                // explored as a perf win, but `MTLRasterizationRateMap` does
                // not expose its horizontal/vertical sample arrays — we cannot
                // faithfully reconstruct a smaller version of the system's
                // gaze-tracked map. A hand-rolled Gaussian falloff would
                // produce a foveation curve that disagrees with the resolve
                // pass and adjacent frames, so we drop foveation cleanly here
                // when scale < 1.0.
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

        let viewCount = drawable.views.count
        let isDedicatedPerEyeColor =
            drawable.colorTextures.count == viewCount &&
            drawable.colorTextures.allSatisfy { $0.arrayLength == 1 }

        for eye in 0..<viewCount {
            let destinationTexture: MTLTexture
            let destinationSlice: Int

            if isDedicatedPerEyeColor {
                destinationTexture = drawable.colorTextures[eye]
                destinationSlice = 0
            } else {
                destinationTexture = drawable.colorTextures[0]
                destinationSlice = eye
            }

            // Safety: Metal validation will assert if we copy outside destination.
            let copyWidth = min(outputTexture.width, destinationTexture.width)
            let copyHeight = min(outputTexture.height, destinationTexture.height)
            if RENDERER_DEBUG && !hasLoggedMetalFXBlitSizeMismatch {
                if copyWidth != outputTexture.width || copyHeight != outputTexture.height ||
                    copyWidth != destinationTexture.width || copyHeight != destinationTexture.height {
                    hasLoggedMetalFXBlitSizeMismatch = true
                    print("⚠️ MetalFX blit size mismatch: out=\(outputTexture.width)x\(outputTexture.height) dst=\(destinationTexture.width)x\(destinationTexture.height) copying=\(copyWidth)x\(copyHeight)")
                }
            }

            blitEncoder.copy(
                from: outputTexture,
                sourceSlice: eye,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
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
                let isDedicatedPerEyeDepth =
                    drawable.depthTextures.count == viewCount &&
                    drawable.depthTextures.allSatisfy { $0.arrayLength == 1 }

                for eye in 0..<viewCount {
                    let destinationTexture: MTLTexture
                    let destinationSlice: Int

                    if isDedicatedPerEyeDepth {
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

    func resolveMetalFXOutputToDrawable(
        commandBuffer: MTLCommandBuffer,
        metalFX: MetalFXManager,
        drawable: LayerRenderer.Drawable,
        resolutionScale: Float
    ) {
        guard layerRenderer.configuration.layout == .layered,
              drawable.colorTextures.count == 1,
              drawable.depthTextures.count == 1,
              let colorPipeline = metalFXColorResolvePipeline,
              let depthPipeline = metalFXDepthResolvePipeline,
              let outputTexture = metalFX.outputTexture,
              let depthTexture = metalFX.depthTexture else {
            blitMetalFXOutputToDrawable(commandBuffer: commandBuffer, metalFX: metalFX, drawable: drawable)
            return
        }

        // Only set renderTargetArrayLength when the drawable texture is actually a 2D
        // array. If it's a plain 2D texture (arrayLength == 1), setting this parameter
        // to a value > 1 can cause Metal to misinterpret the resolve pass layout,
        // resulting in immediate aspect-ratio / sampling distortion.
        let colorTex = drawable.colorTextures[0]
        let wantsArrayRouting = drawable.views.count > 1
        let canUseArrayRouting = colorTex.textureType == .type2DArray && colorTex.arrayLength > 1

        // If we need multi-view routing but the drawable isn't a proper 2D array texture,
        // the resolve pass will sample incorrectly → fall back to blit to avoid distortion.
        if wantsArrayRouting && !canUseArrayRouting {
            blitMetalFXOutputToDrawable(commandBuffer: commandBuffer, metalFX: metalFX, drawable: drawable)
            return
        }

        let viewports = drawable.views.map { $0.textureMap.viewport }

        if RENDERER_DEBUG && !hasLoggedMetalFXResolve {
            hasLoggedMetalFXResolve = true
            print("🔍 MetalFX resolve: outputTex=\(outputTexture.width)x\(outputTexture.height)x\(outputTexture.arrayLength) depthTex=\(depthTexture.width)x\(depthTexture.height)x\(depthTexture.arrayLength) drawable=\(drawable.colorTextures[0].width)x\(drawable.colorTextures[0].height)x\(drawable.colorTextures[0].arrayLength) viewCount=\(drawable.views.count)")
            for (i, view) in drawable.views.enumerated() {
                let vp = view.textureMap.viewport
                print("   view[\(i)] viewport=(\(vp.originX),\(vp.originY),\(vp.width)x\(vp.height))")
            }
        }

        // Phase 2.6: Adaptive RCAS strength. At resolutionScale ≈ 1.0 there is
        // almost nothing to sharpen, and the 5-tap RCAS branch in the fragment
        // shader is wasted GPU time — zero it out so the shader's early-out
        // skips it entirely. Ramp from 0 the moment any upscale engages
        // (scale=1.0) up to ~0.95 at the most aggressive scale (0.33) so the
        // spatial-upscaled image stays crisp across the whole slider range.
        let upscaleAmount = ((1.0 - resolutionScale) / 0.67).clamped(to: 0.0...1.0)
        var params = MetalFXResolveParams()
        params.rcasStrength = upscaleAmount * 0.95

        // Preserve compositor foveation mapping in resolve passes; without this,
        // viewport-space sampling can appear zoomed/cropped per eye.
        let resolveRateMap: MTLRasterizationRateMap? = {
            guard let map = drawable.rasterizationRateMaps.first else { return nil }
            let physical = map.physicalSize(layer: 0)
            let colorTex = drawable.colorTextures[0]
            guard physical.width == colorTex.width, physical.height == colorTex.height else {
                return nil
            }
            return map
        }()

        let colorPassDescriptor = MTLRenderPassDescriptor()
        colorPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        colorPassDescriptor.colorAttachments[0].loadAction = .clear
        colorPassDescriptor.colorAttachments[0].storeAction = .store
        colorPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        colorPassDescriptor.renderTargetArrayLength = canUseArrayRouting ? drawable.views.count : 1
        colorPassDescriptor.rasterizationRateMap = resolveRateMap

        // Phase 2.7: When the merged pipeline is available, write color + depth
        // from a single fragment in one render encoder. Saves a full encoder
        // setup, an extra tile-load/store round-trip on the depth attachment,
        // and the second fullscreen draw.
        if let mergedPipeline = metalFXMergedResolvePipeline {
            colorPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
            colorPassDescriptor.depthAttachment.loadAction = .clear
            colorPassDescriptor.depthAttachment.storeAction = .store
            colorPassDescriptor.depthAttachment.clearDepth = 1.0

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: colorPassDescriptor) else {
                blitMetalFXOutputToDrawable(commandBuffer: commandBuffer, metalFX: metalFX, drawable: drawable)
                return
            }
            encoder.label = "Resolve MetalFX (Color+Depth merged)"
            encoder.setRenderPipelineState(mergedPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setViewports(viewports)
            applyVertexAmplificationIfNeeded(to: encoder, viewCount: drawable.views.count)
            encoder.setFragmentTexture(outputTexture, index: 0)
            encoder.setFragmentTexture(depthTexture, index: 1)
            encoder.setFragmentBytes(&params, length: MemoryLayout<MetalFXResolveParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return
        }

        guard let colorEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: colorPassDescriptor) else {
            blitMetalFXOutputToDrawable(commandBuffer: commandBuffer, metalFX: metalFX, drawable: drawable)
            return
        }

        colorEncoder.label = "Resolve MetalFX Color"
        colorEncoder.setRenderPipelineState(colorPipeline)
        colorEncoder.setViewports(viewports)
        applyVertexAmplificationIfNeeded(to: colorEncoder, viewCount: drawable.views.count)
        colorEncoder.setFragmentTexture(outputTexture, index: 0)
        colorEncoder.setFragmentBytes(&params, length: MemoryLayout<MetalFXResolveParams>.stride, index: 0)
        colorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        colorEncoder.endEncoding()

        let depthPassDescriptor = MTLRenderPassDescriptor()
        depthPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
        depthPassDescriptor.depthAttachment.loadAction = .clear
        depthPassDescriptor.depthAttachment.storeAction = .store
        depthPassDescriptor.depthAttachment.clearDepth = 1.0
        depthPassDescriptor.renderTargetArrayLength = canUseArrayRouting ? drawable.views.count : 1
        depthPassDescriptor.rasterizationRateMap = resolveRateMap

        guard let depthEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depthPassDescriptor) else {
            return
        }

        depthEncoder.label = "Resolve MetalFX Depth"
        depthEncoder.setRenderPipelineState(depthPipeline)
        depthEncoder.setDepthStencilState(depthState)
        depthEncoder.setViewports(viewports)
        applyVertexAmplificationIfNeeded(to: depthEncoder, viewCount: drawable.views.count)
        depthEncoder.setFragmentTexture(depthTexture, index: 0)
        depthEncoder.setFragmentBytes(&params, length: MemoryLayout<MetalFXResolveParams>.stride, index: 0)
        depthEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        depthEncoder.endEncoding()
    }

    func updateMetalFXManager(
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        rasterizationRateMap: MTLRasterizationRateMap?
    ) -> (MetalFXManager, Int, Int)? {
        let viewCount = drawable.views.count

        // CRITICAL: Use the drawable texture's *physical* size (actual pixels).
        // On visionOS, `textureMap.viewport` can be in rasterization-rate-map
        // space and may exceed the underlying render target dimensions.
        let outputWidth = max(1, drawable.colorTextures[0].width)
        let outputHeight = max(1, drawable.colorTextures[0].height)

        let drawableColorFormat = drawable.colorTextures[0].pixelFormat
        let drawableDepthFormat = drawable.depthTextures[0].pixelFormat

        // Phase 1.1: Clamp MetalFX input dimensions to a safe minimum.
        // MTLFXSpatialScaler rejects (or crashes on) very small inputs and the
        // app currently exposes resolutionScale down to 0.33, so a small
        // drawable + low scale can land below the scaler's tolerated range.
        let renderScale = effectiveResolutionScale(settingsSnapshot)
        let rawInputWidth = max(1, Int((Float(outputWidth) * renderScale).rounded()))
        let rawInputHeight = max(1, Int((Float(outputHeight) * renderScale).rounded()))

        let shortEdgeMin = MetalFXManager.minimumInputShortEdge
        let longEdgeMin = MetalFXManager.minimumInputLongEdge
        let rawShort = min(rawInputWidth, rawInputHeight)
        // Aspect-preserving scale-up if either edge is below its minimum.
        let neededShort = max(1, shortEdgeMin)
        let scaleShort = rawShort < neededShort ? Float(neededShort) / Float(max(1, rawShort)) : 1.0
        var inputWidth = max(1, Int((Float(rawInputWidth) * scaleShort).rounded()))
        var inputHeight = max(1, Int((Float(rawInputHeight) * scaleShort).rounded()))
        let rawLong = max(inputWidth, inputHeight)
        let neededLong = max(longEdgeMin, neededShort)
        if rawLong < neededLong {
            let scaleLong = Float(neededLong) / Float(max(1, rawLong))
            inputWidth = max(1, Int((Float(inputWidth) * scaleLong).rounded()))
            inputHeight = max(1, Int((Float(inputHeight) * scaleLong).rounded()))
        }
        // Never request an input larger than the output; if clamping pushes us
        // close to native, fall back to direct rendering — the upscale becomes
        // a near-1x copy plus RCAS overhead with no quality benefit.
        inputWidth = min(inputWidth, outputWidth)
        inputHeight = min(inputHeight, outputHeight)

        // Phase 2.9: Snap input dimensions to 16-px buckets so 1-pixel slider
        // movements don't trigger texture + scaler rebuilds. The user can't
        // perceive sub-bucket resolution differences anyway.
        let bucket = 16
        if inputWidth >= bucket * 2 {
            inputWidth = ((inputWidth + bucket / 2) / bucket) * bucket
        }
        if inputHeight >= bucket * 2 {
            inputHeight = ((inputHeight + bucket / 2) / bucket) * bucket
        }
        inputWidth = min(inputWidth, outputWidth)
        inputHeight = min(inputHeight, outputHeight)
        let widthRatio = Float(inputWidth) / Float(max(1, outputWidth))
        let heightRatio = Float(inputHeight) / Float(max(1, outputHeight))
        if min(widthRatio, heightRatio) >= 0.95 {
            // Effective scale is too close to native after clamping — skip MetalFX.
            if !hasLoggedMetalFXFallback {
                hasLoggedMetalFXFallback = true
                print("⚠️ MetalFX skipped: requested scale=\(settingsSnapshot.resolutionScale) but clamped input \(inputWidth)x\(inputHeight) is ≥ 95% of output \(outputWidth)x\(outputHeight). Rendering direct.")
            }
            metalFXManager = nil
            return nil
        }
        if (inputWidth, inputHeight) != (rawInputWidth, rawInputHeight) {
            // One-shot informational log so we can confirm the clamp is engaging.
            if !hasLoggedMetalFXClamp {
                hasLoggedMetalFXClamp = true
                print("ℹ️ MetalFX input clamped: scale=\(settingsSnapshot.resolutionScale) raw=\(rawInputWidth)x\(rawInputHeight) -> \(inputWidth)x\(inputHeight) (output=\(outputWidth)x\(outputHeight))")
            }
        }

        // Phase 1.5: If an existing manager has a stale pixel format (e.g. the
        // compositor reallocated drawables with a different format), drop it
        // and rebuild fresh instead of asking `update()` to detect the change
        // mid-frame.
        if let existing = metalFXManager,
           existing.configuration.colorFormat != drawableColorFormat ||
           existing.configuration.depthFormat != drawableDepthFormat {
            metalFXManager = nil
        }

        let config = MetalFXManager.Configuration(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormat: drawableColorFormat,
            depthFormat: drawableDepthFormat,
            scale: settingsSnapshot.resolutionScale
        )

        do {
            if metalFXManager == nil {
                metalFXManager = try MetalFXManager(device: device, configuration: config, viewCount: viewCount)
            } else {
                try metalFXManager?.update(configuration: config, viewCount: viewCount)
            }
        } catch {
            // Production-visible log: we want to see the failing dims even in
            // release builds, since this path is on the user-reported crash.
            print("⚠️ MetalFX init/update failed: \(error). Falling back to direct rendering.")
            hasLoggedMetalFXFallback = true
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

        // Phase 1.2: fence is now created eagerly in Renderer.init().
        // Defensive fallback if construction failed there for any reason.
        if metalFXFence == nil {
            metalFXFence = device.makeFence()
            metalFXFence?.label = "MetalFX Fragment→Scaler (lazy)"
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
