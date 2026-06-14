#if os(macOS) || os(iOS)
import simd
import Synchronization
#if os(macOS)
import AppKit
import MetalKit
#endif

/// Movement keys for the desktop/iPad fly-through camera (WASD + shift to rise/fall).
enum ThresholdMacMovementKey: Hashable, Sendable {
    case forward
    case backward
    case left
    case right
}

/// One frame's worth of accumulated viewport input, drained by the renderer.
struct ThresholdMacInputFrame: Sendable {
    var pressedKeys: Set<ThresholdMacMovementKey> = []
    var isShiftPressed: Bool = false
    var orbitDelta: SIMD2<Float> = .zero
    var panDelta: SIMD2<Float> = .zero
    var zoomDelta: Float = 0
    var shouldTogglePlayback = false
    var shouldResetView = false
    // Net scene-switch steps requested this frame (left/right arrow keys).
    // Positive = advance, negative = go back.
    var sceneStep = 0
}

#if os(macOS)
protocol ThresholdMacViewportInputDelegate: AnyObject {
    func viewportDidChangeFocus(_ isFocused: Bool)
    func viewportDidOrbit(delta: SIMD2<Float>)
    func viewportDidPan(delta: SIMD2<Float>)
    func viewportDidZoom(delta: Float)
    func viewportDidChangeKey(_ key: ThresholdMacMovementKey, isPressed: Bool)
    func viewportDidChangeShift(_ isPressed: Bool)
    func viewportDidTogglePlayback()
    func viewportDidRequestReset()
    func viewportDidRequestSceneStep(_ step: Int)
}
#endif

/// Thread-safe accumulator that collects viewport input events (from AppKit/UIKit
/// on the main thread) and hands the renderer a snapshot once per frame. State is
/// guarded by a `Mutex` so the render thread's `consumeFrame()` is race-free.
final class ThresholdMacInputController: Sendable {
    private struct State {
        var pressedKeys: Set<ThresholdMacMovementKey> = []
        var isShiftPressed: Bool = false
        var orbitDelta: SIMD2<Float> = .zero
        var panDelta: SIMD2<Float> = .zero
        var zoomDelta: Float = 0
        var shouldTogglePlayback = false
        var shouldResetView = false
        var sceneStep = 0
    }

    private let state = Mutex(State())

    func setFocus(_ isFocused: Bool) {
        guard !isFocused else { return }
        state.withLock { current in
            current.pressedKeys.removeAll()
            current.isShiftPressed = false
            current.orbitDelta = .zero
            current.panDelta = .zero
            current.zoomDelta = 0
            current.shouldTogglePlayback = false
            current.shouldResetView = false
            current.sceneStep = 0
        }
    }

    func setMovementKey(_ key: ThresholdMacMovementKey, isPressed: Bool) {
        state.withLock { current in
            if isPressed {
                current.pressedKeys.insert(key)
            } else {
                current.pressedKeys.remove(key)
            }
        }
    }

    func setShiftPressed(_ isPressed: Bool) {
        state.withLock { current in
            current.isShiftPressed = isPressed
        }
    }

    func addOrbit(delta: SIMD2<Float>) {
        state.withLock { current in
            current.orbitDelta += delta
        }
    }

    func addPan(delta: SIMD2<Float>) {
        state.withLock { current in
            current.panDelta += delta
        }
    }

    func addZoom(delta: Float) {
        state.withLock { current in
            current.zoomDelta += delta
        }
    }

    func requestPlaybackToggle() {
        state.withLock { current in
            current.shouldTogglePlayback = true
        }
    }

    func requestReset() {
        state.withLock { current in
            current.shouldResetView = true
        }
    }

    func requestSceneStep(_ step: Int) {
        state.withLock { current in
            current.sceneStep += step
        }
    }

    func consumeFrame() -> ThresholdMacInputFrame {
        state.withLock { current in
            let frame = ThresholdMacInputFrame(
                pressedKeys: current.pressedKeys,
                isShiftPressed: current.isShiftPressed,
                orbitDelta: current.orbitDelta,
                panDelta: current.panDelta,
                zoomDelta: current.zoomDelta,
                shouldTogglePlayback: current.shouldTogglePlayback,
                shouldResetView: current.shouldResetView,
                sceneStep: current.sceneStep
            )
            current.orbitDelta = .zero
            current.panDelta = .zero
            current.zoomDelta = 0
            current.shouldTogglePlayback = false
            current.shouldResetView = false
            current.sceneStep = 0
            return frame
        }
    }
}

