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
    visibleNodes(atDepth: path.count, in: hierarchy)
  }

  /// Returns the sibling ring at a specific hierarchy depth. Depth zero is the
  /// canonical root ring; every subsequent ring belongs to the selected branch
  /// immediately inside it.
  func visibleNodes(
    atDepth depth: Int,
    in hierarchy: NavigationHierarchy
  ) -> [NavigationHierarchy.Node] {
    guard depth > 0 else { return hierarchy.roots }
    guard depth <= path.count,
      let parent = hierarchy.node(withID: path[depth - 1]),
      parent.isBranch
    else {
      return []
    }
    return parent.children
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
    select(nodeID: nodeID, atDepth: path.count, in: hierarchy)
  }

  /// Selects a node on an explicit radial level. Selecting a sibling on an
  /// earlier level replaces only that branch and discards stale descendants,
  /// matching the path semantics used by Threshold's 2-D radial menu.
  mutating func select(
    nodeID: String,
    atDepth depth: Int,
    in hierarchy: NavigationHierarchy
  ) -> SelectionOutcome {
    guard depth >= 0,
      let node = visibleNodes(atDepth: depth, in: hierarchy)
        .first(where: { $0.id == nodeID })
    else {
      return .ignored
    }

    highlightedNodeID = nil
    path = Array(path.prefix(depth))
    if node.isBranch {
      path.append(node.id)
      return .navigated(path: path)
    }
    return .activate(nodeID: node.id)
  }

  mutating func highlight(
    nodeID: String?,
    atDepth depth: Int,
    in hierarchy: NavigationHierarchy
  ) {
    guard let nodeID else {
      highlightedNodeID = nil
      return
    }
    highlightedNodeID = visibleNodes(atDepth: depth, in: hierarchy)
      .contains(where: { $0.id == nodeID })
      ? nodeID
      : nil
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

enum SpatialRadialHand: Equatable, Sendable {
  case left
  case right
}

/// Frozen world-space coordinate frame captured at menu activation. Subsequent
/// hand and head movement is projected into this frame; none of it mutates the
/// plant itself.
struct SpatialRadialPlant: Equatable, Sendable {
  let origin: SIMD3<Float>
  let right: SIMD3<Float>
  let up: SIMD3<Float>
  let normal: SIMD3<Float>
  let hand: SpatialRadialHand

  init?(
    origin: SIMD3<Float>,
    headPosition: SIMD3<Float>,
    hand: SpatialRadialHand
  ) {
    guard Self.isFinite(origin), Self.isFinite(headPosition) else { return nil }

    var towardHead = headPosition - origin
    if simd_length_squared(towardHead) < 0.000_001 {
      towardHead = SIMD3<Float>(0, 0, 1)
    }
    let normal = simd_normalize(towardHead)

    let worldUp = SIMD3<Float>(0, 1, 0)
    var projectedUp = worldUp - normal * simd_dot(worldUp, normal)
    if simd_length_squared(projectedUp) < 0.000_001 {
      let fallback = SIMD3<Float>(0, 0, -1)
      projectedUp = fallback - normal * simd_dot(fallback, normal)
    }
    guard simd_length_squared(projectedUp) >= 0.000_001 else { return nil }

    let provisionalUp = simd_normalize(projectedUp)
    let right = simd_normalize(simd_cross(provisionalUp, normal))
    let up = simd_normalize(simd_cross(normal, right))
    guard Self.isFinite(right), Self.isFinite(up), Self.isFinite(normal) else { return nil }

    self.origin = origin
    self.right = right
    self.up = up
    self.normal = normal
    self.hand = hand
  }

  func localPosition(of worldPosition: SIMD3<Float>) -> SIMD3<Float> {
    let delta = worldPosition - origin
    return SIMD3<Float>(
      simd_dot(delta, right),
      simd_dot(delta, up),
      simd_dot(delta, normal)
    )
  }

  func worldPosition(of localPosition: SIMD3<Float>) -> SIMD3<Float> {
    origin
      + right * localPosition.x
      + up * localPosition.y
      + normal * localPosition.z
  }

  private static func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
  }
}

