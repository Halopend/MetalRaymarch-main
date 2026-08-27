import Foundation
import SwiftUI

enum RadialInteractionProfile: Sendable {
    case pointer
    case touch

    var supportsHoverNavigation: Bool { self == .pointer }
    var minimumTargetSize: CGFloat { self == .touch ? 44 : 28 }
    var itemSpacing: CGFloat { self == .touch ? 48 : 32 }
}

/// A restrained "focus magnification" shared by every radial pill. The active
/// feature receives a little more visual space as the user moves deeper into
/// the hierarchy, without turning the launcher into a literal loupe or moving
/// its stable hit target.
enum RadialFocusMagnification {
    static func scale(
        for profile: RadialInteractionProfile,
        isFocused: Bool,
        isExpanded: Bool = false,
        isEngaged: Bool = false
    ) -> CGFloat {
        if isExpanded {
            return profile == .touch ? 1.055 : 1.045
        }
        if isFocused || isEngaged {
            return profile == .touch ? 1.045 : 1.035
        }
        return 1
    }

    static func protectedHalfExtent(
        _ restingHalfExtent: CGFloat,
        for profile: RadialInteractionProfile
    ) -> CGFloat {
        restingHalfExtent * scale(
            for: profile,
            isFocused: false,
            isExpanded: true
        )
    }
}

enum RadialActivationPolicy {
    static func maximumMovement(for profile: RadialInteractionProfile) -> CGFloat {
        profile == .touch ? 12 : 4
    }

    static func shouldToggle(
        activationCount: Int,
        movement: CGFloat,
        profile: RadialInteractionProfile
    ) -> Bool {
        activationCount >= 2 && movement <= maximumMovement(for: profile)
    }

    static func shouldOpenFullControls(
        activationCount: Int,
        hasFullControlsAction: Bool
    ) -> Bool {
        hasFullControlsAction && activationCount >= 2
    }
}

/// Phone quick controls deliberately use screen-edge swipes instead of a
/// hidden double-tap. An inward edge swipe opens the strip; the reverse swipe
/// from that strip dismisses it. Neither side is assigned to a dominant hand.
enum PhoneEdgeMenuGesturePolicy {
    static let revealDistance: CGFloat = 96
    static let dismissalDistance: CGFloat = 24

    static func revealProgress(for translation: CGFloat) -> CGFloat {
        min(max(translation / revealDistance, 0), 1)
    }

    static func shouldPresent(translation: CGFloat) -> Bool {
        translation >= revealDistance * 0.72
    }

    static func shouldDismiss(opensLeft: Bool, horizontalTranslation: CGFloat) -> Bool {
        opensLeft
            ? horizontalTranslation >= dismissalDistance
            : horizontalTranslation <= -dismissalDistance
    }
}

/// Shared transient state for every 2-D radial host. Platform adapters provide
/// only the interaction profile and activation location.
@MainActor
@Observable
final class RadialMenuModel {
    let interactionProfile: RadialInteractionProfile
    private(set) var isPresented = false
    var anchor: CGPoint = .zero
    var path: [String] = []
    var hoveredSlider: RadialActiveSlider?

    init(interactionProfile: RadialInteractionProfile) {
        self.interactionProfile = interactionProfile
    }

    func present(at point: CGPoint, initialPath: [String] = []) {
        anchor = point
        path = initialPath
        hoveredSlider = nil
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        path = []
        hoveredSlider = nil
    }

    func toggle(at point: CGPoint, initialPath: [String] = []) {
        isPresented ? dismiss() : present(at: point, initialPath: initialPath)
    }
}

/// A radial-presentation node. The platform-neutral route and label hierarchy
/// lives in `NavigationHierarchy`; this type decorates those routes with live
/// quick inputs and full-controls fallback actions.
///
/// Activation policy is derived from shape, not from position:
///  - `children` non-empty  → hovering the pill auto-selects it and reveals the
///    next ring. Pure navigation must stay side-effect free so sweeping the
///    pointer across pills can never mutate app state irreversibly.
///  - `fallbackAction` non-nil → a leaf that cannot expose useful quick inputs
///    opens the full rectangular controls surface at its routed destination.
///  - `fullControlsAction` non-nil → a branch can be double-clicked to open the
///    same destination in the rectangular control panel without giving up its
///    radial quick-input children.
///  - `slider` non-nil      → a terminal quick input scrubs a live value in place.
///  - `toggle` non-nil      → a terminal binary input switches live in place.
///
/// Branches never run fallback actions. Their normal activation and hover stay
/// inside the quick-menu hierarchy; only an explicit double-click follows the
/// full-controls action.
final class RadialOverflowFallback {
    let node: RadialNavigationNode

