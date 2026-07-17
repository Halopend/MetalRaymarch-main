#if os(macOS)
import Foundation
import SwiftUI

/// One node of the launcher's navigation tree.
///
/// The tree is the single source of truth for BOTH launcher rendering modes
/// (radial fan and right-edge grid): each mode walks the same nodes and decides
/// only where to place them. Reorganizing the launcher therefore means editing
/// the builder in `ThresholdMacApp`, never the renderers.
///
/// Activation policy is derived from shape, not from position:
///  - `children` non-empty  → hovering the pill auto-selects it and reveals the
///    next ring. Pure navigation must stay side-effect free so sweeping the
///    pointer across pills can never mutate app state irreversibly.
///  - `clickAction` non-nil → clicking performs the side effect (today: opening
///    the controls window on a given tab). Whatever layer ends in a window-
///    opening leaf is automatically the click layer — moving "Quick Toggles"
///    deeper into the tree keeps it click-to-open without touching render code.
///  - `slider` non-nil      → terminal ring renders the node as a radial slider
///    that scrubs a live control value in place.
///
/// A node may combine `children` with `clickAction`: hover previews the deeper
/// ring while click still jumps straight into the full controls panel.
struct MacRadialNavNode: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let isSelected: Bool
    let children: [MacRadialNavNode]
    let clickAction: (() -> Void)?
    let slider: MacRadialSliderBinding?

    init(
        id: String,
        title: String,
        systemImage: String,
        isSelected: Bool = false,
        children: [MacRadialNavNode] = [],
        clickAction: (() -> Void)? = nil,
        slider: MacRadialSliderBinding? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.children = children
        self.clickAction = clickAction
        self.slider = slider
    }

    var isBranch: Bool { !children.isEmpty }
}

/// One keyboard-stop in the launcher's flattened, depth-first traversal.
///
/// `ancestorPath` contains only the branches that must be selected to reveal
/// the target. The target's own id is deliberately excluded, even when it is a
/// branch, so focusing an item never opens its children as a side effect.
struct MacRadialKeyboardTarget: Equatable {
    let id: String
    let ancestorPath: [String]
}

/// Pure focus-order policy shared by both launcher layouts.
enum MacRadialKeyboardNavigation {
    /// Returns the adjacent target id, wrapping at either end. A missing or
    /// stale focus starts at the leading edge for forward traversal and the
    /// trailing edge for backward traversal.
    static func nextID(
        from currentID: String?,
        in targets: [MacRadialKeyboardTarget],
        backward: Bool
    ) -> String? {
        guard !targets.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = targets.firstIndex(where: { $0.id == currentID }) else {
            return backward ? targets.last?.id : targets.first?.id
        }

        let delta = backward ? -1 : 1
        let nextIndex = (currentIndex + delta + targets.count) % targets.count
        return targets[nextIndex].id
    }
}

/// Live read/write access for one radial slider leaf.
///
/// Closures rather than key paths so a single type can front every backing
/// store in the app (ControlCatalog-routed descriptors, per-fractal formula
/// params, ad-hoc RenderSettings properties) without the tree knowing which.
struct MacRadialSliderBinding {
    let range: ClosedRange<Float>
    let read: () -> Float
    let write: (Float) -> Void
    /// Live availability check. A closure keeps dependent controls in sync with
    /// the setting that owns their availability without rebuilding the tree.
    let isEnabled: () -> Bool
    /// Optional absolute step used by discrete controls such as transform
    /// enable switches and Coxeter p/q values. Continuous sliders derive their
    /// keyboard step from a fraction of the authored range instead.
    let keyboardStep: Float?
    /// Compact value label shown inside the pill (e.g. "1.4", "12").
    let format: (Float) -> String

    init(
        range: ClosedRange<Float>,
        read: @escaping () -> Float,
        write: @escaping (Float) -> Void,
        isEnabled: @escaping () -> Bool = { true },
        keyboardStep: Float? = nil,
        format: @escaping (Float) -> String = { String(format: "%.2f", $0) }
    ) {
        self.range = range
        self.read = read
        self.write = write
        self.isEnabled = isEnabled
        self.keyboardStep = keyboardStep
        self.format = format
    }

    /// Performs a user-originated write only while the control is available.
    /// Callers still own range clamping/quantization, just as they do for
    /// `write`; this method only centralizes the dynamic availability guard.
    func writeIfEnabled(_ value: Float) {
        guard isEnabled() else { return }
        write(value)
    }

