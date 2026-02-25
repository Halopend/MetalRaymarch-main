//
//  MusicServiceProtocol.swift
//  Threshold
//
//  Core protocol and unified models for the music unification layer.
//  Every music backend (Apple Music, Spotify, future services) conforms
//  to `MusicServiceProvider` so MusicService can orchestrate them
//  through a single interface.
//

import SwiftUI

// ══════════════════════════════════════════════════════════════════════════
// MARK: - Unified Models
// ══════════════════════════════════════════════════════════════════════════

// ── Unified Track ID ──────────────────────────────────────────────────

/// A cross-service identifier in the format `"serviceID:nativeID"`.
/// Examples:
///   - `"appleMusic:1234567890"`  (Apple Music persistent ID)
///   - `"spotify:spotify:track:6rqhFgbbKwnb9MLmUQDhG6"`  (Spotify URI)
///   - `"tidal:tidal:track:999"`  (future service)
///
/// This format is deterministic and round-trips through Codable safely.
struct UnifiedTrackID: Codable, Equatable, Hashable, CustomStringConvertible {
    /// The service that owns this track (e.g. "appleMusic", "spotify").
    let serviceID: String
    /// The native identifier within that service.
    let nativeID: String

    /// Canonical string form: `"serviceID:nativeID"`.
    var description: String { "\(serviceID):\(nativeID)" }

    /// Build from components.
    init(serviceID: String, nativeID: String) {
        self.serviceID = serviceID
        self.nativeID = nativeID
    }

    /// Parse from canonical string `"serviceID:nativeID"`.
    /// Returns nil if the string has no colon.
    init?(string: String) {
        guard let colonIndex = string.firstIndex(of: ":") else { return nil }
        self.serviceID = String(string[string.startIndex..<colonIndex])
        self.nativeID  = String(string[string.index(after: colonIndex)...])
        guard !serviceID.isEmpty, !nativeID.isEmpty else { return nil }
    }

    // Codable as a single string
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = UnifiedTrackID(string: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid UnifiedTrackID: \(raw)"
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A service-agnostic track that any backend can produce.
struct UnifiedTrack: Identifiable, Equatable, Hashable {
    let id: String               // Unique within the service (persistentID or URI)
    let serviceID: String        // Which service this track belongs to
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?         // Remote artwork (Spotify); nil for Apple Music
    let durationSeconds: Double

    /// Convenience: formatted duration
    var durationString: String {
        let total = Int(durationSeconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Cross-service identifier that uniquely identifies this track.
    var trackID: UnifiedTrackID {
        UnifiedTrackID(serviceID: serviceID, nativeID: id)
    }
}

/// A service-agnostic playlist.
struct UnifiedPlaylist: Identifiable, Equatable, Hashable {
    let id: String
    let serviceID: String
    let name: String
    let trackCount: Int
    let artworkURL: URL?
    let ownerName: String?
}

/// A service-agnostic album.
struct UnifiedAlbum: Identifiable, Equatable, Hashable {
    let id: String
    let serviceID: String
    let title: String
    let artist: String
    let trackCount: Int
    let artworkURL: URL?
}

// ══════════════════════════════════════════════════════════════════════════
// MARK: - Connection Status
// ══════════════════════════════════════════════════════════════════════════

/// Describes the connection state of a music service.
enum MusicServiceConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// ══════════════════════════════════════════════════════════════════════════
// MARK: - Protocol
// ══════════════════════════════════════════════════════════════════════════

/// Conforming types provide a complete music service backend.
/// The `MusicService` orchestrator holds an array of providers
/// and delegates to whichever one the user has selected / is active.
@MainActor
protocol MusicServiceProvider: AnyObject {

    // ── Identity ──────────────────────────────────────────────────────────
    /// Machine-readable identifier (e.g. "appleMusic", "spotify").
    var serviceID: String { get }
    /// Human-readable name (e.g. "Apple Music", "Spotify").
    var displayName: String { get }
    /// SF Symbol name for this service.
    var iconName: String { get }
    /// Brand tint color.
    var accentColor: Color { get }

    // ── Connection ────────────────────────────────────────────────────────
    var connectionStatus: MusicServiceConnectionStatus { get }
    func connect()
    func disconnect()

    // ── Now Playing ───────────────────────────────────────────────────────
    var nowPlaying: UnifiedTrack? { get }
    var isPlaying: Bool { get }
    var progressFraction: Float { get }
    var currentTimeString: String { get }
    var totalTimeString: String { get }

    // ── Transport Controls ────────────────────────────────────────────────
    func togglePlayPause() async
    func next() async
    func previous() async
    func seek(fraction: Float) async

    // ── Library / Browsing ────────────────────────────────────────────────
    var librarySongs: [UnifiedTrack] { get }
    var libraryPlaylists: [UnifiedPlaylist] { get }
    var libraryAlbums: [UnifiedAlbum] { get }
    var isLibraryLoading: Bool { get }
    var libraryError: String? { get }

    /// Refresh / fetch the user's library (songs, playlists, albums).
    func refreshLibrary() async
    /// Play a specific track.
    func playSong(_ track: UnifiedTrack) async
    /// Play a track by its native ID (the service-local identifier).
    /// Returns true if the ID was recognized and playback was initiated.
    func playSongByNativeID(_ nativeID: String) async -> Bool
    /// Play a playlist.
    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool) async
    /// Play an album.
    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool) async

    /// Fetch the tracks inside a playlist.
    /// Returns an ordered list of tracks; empty if unavailable.
    func fetchPlaylistTracks(_ playlist: UnifiedPlaylist) async -> [UnifiedTrack]

    // ── Cross-service search ──────────────────────────────────────────────
    /// Search for a track by title and artist on this service.
    /// Used by `captureAttachment()` to cross-match songs across providers.
    /// Returns the best match, or nil if nothing was found.
    func searchTrack(title: String, artist: String) async -> UnifiedTrack?

    // ── Audio Levels (render-thread readable) ─────────────────────────────
    /// These are read from the render thread for audio-reactive visuals.
    var bassLevel: Float { get }
    var midLevel: Float { get }
    var trebleLevel: Float { get }
    var beatIntensity: Float { get }
    var overallLevel: Float { get }

    /// Called every frame to advance beat-sync / audio analysis.
    func updateFrame()
}

// MARK: - Default implementations

extension MusicServiceProvider {
    var isConnected: Bool { connectionStatus.isConnected }
}
