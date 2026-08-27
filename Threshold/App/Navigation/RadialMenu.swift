import SwiftUI
#if os(macOS)
import AppKit
#endif

enum NavigationPresentationStyle: String, CaseIterable {
    case separateWindow = "Window"
    case radial = "Radial"
    // Keep the legacy raw value so existing `Grid` preferences migrate to the
    // newly named mode instead of silently falling back to Radial.
    case controlPanel = "Grid"

    var displayName: String {
        switch self {
        case .separateWindow: return "Separate Window"
        case .radial: return "Radial Menu"
        case .controlPanel: return "Control Panel"
        }
    }

    var explanation: String {
        switch self {
        case .separateWindow:
            return "Keeps the complete navigation and controls in their own movable window, leaving the viewport unobscured."
        case .radial:
            return "Opens navigation around the pointer. Destinations that need a full page open a compact content panel without repeating the top dock or section rail."
        case .controlPanel:
            return "Uses the complete top dock, section rail, and controls together in a panel that reveals from the viewport edge."
        }
    }

    var systemImage: String {
        switch self {
        case .separateWindow: return "macwindow"
        case .radial: return "circle.grid.cross"
        case .controlPanel: return "sidebar.right"
        }
    }
}

/// Host-selected geometry for the shared launcher. Phones use a single-level
/// edge strip because concentric rings consume most of a narrow viewport;
/// larger canvases retain the spatial radial presentation.
enum RadialMenuLayout: Sendable, Equatable {
    case radial
    case straightEdge
}

/// Derives a bright UI accent from the active scene gradient while preserving
/// enough contrast against the launcher's dark-purple capsule surface.
enum RadialMenuSceneAccent {
    static func color(from gradient: GradientColorMap) -> Color {
        let samples = gradient.stops.map(\.color) + [
            gradient.evaluate(at: 0.28),
            gradient.evaluate(at: 0.58),
            gradient.evaluate(at: 0.82)
        ]
        let source = samples.max(by: { accentScore($0) < accentScore($1) })
            ?? SIMD3<Float>(0.92, 0.62, 1.00)
        let tuned = contrastTuned(source)
        return Color(
            red: Double(tuned.x),
            green: Double(tuned.y),
            blue: Double(tuned.z)
        )
    }

    private static func accentScore(_ color: SIMD3<Float>) -> Float {
        let clamped = simdClamp(color)
        let maximum = max(clamped.x, max(clamped.y, clamped.z))
        let minimum = min(clamped.x, min(clamped.y, clamped.z))
        let chroma = maximum - minimum
        return chroma * 1.4 + maximum * 0.3
    }

    private static func contrastTuned(_ source: SIMD3<Float>) -> SIMD3<Float> {
        var result = simdClamp(source)
        let background = SIMD3<Float>(0.16, 0.025, 0.25)
        let targetContrast: Float = 3.2

        // Grayscale or near-black palettes should still produce a visible,
        // neutral glint instead of inventing an unrelated hue.
        if max(result.x, max(result.y, result.z)) < 0.12 {
            result = SIMD3<Float>(repeating: 0.78)
        }

        for _ in 0..<8 where contrastRatio(result, background) < targetContrast {
            result += (SIMD3<Float>(repeating: 1) - result) * 0.18
        }
        return simdClamp(result)
    }

    private static func contrastRatio(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        let light = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let dark = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (light + 0.05) / (dark + 0.05)
    }

    private static func relativeLuminance(_ color: SIMD3<Float>) -> Float {
        func linearized(_ component: Float) -> Float {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(color.x)
            + 0.7152 * linearized(color.y)
            + 0.0722 * linearized(color.z)
    }

    private static func simdClamp(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            min(max(color.x, 0), 1),
            min(max(color.y, 0), 1),
            min(max(color.z, 0), 1)
        )
    }
}

/// Pure radial layout shared by pointer- and touch-driven launchers.
///
/// `curvature` is intentionally a parameter rather than a visual constant. A
/// larger value opens the fan farther, while `depth` adds a restrained amount of
/// extra bend so nested controls read as a deeper ring in the hierarchy.
struct RadialMenuGeometry {
    let curvature: CGFloat
    let interactionProfile: RadialInteractionProfile

    init(curvature: CGFloat, interactionProfile: RadialInteractionProfile = .pointer) {
        self.curvature = curvature
        self.interactionProfile = interactionProfile
    }

    /// Capsules are taller than the raw arc spacing near its ends. Keep enough
    /// center-to-center room for the resting size plus focus magnification.
    /// Deeper pointer rings are shorter, so they can remain denser —
    /// hover-to-navigate makes every point of pointer travel count.
    private func minimumItemSpacing(depth: Int, sliderRing: Bool) -> CGFloat {
        if interactionProfile == .touch { return interactionProfile.itemSpacing }
        if depth == 0 { return 38 }
        return sliderRing ? 40 : 32
    }

    /// Ring radii. The primary ring hugs the anchor; each deeper ring is a
    /// compact concentric level around the pointer. These are the tightest values
    /// that still clear a 184×46 primary pill against a 120×34 branch pill at
    /// EVERY curvature — at the tightest curvature the primary pills stack
    /// almost vertically, which is the binding constraint (see
    /// RadialMenuGeometryTests.childRingClearsPrimaryRing).
    static let primaryRadius: CGFloat = 106
    /// Radial center clearance between a selected pill and its child arc.
    /// The value clears the widest compact capsules when the arc points
    /// horizontally, while avoiding the oversized fixed-depth jumps.
    static let concentricRingStep: CGFloat = 116
    static let localBranchRadius: CGFloat = 156
    static let localBranchRadiusStep: CGFloat = 18

    /// Local branches cap their angular spread: a wide arc's end pills swing
    /// back toward the parent column and collide with the parent ring's
    /// vertical neighbors. Excess items get their room from the
    /// minimum-spacing vertical stretch instead, which preserves X.
    static let localBranchMaxSpread: CGFloat = 0.50

    /// Places a compact ring on an exact circle. Unlike the legacy local-branch
    /// placement, every hierarchy level shares the same center; only radius
    /// changes. Angular spacing is derived from pill height so the arc remains
    /// dense without vertically overlapping adjacent hit targets.
    func concentricPositions(
        count: Int,
        anchor: CGPoint,
        radius: CGFloat,
        baseAngle: CGFloat,
        sliderRing: Bool
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        // This is a hard center-to-center floor, not a curvature-scaled ideal:
        // shrinking it at low curvature made neighboring capsules overlap.
        let linearSpacing: CGFloat = interactionProfile == .touch
            ? interactionProfile.itemSpacing
            : (sliderRing ? 40 : 32)
        let curvatureScale = min(max(curvature, 0.35), 1.35)
        let minimumAngularStep = 2 * asin(min(linearSpacing / (2 * max(radius, 1)), 0.82))
        // Curvature may open the arc farther, but can never compress it below
        // the capsule/hit-target clearance above.
        let angularStep = minimumAngularStep * (1 + (curvatureScale - 0.35) * 0.28)
        let windingSign: CGFloat = cos(baseAngle) <= 0 ? 1 : -1

        return (0..<count).map { index in
            let progress = CGFloat(index) - CGFloat(count - 1) * 0.5
            let angle = baseAngle - windingSign * progress * angularStep
            return CGPoint(
                x: anchor.x + cos(angle) * radius,
                y: anchor.y + sin(angle) * radius
            )
        }
    }

    func positions(
        count: Int,
        depth: Int,
        anchor: CGPoint,
        availableHeight: CGFloat,
        opensLeft: Bool = true,
        bifurcates: Bool = false,
        localBranch: Bool = false,
        branchBaseAngle: CGFloat? = nil,
        radiusBoost: CGFloat = 0,
        sliderRing: Bool = false,
        availableWidth: CGFloat = .infinity
    ) -> [CGPoint] {
        guard count > 0 else { return [] }

        if bifurcates, count > 1 {
            return bifurcatedPositions(
                count: count,
                depth: depth,
                anchor: anchor,
                availableHeight: availableHeight,
                startsLeft: opensLeft
            )
        }

        let clampedCurvature = min(max(curvature, 0.35), 1.35)
        let depthBend = 1 + CGFloat(depth) * 0.06
        let maximumSpread = (.pi * 0.66) * clampedCurvature * depthBend
        // Small child sets should form a compact branch, not occupy the whole
        // outer arc. Larger sets progressively consume the available curvature
        // up to the local-branch cap that keeps a branch inside its own sector
        // instead of curling back into the parent ring.
        let spread = depth == 0
            ? maximumSpread
            : min(maximumSpread, CGFloat(max(count - 1, 0)) * 0.20, Self.localBranchMaxSpread)
        // Branch rings need enough separation for their pills to clear the
        // parent ring's pills, including their hover scale.
        let radius: CGFloat
        if depth == 0 {
            radius = Self.primaryRadius
        } else if localBranch {
            radius = Self.localBranchRadius + CGFloat(depth - 1) * Self.localBranchRadiusStep + radiusBoost
        } else {
            radius = 340 + CGFloat(depth - 1) * 96
        }

        // Local branches fan around their parent pill's own outward direction
        // (radially away from the ring center) rather than straight sideways.
        // A branch from an edge pill therefore extends the fan outward instead
        // of sweeping back across the parent ring's column — that crossing was
        // the geometric source of pill collisions at curvature extremes.
        let baseAngle: CGFloat = {
            guard localBranch, let branchBaseAngle else {
                return opensLeft ? .pi : 0
            }
            return branchBaseAngle
        }()
        // Choose the fan's winding so index order still reads roughly top to
        // bottom; where the fan is near-vertical, the minimum-spacing stretch
        // below re-imposes strict top-to-bottom order by index anyway.
        let windingSign: CGFloat = cos(baseAngle) <= 0 ? 1 : -1

        let raw = (0..<count).map { index -> CGPoint in
            let progress = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let angle = baseAngle + windingSign * (0.5 - progress) * spread
            return CGPoint(
                x: anchor.x + cos(angle) * radius,
                y: anchor.y + sin(angle) * radius
            )
        }

        // Equal angular steps bunch up vertically near the ends of an arc. That
        // made the seven 42pt primary capsules overlap at the default curvature
        // (and collapse almost completely at the tightest setting). Stretch only
        // the vertical component when necessary; retaining the original X values
        // preserves the fan silhouette while guaranteeing readable hit targets.
        let spaced: [CGPoint]
        if count > 1 {
            let requiredSpacing = minimumItemSpacing(depth: depth, sliderRing: sliderRing)
            let rawTop = raw.first?.y ?? anchor.y
            let rawBottom = raw.last?.y ?? anchor.y
            let rawSpan = max(rawBottom - rawTop, 0)
            let requiredSpan = requiredSpacing * CGFloat(count - 1)
            let resolvedSpan = max(rawSpan, requiredSpan)
            let centerY = (rawTop + rawBottom) * 0.5

            spaced = raw.enumerated().map { index, point in
                let progress = CGFloat(index) / CGFloat(count - 1)
                return CGPoint(
                    x: point.x,
                    y: centerY + (progress - 0.5) * resolvedSpan
                )
            }
        } else {
            spaced = raw
        }

        // Keep the complete ring on-screen as a group. The anchor still follows
        // the pointer, but a top/bottom edge cannot collapse multiple tabs onto
        // the same clamped coordinate. Deep branches near a side edge get the
        // same treatment horizontally.
        let verticalMargin: CGFloat = 30
        let minY = spaced.map(\.y).min() ?? anchor.y
        let maxY = spaced.map(\.y).max() ?? anchor.y
        let upperCorrection = max(0, verticalMargin - minY)
        let lowerCorrection = min(0, availableHeight - verticalMargin - maxY)
        let verticalCorrection = upperCorrection > 0 ? upperCorrection : lowerCorrection

        var horizontalCorrection: CGFloat = 0
        if availableWidth.isFinite {
            let horizontalMargin: CGFloat = 76
            let minX = spaced.map(\.x).min() ?? anchor.x
            let maxX = spaced.map(\.x).max() ?? anchor.x
            let leadingCorrection = max(0, horizontalMargin - minX)
            let trailingCorrection = min(0, availableWidth - horizontalMargin - maxX)
            horizontalCorrection = leadingCorrection > 0 ? leadingCorrection : trailingCorrection
        }

        return spaced.map {
            CGPoint(x: $0.x + horizontalCorrection, y: $0.y + verticalCorrection)
        }
    }

