//
//  SpotifyBeatSync.swift
//  Threshold
//
//  Real-time beat synchronization engine.
//  Consumes SpotifyAudioAnalysis + playback position to produce
//  per-frame bass/mid/treble/beat intensity values for the renderer.
//
//  Properties are nonisolated(unsafe) for direct render-thread reads,
//  matching AudioAnalyzer's pattern.
//

import Foundation
import QuartzCore

/// Interpolates Spotify audio analysis data into real-time per-frame values.
/// Designed for render-thread consumption without locks.
@MainActor
@Observable
class SpotifyBeatSync {
    
    // MARK: - Render-Thread Readable Properties
    // These mirror AudioAnalyzer's pattern: written on MainActor, read from render thread.
    
    /// Bass energy (0-1) from segment timbre + pitch analysis
    @ObservationIgnored nonisolated(unsafe) private(set) var bassLevel: Float = 0.0
    
    /// Mid energy (0-1) from segment brightness
    @ObservationIgnored nonisolated(unsafe) private(set) var midLevel: Float = 0.0
    
    /// Treble energy (0-1) from high-frequency content
    @ObservationIgnored nonisolated(unsafe) private(set) var trebleLevel: Float = 0.0
    
    /// Beat intensity (0-1) — peaks on beat onsets, decays between
    @ObservationIgnored nonisolated(unsafe) private(set) var beatIntensity: Float = 0.0
    
    /// Combined overall energy (0-1) — weighted blend of all bands
    @ObservationIgnored nonisolated(unsafe) private(set) var overallLevel: Float = 0.0
    
    /// Current section's tempo in BPM
    @ObservationIgnored nonisolated(unsafe) private(set) var currentTempo: Float = 120.0
    
    /// Whether beat sync is actively producing values
    @ObservationIgnored nonisolated(unsafe) private(set) var isActive: Bool = false
    
    // MARK: - Internal State
    
    private var analysis: SpotifyAudioAnalysis?
    private var features: SpotifyAudioFeatures?
    
    /// Sorted segment start times for binary search
    private var segmentStarts: [Float] = []
    private var beatStarts: [Float] = []
    private var sectionStarts: [Float] = []
    
    /// Track start time (monotonic clock) and playback offset
    private var playbackStartTime: CFTimeInterval = 0
    private var playbackStartOffset: Float = 0  // Where in the track we started (seconds)
    private var isPlaying: Bool = false
    
    /// Smoothing state
    private var smoothBass: Float = 0
    private var smoothMid: Float = 0
    private var smoothTreble: Float = 0
    private var smoothBeat: Float = 0
    
    /// Last processed beat index (to detect new beats)
    private var lastBeatIndex: Int = -1
    
    /// When true, generates synthetic beats from audio features BPM
    /// (fallback when audio analysis API is unavailable)
    private var useSyntheticBeats: Bool = false
    
    // Smoothing parameters
    private let bandAttackSpeed: Float = 25.0
    private let bandDecaySpeed: Float = 8.0
    private let beatAttackSpeed: Float = 60.0   // Very fast attack for beat snaps
    private let beatDecaySpeed: Float = 6.0     // Moderate decay for visible pulses
    
    // MARK: - Public Interface
    
    /// Load audio analysis data for a track.
    func loadAnalysis(_ analysis: SpotifyAudioAnalysis, features: SpotifyAudioFeatures?) {
        self.analysis = analysis
        self.features = features
        self.useSyntheticBeats = false
        
        // Pre-sort start times for efficient binary search
        segmentStarts = analysis.segments.map(\.start)
        beatStarts = analysis.beats.map(\.start)
        sectionStarts = analysis.sections.map(\.start)
        
        lastBeatIndex = -1
        
        if let trackInfo = analysis.track {
            currentTempo = trackInfo.tempo
        }
    }
    
