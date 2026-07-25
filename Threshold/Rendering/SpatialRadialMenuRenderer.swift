#if os(visionOS)
@preconcurrency import CompositorServices
import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

struct SpatialRadialLabelAtlas {
    let texture: MTLTexture
    let uvByNodeID: [String: SIMD4<Float>]
}

private struct SpatialRadialGPUInstance {
    var centerAndKind: SIMD4<Float>
    var rightAndHalfWidth: SIMD4<Float>
    var upAndHalfHeight: SIMD4<Float>
    var fillColor: SIMD4<Float>
    var strokeColor: SIMD4<Float>
    var labelUVRect: SIMD4<Float>
}

private struct SpatialRadialViewUniforms {
    var viewProjection0: matrix_float4x4
    var viewProjection1: matrix_float4x4
}

private enum SpatialRadialPrimitiveKind: Float {
    case card = 0
    case ring = 1
    case hub = 2
    case cursor = 3
}

enum SpatialRadialPresentationResult: Equatable, Sendable {
    case presented
    case unavailable
    case superseded
}

extension Renderer {
    private static var spatialRadialMaximumInstances: Int { 128 }

    /// Captures the currently tracked palm and device-facing basis exactly once.
    /// The reducer keeps that plant immutable until dismissal.
    func presentSpatialRadialMenu(
        focusing nodeID: String?,
        generation: UInt64
    ) -> SpatialRadialPresentationResult {
        guard generation > spatialRadialPresentationGeneration else {
            return .superseded
        }
        spatialRadialPresentationGeneration = generation
        // A newer presentation replaces any older plant. Every failure below
        // therefore leaves the compositor reducer inactive.
        spatialRadialInteraction.reset()

        guard spatialHandTrackingIsRunning,
              hasValidDevicePose,
              ensureSpatialRadialResources(),
              let pose = pendingSpatialActivationPose ?? latestSpatialHandPose else {
            pendingSpatialActivationPose = nil
            pendingSpatialActivationHand = nil
            return .unavailable
        }
        pendingSpatialActivationPose = nil

        let preferred = pendingSpatialActivationHand
            ?? (appModel.renderSettings.leftHandedMode ? .left : .right)
        pendingSpatialActivationHand = nil
        let fallback: SpatialRadialHand = preferred == .left ? .right : .left

        guard let selected = trackedPalm(for: preferred, in: pose)
            .map({ (preferred, $0) })
            ?? trackedPalm(for: fallback, in: pose).map({ (fallback, $0) })
        else {
            return .unavailable
        }

        return spatialRadialInteraction.activate(
            at: selected.1,
            headPosition: latestDevicePosition,
            hand: selected.0,
            focusing: nodeID,
            in: spatialRadialHierarchy
        ) ? .presented : .unavailable
    }

    func dismissSpatialRadialMenu(generation: UInt64) {
        guard generation > spatialRadialPresentationGeneration else { return }
        spatialRadialPresentationGeneration = generation
        pendingSpatialActivationPose = nil
        pendingSpatialActivationHand = nil
        spatialRadialInteraction.reset()
    }

    func clearSpatialRadialTrackingState(atTime time: TimeInterval) {
        spatialHandTrackingIsRunning = false
        lastSpatialHandTrackingLossTime = max(lastSpatialHandTrackingLossTime, time)
        latestSpatialHandPose = nil
        pendingSpatialActivationPose = nil
        pendingSpatialActivationHand = nil
    }

    /// Gesture recognition runs off the render actor. Preserve the exact sample
    /// that produced a menu command so later hand updates cannot shift the plant
    /// before the MainActor presentation edge executes.
    func captureSpatialRadialActivationPose(
        _ pose: HandPoseSnapshot,
        hand: GestureHandMode?
    ) {
        guard spatialHandTrackingIsRunning,
              pose.timestamp > lastSpatialHandTrackingLossTime else {
            return
        }
        pendingSpatialActivationPose = pose
        switch hand {
        case .left:
            pendingSpatialActivationHand = .left
        case .right:
            pendingSpatialActivationHand = .right
        case .both, nil:
            pendingSpatialActivationHand = nil
        }
    }

