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
        // Existing behavior parity:
        // - Single-hand active on either side for same digit blocks two-hand.
        // - Grab active / cooldown suppresses new single-hand starts.
        let singleOwnsDigit = input.leftSingleActive || input.rightSingleActive
        let allowTwoHand = input.twoHandCandidate && !singleOwnsDigit
        let suppressSingleHand = input.grabActive || input.grabEndCooldown > 0 || (input.twoHandCurrentlyActive && allowTwoHand)
        return GestureArbitrationDecision(allowTwoHand: allowTwoHand, suppressSingleHand: suppressSingleHand)
    }
}
