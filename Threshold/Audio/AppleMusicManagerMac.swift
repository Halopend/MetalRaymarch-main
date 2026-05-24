#if os(macOS)
import Foundation
@preconcurrency import MusicKit
import Observation
import QuartzCore
import os

@MainActor
@Observable
final class AppleMusicManager {
    struct LibrarySong: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let durationSeconds: Double
    }

    struct LibraryPlaylist: Identifiable, Hashable {
        let id: String
        let name: String
        let trackCount: Int
    }

    struct LibraryAlbum: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let trackCount: Int
    }

    private struct PlaylistSnapshot {
        let playlist: Playlist
        let tracks: [Track]
    }

    @ObservationIgnored nonisolated(unsafe) private(set) var bassLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var midLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var trebleLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var beatIntensity: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var overallLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var isActive: Bool = false

    private(set) var authorizationStatus: MusicAuthorization.Status = .notDetermined
    private(set) var nowPlayingID: String?
    private(set) var nowPlayingTitle: String = ""
    private(set) var nowPlayingArtist: String = ""
    private(set) var nowPlayingAlbum: String = ""
    private(set) var isPlaying: Bool = false
    private(set) var playbackTimeSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var librarySongs: [LibrarySong] = []
    private(set) var libraryPlaylists: [LibraryPlaylist] = []
    private(set) var libraryAlbums: [LibraryAlbum] = []
    private(set) var libraryLoading: Bool = false
    private(set) var libraryErrorMessage: String?

    var onPlaybackProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    var authorizationDescription: String {
        switch authorizationStatus {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Requested"
        @unknown default:
            return "Unknown"
        }
    }

    var progressFraction: Float {
        guard durationSeconds > 0 else { return 0 }
        return Float(max(0, min(1, playbackTimeSeconds / durationSeconds)))
    }

    var currentTimeString: String { formatTime(playbackTimeSeconds) }
    var totalTimeString: String { formatTime(durationSeconds) }

    private let player = ApplicationMusicPlayer.shared
    private let logger = Logger(subsystem: "com.puppypower.Threshold", category: "AppleMusicMac")
    private var lastUpdateTime: CFTimeInterval = 0
    private var monitorTask: Task<Void, Never>?
    private var songLookup: [String: Song] = [:]
    private var playlistLookup: [String: Playlist] = [:]
    private var albumLookup: [String: Album] = [:]
    private var playlistTracksLookup: [String: [Track]] = [:]
    private var albumTracksLookup: [String: [Track]] = [:]

    init() {
        authorizationStatus = MusicAuthorization.currentStatus
        if isAuthorized {
            startMonitoring()
            Task {
                await refreshLibrary()
            }
        }
        updateFrame()
    }

    func requestAuthorization() {
        guard authorizationStatus != .authorized else {
            startMonitoring()
            Task {
                await refreshLibrary()
                updateFrame()
            }
            return
        }

        Task {
            let status = await MusicAuthorization.request()
            authorizationStatus = status

            if status == .authorized {
                startMonitoring()
                await refreshLibrary()
                updateFrame()
            } else {
                stopMonitoring()
                clearLibrary(reason: "Apple Music access is required to browse songs and playlists.")
            }
        }
    }

    func refreshLibrary() async {
        guard isAuthorized else {
            clearLibrary(reason: "Apple Music access is required to browse songs and playlists.")
            return
        }

        libraryLoading = true
        libraryErrorMessage = nil

        do {
            async let songsTask = fetchSongs()
            async let playlistsTask = fetchPlaylists()
            async let albumsTask = fetchAlbums()

            let songs = try await songsTask
            let playlists = try await playlistsTask
            let albums = try await albumsTask

            songLookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id.rawValue, $0) })
            playlistLookup = Dictionary(uniqueKeysWithValues: playlists.map { ($0.playlist.id.rawValue, $0.playlist) })
            albumLookup = Dictionary(uniqueKeysWithValues: albums.map { ($0.id.rawValue, $0) })
            playlistTracksLookup = Dictionary(uniqueKeysWithValues: playlists.map { ($0.playlist.id.rawValue, $0.tracks) })
            albumTracksLookup = [:]

            librarySongs = songs
                .map(librarySong(from:))
                .sorted { lhs, rhs in
                    if lhs.title == rhs.title {
                        return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

            libraryPlaylists = playlists
                .map {
                    LibraryPlaylist(
                        id: $0.playlist.id.rawValue,
                        name: $0.playlist.name,
                        trackCount: $0.tracks.count
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            libraryAlbums = albums
                .map {
                    LibraryAlbum(
                        id: $0.id.rawValue,
                        title: $0.title,
                        artist: $0.artistName,
                        trackCount: $0.trackCount
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.title == rhs.title {
                        return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

            libraryLoading = false
        } catch {
            logger.error("Failed to refresh macOS Apple Music library: \(error.localizedDescription, privacy: .public)")
            clearLibrary(reason: "Couldn't load your Apple Music library on macOS.")
        }
    }

    func playSong(id: String) async {
        guard isAuthorized else {
            requestAuthorization()
            return
        }

        if songLookup[id] == nil {
            await refreshLibrary()
        }

        guard let song = songLookup[id] else {
            libraryErrorMessage = "Song unavailable in your Apple Music library."
            return
        }

        do {
            player.queue = [song]
            try await player.play()
            libraryErrorMessage = nil
            startMonitoring()
            updateFrame()
        } catch {
            reportPlaybackError(error, fallbackMessage: "Couldn't start Apple Music playback for that song.")
        }
    }

    func playlistTracks(id: String) async -> [LibrarySong] {
        if playlistLookup[id] == nil {
            await refreshLibrary()
        }

        guard let playlist = playlistLookup[id] else { return [] }

        do {
            let tracks = try await tracks(for: playlist, playlistID: id)
            return tracks.map(librarySong(from:))
        } catch {
            reportPlaybackError(error, fallbackMessage: "Couldn't load tracks for that playlist.")
            return []
        }
    }

    func playPlaylist(id: String, shuffle: Bool = false) async {
        guard isAuthorized else {
            requestAuthorization()
            return
        }

        if playlistLookup[id] == nil {
            await refreshLibrary()
        }

        guard let playlist = playlistLookup[id] else {
            libraryErrorMessage = "Playlist unavailable in your Apple Music library."
            return
        }

        do {
            let tracks = try await tracks(for: playlist, playlistID: id)
            let queue = shuffle ? tracks.shuffled() : tracks
            guard !queue.isEmpty else {
                libraryErrorMessage = "That playlist doesn't contain any playable tracks."
                return
            }

            player.queue = ApplicationMusicPlayer.Queue(for: queue)
            try await player.play()
            libraryErrorMessage = nil
            startMonitoring()
            updateFrame()
        } catch {
            reportPlaybackError(error, fallbackMessage: "Couldn't start Apple Music playback for that playlist.")
        }
    }

    func playAlbum(id: String, shuffle: Bool = false) async {
        guard isAuthorized else {
            requestAuthorization()
            return
        }

        if albumLookup[id] == nil {
            await refreshLibrary()
        }

        guard let album = albumLookup[id] else {
            libraryErrorMessage = "Album unavailable in your Apple Music library."
            return
        }

        do {
            let tracks = try await tracks(for: album, albumID: id)
            let queue = shuffle ? tracks.shuffled() : tracks
            guard !queue.isEmpty else {
                libraryErrorMessage = "That album doesn't contain any playable tracks."
                return
            }

            player.queue = ApplicationMusicPlayer.Queue(for: queue)
            try await player.play()
            libraryErrorMessage = nil
            startMonitoring()
            updateFrame()
        } catch {
            reportPlaybackError(error, fallbackMessage: "Couldn't start Apple Music playback for that album.")
        }
    }

    func startMonitoring(pollInterval: Duration = .milliseconds(200)) {
        guard monitorTask == nil else { return }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.updateFrame()
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func togglePlayPause() async {
        if isPlaying {
            player.pause()
            updateFrame()
            return
        }

        do {
            try await player.play()
            libraryErrorMessage = nil
            startMonitoring()
            updateFrame()
        } catch {
            reportPlaybackError(error, fallbackMessage: "Couldn't resume Apple Music playback.")
        }
    }

    func nextTrack() async {
        do {
            try await player.skipToNextEntry()
            libraryErrorMessage = nil
            updateFrame()
        } catch {
            reportPlaybackError(error, fallbackMessage: "Couldn't skip to the next Apple Music track.")
        }
    }

    func previousTrack() async {
        do {
            try await player.skipToPreviousEntry()
            libraryErrorMessage = nil
            updateFrame()
        } catch {
            reportPlaybackError(error, fallbackMessage: "Couldn't return to the previous Apple Music track.")
        }
    }

    func seek(fraction: Float) {
        guard durationSeconds > 0 else { return }
        player.playbackTime = durationSeconds * Double(max(0, min(1, fraction)))
        updateFrame()
    }

    func updateFrame() {
        let wasPlaying = isPlaying
        let previousPlaybackTime = playbackTimeSeconds
        let previousDuration = durationSeconds

        let playbackStatus = player.state.playbackStatus
        let isNowPlaying = playbackStatus == .playing
        isPlaying = isNowPlaying
        isActive = isNowPlaying
        updateMetadata()

        if wasPlaying && !isNowPlaying {
            let endThreshold = max(0.2, min(1.0, previousDuration * 0.02))
            let reachedEnd = previousDuration > 1.0 && previousPlaybackTime >= (previousDuration - endThreshold)
            if reachedEnd {
                onPlaybackFinished?()
            }
        }

        onPlaybackProgress?(playbackTimeSeconds, durationSeconds, isNowPlaying)

        guard isNowPlaying else {
            decayToZero()
            return
        }

        let now = CACurrentMediaTime()
        let dt = lastUpdateTime > 0 ? Float(now - lastUpdateTime) : Float(1.0 / 90.0)
        lastUpdateTime = now
        let clampedDt = max(0.001, min(0.1, dt))

        let phase = Float(playbackTimeSeconds) * 2.0
        let beatPulse = pow(max(0, sin(phase * .pi)), 4)
        let bassTarget = min(1.0, beatPulse * 0.95)
        let midTarget = min(1.0, 0.35 + 0.45 * (0.5 + 0.5 * sin(phase * .pi)))
        let trebleTarget = min(1.0, 0.25 + 0.55 * (0.5 + 0.5 * sin(phase * 3.2 * .pi + 0.8)))

        smooth(&bassLevel, target: bassTarget, attack: 24, decay: 8, dt: clampedDt)
        smooth(&midLevel, target: midTarget, attack: 14, decay: 6, dt: clampedDt)
        smooth(&trebleLevel, target: trebleTarget, attack: 18, decay: 9, dt: clampedDt)
        smooth(&beatIntensity, target: beatPulse, attack: 40, decay: 9, dt: clampedDt)
        overallLevel = bassLevel * 0.45 + midLevel * 0.3 + trebleLevel * 0.25
    }

    func createPlaylist(name: String, songIDs: [String]) async -> String? {
        libraryErrorMessage = "Creating Apple Music playlists isn't available in the macOS build."
        return nil
    }

    private func fetchSongs() async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.limit = 5_000
        let response = try await request.response()
        return Array(response.items)
    }

    private func fetchPlaylists() async throws -> [PlaylistSnapshot] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 1_000
        let response = try await request.response()

        var snapshots: [PlaylistSnapshot] = []
        snapshots.reserveCapacity(response.items.count)

        for playlist in response.items {
            let detailedPlaylist = try await playlist.with([.tracks])
            snapshots.append(
                PlaylistSnapshot(
                    playlist: detailedPlaylist,
                    tracks: Array(detailedPlaylist.tracks ?? [])
                )
            )
        }

        return snapshots
    }

    private func fetchAlbums() async throws -> [Album] {
        var request = MusicLibraryRequest<Album>()
        request.limit = 2_000
        let response = try await request.response()
        return Array(response.items)
    }

    private func tracks(for playlist: Playlist, playlistID: String) async throws -> [Track] {
        if let cachedTracks = playlistTracksLookup[playlistID] {
            return cachedTracks
        }

        let detailedPlaylist = try await playlist.with([.tracks])
        let tracks = Array(detailedPlaylist.tracks ?? [])
        playlistLookup[playlistID] = detailedPlaylist
        playlistTracksLookup[playlistID] = tracks
        return tracks
    }

    private func tracks(for album: Album, albumID: String) async throws -> [Track] {
        if let cachedTracks = albumTracksLookup[albumID] {
            return cachedTracks
        }

        let detailedAlbum = try await album.with([.tracks])
        let tracks = Array(detailedAlbum.tracks ?? [])
        albumLookup[albumID] = detailedAlbum
        albumTracksLookup[albumID] = tracks
        return tracks
    }

    private func librarySong(from song: Song) -> LibrarySong {
        LibrarySong(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            durationSeconds: song.duration ?? 0
        )
    }

    private func librarySong(from track: Track) -> LibrarySong {
        LibrarySong(
            id: track.id.rawValue,
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle ?? "",
            durationSeconds: track.duration ?? 0
        )
    }

    private func updateMetadata() {
        playbackTimeSeconds = max(0, player.playbackTime)
        nowPlayingID = nil
        nowPlayingTitle = ""
        nowPlayingArtist = ""
        nowPlayingAlbum = ""
        durationSeconds = 0

        if let song = player.queue.currentEntry?.item as? Song {
            nowPlayingID = song.id.rawValue
            nowPlayingTitle = song.title
            nowPlayingArtist = song.artistName
            nowPlayingAlbum = song.albumTitle ?? ""
            durationSeconds = song.duration ?? 0
            return
        }

        if let track = player.queue.currentEntry?.item as? Track {
            nowPlayingID = track.id.rawValue
            nowPlayingTitle = track.title
            nowPlayingArtist = track.artistName
            nowPlayingAlbum = track.albumTitle ?? ""
            durationSeconds = track.duration ?? 0
        }
    }

    private func clearLibrary(reason: String? = nil) {
        librarySongs = []
        libraryPlaylists = []
        libraryAlbums = []
        songLookup = [:]
        playlistLookup = [:]
        albumLookup = [:]
        playlistTracksLookup = [:]
        albumTracksLookup = [:]
        libraryLoading = false
        libraryErrorMessage = reason
    }

    private func decayToZero() {
        bassLevel *= 0.9
        midLevel *= 0.9
        trebleLevel *= 0.9
        beatIntensity *= 0.88
        overallLevel *= 0.9
    }

    private func smooth(_ value: inout Float, target: Float, attack: Float, decay: Float, dt: Float) {
        let speed = target > value ? attack : decay
        let t = 1.0 - exp(-speed * dt)
        value += (target - value) * t
    }

    private func reportPlaybackError(_ error: Error, fallbackMessage: String) {
        logger.error("Apple Music macOS operation failed: \(error.localizedDescription, privacy: .public)")
        libraryErrorMessage = fallbackMessage
        updateFrame()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
#endif