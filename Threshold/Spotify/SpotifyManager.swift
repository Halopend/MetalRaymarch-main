//
//  SpotifyManager.swift
//  Threshold
//
//  High-level coordinator for Spotify integration.
//  Owns auth, API client, and beat sync. Polls playback state and
//  exposes observable state for UI + render-thread-readable audio data.
//

import Foundation

enum MusicReactiveSource: String, CaseIterable, Codable, Sendable {
    case composite
    case bass
    case mid
    case treble
    case beat
    case overall

    var displayName: String {
        switch self {
        case .composite: return "Composite"
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .treble: return "Treble"
        case .beat: return "Beat"
        case .overall: return "Overall"
        }
    }
}

enum MusicReactiveTarget: String, CaseIterable, Codable, Sendable {
    case fractalScale
    case foldingLimit
    case sphereRadius
    case colorMix
    case glow
    case fog
    case bloom
    case hueSpeed
    case saturation
    case iterations

    var displayName: String {
        switch self {
        case .fractalScale: return "Fractal Scale"
        case .foldingLimit: return "Folding Limit"
        case .sphereRadius: return "Sphere Radius"
        case .colorMix: return "Color Mix"
        case .glow: return "Glow"
        case .fog: return "Fog"
        case .bloom: return "Bloom"
        case .hueSpeed: return "Hue Speed"
        case .saturation: return "Saturation"
        case .iterations: return "Iterations"
        }
    }

    var icon: String {
        switch self {
        case .fractalScale: return "arrow.up.left.and.arrow.down.right"
        case .foldingLimit: return "square.dashed"
        case .sphereRadius: return "circle.circle"
        case .colorMix: return "paintpalette"
        case .glow: return "sparkles"
        case .fog: return "cloud.fog"
        case .bloom: return "sun.max"
        case .hueSpeed: return "dial.high"
        case .saturation: return "circle.lefthalf.filled"
        case .iterations: return "number"
        }
    }

    var allowedRange: ClosedRange<Float> {
        switch self {
        case .fractalScale: return 1.6...5.2
        case .foldingLimit: return -10.0...30.0
        case .sphereRadius: return 0.03...1.2
        case .colorMix: return 0.0...1.0
        case .glow: return 0.0...1.0
        case .fog: return 0.0...1.0
        case .bloom: return 0.0...1.0
        case .hueSpeed: return 0.0...0.5
        case .saturation: return 0.0...3.0
        case .iterations: return 2.0...24.0
        }
    }

    var defaultRange: ClosedRange<Float> {
        switch self {
        case .fractalScale: return 2.4...3.4
        case .foldingLimit: return 0.9...1.35
        case .sphereRadius: return 0.25...0.8
        case .colorMix: return 0.2...0.9
        case .glow: return 0.2...0.9
        case .fog: return 0.05...0.5
        case .bloom: return 0.1...0.8
        case .hueSpeed: return 0.02...0.25
        case .saturation: return 0.8...2.0
        case .iterations: return 8.0...12.0
        }
    }

    var defaultSource: MusicReactiveSource {
        switch self {
        case .fractalScale: return .composite
        case .foldingLimit: return .bass
        case .sphereRadius: return .mid
        case .colorMix: return .composite
        case .glow: return .composite
        case .fog: return .composite
        case .bloom: return .beat
        case .hueSpeed: return .treble
        case .saturation: return .mid
        case .iterations: return .mid
        }
    }

    var parameterTargetID: String? {
        switch self {
        case .fractalScale: return "core.targetFractalScale"
        case .foldingLimit: return "formula.0.1.Folding Limit"
        case .sphereRadius: return "formula.0.2.Sphere Radius"
        case .colorMix: return "core.colorMix"
        case .glow: return "effect.glow"
        case .fog: return "effect.fog"
        case .bloom: return "effect.bloom"
        case .hueSpeed: return "effect.hueSpeed"
        case .saturation: return "effect.saturation"
        case .iterations: return "core.fractalIterations"
        }
    }

