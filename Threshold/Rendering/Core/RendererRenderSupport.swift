@preconcurrency import CompositorServices
import Foundation
import Metal

// RenderFramePath / RendererFragmentPassPlan / FramePhaseBreakdown now live in
// Rendering/Core/FramePath.swift.

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
        framePath _: RenderFramePath
    ) -> RendererFragmentPassPlan {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        let directViewports = drawable.views.map { $0.textureMap.viewport }

        configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)
        return RendererFragmentPassPlan(
            renderPassDescriptor: renderPassDescriptor,
            viewports: directViewports,
            resolutionScale: settingsSnapshot.resolutionScale
        )
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
        case .immersive, .window: return false
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
    /// whole image remains soft unless the app applies the user's quality target.
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
    /// resolution candidate here; the compositor's render-quality setting owns
    /// any intentional resolution reduction. Picking the smallest drawable would
    /// introduce a second, uncontrolled quality loss.
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

}
