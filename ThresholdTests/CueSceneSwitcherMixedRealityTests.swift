//
//  CueSceneSwitcherMixedRealityTests.swift
//  ThresholdTests
//
//  Pins the cue scene switcher (Transitions tab pool + canvas arrow-key
//  switch) to the Mixed-reality visibility gate: scenes authored for Vision
//  Pro Mixed immersion stay out of the switcher pool on flat-display hosts
//  until the Settings → Display opt-in is enabled.
//

import Foundation
import Testing
@testable import Threshold

@MainActor
@Suite("Cue scene switcher Mixed-reality gating")
struct CueSceneSwitcherMixedRealityTests {
    private func keyframe(name: String, scale: Float, duration: TimeInterval = 1) -> AnimationKeyframe {
        AnimationKeyframe(
            name: name,
            duration: duration,
            minDistance: 0.8,
            foldingLimit: 1.0,
            sphereRadius: 0.5,
            fractalScale: 2.8,
            scale: scale,
            position: .zero
        )
    }

    private func animationScene(name: String, mixed: Bool) -> AnimationScene {
        var scene = AnimationScene(
            name: name,
            initialKeyframe: keyframe(name: "Start", scale: 2, duration: 0),
            fractalType: .mandelbox
        )
        scene.keyframes.append(keyframe(name: "End", scale: 4))
        scene.mixedModeScene = mixed
        return scene
    }

    private func staticPreset(id: UUID, name: String, mixed: Bool) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name)
        preset.mixedModeScene = mixed
        return preset
    }

    @Test("Mixed-reality scenes leave the switcher pool until opted in")
    func mixedTargetsFollowOptIn() {
        let mixedStaticID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let plainStaticID = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!

        let mixedKey = MixedRealitySceneCatalogSettings.defaultsKey
        let originalSetting = UserDefaults.standard.bool(forKey: mixedKey)
        defer { UserDefaults.standard.set(originalSetting, forKey: mixedKey) }

        // Start from the gated state so the import-time rebuild reflects it.
        UserDefaults.standard.set(false, forKey: mixedKey)

        let manager = AnimationManager()
        let mixedAnimation = manager.importScene(animationScene(name: "Mixed float", mixed: true))
        let plainAnimation = manager.importScene(animationScene(name: "Plain", mixed: false))

        let mixedStatic = staticPreset(id: mixedStaticID, name: "Passthrough static", mixed: true)
        let plainStatic = staticPreset(id: plainStaticID, name: "Plain static", mixed: false)
        manager.musicCueStaticSceneProvider = { [mixedStatic, plainStatic] }

        // Opted out: neither the animation library nor the static scene
        // library offers a Mixed-reality target.
        let gatedTargets = manager.musicCueGroupAvailableTargets

        #expect(!gatedTargets.contains {
            $0.kind == .animation && $0.sourceID == mixedAnimation.id
        })
        #expect(!gatedTargets.contains {
            $0.kind == .staticScene && $0.sourceID == mixedStaticID
        })
        #expect(gatedTargets.contains {
            $0.kind == .animation && $0.sourceID == plainAnimation.id
        })
        #expect(gatedTargets.contains {
            $0.kind == .staticScene && $0.sourceID == plainStaticID
        })

        // Opted in: the Settings toggle refreshes the animation-scene list,
        // and Mixed-reality targets surface from both libraries.
        UserDefaults.standard.set(true, forKey: mixedKey)
        manager.refreshSceneVisibility()
        let optedInTargets = manager.musicCueGroupAvailableTargets

        #expect(optedInTargets.contains {
            $0.kind == .animation && $0.sourceID == mixedAnimation.id
        })
        #expect(optedInTargets.contains {
            $0.kind == .staticScene && $0.sourceID == mixedStaticID
        })
    }

    @Test("A stale configured-group membership cannot keep a gated Mixed scene in the pool")
    func staleConfiguredGroupMembershipIsInert() {
        let mixedID = UUID(uuidString: "20000000-0000-0000-0000-000000000005")!
        let plainID = UUID(uuidString: "20000000-0000-0000-0000-000000000006")!

        // The Mixed target only ever reached the persisted group membership
        // while it was visible; once gated it is absent from the available
        // catalog, so group membership alone cannot resurrect it.
        let mixedTarget = MusicCueSceneTarget(
            kind: .animation,
            sourceID: mixedID,
            name: "Mixed float",
            detail: "2 keyframes"
        )
        let plainTarget = MusicCueSceneTarget(
            kind: .animation,
            sourceID: plainID,
            name: "Plain",
            detail: "2 keyframes"
        )

        let pool = MusicCueSceneGroupSequence.eligibleTargets(
            sources: [.configuredGroup],
            availableTargets: [plainTarget],
            configuredGroupTargetIDs: [mixedTarget.id, plainTarget.id]
        )

        #expect(pool.map(\.sourceID) == [plainID])
    }
}