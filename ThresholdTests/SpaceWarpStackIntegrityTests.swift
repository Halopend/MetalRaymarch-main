//
//  SpaceWarpStackIntegrityTests.swift
//  ThresholdTests
//
//  The Transformations editor assumes one groupID names exactly ONE contiguous
//  run of the flat warp stack (StackUnit ForEach identity, group cards, and every
//  groupID-scoped mutation). In-app edits preserve that invariant, but scene and
//  preset JSON is external input — a hand-edited, merged, or foreign file can
//  repeat a groupID after an interloper op. These tests pin the decode-time heal
//  (`normalizingGroupContiguity`) and both file lanes that feed the live stack:
//  the canonical `sceneState.space.warpStack` and the legacy flat `spaceWarpOps`.
//

import Foundation
import Testing
@testable import Threshold

@Suite("Space warp stack integrity — split repeat groups")
struct SpaceWarpStackIntegrityTests {

    /// The editor's invariant: once a groupID's contiguous run ends, that id
    /// never appears again later in the stack.
    private func groupRunsAreContiguous(_ stack: [SpaceWarpOpValue]) -> Bool {
        var closed: Set<UUID> = []
        var current: UUID?
        for op in stack {
            if op.groupID != current {
                if let finished = current { closed.insert(finished) }
                current = op.groupID
                if let groupID = op.groupID, closed.contains(groupID) { return false }
            }
        }
        return true
    }

    private func groupedOp(_ kind: SpaceWarpKind, groupID: UUID,
                           iterations: Int = 4,
                           mode: SpaceWarpGroupMode = .mandelboxRecurrence) -> SpaceWarpOpValue {
        var op = SpaceWarpOpValue(kind: kind)
        op.groupID = groupID
        op.groupIterations = iterations
        op.groupMode = mode
        return op
    }

    // MARK: - normalizingGroupContiguity

    @Test("Split group heals: the later fragment becomes its own group")
    func healsSplitGroupIntoIndependentFragments() {
        let groupID = UUID()
        let stack = [
            groupedOp(.boxFold, groupID: groupID),
            SpaceWarpOpValue(kind: .twist),
            groupedOp(.sphereFold, groupID: groupID),
        ]

        let healed = stack.normalizingGroupContiguity()

        #expect(groupRunsAreContiguous(healed))
        // The first run keeps its file identity; only the orphaned fragment re-mints.
        #expect(healed[0].groupID == groupID)
        #expect(healed[1].groupID == nil)
        #expect(healed[2].groupID != nil)
        #expect(healed[2].groupID != groupID)
        // Healing renames groups — it must never reorder, drop, or edit the ops.
        #expect(healed.map(\.id) == stack.map(\.id))
        #expect(healed.map(\.kind) == stack.map(\.kind))
        #expect(healed[2].groupIterations == stack[2].groupIterations)
        #expect(healed[2].groupMode == stack[2].groupMode)
    }

    @Test("Every fragment re-mints independently — the heal cannot re-split itself")
    func healsEachFragmentToItsOwnGroup() {
        let groupID = UUID()
        let stack = [
            groupedOp(.boxFold, groupID: groupID),
            SpaceWarpOpValue(kind: .twist),
            groupedOp(.sphereFold, groupID: groupID),
            SpaceWarpOpValue(kind: .bend),
            groupedOp(.scale, groupID: groupID),
        ]

        let healed = stack.normalizingGroupContiguity()

        #expect(groupRunsAreContiguous(healed))
        // [G, x, G, y, G] must yield THREE distinct groups — a shared replacement
        // id would leave the last two fragments non-contiguous again.
        let runIDs = [healed[0].groupID, healed[2].groupID, healed[4].groupID].compactMap { $0 }
        #expect(Set(runIDs).count == 3)
    }

