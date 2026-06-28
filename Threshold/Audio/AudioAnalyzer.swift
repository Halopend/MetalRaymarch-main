//
//  AudioAnalyzer.swift
//  Threshold
//
//  Captures microphone input and provides audio levels for reactive lighting.
//  Uses FFT for proper frequency band separation (bass, mids, treble).
//

import AVFoundation
import Accelerate

/// Analyzes audio input and provides normalized level values for visual effects
@MainActor
@Observable
class AudioAnalyzer {
    
    // MARK: - Public Properties
    
    /// Current audio level (0-1), smoothed for visual appeal
    /// @ObservationIgnored + nonisolated(unsafe) allows reading from render thread
    @ObservationIgnored nonisolated(unsafe) private(set) var level: Float = 0.0
    
    /// Bass level (low frequencies 20-250Hz) - good for deep pulses
    @ObservationIgnored nonisolated(unsafe) private(set) var bassLevel: Float = 0.0
    
    /// Mid level (250Hz-2kHz) - vocals and instruments
    @ObservationIgnored nonisolated(unsafe) private(set) var midLevel: Float = 0.0
    
    /// Treble level (high frequencies 2k-8kHz) - good for sparkles
    @ObservationIgnored nonisolated(unsafe) private(set) var trebleLevel: Float = 0.0

    /// Onset / "Drop" strength (0–1) from spectral flux. Near-zero most of the
    /// time, spikes hard on a transient or a big musical punctuation (the drop).
    /// This is the real signal behind the "Drop" reactive source — unlike the
    /// old peak-envelope, it actually fires on hits, not on loudness.
    @ObservationIgnored nonisolated(unsafe) private(set) var onsetLevel: Float = 0.0

    /// Whether any audio capture source is active.
    @ObservationIgnored nonisolated(unsafe) private(set) var isCapturing: Bool = false

    /// Whether the microphone capture path is active.
    @ObservationIgnored nonisolated(unsafe) private(set) var isMicrophoneCapturing: Bool = false

    /// Whether an external PCM source (whole-system output minus this process,
    /// captured via ScreenCaptureKit) is active. Read only within AudioAnalyzer.
    @ObservationIgnored nonisolated(unsafe) private var isExternalCapturing: Bool = false
    
    // Pending MainActor dispatch batching — avoids creating ~86 Tasks/sec
    @ObservationIgnored nonisolated(unsafe) private var pendingLevelDispatch = false
    @ObservationIgnored nonisolated(unsafe) private var pendingOverall: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingBass: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingMid: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingTreble: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingOnset: Float = 0

    /// Error message if capture fails
    private(set) var errorMessage: String?
    
    // MARK: - Private Properties
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    
    // FFT setup
    private var fftSetup: vDSP_DFT_Setup?
    private let fftSize: Int = 2048
    private var sampleRate: Float = 44100.0
    
    // Buffers for FFT
    private var realBuffer: [Float] = []
    private var imagBuffer: [Float] = []
    private var magnitudeBuffer: [Float] = []
    private var windowBuffer: [Float] = []

    // Spectral-flux onset detection state (drives onsetLevel / the "Drop" source)
    private var prevMagnitudeBuffer: [Float] = []   // last frame's spectrum
    private var fluxBaseline: Float = 0             // EMA of recent flux = adaptive threshold
    private var fluxFrameCount: Int = 0             // warm-up guard so startup doesn't false-trigger
    
    // Precomputed band boundary indices (set once in setupFFT, reused per frame)
    private var bassStartBin: Int = 0
    private var bassEndBin: Int = 0
    private var midStartBin: Int = 0
    private var midEndBin: Int = 0
    private var trebleStartBin: Int = 0
    private var trebleEndBin: Int = 0
    
    // Frame-rate independent smoothing speeds
    private let attackSpeed: Float = 40.0      // Fast attack for responsiveness
    private let decaySpeed: Float = 12.0       // Moderate decay
    private let bandAttackSpeed: Float = 35.0  // Band-specific attack
    private let bandDecaySpeed: Float = 10.0   // Band-specific decay
    private let onsetDecaySpeed: Float = 6.0   // Drop envelope fall (~0.17s) — instant attack, fast decay
    
    // Cached smoothing factors — avoids 4 exp() calls per frame when dt is stable
    private var cachedDT: Float = 0
    private var cachedAttackFactor: Float = 0
    private var cachedDecayFactor: Float = 0
    private var cachedBandAttackFactor: Float = 0
    private var cachedBandDecayFactor: Float = 0
    
    private func refreshSmoothingFactors(_ dt: Float) {
        if abs(dt - cachedDT) < 0.001 { return }
        cachedDT = dt
        cachedAttackFactor = 1.0 - exp(-attackSpeed * dt)
        cachedDecayFactor = 1.0 - exp(-decaySpeed * dt)
        cachedBandAttackFactor = 1.0 - exp(-bandAttackSpeed * dt)
        cachedBandDecayFactor = 1.0 - exp(-bandDecaySpeed * dt)
    }
    
