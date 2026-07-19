import Testing
import simd

@testable import Threshold

@Suite("Spatial radial navigation")
struct SpatialRadialNavigationTests {
  private func hierarchy() -> NavigationHierarchy {
    NavigationHierarchy.application(
      availability: NavigationAvailability(
        allowsCustomScenes: true,
        shapeSections: ShapeRailSection.allCases.filter { $0 != .performance },
        musicSections: MusicRailSection.availableCases,
        includesGestureEditing: true
      ))
  }

  @Test("Branches navigate in volume while leaves request activation")
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

  @Test("Requested branches open directly and requested leaves await confirmation")
  func focusedPresentation() {
    let tree = hierarchy()
    var state = SpatialRadialNavigationState()

    let performanceID = NavigationHierarchy.rootID(for: .performance)
    state.focus(nodeID: performanceID, in: tree)
    #expect(state.path == [performanceID])
    #expect(state.highlightedNodeID == nil)

    state.focus(nodeID: "utility.quickToggles", in: tree)
    #expect(state.path.isEmpty)
    #expect(state.highlightedNodeID == "utility.quickToggles")
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

  @Test("Spatial rings use real depth and preserve useful separation")
  func threeDimensionalGeometry() {
    let placements = SpatialRadialGeometry.placements(count: 8, depth: 2)
    #expect(placements.count == 8)
    #expect(Set(placements.map { Int(($0.position.z * 100_000).rounded()) }).count > 1)

    for index in placements.indices {
      let next = placements[(index + 1) % placements.count]
      #expect(simd_distance(placements[index].position, next.position) > 0.12)
    }
  }

  @Test("Geometry clamps unsupported counts and navigation depths")
  func geometryBoundsInputs() {
    #expect(SpatialRadialGeometry.placements(count: 0, depth: 0).isEmpty)
    #expect(SpatialRadialGeometry.placements(count: -1, depth: 0).isEmpty)

    let negativeDepth = SpatialRadialGeometry.placements(count: 3, depth: -4)
    let rootDepth = SpatialRadialGeometry.placements(count: 3, depth: 0)
    #expect(negativeDepth == rootDepth)

    let deepRing = SpatialRadialGeometry.placements(count: 3, depth: 50)
    let cappedRing = SpatialRadialGeometry.placements(count: 3, depth: 5)
    #expect(deepRing == cappedRing)
  }

  @Test("Rotation is rigid and does not change ring radius")
  func rotationPreservesRadius() {
    let base = SpatialRadialGeometry.placements(count: 7, depth: 0, rotation: 0)
    let rotated = SpatialRadialGeometry.placements(count: 7, depth: 0, rotation: 0.7)

    for (lhs, rhs) in zip(base, rotated) {
      #expect(abs(simd_length(lhs.position) - simd_length(rhs.position)) < 0.0001)
    }
  }

  @Test("Recurrence layout matches direct trigonometry without drift")
  func recurrenceAccuracy() {
    let count = 32
    let rotation: Float = 1.137
    let placements = SpatialRadialGeometry.placements(
      count: count,
      depth: 3,
      rotation: rotation
    )
    let radius =
      SpatialRadialGeometry.baseRadius
      + 3 * SpatialRadialGeometry.depthRadiusStep
    let step = 2 * Float.pi / Float(count)
    let start = -Float.pi / 2 + rotation

    for (index, placement) in placements.enumerated() {
      let angle = start + Float(index) * step
      let vertical = sin(angle) * radius
      let expected = SIMD3<Float>(
        cos(angle) * radius,
        vertical * cos(SpatialRadialGeometry.ringTilt),
        vertical * sin(SpatialRadialGeometry.ringTilt)
          - 3 * SpatialRadialGeometry.depthStep
      )
      #expect(simd_distance(placement.position, expected) < 0.000_002)
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

    // 20k full ring layouts in under half a second leaves several orders of
    // magnitude of headroom for one layout at 90 Hz, while remaining broad
    // enough not to flake under ordinary CI contention.
    #expect(elapsed < .milliseconds(500))
    #expect(checksum.isFinite)
  }

  @Test("Worst-case gesture ring and teaching overlays fit the volume")
  func volumeBounds() {
    let halfWidth = Float(SpatialRadialGeometry.volumeWidth / 2)
    let halfHeight = Float(SpatialRadialGeometry.volumeHeight / 2)
    let halfDepth = Float(SpatialRadialGeometry.volumeDepth / 2)

    // Sweep a full rotation because extrema can fall between the initial
    // ten evenly-spaced card positions.
    for sample in 0..<72 {
      let rotation = Float(sample) * 2 * .pi / 72
      for placement in SpatialRadialGeometry.placements(
        count: 10,
        depth: 1,
        rotation: rotation
      ) {
        #expect(abs(placement.position.x) + SpatialRadialGeometry.ringItemHalfSize.x < halfWidth)
        #expect(abs(placement.position.y) + SpatialRadialGeometry.ringItemHalfSize.y < halfHeight)
        #expect(abs(placement.position.z) < halfDepth)
      }
    }

    #expect(
      abs(SpatialRadialGeometry.headerPosition.y)
        + SpatialRadialGeometry.headerHalfHeight < halfHeight
    )
    #expect(
      SpatialRadialGeometry.mathLensHalfWidth < halfWidth
    )
    #expect(
      abs(SpatialRadialGeometry.mathLensPosition.y)
        + SpatialRadialGeometry.mathLensHalfHeight < halfHeight
    )
    #expect(abs(SpatialRadialGeometry.mathLensPosition.z) < halfDepth)
  }

  @Test("Spatial Math Lens snapshots only the enabled construction")
  func mathLensSnapshot() {
    var disabled = SpaceWarpOpValue(kind: .bend)
    disabled.isEnabled = false
    let snapshot = SpatialMathLensSnapshot.capture(
      formula: .mandelbox,
      transforms: [
        SpaceWarpOpValue(kind: .mirror),
        disabled,
        SpaceWarpOpValue(kind: .sphereFold),
        SpaceWarpOpValue(kind: .scale),
        SpaceWarpOpValue(kind: .twist),
      ]
    )

    #expect(snapshot.transformCount == 4)
    #expect(snapshot.constructionRoute.hasPrefix("p"))
    #expect(snapshot.constructionRoute.contains("Mirror"))
    #expect(!snapshot.constructionRoute.contains("Bend"))
    #expect(snapshot.constructionRoute.contains("+…"))
    #expect(snapshot.constructionRoute.hasSuffix("d(p)"))
    #expect(snapshot.pages.count == 5)
    #expect(snapshot.pages.first?.title == FractalModelType.mandelbox.displayName)
    #expect(
      snapshot.pages.dropFirst().map(\.title) == [
        SpaceWarpKind.mirror.displayName,
        SpaceWarpKind.sphereFold.displayName,
        SpaceWarpKind.scale.displayName,
        SpaceWarpKind.twist.displayName,
      ])
  }

  @Test("Math Lens cross-references the active spatial branch")
  func mathLensCrossReference() {
    let tree = hierarchy()
    let snapshot = SpatialMathLensSnapshot.capture(formula: .mandelbulb, transforms: [])
    let shape = tree.node(withID: NavigationHierarchy.rootID(for: .shape))
    let performance = tree.node(withID: NavigationHierarchy.rootID(for: .performance))

    #expect(snapshot.crossReference(for: shape).contains("signed distance"))
    #expect(snapshot.crossReference(for: performance).contains("not the field itself"))
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
