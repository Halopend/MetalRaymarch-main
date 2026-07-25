import Foundation
import simd
import Testing
@testable import Threshold

@Suite("Gesture engine replay")
struct GestureEngineReplayTests {
    private func pinchingHands(distance: Float, pinch: Float = 1) -> GestureContext {
        var left = HandData.zero
        left.isTracked = true
        left.thumbTip = SIMD3<Float>(-distance * 0.5, 1, 0)
        left.indexTip = left.thumbTip
        left.middleTip = left.thumbTip
        left.ringTip = left.thumbTip
        left.palmPosition = left.thumbTip
        left.indexPinch = pinch
        left.middlePinch = pinch
        left.ringPinch = pinch

        var right = HandData.zero
        right.isTracked = true
        right.thumbTip = SIMD3<Float>(distance * 0.5, 1, 0)
        right.indexTip = right.thumbTip
        right.middleTip = right.thumbTip
        right.ringTip = right.thumbTip
        right.palmPosition = right.thumbTip
        right.indexPinch = pinch
        right.middlePinch = pinch
        right.ringPinch = pinch
        return GestureContext(leftHand: left, rightHand: right, deltaTime: 1 / 90)
    }

    @Test("two-hand scalar activates, changes, and releases")
    func scalarTrace() {
        let engine = TwoHandScalarGestureEngine()
        let initial = engine.process(
            digit: 1,
            context: pinchingHands(distance: 0.20),
            leftHandStable: true,
            currentTarget: 1,
            range: 0...10,
            parameterID: nil,
            useRelativeGestures: true,
            detailScale: 1
        )
        let changed = engine.process(
            digit: 1,
            context: pinchingHands(distance: 0.30),
            leftHandStable: true,
            currentTarget: 1,
            range: 0...10,
            parameterID: nil,
            useRelativeGestures: true,
            detailScale: 1
        )
        let released = engine.process(
            digit: 1,
            context: pinchingHands(distance: 0.30, pinch: 0),
            leftHandStable: true,
            currentTarget: changed.value ?? 1,
            range: 0...10,
            parameterID: nil,
            useRelativeGestures: true,
            detailScale: 1
        )

        #expect(initial.isActive)
        #expect((changed.value ?? 0) > (initial.value ?? 0))
        #expect(!released.isActive)
        #expect(released.value == nil)
    }

    @Test("grab engine preserves 1:1 scale ratio")
    func grabTrace() {
        let engine = TwoPointGrabGestureEngine()
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        _ = engine.process(
            digit: 1,
            context: pinchingHands(distance: 0.20),
            leftHandStable: true,
            startPosition: SIMD3<Float>(0, 0, -2),
            startRotation: identity,
            startDetailScale: 2,
            scaleClamp: 0.001...500
        )
        let changed = engine.process(
            digit: 1,
            context: pinchingHands(distance: 0.30),
            leftHandStable: true,
            startPosition: .zero,
            startRotation: identity,
            startDetailScale: 2,
            scaleClamp: 0.001...500
        )

        #expect(changed.isActive)
        #expect(abs((changed.transform?.detailScale ?? 0) - 3) < 0.001)
    }

