import Foundation

@MainActor
final class TwoHandScalarGestureEngine {
    var state = TwoHandScalarEngineState()

    func reset() {
        state = TwoHandScalarEngineState()
    }
}

@MainActor
final class TwoPointGrabEngine {
    var state = TwoPointGrabGestureState()

    func reset() {
        state = TwoPointGrabGestureState()
    }
}

@MainActor
final class SingleHandDragEngine {
    var state = SingleHandDragEngineState()

    func reset(accumulatedPosition: SIMD3<Float>) {
        state = SingleHandDragEngineState(perSlot: [:], accumulatedPosition: accumulatedPosition)
    }
}
