#if os(macOS) || os(iOS)
import Metal

/// Exact-size low-resolution target for frames without a ready MetalFX scaler.
/// The existing presentation pass enlarges its color texture to the drawable,
/// so unsupported sizes and scaler warmup never force a full-resolution march.
final class ViewportScaledRenderTarget {
    private(set) var color: MTLTexture?
    private(set) var depth: MTLTexture?

    func prepare(device: MTLDevice, width: Int, height: Int,
                 colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) -> Bool {
        guard width > 0, height > 0 else { return false }
        if let color, let depth,
           color.width == width, color.height == height,
           color.pixelFormat == colorFormat, depth.pixelFormat == depthFormat {
            return true
        }
        guard let newColor = MetalFXTextureSupport.makeTexture(
            device: device, width: width, height: height,
            format: colorFormat, usage: [.renderTarget, .shaderRead],
            depthFormat: depthFormat, label: "Viewport Basic Upscale Color"
        ), let newDepth = MetalFXTextureSupport.makeTexture(
            device: device, width: width, height: height,
            format: depthFormat, usage: [.renderTarget],
            depthFormat: depthFormat, label: "Viewport Basic Upscale Depth"
        ) else { return false }
        color = newColor
        depth = newDepth
        return true
    }
}
#endif