    func defaultMapping(enabled: Bool = true) -> MusicReactiveMapping {
        MusicReactiveMapping(
            target: self,
            source: defaultSource,
            rangeMin: defaultRange.lowerBound,
            rangeMax: defaultRange.upperBound,
            responseSpeed: 0.12,
            amount: 1.0,
            isEnabled: enabled
        )
    }
}

struct MusicReactiveMapping: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var target: MusicReactiveTarget
    var source: MusicReactiveSource
    var rangeMin: Float
    var rangeMax: Float
    var responseSpeed: Float
    var amount: Float
    var isEnabled: Bool

    init(id: UUID = UUID(),
         target: MusicReactiveTarget,
         source: MusicReactiveSource,
         rangeMin: Float,
         rangeMax: Float,
         responseSpeed: Float,
         amount: Float,
         isEnabled: Bool) {
        self.id = id
        self.target = target
        self.source = source
        self.rangeMin = rangeMin
        self.rangeMax = rangeMax
        self.responseSpeed = responseSpeed
        self.amount = amount
        self.isEnabled = isEnabled
        sanitizeInPlace()
    }

    mutating func sanitizeInPlace() {
        let allowed = target.allowedRange
        rangeMin = min(allowed.upperBound, max(allowed.lowerBound, rangeMin))
        rangeMax = min(allowed.upperBound, max(allowed.lowerBound, rangeMax))
        if rangeMin > rangeMax {
            swap(&rangeMin, &rangeMax)
        }
        responseSpeed = max(0.01, min(0.6, responseSpeed))
        amount = max(-2.0, min(2.0, amount))
    }

    static func defaultMappings() -> [MusicReactiveMapping] {
        [
            MusicReactiveTarget.fractalScale.defaultMapping(enabled: true),
            MusicReactiveTarget.foldingLimit.defaultMapping(enabled: true),
            MusicReactiveTarget.sphereRadius.defaultMapping(enabled: true),
            MusicReactiveTarget.colorMix.defaultMapping(enabled: true),
            MusicReactiveTarget.glow.defaultMapping(enabled: true),
            MusicReactiveTarget.fog.defaultMapping(enabled: true),
            MusicReactiveTarget.bloom.defaultMapping(enabled: true),
            MusicReactiveTarget.hueSpeed.defaultMapping(enabled: true),
            MusicReactiveTarget.saturation.defaultMapping(enabled: true),
            MusicReactiveTarget.iterations.defaultMapping(enabled: false)
        ]
    }
}

struct MusicReactivePreset: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var audioAmount: Float
    var beatPunch: Float
    var bassSensitivity: Float
    var midSensitivity: Float
    var trebleSensitivity: Float
    var beatSensitivity: Float
    var mappings: [MusicReactiveMapping]

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         audioAmount: Float,
         beatPunch: Float,
         bassSensitivity: Float,
         midSensitivity: Float,
         trebleSensitivity: Float,
         beatSensitivity: Float,
         mappings: [MusicReactiveMapping]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.audioAmount = audioAmount
        self.beatPunch = beatPunch
        self.bassSensitivity = bassSensitivity
        self.midSensitivity = midSensitivity
        self.trebleSensitivity = trebleSensitivity
        self.beatSensitivity = beatSensitivity
        self.mappings = mappings
    }
}

/// Genre-optimized reactivity presets (Fractal Forge–inspired).
/// Each preset tunes sensitivity curves and which parameters respond to audio.
enum ReactivityPreset: String, CaseIterable {
    case electronic = "EDM"
    case ambient    = "Ambient"
    case rock       = "Rock"
    case classical  = "Classical"
    case hiphop     = "Hip-Hop"

    var icon: String {
        switch self {
        case .electronic: return "bolt.fill"
        case .ambient:    return "leaf.fill"
        case .rock:       return "flame.fill"
        case .classical:  return "music.note"
        case .hiphop:     return "waveform"
        }
    }

