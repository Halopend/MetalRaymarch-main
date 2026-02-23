//
//  SpotifyManager.swift
//  MetalRaymarch
//
//  High-level coordinator for Spotify integration.
//  Owns auth, API client, and beat sync. Polls playback state and
//  exposes observable state for UI + render-thread-readable audio data.
//

import Foundation

/// Reactivity preset — controls how intensely audio modulates the fractal.
enum ReactivityPreset: String, CaseIterable {
    case subtle  = "Subtle"
    case medium  = "Medium"
    case intense = "Intense"

    var icon: String {
        switch self {
        case .subtle:  return "leaf"
        case .medium:  return "bolt.fill"
        case .intense: return "sparkles"
        }
    }

    /// (audioAmount, beatPunch, bassSens, midSens, trebleSens, beatSens)
    var settings: (audioAmount: Float, beatPunch: Float, bassSensitivity: Float, midSensitivity: Float, trebleSensitivity: Float, beatSensitivity: Float) {
        switch self {
        case .subtle:  return (0.25, 0.20, 0.5, 0.4, 0.3, 0.4)
        case .medium:  return (0.55, 0.55, 0.8, 0.7, 0.6, 0.7)
        case .intense: return (0.85, 0.85, 1.0, 1.0, 1.0, 1.0)
        }
    }
}

/// Coordinates Spotify auth, API, and beat sync into a unified interface.
@MainActor
@Observable
class SpotifyManager {
    
    // MARK: - Sub-Components
    
    let authManager = SpotifyAuthManager()
    private(set) var beatSync = SpotifyBeatSync()
    private var apiClient: SpotifyAPIClient?

    // Render-thread readable mirrors of beat sync output
    @ObservationIgnored nonisolated(unsafe) private(set) var bassLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var midLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var trebleLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var beatIntensity: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var overallLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var beatSyncActive: Bool = false
    
    // MARK: - Observable State (for UI)
    
    var isConnected: Bool { authManager.isAuthenticated }
    private(set) var currentTrack: SpotifyTrack?
    private(set) var isPlaying: Bool = false
    private(set) var progressMs: Int = 0
    private(set) var durationMs: Int = 0
    private(set) var audioFeatures: SpotifyAudioFeatures?
    private(set) var error: String?
    
    /// Wall-clock time when progressMs was last synced from polling
    private var progressSyncTime: Date = .now
    
    /// Progress as 0-1 fraction (interpolated between polls)
    var progressFraction: Float {
        guard durationMs > 0 else { return 0 }
        let interpolated = interpolatedProgressMs
        return Float(min(interpolated, durationMs)) / Float(durationMs)
    }
    
    /// Interpolated progress accounting for elapsed time since last poll
    private var interpolatedProgressMs: Int {
        guard isPlaying else { return progressMs }
        let elapsed = Date.now.timeIntervalSince(progressSyncTime) * 1000
        return progressMs + Int(elapsed)
    }
    
    /// Formatted current time (interpolated)
    var currentTimeString: String {
        formatTime(ms: interpolatedProgressMs)
    }
    
    /// Formatted total time
    var totalTimeString: String {
        formatTime(ms: durationMs)
    }
    
    // MARK: - Polling
    
    private var pollTask: Task<Void, Never>?
    private var lastTrackId: String?
    private let pollInterval: TimeInterval = 1.0
    
    // MARK: - Lifecycle
    
    init() {
        // Create API client once auth manager is ready
        apiClient = SpotifyAPIClient(authManager: authManager)
        
        // If already authenticated from Keychain, start polling immediately
        if authManager.isAuthenticated {
            startPolling()
        }
    }
    