    // Gain and sensitivity
    private let inputGain: Float = 25.0        // Amplify quiet input
    private let bassBoost: Float = 1.5         // Bass needs more boost
    private let trebleBoost: Float = 1.2       // Treble boost
    private let silenceRMSFloor: Float = 0.0015
    
    // Timestamp for frame-rate independent smoothing
    private var lastUpdateTime: CFTimeInterval = 0
    
    // MARK: - Initialization
    
    init() {
        setupFFT()
    }
    
    // MARK: - Public Methods
    
    /// Start capturing audio from the default input device
    func startCapture() {
        guard !isMicrophoneCapturing else { return }
        errorMessage = nil
        
        Task {
            let permission = await checkMicrophonePermission()
            if permission {
                await MainActor.run {
                    setupAudioCapture()
                }
            } else {
                await MainActor.run {
                    #if os(macOS)
                    errorMessage = "Microphone access denied. Enable Threshold in System Settings -> Privacy & Security -> Microphone. If you recently changed the bundle identifier, macOS treats it as a new app and you must re-enable access."
                    #else
                    errorMessage = "Microphone access denied. Enable in Settings."
                    #endif
                }
            }
        }
    }
    
    /// Stop capturing audio
    func stopCapture() {
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        inputNode = nil
        isMicrophoneCapturing = false
        refreshCaptureState(resetLevelsWhenIdle: true)
    }

    // MARK: - External PCM Ingestion
    //
    // Allows alternate capture backends (e.g. ScreenCaptureKit capturing
    // the native Music.app window on macOS) to feed PCM into the same
    // FFT pipeline used by the microphone path.

    /// Mark the analyzer as actively receiving samples from an external source.
    /// Recomputes band indices if the source's sample rate differs from the
    /// last-known rate.
    func beginExternalCapture(sampleRate externalSampleRate: Double) {
        let rate = Float(externalSampleRate)
        if rate > 0, abs(rate - sampleRate) > 1 {
            sampleRate = rate
            computeBandIndices()
        }
        isExternalCapturing = true
        refreshCaptureState()
        errorMessage = nil
    }

    /// Stop external ingestion and decay levels back to zero.
    func endExternalCapture() {
        isExternalCapturing = false
        refreshCaptureState(resetLevelsWhenIdle: true)
    }

    /// Feed an externally-captured PCM buffer into the FFT pipeline.
    /// Caller must guarantee the buffer is owned (not referencing borrowed
    /// memory from a CMSampleBuffer); see `SystemAudioTapCapture` for the
    /// copying delegate used on macOS.
    func ingestExternalBuffer(_ buffer: AVAudioPCMBuffer) {
        processAudioBuffer(buffer)
    }

    // MARK: - Private Methods
    
    private func setupFFT() {
        // Create FFT setup for real-to-complex DFT
        fftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(fftSize),
            .FORWARD
        )
        
        // Allocate buffers
        realBuffer = [Float](repeating: 0, count: fftSize)
        imagBuffer = [Float](repeating: 0, count: fftSize)
        magnitudeBuffer = [Float](repeating: 0, count: fftSize / 2)
        prevMagnitudeBuffer = [Float](repeating: 0, count: fftSize / 2)
        
