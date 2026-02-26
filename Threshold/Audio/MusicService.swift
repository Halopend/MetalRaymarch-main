//
//  MusicService.swift
//  Threshold
//
//  Registry-based orchestrator for the unified music layer.
//  Holds an array of `MusicServiceProvider` adapters and delegates
//  to whichever one the user has selected (or auto-detected).
//
//  Supports: individual songs, playback, playlists, albums,
//  a single UI surface for all services, and a user-togglable
//  active service. New services are added by conforming to
//  `MusicServiceProvider` and registering here.
//

import SwiftUI

// MARK: - Unified Track (legacy compat)

/// A source-agnostic representation of a playing track.
/// Kept for backward compatibility with existing code that uses MusicTrack.
struct MusicTrack: Equatable {
    let source: SongSource
    let title: String
    let artist: String
    /// Apple Music persistent ID (as String) or Spotify track URI
    let identifier: String
    /// Spotify album art URL (nil for Apple Music)
    let artworkURL: URL?
}

// MARK: - Music Service

@MainActor
@Observable
final class MusicService {

    // ══════════════════════════════════════════════════════════════════════
    // PROVIDER REGISTRY
    // ══════════════════════════════════════════════════════════════════════

    /// All registered service providers, in display order.
    private(set) var providers: [MusicServiceProvider] = []

    /// Register a new music service provider.
    /// Call order determines display order in the service picker.
    func register(_ provider: MusicServiceProvider) {
        guard !providers.contains(where: { $0.serviceID == provider.serviceID }) else { return }
        providers.append(provider)
    }

    /// Look up a provider by serviceID.
    func provider(for serviceID: String) -> MusicServiceProvider? {
        providers.first { $0.serviceID == serviceID }
    }

    // ══════════════════════════════════════════════════════════════════════
    // ACTIVE SERVICE SELECTION
    // ══════════════════════════════════════════════════════════════════════

    /// User-selected preferred service ID (nil = auto-detect).
    /// Persisted across launches.
    var preferredServiceID: String? {
        get { UserDefaults.standard.string(forKey: "music.preferredServiceID") }
        set { UserDefaults.standard.set(newValue, forKey: "music.preferredServiceID") }
    }

    /// The currently active provider.
    /// Priority: 1) user's preferred service if connected,
    ///           2) whichever is currently playing,
    ///           3) first connected service with a track,
    ///           4) first connected service.
    var activeProvider: MusicServiceProvider? {
        // If user has a preference and it's connected
        if let prefID = preferredServiceID,
           let preferred = provider(for: prefID),
           preferred.isConnected {
            return preferred
        }

        // Auto: whichever is playing
        if let playing = providers.first(where: { $0.isPlaying }) {
            return playing
        }

        // Auto: whichever is connected and has a track
        if let withTrack = providers.first(where: { $0.isConnected && $0.nowPlaying != nil }) {
            return withTrack
        }

        // Auto: first connected
        return providers.first(where: { $0.isConnected })
    }

    /// Cycle through available connected services.
    func cycleActiveService() {
        let connected = providers.filter { $0.isConnected }
        guard connected.count > 1 else { return }

        if let current = preferredServiceID,
           let idx = connected.firstIndex(where: { $0.serviceID == current }) {
            let nextIdx = (idx + 1) % connected.count
            preferredServiceID = connected[nextIdx].serviceID
        } else if let first = connected.first {
            preferredServiceID = first.serviceID
        }
    }

    /// Set the preferred service by ID.
    func setPreferredService(_ serviceID: String?) {
        preferredServiceID = serviceID
    }

    // ══════════════════════════════════════════════════════════════════════
    // BACKWARD-COMPATIBLE ACCESSORS
    // ══════════════════════════════════════════════════════════════════════

    /// Direct access to backing managers (for code that still needs them).
    let appleMusic: AppleMusicManager
    let spotify: SpotifyManager

    /// Typed adapter access when needed.
    private(set) var appleMusicAdapter: AppleMusicServiceAdapter!
    private(set) var spotifyAdapter: SpotifyServiceAdapter!

    init(appleMusic: AppleMusicManager, spotify: SpotifyManager) {
        self.appleMusic = appleMusic
        self.spotify = spotify

        // Build and register adapters
        let amAdapter = AppleMusicServiceAdapter(manager: appleMusic)
        let spAdapter = SpotifyServiceAdapter(manager: spotify)
        self.appleMusicAdapter = amAdapter
        self.spotifyAdapter = spAdapter
        register(amAdapter)
        register(spAdapter)
    }

