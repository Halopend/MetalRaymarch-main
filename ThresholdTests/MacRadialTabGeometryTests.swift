#if os(macOS)
import CoreGraphics
import Testing
@testable import Threshold

@Suite("Mac radial tab geometry")
struct MacRadialTabGeometryTests {
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
        expectMinimumVerticalSpacing(positions, minimum: 46)
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
        expectMinimumVerticalSpacing(positions, minimum: 46)
    }

    @Test("Child pills keep compact non-overlapping spacing")
    func childRingDoesNotOverlap() {
        let positions = MacRadialTabGeometry(curvature: 0.82).positions(
            count: 6,
            depth: 1,
            anchor: CGPoint(x: 1_220, y: 92),
            availableHeight: 768
        )

        expectMinimumVerticalSpacing(positions, minimum: 34)
        #expect(positions.allSatisfy { $0.x < 1_220 })
    }

    @Test("Child ring clears every primary pill")
    func childRingClearsPrimaryRing() {
        let geometry = MacRadialTabGeometry(curvature: 0.82)
        let anchor = CGPoint(x: 1_220, y: 30)
        let primary = geometry.positions(
            count: 7,
            depth: 0,
            anchor: anchor,
            availableHeight: 768
        )

        // The five dock categories can each own a child branch. Exercise both a
        // compact three-item branch and the largest seven-item branch at every
        // possible attachment point. Bounds include room for the hover scale.
        for selectedIndex in 0..<5 {
            for childCount in [3, 7] {
                let childAnchor = CGPoint(x: anchor.x, y: primary[selectedIndex].y)
                let children = geometry.positions(
                    count: childCount,
                    depth: 1,
                    anchor: childAnchor,
                    availableHeight: 768
                )

                for primaryPoint in primary {
                    let primaryBounds = CGRect(
                        x: primaryPoint.x - 92,
                        y: primaryPoint.y - 23,
                        width: 184,
                        height: 46
                    )
                    for childPoint in children {
                        let childBounds = CGRect(
                            x: childPoint.x - 60,
                            y: childPoint.y - 17,
                            width: 120,
                            height: 34
                        )
                        #expect(!primaryBounds.intersects(childBounds))
                    }
                }
            }
        }
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
        #expect(positions.allSatisfy { abs($0.x - anchor.x) <= 304.001 })
        for rowStart in stride(from: 0, to: positions.count - 1, by: 2) {
            #expect(abs(positions[rowStart].y - positions[rowStart + 1].y) < 0.001)
        }
    }

    @Test("Child layer follows a compact local branch")
    func childLayerFollowsCompactLocalBranch() {
        let anchor = CGPoint(x: 520, y: 380)
        let children = MacRadialTabGeometry(curvature: 0.82).positions(
            count: 5,
            depth: 1,
            anchor: anchor,
            availableHeight: 768,
            opensLeft: true,
            localBranch: true
        )

        #expect(children.allSatisfy { $0.x < anchor.x })
        #expect(children.allSatisfy { abs($0.x - anchor.x) <= 164.001 })
        expectMinimumVerticalSpacing(children, minimum: 34)
    }

    private func expectMinimumVerticalSpacing(_ positions: [CGPoint], minimum: CGFloat) {
        for pair in zip(positions, positions.dropFirst()) {
            #expect(pair.1.y - pair.0.y >= minimum - 0.001)
        }
    }
}
#endif
