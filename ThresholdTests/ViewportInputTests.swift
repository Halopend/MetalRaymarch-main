#if os(macOS) || os(iOS)
import Dispatch
import Testing
import simd

@testable import Threshold

@Suite("Universal viewport input")
struct ViewportInputTests {
    @Test("A drain retains held state and clears edge-triggered state")
    func drainSemantics() {
        let input = ViewportInputAccumulator()
        input.setMovementKey(.forward, isPressed: true)
        input.setShiftPressed(true)
        input.addOrbit(delta: SIMD2<Float>(3, -2))
        input.addPan(delta: SIMD2<Float>(1, 4))
        input.addZoom(delta: 0.5)
        input.requestPlaybackToggle()
        input.requestReset()
        input.requestSceneStep(-1)

        let first = input.consumeFrame()
        #expect(first.heldKeys == [.forward])
        #expect(first.isShiftPressed)
        #expect(first.orbitDelta == SIMD2<Float>(3, -2))
        #expect(first.panDelta == SIMD2<Float>(1, 4))
        #expect(first.zoomDelta == 0.5)
        #expect(first.actions == [.togglePlayback, .resetView])
        #expect(first.sceneStep == -1)

        let second = input.consumeFrame()
        #expect(second.heldKeys == [.forward])
        #expect(second.isShiftPressed)
        #expect(second.orbitDelta == .zero)
        #expect(second.panDelta == .zero)
        #expect(second.zoomDelta == 0)
        #expect(second.actions.isEmpty)
        #expect(second.sceneStep == 0)
    }

    @Test("Losing focus atomically clears all input")
    func focusReset() {
        let input = ViewportInputAccumulator()
        input.setMovementKey([.forward, .right], isPressed: true)
        input.setShiftPressed(true)
        input.addOrbit(delta: SIMD2<Float>(1, 1))
        input.requestReset()
        input.setFocus(false)

        let frame = input.consumeFrame()
        #expect(frame.heldKeys.isEmpty)
        #expect(!frame.isShiftPressed)
        #expect(frame.orbitDelta == .zero)
        #expect(frame.actions.isEmpty)
    }

    @Test("Concurrent producers are lossless across one drain")
    func concurrentProducers() {
        let input = ViewportInputAccumulator()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ViewportInputTests", attributes: .concurrent)
        let eventCount = 1_000

        for _ in 0..<eventCount {
            group.enter()
            queue.async {
                input.addZoom(delta: 1)
                input.requestSceneStep(1)
                group.leave()
            }
        }
        group.wait()

        let frame = input.consumeFrame()
        #expect(frame.zoomDelta == Float(eventCount))
        #expect(frame.sceneStep == eventCount)
    }
}
#endif
