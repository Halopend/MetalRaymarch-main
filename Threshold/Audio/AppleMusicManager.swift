import Foundation
import MediaPlayer
import QuartzCore

@MainActor
@Observable
final class AppleMusicManager {
    struct LibrarySong: Identifiable, Hashable {
        let id: UInt64
        let title: String
        let artist: String
        let album: String
    }

    struct LibraryPlaylist: Identifiable, Hashable {
        let id: UInt64
        let name: String
        let trackCount: Int
    }

    struct LibraryAlbum: Identifiable, Hashable {
        let id: UInt64
        let title: String
        let artist: String
        let trackCount: Int
    }

    @ObservationIgnored nonisolated(unsafe) private(set) var bassLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var midLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var trebleLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var beatIntensity: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var overallLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var isActive: Bool = false

    private(set) var authorizationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined
    private(set) var nowPlayingTitle: String = ""
    private(set) var nowPlayingArtist: String = ""
    private(set) var isPlaying: Bool = false
    private(set) var playbackTimeSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var librarySongs: [LibrarySong] = []
    private(set) var libraryPlaylists: [LibraryPlaylist] = []
    private(set) var libraryAlbums: [LibraryAlbum] = []
    private(set) var libraryLoading: Bool = false
    private(set) var libraryErrorMessage: String?

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

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var lastUpdateTime: CFTimeInterval = 0
    private var monitorTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var songLookup: [UInt64: MPMediaItem] = [:]
    private var playlistLookup: [UInt64: MPMediaPlaylist] = [:]
    private var albumLookup: [UInt64: MPMediaItemCollection] = [:]

    init() {
        authorizationStatus = MPMediaLibrary.authorizationStatus()
        player.beginGeneratingPlaybackNotifications()
        observePlayerNotifications()
        if isAuthorized {
            startMonitoring()
            refreshLibrary()
        }
        updateMetadata()
    }