    /// Called before gesture-dispatch coalescing, so direct menu motion receives
    /// every available hand sample even while scene parameter gestures are busy.
    func updateSpatialRadialHandInteraction(with pose: HandPoseSnapshot?) {
        guard spatialRadialInteraction.isActive else { return }

        let position: SIMD3<Float>?
        if let pose, let hand = spatialRadialInteraction.hand {
            position = trackedPalm(for: hand, in: pose)
        } else {
            position = nil
        }

        let outcome = spatialRadialInteraction.update(
            handPosition: position,
            in: spatialRadialHierarchy
        )
        guard case .activate(let nodeID) = outcome,
              let target = spatialRadialHierarchy.node(withID: nodeID)?.target else {
            return
        }

        Task { @MainActor [weak appModel] in
            appModel?.activateSpatialNavigationTarget(target)
        }
    }

    /// Adds the spatial controls after either the compute blit or fragment
    /// resolve, and before the compositor's required progressive-portal pass.
    func encodeSpatialRadialMenuPass(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        preserveSceneDepth: Bool
    ) {
        guard spatialRadialInteraction.isActive,
              let pipeline = spatialRadialPipeline,
              let depthState = spatialRadialDepthState,
              let instanceBuffer = spatialRadialInstanceBuffer,
              let atlas = spatialRadialLabelAtlas else {
            return
        }

        let instances = makeSpatialRadialInstances()
        guard !instances.isEmpty,
              instances.count <= Self.spatialRadialMaximumInstances else {
            return
        }

        let stride = MemoryLayout<SpatialRadialGPUInstance>.stride
        let slotLength = stride * Self.spatialRadialMaximumInstances
        let slotOffset = uniformBufferIndex * slotLength
        instances.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            memcpy(
                instanceBuffer.contents().advanced(by: slotOffset),
                baseAddress,
                source.count * stride
            )
        }

        // A position-only fallback loses head orientation and makes a planted
        // world-space menu visibly rotate on a transient anchor miss. Preserve
        // spatial stability by omitting that overlay frame instead.
        guard hasValidDevicePose,
              let deviceTransform =
            drawable.deviceAnchor?.originFromAnchorTransform else {
            return
        }
        let viewProjections = drawable.views.enumerated().map { index, view in
            drawable.computeProjection(viewIndex: index)
                * (deviceTransform * view.transform).inverse
        }
        guard !viewProjections.isEmpty else { return }

        if drawable.colorTextures.count == 1,
           drawable.depthTextures.count == 1 {
            var uniforms = SpatialRadialViewUniforms(
                viewProjection0: viewProjections[0],
                viewProjection1: viewProjections[min(1, viewProjections.count - 1)]
            )
            encodeSpatialRadialLayeredPass(
                commandBuffer: commandBuffer,
                drawable: drawable,
                pipeline: pipeline,
                depthState: depthState,
                instanceBuffer: instanceBuffer,
                instanceBufferOffset: slotOffset,
                instanceCount: instances.count,
                atlas: atlas.texture,
                uniforms: &uniforms,
                preserveSceneDepth: preserveSceneDepth
            )
            return
        }