    // ══════════════════════════════════════════════════════════════════════
    // NOW PLAYING (delegated to active provider)
    // ══════════════════════════════════════════════════════════════════════

    /// Which backend is currently the active source (legacy enum).
    var activeSource: SongSource? {
        guard let p = activeProvider else { return nil }
        return songSource(for: p.serviceID)
    }

    /// Unified now-playing track (nil when nothing is loaded).
    var nowPlaying: MusicTrack? {
        guard let p = activeProvider, let track = p.nowPlaying else { return nil }
        return MusicTrack(
            source: songSource(for: p.serviceID) ?? .appleMusic,
            title: track.title,
            artist: track.artist,
            identifier: track.id,
            artworkURL: track.artworkURL
        )
    }

    /// Unified now-playing as `UnifiedTrack`.
    var nowPlayingUnified: UnifiedTrack? {
        activeProvider?.nowPlaying
    }

    var isPlaying: Bool {
        providers.contains { $0.isPlaying }
    }

    var progressFraction: Float {
        activeProvider?.progressFraction ?? 0
    }

    var currentTimeString: String {
        activeProvider?.currentTimeString ?? "0:00"
    }

    var totalTimeString: String {
        activeProvider?.totalTimeString ?? "0:00"
    }

    /// Tint color for the active source.
    var accentColor: Color {
        activeProvider?.accentColor ?? .secondary
    }

    /// SF Symbol icon for the active source.
    var sourceIcon: String {
        activeProvider?.iconName ?? "music.note"
    }

    // ══════════════════════════════════════════════════════════════════════
    // TRANSPORT CONTROLS (delegated to active provider)
    // ══════════════════════════════════════════════════════════════════════

    func togglePlayPause() {
        guard let p = activeProvider else { return }
        Task { await p.togglePlayPause() }
    }

    func next() {
        guard let p = activeProvider else { return }
        Task { await p.next() }
    }

    func previous() {
        guard let p = activeProvider else { return }
        Task { await p.previous() }
    }

    func seek(fraction: Float) {
        guard let p = activeProvider else { return }
        Task { await p.seek(fraction: fraction) }
    }

    // ══════════════════════════════════════════════════════════════════════
    // LIBRARY (delegated to active provider — or specific provider)
    // ══════════════════════════════════════════════════════════════════════

    /// Songs from the given (or active) provider.
    func librarySongs(for serviceID: String? = nil) -> [UnifiedTrack] {
        resolvedProvider(serviceID)?.librarySongs ?? []
    }

    func libraryPlaylists(for serviceID: String? = nil) -> [UnifiedPlaylist] {
        resolvedProvider(serviceID)?.libraryPlaylists ?? []
    }

    func libraryAlbums(for serviceID: String? = nil) -> [UnifiedAlbum] {
        resolvedProvider(serviceID)?.libraryAlbums ?? []
    }

    func isLibraryLoading(for serviceID: String? = nil) -> Bool {
        resolvedProvider(serviceID)?.isLibraryLoading ?? false
    }

    func libraryError(for serviceID: String? = nil) -> String? {
        resolvedProvider(serviceID)?.libraryError
    }

    func refreshLibrary(for serviceID: String? = nil) {
        guard let p = resolvedProvider(serviceID) else { return }
        Task { await p.refreshLibrary() }
    }

