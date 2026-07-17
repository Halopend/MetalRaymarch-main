#if os(macOS)
import Foundation
import SwiftUI

/// One node of the launcher's navigation tree.
///
/// One layout-neutral node in the quick-menu navigation hierarchy. Radial,
/// grid, and keyboard presentations all consume the same node graph.
///
/// Activation policy is derived from shape, not from position:
///  - `children` non-empty  → hovering the pill auto-selects it and reveals the
///    next ring. Pure navigation must stay side-effect free so sweeping the
///    pointer across pills can never mutate app state irreversibly.
///  - `fallbackAction` non-nil → a leaf that cannot expose useful quick inputs
///    opens the full rectangular controls surface at its routed destination.
///  - `slider` non-nil      → a terminal quick input scrubs a live value in place.
///
/// Branches never run fallback actions. Once quick inputs exist, hover, click,
/// Return, and Right Arrow all remain inside the quick-menu hierarchy.
final class MacNavigationOverflowFallback {
    let node: MacNavigationNode

    init(_ node: MacNavigationNode) {
        self.node = node
    }
}

struct MacNavigationNode: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let isSelected: Bool
    let children: [MacNavigationNode]
    let fallbackAction: (() -> Void)?
    let slider: MacQuickSliderBinding?
    /// Optional item budget for compact presentations such as the radial fan.
    /// Grid retains the complete descendant set when it flattens quick inputs.
    let compactChildrenLimit: Int?
    /// A routed leaf appended when compact projection exceeds its item budget.
    let overflowFallback: MacNavigationOverflowFallback?

    init(
        id: String,
        title: String,
        systemImage: String,
        isSelected: Bool = false,
        children: [MacNavigationNode] = [],
        fallbackAction: (() -> Void)? = nil,
        slider: MacQuickSliderBinding? = nil,
        compactChildrenLimit: Int? = nil,
        overflowFallback: MacNavigationOverflowFallback? = nil
    ) {
        assert(
            fallbackAction == nil || (children.isEmpty && slider == nil),
            "Fallback actions belong only on leaves without radial quick inputs."
        )
        assert(compactChildrenLimit == nil || !children.isEmpty)
        assert(
            overflowFallback == nil
            || (overflowFallback?.node.children.isEmpty == true
                && overflowFallback?.node.slider == nil
                && overflowFallback?.node.fallbackAction != nil),
            "Overflow fallbacks must be routed action leaves."
        )
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.children = children
        self.fallbackAction = fallbackAction
        self.slider = slider
        self.compactChildrenLimit = compactChildrenLimit
        self.overflowFallback = overflowFallback
    }

    var isBranch: Bool { !children.isEmpty }
}

/// One keyboard-stop in the launcher's flattened, depth-first traversal.
///
/// `ancestorPath` contains only the branches that must be selected to reveal
/// the target. The target's own id is deliberately excluded, even when it is a
/// branch, so focusing an item never opens its children as a side effect.
struct MacNavigationKeyboardTarget: Equatable {
    let id: String
    let ancestorPath: [String]
}