    @Test("Interleaved groups heal without touching each first run")
    func healsInterleavedGroups() {
        let groupA = UUID()
        let groupB = UUID()
        let stack = [
            groupedOp(.boxFold, groupID: groupA),
            groupedOp(.sphereFold, groupID: groupB),
            groupedOp(.scale, groupID: groupA),
            groupedOp(.twist, groupID: groupB),
        ]

        let healed = stack.normalizingGroupContiguity()

        #expect(groupRunsAreContiguous(healed))
        #expect(healed[0].groupID == groupA)
        #expect(healed[1].groupID == groupB)
        #expect(healed[2].groupID != groupA)
        #expect(healed[3].groupID != groupB)
    }

    @Test("Well-formed stacks pass through byte-identical")
    func leavesWellFormedStacksUntouched() {
        let groupID = UUID()
        let stack = [
            groupedOp(.boxFold, groupID: groupID),
            groupedOp(.sphereFold, groupID: groupID),
            groupedOp(.scale, groupID: groupID),
            SpaceWarpOpValue(kind: .twist),
            groupedOp(.kaleidoscope, groupID: UUID(), iterations: 2, mode: .repeatOutput),
        ]

        #expect(stack.normalizingGroupContiguity() == stack)
        #expect([SpaceWarpOpValue]().normalizingGroupContiguity().isEmpty)
    }

    @Test("A multi-op fragment stays one group after healing")
    func keepsFragmentOpsTogether() {
        let groupID = UUID()
        let stack = [
            groupedOp(.boxFold, groupID: groupID),
            SpaceWarpOpValue(kind: .twist),
            groupedOp(.sphereFold, groupID: groupID),
            groupedOp(.scale, groupID: groupID),
        ]

        let healed = stack.normalizingGroupContiguity()

        #expect(groupRunsAreContiguous(healed))
        #expect(healed[2].groupID == healed[3].groupID)
        #expect(healed[2].groupID != groupID)
    }

    // MARK: - Decode choke points

    @Test("SceneState decode heals a split group in the canonical warp stack")
    func sceneStateDecodeHealsSplitGroups() throws {
        let groupID = UUID()
        var state = SceneState()
        state.space.warpStack = [
            groupedOp(.boxFold, groupID: groupID),
            SpaceWarpOpValue(kind: .twist),
            groupedOp(.sphereFold, groupID: groupID),
        ]

        let decoded = try JSONDecoder().decode(SceneState.self,
                                               from: try JSONEncoder().encode(state))

        #expect(groupRunsAreContiguous(decoded.space.warpStack))
        #expect(decoded.space.warpStack.map(\.id) == state.space.warpStack.map(\.id))
        #expect(decoded.space.warpStack[0].groupID == groupID)
        #expect(decoded.space.warpStack[2].groupID != groupID)
    }

    @Test("Preset decode heals both the canonical and the legacy flat warp lanes")
    func presetDecodeHealsBothWarpLanes() throws {
        let groupID = UUID()
        let split = [
            groupedOp(.boxFold, groupID: groupID),
            SpaceWarpOpValue(kind: .twist),
            groupedOp(.sphereFold, groupID: groupID),
        ]
        let source = RenderSettings()
        source.withPersistenceSuppressed {
            source.spaceWarpStack = split
        }
        let preset = FractalPreset.fromSettings(source, name: "Split Group")

        let decoded = try JSONDecoder().decode(FractalPreset.self,
                                               from: try JSONEncoder().encode(preset))

        #expect(groupRunsAreContiguous(decoded.spaceWarpOps ?? []))
        #expect(groupRunsAreContiguous(decoded.sceneState?.space.warpStack ?? []))
        #expect(decoded.spaceWarpOps?.count == split.count)

        // End to end: applying the decoded preset must hand the editor a stack
        // that satisfies its contiguity invariant, with nothing lost or reordered.
        let destination = RenderSettings()
        decoded.apply(to: destination, includePerformance: false, scope: .session)
        #expect(groupRunsAreContiguous(destination.spaceWarpStack))
        #expect(destination.spaceWarpStack.map(\.kind) == split.map(\.kind))
        #expect(destination.spaceWarpStack.map(\.id) == split.map(\.id))
    }
}
