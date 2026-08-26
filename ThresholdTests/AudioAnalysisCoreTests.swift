//
//  AudioAnalysisCoreTests.swift
//  ThresholdTests
//
//  Exercises the lock-protected DSP core directly: band routing, delivery-size
//  independence (the tap's buffer size must never dictate FFT behavior),
//  silence-gate hysteresis, onset reseeding after silence, staleness gating,
//  and strongest-channel selection.
//

import AVFoundation
import Foundation
import Testing
@testable import Threshold

#if os(macOS)
@Suite("macOS microphone preflight")
struct MacMicrophonePreflightTests {
    @Test("A missing HAL output component blocks AVAudioEngine access")
    func missingAudioComponent() {
        let failure = MacMicrophonePreflight.failure(
            hasHALOutputComponent: false,
            hasDefaultInputDevice: true
        )

        #expect(failure == .audioComponentUnavailable)
    }

    @Test("A missing default input device blocks AVAudioEngine access")
    func missingDefaultInputDevice() {
        let failure = MacMicrophonePreflight.failure(
            hasHALOutputComponent: true,
            hasDefaultInputDevice: false
        )

        #expect(failure == .noDefaultInputDevice)
    }

    @Test("Available audio services and input pass the preflight")
    func availableAudioInput() {
        let failure = MacMicrophonePreflight.failure(
            hasHALOutputComponent: true,
            hasDefaultInputDevice: true
        )

        #expect(failure == nil)
    }
}
#endif

@Suite("iOS microphone audio-session policy")
struct IOSMicrophoneAudioSessionPolicyTests {
    @Test("Microphone capture preserves music playback routes")
    func playbackRoutesArePreserved() {
        let options = IOSMicrophoneAudioSessionPolicy.playbackPreserving.routeOptions

        #expect(options.contains(.mixWithOthers))
        #expect(options.contains(.defaultToSpeaker))
        #expect(options.contains(.allowBluetoothA2DP))
        #expect(options.contains(.allowAirPlay))
    }

    @Test("Bluetooth capture never opts into the call-quality hands-free route")
    func handsFreeRouteIsExcluded() {
        let options = IOSMicrophoneAudioSessionPolicy.playbackPreserving.routeOptions

        #expect(!options.contains(.allowBluetoothHandsFree))
    }
}

@Suite("Audio analysis core")
struct AudioAnalysisCoreTests {

    private let sampleRate: Double = 48_000

