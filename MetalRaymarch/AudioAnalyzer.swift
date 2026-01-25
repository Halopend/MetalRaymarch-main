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
    
    // Smoothing parameters
    private let attackSpeed: Float = 0.3     // How fast level rises
    private let decaySpeed: Float = 0.1      // How fast level falls
    private let peakDecaySpeed: Float = 0.02 // How fast peak falls
    
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
        // Smooth the overall level (fast attack, slow decay)
        if overall > level {
            level = level + (overall - level) * attackSpeed
        } else {
            level = level + (overall - level) * decaySpeed
        }
        
        // Update peak with slow decay
        if level > peakLevel {
            peakLevel = level
        } else {
            peakLevel = max(0, peakLevel - peakDecaySpeed)
        }
        
        // Smooth bass and treble
        bassLevel = bassLevel + (bass - bassLevel) * 0.2
        trebleLevel = trebleLevel + (treble - trebleLevel) * 0.2
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
