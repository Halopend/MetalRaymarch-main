#if os(macOS) || os(iOS)
import Metal
import Testing
@testable import Threshold

@Suite("Basic low-resolution viewport")
struct ViewportScaledRenderTargetTests {
    @Test("A 10 percent phone target stays below MetalFX's minimum without rendering native")
    func smallPhoneTarget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let target = ViewportScaledRenderTarget()
        // A 1170 × 2532 drawable at 10% has a short edge below 128.
        #expect(target.prepare(device: device, width: 117, height: 253,
                               colorFormat: .rgba16Float, depthFormat: .depth32Float))
        let color = try #require(target.color)
        let depth = try #require(target.depth)
        #expect(color.width == 117 && color.height == 253)
        #expect(depth.width == color.width && depth.height == color.height)
        #expect(color.usage.contains([.renderTarget, .shaderRead]))

        // Repeated frames reuse the allocation; rotation reallocates both attachments.
        #expect(target.prepare(device: device, width: 117, height: 253,
                               colorFormat: .rgba16Float, depthFormat: .depth32Float))
        #expect(target.color === color)
        #expect(target.prepare(device: device, width: 253, height: 117,
                               colorFormat: .rgba16Float, depthFormat: .depth32Float))
        #expect(target.color?.width == 253 && target.depth?.height == 117)
    }
}
#endif
