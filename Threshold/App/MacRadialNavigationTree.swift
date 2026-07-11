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

/// Live read/write access for one radial slider leaf.
///
/// Closures rather than key paths so a single type can front every backing
/// store in the app (ControlCatalog-routed descriptors, per-fractal formula
/// params, ad-hoc RenderSettings properties) without the tree knowing which.
struct MacRadialSliderBinding {
    let range: ClosedRange<Float>
    let read: () -> Float
    let write: (Float) -> Void
    /// Compact value label shown inside the pill (e.g. "1.4", "12").
    let format: (Float) -> String

    init(
        range: ClosedRange<Float>,
        read: @escaping () -> Float,
        write: @escaping (Float) -> Void,
        format: @escaping (Float) -> String = { String(format: "%.2f", $0) }
    ) {
        self.range = range
        self.read = read
        self.write = write
        self.format = format
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

/// The slider pill currently under the pointer, with its (inflated) hit frame
/// in the menu's coordinate space. The frame lets the NSEvent monitor verify
/// the pointer geometrically — hover-exit events are sometimes dropped by the
/// system, and a stale id alone would keep hijacking scroll events.
struct MacRadialActiveSlider: Equatable {
    let id: String
    let frame: CGRect
}

extension [MacRadialNavNode] {
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