        encodeSpatialRadialDedicatedPasses(
            commandBuffer: commandBuffer,
            drawable: drawable,
            viewProjections: viewProjections,
            pipeline: pipeline,
            depthState: depthState,
            instanceBuffer: instanceBuffer,
            instanceBufferOffset: slotOffset,
            instanceCount: instances.count,
            atlas: atlas.texture,
            preserveSceneDepth: preserveSceneDepth
        )
    }

    private func trackedPalm(
        for hand: SpatialRadialHand,
        in pose: HandPoseSnapshot
    ) -> SIMD3<Float>? {
        let data = hand == .left ? pose.leftHand : pose.rightHand
        guard data.isTracked else { return nil }
        if simd_length_squared(data.palmCenter) > 0.000_001 {
            return data.palmCenter
        }
        if simd_length_squared(data.palmPosition) > 0.000_001 {
            return data.palmPosition
        }
        return nil
    }

    private func ensureSpatialRadialResources() -> Bool {
        if spatialRadialPipeline != nil,
           spatialRadialDepthState != nil,
           spatialRadialInstanceBuffer != nil,
           spatialRadialLabelAtlas != nil {
            return true
        }

        guard let library = Renderer.bundledDefaultLibrary(device: device),
              let vertex = library.makeFunction(name: "spatialRadialVertex"),
              let fragment = library.makeFunction(name: "spatialRadialFragment") else {
            return false
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Planted Spatial Radial Menu"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        descriptor.rasterSampleCount = rasterSampleCount
        descriptor.maxVertexAmplificationCount =
            max(1, layerRenderer.properties.viewCount)

        let color = descriptor.colorAttachments[0]!
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return false
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        // Controls remain readable over the raymarched surface, while writing
        // their real projected depth for compositor reprojection.
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return false
        }

        let stride = MemoryLayout<SpatialRadialGPUInstance>.stride
        let bufferLength =
            stride * Self.spatialRadialMaximumInstances * maxBuffersInFlight
        guard let instanceBuffer = device.makeBuffer(
            length: bufferLength,
            options: .storageModeShared
        ), let atlas = makeSpatialRadialLabelAtlas() else {
            return false
        }
        instanceBuffer.label = "Spatial Radial Instances"

        spatialRadialPipeline = pipeline
        spatialRadialDepthState = depthState
        spatialRadialInstanceBuffer = instanceBuffer
        spatialRadialLabelAtlas = atlas
        return true
    }

    private func makeSpatialRadialLabelAtlas() -> SpatialRadialLabelAtlas? {
        var nodes: [NavigationHierarchy.Node] = []
        func append(_ candidates: [NavigationHierarchy.Node]) {
            for node in candidates {
                nodes.append(node)
                append(node.children)
            }
        }
        append(spatialRadialHierarchy.roots)
        guard !nodes.isEmpty else { return nil }

        let cellWidth = 320
        let cellHeight = 88
        let columns = 4
        let rows = Int(ceil(Double(nodes.count) / Double(columns)))
        let width = cellWidth * columns
        let height = cellHeight * rows
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo =
            CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let font = CTFontCreateWithName("SF Pro Display" as CFString, 23, nil)
        let foreground = CGColor(
            colorSpace: colorSpace,
            components: [1, 1, 1, 1]
        )!

        var uvByNodeID: [String: SIMD4<Float>] = [:]
        let madeContext = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity

            for (index, node) in nodes.enumerated() {
                let column = index % columns
                let row = index / columns
                let x = column * cellWidth
                let y = row * cellHeight
                let label = node.isBranch ? "\(node.title)  ›" : node.title
                let attributes: CFDictionary = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: foreground,
                ] as CFDictionary
                guard let attributed = CFAttributedStringCreate(
                    nil,
                    label as CFString,
                    attributes
                ) else {
                    continue
                }
                let line = CTLineCreateWithAttributedString(attributed)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let lineWidth = CGFloat(
                    CTLineGetTypographicBounds(
                        line,
                        &ascent,
                        &descent,
                        &leading
                    )
                )
                let textX = CGFloat(x) + max(12, (CGFloat(cellWidth) - lineWidth) * 0.5)
                let baseline = CGFloat(y)
                    + (CGFloat(cellHeight) + ascent - descent) * 0.5
                context.textPosition = CGPoint(x: textX, y: baseline)
                CTLineDraw(line, context)

                let inset: Float = 5
                uvByNodeID[node.id] = SIMD4<Float>(
                    (Float(x) + inset) / Float(width),
                    (Float(y) + inset) / Float(height),
                    (Float(x + cellWidth) - inset) / Float(width),
                    (Float(y + cellHeight) - inset) / Float(height)
                )
            }
            return true
        }
        guard madeContext else { return nil }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }
        texture.label = "Spatial Radial Label Atlas"
        pixels.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
        return SpatialRadialLabelAtlas(
            texture: texture,
            uvByNodeID: uvByNodeID
        )
    }

    private func makeSpatialRadialInstances() -> [SpatialRadialGPUInstance] {
        guard let plant = spatialRadialInteraction.plant,
              let atlas = spatialRadialLabelAtlas else {
            return []
        }

        let navigation = spatialRadialInteraction.navigation
        let activeDepth = navigation.depth
        var instances: [SpatialRadialGPUInstance] = []
        instances.reserveCapacity(48)

        func instance(
            localCenter: SIMD3<Float>,
            halfSize: SIMD2<Float>,
            kind: SpatialRadialPrimitiveKind,
            fill: SIMD4<Float>,
            stroke: SIMD4<Float>,
            labelUV: SIMD4<Float> = .zero
        ) -> SpatialRadialGPUInstance {
            let worldCenter = plant.worldPosition(of: localCenter)
            return SpatialRadialGPUInstance(
                centerAndKind: SIMD4<Float>(
                    worldCenter.x,
                    worldCenter.y,
                    worldCenter.z,
                    kind.rawValue
                ),
                rightAndHalfWidth: SIMD4<Float>(
                    plant.right.x,
                    plant.right.y,
                    plant.right.z,
                    halfSize.x
                ),
                upAndHalfHeight: SIMD4<Float>(
                    plant.up.x,
                    plant.up.y,
                    plant.up.z,
                    halfSize.y
                ),
                fillColor: fill,
                strokeColor: stroke,
                labelUVRect: labelUV
            )
        }

        // Center hub marks the immutable activation point.
        instances.append(
            instance(
                localCenter: SIMD3<Float>(0, 0, 0.004),
                halfSize: SIMD2<Float>(repeating: 0.048),
                kind: .hub,
                fill: SIMD4<Float>(0.02, 0.16, 0.20, 0.82),
                stroke: SIMD4<Float>(0.10, 0.90, 1.00, 0.95)
            )
        )

        for depth in 0...activeDepth {
            let radius = SpatialRadialGeometry.ringRadius(forDepth: depth)
            let isActiveRing = depth == activeDepth
            instances.append(
                instance(
                    localCenter: SIMD3<Float>(0, 0, -0.003 - Float(depth) * 0.001),
                    halfSize: SIMD2<Float>(repeating: radius + 0.012),
                    kind: .ring,
                    fill: isActiveRing
                        ? SIMD4<Float>(0.08, 0.80, 0.94, 0.42)
                        : SIMD4<Float>(0.05, 0.46, 0.58, 0.18),
                    stroke: .zero
                )
            )

            let nodes = navigation.visibleNodes(
                atDepth: depth,
                in: spatialRadialHierarchy
            )
            for (index, node) in nodes.enumerated() {
                let position = SpatialRadialGeometry.localPosition(
                    index: index,
                    count: nodes.count,
                    depth: depth
                ) + SIMD3<Float>(0, 0, 0.006 + Float(depth) * 0.002)
                let isHighlighted =
                    depth == activeDepth
                    && navigation.highlightedNodeID == node.id
                let isSelectedBranch =
                    depth < navigation.path.count
                    && navigation.path[depth] == node.id

                let fill: SIMD4<Float>
                let stroke: SIMD4<Float>
                if isHighlighted {
                    fill = SIMD4<Float>(0.92, 0.24, 0.04, 0.92)
                    stroke = SIMD4<Float>(1.00, 0.72, 0.20, 1.00)
                } else if isSelectedBranch {
                    fill = SIMD4<Float>(0.02, 0.46, 0.62, 0.86)
                    stroke = SIMD4<Float>(0.22, 0.94, 1.00, 0.96)
                } else {
                    fill = SIMD4<Float>(0.01, 0.025, 0.04, 0.80)
                    stroke = node.isBranch
                        ? SIMD4<Float>(0.08, 0.74, 0.90, 0.78)
                        : SIMD4<Float>(0.72, 0.82, 0.88, 0.36)
                }

                instances.append(
                    instance(
                        localCenter: position,
                        halfSize: SpatialRadialGeometry.ringItemHalfSize,
                        kind: .card,
                        fill: fill,
                        stroke: stroke,
                        labelUV: atlas.uvByNodeID[node.id] ?? .zero
                    )
                )
            }
        }

        // The active commit threshold is a second, warm-colored guide: crossing
        // it with a direct hand commits the highlighted branch or leaf.
        let commitRadius = SpatialRadialGeometry.commitRadius(forDepth: activeDepth)
        instances.append(
            instance(
                localCenter: SIMD3<Float>(0, 0, -0.005),
                halfSize: SIMD2<Float>(repeating: commitRadius + 0.012),
                kind: .ring,
                fill: SIMD4<Float>(1.00, 0.36, 0.05, 0.22),
                stroke: .zero
            )
        )

        if var cursor = spatialRadialInteraction.cursorLocalPosition {
            cursor.z = 0.016
            let radialLength = hypot(cursor.x, cursor.y)
            if radialLength > SpatialRadialGeometry.maximumReach {
                let scale = SpatialRadialGeometry.maximumReach / radialLength
                cursor.x *= scale
                cursor.y *= scale
            }
            instances.append(
                instance(
                    localCenter: cursor,
                    halfSize: SIMD2<Float>(repeating: 0.024),
                    kind: .cursor,
                    fill: SIMD4<Float>(1.00, 0.27, 0.04, 0.94),
                    stroke: SIMD4<Float>(1.00, 0.92, 0.64, 1.00)
                )
            )
        }

        return instances
    }

    private func encodeSpatialRadialLayeredPass(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        pipeline: MTLRenderPipelineState,
        depthState: MTLDepthStencilState,
        instanceBuffer: MTLBuffer,
        instanceBufferOffset: Int,
        instanceCount: Int,
        atlas: MTLTexture,
        uniforms: inout SpatialRadialViewUniforms,
        preserveSceneDepth: Bool
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.texture = drawable.depthTextures[0]
        descriptor.depthAttachment.loadAction =
            preserveSceneDepth ? .load : .clear
        descriptor.depthAttachment.clearDepth = 1.0
        descriptor.depthAttachment.storeAction = .store
        descriptor.renderTargetArrayLength =
            drawable.colorTextures[0].textureType == .type2DArray
            ? drawable.views.count
            : 1
        descriptor.rasterizationRateMap = compatibleRateMap(
            drawable.rasterizationRateMaps.first,
            texture: drawable.colorTextures[0],
            layer: 0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor
        ) else {
            return
        }
        encoder.label = "Planted Spatial Radial Menu"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setViewports(drawable.views.map(\.textureMap.viewport))
        applyVertexAmplificationIfNeeded(
            to: encoder,
            viewCount: descriptor.renderTargetArrayLength
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<SpatialRadialViewUniforms>.stride,
            index: 0
        )
        encoder.setVertexBuffer(
            instanceBuffer,
            offset: instanceBufferOffset,
            index: 1
        )
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instanceCount
        )
        encoder.endEncoding()
    }

    private func encodeSpatialRadialDedicatedPasses(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        viewProjections: [matrix_float4x4],
        pipeline: MTLRenderPipelineState,
        depthState: MTLDepthStencilState,
        instanceBuffer: MTLBuffer,
        instanceBufferOffset: Int,
        instanceCount: Int,
        atlas: MTLTexture,
        preserveSceneDepth: Bool
    ) {
        let count = min(
            drawable.views.count,
            min(drawable.colorTextures.count, drawable.depthTextures.count)
        )
        for index in 0..<count {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.colorTextures[index]
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.depthAttachment.texture = drawable.depthTextures[index]
            descriptor.depthAttachment.loadAction =
                preserveSceneDepth ? .load : .clear
            descriptor.depthAttachment.clearDepth = 1.0
            descriptor.depthAttachment.storeAction = .store
            let rateMap = drawable.rasterizationRateMaps.count == count
                ? drawable.rasterizationRateMaps[index]
                : drawable.rasterizationRateMaps.first
            descriptor.rasterizationRateMap = compatibleRateMap(
                rateMap,
                texture: drawable.colorTextures[index],
                layer: 0
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            ) else {
                continue
            }
            var uniforms = SpatialRadialViewUniforms(
                viewProjection0: viewProjections[index],
                viewProjection1: viewProjections[index]
            )
            encoder.label = "Planted Spatial Radial Menu Eye \(index)"
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setViewport(drawable.views[index].textureMap.viewport)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<SpatialRadialViewUniforms>.stride,
                index: 0
            )
            encoder.setVertexBuffer(
                instanceBuffer,
                offset: instanceBufferOffset,
                index: 1
            )
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: instanceCount
            )
            encoder.endEncoding()
        }
    }

    private func compatibleRateMap(
        _ map: MTLRasterizationRateMap?,
        texture: MTLTexture,
        layer: Int
    ) -> MTLRasterizationRateMap? {
        guard let map else { return nil }
        let physical = map.physicalSize(layer: layer)
        return physical.width == texture.width && physical.height == texture.height
            ? map
            : nil
    }
}
#endif
