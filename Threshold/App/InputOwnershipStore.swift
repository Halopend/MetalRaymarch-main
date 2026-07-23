import SwiftUI

enum InteractionOwner: String, Sendable {
    case viewport
    case radialMenu
    case inspector
    case spatialControls
}

/// Serializes ownership at the semantic-input boundary so an event stream is
/// never interpreted by the viewport and an overlaid control surface together.
@MainActor
@Observable
final class InputOwnershipStore {
    private(set) var owner: InteractionOwner?
    private var claimCount = 0

    func claim(_ requester: InteractionOwner) -> Bool {
        guard owner == nil || owner == requester else { return false }
        owner = requester
        claimCount += 1
        return true
    }

    func release(_ requester: InteractionOwner) {
        guard owner == requester else { return }
        claimCount = max(0, claimCount - 1)
        if claimCount == 0 { owner = nil }
    }

    func canConsume(_ requester: InteractionOwner) -> Bool {
        owner == nil || owner == requester
    }
}