    /// Moves by a fraction of the full range and clamps the live value. This is
    /// the keyboard/accessibility counterpart to pointer drag and scroll. The
    /// availability closure is evaluated for every call so dependent controls
    /// cannot be changed after becoming unavailable.
    func step(by direction: Float, fraction: Float = 0.05) {
        guard isEnabled() else { return }
        let span = range.upperBound - range.lowerBound
        let delta = direction * (keyboardStep ?? span * max(fraction, 0))
        writeIfEnabled((read() + delta).clamped(to: range))
    }

    /// Normalized 0…1 position of the current value inside `range`.
    func normalized(_ value: Float) -> Float {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    /// Value for a normalized 0…1 position, clamped into `range`.
    func denormalized(_ position: Float) -> Float {
        (range.lowerBound + position.clamped(to: 0...1) * (range.upperBound - range.lowerBound))
            .clamped(to: range)
    }

    /// Conventional horizontal slider mapping: right increases and left
    /// decreases. `fullRangeTravel` is the point distance that spans min→max.
    func value(
        startingAt start: Float,
        horizontalTranslation: CGFloat,
        fullRangeTravel: CGFloat
    ) -> Float {
        guard fullRangeTravel > 0 else { return start.clamped(to: range) }
        let span = range.upperBound - range.lowerBound
        let delta = Float(horizontalTranslation / fullRangeTravel) * span
        return (start + delta).clamped(to: range)
    }
}

/// Builds the live controls for one instance in the composable Transform stack.
///
/// Bindings deliberately capture the op UUID rather than its array position.
/// Users can put multiple instances of the same transform in the stack and can
/// reorder them in the full editor; a stale quick-control binding must continue
/// to edit that exact instance or become a no-op after it is deleted.
enum MacRadialTransformNodeFactory {
    typealias OpReader = (UUID) -> SpaceWarpOpValue?
    typealias OpUpdater = (UUID, (inout SpaceWarpOpValue) -> Void) -> Void

    static func branch(
        for snapshot: SpaceWarpOpValue,
        position: Int,
        read: @escaping OpReader,
        update: @escaping OpUpdater
    ) -> MacRadialNavNode {
        let kind = snapshot.kind
        let opID = snapshot.id
        let idPrefix = "transform.op.\(opID.uuidString.lowercased())"
        var controls: [MacRadialNavNode] = []

        controls.append(sliderNode(
            id: "\(idPrefix).enabled",
            title: "Enabled",
            systemImage: "power",
            range: 0...1,
            fallback: snapshot.isEnabled ? 1 : 0,
            keyboardStep: 1,
            read: { read(opID).map { $0.isEnabled ? 1 : 0 } },
            write: { value in update(opID) { $0.isEnabled = value >= 0.5 } },
            isEnabled: { read(opID) != nil },
            format: { $0 >= 0.5 ? "On" : "Off" }
        ))

        // Coxeter's reflection group is discrete; its full editor intentionally
        // exposes only p/q rather than a blend-strength control.
        if kind != .coxeter {
            controls.append(sliderNode(
                id: "\(idPrefix).strength",
                title: kind.amountLabel,
                systemImage: kind.icon,
                range: kind.strengthRange,
                fallback: snapshot.strength,
                read: { read(opID)?.strength },
                write: { value in update(opID) { $0.strength = value } },
                isEnabled: { read(opID)?.isEnabled == true }
            ))
        }

        for spec in kind.params {
            let isDiscrete = kind == .coxeter
                || (kind == .kaleidoscope && spec.slot == 1)
            let fallback = spec.slot == 1 ? snapshot.p1 : snapshot.p2
            controls.append(sliderNode(
                id: "\(idPrefix).param\(spec.slot)",
                title: spec.label,
                systemImage: spec.icon,
                range: spec.range,
                fallback: fallback,
                keyboardStep: isDiscrete ? 1 : nil,
                read: {
                    guard let op = read(opID) else { return nil }
                    return spec.slot == 1 ? op.p1 : op.p2
                },
                write: { value in
                    update(opID) { op in
                        let resolved = isDiscrete ? value.rounded() : value
                        if spec.slot == 1 { op.p1 = resolved } else { op.p2 = resolved }
                    }
                },
                isEnabled: { read(opID)?.isEnabled == true },
                format: isDiscrete ? { String(Int($0.rounded())) } : valueFormat(for: spec.range)
            ))
        }

        if let toggle = kind.toggle {
            controls.append(sliderNode(
                id: "\(idPrefix).option",
                title: toggle.label,
                systemImage: toggle.icon,
                range: 0...1,
                fallback: snapshot.p2,
                keyboardStep: 1,
                read: { read(opID)?.p2 },
                write: { value in update(opID) { $0.p2 = value >= 0.5 ? 1 : 0 } },
                isEnabled: { read(opID)?.isEnabled == true },
                format: { $0 >= 0.5 ? "On" : "Off" }
            ))
        }

        if kind.usesAxis {
            let axisControls: [(suffix: String, title: String, icon: String, keyPath: WritableKeyPath<SIMD3<Float>, Float>)] = [
                ("axisX", "\(kind.axisLabel) X", "arrow.left.and.right", \.x),
                ("axisY", "\(kind.axisLabel) Y", "arrow.up.and.down", \.y),
                ("axisZ", "\(kind.axisLabel) Z", "arrow.up.left.and.arrow.down.right", \.z)
            ]
            for axis in axisControls {
                controls.append(sliderNode(
                    id: "\(idPrefix).\(axis.suffix)",
                    title: axis.title,
                    systemImage: axis.icon,
                    range: -1...1,
                    fallback: snapshot.axis[keyPath: axis.keyPath],
                    read: { read(opID)?.axis[keyPath: axis.keyPath] },
                    write: { value in update(opID) { $0.axis[keyPath: axis.keyPath] = value } },
                    isEnabled: { read(opID)?.isEnabled == true }
                ))
            }
        }

        return MacRadialNavNode(
            id: idPrefix,
            title: "\(position + 1) · \(kind.displayName)",
            systemImage: kind.icon,
            children: controls
        )
    }