    init(_ node: RadialNavigationNode) {
        self.node = node
    }
}

struct RadialNavigationNode: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let isSelected: Bool
    let children: [RadialNavigationNode]
    let fallbackAction: (() -> Void)?
    let fullControlsAction: (() -> Void)?
    let slider: RadialSliderBinding?
    let toggle: RadialToggleBinding?
    /// Optional item budget for the compact radial fan.
    let compactChildrenLimit: Int?
    /// A routed leaf appended when compact projection exceeds its item budget.
    let overflowFallback: RadialOverflowFallback?

    init(
        id: String,
        title: String,
        systemImage: String,
        isSelected: Bool = false,
        children: [RadialNavigationNode] = [],
        fallbackAction: (() -> Void)? = nil,
        fullControlsAction: (() -> Void)? = nil,
        slider: RadialSliderBinding? = nil,
        toggle: RadialToggleBinding? = nil,
        compactChildrenLimit: Int? = nil,
        overflowFallback: RadialOverflowFallback? = nil
    ) {
        assert(
            fallbackAction == nil || (children.isEmpty && slider == nil && toggle == nil),
            "Fallback actions belong only on leaves without radial quick inputs."
        )
        assert(
            fullControlsAction == nil || !children.isEmpty,
            "Full-controls actions decorate navigable radial branches."
        )
        assert(
            slider == nil || toggle == nil,
            "A radial quick input must be either continuous or binary."
        )
        assert(compactChildrenLimit == nil || !children.isEmpty)
        assert(
            overflowFallback == nil
            || (overflowFallback?.node.children.isEmpty == true
                && overflowFallback?.node.slider == nil
                && overflowFallback?.node.toggle == nil
                && overflowFallback?.node.fallbackAction != nil),
            "Overflow fallbacks must be routed action leaves."
        )
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.children = children
        self.fallbackAction = fallbackAction
        self.fullControlsAction = fullControlsAction
        self.slider = slider
        self.toggle = toggle
        self.compactChildrenLimit = compactChildrenLimit
        self.overflowFallback = overflowFallback
    }

    var isBranch: Bool { !children.isEmpty }
}

/// Live read/write access for a binary radial leaf.
///
/// Keeping toggles distinct from sliders gives touch, keyboard, and assistive
/// technologies an actual on/off interaction instead of exposing a continuous
/// 0…1 value. Availability is checked again for every write so a dependent
/// control cannot mutate after the projection was built.
struct RadialToggleBinding {
    let read: () -> Bool
    let write: (Bool) -> Void
    let isEnabled: () -> Bool

    init(
        read: @escaping () -> Bool,
        write: @escaping (Bool) -> Void,
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.read = read
        self.write = write
        self.isEnabled = isEnabled
    }

    func set(_ value: Bool) {
        guard isEnabled() else { return }
        write(value)
    }

    func toggle() {
        set(!read())
    }
}

/// Live read/write access for one hierarchy slider leaf.
///
/// Closures rather than key paths so a single type can front every backing
/// store in the app (ControlCatalog-routed descriptors, per-fractal formula
/// params, ad-hoc RenderSettings properties) without the tree knowing which.
struct RadialSliderBinding {
    let range: ClosedRange<Float>
    let read: () -> Float
    let write: (Float) -> Void
    /// Live availability check. A closure keeps dependent controls in sync with
    /// the setting that owns their availability without rebuilding the tree.
    let isEnabled: () -> Bool
    /// Optional absolute step used by discrete scalar controls such as Coxeter
    /// p/q values. Continuous sliders derive their keyboard step from a
    /// fraction of the authored range instead.
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
enum RadialTransformNodeFactory {
    typealias OpReader = (UUID) -> SpaceWarpOpValue?
    typealias OpUpdater = (UUID, (inout SpaceWarpOpValue) -> Void) -> Void

