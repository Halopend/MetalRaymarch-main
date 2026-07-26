import Testing
import simd

@testable import Threshold

@Suite("Spatial radial navigation")
struct SpatialRadialNavigationTests {
  private func hierarchy() -> NavigationHierarchy {
    NavigationHierarchy.application(
      availability: NavigationAvailability(
        allowsCustomScenes: true,
        shapeSections: ShapeRailSection.allCases,
        musicSections: MusicRailSection.availableCases(for: .current),
        includesGestureEditing: true
      ))
  }

  private func handPosition(
    in plant: SpatialRadialPlant,
    index: Int,
    count: Int,
    radius: Float
  ) -> SIMD3<Float> {
    let angle = SpatialRadialGeometry.angle(forIndex: index, count: count)
    return plant.worldPosition(
      of: SIMD3<Float>(
        sin(angle) * radius,
        cos(angle) * radius,
        0
      ))
  }

  @Test("Branches navigate while leaves activate the shared target")
  func branchAndLeafOutcomes() {
    let tree = hierarchy()
    var state = SpatialRadialNavigationState()
    let shapeID = NavigationHierarchy.rootID(for: .shape)

    #expect(
      state.select(nodeID: shapeID, in: tree)
        == .navigated(path: [shapeID]))
    #expect(state.visibleNodes(in: tree).contains(where: { $0.id.hasPrefix("shape.") }))