enum SpatialRadialInteractionOutcome: Equatable {
  case none
  case highlighted(nodeID: String?, depth: Int)
  case navigated(path: [String])
  case retreated(path: [String])
  case activate(nodeID: String)
  case dismissed
}

/// Platform-neutral direct-hand reducer. Radius moves through hierarchy levels;
/// azimuth chooses siblings; a pinch commits the highlighted sibling (or, over
/// the hub, retreats/dismisses). Gaze is accepted only as a boundary tie-break
/// and can never commit a selection by itself.
struct SpatialRadialInteractionState: Equatable {
  private(set) var navigation = SpatialRadialNavigationState()
  private(set) var plant: SpatialRadialPlant?
  private(set) var cursorWorldPosition: SIMD3<Float>?
  private(set) var cursorLocalPosition: SIMD3<Float>?
  private(set) var highlightedDepth: Int?
  private(set) var isActive = false

  private var previousRadius: Float = 0
  private var needsRearmAfterTrackingLoss = false
  /// A pinch may commit only after the hand has been seen released once —
  /// the menu-toggle pose itself can read as a pinch at activation.
  private var pinchReadyToCommit = false
  private var previousPinchStrength: Float = 1

  var hand: SpatialRadialHand? { plant?.hand }

  mutating func activate(
    at handPosition: SIMD3<Float>,
    headPosition: SIMD3<Float>,
    hand: SpatialRadialHand,
    focusing nodeID: String? = nil,
    in hierarchy: NavigationHierarchy
  ) -> Bool {
    guard let captured = SpatialRadialPlant(
      origin: handPosition,
      headPosition: headPosition,
      hand: hand
    ) else {
      reset()
      return false
    }

    navigation.reset()
    navigation.focus(nodeID: nodeID, in: hierarchy)
    plant = captured
    cursorWorldPosition = handPosition
    cursorLocalPosition = .zero
    highlightedDepth = navigation.depth
    previousRadius = 0
    needsRearmAfterTrackingLoss = false
    pinchReadyToCommit = false
    previousPinchStrength = 1
    isActive = true
    return true
  }