    /// Splits the ordered tabs into paired horizontal rows on both sides of the
    /// pointer. Each branch still follows an arc, but the pills themselves stay
    /// level and the hierarchy reads left-to-right instead of as a long column.
    private func bifurcatedPositions(
        count: Int,
        depth: Int,
        anchor: CGPoint,
        availableHeight: CGFloat,
        startsLeft: Bool
    ) -> [CGPoint] {
        // Paired branches do not bunch together at the arc ends, so their
        // second layer can sit materially closer without colliding with the
        // primary and branch pills.
        let radius: CGFloat = depth == 0 ? Self.primaryRadius : 304 + CGFloat(depth - 1) * 72
        let rowCount = Int(ceil(Double(count) / 2.0))
        let curvatureSpacing = depth == 0 ? curvature * 5 : curvature * 3
        let rowSpacing = minimumItemSpacing(depth: depth, sliderRing: false) + curvatureSpacing
        let span = rowSpacing * CGFloat(max(rowCount - 1, 0))
        let top = anchor.y - span * 0.5

        let raw = (0..<count).map { index -> CGPoint in
            let row = index / 2
            let yOffset = top + CGFloat(row) * rowSpacing - anchor.y
            let clampedYOffset = min(max(yOffset, -radius * 0.82), radius * 0.82)
            let xMagnitude = sqrt(max(radius * radius - clampedYOffset * clampedYOffset, 0))
            let usesLeftBranch = index.isMultiple(of: 2) ? startsLeft : !startsLeft
            return CGPoint(
                x: anchor.x + (usesLeftBranch ? -xMagnitude : xMagnitude),
                y: anchor.y + clampedYOffset
            )
        }

        let verticalMargin: CGFloat = 30
        let minY = raw.map(\.y).min() ?? anchor.y
        let maxY = raw.map(\.y).max() ?? anchor.y
        let upperCorrection = max(0, verticalMargin - minY)
        let lowerCorrection = min(0, availableHeight - verticalMargin - maxY)
        let verticalCorrection = upperCorrection > 0 ? upperCorrection : lowerCorrection
        return raw.map { CGPoint(x: $0.x, y: $0.y + verticalCorrection) }
    }

    /// One already-placed pill, for scoring deeper ring placements.
    struct PlacedPill {
        let center: CGPoint
        let halfWidth: CGFloat
        let halfHeight: CGFloat

        init(center: CGPoint, halfWidth: CGFloat, halfHeight: CGFloat) {
            self.center = center
            self.halfWidth = halfWidth
            self.halfHeight = halfHeight
        }
    }

    /// Places a branch ring by scoring candidate fan directions — radially
    /// outward first, then progressively rotated, then flat horizontal — and
    /// returning the first with zero overlap against already-placed pills (or
    /// the least overlapping one when a corner genuinely has no clean spot).
    /// A second radius tier jumps the branch outside the ring envelope for
    /// edge-clamped anchors at high curvature, where no nearby direction has
    /// room — the successor of the old far-branch radius.
    func branchPlacement(
        count: Int,
        depth: Int,
        anchor: CGPoint,
        baseAngle: CGFloat,
        prior: [PlacedPill],
        parentPillIndex: Int,
        halfWidth: CGFloat,
        halfHeight: CGFloat,
        sliderRing: Bool = false,
        availableHeight: CGFloat,
        availableWidth: CGFloat = .infinity
    ) -> (positions: [CGPoint], baseAngle: CGFloat, radius: CGFloat) {
        let horizontal: CGFloat = cos(baseAngle) <= 0 ? .pi : 0
        // Interior-facing (mirrored) candidates make the free side reachable
        // when the outward side is pinned against a window edge.
        let mirrored: CGFloat = .pi - horizontal
        let candidates: [CGFloat] = [
            baseAngle, baseAngle - 0.30, baseAngle + 0.30,
            baseAngle - 0.60, baseAngle + 0.60, horizontal,
            mirrored - 0.30, mirrored, mirrored + 0.30
        ]
        let baseRadius = Self.localBranchRadius + CGFloat(depth - 1) * Self.localBranchRadiusStep

        var bestPositions: [CGPoint] = []
        var bestAngle = baseAngle
        var bestRadius = baseRadius
        var bestPenalty = CGFloat.infinity
        outer: for radiusBoost: CGFloat in [0, 132] {
            for candidate in candidates {
                let candidatePositions = positions(
                    count: count,
                    depth: depth,
                    anchor: anchor,
                    availableHeight: availableHeight,
                    localBranch: true,
                    branchBaseAngle: candidate,
                    radiusBoost: radiusBoost,
                    sliderRing: sliderRing,
                    availableWidth: availableWidth
                )
                var penalty: CGFloat = 0
                // Penalize edge clamping: a wholesale horizontal shift collapses
                // the branch onto its parent column, so a genuinely-fitting
                // direction must always beat a clamped one.
                if availableWidth.isFinite {
                    let unclamped = positions(
                        count: count,
                        depth: depth,
                        anchor: anchor,
                        availableHeight: availableHeight,
                        localBranch: true,
                        branchBaseAngle: candidate,
                        radiusBoost: radiusBoost,
                        sliderRing: sliderRing
                    )
                    if let clampedX = candidatePositions.first?.x, let freeX = unclamped.first?.x {
                        penalty += abs(clampedX - freeX) * 30
                    }
                }
                for (index, pill) in prior.enumerated() {
                    // The parent pill tolerates contact with its own children;
                    // everything else keeps a little breathing room.
                    let margin: CGFloat = index == parentPillIndex ? 0 : 2
                    for point in candidatePositions {
                        let overlapX = pill.halfWidth + halfWidth + margin - abs(pill.center.x - point.x)
                        let overlapY = pill.halfHeight + halfHeight + margin - abs(pill.center.y - point.y)
                        if overlapX > 0, overlapY > 0 { penalty += overlapX * overlapY }
                    }
                }
                if penalty < bestPenalty {
                    bestPenalty = penalty
                    bestPositions = candidatePositions
                    bestAngle = candidate
                    bestRadius = baseRadius + radiusBoost
                    if penalty == 0 { break outer }
                }
            }
        }
        return (bestPositions, bestAngle, bestRadius)
    }
}

/// Pure reconciliation policy for the hover-to-navigate dwell, separated from
/// the menu's task state so the invariant is regression-testable.
///
/// The invariant: an armed dwell is trusted only while the most recent hover
/// *enter* anywhere in the menu is the arming pill itself. Hover exits can be
/// dropped by the system (see `RadialMenu.pendingHoverSelection`), so an enter
/// is the only reliable report of where the pointer actually is — which is why
/// `EnterResponse` deliberately has no "leave it armed" case. A dwell that the
/// entered target does not itself re-arm is stale by definition: the pointer
/// has provably left the arming pill, and letting the dwell fire would tear
/// the ring down under a stationary pointer.
enum RadialHoverDwellPolicy {
    /// Hovering a branch pill this long commits the selection. Long enough
    /// that sweeping across a pill en route to another does not thrash the
    /// deeper rings, short enough to read as instantaneous when aiming at it.
    static let selectDwell: Duration = .milliseconds(120)
    /// Switching a parent after its child ring is visible gets a wider intent
    /// window. This protects diagonal travel toward the child arc without
    /// making first-time branch discovery feel sluggish.
    static let parentSwitchDwell: Duration = .milliseconds(220)
    /// SwiftUI removes very transparent descendants from hit testing. Keep
    /// receded siblings visibly subdued but above that cutoff so hovering a
    /// different root/section can replace the active branch directly.
    static let recededSiblingOpacity = 0.56

    enum EnterResponse: Equatable {
        case arm(dwell: Duration)
        case disarm
    }

    /// Targets that must not navigate — leaves, slider pills, the branch that
    /// is already selected at its depth, and everything while shift-peek
    /// suspends hover navigation — all disarm.
    static func enterResponse(
        nodeID: String,
        isBranch: Bool,
        depth: Int,
        path: [String],
        suspendsHoverNavigation: Bool
    ) -> EnterResponse {
        guard !suspendsHoverNavigation, isBranch,
              depth >= path.count || path[depth] != nodeID else { return .disarm }
        return .arm(dwell: depth < path.count ? parentSwitchDwell : selectDwell)
    }
}

/// Pure path transitions shared by pointer activation and keyboard/chrome
/// retreat. Keeping these transitions independent of focus is important:
/// focus may sit on an ancestor pill while deeper rings are still visible, so
/// deriving "back" from the focused node can accidentally skip multiple rings.
enum RadialNavigationPathPolicy {
    /// Pointer activation toggles an already-expanded branch closed. Activating
    /// any other branch replaces the selection at that depth and drops its stale
    /// descendants.
    static func activatingBranch(
        nodeID: String,
        depth: Int,
        in path: [String]
    ) -> [String] {
        if path.indices.contains(depth), path[depth] == nodeID {
            return Array(path.prefix(depth))
        }
        return Array(path.prefix(depth)) + [nodeID]
    }