    /// Start polling Spotify playback state.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPlaybackState()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 1.0))
            }
        }
    }
    
    /// Stop polling.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
    
    // MARK: - Auth Actions
    
    func connect() {
        authManager.login()
    }
    
    func disconnect() {
        stopPolling()
        authManager.logout()
        currentTrack = nil
        isPlaying = false
        progressMs = 0
        audioFeatures = nil
        beatSync.stop()
        Task { await apiClient?.clearCaches() }
    }
    
    func handleCallback(_ url: URL) async {
        await authManager.handleCallback(url)
        if authManager.isAuthenticated {
            startPolling()
        }
    }
    
    // MARK: - Transport Controls
    
    func play() async {
        do {
            try await apiClient?.play()
            isPlaying = true
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    func pause() async {
        do {
            try await apiClient?.pause()
            isPlaying = false
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    func togglePlayPause() async {
        if isPlaying {
            await pause()
        } else {
            await play()
        }
    }
    
    func next() async {
        do {
            try await apiClient?.next()
            // Poll immediately to update track info
            try? await Task.sleep(for: .milliseconds(300))
            await pollPlaybackState()
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    func previous() async {
        do {
            try await apiClient?.previous()
            try? await Task.sleep(for: .milliseconds(300))
            await pollPlaybackState()
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    func seek(fraction: Float) async {
        let posMs = Int(fraction * Float(durationMs))
        do {
            try await apiClient?.seek(positionMs: posMs)
            progressMs = posMs
            progressSyncTime = .now  // Reset interpolation anchor
            beatSync.updatePlaybackPosition(
                progressSeconds: Float(posMs) / 1000.0,
                isPlaying: isPlaying
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    // MARK: - Polling Implementation
    
    private func pollPlaybackState() async {
        guard isConnected else { return }
        
        do {
            guard let state = try await apiClient?.getPlaybackState() else {
                // Nothing playing
                isPlaying = false
                return
            }
            
            isPlaying = state.isPlaying
            progressMs = state.progressMs ?? 0
            progressSyncTime = .now  // Reset interpolation anchor
            
            if let track = state.item {
                durationMs = track.durationMs
                currentTrack = track
                
                // If track changed, load new analysis
                if track.id != lastTrackId {
                    lastTrackId = track.id
                    await loadTrackAnalysis(trackId: track.id)
                }
                
                // Update beat sync timing
                beatSync.updatePlaybackPosition(
                    progressSeconds: Float(progressMs) / 1000.0,
                    isPlaying: isPlaying
                )
            }
            
            error = nil
            
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    private func loadTrackAnalysis(trackId: String) async {
        // Try to load both audio analysis and features.
        // Audio analysis was deprecated by Spotify (Nov 2023) so it may fail.
        // In that case, fall back to features-only synthetic beat mode.
        
        var loadedFeatures: SpotifyAudioFeatures?
        var loadedAnalysis: SpotifyAudioAnalysis?
        
        // Load features first (more likely to succeed)
        do {
            loadedFeatures = try await apiClient?.getAudioFeatures(trackId: trackId)
            self.audioFeatures = loadedFeatures
        } catch {
            print("⚠️ Failed to load audio features: \(error.localizedDescription)")
        }
        
        // Try analysis (may 403 if deprecated)
        do {
            loadedAnalysis = try await apiClient?.getAudioAnalysis(trackId: trackId)
        } catch {
            print("⚠️ Audio analysis unavailable (API deprecated): \(error.localizedDescription)")
        }
        
        // Apply to beat sync with fallback
        if let analysis = loadedAnalysis {
            beatSync.loadAnalysis(analysis, features: loadedFeatures)
        } else if let features = loadedFeatures {
            // Fallback: synthetic beats from BPM + energy
            beatSync.loadFeaturesOnly(features)
        }
    }
    
    // MARK: - Frame Update
    
    /// Call every frame to update beat sync interpolation.
    /// This drives the real-time audio values that the renderer reads.
    func updateFrame() {
        beatSync.update()
        bassLevel = beatSync.bassLevel
        midLevel = beatSync.midLevel
        trebleLevel = beatSync.trebleLevel
        beatIntensity = beatSync.beatIntensity
        overallLevel = beatSync.overallLevel
        beatSyncActive = beatSync.isActive
    }
    
    // MARK: - Helpers
    
    private func formatTime(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