    let leaf = state.visibleNodes(in: tree).first!
    #expect(state.select(nodeID: leaf.id, in: tree) == .activate(nodeID: leaf.id))
    #expect(state.path == [shapeID])
  }

  @Test("Requested branches open directly and requested leaves await hand confirmation")
  func focusedPresentation() {
    let tree = hierarchy()
    var state = SpatialRadialNavigationState()

    let qualityID = NavigationHierarchy.rootID(for: .quality)
    state.focus(nodeID: qualityID, in: tree)
    #expect(state.path == [qualityID])
    #expect(state.highlightedNodeID == nil)

    state.focus(nodeID: "utility.quickToggles", in: tree)
    #expect(state.path.isEmpty)
    #expect(state.highlightedNodeID == "utility.quickToggles")
  }

  @Test("Selecting an earlier sibling replaces stale descendants")
  func siblingReplacement() {
    let tree = hierarchy()
    var state = SpatialRadialNavigationState()
    let shapeID = NavigationHierarchy.rootID(for: .shape)
    let qualityID = NavigationHierarchy.rootID(for: .quality)

    _ = state.select(nodeID: shapeID, in: tree)
    #expect(
      state.select(nodeID: qualityID, atDepth: 0, in: tree)
        == .navigated(path: [qualityID]))
    #expect(state.path == [qualityID])
    #expect(
      state.visibleNodes(in: tree).map(\.id)
        == tree.node(withID: qualityID)?.children.map(\.id))
  }

  @Test("Backtracking never activates a route")
  func backtracking() {
    let tree = hierarchy()
    var state = SpatialRadialNavigationState()
    _ = state.select(nodeID: NavigationHierarchy.rootID(for: .shape), in: tree)

    state.goBack()
    #expect(state.path.isEmpty)
    #expect(state.visibleNodes(in: tree).map(\.id) == tree.roots.map(\.id))

    state.goBack()
    #expect(state.path.isEmpty)
  }

  @Test("Plant captures the exact activation point and a stable head-facing frame")
  func plantedFrame() throws {
    let origin = SIMD3<Float>(0.31, 1.08, -0.44)
    let plant = try #require(
      SpatialRadialPlant(
        origin: origin,
        headPosition: SIMD3<Float>(0.18, 1.62, 0.11),
        hand: .right
      ))

    #expect(plant.origin == origin)
    #expect(abs(simd_length(plant.right) - 1) < 0.000_001)
    #expect(abs(simd_length(plant.up) - 1) < 0.000_001)
    #expect(abs(simd_length(plant.normal) - 1) < 0.000_001)
    #expect(abs(simd_dot(plant.right, plant.up)) < 0.000_001)
    #expect(simd_dot(plant.normal, SIMD3<Float>(0.18, 1.62, 0.11) - origin) > 0)

    let local = SIMD3<Float>(0.23, -0.17, 0.04)
    #expect(simd_distance(plant.localPosition(of: plant.worldPosition(of: local)), local) < 0.000_001)
  }

  @Test("Later hand and head movement never moves the planted origin")
  func plantRemainsFixed() throws {
    let tree = hierarchy()
    let activation = SIMD3<Float>(0.14, 1.02, -0.38)
    var state = SpatialRadialInteractionState()

    let activated = state.activate(
      at: activation,
      headPosition: SIMD3<Float>(0, 1.55, 0.2),
      hand: .left,
      in: tree
    )
    #expect(activated)
    let captured = try #require(state.plant)
    _ = state.update(
      handPosition: captured.worldPosition(of: SIMD3<Float>(0.17, 0.11, 0.08)),
      in: tree
    )

    #expect(state.plant == captured)
    #expect(state.plant?.origin == activation)
    #expect(state.cursorWorldPosition != activation)
  }

  @Test("Outward motion traverses a branch and then activates its leaf")
  func directHandTraversal() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: .zero,
      headPosition: SIMD3<Float>(0, 0, 1),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let plant = try #require(state.plant)
    let shapeID = NavigationHierarchy.rootID(for: .shape)
    let rootIndex = try #require(tree.roots.firstIndex(where: { $0.id == shapeID }))

    let highlight = state.update(
      handPosition: handPosition(
        in: plant,
        index: rootIndex,
        count: tree.roots.count,
        radius: 0.12
      ),
      in: tree
    )
    #expect(highlight == .highlighted(nodeID: shapeID, depth: 0))

    let branch = state.update(
      handPosition: handPosition(
        in: plant,
        index: rootIndex,
        count: tree.roots.count,
        radius: SpatialRadialGeometry.rootCommitRadius + 0.01
      ),
      in: tree
    )
    #expect(branch == .navigated(path: [shapeID]))
    #expect(state.navigation.path == [shapeID])

    let children = state.navigation.visibleNodes(in: tree)
    let leafIndex = try #require(children.firstIndex(where: { !$0.isBranch }))
    let leaf = children[leafIndex]
    _ = state.update(
      handPosition: handPosition(
        in: plant,
        index: leafIndex,
        count: children.count,
        radius: 0.40
      ),
      in: tree
    )
    let activation = state.update(
      handPosition: handPosition(
        in: plant,
        index: leafIndex,
        count: children.count,
        radius: SpatialRadialGeometry.descendantCommitRadius + 0.01
      ),
      in: tree
    )

    #expect(activation == .activate(nodeID: leaf.id))
    #expect(!state.isActive)
  }

  @Test("Moving around a ring changes siblings without selecting them")
  func azimuthSelectsSiblings() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: .zero,
      headPosition: SIMD3<Float>(0, 0, 1),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let plant = try #require(state.plant)

    _ = state.update(
      handPosition: handPosition(
        in: plant,
        index: 0,
        count: tree.roots.count,
        radius: 0.14
      ),
      in: tree
    )
    #expect(state.navigation.highlightedNodeID == tree.roots[0].id)

    _ = state.update(
      handPosition: handPosition(
        in: plant,
        index: 2,
        count: tree.roots.count,
        radius: 0.14
      ),
      in: tree
    )
    #expect(state.navigation.highlightedNodeID == tree.roots[2].id)
    #expect(state.navigation.path.isEmpty)
  }

  @Test("Crossing inward retreats exactly one hierarchy level")
  func inwardRetreat() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: .zero,
      headPosition: SIMD3<Float>(0, 0, 1),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let plant = try #require(state.plant)
    let shapeID = NavigationHierarchy.rootID(for: .shape)
    let rootIndex = try #require(tree.roots.firstIndex(where: { $0.id == shapeID }))

    _ = state.update(
      handPosition: handPosition(
        in: plant,
        index: rootIndex,
        count: tree.roots.count,
        radius: 0.12
      ),
      in: tree
    )
    _ = state.update(
      handPosition: handPosition(
        in: plant,
        index: rootIndex,
        count: tree.roots.count,
        radius: SpatialRadialGeometry.rootCommitRadius + 0.01
      ),
      in: tree
    )

    let retreat = state.update(
      handPosition: handPosition(
        in: plant,
        index: rootIndex,
        count: tree.roots.count,
        radius: SpatialRadialGeometry.retreatRadius(forDepth: 1) - 0.01
      ),
      in: tree
    )
    #expect(retreat == .retreated(path: []))
    #expect(state.navigation.path.isEmpty)
    #expect(state.isActive)
  }

  @Test("Tracking loss freezes the menu and rearms radial crossings")
  func trackingLossDoesNotTeleportOrCommit() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: SIMD3<Float>(0.2, 1, -0.3),
      headPosition: SIMD3<Float>(0, 1.6, 0.2),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let captured = try #require(state.plant)

    _ = state.update(
      handPosition: handPosition(
        in: captured,
        index: 0,
        count: tree.roots.count,
        radius: 0.15
      ),
      in: tree
    )
    #expect(state.update(handPosition: nil, in: tree) == .none)
    #expect(state.cursorWorldPosition == nil)
    #expect(state.plant == captured)

    let reacquired = state.update(
      handPosition: handPosition(
        in: captured,
        index: 0,
        count: tree.roots.count,
        radius: SpatialRadialGeometry.maximumReach
      ),
      in: tree
    )
    #expect(reacquired == .none)
    #expect(state.navigation.path.isEmpty)
    #expect(state.plant == captured)
  }

  @Test("Gaze only breaks an adjacent angular tie and never overrides clear hand intent")
  func gazeIsSecondary() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: .zero,
      headPosition: SIMD3<Float>(0, 0, 1),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let plant = try #require(state.plant)
    let step = 2 * Float.pi / Float(tree.roots.count)
    let boundary = step * 0.5

    let boundaryPosition = plant.worldPosition(
      of: SIMD3<Float>(sin(boundary) * 0.13, cos(boundary) * 0.13, 0))
    _ = state.update(
      handPosition: boundaryPosition,
      gazeAssistedNodeID: tree.roots[0].id,
      in: tree
    )
    #expect(state.navigation.highlightedNodeID == tree.roots[0].id)
    #expect(state.navigation.path.isEmpty)

    _ = state.update(
      handPosition: handPosition(
        in: plant,
        index: 2,
        count: tree.roots.count,
        radius: 0.13
      ),
      gazeAssistedNodeID: tree.roots[1].id,
      in: tree
    )
    #expect(state.navigation.highlightedNodeID == tree.roots[2].id)
    #expect(state.navigation.path.isEmpty)
  }

  @Test("Angular hysteresis prevents sibling chatter at sector boundaries")
  func angularHysteresis() {
    let count = 8
    let step = 2 * Float.pi / Float(count)
    let justPastBoundary = step * 0.5 + SpatialRadialGeometry.angularHysteresis * 0.5

    #expect(
      SpatialRadialGeometry.sectorIndex(
        angle: justPastBoundary,
        count: count,
        preserving: 0
      ) == 0)
    #expect(
      SpatialRadialGeometry.sectorIndex(
        angle: justPastBoundary,
        count: count
      ) == 1)
  }

  @Test("Deep interaction threshold remains within the intended 1.5–2 foot reach")
  func deepReach() {
    let intended = SpatialRadialGeometry.intendedDeepReach
    #expect(intended.contains(SpatialRadialGeometry.descendantCommitRadius))
    #expect(intended.contains(SpatialRadialGeometry.maximumReach))
    #expect(SpatialRadialGeometry.rootCommitRadius < intended.lowerBound)
    #expect(SpatialRadialGeometry.maximumReach <= 0.6096)
  }

  @Test("Radial geometry distributes targets around a planted world-space ring")
  func ringGeometry() {
    let placements = SpatialRadialGeometry.placements(count: 9, depth: 1)
    #expect(placements.count == 9)
    #expect(
      placements.allSatisfy {
        abs(hypot($0.position.x, $0.position.y)
          - SpatialRadialGeometry.ringRadius(forDepth: 1)) < 0.000_001
      })

    for first in placements.indices {
      for second in placements.indices where second > first {
        #expect(simd_distance(placements[first].position, placements[second].position) > 0.10)
      }
    }
  }

  @Test("Gesture-cadence layout stays comfortably below frame budget")
  func layoutThroughput() {
    let clock = ContinuousClock()
    var checksum: Float = 0
    let elapsed = clock.measure {
      for frame in 0..<20_000 {
        let placements = SpatialRadialGeometry.placements(
          count: 9,
          depth: frame % 4,
          rotation: Float(frame) * 0.001
        )
        checksum += placements[frame % placements.count].position.x
      }
    }

    #expect(elapsed < .milliseconds(500))
    #expect(checksum.isFinite)
  }

  @Test("Activations near the face plant at the minimum standoff along the same sight line")
  func plantStandoff() {
    let head = SIMD3<Float>(0.10, 1.60, 0.20)
    let closeHand = SIMD3<Float>(0.10, 1.35, -0.05)
    let planted = SpatialRadialGeometry.plantedOrigin(
      handPosition: closeHand,
      headPosition: head
    )

    #expect(
      abs(simd_distance(planted, head) - SpatialRadialGeometry.minimumHeadStandoff)
        < 0.000_01)
    #expect(
      simd_distance(
        simd_normalize(closeHand - head),
        simd_normalize(planted - head)
      ) < 0.000_01)

    let farHand = head + simd_normalize(closeHand - head) * 0.9
    #expect(
      SpatialRadialGeometry.plantedOrigin(handPosition: farHand, headPosition: head)
        == farHand)
  }

  @Test("A released-then-closed pinch commits the highlighted sibling without a sweep")
  func pinchCommitsHighlight() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: .zero,
      headPosition: SIMD3<Float>(0, 0, 1),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let plant = try #require(state.plant)
    let shapeID = NavigationHierarchy.rootID(for: .shape)
    let rootIndex = try #require(tree.roots.firstIndex(where: { $0.id == shapeID }))
    let highlightPosition = handPosition(
      in: plant,
      index: rootIndex,
      count: tree.roots.count,
      radius: 0.12
    )

    _ = state.update(handPosition: highlightPosition, pinchStrength: 0.1, in: tree)
    #expect(state.navigation.highlightedNodeID == shapeID)

    let committed = state.update(handPosition: highlightPosition, pinchStrength: 0.95, in: tree)
    #expect(committed == .navigated(path: [shapeID]))
    #expect(state.navigation.path == [shapeID])
  }

  @Test("A pinch already held at activation cannot commit until released once")
  func heldPinchRequiresRelease() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: .zero,
      headPosition: SIMD3<Float>(0, 0, 1),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let plant = try #require(state.plant)
    let position = handPosition(in: plant, index: 0, count: tree.roots.count, radius: 0.12)

    _ = state.update(handPosition: position, pinchStrength: 1.0, in: tree)
    _ = state.update(handPosition: position, pinchStrength: 1.0, in: tree)
    #expect(state.navigation.path.isEmpty)

    _ = state.update(handPosition: position, pinchStrength: 0.1, in: tree)
    let committed = state.update(handPosition: position, pinchStrength: 0.95, in: tree)
    #expect(committed == .navigated(path: [tree.roots[0].id]))
  }

  @Test("Pinching the hub retreats one level and dismisses from the root")
  func hubPinchRetreatsAndDismisses() throws {
    let tree = hierarchy()
    var state = SpatialRadialInteractionState()
    let activated = state.activate(
      at: .zero,
      headPosition: SIMD3<Float>(0, 0, 1),
      hand: .right,
      in: tree
    )
    #expect(activated)
    let plant = try #require(state.plant)
    let shapeID = NavigationHierarchy.rootID(for: .shape)
    let rootIndex = try #require(tree.roots.firstIndex(where: { $0.id == shapeID }))
    let highlightPosition = handPosition(
      in: plant,
      index: rootIndex,
      count: tree.roots.count,
      radius: 0.12
    )
    _ = state.update(handPosition: highlightPosition, pinchStrength: 0.1, in: tree)
    _ = state.update(handPosition: highlightPosition, pinchStrength: 0.95, in: tree)
    #expect(state.navigation.path == [shapeID])

    let hubPosition = plant.worldPosition(of: SIMD3<Float>(0.01, 0.01, 0))
    _ = state.update(handPosition: hubPosition, pinchStrength: 0.1, in: tree)
    let retreated = state.update(handPosition: hubPosition, pinchStrength: 0.95, in: tree)
    #expect(retreated == .retreated(path: []))
    #expect(state.navigation.path.isEmpty)
    #expect(state.isActive)

    _ = state.update(handPosition: hubPosition, pinchStrength: 0.1, in: tree)
    let dismissed = state.update(handPosition: hubPosition, pinchStrength: 0.95, in: tree)
    #expect(dismissed == .dismissed)
    #expect(!state.isActive)
  }

  @Test("Gesture map preserves hand, finger, action, and configured menu gesture")
  func gestureMapSnapshot() {
    let map = SpatialGestureMapSnapshot.capture(
      isEnabled: true,
      menuGestureIsEnabled: true,
      menuGestureMode: .middleOrRingToPalm,
      leftActions: [.none, .none, .none, .openShapeMenu, .openRenderMenu],
      rightActions: [.none, .none, .none, .openQuickToggles, .none]
    )

    #expect(map.isEnabled)
    #expect(map.menuGestureIsEnabled)
    #expect(map.menuGestureName == MenuToggleGestureMode.middleOrRingToPalm.displayName)
    #expect(map.shortcuts.map(\.id) == ["Left.3", "Left.4", "Right.3"])
    #expect(map.shortcuts.map(\.fingerName) == ["Ring", "Pinky", "Ring"])
    #expect(
      map.shortcuts.map(\.action) == [
        .openShapeMenu, .openRenderMenu, .openQuickToggles,
      ])
  }

  @Test("Gesture map represents an enabled but unassigned command layer")
  func emptyGestureMapSnapshot() {
    let unassigned = Array(repeating: PerFingerTapAction.none, count: 5)
    let map = SpatialGestureMapSnapshot.capture(
      isEnabled: true,
      menuGestureIsEnabled: true,
      menuGestureMode: .middleOrRingToPalm,
      leftActions: unassigned,
      rightActions: unassigned
    )

    #expect(map.isEnabled)
    #expect(map.shortcuts.isEmpty)
  }

  @Test("Gesture map safely truncates malformed persisted arrays")
  func gestureMapBounds() {
    let map = SpatialGestureMapSnapshot.capture(
      isEnabled: false,
      menuGestureIsEnabled: false,
      menuGestureMode: .middleOrRingToPalm,
      leftActions: Array(repeating: .openShapeMenu, count: 8),
      rightActions: []
    )

    #expect(!map.isEnabled)
    #expect(!map.menuGestureIsEnabled)
    #expect(map.shortcuts.count == 5)
    #expect(map.shortcuts.last?.fingerName == "Pinky")
  }
}
