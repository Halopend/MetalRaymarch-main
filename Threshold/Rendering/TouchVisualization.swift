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

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Touch feed

    func touchesBegan(_ touches: Set<UITouch>) {
        guard TouchVisualizationSettings.isEnabled else { return }
        for touch in touches {
            let indicator = Indicator(at: touch.location(in: self), color: currentColor(extraTouches: touches.count))
            indicators[ObjectIdentifier(touch)] = indicator
            layer.addSublayer(indicator.container)
        }
        retintAll()
    }

    func touchesMoved(_ touches: Set<UITouch>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for touch in touches {
            indicators[ObjectIdentifier(touch)]?.container.position = touch.location(in: self)
        }
        CATransaction.commit()
    }

    func touchesEnded(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let indicator = indicators.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            release(indicator, at: touch.location(in: self))
        }
        retintAll()
    }

    // MARK: - Internals

    /// Tint reflects how the renderer interprets the touch set:
    /// one finger orbits, two (or more) pan/zoom.
    private func currentColor(extraTouches: Int = 0) -> UIColor {
        (indicators.count + extraTouches) >= 2 ? Style.panZoomColor : Style.orbitColor
    }

    private func retintAll() {
        let color = currentColor()
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
    }
}

/// MTKView that mirrors its raw touches into a `TouchVisualizationOverlay`
/// while leaving gesture recognition untouched.
final class TouchVisualizingMTKView: MTKView {
    private let touchOverlay = TouchVisualizationOverlay(frame: .zero)
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
        touchOverlay.touchesBegan(touches)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOverlay.touchesMoved(touches)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOverlay.touchesEnded(touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOverlay.touchesEnded(touches)
        super.touchesCancelled(touches, with: event)
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
        inputSink?.setFocus(false)
        super.pressesCancelled(presses, with: event)
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        inputSink?.setFocus(false)
        return super.resignFirstResponder()
    }

    private func handle(_ press: UIPress, isPressed: Bool) -> Bool {
        guard let key = press.key else { return false }

        if isPressed,
           key.modifierFlags.contains(.command),
           key.charactersIgnoringModifiers == "." {
            onRadialMenuRequest?(CGPoint(x: bounds.midX, y: bounds.midY))
            return true
        }

        guard shouldAcceptViewportInput() else { return false }
        switch key.keyCode {
        case .keyboardW:
            inputSink?.setMovementKey(.forward, isPressed: isPressed)
        case .keyboardS:
            inputSink?.setMovementKey(.backward, isPressed: isPressed)
        case .keyboardA:
            inputSink?.setMovementKey(.left, isPressed: isPressed)
        case .keyboardD:
            inputSink?.setMovementKey(.right, isPressed: isPressed)
        case .keyboardLeftShift, .keyboardRightShift:
            inputSink?.setShiftPressed(isPressed)
        case .keyboardLeftArrow:
            if isPressed { inputSink?.requestSceneStep(-1) }
        case .keyboardRightArrow:
            if isPressed { inputSink?.requestSceneStep(1) }
        case .keyboardSpacebar:
            if isPressed { inputSink?.requestPlaybackToggle() }
        case .keyboardR:
            if isPressed { inputSink?.requestReset() }
        default:
            return false
        }
        return true
    }
}
#endif