/// Pure focus-order policy shared by radial, grid, and keyboard presentations.
enum MacNavigationKeyboardTraversal {
    /// Returns the adjacent target id, wrapping at either end. A missing or
    /// stale focus starts at the leading edge for forward traversal and the
    /// trailing edge for backward traversal.
    static func nextID(
        from currentID: String?,
        in targets: [MacNavigationKeyboardTarget],
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

/// Live read/write access for one hierarchy slider leaf.
///
/// Closures rather than key paths so a single type can front every backing
/// store in the app (ControlCatalog-routed descriptors, per-fractal formula
/// params, ad-hoc RenderSettings properties) without the tree knowing which.
struct MacQuickSliderBinding {
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
enum MacQuickTransformNodeFactory {
    typealias OpReader = (UUID) -> SpaceWarpOpValue?
    typealias OpUpdater = (UUID, (inout SpaceWarpOpValue) -> Void) -> Void

    static func branch(
        for snapshot: SpaceWarpOpValue,
        position: Int,
        read: @escaping OpReader,
        update: @escaping OpUpdater
    ) -> MacNavigationNode {
        let kind = snapshot.kind
        let opID = snapshot.id
        let idPrefix = "transform.op.\(opID.uuidString.lowercased())"
        var controls: [MacNavigationNode] = []

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

        return MacNavigationNode(
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
    ) -> MacNavigationNode {
        MacNavigationNode(
            id: "slider.\(id)",
            title: title,
            systemImage: systemImage,
            slider: MacQuickSliderBinding(
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
struct MacQuickActiveSlider: Equatable {
    let id: String
    let frame: CGRect
}

/// Complete, layout-neutral hierarchy consumed by every quick-menu input mode.
///
/// The hierarchy owns traversal and projection; renderers own only placement.
/// `.grid` is the complete flattened projection, while `.radial` may substitute
/// an explicit overflow leaf at compact item budgets authored on a node.
struct MacNavigationHierarchy {
    /// Grid reserves these two levels for navigation (top and inner sidebar),
    /// then flattens every deeper descendant into one complete quick-input
    /// surface. Radial continues to present every authored hierarchy level.
    static let gridNavigationDepth = 2

    let roots: [MacNavigationNode]

    init(roots: [MacNavigationNode]) {
        self.roots = roots
    }

    func presentedRoots(for style: MacTabLauncherStyle) -> [MacNavigationNode] {
        roots
    }

    /// Presentation-specific children of a node at an authored hierarchy depth.
    ///
    /// The hierarchy remains the source of truth. Radial consumes its authored
    /// levels (with an optional compact overflow projection); grid consumes the
    /// first two levels as navigation and flattens all terminal descendants of
    /// the selected inner-sidebar node. Group names are retained in projected
    /// leaf titles so controls with repeated labels remain distinguishable.
    func presentedChildren(
        of node: MacNavigationNode,
        atDepth depth: Int,
        for style: MacTabLauncherStyle
    ) -> [MacNavigationNode] {
        if style == .grid {
            return depth >= Self.gridNavigationDepth - 1
                ? flattenedGridLeaves(in: node.children)
                : node.children
        }

        guard let limit = node.compactChildrenLimit,
              node.children.count > limit,
              let overflowFallback = node.overflowFallback?.node,
              limit > 0 else { return node.children }
        return Array(node.children.prefix(max(limit - 1, 0))) + [overflowFallback]
    }

    /// All presented nodes in stable preorder. Each target carries the branch
    /// path needed to reveal it without invoking any node action.
    func flattenedKeyboardTargets(for style: MacTabLauncherStyle) -> [MacNavigationKeyboardTarget] {
        var targets: [MacNavigationKeyboardTarget] = []

        func append(_ nodes: [MacNavigationNode], ancestors: [String], depth: Int) {
            for node in nodes {
                targets.append(MacNavigationKeyboardTarget(id: node.id, ancestorPath: ancestors))
                append(
                    presentedChildren(of: node, atDepth: depth, for: style),
                    ancestors: ancestors + [node.id],
                    depth: depth + 1
                )
            }
        }

        append(presentedRoots(for: style), ancestors: [], depth: 0)
        return targets
    }

    /// The nodes revealed at each depth by following `path` (selected node ids
    /// per level) from these roots. Index 0 is always the root ring; a path
    /// entry that no longer matches (e.g. a fractal switch removed a formula
    /// branch) truncates the walk instead of showing an orphaned ring.
    func rings(
        along path: [String],
        for style: MacTabLauncherStyle
    ) -> [[MacNavigationNode]] {
        let presentedRoots = presentedRoots(for: style)
        var rings: [[MacNavigationNode]] = [presentedRoots]
        var current = presentedRoots
        for (depth, id) in path.enumerated() {
            guard let next = current.first(where: { $0.id == id }), next.isBranch else { break }
            let children = presentedChildren(of: next, atDepth: depth, for: style)
            rings.append(children)
            current = children
        }
        return rings
    }

    /// Keeps the longest valid branch prefix when switching presentation or
    /// rebuilding dynamic children. A grid-only deep selection therefore
    /// retreats to its nearest radial ancestor instead of orphaning the path.
    func reconciledPath(
        _ path: [String],
        for style: MacTabLauncherStyle
    ) -> [String] {
        var resolved: [String] = []
        var current = presentedRoots(for: style)
        for (depth, id) in path.enumerated() {
            guard let node = current.first(where: { $0.id == id }), node.isBranch else { break }
            resolved.append(id)
            current = presentedChildren(of: node, atDepth: depth, for: style)
        }
        return resolved
    }

    /// Depth-first lookup in one presentation, used by focus, live slider
    /// routing, tests, and path reconciliation.
    func node(
        withID id: String,
        for style: MacTabLauncherStyle
    ) -> MacNavigationNode? {
        func find(in nodes: [MacNavigationNode], depth: Int) -> MacNavigationNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = find(
                    in: presentedChildren(of: node, atDepth: depth, for: style),
                    depth: depth + 1
                ) { return found }
            }
            return nil
        }

        return find(in: presentedRoots(for: style), depth: 0)
    }

    /// Complete lookup independent of a presentation. Overflow fallbacks are
    /// included even though they are not part of the grid's complete child set.
    func node(withID id: String) -> MacNavigationNode? {
        func find(in nodes: [MacNavigationNode]) -> MacNavigationNode? {
            for node in nodes {
                if node.id == id { return node }
                if let overflow = node.overflowFallback?.node, overflow.id == id { return overflow }
                if let found = find(in: node.children) { return found }
            }
            return nil
        }

        return find(in: roots)
    }

    private func flattenedGridLeaves(in nodes: [MacNavigationNode]) -> [MacNavigationNode] {
        var leaves: [MacNavigationNode] = []

        func append(_ nodes: [MacNavigationNode], groupTitles: [String]) {
            for node in nodes {
                if node.isBranch {
                    append(node.children, groupTitles: groupTitles + [node.title])
                } else {
                    let projectedTitle = (groupTitles + [node.title]).joined(separator: " › ")
                    leaves.append(node.projected(title: projectedTitle))
                }
            }
        }

        append(nodes, groupTitles: [])
        return leaves
    }
}

private extension MacNavigationNode {
    func projected(title: String) -> MacNavigationNode {
        MacNavigationNode(
            id: id,
            title: title,
            systemImage: systemImage,
            isSelected: isSelected,
            children: children,
            fallbackAction: fallbackAction,
            slider: slider,
            compactChildrenLimit: compactChildrenLimit,
            overflowFallback: overflowFallback
        )
    }
}

extension [MacNavigationNode] {
    /// Compatibility conveniences for non-rendering callers. New presentation
    /// code should consume `MacNavigationHierarchy` explicitly.
    func flattenedKeyboardTargets() -> [MacNavigationKeyboardTarget] {
        MacNavigationHierarchy(roots: self).flattenedKeyboardTargets(for: .grid)
    }

    func rings(along path: [String]) -> [[MacNavigationNode]] {
        MacNavigationHierarchy(roots: self).rings(along: path, for: .grid)
    }

    func node(withID id: String) -> MacNavigationNode? {
        for node in self {
            if node.id == id { return node }
            if let found = node.children.node(withID: id) { return found }
        }
        return nil
    }
}
#endif
