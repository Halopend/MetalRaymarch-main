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
    
    // Frame-rate independent smoothing speeds
    private let attackSpeed: Float = 40.0      // Fast attack for responsiveness
    private let decaySpeed: Float = 12.0       // Moderate decay
    private let peakDecaySpeed: Float = 2.0    // Slow peak decay
    private let bandAttackSpeed: Float = 35.0  // Band-specific attack
    private let bandDecaySpeed: Float = 10.0   // Band-specific decay
    
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
            
            // Calculate frequency bands
            // Bin frequency = (bin index * sample rate) / FFT size
            let binWidth = sampleRate / Float(fftSize)
            
            // Bass: 20-250 Hz
            let bassStart = max(1, Int(20.0 / binWidth))
            let bassEnd = min(halfSize - 1, Int(250.0 / binWidth))
            
            // Mids: 250-2000 Hz  
            let midStart = bassEnd + 1
            let midEnd = min(halfSize - 1, Int(2000.0 / binWidth))
            
            // Treble: 2000-8000 Hz (limiting upper range for better response)
            let trebleStart = midEnd + 1
            let trebleEnd = min(halfSize - 1, Int(8000.0 / binWidth))
            
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
        
        // Update levels on main thread with smoothing
        Task { @MainActor in
            self.updateLevels(overall: normalizedLevel, bass: bass, mid: mid, treble: treble)
        }
    }
    
    /// Soft compression to make quiet sounds more visible without clipping loud sounds
    private func compressLevel(_ x: Float) -> Float {
        // Soft knee compression: x / (1 + x) with gain
        // Maps 0-inf to 0-1 range, with most interesting range in 0-0.8
        return x / (0.5 + x)
    }
    
    private func updateLevels(overall: Float, bass: Float, mid: Float, treble: Float) {
        let currentTime = CACurrentMediaTime()
        let deltaTime = lastUpdateTime > 0 ? Float(currentTime - lastUpdateTime) : Float(1.0 / 60.0)
        lastUpdateTime = currentTime
        
        let clampedDT = max(0.001, min(0.1, deltaTime))
        
        // Smooth overall level (fast attack, slow decay)
        if overall > level {
            let attackFactor = 1.0 - exp(-attackSpeed * clampedDT)
            level = level + (overall - level) * attackFactor
        } else {
            let decayFactor = 1.0 - exp(-decaySpeed * clampedDT)
            level = level + (overall - level) * decayFactor
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
            let attackFactor = 1.0 - exp(-bandAttackSpeed * dt)
            current = current + (target - current) * attackFactor
        } else {
            let decayFactor = 1.0 - exp(-bandDecaySpeed * dt)
            current = current + (target - current) * decayFactor
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
