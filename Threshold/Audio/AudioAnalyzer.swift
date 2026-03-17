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
    
    /// Peak level with slow decay for "peak hold" effects
    @ObservationIgnored nonisolated(unsafe) private(set) var peakLevel: Float = 0.0
    
    /// Bass level (low frequencies 20-250Hz) - good for deep pulses
    @ObservationIgnored nonisolated(unsafe) private(set) var bassLevel: Float = 0.0
    
    /// Mid level (250Hz-2kHz) - vocals and instruments
    @ObservationIgnored nonisolated(unsafe) private(set) var midLevel: Float = 0.0
    
    /// Treble level (high frequencies 2k-20kHz) - good for sparkles
    @ObservationIgnored nonisolated(unsafe) private(set) var trebleLevel: Float = 0.0
    
    /// Whether audio capture is active
    @ObservationIgnored nonisolated(unsafe) private(set) var isCapturing: Bool = false
    
    // Pending MainActor dispatch batching — avoids creating ~86 Tasks/sec
    @ObservationIgnored nonisolated(unsafe) private var pendingLevelDispatch = false
    @ObservationIgnored nonisolated(unsafe) private var pendingOverall: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingBass: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingMid: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingTreble: Float = 0
    
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
    private let peakDecaySpeed: Float = 2.0    // Slow peak decay
    private let bandAttackSpeed: Float = 35.0  // Band-specific attack
    private let bandDecaySpeed: Float = 10.0   // Band-specific decay
    
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
    
    // Timestamp for frame-rate independent smoothing
    private var lastUpdateTime: CFTimeInterval = 0
    
    // MARK: - Initialization
    
    init() {
        setupFFT()
    }
    
    // MARK: - Public Methods
    
    /// Start capturing audio from the default input device
    func startCapture() {
        guard !isCapturing else { return }
        
        Task {
            let permission = await checkMicrophonePermission()
            if permission {
                await MainActor.run {
                    setupAudioCapture()
                }
            } else {
                await MainActor.run {
                    errorMessage = "Microphone access denied. Enable in Settings."
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
        isCapturing = false
        level = 0
        peakLevel = 0
        bassLevel = 0
        midLevel = 0
        trebleLevel = 0
        lastUpdateTime = 0
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
        #if os(visionOS) || os(iOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #else
        return true
        #endif
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
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            self.inputNode = input
            self.isCapturing = true
            self.errorMessage = nil
            print("🎤 Audio capture started (sample rate: \(format.sampleRate), FFT size: \(fftSize))")
        } catch {
            self.errorMessage = "Failed to start audio: \(error.localizedDescription)"
            print("❌ Audio capture error: \(error)")
        }
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
        
        // Apply gain and compress
        let normalizedLevel = min(1.0, compressLevel(rms * inputGain))
        
        // Perform FFT analysis for frequency bands
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
        
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
        updateLevels(overall: pendingOverall, bass: pendingBass, mid: pendingMid, treble: pendingTreble)
    }
    
    private func updateLevels(overall: Float, bass: Float, mid: Float, treble: Float) {
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
        
        // Update peak with slow decay
        if level > peakLevel {
            peakLevel = level
        } else {
            peakLevel = max(0, peakLevel - peakDecaySpeed * clampedDT)
        }
        
        // Smooth frequency bands with attack/decay
        smoothBand(&bassLevel, target: bass, dt: clampedDT)
        smoothBand(&midLevel, target: mid, dt: clampedDT)
        smoothBand(&trebleLevel, target: treble, dt: clampedDT)
    }
    
    private func smoothBand(_ current: inout Float, target: Float, dt: Float) {
        if target > current {
            current = current + (target - current) * cachedBandAttackFactor
        } else {
            current = current + (target - current) * cachedBandDecayFactor
        }
    }
}

// MARK: - Extension for RenderSettings integration

extension RenderSettings {
    /// Updates audio level from the analyzer (call each frame when in audio-reactive mode)
    @MainActor
    func updateFromAudioAnalyzer(_ analyzer: AudioAnalyzer) {
        if lightingMode == .audioReactive && analyzer.isCapturing {
            // Use weighted combination: bass for punch, mids for body, treble for sparkle
            let combinedLevel = analyzer.bassLevel * 0.5 + analyzer.midLevel * 0.3 + analyzer.level * 0.2
            audioLevel = combinedLevel
        }
    }
}
