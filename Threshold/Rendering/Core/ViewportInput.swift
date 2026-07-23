#if os(macOS) || os(iOS)
import simd
import Synchronization
#if os(macOS)
import AppKit
import MetalKit
#endif

/// Compact held-key state shared by macOS and iPadOS viewport adapters.
struct ViewportMovementKeys: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let forward  = Self(rawValue: 1 << 0)
    static let backward = Self(rawValue: 1 << 1)
    static let left     = Self(rawValue: 1 << 2)
    static let right    = Self(rawValue: 1 << 3)
}

/// Compact edge-triggered actions. They are cleared after every renderer drain.
struct ViewportInputActions: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let togglePlayback = Self(rawValue: 1 << 0)
    static let resetView      = Self(rawValue: 1 << 1)
}

/// One frame's accumulated viewport input. Draining copies only value types and
/// performs no heap allocation; held state survives while deltas/actions clear.
struct ViewportInputFrame: Sendable {
    var heldKeys: ViewportMovementKeys = []
    var isShiftPressed: Bool = false
    var orbitDelta: SIMD2<Float> = .zero
    var panDelta: SIMD2<Float> = .zero
    var zoomDelta: Float = 0
    var actions: ViewportInputActions = []
    // Net scene-switch steps requested this frame (left/right arrow keys).
    // Positive = advance, negative = go back.
    var sceneStep = 0

    var shouldTogglePlayback: Bool { actions.contains(.togglePlayback) }
    var shouldResetView: Bool { actions.contains(.resetView) }
}

/// The single native-adapter boundary for mouse, trackpad, touch, and hardware
/// keyboard events. Platform views translate events; this sink owns semantics.
protocol ViewportInputSink: AnyObject {
    func setFocus(_ isFocused: Bool)
    func addOrbit(delta: SIMD2<Float>)
    func addPan(delta: SIMD2<Float>)
    func addZoom(delta: Float)
    func setMovementKey(_ key: ViewportMovementKeys, isPressed: Bool)
    func setShiftPressed(_ isPressed: Bool)
    func requestPlaybackToggle()
    func requestReset()
    func requestSceneStep(_ step: Int)
}

/// Thread-safe accumulator that collects viewport input events (from AppKit/UIKit
/// on the main thread) and hands the renderer a snapshot once per frame. State is
/// guarded by a `Mutex` so the render thread's `consumeFrame()` is race-free.
final class ViewportInputAccumulator: ViewportInputSink, Sendable {
    private struct State {
        var heldKeys: ViewportMovementKeys = []
        var isShiftPressed: Bool = false
        var orbitDelta: SIMD2<Float> = .zero
        var panDelta: SIMD2<Float> = .zero
        var zoomDelta: Float = 0
        var actions: ViewportInputActions = []
        var sceneStep = 0
    }

    private let state = Mutex(State())

    func setFocus(_ isFocused: Bool) {
        guard !isFocused else { return }
        state.withLock { current in
            current.heldKeys = []
            current.isShiftPressed = false
            current.orbitDelta = .zero
            current.panDelta = .zero
            current.zoomDelta = 0
            current.actions = []
            current.sceneStep = 0
        }
    }