    /// Back always removes exactly one visible ring, regardless of which pill
    /// currently owns keyboard focus. Nil means the root ring is already active.
    static func retreating(from path: [String]) -> [String]? {
        guard !path.isEmpty else { return nil }
        return Array(path.dropLast())
    }
}

/// Screen-position anchored radial presentation of the shared application
/// navigation hierarchy. Platform hosts decide how the anchor is invoked and
/// how fallback destinations reveal the standard controls.
struct RadialMenu: View {
    let size: CGSize
    let pointerAnchor: CGPoint
    @Binding var curvature: Double
    let projection: RadialNavigationProjection
    let interactionProfile: RadialInteractionProfile
    let layout: RadialMenuLayout
    /// Interactive progress used by the phone edge reveal. The strip starts
    /// off-screen, follows the finger, then settles at its resting inset.
    var edgeRevealProgress: CGFloat = 1
    let allowsPresentationSelection: Bool
    @Binding var path: [String]
    let sceneAccent: Color
    /// Ordered pins from the app's Quick Access store. This is rendered
    /// outside the path-driven rings so it stays reachable at every depth.
    let quickAccessShortcuts: [RadialQuickAccessShortcut]
    /// True while the user shift-peeks at the fractal: the menu stays mounted
    /// but hover must not re-navigate underneath the faded pills.
    let suspendsHoverNavigation: Bool
    @Binding var hoveredSlider: RadialActiveSlider?
    let onSliderEditingChanged: (Bool) -> Void
    let onSelectPresentation: (NavigationPresentationStyle) -> Void
    let onActivateQuickAccess: (AppRoute) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedItemID: String?
    /// The single dwell timer for hover-to-select. One task, not one per pill:
    /// hover exit events can be dropped by the system, so navigation always
    /// reconciles from the most recent hover *enter* instead of enter/exit
    /// pairs — `RadialHoverDwellPolicy` decides per enter whether that means
    /// re-arming or disarming.
    @State private var pendingHoverSelection: Task<Void, Never>?
    /// Which node scheduled the pending dwell. SwiftUI does not order hover
    /// exit/enter between pills, so only the owning pill's exit may cancel —
    /// a trailing exit from the pill just left must not kill the new dwell.
    @State private var pendingHoverNodeID: String?
    /// The layer currently under the pointer. A receded parent layer returns
    /// to full strength while the user moves back through it.
    @State private var hoveredRingDepth: Int?

    /// Focus identifiers for launcher chrome live outside the hierarchy.
    private enum ChromeFocusID {
        static let back = "launcher.chrome.back"
        static let windowLayout = "launcher.chrome.layout.window"
        static let radialLayout = "launcher.chrome.layout.radial"
        static let panelLayout = "launcher.chrome.layout.panel"
        static let tighterCurvature = "launcher.chrome.curvature.tighter"
        static let widerCurvature = "launcher.chrome.curvature.wider"
    }

    private struct RingLayout {
        let depth: Int
        let nodes: [RadialNavigationNode]
        let positions: [CGPoint]
        /// Center the ring fans around — the pointer anchor for ring 0, the
        /// pointer anchor shared by all concentric rings. Also the pivot radial
        /// sliders measure drag angles against.
        let anchor: CGPoint
        /// Outward direction the ring fans around (radians, screen coords).
        let baseAngle: CGFloat
        /// Arc radius actually used (branch placement may boost it in corners).
        let radius: CGFloat
    }

    private var anchor: CGPoint {
        pointerAnchor
    }

    private var roots: [RadialNavigationNode] {
        projection.roots
    }

    /// The bound path can outlive a projection change or come from the authored
    /// hierarchy, where a singleton category still has an id. Every radial
    /// interaction reads the flattened form so hidden categories never consume
    /// a visible navigation or Back step.
    private var presentedPath: [String] {
        projection.reconciledPath(path)
    }

    private var opensLeft: Bool { anchor.x >= size.width * 0.5 }
    private var bifurcates: Bool {
        // Enough room for the compact slider ring and its 118pt pill.
        let horizontalClearance: CGFloat = 422
        return anchor.x >= horizontalClearance && anchor.x <= size.width - horizontalClearance
    }

    static let windowDragHandleSize: CGFloat = 44
    private static let quickAccessShelfHeight: CGFloat = 64
    private static let straightEdgeMinimumTop: CGFloat = 70
    private static let straightEdgeBottomMargin: CGFloat = 22
    private static let straightEdgeScrollableListTop: CGFloat = 56
    private static let straightEdgeScrollableListBottom: CGFloat = 12
    private let radialSliderWidth: CGFloat = 118

    private var hasQuickAccessShortcuts: Bool { !quickAccessShortcuts.isEmpty }
    /// The bottom dock has an opaque hit surface, so all navigable rings stay
    /// above it rather than allowing their final pills to be covered.
    private var menuContentHeight: CGFloat {
        max(0, size.height - (hasQuickAccessShortcuts ? Self.quickAccessShelfHeight : 0))
    }

    private var straightEdgeScrollableListHeight: CGFloat {
        max(
            0,
            menuContentHeight
                - Self.straightEdgeScrollableListTop
                - Self.straightEdgeScrollableListBottom
        )
    }

    /// A vertical strip needs at least one full touch target between adjacent
    /// centers. If the current phone height cannot provide that above the
    /// persistent dock, switch to a scrollable strip rather than overlapping
    /// or hiding the final controls underneath Quick Access.
    private func straightEdgeNeedsScrolling(itemCount: Int) -> Bool {
        guard itemCount > 1 else { return false }
        let availableSpan = max(
            0,
            menuContentHeight
                - Self.straightEdgeMinimumTop
                - Self.straightEdgeBottomMargin
        )
        let requiredSpan = CGFloat(itemCount - 1) * interactionProfile.minimumTargetSize
        return availableSpan < requiredSpan
    }

    /// Phone controls benefit more from horizontal precision than from the
    /// very narrow radial pill. Keep the iPad/Mac ring width unchanged.
    private var activeSliderWidth: CGFloat {
        guard layout == .straightEdge else { return radialSliderWidth }
        return min(184, max(156, size.width * 0.44))
    }

    private var straightEdgeCenterX: CGFloat {
        let inset = activeSliderWidth * 0.5 + 12
        let resting = opensLeft ? size.width - inset : inset
        let hidden = opensLeft
            ? size.width + activeSliderWidth * 0.5 + 8
            : -activeSliderWidth * 0.5 - 8
        let progress = min(max(edgeRevealProgress, 0), 1)
        return hidden + (resting - hidden) * progress
    }

    static func windowDragHandleFrame(
        size: CGSize,
        pointerAnchor: CGPoint
    ) -> CGRect {
        let center = pointerAnchor
        return CGRect(
            x: center.x - windowDragHandleSize * 0.5,
            y: center.y - windowDragHandleSize * 0.5,
            width: windowDragHandleSize,
            height: windowDragHandleSize
        )
    }