  mutating func update(
    handPosition: SIMD3<Float>?,
    pinchStrength: Float? = nil,
    gazeAssistedNodeID: String? = nil,
    in hierarchy: NavigationHierarchy
  ) -> SpatialRadialInteractionOutcome {
    guard isActive, let plant else { return .none }
    guard let handPosition, Self.isFinite(handPosition) else {
      cursorWorldPosition = nil
      cursorLocalPosition = nil
      needsRearmAfterTrackingLoss = true
      pinchReadyToCommit = false
      previousPinchStrength = 1
      return .none
    }

    let local = plant.localPosition(of: handPosition)
    let radius = hypot(local.x, local.y)
    cursorWorldPosition = handPosition
    cursorLocalPosition = local

    if needsRearmAfterTrackingLoss {
      previousRadius = radius
      needsRearmAfterTrackingLoss = false
      return .none
    }

    let depth = navigation.depth
    if depth > 0 {
      let retreatRadius = SpatialRadialGeometry.retreatRadius(forDepth: depth)
      if previousRadius > retreatRadius, radius <= retreatRadius {
        navigation.goBack()
        highlightedDepth = navigation.depth
        previousRadius = radius
        updateHighlight(
          localPosition: local,
          gazeAssistedNodeID: gazeAssistedNodeID,
          in: hierarchy
        )
        return .retreated(path: navigation.path)
      }
    }

    let oldHighlight = navigation.highlightedNodeID
    updateHighlight(
      localPosition: local,
      gazeAssistedNodeID: gazeAssistedNodeID,
      in: hierarchy
    )

    let currentDepth = navigation.depth
    let commitRadius = SpatialRadialGeometry.commitRadius(forDepth: currentDepth)
    let crossedOutward = previousRadius < commitRadius && radius >= commitRadius
    previousRadius = radius

    if crossedOutward, let nodeID = navigation.highlightedNodeID,
      let outcome = commitHighlight(
        nodeID,
        atDepth: currentDepth,
        localPosition: local,
        gazeAssistedNodeID: gazeAssistedNodeID,
        in: hierarchy
      )
    {
      return outcome
    }

    // Pinch is the direct confirmation: it commits the highlighted sibling
    // without requiring the full radial sweep. Over the hub it retreats one
    // level, or dismisses from the root. The rising edge is only honored after
    // the hand has been seen released, so the activation pose cannot commit.
    let pinch = pinchStrength ?? 0
    let pinchRose = pinchReadyToCommit
      && previousPinchStrength < SpatialRadialGeometry.pinchCommitThreshold
      && pinch >= SpatialRadialGeometry.pinchCommitThreshold
    if pinch <= SpatialRadialGeometry.pinchRearmThreshold {
      pinchReadyToCommit = true
    }
    previousPinchStrength = pinch

    if pinchRose {
      pinchReadyToCommit = false
      // The highlight is intentionally sticky through the hub dead zone, so
      // the radius (not highlight presence) decides between committing the
      // pointed-at sibling and operating the hub.
      if radius >= SpatialRadialGeometry.activationDeadZone,
        let nodeID = navigation.highlightedNodeID
      {
        if let outcome = commitHighlight(
          nodeID,
          atDepth: currentDepth,
          localPosition: local,
          gazeAssistedNodeID: gazeAssistedNodeID,
          in: hierarchy
        ) {
          return outcome
        }
      } else if radius < SpatialRadialGeometry.activationDeadZone {
        if navigation.canGoBack {
          navigation.goBack()
          highlightedDepth = navigation.depth
          updateHighlight(
            localPosition: local,
            gazeAssistedNodeID: gazeAssistedNodeID,
            in: hierarchy
          )
          return .retreated(path: navigation.path)
        }
        isActive = false
        return .dismissed
      }
    }

    if oldHighlight != navigation.highlightedNodeID || highlightedDepth != currentDepth {
      highlightedDepth = currentDepth
      return .highlighted(nodeID: navigation.highlightedNodeID, depth: currentDepth)
    }
    return .none
  }

  /// Shared radial-crossing / pinch commit path. Returns nil when the
  /// hierarchy rejects the selection (stale highlight).
  private mutating func commitHighlight(
    _ nodeID: String,
    atDepth depth: Int,
    localPosition: SIMD3<Float>,
    gazeAssistedNodeID: String?,
    in hierarchy: NavigationHierarchy
  ) -> SpatialRadialInteractionOutcome? {
    switch navigation.select(nodeID: nodeID, atDepth: depth, in: hierarchy) {
    case .navigated(let path):
      highlightedDepth = navigation.depth
      updateHighlight(
        localPosition: localPosition,
        gazeAssistedNodeID: gazeAssistedNodeID,
        in: hierarchy
      )
      return .navigated(path: path)
    case .activate(let nodeID):
      isActive = false
      return .activate(nodeID: nodeID)
    case .ignored:
      return nil
    }
  }

  mutating func reset() {
    navigation.reset()
    plant = nil
    cursorWorldPosition = nil
    cursorLocalPosition = nil
    highlightedDepth = nil
    previousRadius = 0
    needsRearmAfterTrackingLoss = false
    pinchReadyToCommit = false
    previousPinchStrength = 1
    isActive = false
  }

  private mutating func updateHighlight(
    localPosition: SIMD3<Float>,
    gazeAssistedNodeID: String?,
    in hierarchy: NavigationHierarchy
  ) {
    let depth = navigation.depth
    let nodes = navigation.visibleNodes(atDepth: depth, in: hierarchy)
    guard !nodes.isEmpty else {
      navigation.highlight(nodeID: nil, atDepth: depth, in: hierarchy)
      highlightedDepth = depth
      return
    }

    let radius = hypot(localPosition.x, localPosition.y)
    guard radius >= SpatialRadialGeometry.activationDeadZone else {
      highlightedDepth = depth
      return
    }

    let angle = SpatialRadialGeometry.angle(
      forLocalPosition: SIMD2<Float>(localPosition.x, localPosition.y)
    )
    let currentIndex = navigation.highlightedNodeID.flatMap { highlightedID in
      nodes.firstIndex(where: { $0.id == highlightedID })
    }
    var index = SpatialRadialGeometry.sectorIndex(
      angle: angle,
      count: nodes.count,
      preserving: currentIndex
    )

    if let gazeAssistedNodeID,
      let gazeIndex = nodes.firstIndex(where: { $0.id == gazeAssistedNodeID }),
      SpatialRadialGeometry.isNearSectorBoundary(angle: angle, count: nodes.count),
      SpatialRadialGeometry.areAdjacentSectors(index, gazeIndex, count: nodes.count)
    {
      index = gazeIndex
    }

    navigation.highlight(nodeID: nodes[index].id, atDepth: depth, in: hierarchy)
    highlightedDepth = depth
  }

