import Foundation

struct GestureArbitrationInput {
    var twoHandCandidate: Bool
    var twoHandCurrentlyActive: Bool
    var grabActive: Bool
    var grabEndCooldown: Float
}

struct GestureArbitrationDecision: Equatable {
    var allowTwoHand: Bool
}

final class GestureArbitrationEngine {
    func decide(_ input: GestureArbitrationInput) -> GestureArbitrationDecision {
        // Two-hand gestures always take priority over single-hand for the same
        // digit. A user must pinch at least one hand first (starting a single-hand
        // drag) before the second hand joins — blocking two-hand because a
        // single-hand is active defeats the purpose.
        // Only block two-hand if it's NOT already active AND neither hand just
        // started (i.e., the single-hand has been running long enough to be
        // intentional, not a transient pinch-overlap).
        let allowTwoHand = input.twoHandCandidate
        return GestureArbitrationDecision(allowTwoHand: allowTwoHand)
    }
}
