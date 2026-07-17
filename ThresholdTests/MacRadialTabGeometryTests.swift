#if os(macOS)
import CoreGraphics
import Testing
@testable import Threshold

@Suite("Mac radial tab geometry")
struct MacRadialTabGeometryTests {
    @Test("Flattened window-drag hub does not overlap its center primary control")
    func gridWindowDragHubClearsPrimaryControl() {
        let size = CGSize(width: 1_440, height: 640)
        let pointerAnchor = CGPoint(x: 900, y: 320)
        let handle = MacQuickMenu.windowDragHandleFrame(
            size: size,
            pointerAnchor: pointerAnchor,
            layoutStyle: .grid
        )
        let primary = MacQuickMenu.gridCenterPrimaryPillFrame(
            size: size,
            pointerAnchor: pointerAnchor
        )

        #expect(!handle.intersects(primary))
        #expect(primary.maxX < handle.minX)
    }

    @Test("Primary pills remain separated when revealed against the top edge")
    func primaryRingDoesNotOverlapAtTopEdge() {
        let positions = MacRadialTabGeometry(curvature: 0.35).positions(
            count: 7,
            depth: 0,
            anchor: CGPoint(x: 1_220, y: 30),
            availableHeight: 768
        )

        #expect(positions.count == 7)
        #expect((positions.first?.y ?? 0) >= 30)
        expectMinimumVerticalSpacing(positions, minimum: 38)
    }

    @Test("Primary pills remain separated when revealed against the bottom edge")
    func primaryRingDoesNotOverlapAtBottomEdge() {
        let positions = MacRadialTabGeometry(curvature: 1.35).positions(
            count: 7,
            depth: 0,
            anchor: CGPoint(x: 1_220, y: 738),
            availableHeight: 768
        )

        #expect((positions.last?.y ?? 768) <= 738)
        expectMinimumVerticalSpacing(positions, minimum: 38)
    }

    @Test("Branch rings stay compact around their parent pill")
    func branchRingStaysCompact() {
        let anchor = CGPoint(x: 520, y: 380)
        let children = MacRadialTabGeometry(curvature: 0.82).positions(
            count: 5,
            depth: 1,
            anchor: anchor,
            availableHeight: 768,
            localBranch: true,
            branchBaseAngle: .pi
        )

        #expect(children.allSatisfy { $0.x < anchor.x })
        for child in children {
            let distance = hypot(child.x - anchor.x, child.y - anchor.y)
            // Distance from the parent grows past the arc radius only through
            // the vertical minimum-spacing stretch.
            #expect(distance >= MacRadialTabGeometry.localBranchRadius * 0.9)
        }
        expectMinimumVerticalSpacing(children, minimum: 32)
    }