  private static func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
  }
}

/// World-space ring layout and interaction thresholds, in meters.
enum SpatialRadialGeometry {
  static let activationDeadZone: Float = 0.070
  static let rootRingRadius: Float = 0.190
  static let descendantRingRadius: Float = 0.460
  static let rootCommitRadius: Float = 0.320
  static let descendantCommitRadius: Float = 0.540
  static let maximumReach: Float = 0.580
  static let intendedDeepReach: ClosedRange<Float> = 0.4572...0.6096
  static let angularHysteresis: Float = .pi / 36
  static let gazeBoundaryTolerance: Float = .pi / 72

  /// The menu gesture is usually made near the chest, and a ring spanning up
  /// to ~1.2 m planted there fills the whole field of view. Plant the frame at
  /// least this far from the head, pushed along the head→hand sight line so
  /// the cursor still starts centered on the hub.
  static let minimumHeadStandoff: Float = 0.70
  /// Pinch hysteresis for the direct confirmation. Commit requires a clear
  /// pinch; re-arming requires a clear release, so tracking jitter around the
  /// threshold cannot double-commit.
  static let pinchCommitThreshold: Float = 0.80
  static let pinchRearmThreshold: Float = 0.45

  // Compatibility values retained for the dormant RealityKit prototype. The
  // active visionOS path is the planted compositor renderer.
  static let maximumFanTilt: Float = .pi / 12
  static let railLength: Float = maximumReach
  static let hubPosition = SIMD3<Float>(0, 0, 0.012)
  static let handRelativeOffset = SIMD3<Float>.zero

  static let anchorToFacingOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

  static let ringItemHalfSize = SIMD2<Float>(0.055, 0.030)
  static let headerHalfSize = SIMD2<Float>(0.145, 0.050)

  static func inwardSign(isLeftHanded: Bool) -> Float {
    isLeftHanded ? 1 : -1
  }

  /// Where to plant the menu frame for an activation at `handPosition`: the
  /// hand itself when it is already comfortably far away, otherwise the same
  /// sight line extended to the minimum standoff. Keeping the origin on the
  /// head→hand ray means the cursor starts exactly on the hub either way.
  static func plantedOrigin(
    handPosition: SIMD3<Float>,
    headPosition: SIMD3<Float>
  ) -> SIMD3<Float> {
    let towardHand = handPosition - headPosition
    let distance = simd_length(towardHand)
    guard distance > 0.001, distance < minimumHeadStandoff else {
      return handPosition
    }
    return headPosition + towardHand * (minimumHeadStandoff / distance)
  }

  static func constrainedRotation(_ rotation: Float) -> Float {
    guard rotation.isFinite else { return 0 }
    return min(max(rotation, -maximumFanTilt), maximumFanTilt)
  }

  static func shouldShowContent(menuRequested: Bool, handIsAnchored: Bool) -> Bool {
    menuRequested && handIsAnchored
  }

  static func headerPosition(isLeftHanded: Bool) -> SIMD3<Float> {
    SIMD3<Float>(0, maximumReach + 0.08, 0.004)
  }