    func playSong(_ track: UnifiedTrack) {
        guard let p = provider(for: track.serviceID) else { return }
        Task { await p.playSong(track) }
    }

    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool = false) {
        guard let p = provider(for: playlist.serviceID) else { return }
        Task { await p.playPlaylist(playlist, shuffle: shuffle) }
    }

    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool = false) {
        guard let p = provider(for: album.serviceID) else { return }
        Task { await p.playAlbum(album, shuffle: shuffle) }
    }

    private func resolvedProvider(_ serviceID: String?) -> MusicServiceProvider? {
        if let id = serviceID { return provider(for: id) }
        return activeProvider
    }

    // ══════════════════════════════════════════════════════════════════════
    // SONG ATTACHMENT — capture & playback
    // ══════════════════════════════════════════════════════════════════════

    // ── Service Priority (for fallback ordering) ──────────────────────────

    /// User-configured service priority for fallback playback.
    /// Persisted in UserDefaults as a JSON array of service IDs.
    /// Example: `["spotify", "appleMusic"]` — try Spotify first, then Apple Music.
    /// If empty/nil, uses the default provider registration order.
    var servicePriority: [String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "music.servicePriority"),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                return providers.map(\.serviceID)
            }
            return ids
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "music.servicePriority")
            }
        }
    }

    /// Move a service up in the priority list.
    func moveServiceUp(_ serviceID: String) {
        var order = servicePriority
        guard let idx = order.firstIndex(of: serviceID), idx > 0 else { return }
        order.swapAt(idx, idx - 1)
        servicePriority = order
    }

    /// Move a service down in the priority list.
    func moveServiceDown(_ serviceID: String) {
        var order = servicePriority
        guard let idx = order.firstIndex(of: serviceID), idx < order.count - 1 else { return }
        order.swapAt(idx, idx + 1)
        servicePriority = order
    }

    /// Reorder the priority list (e.g. from drag-and-drop).
    func setServicePriority(_ order: [String]) {
        servicePriority = order
    }

    // ── Capture ───────────────────────────────────────────────────────────

    /// Capture the current now-playing track as a `SongAttachment`
    /// suitable for storing on an `AnimationScene`.
    ///
    /// Synchronously captures from the active provider, then returns
    /// immediately. Cross-matching across other services happens
    /// asynchronously — call `crossMatchAttachment(_:)` afterward
    /// to fill in alternative IDs for fallback playback.
    func captureAttachment() -> SongAttachment? {
        guard let p = activeProvider, let track = p.nowPlaying else { return nil }
        return SongAttachment(
            trackID: track.trackID,
            title: track.title,
            artist: track.artist
        )
    }

    /// Search all *other* connected services for the same song and
    /// return an updated attachment with additional trackIDs.
    /// Call this after `captureAttachment()` to enrich the attachment.
    func crossMatchAttachment(_ attachment: SongAttachment) async -> SongAttachment {
        var ids = attachment.trackIDs
        let title = attachment.title
        let artist = attachment.artist
        let originService = attachment.trackID.serviceID

        // Search each connected provider that isn't the origin
        await withTaskGroup(of: UnifiedTrackID?.self) { group in
            for provider in self.connectedProviders where provider.serviceID != originService {
                let providerRef = provider
                group.addTask { @MainActor in
                    guard let match = await providerRef.searchTrack(title: title, artist: artist) else {
                        return nil
                    }
                    return match.trackID
                }
            }

            for await maybeID in group {
                if let id = maybeID, !ids.contains(id) {
                    ids.append(id)
                }
            }
        }

        return SongAttachment(trackIDs: ids, title: title, artist: artist)
    }

    /// Convenience: capture + cross-match in one async call.
    func captureAttachmentWithFallbacks() async -> SongAttachment? {
        guard let attachment = captureAttachment() else { return nil }
        return await crossMatchAttachment(attachment)
    }

    // ── Playback with fallback ────────────────────────────────────────────

    /// Play a previously captured song attachment.
    /// Walks the `trackIDs` in the user's service priority order,
    /// falling back to the next service if one fails or isn't connected.
    func play(attachment: SongAttachment) {
        Task {
            let prioritizedIDs = prioritize(attachment.trackIDs)

            for tid in prioritizedIDs {
                guard let p = provider(for: tid.serviceID),
                      p.isConnected else { continue }

                let success = await p.playSongByNativeID(tid.nativeID)
                if success { return }
            }
            // All fallbacks exhausted — nothing played
        }
    }

    /// Reorder trackIDs by the user's service priority.
    private func prioritize(_ trackIDs: [UnifiedTrackID]) -> [UnifiedTrackID] {
        let order = servicePriority
        return trackIDs.sorted { a, b in
            let idxA = order.firstIndex(of: a.serviceID) ?? Int.max
            let idxB = order.firstIndex(of: b.serviceID) ?? Int.max
            return idxA < idxB
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // CONNECTION STATUS
    // ══════════════════════════════════════════════════════════════════════

    var isAppleMusicConnected: Bool { appleMusic.isAuthorized }
    var isSpotifyConnected: Bool { spotify.isConnected }

    /// At least one music service is available.
    var hasAnyConnection: Bool {
        providers.contains { $0.isConnected }
    }

    /// All connected providers.
    var connectedProviders: [MusicServiceProvider] {
        providers.filter { $0.isConnected }
    }

    // ══════════════════════════════════════════════════════════════════════
    // PRIVATE HELPERS
    // ══════════════════════════════════════════════════════════════════════

    /// Map a serviceID to the legacy `SongSource` enum.
    private func songSource(for serviceID: String) -> SongSource? {
        switch serviceID {
        case "appleMusic": return .appleMusic
        case "spotify":    return .spotify
        default:           return nil
        }
    }
}