    var body: some View {
        let rings = ringLayouts()
        let focusOrder = keyboardFocusOrder(rings: rings)

        ZStack {
            Color.clear
                .contentShape(Rectangle())

            if layout == .straightEdge {
                straightEdgeScrim
                straightEdgeChrome(ring: rings.last)
            } else {
                radialGuide(rings: rings)
                    .allowsHitTesting(false)
            }

            ForEach(rings, id: \.depth) { ring in
                ringView(ring)
            }

            if allowsPresentationSelection {
                layoutPicker(primaryPositions: rings.first?.positions ?? [])
            }

            if layout == .radial {
                anchorMark
            }

            if hasQuickAccessShortcuts {
                quickAccessShelf
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(3)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .overlay(alignment: opensLeft ? .trailing : .leading) {
            // A narrow, transparent edge handle reserves the reverse of the
            // opening gesture for dismissal without stealing taps or drags
            // from any control pill.
            if layout == .straightEdge {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: PhoneEdgeMenuGesturePolicy.dismissalDistance)
                            .onEnded { value in
                                guard PhoneEdgeMenuGesturePolicy.shouldDismiss(
                                    opensLeft: opensLeft,
                                    horizontalTranslation: value.translation.width
                                ) else { return }
                                onDismiss()
                            }
                    )
                    .accessibilityLabel("Swipe toward the screen edge to close controls")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onDismiss() }
            }
        }
        .onAppear {
            // Initial paths may open directly onto the active route. Put
            // hardware-keyboard focus in the deepest visible ring as well, so
            // keyboard users receive the same zero-traversal quick-control
            // entry point as touch users.
            let deepestVisibleNodes = rings.last?.nodes ?? roots
            focusedItemID = deepestVisibleNodes.first(where: \.isSelected)?.id
                ?? deepestVisibleNodes.first?.id
                ?? roots.first?.id
        }
        .onDisappear {
            disarmPendingHover()
        }
        .onChange(of: suspendsHoverNavigation) { _, suspended in
            // Shift-peek must not let an already-armed dwell re-navigate
            // under the faded pills.
            if suspended {
                disarmPendingHover()
            }
        }
        .onKeyPress(.tab, phases: [.down, .repeat]) { press in
            moveFocus(through: focusOrder, backward: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(
            keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
            phases: [.down, .repeat]
        ) { press in
            handleDirectionalKey(press, focusOrder: focusOrder)
        }
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            activateFocusedItem()
        }
        .onKeyPress(.escape, phases: .down) { _ in
            retreatOrDismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Control launcher")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
    }

    static let coordinateSpaceName = "RadialMenu"

    // MARK: Ring layout

    /// Walks the flattened path through the current radial projection, using
    /// concentric arcs for every visible hierarchy level.
    private func ringLayouts() -> [RingLayout] {
        if layout == .straightEdge {
            return straightEdgeRingLayouts()
        }

        let presentedPath = self.presentedPath
        var layouts: [RingLayout] = []
        var nodes = roots
        var ringBaseAngle: CGFloat = opensLeft ? .pi : 0
        var radialRingRadius = RadialMenuGeometry.primaryRadius
        var depth = 0

        while !nodes.isEmpty {
            let positions: [CGPoint]
            let isControlRing = nodes.contains { $0.slider != nil || $0.toggle != nil }
            let ringRadius: CGFloat
            let layoutCenter: CGPoint
            var resolvedBaseAngle = ringBaseAngle

            layoutCenter = anchor
            ringRadius = radialRingRadius
            if depth == 0 {
                positions = itemPositions(
                    count: nodes.count,
                    depth: depth,
                    centeredAt: anchor,
                    baseAngle: ringBaseAngle,
                    sliderRing: false
                )
            } else {
                let resolved = fittedConcentricPositions(
                    count: nodes.count,
                    radius: ringRadius,
                    baseAngle: ringBaseAngle,
                    sliderRing: isControlRing,
                    priorLayouts: layouts
                )
                positions = resolved.positions
                resolvedBaseAngle = resolved.baseAngle
            }
            layouts.append(RingLayout(
                depth: depth,
                nodes: nodes,
                positions: positions,
                anchor: layoutCenter,
                baseAngle: resolvedBaseAngle,
                radius: ringRadius
            ))

            guard depth < presentedPath.count,
                  let selectedIndex = nodes.firstIndex(where: { $0.id == presentedPath[depth] }),
                  nodes[selectedIndex].isBranch,
                  positions.indices.contains(selectedIndex) else { break }

            let pill = positions[selectedIndex]
            // Deeper concentric rings stay in the selected pill's angular
            // sector while retaining the shared pointer center.
            let dx = pill.x - anchor.x
            let dy = pill.y - anchor.y
            if dx*dx + dy*dy > 1 {
                // Follow the selected sector, but damp its vertical offset at
                // each hop so an upper primary does not pull the whole arc high.
                ringBaseAngle = atan2(dy * 0.62, dx)
            }
            radialRingRadius = hypot(dx, dy) + RadialMenuGeometry.concentricRingStep
            nodes = projection.presentedChildren(of: nodes[selectedIndex])
            depth += 1
        }
        return layouts
    }

    /// Presents only the active hierarchy level in a vertical strip beside
    /// the edge where the user invoked the launcher. Hiding ancestor rings is
    /// the key space saving on iPhone; the explicit Back control preserves the
    /// complete hierarchy without covering the artwork with multiple columns.
    private func straightEdgeRingLayouts() -> [RingLayout] {
        let presentedPath = self.presentedPath
        var nodes = roots
        var depth = 0

        while depth < presentedPath.count,
              let selected = nodes.first(where: { $0.id == presentedPath[depth] }),
              selected.isBranch {
            nodes = projection.presentedChildren(of: selected)
            depth += 1
        }

        guard !nodes.isEmpty else { return [] }

        // Reserve a compact header row above the list. Never tighten below a
        // full touch target; rings that cannot meet that requirement use the
        // scrollable straight-edge strip instead of overlapping controls.
        let minimumTop = Self.straightEdgeMinimumTop
        let bottomMargin = Self.straightEdgeBottomMargin
        let availableSpan = max(0, menuContentHeight - minimumTop - bottomMargin)
        let fittedSpacing = nodes.count > 1
            ? availableSpan / CGFloat(nodes.count - 1)
            : interactionProfile.itemSpacing
        let spacing = min(
            interactionProfile.itemSpacing,
            max(interactionProfile.minimumTargetSize, fittedSpacing)
        )
        let span = spacing * CGFloat(max(nodes.count - 1, 0))
        let desiredTop = anchor.y - span * 0.5
        let maximumTop = max(minimumTop, menuContentHeight - bottomMargin - span)
        let top = min(max(desiredTop, minimumTop), maximumTop)
        let positions = nodes.indices.map { index in
            CGPoint(x: straightEdgeCenterX, y: top + CGFloat(index) * spacing)
        }

        return [RingLayout(
            depth: depth,
            nodes: nodes,
            positions: positions,
            anchor: CGPoint(x: opensLeft ? size.width : 0, y: anchor.y),
            baseAngle: opensLeft ? .pi : 0,
            radius: 0
        )]
    }

    private var straightEdgeScrim: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.76), Color.black.opacity(0.34), Color.clear],
            startPoint: opensLeft ? .trailing : .leading,
            endPoint: opensLeft ? .leading : .trailing
        )
        .frame(width: activeSliderWidth + 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: opensLeft ? .trailing : .leading)
        .opacity(min(max(edgeRevealProgress, 0), 1))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func straightEdgeChrome(ring: RingLayout?) -> some View {
        if let ring {
            let top = straightEdgeNeedsScrolling(itemCount: ring.nodes.count)
                ? Self.straightEdgeScrollableListTop
                    + interactionProfile.minimumTargetSize * 0.5
                    + 2
                : ring.positions.first?.y ?? Self.straightEdgeMinimumTop
            HStack(spacing: 8) {
                if !presentedPath.isEmpty {
                    Button(action: retreatOneLevel) {
                        Image(systemName: "chevron.backward")
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityLabel("Back")
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("Close controls")
            }
            .font(.system(size: 13, weight: .bold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.92))
            .background(Color.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .position(
                x: straightEdgeCenterX,
                y: max(24, top - 46)
            )
        }
    }

    /// Rotates a concentric child arc just enough to remain on-screen and clear
    /// already-visible pills. Radius and center never change, so the hierarchy
    /// retains its concentric character instead of jumping to an unrelated fan.
    private func fittedConcentricPositions(
        count: Int,
        radius: CGFloat,
        baseAngle: CGFloat,
        sliderRing: Bool,
        priorLayouts: [RingLayout]
    ) -> (positions: [CGPoint], baseAngle: CGFloat) {
        let presentedPath = self.presentedPath
        let geometry = RadialMenuGeometry(
            curvature: CGFloat(curvature),
            interactionProfile: interactionProfile
        )
        let offsets: [CGFloat] = [0, 0.10, -0.10, 0.20, -0.20, 0.32, -0.32]
        let restingHalfWidth: CGFloat = sliderRing ? radialSliderWidth * 0.5 : 52
        let restingHalfHeight = max(
            interactionProfile.minimumTargetSize * 0.5,
            sliderRing ? 17 : 16
        )
        // Scoring protects the focused/engaged size, not merely the resting
        // capsule. A pill can therefore grow toward the touch without being
        // clipped at the edge of an iPad window.
        let halfWidth = RadialFocusMagnification.protectedHalfExtent(
            restingHalfWidth,
            for: interactionProfile
        )
        let halfHeight = RadialFocusMagnification.protectedHalfExtent(
            restingHalfHeight,
            for: interactionProfile
        )
        let margin: CGFloat = 12

        func score(_ points: [CGPoint], offset: CGFloat) -> CGFloat {
            var total = abs(offset) * 18
            for point in points {
                let frame = CGRect(
                    x: point.x - halfWidth,
                    y: point.y - halfHeight,
                    width: halfWidth * 2,
                    height: halfHeight * 2
                )
                if frame.minX < margin { total += (margin - frame.minX) * 80 }
                if frame.maxX > size.width - margin { total += (frame.maxX - size.width + margin) * 80 }
                if frame.minY < margin { total += (margin - frame.minY) * 80 }
                if frame.maxY > menuContentHeight - margin {
                    total += (frame.maxY - menuContentHeight + margin) * 80
                }

                for prior in priorLayouts {
                    for (priorIndex, priorPoint) in prior.positions.enumerated() {
                        let isSelectedParent = prior.depth == priorLayouts.last?.depth
                            && presentedPath.indices.contains(prior.depth)
                            && prior.nodes.indices.contains(priorIndex)
                            && prior.nodes[priorIndex].id == presentedPath[prior.depth]
                        if isSelectedParent { continue }
                        let priorRestingHalfWidth: CGFloat = prior.depth == 0 ? 72 : 52
                        let priorRestingHalfHeight = max(
                            interactionProfile.minimumTargetSize * 0.5,
                            prior.depth == 0 ? 20 : 16
                        )
                        let priorHalfWidth = RadialFocusMagnification.protectedHalfExtent(
                            priorRestingHalfWidth,
                            for: interactionProfile
                        )
                        let priorHalfHeight = RadialFocusMagnification.protectedHalfExtent(
                            priorRestingHalfHeight,
                            for: interactionProfile
                        )
                        let priorFrame = CGRect(
                            x: priorPoint.x - priorHalfWidth - 4,
                            y: priorPoint.y - priorHalfHeight - 3,
                            width: (priorHalfWidth + 4) * 2,
                            height: (priorHalfHeight + 3) * 2
                        )
                        if frame.intersects(priorFrame) {
                            let overlap = frame.intersection(priorFrame)
                            total += overlap.width * overlap.height
                        }
                    }
                }
            }
            return total
        }

        return offsets
            .map { offset -> (positions: [CGPoint], baseAngle: CGFloat, score: CGFloat) in
                let angle = baseAngle + offset
                let points = fitAboveQuickAccessShelf(
                    geometry.concentricPositions(
                        count: count,
                        anchor: anchor,
                        radius: radius,
                        baseAngle: angle,
                        sliderRing: sliderRing
                    )
                )
                return (points, angle, score(points, offset: offset))
            }
            .min(by: { $0.score < $1.score })
            .map { ($0.positions, $0.baseAngle) }
            ?? ([], baseAngle)
    }

    /// Applies the same bottom reservation to concentric child rings that the
    /// primary-ring geometry receives through `availableHeight`. Translating a
    /// complete ring keeps its angular relationship intact while ensuring the
    /// Quick Access shelf never covers a live control.
    private func fitAboveQuickAccessShelf(_ positions: [CGPoint]) -> [CGPoint] {
        guard hasQuickAccessShortcuts, !positions.isEmpty else { return positions }

        let margin: CGFloat = 30
        let top = positions.map(\.y).min() ?? 0
        let bottom = positions.map(\.y).max() ?? 0
        let upperCorrection = max(0, margin - top)
        let lowerCorrection = min(0, menuContentHeight - margin - bottom)
        let correction = upperCorrection > 0 ? upperCorrection : lowerCorrection

        return positions.map { CGPoint(x: $0.x, y: $0.y + correction) }
    }

    @ViewBuilder
    private func ringView(_ ring: RingLayout) -> some View {
        if layout == .straightEdge, straightEdgeNeedsScrolling(itemCount: ring.nodes.count) {
            straightEdgeScrollableRingView(ring)
        } else {
            ForEach(Array(ring.nodes.enumerated()), id: \.element.id) { index, node in
                let position = ring.positions[index]
                let transitionDirection: CGFloat = position.x < anchor.x ? 1 : -1

                ringItemView(node, in: ring, at: position)
                    .position(position)
                    .transition(
                        .offset(x: transitionDirection * (ring.depth == 0 ? 48 : 62))
                            .combined(with: .scale(scale: 0.82, anchor: .trailing))
                            .combined(with: .opacity)
                    )
            }
        }
    }

    /// A short landscape phone cannot always fit the full touch-target stack
    /// above the persistent dock. Keep the same pills, but let their vertical
    /// strip scroll within the space reserved for normal straight-edge content.
    @ViewBuilder
    private func straightEdgeScrollableRingView(_ ring: RingLayout) -> some View {
        let listHeight = straightEdgeScrollableListHeight
        if listHeight > 0 {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(ring.nodes.enumerated()), id: \.element.id) { index, node in
                            ringItemView(node, in: ring, at: ring.positions[index])
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: interactionProfile.minimumTargetSize)
                                .id(node.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: activeSliderWidth + 16, height: listHeight)
                .position(
                    x: straightEdgeCenterX,
                    y: Self.straightEdgeScrollableListTop + listHeight * 0.5
                )
                .onAppear {
                    // The parent establishes initial keyboard focus after the
                    // menu mounts. Yield once so an already-focused lower item
                    // is visible in this shortened phone layout.
                    Task { @MainActor in
                        await Task.yield()
                        guard let focusedItemID,
                              ring.nodes.contains(where: { $0.id == focusedItemID }) else { return }
                        proxy.scrollTo(focusedItemID, anchor: .center)
                    }
                }
                .onChange(of: focusedItemID) { _, focusedID in
                    guard let focusedID,
                          ring.nodes.contains(where: { $0.id == focusedID }) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        proxy.scrollTo(focusedID, anchor: .center)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func ringItemView(
        _ node: RadialNavigationNode,
        in ring: RingLayout,
        at position: CGPoint
    ) -> some View {
        let selectedPathID = presentedPath.indices.contains(ring.depth)
            ? presentedPath[ring.depth]
            : nil
        let isSelectedPathNode = selectedPathID == node.id
        let recedesBehindChildRing = selectedPathID != nil
            && !isSelectedPathNode
            && hoveredRingDepth != ring.depth

        Group {
            if let slider = node.slider {
                let width = activeSliderWidth
                // Inflated hit frame for platform pointer/indirect-input
                // adapters, extending past the pill's hover scale.
                let hitFrame = CGRect(
                    x: position.x - width * 0.5 - 8,
                    y: position.y - interactionProfile.minimumTargetSize * 0.5 - 8,
                    width: width + 16,
                    height: interactionProfile.minimumTargetSize + 16
                )
                RadialSliderPill(
                    node: node,
                    slider: slider,
                    fixedWidth: width,
                    isFocused: focusedItemID == node.id,
                    sceneAccent: sceneAccent,
                    interactionProfile: interactionProfile,
                    allowsVerticalScroll: layout == .straightEdge
                        && straightEdgeNeedsScrolling(itemCount: ring.nodes.count),
                    onHoverChanged: { hovering in
                        updateHoveredRing(ring.depth, hovering: hovering)
                        // Slider pills never arm the dwell, but their enters
                        // must still disarm a stale one. The pill reports raw
                        // hover so even a disabled pill reconciles; availability
                        // gates only the scroll target below.
                        handleNodeHover(node, depth: ring.depth, hovering: hovering)
                        if hovering, slider.isEnabled() {
                            hoveredSlider = RadialActiveSlider(id: node.id, frame: hitFrame)
                        } else if hoveredSlider?.id == node.id {
                            hoveredSlider = nil
                        }
                    },
                    onEditingChanged: onSliderEditingChanged
                )
                .focusable()
                .focused($focusedItemID, equals: node.id)
            } else if let toggle = node.toggle {
                RadialTogglePill(
                    node: node,
                    toggle: toggle,
                    fixedWidth: activeSliderWidth,
                    isFocused: focusedItemID == node.id,
                    sceneAccent: sceneAccent,
                    interactionProfile: interactionProfile,
                    onHoverChanged: { hovering in
                        updateHoveredRing(ring.depth, hovering: hovering)
                        handleNodeHover(node, depth: ring.depth, hovering: hovering)
                    }
                )
                .focusable()
                .focused($focusedItemID, equals: node.id)
            } else {
                RadialMenuButton(
                    item: node,
                    depth: ring.depth,
                    fixedWidth: nil,
                    isFocused: focusedItemID == node.id,
                    isExpanded: isSelectedPathNode,
                    retreatDirection: position.x < anchor.x ? -1 : 1,
                    sceneAccent: sceneAccent,
                    interactionProfile: interactionProfile,
                    onActivate: {
                        // Click (or keyboard activation) on a pure branch
                        // navigates immediately — hover-only switching would
                        // strand click-first users. Clicking the expanded parent
                        // collapses exactly that level as a local Back action.
                        if node.isBranch {
                            activateBranch(node, depth: ring.depth)
                        } else {
                            node.fallbackAction?()
                        }
                    },
                    onOpenFullControls: node.fullControlsAction,
                    onHoverChanged: { hovering in
                        updateHoveredRing(ring.depth, hovering: hovering)
                        handleNodeHover(node, depth: ring.depth, hovering: hovering)
                    }
                )
                .focused($focusedItemID, equals: node.id)
            }
        }
        // Once this layer opens a child arc, fade its siblings back while
        // keeping the chosen parent fully lit. The resulting bright chain
        // makes the active route through a deep hierarchy immediately clear.
        .opacity(
            recedesBehindChildRing
                ? RadialHoverDwellPolicy.recededSiblingOpacity
                : 1
        )
        .saturation(recedesBehindChildRing ? 0.42 : 1)
        .scaleEffect(recedesBehindChildRing ? 0.97 : 1)
        .animation(.easeOut(duration: 0.16), value: recedesBehindChildRing)
    }

    // MARK: Hover navigation

    private func updateHoveredRing(_ depth: Int, hovering: Bool) {
        if hovering {
            hoveredRingDepth = depth
        } else if hoveredRingDepth == depth {
            hoveredRingDepth = nil
        }
    }

    /// Hover enter on a branch pill schedules the selection after a dwell;
    /// every other enter disarms a stale one (`RadialHoverDwellPolicy`).
    /// Leaves never re-navigate on hover — only their own click acts — so a
    /// deeper ring stays open while the pointer visits a sibling leaf.
    private func handleNodeHover(_ node: RadialNavigationNode, depth: Int, hovering: Bool) {
        guard interactionProfile.supportsHoverNavigation else { return }
        guard hovering else {
            // Only the owning pill's exit cancels: SwiftUI does not order
            // hover exit/enter between pills, so a trailing exit from the
            // pill just left must not kill the dwell its successor armed.
            if pendingHoverNodeID == node.id {
                disarmPendingHover()
            }
            return
        }

        switch RadialHoverDwellPolicy.enterResponse(
            nodeID: node.id,
            isBranch: node.isBranch,
            depth: depth,
            path: presentedPath,
            suspendsHoverNavigation: suspendsHoverNavigation
        ) {
        case .disarm:
            disarmPendingHover()
        case .arm(let dwell):
            pendingHoverSelection?.cancel()
            pendingHoverNodeID = node.id
            pendingHoverSelection = Task { @MainActor in
                try? await Task.sleep(for: dwell)
                guard !Task.isCancelled else { return }
                pendingHoverNodeID = nil
                commitHoverSelection(node, depth: depth)
            }
        }
    }

    /// The single dwell teardown. Every hover enter that does not itself
    /// re-arm routes here (see `RadialHoverDwellPolicy`), as do the owning
    /// pill's exit and the lifecycle resets (dismiss, shift-peek, commit) —
    /// so a stale dwell can only outlive a dropped exit while the pointer
    /// produces no enter at all.
    private func disarmPendingHover() {
        pendingHoverSelection?.cancel()
        pendingHoverSelection = nil
        pendingHoverNodeID = nil
    }

    private func commitHoverSelection(_ node: RadialNavigationNode, depth: Int) {
        disarmPendingHover()
        let newPath = Array(presentedPath.prefix(depth)) + [node.id]
        setNavigationPath(newPath)
    }

    private func activateBranch(_ node: RadialNavigationNode, depth: Int) {
        disarmPendingHover()
        let newPath = RadialNavigationPathPolicy.activatingBranch(
            nodeID: node.id,
            depth: depth,
            in: presentedPath
        )
        focusedItemID = node.id
        setNavigationPath(newPath)
    }

    private func setNavigationPath(_ newPath: [String]) {
        let newPath = projection.reconciledPath(newPath)
        guard path != newPath else { return }
        if reduceMotion {
            path = newPath
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                path = newPath
            }
        }
    }

    private func itemPositions(
        count: Int,
        depth: Int,
        centeredAt layoutAnchor: CGPoint,
        baseAngle: CGFloat,
        radiusBoost: CGFloat = 0,
        sliderRing: Bool = false
    ) -> [CGPoint] {
        // The primary ring is exempt from the width clamp: shifting it would
        // divorce the fan from the anchor mark, guide arc, and picker. Only
        // deep branches near a side edge need rescuing.
        return RadialMenuGeometry(
            curvature: CGFloat(curvature),
            interactionProfile: interactionProfile
        ).positions(
            count: count,
            depth: depth,
            anchor: layoutAnchor,
            availableHeight: menuContentHeight,
            opensLeft: opensLeft,
            bifurcates: depth == 0 ? bifurcates : false,
            localBranch: depth > 0,
            branchBaseAngle: depth > 0 ? baseAngle : nil,
            radiusBoost: radiusBoost,
            sliderRing: sliderRing,
            availableWidth: depth == 0 ? .infinity : size.width
        )
    }

    private func layoutPicker(primaryPositions: [CGPoint]) -> some View {
        HStack(spacing: 3) {
            if !presentedPath.isEmpty {
                let isKeyboardFocused = focusedItemID == ChromeFocusID.back
                Button {
                    retreatOneLevel()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 22)
                        .foregroundStyle(isKeyboardFocused ? Color.white : Color.white.opacity(0.78))
                        .background(
                            isKeyboardFocused ? sceneAccent.opacity(0.34) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .focused($focusedItemID, equals: ChromeFocusID.back)
                .help("Back one radial menu level")
                .accessibilityLabel("Back")

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 1)
            }

            ForEach(NavigationPresentationStyle.allCases, id: \.self) { style in
                let focusID = layoutFocusID(for: style)
                let isKeyboardFocused = focusedItemID == focusID
                Button {
                    onSelectPresentation(style)
                } label: {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .foregroundStyle(style == .radial ? Color.white : Color.white.opacity(0.52))
                        .background(
                            style == .radial || isKeyboardFocused
                                ? Color(red: 0.58, green: 0.13, blue: 0.84).opacity(0.88)
                                : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isKeyboardFocused ? sceneAccent.opacity(0.92) : Color.clear,
                                    lineWidth: 1.2
                                )
                        )
                }
                .buttonStyle(.plain)
                .focused($focusedItemID, equals: focusID)
                .help(style.displayName)
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 1)

            curvatureButton(
                systemImage: "minus",
                delta: -0.08,
                focusID: ChromeFocusID.tighterCurvature
            )
            curvatureButton(
                systemImage: "plus",
                delta: 0.08,
                focusID: ChromeFocusID.widerCurvature
            )
        }
        .padding(3)
        .background(Color(red: 0.055, green: 0.012, blue: 0.09).opacity(0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        .onHover { hovering in
            // Chrome takes no part in hover navigation, but it sits within
            // dwell-travel range of the primary ring, so entering it must
            // still disarm a stale dwell (see RadialHoverDwellPolicy).
            if hovering { disarmPendingHover() }
        }
        .position(layoutPickerPosition(primaryPositions: primaryPositions))
        .accessibilityLabel("Quick menu layout")
    }

    private func layoutPickerPosition(primaryPositions: [CGPoint]) -> CGPoint {
        let top = primaryPositions.map(\.y).min() ?? anchor.y
        let bottom = primaryPositions.map(\.y).max() ?? anchor.y
        let desiredY = top - 32
        let resolvedY = desiredY >= 24 ? desiredY : min(bottom + 32, size.height - 24)
        return CGPoint(
            x: bifurcates ? anchor.x : anchor.x + (opensLeft ? -70 : 70),
            y: resolvedY
        )
    }

    private func curvatureButton(systemImage: String, delta: Double, focusID: String) -> some View {
        let isKeyboardFocused = focusedItemID == focusID
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                curvature = min(max(curvature + delta, 0.35), 1.35)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 19, height: 22)
                .foregroundStyle(isKeyboardFocused ? Color.white : Color.white.opacity(0.72))
                .background(
                    isKeyboardFocused ? sceneAccent.opacity(0.34) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .focused($focusedItemID, equals: focusID)
        .help(delta < 0 ? "Tighten radial curvature" : "Open radial curvature")
    }

    /// A scrollable dock makes every pin reachable without adding an arbitrary
    /// cap or expanding the hierarchy's root ring. It lives outside the
    /// path-driven layout, so both concentric and straight-edge presentations
    /// retain it while the user drills into controls.
    private var quickAccessShelf: some View {
        HStack(spacing: 8) {
            Label("Quick Access", systemImage: AppIcons.pinFill)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 22)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickAccessShortcuts) { shortcut in
                            quickAccessButton(shortcut)
                                .id(shortcut.id)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onAppear {
                    // Keyboard traversal can enter the unbounded dock at any
                    // pin. Yield once so the scroll view has laid out its IDs
                    // before revealing the focused shortcut.
                    Task { @MainActor in
                        await Task.yield()
                        guard let focusedItemID,
                              quickAccessShortcuts.contains(where: { $0.id == focusedItemID }) else { return }
                        proxy.scrollTo(focusedItemID, anchor: .center)
                    }
                }
                .onChange(of: focusedItemID) { _, focusedID in
                    guard let focusedID,
                          quickAccessShortcuts.contains(where: { $0.id == focusedID }) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        proxy.scrollTo(focusedID, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(4)
        .frame(height: 56)
        .background(Color(red: 0.045, green: 0.010, blue: 0.075).opacity(0.97), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [sceneAccent.opacity(0.42), Color.white.opacity(0.16)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 0.9
                )
        )
        .shadow(color: Color.black.opacity(0.34), radius: 10, y: 3)
        .onHover { hovering in
            // A dock sits above older rings; entering it must cancel any
            // branch dwell that was armed before the pointer reached it.
            if hovering { disarmPendingHover() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Access shortcuts")
    }

    private func quickAccessButton(_ shortcut: RadialQuickAccessShortcut) -> some View {
        let isFocused = focusedItemID == shortcut.id
        let isEmphasized = shortcut.isSelected || isFocused
        let textWeight: Font.Weight = isEmphasized ? .bold : .semibold
        let foreground = isEmphasized ? Color.white : Color.white.opacity(0.76)
        let fill = isEmphasized ? sceneAccent.opacity(0.36) : Color.white.opacity(0.08)
        let stroke = isFocused ? sceneAccent.opacity(0.92) : Color.white.opacity(0.11)
        let strokeWidth: CGFloat = isFocused ? 1.2 : 0.7

        return Button {
            activateQuickAccessShortcut(shortcut)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: shortcut.systemImage)
                Text(shortcut.title)
            }
                .font(.caption2.weight(textWeight))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .frame(minHeight: interactionProfile.minimumTargetSize)
                .foregroundStyle(foreground)
                .background(fill, in: Capsule())
                .overlay(Capsule().strokeBorder(stroke, lineWidth: strokeWidth))
        }
        .buttonStyle(.plain)
        .focused($focusedItemID, equals: shortcut.id)
        .help("Open \(shortcut.title) controls")
        .accessibilityLabel(shortcut.title)
        .accessibilityHint("Opens this pinned section's controls.")
        .accessibilityAddTraits(shortcut.isSelected ? .isSelected : [])
    }

    private func activateQuickAccessShortcut(_ shortcut: RadialQuickAccessShortcut) {
        disarmPendingHover()
        onActivateQuickAccess(shortcut.route)
    }

    private func radialGuide(rings: [RingLayout]) -> some View {
        let presentedPath = self.presentedPath
        return Canvas { context, _ in
            for ring in rings {
                let radius: CGFloat
                let baseAngles: [CGFloat]
                let halfSweep: CGFloat
                let opacity: Double
                if ring.depth == 0 {
                    radius = ring.radius
                    baseAngles = bifurcates ? [.pi, 0] : [ring.baseAngle]
                    halfSweep = .pi * 0.3
                    opacity = 0.34
                } else {
                    radius = ring.radius
                    baseAngles = [ring.baseAngle]
                    halfSweep = RadialMenuGeometry.localBranchMaxSpread * 0.5 + 0.16
                    opacity = ring.depth == 1 ? 0.20 : 0.15
                }

                for baseAngle in baseAngles {
                    var path = Path()
                    path.addArc(
                        center: ring.anchor,
                        radius: radius,
                        startAngle: .radians(baseAngle - halfSweep),
                        endAngle: .radians(baseAngle + halfSweep),
                        clockwise: false
                    )
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.20, green: 0.04, blue: 0.34).opacity(0.10),
                                Color(red: 0.78, green: 0.26, blue: 1.00).opacity(opacity)
                            ]),
                            startPoint: CGPoint(
                                x: ring.anchor.x + cos(baseAngle) * radius,
                                y: ring.anchor.y + sin(baseAngle) * radius
                            ),
                            endPoint: ring.anchor
                        ),
                        style: StrokeStyle(lineWidth: ring.depth == 0 ? 1.2 : 0.8, dash: [2, 7])
                    )
                }
            }

            // A single luminous route makes the selected ancestry legible at
            // a glance. It is static Canvas geometry—no blur and no timeline.
            let selectedPoints = rings.compactMap { ring -> CGPoint? in
                guard presentedPath.indices.contains(ring.depth),
                      let index = ring.nodes.firstIndex(where: {
                          $0.id == presentedPath[ring.depth]
                      }),
                      ring.positions.indices.contains(index) else { return nil }
                return ring.positions[index]
            }
            if !selectedPoints.isEmpty {
                var route = Path()
                route.move(to: anchor)
                for point in selectedPoints {
                    route.addLine(to: point)
                }
                context.stroke(
                    route,
                    with: .linearGradient(
                        Gradient(colors: [
                            sceneAccent.opacity(0.16),
                            sceneAccent.opacity(0.78),
                            Color.white.opacity(0.72)
                        ]),
                        startPoint: anchor,
                        endPoint: selectedPoints.last ?? anchor
                    ),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    @ViewBuilder
    private var anchorMark: some View {
        #if os(macOS)
        anchorMarkContent
            .position(anchor)
            .gesture(WindowDragGesture())
            .help("Drag to move the window")
            .accessibilityElement()
            .accessibilityLabel("Window drag handle")
            .accessibilityHint("Drag to move the Threshold window")
        #else
        Button(action: onDismiss) {
            anchorMarkContent
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
        }
        .buttonStyle(.plain)
        .position(anchor)
        .accessibilityLabel("Close radial controls")
        .accessibilityHint("Dismisses the radial control menu")
        #endif
    }

    private var anchorMarkContent: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.54, green: 0.12, blue: 0.82).opacity(0.22))
                .frame(width: 34, height: 34)
            Circle()
                .fill(Color(red: 0.92, green: 0.62, blue: 1.00))
                .frame(width: 6, height: 6)
                .shadow(color: Color.purple.opacity(0.9), radius: 7)
        }
        .frame(width: Self.windowDragHandleSize, height: Self.windowDragHandleSize)
        .contentShape(Circle())
        .onHover { hovering in
            // The hub is a natural pointer rest at the shared ring center;
            // entering it must disarm a stale dwell (see RadialHoverDwellPolicy).
            if hovering { disarmPendingHover() }
        }
    }

    // MARK: Keyboard navigation

    /// Keyboard traversal follows the visible radial ring order.
    private func keyboardFocusOrder(rings: [RingLayout]) -> [NavigationHierarchy.KeyboardTarget] {
        let flattened = projection.flattenedKeyboardTargets()
        // Node ids originate in persisted scene data (transform ops keep
        // their imported UUIDs), so uniqueness is not guaranteed here. The
        // projection collapses duplicate siblings; keeping the first target
        // covers any remaining collision instead of trapping on every body
        // evaluation while such a scene is loaded.
        let targetsByID = Dictionary(flattened.map { ($0.id, $0) }) { first, _ in first }
        let nodeTargets = rings.flatMap(\.nodes).compactMap { targetsByID[$0.id] }
        let quickAccessTargets = quickAccessShortcuts.map {
            NavigationHierarchy.KeyboardTarget(id: $0.id, ancestorPath: [])
        }

        let chromeTargets = chromeFocusIDs.map {
            NavigationHierarchy.KeyboardTarget(id: $0, ancestorPath: [])
        }
        return nodeTargets + quickAccessTargets + chromeTargets
    }

    private var chromeFocusIDs: [String] {
        (presentedPath.isEmpty ? [] : [ChromeFocusID.back]) + [
            ChromeFocusID.windowLayout,
            ChromeFocusID.radialLayout,
            ChromeFocusID.panelLayout,
            ChromeFocusID.tighterCurvature,
            ChromeFocusID.widerCurvature
        ]
    }

    private func layoutFocusID(for style: NavigationPresentationStyle) -> String {
        switch style {
        case .separateWindow: ChromeFocusID.windowLayout
        case .radial: ChromeFocusID.radialLayout
        case .controlPanel: ChromeFocusID.panelLayout
        }
    }

    private func moveFocus(through targets: [NavigationHierarchy.KeyboardTarget], backward: Bool) {
        guard let nextID = NavigationKeyboardTraversal.nextID(
            from: focusedItemID,
            in: targets,
            backward: backward
        ) else { return }
        focusKeyboardTarget(nextID)
    }

    private func focusKeyboardTarget(_ id: String) {
        focusedItemID = id
    }

    private func handleDirectionalKey(
        _ press: KeyPress,
        focusOrder: [NavigationHierarchy.KeyboardTarget]
    ) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            moveFocus(through: focusOrder, backward: true)
            return .handled
        case .downArrow:
            moveFocus(through: focusOrder, backward: false)
            return .handled
        case .leftArrow:
            if focusedQuickAccessShortcut != nil {
                moveFocus(through: focusOrder, backward: true)
            } else if let slider = focusedNode?.slider {
                slider.step(by: -1)
            } else if let toggle = focusedNode?.toggle {
                toggle.set(false)
            } else {
                retreatOrDismiss()
            }
            return .handled
        case .rightArrow:
            if focusedQuickAccessShortcut != nil {
                moveFocus(through: focusOrder, backward: false)
                return .handled
            }
            if let slider = focusedNode?.slider {
                slider.step(by: 1)
                return .handled
            }
            if let toggle = focusedNode?.toggle {
                toggle.set(true)
                return .handled
            }
            return expandFocusedBranch() ? .handled : .ignored
        default:
            return .ignored
        }
    }

    private var focusedNode: RadialNavigationNode? {
        guard let focusedItemID else { return nil }
        return projection.node(withID: focusedItemID)
    }

    private var focusedQuickAccessShortcut: RadialQuickAccessShortcut? {
        guard let focusedItemID else { return nil }
        return quickAccessShortcuts.first(where: { $0.id == focusedItemID })
    }

    private func activateFocusedItem() -> KeyPress.Result {
        guard let focusedItemID else { return .ignored }

        switch focusedItemID {
        case ChromeFocusID.back:
            retreatOneLevel()
            return .handled
        case ChromeFocusID.windowLayout:
            onSelectPresentation(.separateWindow)
            return .handled
        case ChromeFocusID.radialLayout:
            onSelectPresentation(.radial)
            return .handled
        case ChromeFocusID.panelLayout:
            onSelectPresentation(.controlPanel)
            return .handled
        case ChromeFocusID.tighterCurvature:
            curvature = min(max(curvature - 0.08, 0.35), 1.35)
            return .handled
        case ChromeFocusID.widerCurvature:
            curvature = min(max(curvature + 0.08, 0.35), 1.35)
            return .handled
        default:
            break
        }

        if let shortcut = focusedQuickAccessShortcut {
            activateQuickAccessShortcut(shortcut)
            return .handled
        }

        guard let node = projection.node(withID: focusedItemID) else { return .ignored }
        if node.slider != nil {
            // Sliders use Left/Right for adjustment. Consuming activation avoids
            // Space falling through to viewport playback while a slider owns focus.
            return .handled
        }
        if let toggle = node.toggle {
            toggle.toggle()
            return .handled
        }
        if expandFocusedBranch() { return .handled }
        if let action = node.fallbackAction {
            action()
            return .handled
        }
        return .ignored
    }

    /// Right Arrow (or activation of a branch) descends through the same quick
    /// inputs that pointer users reveal by hovering.
    @discardableResult
    private func expandFocusedBranch() -> Bool {
        guard let focusedItemID,
              let node = projection.node(withID: focusedItemID),
              node.isBranch,
              let target = projection.flattenedKeyboardTargets()
                .first(where: { $0.id == focusedItemID })
        else { return false }

        setNavigationPath(target.ancestorPath + [node.id])
        if let firstChild = projection.presentedChildren(of: node).first {
            self.focusedItemID = firstChild.id
        }
        return true
    }

    private func retreatOrDismiss() {
        if RadialNavigationPathPolicy.retreating(from: presentedPath) != nil {
            retreatOneLevel()
            return
        }

        onDismiss()
    }

    private func retreatOneLevel() {
        let presentedPath = self.presentedPath
        guard let newPath = RadialNavigationPathPolicy.retreating(from: presentedPath),
              let collapsedParentID = presentedPath.last else { return }
        disarmPendingHover()
        setNavigationPath(newPath)
        focusedItemID = collapsedParentID
    }
}

