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

/// A compact fan that grows from the menu hand toward the center of the body.
/// Values are meters in the visionOS RealityView; the pure SIMD output is also
/// straightforward to test on every platform.
enum SpatialRadialGeometry {
  static let singleTrackReach: Float = 0.150
  static let nearTrackReach: Float = 0.115
  static let farTrackReach: Float = 0.225
  static let trackCurve: Float = 0.018
  static let verticalStep: Float = 0.078
  static let depthStep: Float = 0.006
  /// A small amount of two-hand adjustment is useful, but a 15-degree cap
  /// keeps even the outermost target inside the hand-scale interaction zone.
  static let maximumFanTilt: Float = .pi / 12
  static let railLength: Float = farTrackReach + trackCurve
  static let hubPosition = SIMD3<Float>(0, 0, 0.012)
  static let handRelativeOffset = SIMD3<Float>(0, 0.035, -0.025)

  /// `aboveHand` points +y toward the person's head and +z toward the ground.
  /// Rotate the menu plane so its normal points at the person and its top points
  /// against gravity, independent of palm roll and pitch.
  static let anchorToFacingOrientation = simd_quatf(
    angle: -.pi / 2,
    axis: SIMD3<Float>(1, 0, 0)
  )

  /// Conservative physical extents for layout regression tests. SwiftUI
  /// attachment typography can vary, so these slightly exceed the fixed frames.
  static let ringItemHalfSize = SIMD2<Float>(0.058, 0.034)
  static let headerHalfSize = SIMD2<Float>(0.145, 0.050)

  static func inwardSign(isLeftHanded: Bool) -> Float {
    isLeftHanded ? 1 : -1
  }

  static func constrainedRotation(_ rotation: Float) -> Float {
    guard rotation.isFinite else { return 0 }
    return min(max(rotation, -maximumFanTilt), maximumFanTilt)
  }

  static func shouldShowContent(menuRequested: Bool, handIsAnchored: Bool) -> Bool {
    menuRequested && handIsAnchored
  }

  static func headerPosition(isLeftHanded: Bool) -> SIMD3<Float> {
    SIMD3<Float>(inwardSign(isLeftHanded: isLeftHanded) * 0.120, 0.235, 0.004)
  }

  static func railPosition(
    depth: Int,
    rotation: Float,
    isLeftHanded: Bool
  ) -> SIMD3<Float> {
    let safeDepth = Float(min(max(depth, 0), 5))
    let safeRotation = constrainedRotation(rotation)
    let midpoint = inwardSign(isLeftHanded: isLeftHanded) * railLength * 0.5
    return SIMD3<Float>(
      midpoint * cos(safeRotation),
      midpoint * sin(safeRotation),
      -safeDepth * depthStep - 0.016
    )
  }

  static func railOrientation(rotation: Float) -> simd_quatf {
    simd_quatf(
      angle: constrainedRotation(rotation),
      axis: SIMD3<Float>(0, 0, 1)
    )
  }

  /// Rolls an attachment in the menu plane so its inward horizontal edge follows
  /// the circular plane/sphere section toward the hub. Rotation is constrained to
  /// the plane normal: the attachment continues to face the person rather than
  /// pitching edge-on as it moves around the arc.
  static func itemOrientation(
    angle: Float,
    isLeftHanded: Bool
  ) -> simd_quatf {
    guard angle.isFinite else {
      return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    // The fan mirrors across the hub. Pick the naturally inward horizontal edge
    // on each hand so the mirrored fan does not turn its labels upside down.
    let referenceAngle: Float = isLeftHanded ? 0 : .pi
    var roll = angle - referenceAngle
    if roll > .pi {
      roll -= 2 * .pi
    } else if roll < -.pi {
      roll += 2 * .pi
    }
    return simd_quatf(
      angle: roll,
      axis: SIMD3<Float>(0, 0, 1)
    )
  }

  static func placements(
    count: Int,
    depth: Int,
    rotation: Float = 0,
    isLeftHanded: Bool = false
  ) -> [SpatialRadialPlacement] {
    guard count > 0 else { return [] }
    let safeDepth = Float(min(max(depth, 0), 5))
    let sign = inwardSign(isLeftHanded: isLeftHanded)
    let safeRotation = constrainedRotation(rotation)
    let rotationCosine = cos(safeRotation)
    let rotationSine = sin(safeRotation)
    let nearCount = count <= 5 ? count : (count + 1) / 2
    let farCount = count - nearCount
    var result: [SpatialRadialPlacement] = []
    result.reserveCapacity(count)

    func appendTrack(itemCount: Int, reach: Float, indexOffset: Int, track: Int) {
      guard itemCount > 0 else { return }
      let midpoint = Float(itemCount - 1) * 0.5
      let maxDistanceFromCenter = max(midpoint, 1)
      for trackIndex in 0..<itemCount {
        let centeredIndex = Float(trackIndex) - midpoint
        let vertical = centeredIndex * verticalStep
        let centerWeight = 1 - abs(centeredIndex) / maxDistanceFromCenter
        let inward = sign * (reach + centerWeight * trackCurve)
        let x = inward * rotationCosine - vertical * rotationSine
        let y = inward * rotationSine + vertical * rotationCosine
        let index = indexOffset + trackIndex
        result.append(
          SpatialRadialPlacement(
            index: index,
            angle: atan2(y, x),
            position: SIMD3<Float>(
              x,
              y,
              -safeDepth * depthStep - Float(track) * 0.008
            )
          ))
      }
    }

    if farCount == 0 {
      appendTrack(itemCount: nearCount, reach: singleTrackReach, indexOffset: 0, track: 0)
    } else {
      appendTrack(itemCount: nearCount, reach: nearTrackReach, indexOffset: 0, track: 0)
      appendTrack(itemCount: farCount, reach: farTrackReach, indexOffset: nearCount, track: 1)
    }
    return result
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