    /// Core sensitivity tuning: (audioAmount, beatPunch, bassSens, midSens, trebleSens, beatSens)
    var settings: (audioAmount: Float, beatPunch: Float, bassSensitivity: Float, midSensitivity: Float, trebleSensitivity: Float, beatSensitivity: Float) {
        switch self {
        // EDM: Punchy kicks, big beat response, bright glow, fast color shifts
        case .electronic: return (0.75, 0.85, 1.1, 0.8, 0.9, 1.2)
        // Ambient: Ultra-smooth, gentle ripples, rich colors, fog modulation
        case .ambient:    return (0.45, 0.15, 0.6, 0.8, 0.9, 0.3)
        // Rock: Balanced, mid-emphasis on structure, moderate beats
        case .rock:       return (0.65, 0.70, 0.9, 1.0, 0.7, 0.8)
        // Classical: Refined, sustained tonal beauty, harmonic saturation
        case .classical:  return (0.40, 0.20, 0.5, 0.9, 0.8, 0.3)
        // Hip-Hop: Bass-heavy, punchy, scale/fold emphasis
        case .hiphop:     return (0.80, 0.90, 1.2, 0.7, 0.5, 1.0)
        }
    }
    
    /// Which geometry parameters this preset enables
    var geometryProfile: (scale: Bool, folding: Bool, radius: Bool, colorMix: Bool) {
        switch self {
        case .electronic: return (true,  true,  true,  true )
        case .ambient:    return (true,  false, false, true )
        case .rock:       return (true,  true,  true,  false)
        case .classical:  return (false, false, true,  true )
        case .hiphop:     return (true,  true,  true,  false)
        }
    }
    
    /// Which effect parameters this preset enables (Fractal Forge–inspired)
    var effectsProfile: (glow: Bool, fog: Bool, bloom: Bool, hueSpeed: Bool, saturation: Bool, iterations: Bool) {
        switch self {
        // EDM: Glow + bloom on beats, fog clears on drops, fast hue cycling
        case .electronic: return (true,  true,  true,  true,  false, false)
        // Ambient: Gentle fog breathing, rich saturation, slow hue drift
        case .ambient:    return (false, true,  false, true,  true,  false)
        // Rock: Glow + bloom punches
        case .rock:       return (true,  false, true,  false, false, false)
        // Classical: Fog + saturation richness, gentle hue rotation
        case .classical:  return (false, true,  false, true,  true,  false)
        // Hip-Hop: Glow flashes, bloom on kicks
        case .hiphop:     return (true,  false, true,  false, false, false)
        }
    }