private struct RadialMenuButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: RadialNavigationNode
    let depth: Int
    let fixedWidth: CGFloat?
    let isFocused: Bool
    let isExpanded: Bool
    let retreatDirection: CGFloat
    let sceneAccent: Color
    let interactionProfile: RadialInteractionProfile
    let onActivate: () -> Void
    let onOpenFullControls: (() -> Void)?
    let onHoverChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var hoverOffset: CGFloat = 0
    @State private var hoverSequence = 0
    @State private var shimmerProgress: CGFloat = -1

    private var isEmphasized: Bool { item.isSelected || isExpanded || isHovering || isFocused }
    private var shouldWiggle: Bool {
        !reduceMotion && !item.isSelected && !isExpanded && !isHovering && !isFocused
    }

    /// Different rests keep the symbols from moving as a synchronized block.
    /// The animation itself is handled by the system symbol compositor, so it
    /// does not drive layout or rebuild the Metal-backed content underneath.
    private var wiggleDelay: Double {
        let phase = item.id.utf8.reduce(0) { (partial, byte) in
            (partial + Int(byte)) % 9
        }
        return 0.32 + Double(phase) * 0.09
    }

    var body: some View {
        Button(action: handleActivation) {
            HStack(spacing: depth == 0 ? 7 : 6) {
                Image(systemName: item.systemImage)
                    .font(.system(size: depth == 0 ? 12 : 10.5, weight: .semibold))
                    .frame(width: depth == 0 ? 16 : 13)
                    .symbolEffect(
                        .wiggle.wholeSymbol,
                        options: .repeat(.periodic(delay: wiggleDelay)).speed(0.52),
                        isActive: shouldWiggle
                    )

                Text(item.title)
                    .font(.system(size: depth == 0 ? 11.5 : 10, weight: isEmphasized ? .bold : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if item.isSelected {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.74, blue: 1.00))
                        .frame(width: 5, height: 5)
                        .shadow(color: .purple, radius: 5)
                }

                // Branch pills advertise that hovering opens a deeper ring.
                if item.isBranch {
                    Image(systemName: isExpanded ? "chevron.compact.left" : "chevron.compact.right")
                        .font(.system(size: depth == 0 ? 10 : 8, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.38))
                }
            }
            .padding(.horizontal, depth == 0 ? 11 : 8)
            .frame(height: max(interactionProfile.minimumTargetSize, depth == 0 ? 36 : 28))
            .frame(
                minWidth: fixedWidth ?? (depth == 0 ? 116 : 84),
                idealWidth: fixedWidth ?? (depth == 0 ? 128 : 92),
                maxWidth: fixedWidth ?? (depth == 0 ? 140 : 100),
                alignment: .leading
            )
            .background(tabFill, in: Capsule())
            .overlay(
                Capsule()
                    .inset(by: 1)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.24), Color.clear, sceneAccent.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isEmphasized ? emphasisAccent.opacity(0.78) : Color.white.opacity(0.10),
                        lineWidth: isEmphasized ? 1.2 : 0.8
                    )
            )
            .overlay(shimmerOverlay)
            // Move only the painted pill, leaving the button's layout and hit
            // target fixed. The cursor can therefore catch the pill when it
            // springs back instead of chasing a moving target.
            .offset(x: hoverOffset)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEmphasized ? Color.white : Color.white.opacity(0.68))
        .shadow(color: isEmphasized ? Color.white.opacity(0.34) : .clear, radius: 2.5)
        .shadow(
            color: isEmphasized ? emphasisAccent.opacity(0.44) : Color.black.opacity(0.28),
            radius: isEmphasized ? 11 : 4,
            x: 0,
            y: 2
        )
        .scaleEffect(RadialFocusMagnification.scale(
            for: interactionProfile,
            isFocused: isFocused,
            isExpanded: isExpanded,
            isEngaged: isHovering
        ))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isFocused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
        .onHover { hovering in
            guard interactionProfile.supportsHoverNavigation else { return }
            isHovering = hovering
            onHoverChanged(hovering)
            hoverSequence &+= 1
            let sequence = hoverSequence

            if hovering && !reduceMotion {
                shimmerProgress = -1
                withAnimation(.linear(duration: 0.92).repeatForever(autoreverses: false)) {
                    shimmerProgress = 1
                }
            } else {
                shimmerProgress = -1
            }

            guard hovering, !reduceMotion else {
                withAnimation(.easeOut(duration: 0.08)) {
                    hoverOffset = 0
                }
                return
            }

            // A six-point retreat reads as a playful flinch without escaping
            // the stable hit target, then a short spring lands it under the mouse.
            withAnimation(.easeOut(duration: 0.06)) {
                hoverOffset = retreatDirection * 6
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(55))
                guard hoverSequence == sequence, isHovering else { return }
                withAnimation(.spring(response: 0.19, dampingFraction: 0.58)) {
                    hoverOffset = 0
                }
            }
        }
        .help(item.isBranch
            ? isExpanded
                ? "\(item.title): click to go back one level; double-click to open full controls"
                : "\(item.title): hover or press Right Arrow to reveal; double-click to open full controls"
            : item.title)
        .accessibilityHint(item.isBranch
            ? isExpanded
                ? "Activate to collapse this level."
                : "Press Right Arrow or Return to reveal child controls."
            : item.fallbackAction != nil
                ? "Press Return to open the full controls for this section."
                : "Use the available quick control.")
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }

    private func handleActivation() {
        #if os(macOS)
        if let event = NSApp.currentEvent,
           event.type == .leftMouseUp,
           RadialActivationPolicy.shouldOpenFullControls(
               activationCount: event.clickCount,
               hasFullControlsAction: onOpenFullControls != nil
           ),
           let onOpenFullControls {
            onOpenFullControls()
            return
        }
        #endif
        onActivate()
    }

    private var tabFill: LinearGradient {
        let depthLift = min(CGFloat(depth) * 0.025, 0.07)
        return LinearGradient(
            colors: isEmphasized
                ? [
                    Color(red: 0.08 + depthLift, green: 0.012, blue: 0.15 + depthLift).opacity(0.99),
                    Color(red: 0.38 + depthLift, green: 0.055, blue: 0.60 + depthLift).opacity(0.98),
                    sceneAccent.opacity(0.94)
                ]
                : [
                    Color(red: 0.035 + depthLift, green: 0.008, blue: 0.075 + depthLift).opacity(0.97),
                    Color(red: 0.18 + depthLift, green: 0.025, blue: 0.31 + depthLift).opacity(0.95)
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private var shimmerOverlay: some View {
        if isHovering {
            GeometryReader { proxy in
                let bandWidth = max(30, proxy.size.width * 0.22)
                let travel = proxy.size.width + bandWidth * 2

                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.08),
                        sceneAccent.opacity(0.90),
                        Color.white.opacity(0.16),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: bandWidth, height: proxy.size.height * 2.2)
                .rotationEffect(.degrees(18))
                .offset(
                    x: -bandWidth + travel * ((shimmerProgress + 1) * 0.5),
                    y: -proxy.size.height * 0.6
                )
            }
            .clipShape(Capsule())
            .blendMode(.screen)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var emphasisAccent: Color {
        isHovering || isFocused
            ? sceneAccent
            : Color(red: 0.92, green: 0.62, blue: 1.00)
    }
}

/// Terminal binary control. It stays in the radial surface after activation so
/// several related switches can be changed without reopening or traversing the
/// menu, and it exposes explicit On/Off semantics to keyboard and VoiceOver.
private struct RadialTogglePill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: RadialNavigationNode
    let toggle: RadialToggleBinding
    let fixedWidth: CGFloat
    let isFocused: Bool
    let sceneAccent: Color
    let interactionProfile: RadialInteractionProfile
    let onHoverChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isPointerInside = false

    private var isEnabled: Bool { toggle.isEnabled() }
    private var isEmphasized: Bool { isFocused || (isEnabled && isHovering) }

    var body: some View {
        let value = toggle.read()
        let enabled = isEnabled

        Button {
            toggle.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: node.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)

                Text(node.title)
                    .font(.system(size: 10.5, weight: isEmphasized ? .bold : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 3)

                Text(value ? "On" : "Off")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(value ? sceneAccent : Color.white.opacity(0.56))

                ZStack {
                    Capsule()
                        .fill(value ? sceneAccent.opacity(0.78) : Color.white.opacity(0.16))
                        .frame(width: 27, height: 16)
                    Circle()
                        .fill(value ? Color.white : Color.white.opacity(0.68))
                        .frame(width: 12, height: 12)
                        .offset(x: value ? 5.5 : -5.5)
                }
            }
            .padding(.horizontal, 10)
            .frame(
                width: fixedWidth,
                height: max(30, interactionProfile.minimumTargetSize),
                alignment: .leading
            )
            .background(
                LinearGradient(
                    colors: value
                        ? [
                            Color(red: 0.12, green: 0.018, blue: 0.20).opacity(0.98),
                            sceneAccent.opacity(isEmphasized ? 0.56 : 0.36)
                        ]
                        : [
                            Color(red: 0.055, green: 0.012, blue: 0.09).opacity(0.96),
                            Color(red: 0.25, green: 0.04, blue: 0.38).opacity(0.94)
                        ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isEmphasized ? sceneAccent.opacity(0.78) : Color.white.opacity(0.10),
                        lineWidth: isEmphasized ? 1.2 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(isEmphasized ? Color.white : Color.white.opacity(0.72))
        .opacity(enabled ? 1 : 0.42)
        .saturation(enabled ? 1 : 0.18)
        .shadow(
            color: isEmphasized ? sceneAccent.opacity(0.38) : Color.black.opacity(0.28),
            radius: isEmphasized ? 9 : 4,
            x: 0,
            y: 2
        )
        .scaleEffect(RadialFocusMagnification.scale(
            for: interactionProfile,
            isFocused: isFocused,
            isEngaged: isEnabled && isHovering
        ))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isEmphasized)
        .animation(.easeOut(duration: 0.12), value: enabled)
        .onHover { hovering in
            isPointerInside = hovering
            isHovering = enabled && hovering
            onHoverChanged(hovering)
        }
        .onDisappear {
            if isPointerInside {
                isPointerInside = false
                isHovering = false
                onHoverChanged(false)
            }
        }
        .help(enabled ? "\(node.title): \(value ? "On" : "Off")" : "\(node.title) is unavailable")
        .accessibilityLabel(node.title)
        .accessibilityValue(enabled ? (value ? "On" : "Off") : "\(value ? "On" : "Off"), unavailable")
        .accessibilityHint(enabled
            ? "Activate to turn \(value ? "off" : "on"). Left Arrow turns off; Right Arrow turns on."
            : "This setting is currently unavailable.")
    }
}

/// Terminal-ring slider pill. Horizontal drag follows the conventional slider
/// direction — right increases, left decreases — while trackpad scroll remains
/// available for fine adjustment.
///
/// Static gradients + a proportional fill only — same performance contract as
/// the tab pills: no blur, no control-tree mount, nothing re-rendering the
/// Metal view underneath.
private struct RadialSliderPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: RadialNavigationNode
    let slider: RadialSliderBinding
    let fixedWidth: CGFloat
    let isFocused: Bool
    let sceneAccent: Color
    let interactionProfile: RadialInteractionProfile
    /// A slider in the short-phone fallback lives inside a vertical scroll
    /// strip. Horizontal drags still adjust it, while vertical swipes must
    /// remain available to reveal the controls below.
    let allowsVerticalScroll: Bool
    let onHoverChanged: (Bool) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartValue: Float = 0
    /// Raw pointer containment, tracked apart from the availability-gated
    /// `isHovering` emphasis: unmount must retract exactly the raw hover
    /// report the host last received.
    @State private var isPointerInside = false

    /// Horizontal points that sweep the complete value range.
    private let fullRangeTravel: CGFloat = 180

    private var isEnabled: Bool { slider.isEnabled() }
    private var isEmphasized: Bool { isFocused || (isEnabled && (isHovering || isDragging)) }

    var body: some View {
        let value = slider.read()
        let normalized = CGFloat(slider.normalized(value))
        let enabled = isEnabled

        sliderInteractions(
            chrome(value: value, normalized: normalized),
            formattedValue: slider.format(value),
            isEnabled: enabled
        )
        .opacity(enabled ? 1 : 0.42)
        .saturation(enabled ? 1 : 0.18)
        .animation(.easeOut(duration: 0.12), value: enabled)
    }

    /// Break the large SwiftUI expression at a concrete type boundary. This
    /// transient overlay has only a few pills, while the boundary keeps Xcode's
    /// type checker from expanding its modifier tree exponentially.
    private func chrome(value: Float, normalized: CGFloat) -> AnyView {
        AnyView(pillChrome(pillLabel(value: value), normalized: normalized))
    }

    private func pillLabel(value: Float) -> some View {
        HStack(spacing: 7) {
            Image(systemName: node.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)

            Text(node.title)
                .font(.system(size: 10.5, weight: isEmphasized ? .bold : .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 3)

            Text(slider.format(value))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isEmphasized ? sceneAccent : Color.white.opacity(0.62))
        }
    }

    private func pillChrome<Content: View>(
        _ content: Content,
        normalized: CGFloat
    ) -> some View {
        content
        .padding(.horizontal, 10)
        .frame(width: fixedWidth, height: max(30, interactionProfile.minimumTargetSize), alignment: .leading)
        .background(
            gaugeBackground(normalized: normalized)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isEmphasized ? sceneAccent.opacity(0.78) : Color.white.opacity(0.10),
                    lineWidth: isEmphasized ? 1.2 : 0.8
                )
        )
        .foregroundStyle(isEmphasized ? Color.white : Color.white.opacity(0.72))
        .shadow(
            color: isEmphasized ? sceneAccent.opacity(0.38) : Color.black.opacity(0.28),
            radius: isEmphasized ? 9 : 4,
            x: 0,
            y: 2
        )
        .scaleEffect(RadialFocusMagnification.scale(
            for: interactionProfile,
            isFocused: isFocused,
            isEngaged: isEnabled && (isHovering || isDragging)
        ))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isEmphasized)
    }

    private func sliderInteractions(
        _ content: AnyView,
        formattedValue: String,
        isEnabled: Bool
    ) -> AnyView {
        let interactiveContent = applyingDragGesture(
            to: content.contentShape(Capsule().inset(by: -2)),
            isEnabled: isEnabled
        )

        return AnyView(
            interactiveContent
                .onHover(perform: updateHover)
                .onDisappear(perform: resetInteractionState)
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { resetInteractionState() }
                }
                .help(isEnabled
                    ? "\(node.title): use Left/Right, drag, or scroll to adjust"
                    : "\(node.title) is unavailable")
                .accessibilityElement()
                .accessibilityLabel(node.title)
                .accessibilityValue(isEnabled ? formattedValue : "\(formattedValue), unavailable")
                .accessibilityHint(isEnabled
                    ? "Use Left or Right, drag, scroll, or accessibility adjustment actions to change the value."
                    : "This setting is currently unavailable.")
                .accessibilityAdjustableAction { direction in
                    slider.step(by: direction == .increment ? 1 : -1)
                }
        )
    }

    private func applyingDragGesture<Content: View>(
        to content: Content,
        isEnabled: Bool
    ) -> AnyView {
        if allowsVerticalScroll {
            return AnyView(
                content.simultaneousGesture(
                    dragGesture,
                    including: isEnabled ? .all : .none
                )
            )
        }

        return AnyView(content.gesture(dragGesture, including: isEnabled ? .all : .none))
    }

    private var dragGesture: some Gesture {
        DragGesture(
            minimumDistance: allowsVerticalScroll ? 6 : 0,
            coordinateSpace: .named(RadialMenu.coordinateSpaceName)
        )
            .onChanged { gesture in
                guard slider.isEnabled() else { return }
                if allowsVerticalScroll,
                   abs(gesture.translation.height) >= abs(gesture.translation.width) {
                    return
                }
                if !isDragging {
                    isDragging = true
                    dragStartValue = slider.read()
                    onEditingChanged(true)
                }
                slider.writeIfEnabled(slider.value(
                    startingAt: dragStartValue,
                    horizontalTranslation: gesture.translation.width,
                    fullRangeTravel: fullRangeTravel
                ))
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                onEditingChanged(false)
            }
    }

    private func gaugeBackground(normalized: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.012, blue: 0.09).opacity(0.96),
                        Color(red: 0.25, green: 0.04, blue: 0.38).opacity(0.94)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // Proportional value fill — the pill IS the gauge.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.45, green: 0.08, blue: 0.67).opacity(0.55),
                                sceneAccent.opacity(isEmphasized ? 0.62 : 0.38)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(proxy.size.width * normalized, normalized > 0 ? 6 : 0))
            }
        }
    }

    private func resetInteractionState() {
        // A branch switch can unmount mid-drag; never leave the menu
        // adjustment bracket open.
        if isDragging {
            isDragging = false
            onEditingChanged(false)
        }
        if isPointerInside {
            isPointerInside = false
            isHovering = false
            onHoverChanged(false)
        }
    }

    private func updateHover(_ hovering: Bool) {
        isPointerInside = hovering
        // Emphasis stays availability-gated, but the report upward is raw:
        // the menu reconciles its hover-dwell state from every real
        // enter/exit, including ones over disabled pills, and re-checks
        // availability itself before treating the pill as a scroll target.
        isHovering = slider.isEnabled() && hovering
        onHoverChanged(hovering)
    }

}
