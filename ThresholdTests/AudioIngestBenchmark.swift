//
//  AudioIngestBenchmark.swift
//  ThresholdTests
//
//  Informational micro-benchmark for the capture-thread ingest path. Prints
//  wall time for a fixed workload; makes no pass/fail assertion (CI timing is
//  not stable evidence — see the repo's perf protocol). Run before and after
//  DSP changes on the same machine and record the pair in PERF_LOG.md.
//

import AVFoundation
import Foundation
import Testing
@testable import Threshold

@Suite("Audio ingest micro-benchmark")
struct AudioIngestBenchmark {

    @Test("Time 8-channel interleaved worst-case ingest (informational)")
    func ingestWorstCaseTiming() {
        let sampleRate = 48_000.0
        let channels: AVAudioChannelCount = 8
        let frames = 1024
        let iterations = 2_000

        // >2 channels need an explicit layout; the 1-2 channel convenience
        // init returns nil for 8.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   interleaved: true,
                                   channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let ptr = buffer.floatChannelData![0]
        for frame in 0..<frames {
            for channel in 0..<Int(channels) {
                // Strongest signal on channel 5, quiet noise elsewhere.
                let base = sin(2 * Float.pi * 60 * Float(frame) / Float(sampleRate))
                ptr[frame * Int(channels) + channel] = channel == 5 ? 0.25 * base : 0.001 * base
            }
        }

        let core = AudioAnalysisCore()
        core.activate(sampleRate: Float(sampleRate))
        // Warm-up: allocations, band locks, first windows.
        for _ in 0..<50 { core.ingest(buffer) }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<iterations {
                core.ingest(buffer)
            }
        }
        let totalSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
        let perBufferMicros = totalSeconds * 1e6 / Double(iterations)
        print("AUDIO_INGEST_BENCH: \(iterations) ingests of \(frames)f x \(channels)ch " +
              "took \(elapsed); \(String(format: "%.1f", perBufferMicros)) µs/buffer")
        #expect(core.latestSampleTime > 0)
    }
}