    var defaultMappings: [MusicReactiveMapping] {
        var mappings = MusicReactiveMapping.defaultMappings()
        let geometry = geometryProfile
        let effects = effectsProfile
        for index in mappings.indices {
            switch mappings[index].target {
            case .fractalScale: mappings[index].isEnabled = geometry.scale
            case .foldingLimit: mappings[index].isEnabled = geometry.folding
            case .sphereRadius: mappings[index].isEnabled = geometry.radius
            case .colorMix: mappings[index].isEnabled = geometry.colorMix
            case .glow: mappings[index].isEnabled = effects.glow
            case .fog: mappings[index].isEnabled = effects.fog
            case .bloom: mappings[index].isEnabled = effects.bloom
            case .hueSpeed: mappings[index].isEnabled = effects.hueSpeed
            case .saturation: mappings[index].isEnabled = effects.saturation
            case .iterations: mappings[index].isEnabled = effects.iterations
            }
        }
        return mappings
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

    // MARK: - Library State
    private(set) var savedTracks: [SpotifySavedTrack] = []
    private(set) var userPlaylists: [SpotifySimplifiedPlaylist] = []
    private(set) var savedAlbums: [SpotifySavedAlbum] = []
    private(set) var isLibraryLoading: Bool = false
    private(set) var libraryError: String?
    
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
    private let libraryPageSize: Int = 50
    private let playlistTrackPageSize: Int = 100
    private let maxLibraryItems: Int = 500
    private let maxPlaylistTracks: Int = 1000
    
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
    
    /// Play a specific Spotify track URI (e.g. "spotify:track:...").
    func playURI(_ uri: String) async {
        do {
            try await apiClient?.playURI(uri)
            isPlaying = true
            // Refresh state quickly
            try? await Task.sleep(for: .milliseconds(300))
            await pollPlaybackState()
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

    // MARK: - Library

    /// Fetch the user's saved tracks, playlists, and albums from Spotify.
    func refreshLibrary() async {
        guard isConnected, let api = apiClient else {
            libraryError = "Not connected to Spotify."
            return
        }
        isLibraryLoading = true
        libraryError = nil

        do {
            async let tracks = fetchAllSavedTracks(api: api)
            async let playlists = fetchAllPlaylists(api: api)
            async let albums = fetchAllSavedAlbums(api: api)

            savedTracks = try await tracks
            userPlaylists = try await playlists
            savedAlbums = try await albums
        } catch {
            libraryError = error.localizedDescription
        }

        isLibraryLoading = false
    }

    /// Play a specific Spotify track by URI.
    func playTrackURI(_ uri: String) async {
        await playURI(uri)
    }

    /// Fetch the tracks inside a Spotify playlist.
    func getPlaylistTracks(playlistId: String) async -> [SpotifyTrack] {
        guard isConnected, let api = apiClient else { return [] }
        do {
            var allTracks: [SpotifyTrack] = []
            var offset = 0

            while allTracks.count < maxPlaylistTracks {
                let page = try await api.getPlaylistTracks(playlistId: playlistId, limit: playlistTrackPageSize, offset: offset)
                let newTracks = page.items.compactMap(\.track)
                allTracks.append(contentsOf: newTracks)

                if page.next == nil || page.items.isEmpty || allTracks.count >= page.total {
                    break
                }
                offset += page.items.count
            }

            return Array(allTracks.prefix(maxPlaylistTracks))
        } catch {
            return []
        }
    }

    private func fetchAllSavedTracks(api: SpotifyAPIClient) async throws -> [SpotifySavedTrack] {
        var allItems: [SpotifySavedTrack] = []
        var offset = 0

        while allItems.count < maxLibraryItems {
            let page = try await api.getSavedTracks(limit: libraryPageSize, offset: offset)
            allItems.append(contentsOf: page.items)

            if page.next == nil || page.items.isEmpty || allItems.count >= page.total {
                break
            }
            offset += page.items.count
        }

        return Array(allItems.prefix(maxLibraryItems))
    }

    private func fetchAllPlaylists(api: SpotifyAPIClient) async throws -> [SpotifySimplifiedPlaylist] {
        var allItems: [SpotifySimplifiedPlaylist] = []
        var offset = 0

        while allItems.count < maxLibraryItems {
            let page = try await api.getUserPlaylists(limit: libraryPageSize, offset: offset)
            allItems.append(contentsOf: page.items)

            if page.next == nil || page.items.isEmpty || allItems.count >= page.total {
                break
            }
            offset += page.items.count
        }

        return Array(allItems.prefix(maxLibraryItems))
    }

    private func fetchAllSavedAlbums(api: SpotifyAPIClient) async throws -> [SpotifySavedAlbum] {
        var allItems: [SpotifySavedAlbum] = []
        var offset = 0

        while allItems.count < maxLibraryItems {
            let page = try await api.getSavedAlbums(limit: libraryPageSize, offset: offset)
            allItems.append(contentsOf: page.items)

            if page.next == nil || page.items.isEmpty || allItems.count >= page.total {
                break
            }
            offset += page.items.count
        }

        return Array(allItems.prefix(maxLibraryItems))
    }

    /// Search for tracks by query string.
    func searchTracks(query: String, limit: Int = 5) async -> [SpotifyTrack] {
        guard isConnected else { return [] }
        do {
            return try await apiClient?.searchTracks(query: query, limit: limit) ?? []
        } catch {
            return []
        }
    }

    /// Play a Spotify playlist or album by context URI, optionally shuffled.
    func playContext(_ contextURI: String, shuffle: Bool = false) async {
        do {
            if shuffle {
                try await apiClient?.setShuffle(true)
            }
            try await apiClient?.playContext(contextURI)
            isPlaying = true
            try? await Task.sleep(for: .milliseconds(300))
            await pollPlaybackState()
            if !shuffle {
                // Reset shuffle to off after non-shuffle play
                try? await apiClient?.setShuffle(false)
            }
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
