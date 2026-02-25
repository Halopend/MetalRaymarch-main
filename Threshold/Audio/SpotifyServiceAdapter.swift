//
//  SpotifyServiceAdapter.swift
//  Threshold
//
//  Adapts SpotifyManager to the unified MusicServiceProvider protocol.
//  Thin wrapper — all real work lives in SpotifyManager.
//

import SwiftUI

@MainActor
final class SpotifyServiceAdapter: MusicServiceProvider {

    // ── Backing manager ──────────────────────────────────────────────────
    let manager: SpotifyManager

    init(manager: SpotifyManager) {
        self.manager = manager
    }

    // ── Identity ─────────────────────────────────────────────────────────
    let serviceID   = "spotify"
    let displayName = "Spotify"
    let iconName    = "music.note.tv"
    var accentColor: Color { .green }

    // ── Connection ───────────────────────────────────────────────────────
    var connectionStatus: MusicServiceConnectionStatus {
        if let err = manager.error {
            return .error(err)
        }
        return manager.isConnected ? .connected : .disconnected
    }

    func connect() {
        manager.connect()
    }

    func disconnect() {
        manager.disconnect()
    }

    // ── Now Playing ──────────────────────────────────────────────────────
    var nowPlaying: UnifiedTrack? {
        guard let track = manager.currentTrack else { return nil }
        return UnifiedTrack(
            id: track.uri,
            serviceID: serviceID,
            title: track.name,
            artist: track.artistNames,
            album: track.album.name,
            artworkURL: track.album.thumbnailURL,
            durationSeconds: Double(track.durationMs) / 1000.0
        )
    }

    var isPlaying: Bool { manager.isPlaying }

    var progressFraction: Float { manager.progressFraction }
    var currentTimeString: String { manager.currentTimeString }
    var totalTimeString: String { manager.totalTimeString }

    // ── Transport ────────────────────────────────────────────────────────
    func togglePlayPause() async { await manager.togglePlayPause() }
    func next() async            { await manager.next() }
    func previous() async        { await manager.previous() }
    func seek(fraction: Float) async { await manager.seek(fraction: fraction) }

    // ── Library ──────────────────────────────────────────────────────────
    var librarySongs: [UnifiedTrack] {
        manager.savedTracks.map { saved in
            let t = saved.track
            return UnifiedTrack(
                id: t.uri,
                serviceID: serviceID,
                title: t.name,
                artist: t.artistNames,
                album: t.album.name,
                artworkURL: t.album.thumbnailURL,
                durationSeconds: Double(t.durationMs) / 1000.0
            )
        }
    }

    var libraryPlaylists: [UnifiedPlaylist] {
        manager.userPlaylists.map { pl in
            UnifiedPlaylist(
                id: pl.uri,
                serviceID: serviceID,
                name: pl.name,
                trackCount: pl.tracks.total,
                artworkURL: pl.thumbnailURL,
                ownerName: pl.owner.displayName
            )
        }
    }

    var libraryAlbums: [UnifiedAlbum] {
        manager.savedAlbums.map { saved in
            let a = saved.album
            return UnifiedAlbum(
                id: a.uri,
                serviceID: serviceID,
                title: a.name,
                artist: a.artistNames,
                trackCount: a.totalTracks,
                artworkURL: a.thumbnailURL
            )
        }
    }

    var isLibraryLoading: Bool { manager.isLibraryLoading }
    var libraryError: String? { manager.libraryError }

    func refreshLibrary() async {
        await manager.refreshLibrary()
    }

    func playSong(_ track: UnifiedTrack) async {
        await manager.playTrackURI(track.id)
    }

    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool) async {
        // Spotify playlist URI format: spotify:playlist:ID
        await manager.playContext(playlist.id, shuffle: shuffle)
    }

    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool) async {
        await manager.playContext(album.id, shuffle: shuffle)
    }

    func playSongByNativeID(_ nativeID: String) async -> Bool {
        await manager.playTrackURI(nativeID)
        return true
    }

    // ── Search ───────────────────────────────────────────────────────────
    func searchTrack(title: String, artist: String) async -> UnifiedTrack? {
        guard connectionStatus.isConnected else { return nil }

        let query = "\(title) artist:\(artist)"
        let results = await manager.searchTracks(query: query, limit: 3)
        guard let best = results.first else { return nil }

        return UnifiedTrack(
            id: best.uri,
            serviceID: serviceID,
            title: best.name,
            artist: best.artistNames,
            album: best.album.name,
            artworkURL: best.album.thumbnailURL,
            durationSeconds: Double(best.durationMs) / 1000.0
        )
    }

    // ── Audio Levels ─────────────────────────────────────────────────────
    var bassLevel: Float     { manager.bassLevel }
    var midLevel: Float      { manager.midLevel }
    var trebleLevel: Float   { manager.trebleLevel }
    var beatIntensity: Float { manager.beatIntensity }
    var overallLevel: Float  { manager.overallLevel }

    func updateFrame() { manager.updateFrame() }
}