    private static func sliderNode(
        id: String,
        title: String,
        systemImage: String,
        range: ClosedRange<Float>,
        fallback: Float,
        keyboardStep: Float? = nil,
        read: @escaping () -> Float?,
        write: @escaping (Float) -> Void,
        isEnabled: @escaping () -> Bool,
        format: ((Float) -> String)? = nil
    ) -> MacRadialNavNode {
        MacRadialNavNode(
            id: "slider.\(id)",
            title: title,
            systemImage: systemImage,
            slider: MacRadialSliderBinding(
                range: range,
                read: { read() ?? fallback },
                write: { write($0.clamped(to: range)) },
                isEnabled: isEnabled,
                keyboardStep: keyboardStep,
                format: format ?? valueFormat(for: range)
            )
        )
    }

    private static func valueFormat(for range: ClosedRange<Float>) -> (Float) -> String {
        let span = range.upperBound - range.lowerBound
        return span >= 8
            ? { String(format: "%.1f", $0) }
            : { String(format: "%.2f", $0) }
    }
}

/// The slider pill currently under the pointer, with its (inflated) hit frame
/// in the menu's coordinate space. The frame lets the NSEvent monitor verify
/// the pointer geometrically — hover-exit events are sometimes dropped by the
/// system, and a stale id alone would keep hijacking scroll events.
struct MacRadialActiveSlider: Equatable {
    let id: String
    let frame: CGRect
}

extension [MacRadialNavNode] {
    /// All launcher nodes in stable preorder, including branches, action
    /// leaves, and slider leaves. Each target carries the branch path needed to
    /// reveal it in the ring/column renderer without invoking any node action.
    func flattenedKeyboardTargets() -> [MacRadialKeyboardTarget] {
        var targets: [MacRadialKeyboardTarget] = []

        func append(_ nodes: [MacRadialNavNode], ancestors: [String]) {
            for node in nodes {
                targets.append(MacRadialKeyboardTarget(id: node.id, ancestorPath: ancestors))
                append(node.children, ancestors: ancestors + [node.id])
            }
        }

        append(self, ancestors: [])
        return targets
    }

    /// The nodes revealed at each depth by following `path` (selected node ids
    /// per level) from these roots. Index 0 is always the root ring; a path
    /// entry that no longer matches (e.g. a fractal switch removed a formula
    /// branch) truncates the walk instead of showing an orphaned ring.
    func rings(along path: [String]) -> [[MacRadialNavNode]] {
        var rings: [[MacRadialNavNode]] = [self]
        var current = self
        for id in path {
            guard let next = current.first(where: { $0.id == id }), next.isBranch else { break }
            rings.append(next.children)
            current = next.children
        }
        return rings
    }

    /// Depth-first lookup, used by tests and selection reconciliation.
    func node(withID id: String) -> MacRadialNavNode? {
        for node in self {
            if node.id == id { return node }
            if let found = node.children.node(withID: id) { return found }
        }
        return nil
    }
}
#endif
