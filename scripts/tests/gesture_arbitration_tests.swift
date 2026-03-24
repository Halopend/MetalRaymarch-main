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
        let singleOwnsDigit = input.leftSingleActive || input.rightSingleActive
        let allowTwoHand = input.twoHandCandidate && !singleOwnsDigit
        let suppressSingleHand = input.grabActive || input.grabEndCooldown > 0 || (input.twoHandCurrentlyActive && allowTwoHand)
        return GestureArbitrationDecision(allowTwoHand: allowTwoHand, suppressSingleHand: suppressSingleHand)
    }
}

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        return false
    }
    return true
}

let engine = GestureArbitrationEngine()
var ok = true

let conflict = engine.decide(.init(digit: 1, twoHandCandidate: true, twoHandCurrentlyActive: false, leftSingleActive: true, rightSingleActive: false, grabActive: false, grabEndCooldown: 0))
ok = expect(conflict.allowTwoHand == false, "single-hand ownership must block two-hand") && ok

let cooldown = engine.decide(.init(digit: 2, twoHandCandidate: false, twoHandCurrentlyActive: false, leftSingleActive: false, rightSingleActive: false, grabActive: false, grabEndCooldown: 0.12))
ok = expect(cooldown.suppressSingleHand == true, "grab cooldown suppresses single-hand starts") && ok

let hysteresis = engine.decide(.init(digit: 3, twoHandCandidate: true, twoHandCurrentlyActive: true, leftSingleActive: false, rightSingleActive: false, grabActive: false, grabEndCooldown: 0))
ok = expect(hysteresis.allowTwoHand == true && hysteresis.suppressSingleHand == true, "active two-hand should keep single-hand suppressed") && ok

if !ok { exit(1) }
print("Gesture arbitration tests passed")
