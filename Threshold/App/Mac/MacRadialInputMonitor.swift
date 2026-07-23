#if os(macOS)
import AppKit
import SwiftUI

/// macOS event adapter for the shared radial menu. Pointer movement, Shift,
/// trackpad scrolling, and window-local double clicks are AppKit concerns; the
/// radial hierarchy and renderer remain platform-neutral.
struct MacRadialInputMonitor: NSViewRepresentable {
    @Binding var isPressed: Bool
    let isRadialVisible: Bool
    let onMouseMoved: (CGPoint) -> Void
    let onTwoFingerSwipeUp: () -> Void
    let isPointerOverSlider: (CGPoint) -> Bool
    let isPointerOverWindowDragHandle: (CGPoint) -> Bool
    let onSliderScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPressed: $isPressed,
            isRadialVisible: isRadialVisible,
            onMouseMoved: onMouseMoved,
            onTwoFingerSwipeUp: onTwoFingerSwipeUp,
            isPointerOverSlider: isPointerOverSlider,
            isPointerOverWindowDragHandle: isPointerOverWindowDragHandle,
            onSliderScroll: onSliderScroll
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isPressed = $isPressed
        context.coordinator.isRadialVisible = isRadialVisible
        context.coordinator.onMouseMoved = onMouseMoved
        context.coordinator.onTwoFingerSwipeUp = onTwoFingerSwipeUp
        context.coordinator.isPointerOverSlider = isPointerOverSlider
        context.coordinator.isPointerOverWindowDragHandle = isPointerOverWindowDragHandle
        context.coordinator.onSliderScroll = onSliderScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var isPressed: Binding<Bool>
        var isRadialVisible: Bool
        var onMouseMoved: (CGPoint) -> Void
        var onTwoFingerSwipeUp: () -> Void
        var isPointerOverSlider: (CGPoint) -> Bool
        var isPointerOverWindowDragHandle: (CGPoint) -> Bool
        var onSliderScroll: (CGFloat) -> Void
        weak var hostView: NSView?
        private var monitor: Any?
        private var swipeUpDistance: CGFloat = 0
        private var didTriggerSwipe = false
        private let swipeDismissThreshold: CGFloat = 24

        init(
            isPressed: Binding<Bool>,
            isRadialVisible: Bool,
            onMouseMoved: @escaping (CGPoint) -> Void,
            onTwoFingerSwipeUp: @escaping () -> Void,
            isPointerOverSlider: @escaping (CGPoint) -> Bool,
            isPointerOverWindowDragHandle: @escaping (CGPoint) -> Bool,
            onSliderScroll: @escaping (CGFloat) -> Void
        ) {
            self.isPressed = isPressed
            self.isRadialVisible = isRadialVisible
            self.onMouseMoved = onMouseMoved
            self.onTwoFingerSwipeUp = onTwoFingerSwipeUp
            self.isPointerOverSlider = isPointerOverSlider
            self.isPointerOverWindowDragHandle = isPointerOverWindowDragHandle
            self.onSliderScroll = onSliderScroll
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]
            ) { [weak self] event in
                guard let self else { return event }
                guard let hostWindow = hostView?.window, event.window === hostWindow else { return event }

                if event.type == .flagsChanged {
                    isPressed.wrappedValue = event.modifierFlags.contains(.shift)
                } else if event.type == .leftMouseDown {
                    onMouseMoved(event.locationInWindow)
                } else if event.type == .scrollWheel {
                    guard isRadialVisible else {
                        resetSwipeTracking()
                        return event
                    }

                    let upwardDelta = event.isDirectionInvertedFromDevice
                        ? -event.scrollingDeltaY
                        : event.scrollingDeltaY

                    if isPointerOverSlider(event.locationInWindow) {
                        resetSwipeTracking()
                        if upwardDelta != 0 { onSliderScroll(upwardDelta) }
                        return nil
                    }

                    guard event.hasPreciseScrollingDeltas else { return event }
                    if event.phase == .began { resetSwipeTracking() }

                    if upwardDelta > 0 {
                        swipeUpDistance += upwardDelta
                    } else if upwardDelta < 0 {
                        swipeUpDistance = max(0, swipeUpDistance + upwardDelta)
                    }

                    if !didTriggerSwipe, swipeUpDistance >= swipeDismissThreshold {
                        didTriggerSwipe = true
                        onTwoFingerSwipeUp()
                    }

                    if event.phase == .ended || event.phase == .cancelled {
                        resetSwipeTracking()
                    }
                    return nil
                } else {
                    onMouseMoved(event.locationInWindow)
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            resetSwipeTracking()
            isPressed.wrappedValue = false
        }

        private func resetSwipeTracking() {
            swipeUpDistance = 0
            didTriggerSwipe = false
        }
    }
}
#endif