    func setMovementKey(_ key: ViewportMovementKeys, isPressed: Bool) {
        state.withLock { current in
            if isPressed {
                current.heldKeys.insert(key)
            } else {
                current.heldKeys.remove(key)
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
        _ = state.withLock { current in
            current.actions.insert(.togglePlayback)
        }
    }

    func requestReset() {
        _ = state.withLock { current in
            current.actions.insert(.resetView)
        }
    }

    func requestSceneStep(_ step: Int) {
        state.withLock { current in
            current.sceneStep += step
        }
    }

    func consumeFrame() -> ViewportInputFrame {
        state.withLock { current in
            let frame = ViewportInputFrame(
                heldKeys: current.heldKeys,
                isShiftPressed: current.isShiftPressed,
                orbitDelta: current.orbitDelta,
                panDelta: current.panDelta,
                zoomDelta: current.zoomDelta,
                actions: current.actions,
                sceneStep: current.sceneStep
            )
            current.orbitDelta = .zero
            current.panDelta = .zero
            current.zoomDelta = 0
            current.actions = []
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
    static let didClickViewportNotification = Notification.Name("ThresholdMacInteractiveView.didClickViewport")
    static let clickLocationUserInfoKey = "locationInWindow"

    private enum DragMode {
        case orbit
        case pan
    }

    weak var inputSink: (any ViewportInputSink)?
    var shouldAcceptViewportInput: () -> Bool = { true }
    private var dragMode: DragMode?
    private var primaryMouseDownLocation: CGPoint?
    private var primaryDragDistance: CGFloat = 0
    private let clickMovementTolerance: CGFloat = 4

    // When the window is dragged fully off-screen (or hidden/minimized) on a
    // single-display setup, AppKit clears `.visible` from the window's
    // occlusion state. We pause the display link in that case so animation and
    // GPU work stop entirely. The single-screen gate avoids pausing when the
    // window may still be visible on another display.

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshOcclusionObserver()
        updatePauseForVisibility()
    }

    private func refreshOcclusionObserver() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        center.addObserver(
            self,
            selector: #selector(visibilityDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )

        // Plugging in / removing a display flips the single-screen gate, so
        // re-evaluate whenever the screen configuration changes.
        center.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(
            self,
            selector: #selector(visibilityDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func visibilityDidChange() {
        updatePauseForVisibility()
    }

    private func updatePauseForVisibility() {
        guard let window else {
            // Not in a window hierarchy; the system isn't driving the display
            // link, so leave the flag untouched.
            return
        }
        let isSingleScreen = NSScreen.screens.count <= 1
        let isVisible = window.occlusionState.contains(.visible)
        let shouldPause = isSingleScreen && !isVisible
        if isPaused != shouldPause {
            isPaused = shouldPause
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        dragMode = nil
        inputSink?.setFocus(false)
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        guard shouldAcceptViewportInput() else { return }
        primaryMouseDownLocation = event.locationInWindow
        primaryDragDistance = 0
        beginInteraction(mode: event.modifierFlags.contains(.option) ? .pan : .orbit)
    }

    override func mouseDragged(with event: NSEvent) {
        primaryDragDistance += hypot(event.deltaX, event.deltaY)
        handleDrag(event, fallbackMode: .orbit)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        defer {
            primaryMouseDownLocation = nil
            primaryDragDistance = 0
        }
        guard event.clickCount >= 2,
              primaryMouseDownLocation != nil,
              primaryDragDistance <= clickMovementTolerance else { return }
        NotificationCenter.default.post(
            name: Self.didClickViewportNotification,
            object: window,
            userInfo: [Self.clickLocationUserInfoKey: NSValue(point: event.locationInWindow)]
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        guard shouldAcceptViewportInput() else { return }
        beginInteraction(mode: .pan)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .pan)
    }

    override func rightMouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        guard shouldAcceptViewportInput() else { return }
        beginInteraction(mode: .pan)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .pan)
    }

    override func otherMouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard shouldAcceptViewportInput() else { return }
        _ = window?.makeFirstResponder(self)
        inputSink?.setFocus(true)
        let multiplier: Float = event.hasPreciseScrollingDeltas ? 1.0 : 6.0
        inputSink?.addZoom(delta: Float(event.scrollingDeltaY) * multiplier)
    }

    override func magnify(with event: NSEvent) {
        guard shouldAcceptViewportInput() else { return }
        _ = window?.makeFirstResponder(self)
        inputSink?.setFocus(true)
        inputSink?.addZoom(delta: -Float(event.magnification) * 18.0)
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
        if shouldAcceptViewportInput() {
            inputSink?.setShiftPressed(event.modifierFlags.contains(.shift))
        }
        super.flagsChanged(with: event)
    }

    private func beginInteraction(mode: DragMode) {
        _ = window?.makeFirstResponder(self)
        inputSink?.setFocus(true)
        dragMode = mode
    }

    private func handleDrag(_ event: NSEvent, fallbackMode: DragMode) {
        guard shouldAcceptViewportInput() else { return }
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
            inputSink?.addOrbit(delta: delta)
        case .pan:
            inputSink?.addPan(delta: delta)
        }
    }

    private func handleKey(_ event: NSEvent, isPressed: Bool) -> Bool {
        guard shouldAcceptViewportInput() else { return false }
        // Left/right arrows switch jumping-off scenes. Handled via virtual key
        // codes (123 = left, 124 = right) since arrow keys carry function-key
        // unicode rather than plain characters. Fire once per press (not on
        // auto-repeat) and consume both down and up to suppress the system beep.
        switch event.keyCode {
        case 123:
            if isPressed && !event.isARepeat {
                inputSink?.requestSceneStep(-1)
            }
            return true
        case 124:
            if isPressed && !event.isARepeat {
                inputSink?.requestSceneStep(1)
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
                inputSink?.setMovementKey(.forward, isPressed: isPressed)
                handled = true
            case "s":
                inputSink?.setMovementKey(.backward, isPressed: isPressed)
                handled = true
            case "a":
                inputSink?.setMovementKey(.left, isPressed: isPressed)
                handled = true
            case "d":
                inputSink?.setMovementKey(.right, isPressed: isPressed)
                handled = true
            case " ":
                if isPressed && !event.isARepeat {
                    inputSink?.requestPlaybackToggle()
                }
                handled = true
            case "r":
                if isPressed && !event.isARepeat {
                    inputSink?.requestReset()
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
