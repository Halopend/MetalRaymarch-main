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
        input.setAttributionShortcutHeld(true)
        input.addOrbit(delta: SIMD2<Float>(3, -2))
        input.addPan(delta: SIMD2<Float>(1, 4))
        input.addZoom(delta: 0.5)
        input.requestPlaybackToggle()
        input.requestReset()
        input.requestSceneStep(-1)

        let first = input.consumeFrame()
        #expect(first.heldKeys == [.forward])
        #expect(first.isShiftPressed)
        #expect(first.isAttributionShortcutHeld)
        #expect(first.orbitDelta == SIMD2<Float>(3, -2))
        #expect(first.panDelta == SIMD2<Float>(1, 4))
        #expect(first.zoomDelta == 0.5)
        #expect(first.actions == [.togglePlayback, .resetView])
        #expect(first.sceneStep == -1)

        let second = input.consumeFrame()
        #expect(second.heldKeys == [.forward])
        #expect(second.isShiftPressed)
        #expect(second.isAttributionShortcutHeld)
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
        input.setAttributionShortcutHeld(true)
        input.addOrbit(delta: SIMD2<Float>(1, 1))
        input.requestReset()
        input.setFocus(false)

        let frame = input.consumeFrame()
        #expect(frame.heldKeys.isEmpty)
        #expect(!frame.isShiftPressed)
        #expect(!frame.isAttributionShortcutHeld)
        #expect(frame.orbitDelta == .zero)
        #expect(frame.actions.isEmpty)
    }

    @Test("Clearing camera deltas preserves discrete scene navigation")
    func clearCameraDeltasPreservesSceneNavigation() {
        let input = ViewportInputAccumulator()
        input.addOrbit(delta: SIMD2<Float>(4, -3))
        input.addPan(delta: SIMD2<Float>(2, 1))
        input.addZoom(delta: 0.5)
        input.requestSceneStep(1)

        input.clearCameraDeltas()

        let frame = input.consumeFrame()
        #expect(frame.orbitDelta == .zero)
        #expect(frame.panDelta == .zero)
        #expect(frame.zoomDelta == 0)
        #expect(frame.sceneStep == 1)
    }

    @Test("Scene swipes require an intentional horizontal translation")
    func sceneSwipePolicy() {
        #expect(SceneSwipeGesturePolicy.sceneStep(for: SIMD2<Float>(-32, 0)) == 1)
        #expect(SceneSwipeGesturePolicy.sceneStep(for: SIMD2<Float>(32, 0)) == -1)
        #expect(SceneSwipeGesturePolicy.sceneStep(for: SIMD2<Float>(31, 0)) == 0)
        #expect(SceneSwipeGesturePolicy.sceneStep(for: SIMD2<Float>(48, 48)) == 0)
        #expect(SceneSwipeGesturePolicy.sceneStep(for: SIMD2<Float>(-.infinity, 0)) == 0)
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

    @Test("Mac and iPad hardware-key mappings have semantic parity")
    func keyboardMappingParity() {
        let mac: [ViewportKeyboardKey?] = [
            ViewportKeyboardMap.macOS(keyCode: 0, characters: "w"),
            ViewportKeyboardMap.macOS(keyCode: 0, characters: "s"),
            ViewportKeyboardMap.macOS(keyCode: 0, characters: "a"),
            ViewportKeyboardMap.macOS(keyCode: 0, characters: "d"),
            ViewportKeyboardMap.macOS(keyCode: 123, characters: nil),
            ViewportKeyboardMap.macOS(keyCode: 124, characters: nil),
            ViewportKeyboardMap.macOS(keyCode: 0, characters: " "),
            ViewportKeyboardMap.macOS(keyCode: 0, characters: "r"),
        ]
        let iPad: [ViewportKeyboardKey?] = [26, 22, 4, 7, 80, 79, 44, 21]
            .map(ViewportKeyboardMap.iPadOS(hidUsage:))
        #expect(mac == iPad)
        #expect(ViewportKeyboardMap.iPadOS(hidUsage: 225) == .shift)
        #expect(ViewportKeyboardMap.iPadOS(hidUsage: 229) == .shift)
    }

    @Test("Held keys repeat safely while transient keys remain edge-triggered")
    func keyboardDispatchSemantics() {
        let input = ViewportInputAccumulator()
        input.applyKeyboard(.forward, isPressed: true, isRepeat: false)
        input.applyKeyboard(.forward, isPressed: true, isRepeat: true)
        input.applyKeyboard(.togglePlayback, isPressed: true, isRepeat: false)
        input.applyKeyboard(.togglePlayback, isPressed: true, isRepeat: true)
        input.applyKeyboard(.nextScene, isPressed: true, isRepeat: false)
        input.applyKeyboard(.nextScene, isPressed: true, isRepeat: true)

        let frame = input.consumeFrame()
        #expect(frame.heldKeys == [.forward])
        #expect(frame.actions == [.togglePlayback])
        #expect(frame.sceneStep == 1)
    }

    @Test("Mac attribution shortcut remains visible while I is held")
    func attributionShortcut() {
        let input = ViewportInputAccumulator()
        #expect(ViewportKeyboardMap.macOS(keyCode: 0, characters: "i") == .showAttribution)

        input.applyKeyboard(.showAttribution, isPressed: true, isRepeat: false)
        #expect(input.consumeFrame().isAttributionShortcutHeld)

        input.applyKeyboard(.showAttribution, isPressed: false, isRepeat: false)
        #expect(!input.consumeFrame().isAttributionShortcutHeld)
    }
}
#endif