    /// Build a Float32 PCM buffer whose per-channel content is produced by
    /// `sample(channel, frameIndex)`. Frame indices are global so chunked
    /// ingestion keeps phase continuity across buffers.
    private func makeBuffer(frames: Int,
                            channels: AVAudioChannelCount = 1,
                            startFrame: Int = 0,
                            rate: Double? = nil,
                            sample: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: rate ?? sampleRate,
                                   channels: channels,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![channel]
            for i in 0..<frames {
                ptr[i] = sample(channel, startFrame + i)
            }
        }
        return buffer
    }

    private func sineSample(frequency: Float, amplitude: Float) -> (Int, Int) -> Float {
        { _, frame in
            amplitude * sin(2 * .pi * frequency * Float(frame) / Float(self.sampleRate))
        }
    }

    /// Ingest `totalFrames` of a phase-continuous sine in `chunk`-frame buffers.
    private func ingestSine(into core: AudioAnalysisCore,
                            frequency: Float,
                            amplitude: Float,
                            totalFrames: Int,
                            chunk: Int) {
        var start = 0
        let sample = sineSample(frequency: frequency, amplitude: amplitude)
        while start < totalFrames {
            let frames = min(chunk, totalFrames - start)
            core.ingest(makeBuffer(frames: frames, startFrame: start, sample: sample))
            start += frames
        }
    }

    private func freshTargets(_ core: AudioAnalysisCore) -> AudioAnalysisCore.Targets? {
        core.consumeTargets(now: core.latestSampleTime)
    }

    @Test("A bass sine drives the bass band, not treble")
    func bassSineDrivesBassBand() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))
        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 8192, chunk: 1024)

        let targets = try #require(freshTargets(core))
        #expect(targets.overall > 0.2)
        #expect(targets.bass > 0.3)
        #expect(targets.treble < targets.bass * 0.3)
    }

    @Test("Mid and treble sines route to their bands")
    func midAndTrebleRouting() throws {
        let midCore = AudioAnalysisCore()
        midCore.activate(sampleRate: Float(sampleRate))
        ingestSine(into: midCore, frequency: 1000, amplitude: 0.25, totalFrames: 8192, chunk: 1024)
        let mid = try #require(freshTargets(midCore))
        #expect(mid.mid > mid.bass)
        #expect(mid.mid > mid.treble)

        let trebleCore = AudioAnalysisCore()
        trebleCore.activate(sampleRate: Float(sampleRate))
        ingestSine(into: trebleCore, frequency: 5000, amplitude: 0.25, totalFrames: 8192, chunk: 1024)
        let treble = try #require(freshTargets(trebleCore))
        #expect(treble.treble > treble.bass)
        #expect(treble.treble > treble.mid)
    }

    @Test("Deliveries smaller than the analysis window still produce band output")
    func smallBuffersStillProduceBands() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))
        // 640-frame chunks (e.g. a low-rate Bluetooth route's cadence) never
        // individually reach the 2048-frame window; the accumulator must.
        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 8192, chunk: 640)

        let targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)
    }

    @Test("Band output is independent of capture delivery size")
    func bufferSizeIndependence() throws {
        let smallChunks = AudioAnalysisCore()
        smallChunks.activate(sampleRate: Float(sampleRate))
        ingestSine(into: smallChunks, frequency: 250, amplitude: 0.2, totalFrames: 9600, chunk: 960)

        let bigChunks = AudioAnalysisCore()
        bigChunks.activate(sampleRate: Float(sampleRate))
        ingestSine(into: bigChunks, frequency: 250, amplitude: 0.2, totalFrames: 9600, chunk: 4800)

        let small = try #require(freshTargets(smallChunks))
        let big = try #require(freshTargets(bigChunks))
        #expect(abs(small.bass - big.bass) < 0.1)
        #expect(abs(small.mid - big.mid) < 0.1)
        #expect(abs(small.overall - big.overall) < 0.1)
    }

    @Test("Silence gate engages with hysteresis and does not flicker in the dead band")
    func silenceGateHysteresis() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))

        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 4096, chunk: 1024)
        var targets = try #require(freshTargets(core))
        #expect(targets.overall > 0)

        // 4096 consecutive silent samples (~85 ms at 48 kHz) engage the gate
        // (threshold: 80 ms of quiet, measured in samples so delivery size
        // cannot change the latency).
        for _ in 0..<4 {
            core.ingest(makeBuffer(frames: 1024) { _, _ in 0 })
        }
        targets = try #require(freshTargets(core))
        #expect(targets.overall == 0)
        #expect(targets.bass == 0)

        // Amplitude inside the hysteresis dead band must NOT reopen the gate.
        ingestSine(into: core, frequency: 60, amplitude: 0.0004, totalFrames: 4096, chunk: 1024)
        targets = try #require(freshTargets(core))
        #expect(targets.overall == 0)

        // Clearly audible signal reopens it immediately.
        ingestSine(into: core, frequency: 60, amplitude: 0.05, totalFrames: 4096, chunk: 1024)
        targets = try #require(freshTargets(core))
        #expect(targets.overall > 0)
    }

    @Test("Silence-gate latency is measured in samples, not delivery callbacks")
    func gateLatencyIsDeliverySizeIndependent() throws {
        // Small Bluetooth-style chunks: 1,920 quiet samples (3 × 640 ≈ 40 ms)
        // must NOT gate yet — under callback counting they would have.
        let smallChunks = AudioAnalysisCore()
        smallChunks.activate(sampleRate: Float(sampleRate))
        ingestSine(into: smallChunks, frequency: 60, amplitude: 0.25, totalFrames: 8192, chunk: 1024)
        for _ in 0..<3 {
            smallChunks.ingest(makeBuffer(frames: 640) { _, _ in 0 })
        }
        var targets = try #require(freshTargets(smallChunks))
        #expect(targets.bass > 0)   // gate still open, levels persist

        // Three more (3,840 total ≈ 80 ms) cross the duration threshold.
        for _ in 0..<3 {
            smallChunks.ingest(makeBuffer(frames: 640) { _, _ in 0 })
        }
        targets = try #require(freshTargets(smallChunks))
        #expect(targets.overall == 0)
        #expect(targets.bass == 0)

        // One jumbo iPad-style callback (4,800 quiet samples ≈ 100 ms) gates
        // on its own — same duration rule, one delivery.
        let bigChunks = AudioAnalysisCore()
        bigChunks.activate(sampleRate: Float(sampleRate))
        ingestSine(into: bigChunks, frequency: 60, amplitude: 0.25, totalFrames: 9600, chunk: 4800)
        bigChunks.ingest(makeBuffer(frames: 4800) { _, _ in 0 })
        targets = try #require(freshTargets(bigChunks))
        #expect(targets.overall == 0)
        #expect(targets.bass == 0)
    }

    @Test("Resuming audio after silence does not fire a phantom onset")
    func onsetReseededAfterGateExit() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))

        ingestSine(into: core, frequency: 200, amplitude: 0.2, totalFrames: 32 * 2048, chunk: 2048)
        _ = freshTargets(core)

        for _ in 0..<4 {
            core.ingest(makeBuffer(frames: 1024) { _, _ in 0 })
        }
        _ = freshTargets(core)

        // First analysis window after the gate reopens compares against a
        // reseeded spectrum, so a resume must not read as a "drop".
        ingestSine(into: core, frequency: 2000, amplitude: 0.3, totalFrames: 2048, chunk: 2048)
        let resumed = try #require(freshTargets(core))
        #expect(resumed.onset == 0)
    }

    @Test("Stale targets read as silence once ingestion stops")
    func staleTargetsReadAsSilence() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))
        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 8192, chunk: 1024)

        let live = try #require(core.consumeTargets(now: core.latestSampleTime))
        #expect(live.overall > 0)

        // A second consumer tick a full second later (tap stalled) must not
        // keep presenting the frozen levels.
        let stale = try #require(core.consumeTargets(now: core.latestSampleTime + 1.0))
        #expect(stale.overall == 0)
        #expect(stale.bass == 0)
    }

    @Test("Signal on a non-zero channel is analyzed (strongest-channel selection)")
    func strongestChannelSelection() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))

        // Hard-right-panned content: channel 0 silent, channel 1 carries a
        // bass sine. Analysis must follow the hot channel.
        var start = 0
        while start < 8192 {
            let buffer = makeBuffer(frames: 1024, channels: 2, startFrame: start) { channel, frame in
                channel == 1
                    ? 0.25 * sin(2 * .pi * 60 * Float(frame) / Float(self.sampleRate))
                    : 0
            }
            core.ingest(buffer)
            start += 1024
        }

        let targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)
        #expect(targets.overall > 0.2)
    }

    @Test("A loud window is not discarded by a quieter one in the same delivery")
    func multiWindowDeliveryKeepsLoudestWindow() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))

        // One 4096-frame delivery = two analysis windows: loud bass first,
        // near-silent (but above the gate) second. Band targets must reflect
        // the loud window, not whichever happened to be analyzed last.
        let buffer = makeBuffer(frames: 4096) { _, frame in
            let amplitude: Float = frame < 2048 ? 0.25 : 0.002
            return amplitude * sin(2 * .pi * 60 * Float(frame) / Float(self.sampleRate))
        }
        core.ingest(buffer)

        let targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)
    }

    @Test("Interleaved stereo buffers route the hot channel's signal")
    func interleavedBufferAnalysis() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))

        // Interleaved Float32 stereo with the bass sine on channel 1 only.
        // Exercises the stride/offset path that non-interleaved buffers skip.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 2,
                                   interleaved: true)!
        var start = 0
        while start < 8192 {
            let frames = 1024
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            let ptr = buffer.floatChannelData![0]
            for i in 0..<frames {
                let frame = start + i
                ptr[i * 2] = 0
                ptr[i * 2 + 1] = 0.25 * sin(2 * .pi * 60 * Float(frame) / Float(sampleRate))
            }
            core.ingest(buffer)
            start += frames
        }

        let targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)
        #expect(targets.overall > 0.2)
    }

    @Test("Non-finite samples read as silence and analysis recovers")
    func nonFiniteSamplesReadAsSilenceAndRecover() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))

        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 8192, chunk: 1024)
        var targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)

        // A corrupt buffer (possible after wake-from-sleep) must zero the
        // targets rather than propagate NaN into the envelopes.
        core.ingest(makeBuffer(frames: 1024) { _, i in i % 2 == 0 ? .nan : .infinity })
        targets = try #require(freshTargets(core))
        #expect(targets.overall == 0)
        #expect(targets.bass == 0)
        #expect(targets.overall.isFinite && targets.bass.isFinite &&
                targets.mid.isFinite && targets.treble.isFinite && targets.onset.isFinite)

        // Clean audio afterwards analyzes normally.
        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 8192, chunk: 1024)
        targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)
    }

    @Test("A mid-stream sample-rate change re-locks bands without a phantom onset")
    func midStreamSampleRateChange() throws {
        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))
        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 8192, chunk: 1024)
        var targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)

        // Device swap mid-capture: buffers now arrive at 44.1 kHz. The core
        // must follow the delivered rate — band boundaries re-lock — and the
        // discontinuity must not fire an onset (state resets, flux reseeds).
        let newRate = 44_100.0
        var start = 0
        while start < 4096 {
            let buffer = makeBuffer(frames: 1024, startFrame: start, rate: newRate) { _, frame in
                0.25 * sin(2 * .pi * 60 * Float(frame) / Float(newRate))
            }
            core.ingest(buffer)
            start += 1024
        }
        targets = try #require(freshTargets(core))
        #expect(targets.bass > 0.3)
        #expect(targets.onset == 0)
    }

    @Test("Inactive core returns no targets; deactivation clears state")
    func lifecycle() throws {
        let core = AudioAnalysisCore()
        #expect(core.consumeTargets(now: 1) == nil)

        core.activate(sampleRate: Float(sampleRate))
        ingestSine(into: core, frequency: 60, amplitude: 0.25, totalFrames: 4096, chunk: 1024)
        #expect(core.latestSampleTime > 0)

        core.deactivate()
        #expect(core.consumeTargets(now: 1) == nil)
        #expect(core.latestSampleTime == 0)
    }
}
