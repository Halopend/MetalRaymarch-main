import Foundation
@preconcurrency import Metal
import MetalKit

extension Renderer {
    /// Setup screenshot capture resources
    func setupScreenshotCapture() async {
        let screenshotSize = 512

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: screenshotSize,
            height: screenshotSize,
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .shared
        screenshotTexture = device.makeTexture(descriptor: colorDescriptor)
        screenshotTexture?.label = "Screenshot Color"

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: screenshotSize,
            height: screenshotSize,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        screenshotDepthTexture = device.makeTexture(descriptor: depthDescriptor)
        screenshotDepthTexture?.label = "Screenshot Depth"

        screenshotUniformBuffer = device.makeBuffer(
            length: alignedUniformsSize,
            options: [.storageModeShared]
        )
        screenshotUniformBuffer?.label = "Screenshot Uniforms"

        do {
            guard let library = Renderer.bundledDefaultLibrary(device: device) else {
                if RENDERER_DEBUG { print("⚠️ Failed to load default Metal library for screenshot setup") }
                return
            }
            let vertexFunction = library.makeFunction(name: "screenshotVertexShader")
            let fragmentFunction = try await library.makeFunction(
                name: "fragmentShader",
                constantValues: MTLFunctionConstantValues()
            )

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Screenshot Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            let mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()
            pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

            let pipeline: MTLRenderPipelineState = try await withCheckedThrowingContinuation { continuation in
                // Pipeline compilation can take long enough to starve the
                // compositor when performed synchronously on the Renderer
                // actor. Metal completes this on its own worker thread.
                device.makeRenderPipelineState(descriptor: pipelineDescriptor) { pipeline, error in
                    if let pipeline {
                        continuation.resume(returning: pipeline)
                    } else {
                        continuation.resume(throwing: error ?? NSError(
                            domain: "Threshold.RendererScreenshot",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Metal returned no screenshot pipeline"]
                        ))
                    }
                }
            }
            guard !Task.isCancelled else { return }
            screenshotPipeline = pipeline
            if RENDERER_DEBUG { print("✓ Screenshot capture pipeline ready") }
        } catch {
            if RENDERER_DEBUG { print("⚠️ Failed to create screenshot pipeline: \(error)") }
        }
    }

    /// Request a screenshot capture (async)
    func captureScreenshot() async -> Data? {
        return await withCheckedContinuation { continuation in
            self.pendingScreenshotContinuation = continuation
            self.shouldCaptureScreenshot = true
        }
    }

    /// Render and capture a screenshot to PNG data.
    /// Uses addCompletedHandler instead of waitUntilCompleted to avoid blocking the render thread.
    func renderScreenshot() {
        guard let screenshotTexture = screenshotTexture,
              let screenshotPipeline = screenshotPipeline,
              let screenshotDepthTexture = screenshotDepthTexture,
              let screenshotUniformBuffer = screenshotUniformBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            pendingScreenshotContinuation?.resume(returning: nil)
            pendingScreenshotContinuation = nil
            return
        }

        // A screenshot command buffer is not part of the renderer's in-flight
        // ring semaphore. Binding the live ring slot lets a later frame
        // overwrite matrices and bindless addresses while the screenshot is
        // still executing. Give capture an immutable copy of the latest slot.
        screenshotUniformBuffer.contents().copyMemory(
            from: dynamicUniformBuffer.contents().advanced(by: uniformBufferOffset),
            byteCount: MemoryLayout<UniformsArray>.size
        )
        let screenshotEnvironmentGrid = lastSubmittedEnvironmentGrid

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = screenshotTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

        renderPassDescriptor.depthAttachment.texture = screenshotDepthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            pendingScreenshotContinuation?.resume(returning: nil)
            pendingScreenshotContinuation = nil
            return
        }

        renderEncoder.label = "Screenshot Render Encoder"
        renderEncoder.setCullMode(.front)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(screenshotPipeline)
        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(screenshotUniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentBuffer(screenshotUniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        if let screenshotEnvironmentGrid {
            // EnvScrunchParams carries a GPU address, so Metal needs both an
            // explicit residency declaration and a strong lifetime through
            // command-buffer completion.
            renderEncoder.useResource(
                screenshotEnvironmentGrid.buffer,
                usage: .read,
                stages: .fragment
            )
        }
        // fragmentShader declares the benchmark counter buffer; bind a dummy so
        // the screenshot pipeline validates (screenshots never benchmark).
        if let benchBuf = benchCounterBuffers.first {
            renderEncoder.setFragmentBuffer(benchBuf, offset: 0, index: BufferIndex.benchCounters.rawValue)
        }

        let viewport = MTLViewport(originX: 0, originY: 0,
                                   width: Double(screenshotTexture.width),
                                   height: Double(screenshotTexture.height),
                                   znear: 0, zfar: 1)
        renderEncoder.setViewport(viewport)

        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout, layout.stride != 0 else { continue }
            let buffer = mesh.vertexBuffers[index]
            renderEncoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index)
        }

        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
        }

        renderEncoder.endEncoding()

        #if os(macOS)
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: screenshotTexture)
            blitEncoder.endEncoding()
        }
        #endif

        // Capture continuation and texture ref before the closure to avoid actor re-entry
        let continuation = pendingScreenshotContinuation
        pendingScreenshotContinuation = nil
        let capturedTexture = screenshotTexture

        commandBuffer.addCompletedHandler { [weak self, screenshotEnvironmentGrid] _ in
            withExtendedLifetime(screenshotEnvironmentGrid) {
                let imageData = self?.textureToImageData(capturedTexture)
                continuation?.resume(returning: imageData)
            }
        }
        commandBuffer.commit()
    }

    /// Convert a Metal texture to PNG image data
    private nonisolated func textureToImageData(_ texture: MTLTexture) -> Data? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        texture.getBytes(&pixelData,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                         size: MTLSize(width: width, height: height, depth: 1)),
                         mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let context = CGContext(data: &pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue),
              let cgImage = context.makeImage() else {
            return nil
        }

        #if os(visionOS) || os(iOS)
        let image = UIImage(cgImage: cgImage)
        return image.pngData()
        #elseif os(macOS)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapRep.representation(using: .png, properties: [:])
        #endif
    }
}
