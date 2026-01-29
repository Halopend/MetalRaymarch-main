//
//  AudioAnalyzer.swift
//  MetalRaymarch
//
//  Captures system audio or microphone input and provides audio levels
//  for reactive lighting in the fractal renderer.
//

import AVFoundation
import Accelerate

/// Analyzes audio input and provides normalized level values for visual effects
@MainActor
@Observable
class AudioAnalyzer {
    
    // MARK: - Public Properties
    
    /// Current audio level (0-1), smoothed for visual appeal
    /// nonisolated(unsafe) allows reading from render thread
    nonisolated(unsafe) private(set) var level: Float = 0.0
    
    /// Peak level with slow decay for "peak hold" effects
    nonisolated(unsafe) private(set) var peakLevel: Float = 0.0
    
    /// Bass level (low frequencies) - good for deep pulses
    nonisolated(unsafe) private(set) var bassLevel: Float = 0.0
    
    /// Treble level (high frequencies) - good for sparkles
    nonisolated(unsafe) private(set) var trebleLevel: Float = 0.0
    
    /// Whether audio capture is active
    nonisolated(unsafe) private(set) var isCapturing: Bool = false
    
    /// Error message if capture fails
    private(set) var errorMessage: String?
    
    // MARK: - Private Properties
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    
    // Frame-rate independent smoothing speeds (Freya Holmér exponential decay)
    // Higher values = faster response. speed=20 gives ~63% convergence in 50ms
    private let attackSpeed: Float = 30.0     // How fast level rises (responsive)
    private let decaySpeed: Float = 8.0       // How fast level falls (slower decay)
    private let peakDecaySpeed: Float = 1.5   // How fast peak falls (very slow)
    private let bandSmoothSpeed: Float = 15.0 // Bass/treble smoothing speed
    
    // Timestamp for frame-rate independent smoothing
    private var lastUpdateTime: CFTimeInterval = 0
    
    // MARK: - Initialization
    
    init() {
        // Don't auto-start - let user opt-in for privacy
    }
    
    // MARK: - Public Methods
    
    /// Start capturing audio from the default input device
    func startCapture() {
        guard !isCapturing else { return }
        
        // Check microphone permission
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
        trebleLevel = 0
    }
    
    /// Manually set the audio level (for testing or manual control)
    func setManualLevel(_ newLevel: Float) {
        level = max(0, min(1, newLevel))
        peakLevel = max(peakLevel, level)
    }
    
    // MARK: - Private Methods
    
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
        // macOS doesn't require explicit permission for audio input in most cases
        return true
        #endif
    }
    
    private func setupAudioCapture() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        
        // Ensure we have a valid format
        guard format.sampleRate > 0 else {
            errorMessage = "No audio input available"
            return
        }
        
        // Install tap on the input node to capture audio samples
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            self.inputNode = input
            self.isCapturing = true
            self.errorMessage = nil
            print("🎤 Audio capture started (sample rate: \(format.sampleRate))")
        } catch {
            self.errorMessage = "Failed to start audio: \(error.localizedDescription)"
            print("❌ Audio capture error: \(error)")
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Get pointer to first channel
        let samples = channelData[0]
        
        // Calculate RMS (root mean square) for overall level
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameLength))
        
        // Convert to a more perceptually useful scale
        // RMS values are typically very small (0.001 - 0.1 for normal audio)
        let normalizedLevel = min(1.0, rms * 10.0)
        
        // Simple frequency band estimation using zero-crossing rate
        // (Proper FFT would be better but this is lightweight)
        var zeroCrossings = 0
        for i in 1..<frameLength {
            if (samples[i-1] >= 0 && samples[i] < 0) || (samples[i-1] < 0 && samples[i] >= 0) {
                zeroCrossings += 1
            }
        }
        let zeroCrossingRate = Float(zeroCrossings) / Float(frameLength)
        
        // High zero-crossing = high frequency content (treble)
        // Low zero-crossing = low frequency content (bass)
        let treble = min(1.0, zeroCrossingRate * 5.0) * normalizedLevel
        let bass = max(0.0, 1.0 - zeroCrossingRate * 3.0) * normalizedLevel
        
        // Update levels on main thread with smoothing
        Task { @MainActor in
            self.updateLevels(overall: normalizedLevel, bass: bass, treble: treble)
        }
    }
    
    private func updateLevels(overall: Float, bass: Float, treble: Float) {
        // Calculate deltaTime for frame-rate independent smoothing
        let currentTime = CACurrentMediaTime()
        let deltaTime = lastUpdateTime > 0 ? Float(currentTime - lastUpdateTime) : Float(1.0 / 60.0)
        lastUpdateTime = currentTime
        
        // Clamp deltaTime to reasonable range (handles first call and long pauses)
        let clampedDT = max(0.001, min(0.1, deltaTime))
        
        // Frame-rate independent exponential decay (Freya Holmér technique)
        // factor = 1 - e^(-speed * dt)
        
        // Smooth the overall level (fast attack, slow decay)
        if overall > level {
            let attackFactor = 1.0 - exp(-attackSpeed * clampedDT)
            level = level + (overall - level) * attackFactor
        } else {
            let decayFactor = 1.0 - exp(-decaySpeed * clampedDT)
            level = level + (overall - level) * decayFactor
        }
        
        // Update peak with slow decay (linear decay rate per second)
        if level > peakLevel {
            peakLevel = level
        } else {
            peakLevel = max(0, peakLevel - peakDecaySpeed * clampedDT)
        }
        
        // Smooth bass and treble with frame-rate independent decay
        let bandFactor = 1.0 - exp(-bandSmoothSpeed * clampedDT)
        bassLevel = bassLevel + (bass - bassLevel) * bandFactor
        trebleLevel = trebleLevel + (treble - trebleLevel) * bandFactor
    }
}

// MARK: - Extension for RenderSettings integration

extension RenderSettings {
    /// Updates audio level from the analyzer (call each frame when in audio-reactive mode)
    @MainActor
    func updateFromAudioAnalyzer(_ analyzer: AudioAnalyzer) {
        if lightingMode == .audioReactive && analyzer.isCapturing {
            // Use a combination of overall level and bass for more dramatic effect
            let combinedLevel = analyzer.level * 0.6 + analyzer.bassLevel * 0.4
            audioLevel = combinedLevel
        }
    }
}