    static func branch(
        for snapshot: SpaceWarpOpValue,
        position: Int,
        read: @escaping OpReader,
        update: @escaping OpUpdater,
        fullControlsAction: (() -> Void)? = nil
    ) -> RadialNavigationNode {
        let kind = snapshot.kind
        let opID = snapshot.id
        let idPrefix = "transform.op.\(opID.uuidString.lowercased())"
        var controls: [RadialNavigationNode] = []

        controls.append(toggleNode(
            id: "\(idPrefix).enabled",
            title: "Enabled",
            systemImage: "power",
            fallback: snapshot.isEnabled,
            read: { read(opID)?.isEnabled },
            write: { value in update(opID) { $0.isEnabled = value } },
            isEnabled: { read(opID) != nil }
        ))

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
            controls.append(toggleNode(
                id: "\(idPrefix).option",
                title: toggle.label,
                systemImage: toggle.icon,
                fallback: snapshot.p2 >= 0.5,
                read: { read(opID).map { $0.p2 >= 0.5 } },
                write: { value in update(opID) { $0.p2 = value ? 1 : 0 } },
                isEnabled: { read(opID)?.isEnabled == true }
            ))
        }

        if let sourceAngle = kind.sourceAngle {
            controls.append(sliderNode(
                id: "\(idPrefix).sourceAngle",
                title: sourceAngle.label,
                systemImage: sourceAngle.icon,
                range: sourceAngle.range,
                fallback: snapshot.axis.z,
                read: { read(opID)?.axis.z },
                write: { value in update(opID) { $0.axis.z = value } },
                isEnabled: { read(opID)?.isEnabled == true },
                format: { String(format: "%.0f°", $0 * 180 / Float.pi) }
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

        return RadialNavigationNode(
            id: idPrefix,
            title: "\(position + 1) · \(kind.displayName)",
            systemImage: kind.icon,
            children: controls,
            fullControlsAction: fullControlsAction
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
    ) -> RadialNavigationNode {
        RadialNavigationNode(
            id: "slider.\(id)",
            title: title,
            systemImage: systemImage,
            slider: RadialSliderBinding(
                range: range,
                read: { read() ?? fallback },
                write: { write($0.clamped(to: range)) },
                isEnabled: isEnabled,
                keyboardStep: keyboardStep,
                format: format ?? valueFormat(for: range)
            )
        )
    }

    private static func toggleNode(
        id: String,
        title: String,
        systemImage: String,
        fallback: Bool,
        read: @escaping () -> Bool?,
        write: @escaping (Bool) -> Void,
        isEnabled: @escaping () -> Bool
    ) -> RadialNavigationNode {
        RadialNavigationNode(
            id: "toggle.\(id)",
            title: title,
            systemImage: systemImage,
            toggle: RadialToggleBinding(
                read: { read() ?? fallback },
                write: write,
                isEnabled: isEnabled
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

/// The slider pill currently being targeted, with its inflated hit frame in
/// menu coordinates. Platform input adapters can verify stale hover/pointer
/// state geometrically before routing scroll or indirect-input events.
struct RadialActiveSlider: Equatable {
    let id: String
    let frame: CGRect
}

/// A pinned section exposed independently of the path-driven radial rings.
/// Its identity deliberately differs from the route node's identity: a single
/// route can appear in both the normal hierarchy and persistent Quick Access.
struct RadialQuickAccessShortcut: Identifiable {
    let route: AppRoute
    let isSelected: Bool

    var id: String { "quickAccess.\(route.stableID)" }
    var title: String { route.title }
    var systemImage: String { route.systemImage }
}

/// Presentation-neutral radial decoration and traversal of the shared tree.
/// Compact item budgets may substitute an explicit full-controls fallback leaf.
struct RadialNavigationProjection {
    let roots: [RadialNavigationNode]

    init(roots: [RadialNavigationNode]) {
        self.roots = Self.uniquedByID(roots)
    }

    func presentedChildren(of node: RadialNavigationNode) -> [RadialNavigationNode] {
        var children = directPresentedChildren(of: node)

        // A ring with one navigable branch adds no choice. Treat that branch
        // as transparent so selecting its parent reveals the first meaningful
        // set of options immediately. Keeping the skipped branch out of the
        // visible projection also makes Back remove one visible ring instead
        // of stopping on the redundant singleton.
        while children.count == 1, let onlyChild = children.first, onlyChild.isBranch {
            children = directPresentedChildren(of: onlyChild)
        }
        return children
    }

    /// Applies de-duplication and compact overflow to one authored edge without
    /// collapsing a singleton branch. Path reconciliation and lookup use this
    /// form when they need to recognize a branch omitted from presentation.
    private func directPresentedChildren(
        of node: RadialNavigationNode
    ) -> [RadialNavigationNode] {
        // De-duplicate before the compact budget so a duplicate never counts
        // toward the limit or displaces a unique sibling into overflow.
        let children = Self.uniquedByID(node.children)
        guard let limit = node.compactChildrenLimit,
              children.count > limit,
              let overflowFallback = node.overflowFallback?.node,
              limit > 0 else { return children }
        return Array(children.prefix(max(limit - 1, 0))) + [overflowFallback]
    }

    /// Node id uniqueness is not a structural guarantee: transform quick
    /// controls derive their ids from persisted `SpaceWarpOpValue` UUIDs,
    /// which an imported scene file can duplicate (hand-edited, merged, or
    /// produced by another client). Every projection consumer is id-addressed
    /// — ForEach identity, keyboard-focus dictionaries, `path` walks — so a
    /// duplicate cannot be presented meaningfully; keep the first occurrence
    /// instead of letting the collision reach those consumers.
    private static func uniquedByID(_ nodes: [RadialNavigationNode]) -> [RadialNavigationNode] {
        var seen = Set<String>()
        return nodes.filter { seen.insert($0.id).inserted }
    }

    /// All presented nodes in stable preorder. Each target carries the branch
    /// path needed to reveal it without invoking any node action.
    func flattenedKeyboardTargets() -> [NavigationHierarchy.KeyboardTarget] {
        var targets: [NavigationHierarchy.KeyboardTarget] = []

        func append(_ nodes: [RadialNavigationNode], ancestors: [String]) {
            for node in nodes {
                targets.append(NavigationHierarchy.KeyboardTarget(id: node.id, ancestorPath: ancestors))
                append(presentedChildren(of: node), ancestors: ancestors + [node.id])
            }
        }

        append(roots, ancestors: [])
        return targets
    }

    /// The nodes revealed at each depth by following `path` (selected node ids
    /// per level) from these roots. Index 0 is always the root ring; a path
    /// entry that no longer matches (e.g. a fractal switch removed a formula
    /// branch) truncates the walk instead of showing an orphaned ring.
    func rings(along path: [String]) -> [[RadialNavigationNode]] {
        var rings: [[RadialNavigationNode]] = [roots]
        var current = roots
        for id in path {
            guard let next = current.first(where: { $0.id == id }), next.isBranch else { break }
            let children = presentedChildren(of: next)
            rings.append(children)
            current = children
        }
        return rings
    }

    /// Keeps the longest valid branch prefix while dynamic radial inputs change.
    func reconciledPath(_ path: [String]) -> [String] {
        var resolved: [String] = []
        var current = roots
        var index = 0

        while index < path.count {
            let id = path[index]
            guard let node = current.first(where: { $0.id == id }), node.isBranch else { break }
            resolved.append(id)
            index += 1

            var children = directPresentedChildren(of: node)
            while children.count == 1,
                  let onlyChild = children.first,
                  onlyChild.isBranch {
                // Accept paths produced from the authored hierarchy as well
                // as already-flattened radial paths, but never retain the
                // transparent branch as a visible path component.
                if index < path.count, path[index] == onlyChild.id {
                    index += 1
                }
                children = directPresentedChildren(of: onlyChild)
            }
            current = children
        }
        return resolved
    }

    /// Depth-first lookup in the radial projection.
    func node(withID id: String) -> RadialNavigationNode? {
        func find(in nodes: [RadialNavigationNode]) -> RadialNavigationNode? {
            for node in nodes {
                if node.id == id { return node }
                // Lookup still recognizes a structurally-authored singleton
                // branch even though that branch has no radial pill of its own.
                if let found = find(in: directPresentedChildren(of: node)) { return found }
            }
            return nil
        }

        return find(in: roots)
    }
}

extension [RadialNavigationNode] {
    /// Compatibility conveniences for non-rendering callers. New presentation
    /// code should consume `RadialNavigationProjection` explicitly.
    func flattenedKeyboardTargets() -> [NavigationHierarchy.KeyboardTarget] {
        RadialNavigationProjection(roots: self).flattenedKeyboardTargets()
    }

    func rings(along path: [String]) -> [[RadialNavigationNode]] {
        RadialNavigationProjection(roots: self).rings(along: path)
    }

    func node(withID id: String) -> RadialNavigationNode? {
        for node in self {
            if node.id == id { return node }
            if let found = node.children.node(withID: id) { return found }
        }
        return nil
    }
}