    @Test("arm slider emits typed live and persistence mutations")
    func armSliderTrace() {
        let engine = ArmSliderGestureEngine()
        var left = HandData.zero
        left.isTracked = true
        left.forearmTracked = true
        left.forearmElbow = SIMD3<Float>(0, 1, 0)
        left.forearmWrist = SIMD3<Float>(0, 1.30, 0)
        var right = HandData.zero
        right.isTracked = true
        right.indexTip = SIMD3<Float>(0.01, 1.15, 0)

        var liveMutations: [GestureRenderMutation] = []
        let liveCompleted = engine.process(
            context: GestureContext(leftHand: left, rightHand: right, deltaTime: 1 / 90),
            parametersSuppressed: false,
            grabActive: false,
            geometryGestureActive: false,
            renderMutations: &liveMutations
        )
        var releaseMutations: [GestureRenderMutation] = []
        let released = engine.process(
            context: GestureContext(leftHand: left, rightHand: .zero, deltaTime: 1 / 90),
            parametersSuppressed: false,
            grabActive: false,
            geometryGestureActive: false,
            renderMutations: &releaseMutations
        )

        guard case .setFractalAudioAmount(let amount) = liveMutations.first else {
            Issue.record("Expected an audio-amount mutation")
            return
        }
        #expect(!liveCompleted)
        #expect(abs(amount - 0.5) < 0.05)
        #expect(releaseMutations.contains {
            if case .persistAudioReactive = $0 { return true }
            return false
        })
        #expect(released)
    }

    @Test("processor batches parameters and leaves application to render worker")
    func processorReturnsParameterBatch() async {
        let settings = RenderSettings()
        settings.setBinding(
            .core(.fractalScale),
            for: GestureSlot(hand: .both, finger: .index)
        )
        let pipeline = ParameterPipeline()
        let processor = GestureProcessor(
            renderSettings: settings,
            parameterPipeline: pipeline
        )

        for frame in 0..<29 {
            let context = pinchingHands(distance: 0.20, pinch: 0)
            _ = await processor.process(
                HandPoseSnapshot(
                    leftHand: context.leftHand,
                    rightHand: context.rightHand,
                    timestamp: Double(frame) / 90,
                    deltaTime: 1 / 90
                )
            )
        }
        let start = pinchingHands(distance: 0.20)
        _ = await processor.process(
            HandPoseSnapshot(
                leftHand: start.leftHand,
                rightHand: start.rightHand,
                timestamp: 29 / 90,
                deltaTime: 1 / 90
            )
        )
        let moved = pinchingHands(distance: 0.30)
        let output = await processor.process(
            HandPoseSnapshot(
                leftHand: moved.leftHand,
                rightHand: moved.rightHand,
                timestamp: 30 / 90,
                deltaTime: 1 / 90
            )
        )

        #expect(output.parameterOperations.contains {
            $0.targetID == ParameterTargetID.Core.fractalScale
        })
        #expect(output.commands.isEmpty)
    }

    @Test("recovery menu still runs while parameters are suppressed")
    func recoveryDuringSuppression() async {
        let settings = RenderSettings()
        let processor = GestureProcessor(
            renderSettings: settings,
            parameterPipeline: ParameterPipeline()
        )
        await processor.setParameterGesturesSuppressed(true)

        var right = HandData.zero
        right.isTracked = true
        right.palmCenter = SIMD3<Float>(0, 1, 0)
        right.middleTip = SIMD3<Float>(0, 1.01, 0)
        right.ringTip = SIMD3<Float>(0.01, 1, 0)
        let snapshot = HandPoseSnapshot(
            leftHand: .zero,
            rightHand: right,
            timestamp: 1,
            deltaTime: 1
        )
        _ = await processor.process(snapshot)
        let output = await processor.process(
            HandPoseSnapshot(
                leftHand: .zero,
                rightHand: right,
                timestamp: 2,
                deltaTime: 1
            )
        )

        #expect(output.commands.contains(.toggleRadialMenu))
        #expect(output.menuActivationHand == .right)
        #expect(output.diagnostics.parametersSuppressed)
        #expect(output.parameterOperations.isEmpty)
    }

    @Test("recovery pose owns parameter gestures from its debounce frame")
    func recoveryOwnsActivationFrames() async {
        let settings = RenderSettings()
        settings.menuToggleGestureEnabled = true
        settings.menuToggleGestureMode = .middleAndRingToPalm
        settings.setBinding(
            .core(.fractalScale),
            for: GestureSlot(hand: .both, finger: .index)
        )
        let processor = GestureProcessor(
            renderSettings: settings,
            parameterPipeline: ParameterPipeline()
        )

        var left = HandData.zero
        left.isTracked = true
        left.thumbTip = SIMD3<Float>(-0.10, 1, 0)
        left.indexTip = left.thumbTip
        left.indexPinch = 1

        var right = HandData.zero
        right.isTracked = true
        right.thumbTip = SIMD3<Float>(0.10, 1, 0)
        right.indexTip = right.thumbTip
        right.indexPinch = 1
        right.palmCenter = SIMD3<Float>(0.10, 1, 0)
        right.middleTip = SIMD3<Float>(0.10, 1.20, 0)
        right.ringTip = SIMD3<Float>(0.10, 1.20, 0)

        for frame in 0..<30 {
            _ = await processor.process(
                HandPoseSnapshot(
                    leftHand: left,
                    rightHand: right,
                    timestamp: Double(frame) / 90,
                    deltaTime: 1 / 90
                )
            )
        }

        right.middleTip = SIMD3<Float>(0.10, 1.01, 0)
        right.ringTip = SIMD3<Float>(0.11, 1, 0)
        let first = await processor.process(
            HandPoseSnapshot(
                leftHand: left,
                rightHand: right,
                timestamp: 30 / 90,
                deltaTime: 1
            )
        )
        let second = await processor.process(
            HandPoseSnapshot(
                leftHand: left,
                rightHand: right,
                timestamp: 31 / 90,
                deltaTime: 1
            )
        )

        #expect(first.parameterOperations.isEmpty)
        #expect(first.renderMutations.isEmpty)
        #expect(second.parameterOperations.isEmpty)
        #expect(second.renderMutations.isEmpty)
        #expect(second.commands == [.toggleRadialMenu])
    }

    @Test("neutral synthetic trace stays within processing budget")
    func processingBudget() async {
        let processor = GestureProcessor(
            renderSettings: RenderSettings(),
            parameterPipeline: ParameterPipeline()
        )
        var durations: [UInt64] = []
        durations.reserveCapacity(256)
        for frame in 0..<272 {
            let output = await processor.process(
                HandPoseSnapshot(
                    leftHand: .zero,
                    rightHand: .zero,
                    timestamp: Double(frame) / 90,
                    deltaTime: 1 / 90
                )
            )
            if frame >= 16 {
                durations.append(output.diagnostics.processingDurationNanoseconds)
            }
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count - 1) * 0.95)]
        #if DEBUG
        #expect(p95 < 5_000_000)
        #else
        #expect(p95 < 1_000_000)
        #endif
    }
}
