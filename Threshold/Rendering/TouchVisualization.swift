//
//  TouchVisualization.swift
//  Threshold
//
//  On-screen feedback for finger touches on the iOS render view. Each active
//  finger gets a glowing dot + ring that tracks it; lifting a finger emits an
//  expanding ripple that fades out. The tint encodes the gesture the renderer
//  is interpreting: one finger (orbit) vs. two fingers (pan/zoom).
//
//  Pure CALayer overlay — no Metal pipeline or uniform changes, so it cannot
//  perturb the raymarch/upscale paths. The overlay never intercepts touches.
//

#if os(iOS)
import UIKit
import MetalKit
import QuartzCore

/// User preference for the touch indicators. Backed by UserDefaults so the
/// Settings tab (`@AppStorage`) and the UIKit overlay share one source of
/// truth. Defaults to on.
enum TouchVisualizationSettings {
    static let defaultsKey = "showTouchIndicators"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Transparent, non-interactive view that renders touch indicators.
/// Feed it raw `UITouch` sets from the hosting view's `touches*` overrides.
final class TouchVisualizationOverlay: UIView {

    private enum Style {
        static let dotRadius: CGFloat = 14
        static let ringRadius: CGFloat = 30
        static let ringLineWidth: CGFloat = 2
        static let rippleEndRadius: CGFloat = 64
        static let rippleDuration: CFTimeInterval = 0.45
        static let appearDuration: CFTimeInterval = 0.18
        /// One finger: orbit. Two fingers: pan/zoom.
        static let orbitColor = UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1.0)
        static let panZoomColor = UIColor(red: 0.85, green: 0.55, blue: 1.0, alpha: 1.0)
    }

    private final class Indicator {
        let container = CALayer()
        let dot = CAShapeLayer()
        let ring = CAShapeLayer()

        init(at point: CGPoint, color: UIColor) {
            container.position = point
            container.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)

            dot.path = UIBezierPath(arcCenter: .zero, radius: Style.dotRadius,
                                    startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            dot.lineWidth = 0
            dot.shadowOffset = .zero
            dot.shadowRadius = 10
            dot.shadowOpacity = 0.9

            ring.path = UIBezierPath(arcCenter: .zero, radius: Style.ringRadius,
                                     startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            ring.fillColor = nil
            ring.lineWidth = Style.ringLineWidth

            container.addSublayer(ring)
            container.addSublayer(dot)
            apply(color: color)

            // Pop-in: scale up + fade in.
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.4
            scale.toValue = 1.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = Style.appearDuration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.add(group, forKey: "appear")
        }

        func apply(color: UIColor) {
            dot.fillColor = color.withAlphaComponent(0.55).cgColor
            dot.shadowColor = color.cgColor
            ring.strokeColor = color.withAlphaComponent(0.8).cgColor
        }
    }

    private var indicators: [ObjectIdentifier: Indicator] = [:]
    /// `UserDefaults` notifications are delivered on the thread that performs
    /// the write. SettingsPersistence commits debounced values from a utility
    /// task, so retain a main-queue observer instead of a selector observer
    /// (which would otherwise enter this UIKit view off the main actor).
    private var defaultsChangeObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false

        let notifications = NotificationCenter.default
        notifications.addObserver(
            self,
            selector: #selector(clearForLifecycleChange),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        notifications.addObserver(
            self,
            selector: #selector(clearForLifecycleChange),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        defaultsChangeObserver = notifications.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` is the dispatch guarantee; state it explicitly
            // for Swift's actor checker as the callback type itself has no
            // actor annotation.
            MainActor.assumeIsolated {
                self?.touchVisualizationPreferenceDidChange()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let defaultsChangeObserver {
            NotificationCenter.default.removeObserver(defaultsChangeObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            clearAll()
        }
    }

    // MARK: - Touch feed

    func touchesBegan(_ touches: Set<UITouch>, event: UIEvent?) {
        guard TouchVisualizationSettings.isEnabled else {
            clearAll()
            return
        }

        let newTouches = touches.filter { indicators[ObjectIdentifier($0)] == nil }
        let color = color(forTouchCount: indicators.count + newTouches.count)
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            indicators[identifier]?.container.removeFromSuperlayer()
            let indicator = Indicator(at: touch.location(in: self), color: color)
            indicators[identifier] = indicator
            layer.addSublayer(indicator.container)
        }
        retintAll()
        reconcileActiveTouches(with: event)
    }

    func touchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard TouchVisualizationSettings.isEnabled else {
            clearAll()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for touch in touches {
            indicators[ObjectIdentifier(touch)]?.container.position = touch.location(in: self)
        }
        CATransaction.commit()
        reconcileActiveTouches(with: event)
    }

    func touchesEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        guard TouchVisualizationSettings.isEnabled else {
            clearAll()
            return
        }

        for touch in touches {
            guard let indicator = indicators.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            release(indicator, at: touch.location(in: self))
        }
        retintAll()
        reconcileActiveTouches(with: event)
    }

    /// Cancellation is an interruption of the whole view-level stream. UIKit
    /// can report only the recognizer-owned subset, so clearing just `touches`
    /// here risks leaving a sibling finger's layer behind indefinitely.
    func touchesCancelled() {
        clearAll()
    }

