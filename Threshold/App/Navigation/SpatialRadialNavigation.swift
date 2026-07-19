import Foundation
import simd

/// Mutually exclusive spatial surfaces. Keeping this as one value prevents a
/// quick-control ring and gesture map from becoming active simultaneously as
/// gesture requests arrive while the volume is already open.
enum SpatialRadialPresentationMode: Equatable {
  case navigation
  case quickControls
  case gestureMap
}

/// Platform-neutral traversal for radial navigation in a volume. Presentation,
/// gaze focus, and hand gestures are visionOS concerns; hierarchy semantics stay
/// here so spatial navigation follows the same routes as keyboard and 2-D radial
/// navigation.
struct SpatialRadialNavigationState: Equatable {
  enum SelectionOutcome: Equatable {
    case navigated(path: [String])
    case activate(nodeID: String)
    case ignored
  }

  private(set) var path: [String] = []
  private(set) var highlightedNodeID: String?

  var depth: Int { path.count }
  var canGoBack: Bool { !path.isEmpty }

  func visibleNodes(in hierarchy: NavigationHierarchy) -> [NavigationHierarchy.Node] {
    guard let currentID = path.last,
      let current = hierarchy.node(withID: currentID),
      current.isBranch
    else {
      return hierarchy.roots
    }
    return current.children
  }

  func currentBranch(in hierarchy: NavigationHierarchy) -> NavigationHierarchy.Node? {
    guard let id = path.last else { return nil }
    return hierarchy.node(withID: id)
  }

  /// Prepares a requested route without firing it. Branch requests open that
  /// branch in the volume; leaf requests reveal their parent ring and highlight
  /// the leaf for the person's confirming pinch.
  mutating func focus(nodeID: String?, in hierarchy: NavigationHierarchy) {
    guard let nodeID,
      let node = hierarchy.node(withID: nodeID),
      let target = hierarchy.flattenedKeyboardTargets().first(where: { $0.id == nodeID })
    else {
      path = []
      highlightedNodeID = nil
      return
    }

    if node.isBranch {
      path = target.ancestorPath + [node.id]
      highlightedNodeID = nil
    } else {
      path = target.ancestorPath
      highlightedNodeID = node.id
    }
  }

  mutating func select(
    nodeID: String,
    in hierarchy: NavigationHierarchy
  ) -> SelectionOutcome {
    guard let node = visibleNodes(in: hierarchy).first(where: { $0.id == nodeID }) else {
      return .ignored
    }

    highlightedNodeID = nil
    if node.isBranch {
      path.append(node.id)
      return .navigated(path: path)
    }
    return .activate(nodeID: node.id)
  }

  mutating func goBack() {
    highlightedNodeID = nil
    guard !path.isEmpty else { return }
    path.removeLast()
  }

  mutating func reset() {
    path.removeAll(keepingCapacity: true)
    highlightedNodeID = nil
  }
}

struct SpatialRadialPlacement: Equatable {
  let index: Int
  let angle: Float
  let position: SIMD3<Float>
}

/// A shallow, tilted ring that uses actual volume depth without placing controls
/// so far apart that eye-and-hand targeting becomes tiring. Values are meters in
/// the visionOS RealityView; the pure SIMD output is also straightforward to test.
enum SpatialRadialGeometry {
  static let volumeWidth: Double = 0.72
  static let volumeHeight: Double = 0.84
  static let volumeDepth: Double = 0.24

  static let baseRadius: Float = 0.225
  static let depthRadiusStep: Float = 0.018
  static let ringTilt: Float = .pi / 12
  static let depthStep: Float = 0.018
  static let hubPosition = SIMD3<Float>(0, 0, 0.035)
  static let headerPosition = SIMD3<Float>(0, 0.315, 0.025)
  static let mathLensPosition = SIMD3<Float>(0, -0.315, -0.055)

  /// Conservative physical half-extents for layout regression tests. SwiftUI
  /// attachment typography can vary, so these intentionally exceed the fixed
  /// button frames and expected Lens/header content heights.
  static let ringItemHalfSize = SIMD2<Float>(0.064, 0.038)
  static let headerHalfHeight: Float = 0.060
  static let mathLensHalfWidth: Float = 0.180
  static let mathLensHalfHeight: Float = 0.090

  static func placements(
    count: Int,
    depth: Int,
    rotation: Float = 0
  ) -> [SpatialRadialPlacement] {
    guard count > 0 else { return [] }
    let radius = baseRadius + Float(min(max(depth, 0), 3)) * depthRadiusStep
    let safeDepth = Float(min(max(depth, 0), 5))
    let step = 2 * Float.pi / Float(count)
    let start = -Float.pi / 2 + rotation
    let cosineTilt = cos(ringTilt)
    let sineTilt = sin(ringTilt)
    let stepCosine = cos(step)
    let stepSine = sin(step)
    var radialX = cos(start)
    var radialY = sin(start)
    var result: [SpatialRadialPlacement] = []
    result.reserveCapacity(count)

    // RealityView may request a layout at gesture cadence. Rotate the unit
    // vector by one fixed complex multiply per item instead of evaluating
    // sin/cos twice for every attachment (four trig calls total per ring,
    // independent of item count).
    for index in 0..<count {
      let angle = start + Float(index) * step
      let vertical = radialY * radius
      result.append(
        SpatialRadialPlacement(
          index: index,
          angle: angle,
          position: SIMD3<Float>(
            radialX * radius,
            vertical * cosineTilt,
            vertical * sineTilt - safeDepth * depthStep
          )
        ))
      let nextX = radialX * stepCosine - radialY * stepSine
      radialY = radialX * stepSine + radialY * stepCosine
      radialX = nextX
    }
    return result
  }
}

