import Testing
@testable import Threshold

@Suite("Math Lens explanatory concepts")
struct MathLensConceptTests {
    @Test("Every transform has complete progressive-disclosure copy")
    func everyTransformHasCompleteConcept() {
        for kind in SpaceWarpKind.allCases {
            let concept = MathLensConcept.transform(kind)
            #expect(concept.title == kind.displayName)
            #expect(!concept.field.isEmpty)
            #expect(!concept.what.isEmpty)
            #expect(!concept.notice.isEmpty)
            #expect(!concept.formal.isEmpty)
            #expect(!concept.relatedKinds.isEmpty)
            #expect(!concept.relatedKinds.contains(kind))
            #expect(Set(concept.relatedKinds).count == concept.relatedKinds.count)
            #expect(concept.what.last.map { ".!?".contains($0) } == true)
        }
    }

    @Test("Core transform families teach the intended mathematical idea")
    func coreTransformFamilies() {
        #expect(MathLensConcept.transform(.planeFold).field == "Reflection & folding")
        #expect(MathLensConcept.transform(.inversion).field == "Radial geometry")
        #expect(MathLensConcept.transform(.coxeter).field == "Symmetry groups")
        #expect(MathLensConcept.transform(.scaleRepeat).field == "Self-similarity")
        #expect(MathLensConcept.transform(.tiling).field == "Periodic space")
        #expect(MathLensConcept.transform(.twist).field == "Domain deformation")
    }

    @Test("Formula fallback exposes higher-dimensional and implicit-set ideas")
    func formulaFallbacks() {
        let quaternion = MathLensConcept.formula(.quaternionJulia)
        let primitive = MathLensConcept.formula(.constructionPrimitive)

        #expect(quaternion.field == "Dynamical systems")
        #expect(quaternion.notice.contains("four-dimensional"))
        #expect(primitive.field == "Implicit geometry")
        #expect(primitive.formal.contains("d(p)"))
        #expect(!quaternion.relatedKinds.isEmpty)
        #expect(!primitive.relatedKinds.isEmpty)
    }

    @Test("Stack context cross-references the neighboring operations in execution order")
    func stackContextNamesNeighbors() {
        let transforms = [warpOp(.mirror), warpOp(.scale), warpOp(.twist)]

        let first = MathLensStackContext.description(forTransformAt: 0, in: transforms)
        let middle = MathLensStackContext.description(forTransformAt: 1, in: transforms)
        let last = MathLensStackContext.description(forTransformAt: 2, in: transforms)

        #expect(first.contains("passes it to Scale"))
        #expect(middle.contains("between Mirror Fold and Twist"))
        #expect(last.contains("passes it to the distance formula"))
        #expect(middle.contains("g(f(p))"))
    }

    @Test("Repeated groups explain feedback iteration")
    func groupContextExplainsFeedback() {
        let transforms = warpGroup(
            [warpOp(.boxFold), warpOp(.sphereFold), warpOp(.scale)],
            iterations: 4,
            mode: .mandelboxRecurrence
        )

        let context = MathLensStackContext.description(forTransformAt: 1, in: transforms)
        #expect(context.contains("feeds output back as input 4 times"))
    }

    @Test("Recursive reference paths grow, rewind, and backtrack")
    func recursiveReferenceTraversal() {
        var path = MathLensReferencePath()

        path.follow(.twist)
        path.follow(.bend)
        path.follow(.ripple)
        #expect(path.kinds == [.twist, .bend, .ripple])
        #expect(path.current == .ripple)
        #expect(path.depth == 3)

        path.follow(.bend)
        #expect(path.kinds == [.twist, .bend])

        path.goBack()
        #expect(path.kinds == [.twist])

        path.clear()
        #expect(path.isEmpty)
        #expect(path.current == nil)
    }

    @Test("Recursive traversal is bounded by unique catalog concepts")
    func recursiveReferenceTraversalIsCycleSafe() {
        var path = MathLensReferencePath()
        for kind in SpaceWarpKind.allCases {
            path.follow(kind)
        }
        #expect(path.depth == SpaceWarpKind.allCases.count)

        let first = SpaceWarpKind.allCases[0]
        path.follow(first)
        #expect(path.kinds == [first])
    }
}