    /// Used by view/window/app lifecycle boundaries that may not deliver a
    /// matching `touchesEnded` callback.
    func clearAll() {
        indicators.removeAll(keepingCapacity: true)
        layer.sublayers?.forEach {
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
    }

    // MARK: - Internals

    /// Tint reflects how the renderer interprets the touch set:
    /// one finger orbits, two (or more) pan/zoom.
    private func color(forTouchCount count: Int) -> UIColor {
        count >= 2 ? Style.panZoomColor : Style.orbitColor
    }

    private func retintAll() {
        let color = color(forTouchCount: indicators.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for indicator in indicators.values {
            indicator.apply(color: color)
        }
        CATransaction.commit()
    }

    /// Detach the indicator and play an expanding ripple fade-out, then remove.
    private func release(_ indicator: Indicator, at point: CGPoint) {
        let container = indicator.container
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = point
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { container.removeFromSuperlayer() }

        let endScale = Style.rippleEndRadius / Style.ringRadius
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = endScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Style.rippleDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        container.add(group, forKey: "release")

        CATransaction.commit()

        // Core Animation completion blocks do not run while an app/view layer
        // tree is paused. This independent cleanup is intentionally redundant:
        // a released ripple must never become a permanent violet/cyan dot.
        DispatchQueue.main.asyncAfter(deadline: .now() + Style.rippleDuration + 0.1) {
            container.removeAllAnimations()
            container.removeFromSuperlayer()
        }
    }

    private func reconcileActiveTouches(with event: UIEvent?) {
        guard let eventTouches = event?.allTouches else { return }
        let liveIdentifiers = Set(eventTouches.compactMap { touch -> ObjectIdentifier? in
            switch touch.phase {
            case .began, .moved, .stationary:
                return ObjectIdentifier(touch)
            case .ended, .cancelled, .regionEntered, .regionMoved, .regionExited:
                return nil
            @unknown default:
                return nil
            }
        })

        let staleIdentifiers = indicators.keys.filter { !liveIdentifiers.contains($0) }
        guard !staleIdentifiers.isEmpty else { return }
        for identifier in staleIdentifiers {
            indicators.removeValue(forKey: identifier)?.container.removeFromSuperlayer()
        }
        retintAll()
    }

    @objc private func clearForLifecycleChange() {
        clearAll()
    }

    private func touchVisualizationPreferenceDidChange() {
        if !TouchVisualizationSettings.isEnabled {
            clearAll()
        }
    }
}

/// MTKView that mirrors its raw touches into a `TouchVisualizationOverlay`
/// while leaving gesture recognition untouched.
final class TouchVisualizingMTKView: MTKView {
    private let touchOverlay = TouchVisualizationOverlay(frame: .zero)
    private var heldKeyboardUsages: Set<Int> = []
    weak var inputSink: (any ViewportInputSink)?
    var shouldAcceptViewportInput: () -> Bool = { true }
    var onRadialMenuRequest: ((CGPoint) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        addSubview(touchOverlay)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        touchOverlay.frame = bounds
        bringSubviewToFront(touchOverlay)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        touchOverlay.touchesBegan(touches, event: event)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOverlay.touchesMoved(touches, event: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOverlay.touchesEnded(touches, event: event)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOverlay.touchesCancelled()
        super.touchesCancelled(touches, with: event)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            touchOverlay.clearAll()
        }
        super.willMove(toWindow: newWindow)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = Set(presses.filter { !handle($0, isPressed: true) })
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = Set(presses.filter { !handle($0, isPressed: false) })
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldKeyboardUsages.removeAll(keepingCapacity: true)
        inputSink?.setFocus(false)
        super.pressesCancelled(presses, with: event)
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        touchOverlay.clearAll()
        heldKeyboardUsages.removeAll(keepingCapacity: true)
        inputSink?.setFocus(false)
        return super.resignFirstResponder()
    }

    func clearTouchVisualizations() {
        touchOverlay.clearAll()
    }

    private func handle(_ press: UIPress, isPressed: Bool) -> Bool {
        guard let key = press.key else { return false }
        let usage = Int(key.keyCode.rawValue)
        let wasHeld = heldKeyboardUsages.contains(usage)
        if !isPressed {
            heldKeyboardUsages.remove(usage)
        }

        if isPressed,
           !wasHeld,
           key.modifierFlags.contains(.command),
           key.charactersIgnoringModifiers == "." {
            heldKeyboardUsages.insert(usage)
            onRadialMenuRequest?(CGPoint(x: bounds.midX, y: bounds.midY))
            return true
        }

        guard let semanticKey = ViewportKeyboardMap.iPadOS(
            hidUsage: usage
        ) else { return false }
        let ownsViewportInput = shouldAcceptViewportInput()
        // A menu may claim input while a hardware key is still held. Always
        // deliver that key's release to the viewport accumulator so movement
        // cannot stick, while returning `false` lets the new owner also observe
        // the event. New key-downs remain exclusive to the current owner.
        guard ownsViewportInput || (!isPressed && wasHeld) else { return false }
        if isPressed {
            heldKeyboardUsages.insert(usage)
        }
        let handled = inputSink?.applyKeyboard(
            semanticKey,
            isPressed: isPressed,
            isRepeat: isPressed && wasHeld
        ) ?? true
        return ownsViewportInput ? handled : false
    }
}
#endif