/// A compact, immutable teaching snapshot for spatial controls. Capturing only
/// when the volume opens avoids polling lock-backed RenderSettings from a
/// RealityView update and keeps the compositor render loop completely separate.
struct SpatialMathLensSnapshot: Equatable {
  struct Page: Equatable {
    let field: String
    let title: String
    let formal: String
    let notice: String
  }

  let pages: [Page]
  let constructionRoute: String
  let transformCount: Int

  var field: String { pages.first?.field ?? "" }
  var title: String { pages.first?.title ?? "" }
  var formal: String { pages.first?.formal ?? "" }

  static func capture(
    formula: FractalModelType,
    transforms: [SpaceWarpOpValue]
  ) -> SpatialMathLensSnapshot {
    let concept = MathLensConcept.formula(formula)
    let enabled = transforms.filter(\.isEnabled)
    let namedSteps = enabled.prefix(3).map { $0.kind.displayName }
    var route = ["p"] + namedSteps
    if enabled.count > namedSteps.count { route.append("+…") }
    route.append("d(p)")
    let pages =
      [
        Page(
          field: concept.field,
          title: concept.title,
          formal: concept.formal,
          notice: concept.notice
        )
      ]
      + enabled.map { operation in
        let transform = MathLensConcept.transform(operation.kind)
        return Page(
          field: transform.field,
          title: transform.title,
          formal: transform.formal,
          notice: transform.notice
        )
      }

    return SpatialMathLensSnapshot(
      pages: pages,
      constructionRoute: route.joined(separator: "  →  "),
      transformCount: enabled.count
    )
  }

  /// Relates application navigation to the same mathematical object instead
  /// of showing an isolated equation with no explanation of why the control
  /// branch matters.
  func crossReference(for node: NavigationHierarchy.Node?) -> String {
    guard let destination = node?.destination else {
      return "Choose a ring to see which part of the construction it changes."
    }
    switch destination {
    case .workspace(.shape), .shape:
      return "Shape controls change the function that maps p to signed distance d(p)."
    case .workspace(.visualizations), .visualizations:
      return "Visualization controls reveal samples, normals, and structure derived from d(p)."
    case .workspace(.performance), .performance:
      return
        "Performance controls change how often and how precisely the ray samples d(p), not the field itself."
    case .workspace(.explore), .explore:
      return "A scene selects the formula, parameters, and transform composition shown below."
    case .workspace(.music), .music:
      return "Music modulation changes parameters over time, turning d(p) into d(p, t)."
    case .gestures:
      return "Hand gestures choose controls; they do not alter d(p) until an action is confirmed."
    case .quickToggles, .settings, .animationEditor:
      return "This branch changes how the construction is controlled or presented."
    }
  }
}

/// Read-only projection of the configured per-finger command layer. The same
/// snapshot can be tested on macOS and presented as a 3-D gesture map on
/// visionOS without exposing RenderSettings to the attachment hierarchy.
struct SpatialGestureShortcut: Identifiable, Equatable {
  enum Hand: String, Equatable {
    case left = "Left"
    case right = "Right"
  }

  let hand: Hand
  let fingerIndex: Int
  let fingerName: String
  let fingerIcon: String
  let action: PerFingerTapAction

  var id: String { "\(hand.rawValue).\(fingerIndex)" }
}

struct SpatialGestureMapSnapshot: Equatable {
  let isEnabled: Bool
  let menuGestureIsEnabled: Bool
  let menuGestureName: String
  let menuGestureIcon: String
  let shortcuts: [SpatialGestureShortcut]

  static func capture(
    isEnabled: Bool,
    menuGestureIsEnabled: Bool,
    menuGestureMode: MenuToggleGestureMode,
    leftActions: [PerFingerTapAction],
    rightActions: [PerFingerTapAction]
  ) -> SpatialGestureMapSnapshot {
    let names = ["Thumb", "Index", "Middle", "Ring", "Pinky"]
    let icons = [
      "hand.thumbsup.fill", "1.circle.fill", "2.circle.fill",
      "3.circle.fill", "4.circle.fill",
    ]

    func project(
      _ actions: [PerFingerTapAction],
      hand: SpatialGestureShortcut.Hand
    ) -> [SpatialGestureShortcut] {
      actions.prefix(names.count).indices.compactMap { index in
        let action = actions[index]
        guard action != .none else { return nil }
        return SpatialGestureShortcut(
          hand: hand,
          fingerIndex: index,
          fingerName: names[index],
          fingerIcon: icons[index],
          action: action
        )
      }
    }

    return SpatialGestureMapSnapshot(
      isEnabled: isEnabled,
      menuGestureIsEnabled: menuGestureIsEnabled,
      menuGestureName: menuGestureMode.displayName,
      menuGestureIcon: menuGestureMode.icon,
      shortcuts: project(leftActions, hand: .left)
        + project(rightActions, hand: .right)
    )
  }
}