    @Test("Radial fan mirrors toward the open side of the screen")
    func radialFanMirrorsHorizontally() {
        let geometry = MacRadialTabGeometry(curvature: 0.82)
        let anchor = CGPoint(x: 700, y: 380)
        let left = geometry.positions(
            count: 5,
            depth: 0,
            anchor: anchor,
            availableHeight: 768,
            opensLeft: true
        )
        let right = geometry.positions(
            count: 5,
            depth: 0,
            anchor: anchor,
            availableHeight: 768,
            opensLeft: false
        )

        #expect(left.allSatisfy { $0.x < anchor.x })
        #expect(right.allSatisfy { $0.x > anchor.x })
        #expect(zip(left, right).allSatisfy { pair in
            abs(pair.0.y - pair.1.y) < 0.001
        })
    }

    @Test("Bifurcated radial fan forms horizontal pairs")
    func bifurcatedFanFormsHorizontalPairs() {
        let anchor = CGPoint(x: 700, y: 380)
        let positions = MacRadialTabGeometry(curvature: 0.82).positions(
            count: 7,
            depth: 0,
            anchor: anchor,
            availableHeight: 768,
            opensLeft: true,
            bifurcates: true
        )

        #expect(positions.count == 7)
        #expect(positions.enumerated().allSatisfy { index, point in
            index.isMultiple(of: 2) ? point.x < anchor.x : point.x > anchor.x
        })
        #expect(positions.allSatisfy {
            abs($0.x - anchor.x) <= MacRadialTabGeometry.primaryRadius + 0.001
        })
        for rowStart in stride(from: 0, to: positions.count - 1, by: 2) {
            #expect(abs(positions[rowStart].y - positions[rowStart + 1].y) < 0.001)
        }
    }

    @Test("Hierarchy levels occupy exact concentric arcs")
    func hierarchyLevelsUseConcentricArcs() {
        let geometry = MacRadialTabGeometry(curvature: 0.82)
        let center = CGPoint(x: 700, y: 380)

        for depth in 1...2 {
            let radius = MacRadialTabGeometry.primaryRadius
                + CGFloat(depth) * MacRadialTabGeometry.concentricRingStep
            let points = geometry.concentricPositions(
                count: depth == 1 ? 5 : 8,
                anchor: center,
                radius: radius,
                baseAngle: .pi,
                sliderRing: depth == 2
            )

            #expect(points.allSatisfy { point in
                abs(hypot(point.x - center.x, point.y - center.y) - radius) < 0.001
            })
        }
    }

    @Test("Branches fan radially outward from edge pills")
    func branchFansOutwardFromEdgePill() {
        let geometry = MacRadialTabGeometry(curvature: 0.82)
        let anchor = CGPoint(x: 1_220, y: 384)
        let primary = geometry.positions(
            count: 7,
            depth: 0,
            anchor: anchor,
            availableHeight: 768
        )

        // Branch off the topmost pill: its children must sit farther from the
        // ring center than the pill itself, never back across the ring.
        let pill = primary[0]
        let placement = geometry.branchPlacement(
            count: 5,
            depth: 1,
            anchor: pill,
            baseAngle: atan2(pill.y - anchor.y, pill.x - anchor.x),
            prior: primary.map { point in
                MacRadialTabGeometry.PlacedPill(center: point, halfWidth: 94, halfHeight: 22.5)
            },
            parentPillIndex: 0,
            halfWidth: 61,
            halfHeight: 16.5,
            availableHeight: 768
        )

        let pillDistance = hypot(pill.x - anchor.x, pill.y - anchor.y)
        let centroid = placement.positions.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / CGFloat(placement.positions.count),
                    y: $0.y + $1.y / CGFloat(placement.positions.count))
        }
        #expect(hypot(centroid.x - anchor.x, centroid.y - anchor.y) > pillDistance)
    }

    /// Regression guard for the adaptive placement chooser: across curvature,
    /// vertical anchor position, selected pill, and ring sizes, every branch
    /// ring and every slider ring must clear every earlier pill (rest frame ×
    /// hover scale + 2pt margin; the direct parent tolerates contact). The
    /// constants were chosen by an exhaustive offline sweep of this exact
    /// model — this test keeps the envelope from silently regressing.
    @Test("Branch and slider rings clear all earlier pills at every curvature")
    func adaptivePlacementClearsAllRings() {
        let primaryHalf = (w: CGFloat(94), h: CGFloat(22.5))
        let childHalf = (w: CGFloat(61), h: CGFloat(16.5))
        let sliderHalf = (w: CGFloat(71), h: CGFloat(18))

        for curvature in [0.35, 0.82, 1.35] {
            let geometry = MacRadialTabGeometry(curvature: CGFloat(curvature))
            for anchorY in [CGFloat(30), 384, 738] {
                let anchor = CGPoint(x: 1_220, y: anchorY)
                let primary = geometry.positions(
                    count: 7,
                    depth: 0,
                    anchor: anchor,
                    availableHeight: 768
                )
                for selectedIndex in 0..<7 {
                    let pill = primary[selectedIndex]
                    let prior = primary.map {
                        MacRadialTabGeometry.PlacedPill(
                            center: $0, halfWidth: primaryHalf.w, halfHeight: primaryHalf.h
                        )
                    }
                    for childCount in [3, 7] {
                        let branch = geometry.branchPlacement(
                            count: childCount,
                            depth: 1,
                            anchor: pill,
                            baseAngle: atan2(pill.y - anchor.y, pill.x - anchor.x),
                            prior: prior,
                            parentPillIndex: selectedIndex,
                            halfWidth: childHalf.w,
                            halfHeight: childHalf.h,
                            availableHeight: 768
                        )
                        expectClear(
                            branch.positions, half: childHalf,
                            against: primary, priorHalf: primaryHalf,
                            contactIndex: selectedIndex,
                            context: "R0-R1 curvature \(curvature) anchorY \(anchorY) selected \(selectedIndex) count \(childCount)"
                        )

                        for childIndex in [0, childCount - 1] {
                            let childPill = branch.positions[childIndex]
                            let sliderPrior = prior + branch.positions.map {
                                MacRadialTabGeometry.PlacedPill(
                                    center: $0, halfWidth: childHalf.w, halfHeight: childHalf.h
                                )
                            }
                            for sliderCount in [3, 8] {
                                let sliderRing = geometry.branchPlacement(
                                    count: sliderCount,
                                    depth: 2,
                                    anchor: childPill,
                                    baseAngle: atan2(childPill.y - pill.y, childPill.x - pill.x),
                                    prior: sliderPrior,
                                    parentPillIndex: primary.count + childIndex,
                                    halfWidth: sliderHalf.w,
                                    halfHeight: sliderHalf.h,
                                    sliderRing: true,
                                    availableHeight: 768
                                )
                                // 34pt slider pills need the 40pt spacing floor.
                                let sortedYs = sliderRing.positions.map(\.y).sorted()
                                for pair in zip(sortedYs, sortedYs.dropFirst()) {
                                    #expect(pair.1 - pair.0 >= 40 - 0.001)
                                }
                                expectClear(
                                    sliderRing.positions, half: sliderHalf,
                                    against: primary, priorHalf: primaryHalf,
                                    contactIndex: -1,
                                    context: "R0-R2 curvature \(curvature) anchorY \(anchorY) selected \(selectedIndex)/\(childIndex) count \(sliderCount)"
                                )
                                expectClear(
                                    sliderRing.positions, half: sliderHalf,
                                    against: branch.positions, priorHalf: childHalf,
                                    contactIndex: childIndex,
                                    context: "R1-R2 curvature \(curvature) anchorY \(anchorY) selected \(selectedIndex)/\(childIndex) count \(sliderCount)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func expectClear(
        _ ring: [CGPoint],
        half: (w: CGFloat, h: CGFloat),
        against prior: [CGPoint],
        priorHalf: (w: CGFloat, h: CGFloat),
        contactIndex: Int,
        context: String
    ) {
        for (index, pillCenter) in prior.enumerated() {
            let margin: CGFloat = index == contactIndex ? 0 : 2
            for point in ring {
                let clearedX = abs(pillCenter.x - point.x) >= priorHalf.w + half.w + margin
                let clearedY = abs(pillCenter.y - point.y) >= priorHalf.h + half.h + margin
                #expect(clearedX || clearedY, "\(context): pill \(index) at \(pillCenter) vs \(point)")
            }
        }
    }

    private func expectMinimumVerticalSpacing(_ positions: [CGPoint], minimum: CGFloat) {
        for pair in zip(positions, positions.dropFirst()) {
            #expect(pair.1.y - pair.0.y >= minimum - 0.001)
        }
    }
}
#endif
