//
//  AppleMusicServiceAdapter.swift
//  Threshold
//
//  Adapts AppleMusicManager to the unified MusicServiceProvider protocol.
//  Thin wrapper — all real work lives in AppleMusicManager.
//

import SwiftUI
#if !os(macOS)
import MediaPlayer
#endif

@MainActor
final class AppleMusicServiceAdapter: MusicServiceProvider {

    // ── Backing manager ──────────────────────────────────────────────────
    let manager: AppleMusicManager

    init(manager: AppleMusicManager) {
        self.manager = manager
    }

    // ── Identity ─────────────────────────────────────────────────────────
    let serviceID   = "appleMusic"
    let displayName = "Apple Music"
    let iconName    = "apple.logo"
    var accentColor: Color { .pink }

    // ── Connection ───────────────────────────────────────────────────────
    var connectionStatus: MusicServiceConnectionStatus {
        switch manager.authorizationStatus {
        case .authorized:    return .connected
        case .denied:        return .error("Access denied. Enable in Settings.")
        case .restricted:    return .error("Apple Music is restricted on this device.")
        case .notDetermined: return .disconnected
        @unknown default:    return .disconnected
        }
    }

    func connect() {
        manager.requestAuthorization()
    }

    func disconnect() {
        // Apple Music doesn't have a disconnect — revoked via Settings.
        manager.stopMonitoring()
    }

    // ── Now Playing ──────────────────────────────────────────────────────
    var nowPlaying: UnifiedTrack? {
        guard !manager.nowPlayingTitle.isEmpty else { return nil }
        let player = MPMusicPlayerController.systemMusicPlayer
        let pid = player.nowPlayingItem?.persistentID
        return UnifiedTrack(
            id: pid.map { String($0) } ?? UUID().uuidString,
            serviceID: serviceID,
            title: manager.nowPlayingTitle,
            artist: manager.nowPlayingArtist,
            album: player.nowPlayingItem?.albumTitle ?? "",
            artworkURL: nil,
            durationSeconds: manager.durationSeconds
        )
    }

    var isPlaying: Bool { manager.isPlaying }

    var progressFraction: Float { manager.progressFraction }
    var currentTimeString: String { manager.currentTimeString }
    var totalTimeString: String { manager.totalTimeString }

    // ── Transport ────────────────────────────────────────────────────────
    func togglePlayPause() async { manager.togglePlayPause() }
    func next() async            { manager.nextTrack() }
    func previous() async        { manager.previousTrack() }
    func seek(fraction: Float) async {
        let player = MPMusicPlayerController.systemMusicPlayer
        let pos = Double(fraction) * manager.durationSeconds
        player.currentPlaybackTime = pos
        manager.updateFrame()
    }

    // ── Library ──────────────────────────────────────────────────────────
    var librarySongs: [UnifiedTrack] {
        manager.librarySongs.map { song in
            UnifiedTrack(
                id: String(song.id),
                serviceID: serviceID,
                title: song.title,
                artist: song.artist,
                album: song.album,
                artworkURL: nil,
                durationSeconds: 0  // MediaPlayer doesn't store duration on query items cheaply
            )
        }
    }

    var libraryPlaylists: [UnifiedPlaylist] {
        manager.libraryPlaylists.map { pl in
            UnifiedPlaylist(
                id: String(pl.id),
                serviceID: serviceID,
                name: pl.name,
                trackCount: pl.trackCount,
                artworkURL: nil,
                ownerName: nil
            )
        }
    }

    var libraryAlbums: [UnifiedAlbum] {
        manager.libraryAlbums.map { alb in
            UnifiedAlbum(
                id: String(alb.id),
                serviceID: serviceID,
                title: alb.title,
                artist: alb.artist,
                trackCount: alb.trackCount,
                artworkURL: nil
            )
        }
    }

    var isLibraryLoading: Bool { manager.libraryLoading }
    var libraryError: String? { manager.libraryErrorMessage }

    func refreshLibrary() async {
        manager.refreshLibrary()
    }

    func playSong(_ track: UnifiedTrack) async {
        guard let songID = UInt64(track.id) else { return }
        manager.playSong(id: songID)
    }

    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool) async {
        guard let plID = UInt64(playlist.id) else { return }
        manager.playPlaylist(id: plID, shuffle: shuffle)
    }

    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool) async {
        guard let albID = UInt64(album.id) else { return }
        manager.playAlbum(id: albID, shuffle: shuffle)
    }

    func fetchPlaylistTracks(_ playlist: UnifiedPlaylist) async -> [UnifiedTrack] {
        guard let plID = UInt64(playlist.id) else { return [] }
        return manager.playlistTracks(id: plID).map { song in
            UnifiedTrack(
                id: String(song.id),
                serviceID: serviceID,
                title: song.title,
                artist: song.artist,
                album: song.album,
                artworkURL: nil,
                durationSeconds: 0
            )
        }
    }

    func playSongByNativeID(_ nativeID: String) async -> Bool {
        guard let songID = UInt64(nativeID) else { return false }
        manager.playSong(id: songID)
        return true
    }

    // ── Search ───────────────────────────────────────────────────────────
    func searchTrack(title: String, artist: String) async -> UnifiedTrack? {
        guard connectionStatus.isConnected else { return nil }

        let query = MPMediaQuery.songs()
        query.addFilterPredicate(
            MPMediaPropertyPredicate(value: title,
                                     forProperty: MPMediaItemPropertyTitle,
                                     comparisonType: .contains)
        )

        guard let items = query.items, !items.isEmpty else { return nil }

        // Prefer an exact artist match; fall back to first result
        let normalizedArtist = artist.lowercased()
        let best = items.first {
            ($0.artist ?? "").lowercased().contains(normalizedArtist)
        } ?? items.first!

        return UnifiedTrack(
            id: String(best.persistentID),
            serviceID: serviceID,
            title: best.title ?? title,
            artist: best.artist ?? artist,
            album: best.albumTitle ?? "",
            artworkURL: nil,
            durationSeconds: best.playbackDuration
        )
    }

    // ── Playlist Creation ─────────────────────────────────────────────────
    func createPlaylist(name: String, trackNativeIDs: [String]) async -> String? {
        await manager.createPlaylist(name: name, songIDs: trackNativeIDs.compactMap { UInt64($0) })
    }

    // ── Audio Levels ─────────────────────────────────────────────────────
    var bassLevel: Float     { manager.bassLevel }
    var midLevel: Float      { manager.midLevel }
    var trebleLevel: Float   { manager.trebleLevel }
    var beatIntensity: Float { manager.beatIntensity }
    var overallLevel: Float  { manager.overallLevel }

    func updateFrame() { manager.updateFrame() }
}