#if os(macOS)
/// `MTKView` subclass that translates AppKit mouse/scroll/keyboard events into
/// viewport input callbacks. Orbit (drag), pan (option/right/middle drag), zoom
/// (scroll + magnify), WASD movement, and scene/playback shortcuts.
final class ThresholdMacInteractiveView: MTKView {
    private enum DragMode {
        case orbit
        case pan
    }

    weak var inputDelegate: (any ThresholdMacViewportInputDelegate)?
    private var dragMode: DragMode?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        dragMode = nil
        inputDelegate?.viewportDidChangeFocus(false)
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        beginInteraction(mode: event.modifierFlags.contains(.option) ? .pan : .orbit)
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .orbit)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        beginInteraction(mode: .pan)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .pan)
    }

    override func rightMouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        beginInteraction(mode: .pan)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .pan)
    }

    override func otherMouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func scrollWheel(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        inputDelegate?.viewportDidChangeFocus(true)
        let multiplier: Float = event.hasPreciseScrollingDeltas ? 1.0 : 6.0
        inputDelegate?.viewportDidZoom(delta: Float(event.scrollingDeltaY) * multiplier)
    }

    override func magnify(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        inputDelegate?.viewportDidChangeFocus(true)
        inputDelegate?.viewportDidZoom(delta: -Float(event.magnification) * 18.0)
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event, isPressed: true) {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if handleKey(event, isPressed: false) {
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputDelegate?.viewportDidChangeShift(event.modifierFlags.contains(.shift))
        super.flagsChanged(with: event)
    }

    private func beginInteraction(mode: DragMode) {
        _ = window?.makeFirstResponder(self)
        inputDelegate?.viewportDidChangeFocus(true)
        dragMode = mode
    }

    private func handleDrag(_ event: NSEvent, fallbackMode: DragMode) {
        let delta = SIMD2<Float>(Float(event.deltaX), Float(event.deltaY))
        guard simd_length_squared(delta) > 0 else { return }

        let activeMode: DragMode
        if event.modifierFlags.contains(.option) {
            activeMode = .pan
        } else {
            activeMode = dragMode ?? fallbackMode
        }

        switch activeMode {
        case .orbit:
            inputDelegate?.viewportDidOrbit(delta: delta)
        case .pan:
            inputDelegate?.viewportDidPan(delta: delta)
        }
    }

    private func handleKey(_ event: NSEvent, isPressed: Bool) -> Bool {
        // Left/right arrows switch jumping-off scenes. Handled via virtual key
        // codes (123 = left, 124 = right) since arrow keys carry function-key
        // unicode rather than plain characters. Fire once per press (not on
        // auto-repeat) and consume both down and up to suppress the system beep.
        switch event.keyCode {
        case 123:
            if isPressed && !event.isARepeat {
                inputDelegate?.viewportDidRequestSceneStep(-1)
            }
            return true
        case 124:
            if isPressed && !event.isARepeat {
                inputDelegate?.viewportDidRequestSceneStep(1)
            }
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
            return false
        }

        var handled = false
        for character in characters {
            switch character {
            case "w":
                inputDelegate?.viewportDidChangeKey(.forward, isPressed: isPressed)
                handled = true
            case "s":
                inputDelegate?.viewportDidChangeKey(.backward, isPressed: isPressed)
                handled = true
            case "a":
                inputDelegate?.viewportDidChangeKey(.left, isPressed: isPressed)
                handled = true
            case "d":
                inputDelegate?.viewportDidChangeKey(.right, isPressed: isPressed)
                handled = true
            case " ":
                if isPressed && !event.isARepeat {
                    inputDelegate?.viewportDidTogglePlayback()
                }
                handled = true
            case "r":
                if isPressed && !event.isARepeat {
                    inputDelegate?.viewportDidRequestReset()
                }
                handled = true
            default:
                break
            }
        }

        return handled
    }
}
#endif
#endif