    /// Fallback: generate synthetic beat-sync from audio features alone.
    /// Used when audio analysis API is unavailable (deprecated by Spotify Nov 2023).
    func loadFeaturesOnly(_ features: SpotifyAudioFeatures) {
        self.analysis = nil
        self.features = features
        self.useSyntheticBeats = true
        segmentStarts = []
        beatStarts = []
        sectionStarts = []
        lastBeatIndex = -1
        currentTempo = features.tempo
    }
    
    /// Update playback timing (called when Spotify playback state is polled).
    func updatePlaybackPosition(progressSeconds: Float, isPlaying: Bool) {
        self.playbackStartOffset = progressSeconds
        self.playbackStartTime = CACurrentMediaTime()
        self.isPlaying = isPlaying
        self.isActive = isPlaying && (analysis != nil || useSyntheticBeats)
    }
    
    /// Called every frame to update beat sync values.
    /// Uses interpolated playback position for smooth real-time updates between API polls.
    func update() {
        guard isActive, isPlaying else {
            // Decay to zero when not active
            decayAll()
            return
        }
        
        // Estimate current playback position using wall clock
        let elapsed = Float(CACurrentMediaTime() - playbackStartTime)
        let currentPosition = playbackStartOffset + elapsed
        
        let currentTime = CACurrentMediaTime()
        let deltaTime = lastUpdateTime > 0 ? Float(currentTime - lastUpdateTime) : Float(1.0 / 90.0)
        lastUpdateTime = currentTime
        let dt = max(0.001, min(0.1, deltaTime))
        
        if useSyntheticBeats {
            // SYNTHETIC MODE: Generate beats/bands from audio features + BPM
            updateSynthetic(currentPosition: currentPosition, dt: dt)
        } else if let analysis = analysis {
            // ANALYSIS MODE: Use real segment/beat/section data
            updateFromAnalysis(analysis: analysis, currentPosition: currentPosition, dt: dt)
        }
        
        // Apply energy scaling from audio features if available
        let energyScale = features?.energy ?? 1.0
        
        // Write values for render thread
        bassLevel = smoothBass * energyScale
        midLevel = smoothMid * energyScale
        trebleLevel = smoothTreble * energyScale
        beatIntensity = smoothBeat
        overallLevel = bassLevel * 0.4 + midLevel * 0.3 + trebleLevel * 0.3
    }
    
    /// Stop beat sync (e.g., track changed, playback stopped).
    func stop() {
        isPlaying = false
        isActive = false
        analysis = nil
        features = nil
        useSyntheticBeats = false
        lastBeatIndex = -1
    }
    
    // MARK: - Update Methods
    
    /// Update from full audio analysis data (segments, beats, sections).
    private func updateFromAnalysis(analysis: SpotifyAudioAnalysis, currentPosition: Float, dt: Float) {
        // Find current segment
        let segIdx = findIndex(in: segmentStarts, for: currentPosition)
        if segIdx < analysis.segments.count {
            let segment = analysis.segments[segIdx]
            
            // Calculate position within segment for loudness interpolation
            let segProgress = (currentPosition - segment.start) / max(segment.duration, 0.01)
            
            // Interpolate loudness within segment
            let loudness: Float
            if segProgress < segment.loudnessMaxTime / max(segment.duration, 0.01) {
                let riseProgress = segProgress / max(segment.loudnessMaxTime / max(segment.duration, 0.01), 0.01)
                loudness = segment.loudnessStart + (segment.loudnessMax - segment.loudnessStart) * min(riseProgress, 1.0)
            } else {
                let endLoudness = segment.loudnessEnd ?? (segment.loudnessStart - 5.0)
                let fallProgress = (segProgress - segment.loudnessMaxTime / max(segment.duration, 0.01)) /
                    max(1.0 - segment.loudnessMaxTime / max(segment.duration, 0.01), 0.01)
                loudness = segment.loudnessMax + (endLoudness - segment.loudnessMax) * min(fallProgress, 1.0)
            }
            
            let normalizedLoudness = min(1.0, max(0.0, (loudness + 60.0) / 60.0))
            
            let targetBass = segment.bassEnergy * normalizedLoudness
            let targetMid = segment.midEnergy * normalizedLoudness
            let targetTreble = segment.trebleEnergy * normalizedLoudness
            
            smoothBand(&smoothBass, target: targetBass, dt: dt)
            smoothBand(&smoothMid, target: targetMid, dt: dt)
            smoothBand(&smoothTreble, target: targetTreble, dt: dt)
        }
        
        // Find current beat
        let beatIdx = findIndex(in: beatStarts, for: currentPosition)
        if beatIdx != lastBeatIndex && beatIdx < analysis.beats.count {
            let beat = analysis.beats[beatIdx]
            smoothBeat = beat.confidence
            lastBeatIndex = beatIdx
        } else {
            let decayFactor = 1.0 - exp(-beatDecaySpeed * dt)
            smoothBeat = smoothBeat * (1.0 - decayFactor)
        }
        
        // Find current section for tempo
        let secIdx = findIndex(in: sectionStarts, for: currentPosition)
        if secIdx < analysis.sections.count {
            currentTempo = analysis.sections[secIdx].tempo
        }
    }
    
