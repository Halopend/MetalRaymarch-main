#if os(iOS)
import SwiftUI
import UIKit

/// A horizontal-only recognizer lets vertical swipes continue scrolling the
/// controls panel. The visual label and fill live in SwiftUI above this input.
struct ParameterScrubInput: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let title: String
    let display: String
    let onEditingChanged: (Bool) -> Void
    let isSceneActive: Bool

    func makeUIView(context: Context) -> ParameterScrubTouchView {
        ParameterScrubTouchView()
    }

    func updateUIView(_ view: ParameterScrubTouchView, context: Context) {
        view.value = value
        view.range = range
        view.step = step
        view.valueChanged = { value = $0 }
        view.editingChanged = onEditingChanged
        view.accessibilityLabel = title
        view.accessibilityValue = display
        view.setEnabled(isEnabled && isSceneActive)
    }

    static func dismantleUIView(_ view: ParameterScrubTouchView, coordinator: ()) {
        view.finishEditing()
    }
}

final class ParameterScrubTouchView: UIView, UIGestureRecognizerDelegate {
    var value = 0.0
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var valueChanged: (Double) -> Void = { _ in }
    var editingChanged: (Bool) -> Void = { _ in }
    private var isEditing = false
    private var enabled = true
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(scrub(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityHint = "Drag horizontally to adjust. Swipe vertically to scroll."
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        pan.isEnabled = enabled
        accessibilityTraits = enabled ? .adjustable : [.adjustable, .notEnabled]
        if !enabled { finishEditing() }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: self)
        return enabled && abs(velocity.x) > abs(velocity.y)
    }

    @objc private func scrub(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isEditing = true
            editingChanged(true)
            update(at: gesture.location(in: self).x)
        case .changed:
            update(at: gesture.location(in: self).x)
        case .ended:
            update(at: gesture.location(in: self).x)
            finishEditing()
        case .cancelled, .failed:
            finishEditing()
        default:
            break
        }
    }

    private func update(at x: CGFloat) {
        guard bounds.width > 0 else { return }
        let fraction = min(1, max(0, Double(x / bounds.width)))
        setValue(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
    }

    private func setValue(_ proposed: Double) {
        var result = proposed
        if let step, step > 0 {
            result = range.lowerBound + ((result - range.lowerBound) / step).rounded() * step
        }
        value = min(range.upperBound, max(range.lowerBound, result))
        valueChanged(value)
    }

    func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        editingChanged(false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishEditing() }
    }

    override func accessibilityIncrement() { adjustAccessibly(direction: 1) }
    override func accessibilityDecrement() { adjustAccessibly(direction: -1) }

    private func adjustAccessibly(direction: Double) {
        guard enabled else { return }
        setValue(value + direction * (step ?? (range.upperBound - range.lowerBound) / 100))
    }
}
#endif