  static func railPosition(
    depth: Int,
    rotation: Float,
    isLeftHanded: Bool
  ) -> SIMD3<Float> {
    let safeRotation = constrainedRotation(rotation)
    let midpoint = railLength * 0.5
    return SIMD3<Float>(
      midpoint * cos(safeRotation),
      midpoint * sin(safeRotation),
      -Float(max(depth, 0)) * 0.004 - 0.016
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

  static func ringRadius(forDepth depth: Int) -> Float {
    depth <= 0
      ? rootRingRadius
      : min(descendantRingRadius + Float(depth - 1) * 0.035, maximumReach - 0.04)
  }

  static func commitRadius(forDepth depth: Int) -> Float {
    depth <= 0
      ? rootCommitRadius
      : min(descendantCommitRadius + Float(depth - 1) * 0.015, maximumReach)
  }

  static func retreatRadius(forDepth depth: Int) -> Float {
    guard depth > 0 else { return activationDeadZone }
    if depth == 1 { return rootCommitRadius - 0.05 }
    return max(
      activationDeadZone,
      commitRadius(forDepth: depth - 1) - 0.05
    )
  }

  /// Zero points up in the planted plane; angles increase clockwise when viewed
  /// by the wearer.
  static func angle(forLocalPosition position: SIMD2<Float>) -> Float {
    var result = atan2(position.x, position.y)
    if result < 0 { result += 2 * .pi }
    return result
  }

  static func angle(forIndex index: Int, count: Int) -> Float {
    guard count > 0 else { return 0 }
    return 2 * .pi * Float(index) / Float(count)
  }

  static func sectorIndex(
    angle: Float,
    count: Int,
    preserving currentIndex: Int? = nil
  ) -> Int {
    guard count > 1 else { return 0 }
    let step = 2 * Float.pi / Float(count)
    let normalized = normalizedAngle(angle)

    if let currentIndex, (0..<count).contains(currentIndex) {
      let center = Self.angle(forIndex: currentIndex, count: count)
      if angularDistance(normalized, center) <= step * 0.5 + angularHysteresis {
        return currentIndex
      }
    }

    return Int(floor((normalized + step * 0.5) / step)) % count
  }

  static func isNearSectorBoundary(angle: Float, count: Int) -> Bool {
    guard count > 1 else { return false }
    let step = 2 * Float.pi / Float(count)
    let normalized = normalizedAngle(angle)
    let nearestCenter = Float(sectorIndex(angle: normalized, count: count)) * step
    let fromCenter = angularDistance(normalized, nearestCenter)
    return abs(fromCenter - step * 0.5) <= gazeBoundaryTolerance
  }

  static func areAdjacentSectors(_ first: Int, _ second: Int, count: Int) -> Bool {
    guard count > 1 else { return first == second }
    let distance = abs(first - second)
    return distance == 0 || distance == 1 || distance == count - 1
  }

  static func localPosition(
    index: Int,
    count: Int,
    depth: Int,
    rotation: Float = 0,
    isLeftHanded: Bool = false
  ) -> SIMD3<Float> {
    let direction: Float = isLeftHanded ? -1 : 1
    let itemAngle = direction * angle(forIndex: index, count: count)
      + constrainedRotation(rotation)
    let radius = ringRadius(forDepth: depth)
    return SIMD3<Float>(
      sin(itemAngle) * radius,
      cos(itemAngle) * radius,
      Float(depth) * 0.004
    )
  }

  static func placements(
    count: Int,
    depth: Int,
    rotation: Float = 0,
    isLeftHanded: Bool = false
  ) -> [SpatialRadialPlacement] {
    guard count > 0 else { return [] }
    let safeDepth = max(depth, 0)
    return (0..<count).map { index in
      let position = localPosition(
        index: index,
        count: count,
        depth: safeDepth,
        rotation: rotation,
        isLeftHanded: isLeftHanded
      )
      return SpatialRadialPlacement(
        index: index,
        angle: atan2(position.y, position.x),
        position: position
      )
    }
  }

  private static func normalizedAngle(_ angle: Float) -> Float {
    guard angle.isFinite else { return 0 }
    var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if result < 0 { result += 2 * .pi }
    return result
  }

  private static func angularDistance(_ first: Float, _ second: Float) -> Float {
    let raw = abs(normalizedAngle(first) - normalizedAngle(second))
    return min(raw, 2 * .pi - raw)
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