    func requestAuthorization() {
        if authorizationStatus == .authorized {
            startMonitoring()
            refreshLibrary()
            updateFrame()
            return
        }

        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status == .authorized {
                    self?.startMonitoring()
                    self?.refreshLibrary()
                    self?.updateFrame()
                } else {
                    self?.stopMonitoring()
                    self?.clearLibrary(reason: "Apple Music access is required to browse songs and playlists.")
                }
            }
        }
    }

    func refreshLibrary() {
        guard isAuthorized else {
            clearLibrary(reason: "Apple Music access is required to browse songs and playlists.")
            return
        }

        libraryLoading = true
        libraryErrorMessage = nil

        let songItems = MPMediaQuery.songs().items ?? []
        songLookup = Dictionary(uniqueKeysWithValues: songItems.map { ($0.persistentID, $0) })
        librarySongs = songItems
            .map {
                LibrarySong(
                    id: $0.persistentID,
                    title: $0.title ?? "Unknown Title",
                    artist: $0.artist ?? "Unknown Artist",
                    album: $0.albumTitle ?? "Unknown Album"
                )
            }
            .sorted {
                if $0.title == $1.title { return $0.artist < $1.artist }
                return $0.title < $1.title
            }

        let playlists = (MPMediaQuery.playlists().collections as? [MPMediaPlaylist]) ?? []
        playlistLookup = Dictionary(uniqueKeysWithValues: playlists.map { ($0.persistentID, $0) })
        libraryPlaylists = playlists
            .map {
                LibraryPlaylist(
                    id: $0.persistentID,
                    name: $0.name ?? "Untitled Playlist",
                    trackCount: $0.count
                )
            }
            .sorted { $0.name < $1.name }

        let albums = MPMediaQuery.albums().collections ?? []
        albumLookup = Dictionary(uniqueKeysWithValues: albums.map { ($0.persistentID, $0) })
        libraryAlbums = albums
            .compactMap { collection in
                guard let representative = collection.representativeItem else { return nil }
                return LibraryAlbum(
                    id: collection.persistentID,
                    title: representative.albumTitle ?? "Unknown Album",
                    artist: representative.albumArtist ?? representative.artist ?? "Unknown Artist",
                    trackCount: collection.count
                )
            }
            .sorted {
                if $0.title == $1.title { return $0.artist < $1.artist }
                return $0.title < $1.title
            }

        libraryLoading = false
    }

    func playSong(id: UInt64) {
        guard isAuthorized else {
            requestAuthorization()
            return
        }

        if songLookup.isEmpty {
            refreshLibrary()
        }
        guard let item = songLookup[id] else {
            libraryErrorMessage = "Song unavailable in your Apple Music library."
            return
        }

        player.setQueue(with: MPMediaItemCollection(items: [item]))
        player.play()
        startMonitoring()
        updateFrame()
    }

    /// Return the songs inside a playlist, without starting playback.
    func playlistTracks(id: UInt64) -> [LibrarySong] {
        if playlistLookup.isEmpty { refreshLibrary() }
        guard let playlist = playlistLookup[id] else { return [] }
        return playlist.items.map { item in
            LibrarySong(
                id: item.persistentID,
                title: item.title ?? "Unknown Title",
                artist: item.artist ?? "Unknown Artist",
                album: item.albumTitle ?? ""
            )
        }
    }

    func playPlaylist(id: UInt64, shuffle: Bool = false) {
        guard isAuthorized else {
            requestAuthorization()
            return
        }

        if playlistLookup.isEmpty {
            refreshLibrary()
        }
        guard let playlist = playlistLookup[id] else {
            libraryErrorMessage = "Playlist unavailable in your Apple Music library."
            return
        }

        player.shuffleMode = shuffle ? .songs : .off
        player.setQueue(with: playlist)
        player.play()
        startMonitoring()
        updateFrame()
    }

    func playAlbum(id: UInt64, shuffle: Bool = false) {
        guard isAuthorized else {
            requestAuthorization()
            return
        }

        if albumLookup.isEmpty {
            refreshLibrary()
        }
        guard let album = albumLookup[id] else {
            libraryErrorMessage = "Album unavailable in your Apple Music library."
            return
        }

        player.shuffleMode = shuffle ? .songs : .off
        player.setQueue(with: album)
        player.play()
        startMonitoring()
        updateFrame()
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

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        updateFrame()
    }

    func nextTrack() {
        player.skipToNextItem()
        updateFrame()
    }

    func previousTrack() {
        player.skipToPreviousItem()
        updateFrame()
    }

    func updateFrame() {
        let state = player.playbackState
        isPlaying = (state == .playing)
        isActive = isPlaying
        updateMetadata()

        guard isPlaying else {
            decayToZero()
            return
        }

        let now = CACurrentMediaTime()
        let dt = lastUpdateTime > 0 ? Float(now - lastUpdateTime) : Float(1.0 / 90.0)
        lastUpdateTime = now
        let clampedDt = max(0.001, min(0.1, dt))

        playbackTimeSeconds = max(0, player.currentPlaybackTime)

        let item = player.nowPlayingItem

        let bpmValue = (item?.value(forProperty: MPMediaItemPropertyBeatsPerMinute) as? NSNumber)?.floatValue ?? 120
        let bpm = max(70, min(190, bpmValue))
        let phase = Float(player.currentPlaybackTime) * (bpm / 60.0)

        // Beat pulse from playback time and BPM metadata
        let beatPulse = pow(max(0, sin(phase * 2.0 * .pi)), 4)

        // Lightweight synthetic band split (until we add Apple Music analysis APIs)
        let bassTarget = min(1.0, beatPulse * 0.95)
        let midTarget = min(1.0, 0.35 + 0.45 * (0.5 + 0.5 * sin(phase * .pi)))
        let trebleTarget = min(1.0, 0.25 + 0.55 * (0.5 + 0.5 * sin(phase * 3.2 * .pi + 0.8)))

        smooth(&bassLevel, target: bassTarget, attack: 24, decay: 8, dt: clampedDt)
        smooth(&midLevel, target: midTarget, attack: 14, decay: 6, dt: clampedDt)
        smooth(&trebleLevel, target: trebleTarget, attack: 18, decay: 9, dt: clampedDt)
        smooth(&beatIntensity, target: beatPulse, attack: 40, decay: 9, dt: clampedDt)
        overallLevel = bassLevel * 0.45 + midLevel * 0.3 + trebleLevel * 0.25
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

    private func clearLibrary(reason: String? = nil) {
        librarySongs = []
        libraryPlaylists = []
        libraryAlbums = []
        songLookup = [:]
        playlistLookup = [:]
        albumLookup = [:]
        libraryLoading = false
        libraryErrorMessage = reason
    }

    private func observePlayerNotifications() {
        let center = NotificationCenter.default
        let playbackObserver = center.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateFrame()
            }
        }

        let nowPlayingObserver = center.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateFrame()
            }
        }

        notificationObservers = [playbackObserver, nowPlayingObserver]
    }

    private func updateMetadata() {
        let item = player.nowPlayingItem
        nowPlayingTitle = item?.title ?? ""
        nowPlayingArtist = item?.artist ?? item?.albumTitle ?? ""
        durationSeconds = max(0, item?.playbackDuration ?? 0)
        if !isPlaying {
            playbackTimeSeconds = max(0, player.currentPlaybackTime)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
