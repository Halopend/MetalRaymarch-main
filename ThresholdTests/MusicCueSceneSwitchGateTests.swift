import Foundation
import Testing
@testable import Threshold

@Suite("Music-cue scene transition gate")
struct MusicCueSceneSwitchGateTests {
    @Test("A qualifying onset fires once and observes the cooldown")
    func onsetIsEdgeTriggeredAndRateLimited() {
        var gate = MusicCueSceneSwitchGate()

        let initialCue = gate.consume(
            onset: 0.8,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 0
        )
        #expect(initialCue)

        // A held onset never fires a second time.
        let heldCue = gate.consume(
            onset: 0.8,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 0.1
        )
        #expect(!heldCue)

        // A new threshold crossing before the cooldown is ignored.
        let rearmDuringCooldown = gate.consume(
            onset: 0.1,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 1
        )
        #expect(!rearmDuringCooldown)
        let cueDuringCooldown = gate.consume(
            onset: 0.9,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 4.9
        )
        #expect(!cueDuringCooldown)

        // It re-arms only after the onset falls and the cooldown expires.
        let rearmAfterCooldown = gate.consume(
            onset: 0.1,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 5.1
        )
        #expect(!rearmAfterCooldown)
        let cueAfterCooldown = gate.consume(
            onset: 0.9,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 5.2
        )
        #expect(cueAfterCooldown)
    }

    @Test("Disabled or inactive audio cannot leave a stale cue armed")
    func disabledOrInactiveAudioResetsGate() {
        var gate = MusicCueSceneSwitchGate()

        let disabledCue = gate.consume(
            onset: 1,
            isEnabled: false,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 0
        )
        #expect(!disabledCue)
        let enabledCue = gate.consume(
            onset: 1,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 0.1
        )
        #expect(enabledCue)

        let inactiveCue = gate.consume(
            onset: 1,
            isEnabled: true,
            isAudioActive: false,
            threshold: 0.7,
            minimumInterval: 5,
            at: 1
        )
        #expect(!inactiveCue)
        let resumedCue = gate.consume(
            onset: 1,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 1.1
        )
        #expect(resumedCue)
    }

    @Test("Invalid cues never trigger a scene switch")
    func invalidCueValuesAreSafe() {
        var gate = MusicCueSceneSwitchGate()

        let invalidOnset = gate.consume(
            onset: .nan,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: 1
        )
        #expect(!invalidOnset)
        let invalidTime = gate.consume(
            onset: 1,
            isEnabled: true,
            isAudioActive: true,
            threshold: 0.7,
            minimumInterval: 5,
            at: .infinity
        )
        #expect(!invalidTime)
    }

    @Test("Configured cue groups wrap and enter predictably")
    func cueGroupSequenceWrapsInBothDirections() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let group = [first, second, third]

        let forward = MusicCueSceneGroupSequence.nextIndex(
            currentID: third,
            candidateIDs: group,
            step: 1
        )
        let backward = MusicCueSceneGroupSequence.nextIndex(
            currentID: first,
            candidateIDs: group,
            step: -1
        )
        let enteringForward = MusicCueSceneGroupSequence.nextIndex(
            currentID: UUID(),
            candidateIDs: group,
            step: 1
        )
        let enteringBackward = MusicCueSceneGroupSequence.nextIndex(
            currentID: nil,
            candidateIDs: group,
            step: -1
        )

        #expect(forward == 0)
        #expect(backward == 2)
        #expect(enteringForward == 0)
        #expect(enteringBackward == 2)
    }

    @Test("Animation and static scenes coexist in one cue group")
    func mixedCueGroupUsesSourceQualifiedIdentifiers() {
        let sharedID = UUID()
        let animation = MusicCueSceneTarget(
            kind: .animation,
            sourceID: sharedID,
            name: "Motion",
            detail: "2 keyframes"
        )
        let staticScene = MusicCueSceneTarget(
            kind: .staticScene,
            sourceID: sharedID,
            name: "Still",
            detail: "Mandelbox"
        )

        let next = MusicCueSceneGroupSequence.nextIndex(
            currentID: animation.id,
            candidateIDs: [animation.id, staticScene.id],
            step: 1
        )

        #expect(animation.id != staticScene.id)
        #expect(next == 1)
        #expect(MusicCueSceneTarget.normalizedStorageID(sharedID.uuidString) == animation.id)
    }

    @Test("Scene sources combine without duplicating configured members")
    func sourceCombinationsBuildOneStablePool() {
        let firstAnimation = MusicCueSceneTarget(
            kind: .animation,
            sourceID: UUID(),
            name: "First Motion",
            detail: "2 keyframes"
        )
        let staticScene = MusicCueSceneTarget(
            kind: .staticScene,
            sourceID: UUID(),
            name: "Still Life",
            detail: "Mandelbox"
        )
        let secondAnimation = MusicCueSceneTarget(
            kind: .animation,
            sourceID: UUID(),
            name: "Second Motion",
            detail: "3 keyframes"
        )
        let secondStaticScene = MusicCueSceneTarget(
            kind: .staticScene,
            sourceID: UUID(),
            name: "Another Still",
            detail: "Kleinian"
        )
        let available = [firstAnimation, staticScene, secondAnimation, secondStaticScene]

        let combined = MusicCueSceneGroupSequence.eligibleTargets(
            sources: [.configuredGroup, .animationLibrary],
            availableTargets: available,
            configuredGroupTargetIDs: [staticScene.id, secondAnimation.id]
        )
        let allLibraries = MusicCueSceneGroupSequence.eligibleTargets(
            sources: [.animationLibrary, .staticSceneLibrary],
            availableTargets: available,
            configuredGroupTargetIDs: []
        )

        #expect(combined.map(\.id) == [staticScene.id, secondAnimation.id, firstAnimation.id])
        #expect(allLibraries.map(\.id) == [
            firstAnimation.id,
            secondAnimation.id,
            staticScene.id,
            secondStaticScene.id
        ])
    }

    @Test("Random selection candidates exclude the displayed scene")
    func randomCandidatesAvoidImmediateRepeat() {
        let candidates = ["first", "current", "last"]
        let withoutCurrent = MusicCueSceneGroupSequence.nonRepeatingCandidateIDs(
            currentID: "current",
            candidateIDs: candidates
        )
        let withoutKnownCurrent = MusicCueSceneGroupSequence.nonRepeatingCandidateIDs(
            currentID: nil as String?,
            candidateIDs: candidates
        )

        #expect(withoutCurrent == ["first", "last"])
        #expect(withoutKnownCurrent == candidates)
    }

    @Test("Scene tags are trimmed and de-duplicated for grouping")
    func sceneTagNormalization() {
        #expect(SceneTagging.normalized([" Favorites ", "favorites", "deep   cavern", ""]) == ["Favorites", "deep cavern"])
        #expect(SceneTagging.normalized(String(repeating: "x", count: SceneTagging.maximumTagLength + 1)) == nil)
    }
}
