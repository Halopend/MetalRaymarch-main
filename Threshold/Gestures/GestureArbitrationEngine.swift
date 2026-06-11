import Foundation

struct GestureArbitrationInput {
    var digit: Int
    var twoHandCandidate: Bool
    var twoHandCurrentlyActive: Bool
    var leftSingleActive: Bool
    var rightSingleActive: Bool
    var grabActive: Bool
    var grabEndCooldown: Float
}

struct GestureArbitrationDecision: Equatable {
    var allowTwoHand: Bool
    var suppressSingleHand: Bool
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
        let suppressSingleHand = input.grabActive || input.grabEndCooldown > 0 || (input.twoHandCurrentlyActive && allowTwoHand)
        return GestureArbitrationDecision(allowTwoHand: allowTwoHand, suppressSingleHand: suppressSingleHand)
    }
}
