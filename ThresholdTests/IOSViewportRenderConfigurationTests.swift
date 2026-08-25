#if os(macOS) || os(iOS)
@preconcurrency import Metal
import Testing

@testable import Threshold

@Suite("iOS viewport render configuration")
struct IOSViewportRenderConfigurationTests {
    @Test("iPhone uses the identical Metal surface configuration as iPad")
    func iPhoneAndIPadRenderParity() {
        #expect(
            IOSViewportRenderConfiguration.rendering(for: .iPhone)
                == IOSViewportRenderConfiguration.rendering(for: .iPad)
        )
    }

    @Test("Shared iOS surface preserves the HDR render contract")
    func sharedSurfaceContract() {
        let configuration = IOSViewportRenderConfiguration.rendering(for: .iPad)

        #expect(configuration.colorPixelFormat == .rgba16Float)
        #expect(configuration.depthStencilPixelFormat == .depth32Float)
        #expect(configuration.clearRed == 0.005)
        #expect(configuration.clearGreen == 0.006)
        #expect(configuration.clearBlue == 0.008)
        #expect(configuration.clearAlpha == 1.0)
        #expect(configuration.clearDepth == 1.0)
        #expect(configuration.framebufferOnly)
        #expect(configuration.automaticallyResizesDrawable)
    }
}
#endif