    /// Synthetic beat generation from audio features BPM + energy.
    /// Fallback when Spotify Audio Analysis API is unavailable.
    private func updateSynthetic(currentPosition: Float, dt: Float) {
        guard let features = features else {
            decayAll()
            return
        }
        
        let tempo = features.tempo  // BPM
        let beatPeriod = 60.0 / max(tempo, 30.0)  // seconds per beat
        
        // Synthetic beat: calculate phase within current beat
        let beatPhase = fmod(currentPosition, beatPeriod) / beatPeriod  // 0-1
        
        // Detect beat onset (phase wraps around)
        let currentBeatNumber = Int(currentPosition / beatPeriod)
        if currentBeatNumber != lastBeatIndex {
            smoothBeat = features.energy  // Snap intensity proportional to track energy
            lastBeatIndex = currentBeatNumber
        } else {
            let decayFactor = 1.0 - exp(-beatDecaySpeed * dt)
            smoothBeat = smoothBeat * (1.0 - decayFactor)
        }
        
        // Synthetic frequency bands from audio features
        // Use energy/danceability/valence to approximate spectral distribution
        let bassPulse = (1.0 - beatPhase) * features.energy
        let midPulse = sin(beatPhase * 3.14159) * features.danceability
        let treblePulse = sin(beatPhase * 6.28318) * 0.5 + 0.5 * (1.0 - features.acousticness)
        
        smoothBand(&smoothBass, target: bassPulse * 0.8, dt: dt)
        smoothBand(&smoothMid, target: midPulse * 0.7, dt: dt)
        smoothBand(&smoothTreble, target: treblePulse * 0.6, dt: dt)
    }
    
    // MARK: - Private Helpers
    
    private var lastUpdateTime: CFTimeInterval = 0
    
    private func decayAll() {
        let dt: Float = 1.0 / 90.0  // Assume 90Hz when decaying
        let factor = 1.0 - exp(-bandDecaySpeed * dt)
        smoothBass *= (1.0 - factor)
        smoothMid *= (1.0 - factor)
        smoothTreble *= (1.0 - factor)
        smoothBeat *= (1.0 - factor)
        
        bassLevel = smoothBass
        midLevel = smoothMid
        trebleLevel = smoothTreble
        beatIntensity = smoothBeat
        overallLevel = 0
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
    
    /// Binary search to find the last index whose start <= position
    private func findIndex(in starts: [Float], for position: Float) -> Int {
        guard !starts.isEmpty else { return 0 }
        
        var lo = 0
        var hi = starts.count - 1
        
        while lo < hi {
            let mid = (lo + hi + 1) / 2  // Bias toward upper half
            if starts[mid] <= position {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        
        return lo
    }
}