        // Create Hann window for better frequency resolution
        windowBuffer = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&windowBuffer, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        
        // Precompute frequency band bin indices (avoids per-frame recalculation)
        computeBandIndices()
    }
    
    /// Recompute band boundary indices from current sampleRate and fftSize.
    /// Called once at setup and again if sampleRate changes.
    private func computeBandIndices() {
        let halfSize = fftSize / 2
        let binWidth = sampleRate / Float(fftSize)
        bassStartBin = max(1, Int(20.0 / binWidth))
        bassEndBin = min(halfSize - 1, Int(250.0 / binWidth))
        midStartBin = bassEndBin + 1
        midEndBin = min(halfSize - 1, Int(2000.0 / binWidth))
        trebleStartBin = midEndBin + 1
        trebleEndBin = min(halfSize - 1, Int(8000.0 / binWidth))
    }
    
    private func checkMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
    
    private func setupAudioCapture() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        
        guard format.sampleRate > 0 else {
            errorMessage = "No audio input available"
            return
        }
        
        sampleRate = Float(format.sampleRate)
        
        // Recompute band indices for the actual hardware sample rate
        computeBandIndices()
        
        // Use larger buffer for FFT analysis
        input.installTap(onBus: 0,
                         bufferSize: AVAudioFrameCount(fftSize),
                         format: format,
                         block: makeMicrophoneTapHandler())
        
        do {
            try engine.start()
            self.audioEngine = engine
            self.inputNode = input
            self.isMicrophoneCapturing = true
            self.refreshCaptureState()
            self.errorMessage = nil
        } catch {
            self.isMicrophoneCapturing = false
            self.refreshCaptureState(resetLevelsWhenIdle: true)
            self.errorMessage = "Failed to start audio: \(error.localizedDescription)"
        }
    }

    private nonisolated func makeMicrophoneTapHandler() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            guard let ownedBuffer = Self.makeOwnedPCMBufferCopy(buffer) else { return }
            let payload = SendablePCMBuffer(buffer: ownedBuffer)

            Task { @MainActor [weak self] in
                self?.processAudioBuffer(payload.buffer)
            }
        }
    }

    private nonisolated static func makeOwnedPCMBufferCopy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.format.commonFormat == .pcmFormatFloat32,
              let sourceChannels = source.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength),
              let destinationChannels = copy.floatChannelData else {
            return nil
        }

        copy.frameLength = source.frameLength

        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)

        if source.format.isInterleaved {
            let byteCount = frameCount * channelCount * MemoryLayout<Float>.size
            memcpy(destinationChannels[0], sourceChannels[0], byteCount)
        } else {
            let byteCount = frameCount * MemoryLayout<Float>.size
            for channel in 0..<channelCount {
                memcpy(destinationChannels[channel], sourceChannels[channel], byteCount)
            }
        }

        return copy
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData,
              let fftSetup = fftSetup else { return }
        
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        
        let samples = channelData[0]
        
        // Calculate RMS for overall level
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameLength))

        // ScreenCaptureKit and microphones both produce a small idle noise floor.
        // Gate it here so paused music and silent rooms decay to zero instead of flickering.
        if rms < silenceRMSFloor {
            pendingOverall = 0
            pendingBass = 0
            pendingMid = 0
            pendingTreble = 0
            pendingOnset = 0
            if !pendingLevelDispatch {
                pendingLevelDispatch = true
                Task { @MainActor in
                    self.drainPendingLevels()
                }
            }
            return
        }
        
        // Apply gain and compress
        let normalizedLevel = min(1.0, compressLevel(rms * inputGain))
        
        // Perform FFT analysis for frequency bands
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0

        // Reset each buffer; only a real flux computation (below) raises it.
        // Prevents a stale onset re-latching when a short buffer skips the FFT.
        pendingOnset = 0
        
        if frameLength >= fftSize {
            // Copy and window the samples
            var windowedSamples = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(samples, vDSP_Stride(1), windowBuffer, vDSP_Stride(1), &windowedSamples, vDSP_Stride(1), vDSP_Length(fftSize))
            
            // Prepare for FFT (real input)
            var realInput = windowedSamples
            var imagInput = [Float](repeating: 0, count: fftSize)
            
            // Execute FFT
            vDSP_DFT_Execute(fftSetup, &realInput, &imagInput, &realBuffer, &imagBuffer)
            
            // Calculate magnitudes for first half (positive frequencies)
            let halfSize = fftSize / 2
            realBuffer.withUnsafeMutableBufferPointer { realPtr in
                imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_zvabs(&splitComplex, vDSP_Stride(1), &magnitudeBuffer, vDSP_Stride(1), vDSP_Length(halfSize))
                }
            }
            
            // Normalize magnitudes
            var scale: Float = 2.0 / Float(fftSize)
            vDSP_vsmul(magnitudeBuffer, 1, &scale, &magnitudeBuffer, 1, vDSP_Length(halfSize))
            
            // Use precomputed band boundary indices
            let bassStart = bassStartBin
            let bassEnd = bassEndBin
            let midStart = midStartBin
            let midEnd = midEndBin
            let trebleStart = trebleStartBin
            let trebleEnd = trebleEndBin
            
            // Sum magnitudes in each band
            if bassEnd > bassStart {
                var bassSum: Float = 0
                vDSP_sve(&magnitudeBuffer[bassStart], 1, &bassSum, vDSP_Length(bassEnd - bassStart))
                bass = bassSum / Float(bassEnd - bassStart) * bassBoost
            }
            
            if midEnd > midStart {
                var midSum: Float = 0
                vDSP_sve(&magnitudeBuffer[midStart], 1, &midSum, vDSP_Length(midEnd - midStart))
                mid = midSum / Float(midEnd - midStart)
            }
            
            if trebleEnd > trebleStart {
                var trebleSum: Float = 0
                vDSP_sve(&magnitudeBuffer[trebleStart], 1, &trebleSum, vDSP_Length(trebleEnd - trebleStart))
                treble = trebleSum / Float(trebleEnd - trebleStart) * trebleBoost
            }
            
            // Apply gain and compression to bands
            bass = min(1.0, compressLevel(bass * inputGain))
            mid = min(1.0, compressLevel(mid * inputGain))
            treble = min(1.0, compressLevel(treble * inputGain))

            // ── Spectral-flux onset detection (the "Drop" signal) ──
            // Sum of positive per-bin magnitude *increases* vs the previous
            // frame: a transient/drop raises many bins at once → large flux,
            // while sustained sound has near-zero flux. An EMA baseline acts as
            // an adaptive threshold so only above-average jumps register, making
            // the detector level-independent. Tuning knobs (threshold 1.5×,
            // gain 0.6) are intentionally conservative — refine on-device.
            if prevMagnitudeBuffer.count == halfSize {
                var flux: Float = 0
                let fluxEnd = max(2, min(halfSize, trebleEndBin))  // ignore very-high noise bins
                for i in 1..<fluxEnd {
                    let d = magnitudeBuffer[i] - prevMagnitudeBuffer[i]
                    if d > 0 { flux += d }
                }
                fluxFrameCount += 1
                if fluxFrameCount == 1 {
                    fluxBaseline = flux                               // seed at the right magnitude (no startup over-trigger)
                } else {
                    fluxBaseline = fluxBaseline * 0.96 + flux * 0.04  // slow EMA: a spike barely moves the threshold it's measured against
                }
                if fluxFrameCount > 8 {  // warm-up so startup doesn't false-trigger
                    let excess = max(0, flux - fluxBaseline * 1.5)
                    pendingOnset = min(1.0, excess / max(fluxBaseline, 1e-3) * 0.6)
                }
                // Stash this frame's spectrum for next frame's comparison.
                prevMagnitudeBuffer.withUnsafeMutableBufferPointer { dst in
                    magnitudeBuffer.withUnsafeBufferPointer { src in
                        dst.baseAddress!.update(from: src.baseAddress!, count: halfSize)
                    }
                }
            }
        }

        // Batch level updates: store latest values, dispatch to MainActor only if no dispatch is pending
        pendingOverall = normalizedLevel
        pendingBass = bass
        pendingMid = mid
        pendingTreble = treble
        if !pendingLevelDispatch {
            pendingLevelDispatch = true
            Task { @MainActor in
                self.drainPendingLevels()
            }
        }
    }
    
    /// Soft compression to make quiet sounds more visible without clipping loud sounds
    private func compressLevel(_ x: Float) -> Float {
        // Soft knee compression: x / (1 + x) with gain
        // Maps 0-inf to 0-1 range, with most interesting range in 0-0.8
        return x / (0.5 + x)
    }
    
    private func drainPendingLevels() {
        pendingLevelDispatch = false
        updateLevels(overall: pendingOverall, bass: pendingBass, mid: pendingMid, treble: pendingTreble, onset: pendingOnset)
    }

    private func updateLevels(overall: Float, bass: Float, mid: Float, treble: Float, onset: Float) {
        let currentTime = CACurrentMediaTime()
        let deltaTime = lastUpdateTime > 0 ? Float(currentTime - lastUpdateTime) : Float(1.0 / 60.0)
        lastUpdateTime = currentTime
        
        let clampedDT = max(0.001, min(0.1, deltaTime))
        refreshSmoothingFactors(clampedDT)
        
        // Smooth overall level (fast attack, slow decay)
        if overall > level {
            level = level + (overall - level) * cachedAttackFactor
        } else {
            level = level + (overall - level) * cachedDecayFactor
        }

        // Smooth frequency bands with attack/decay
        smoothBand(&bassLevel, target: bass, dt: clampedDT)
        smoothBand(&midLevel, target: mid, dt: clampedDT)
        smoothBand(&trebleLevel, target: treble, dt: clampedDT)

        // Onset/"Drop": instant attack (snap to the spike), fast linear decay so
        // it reads as a discrete hit rather than a sustained level.
        if onset > onsetLevel {
            onsetLevel = onset
        } else {
            onsetLevel = max(0, onsetLevel - onsetDecaySpeed * clampedDT)
        }
    }
    
    private func smoothBand(_ current: inout Float, target: Float, dt: Float) {
        if target > current {
            current = current + (target - current) * cachedBandAttackFactor
        } else {
            current = current + (target - current) * cachedBandDecayFactor
        }
    }

    private func refreshCaptureState(resetLevelsWhenIdle: Bool = false) {
        isCapturing = isMicrophoneCapturing || isExternalCapturing
        if resetLevelsWhenIdle, !isCapturing {
            resetLevels()
        }
    }

    private func resetLevels() {
        level = 0
        bassLevel = 0
        midLevel = 0
        trebleLevel = 0
        onsetLevel = 0
        fluxBaseline = 0
        fluxFrameCount = 0
        lastUpdateTime = 0
    }
}

private struct SendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

