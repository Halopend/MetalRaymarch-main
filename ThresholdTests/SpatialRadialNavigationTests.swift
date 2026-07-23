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
        musicSections: MusicRailSection.availableCases(for: .current),
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

  @Test("Spatial fan uses shallow depth and preserves useful separation")
  func threeDimensionalGeometry() {
    let placements = SpatialRadialGeometry.placements(count: 8, depth: 2)
    #expect(placements.count == 8)
    #expect(Set(placements.map { Int(($0.position.z * 100_000).rounded()) }).count > 1)

    for first in placements.indices {
      for second in placements.indices where second > first {
        #expect(simd_distance(placements[first].position, placements[second].position) > 0.07)
      }
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

  @Test("Rotation is rigid and does not change fan reach")
  func rotationPreservesRadius() {
    let base = SpatialRadialGeometry.placements(count: 7, depth: 0, rotation: 0)
    let rotated = SpatialRadialGeometry.placements(count: 7, depth: 0, rotation: 0.7)

    for (lhs, rhs) in zip(base, rotated) {
      #expect(abs(simd_length(lhs.position) - simd_length(rhs.position)) < 0.0001)
    }
  }

  @Test("Fan tilt is bounded so every target remains inward")
  func boundedFanTilt() {
    let maximum = SpatialRadialGeometry.maximumFanTilt
    #expect(SpatialRadialGeometry.constrainedRotation(.infinity) == 0)
    #expect(SpatialRadialGeometry.constrainedRotation(-.infinity) == 0)
    #expect(SpatialRadialGeometry.constrainedRotation(.nan) == 0)
    #expect(SpatialRadialGeometry.constrainedRotation(10) == maximum)
    #expect(SpatialRadialGeometry.constrainedRotation(-10) == -maximum)

    for isLeftHanded in [false, true] {
      let sign = SpatialRadialGeometry.inwardSign(isLeftHanded: isLeftHanded)
      for rotation in [-maximum, maximum] {
        let placements = SpatialRadialGeometry.placements(
          count: 10,
          depth: 2,
          rotation: rotation,
          isLeftHanded: isLeftHanded
        )
        #expect(placements.allSatisfy { $0.position.x * sign > 0 })

        let overRotated = SpatialRadialGeometry.placements(
          count: 10,
          depth: 2,
          rotation: rotation * 100,
          isLeftHanded: isLeftHanded
        )
        #expect(overRotated == placements)
      }
    }
  }

  @Test("Visual rail mirrors with handedness and follows the bounded tilt")
  func handRailGeometry() {
    let maximum = SpatialRadialGeometry.maximumFanTilt
    for rotation in [-maximum, Float(0), maximum] {
      let right = SpatialRadialGeometry.railPosition(
        depth: 3,
        rotation: rotation,
        isLeftHanded: false
      )
      let left = SpatialRadialGeometry.railPosition(
        depth: 3,
        rotation: rotation,
        isLeftHanded: true
      )
      #expect(abs(right.x + left.x) < 0.000_001)
      #expect(abs(right.y + left.y) < 0.000_001)
      #expect(abs(right.z - left.z) < 0.000_001)
    }
  }

  @Test("Fan items follow their planar arc while keeping an edge aimed at the hub")
  func itemOrientationFollowsArc() {
    for isLeftHanded in [false, true] {
      let sign = SpatialRadialGeometry.inwardSign(isLeftHanded: isLeftHanded)
      for rotation in [
        -SpatialRadialGeometry.maximumFanTilt,
        Float(0),
        SpatialRadialGeometry.maximumFanTilt,
      ] {
        let placements = SpatialRadialGeometry.placements(
          count: 9,
          depth: 2,
          rotation: rotation,
          isLeftHanded: isLeftHanded
        )

        for placement in placements {
          let orientation = SpatialRadialGeometry.itemOrientation(
            angle: placement.angle,
            isLeftHanded: isLeftHanded
          )
          let planarPosition = SIMD3<Float>(
            placement.position.x,
            placement.position.y,
            0
          )
          let expectedInward = -simd_normalize(planarPosition)
          let localInwardEdge = SIMD3<Float>(-sign, 0, 0)
          let actualInward = simd_act(orientation, localInwardEdge)
          let facingNormal = simd_act(orientation, SIMD3<Float>(0, 0, 1))

          #expect(simd_distance(actualInward, expectedInward) < 0.000_001)
          #expect(simd_distance(facingNormal, SIMD3<Float>(0, 0, 1)) < 0.000_001)
        }
      }
    }
  }

  @Test("An invalid arc angle has a stable identity orientation")
  func itemOrientationInvalidAngleFallback() {
    for isLeftHanded in [false, true] {
      let orientation = SpatialRadialGeometry.itemOrientation(
        angle: .nan,
        isLeftHanded: isLeftHanded
      )
      #expect(
        simd_distance(
          orientation.vector,
          SIMD4<Float>(0, 0, 0, 1)
        ) < 0.000_001
      )
    }
  }

  @Test("Spatial controls require both a menu request and a tracked hand")
  func trackedHandVisibility() {
    #expect(
      SpatialRadialGeometry.shouldShowContent(
        menuRequested: true,
        handIsAnchored: true
      )
    )
    #expect(
      !SpatialRadialGeometry.shouldShowContent(
        menuRequested: true,
        handIsAnchored: false
      )
    )
    #expect(
      !SpatialRadialGeometry.shouldShowContent(
        menuRequested: false,
        handIsAnchored: true
      )
    )
    #expect(
      !SpatialRadialGeometry.shouldShowContent(
        menuRequested: false,
        handIsAnchored: false
      )
    )
  }

  @Test("Fan mirrors from either hand toward the body center")
  func handedFanDirection() {
    let right = SpatialRadialGeometry.placements(
      count: 10,
      depth: 1,
      isLeftHanded: false
    )
    let left = SpatialRadialGeometry.placements(
      count: 10,
      depth: 1,
      isLeftHanded: true
    )

    #expect(right.allSatisfy { $0.position.x < 0 })
    #expect(left.allSatisfy { $0.position.x > 0 })
    for (rightPlacement, leftPlacement) in zip(right, left) {
      #expect(abs(rightPlacement.position.x + leftPlacement.position.x) < 0.000_001)
      #expect(abs(rightPlacement.position.y - leftPlacement.position.y) < 0.000_001)
      #expect(abs(rightPlacement.position.z - leftPlacement.position.z) < 0.000_001)
    }
  }

  @Test("Above-hand coordinates become an upright user-facing menu plane")
  func handAnchorOrientation() {
    let facing = simd_act(
      SpatialRadialGeometry.anchorToFacingOrientation,
      SIMD3<Float>(0, 0, 1)
    )
    let upright = simd_act(
      SpatialRadialGeometry.anchorToFacingOrientation,
      SIMD3<Float>(0, 1, 0)
    )

    #expect(simd_distance(facing, SIMD3<Float>(0, 1, 0)) < 0.000_001)
    #expect(simd_distance(upright, SIMD3<Float>(0, 0, -1)) < 0.000_001)
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

    // 20k full fan layouts in under half a second leaves several orders of
    // magnitude of headroom for one layout at 90 Hz, while remaining broad
    // enough not to flake under ordinary CI contention.
    #expect(elapsed < .milliseconds(500))
    #expect(checksum.isFinite)
  }

  @Test("Worst-case fan stays in a compact hand-scale envelope")
  func compactBounds() {
    let rotations: [Float] = [
      -SpatialRadialGeometry.maximumFanTilt,
      0,
      SpatialRadialGeometry.maximumFanTilt,
    ]
    for isLeftHanded in [false, true] {
      for rotation in rotations {
        for placement in SpatialRadialGeometry.placements(
          count: 10,
          depth: 1,
          rotation: rotation,
          isLeftHanded: isLeftHanded
        ) {
          #expect(abs(placement.position.x) + SpatialRadialGeometry.ringItemHalfSize.x < 0.34)
          #expect(abs(placement.position.y) + SpatialRadialGeometry.ringItemHalfSize.y < 0.25)
          #expect(abs(placement.position.z) < 0.04)
        }
      }

      let header = SpatialRadialGeometry.headerPosition(isLeftHanded: isLeftHanded)
      #expect(abs(header.x) + SpatialRadialGeometry.headerHalfSize.x < 0.28)
      #expect(abs(header.y) + SpatialRadialGeometry.headerHalfSize.y < 0.30)
    }

    #expect(simd_length(SpatialRadialGeometry.handRelativeOffset) < 0.05)
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
