#if os(macOS) || os(iOS)
import Metal

/// Pixel dimensions shared by the Mac/iOS MetalFX scalers.
struct MetalFXSize: Equatable {
    var width: Int
    var height: Int
}

/// Shared texture allocation for the Mac/iOS MetalFX scalers
/// (`MacSpatialUpscaler` / `MacTemporalUpscaler`). Keeping this in one place
/// means the platform storage-mode rules (e.g. `.memoryless` depth on iOS tile
/// GPUs) live in a single source of truth.
enum MetalFXTextureSupport {
    /// MetalFX rejects very small inputs; floor the shortest edge.
    static let minimumInputShortEdge = 128

    static func makeTexture(device: MTLDevice,
                            width: Int,
                            height: Int,
                            format: MTLPixelFormat,
                            usage: MTLTextureUsage,
                            depthFormat: MTLPixelFormat,
                            label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: max(width, 1),
                                                                  height: max(height, 1),
                                                                  mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        #if os(iOS)
        // A render-only depth target (never sampled) can stay in tile memory on
        // iOS, avoiding a system-memory allocation.
        if format == depthFormat, !usage.contains(.shaderRead) {
            descriptor.storageMode = .memoryless
        }
        #endif
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }
}
#endif
