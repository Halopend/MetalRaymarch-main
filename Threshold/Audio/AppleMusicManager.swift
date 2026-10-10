import Foundation
@preconcurrency import MediaPlayer
import os
import QuartzCore

private struct AppleMusicPlaybackSnapshot: Sendable {
    let isPlaying: Bool
    let isStopped: Bool
    let playbackTime: Double
    let duration: Double
    let title: String
    let artist: String
    let album: String
    let persistentID: UInt64?
    let beatsPerMinute: Float
}

/// MediaPlayer getters can synchronously wait for Apple's account service.
/// Keep those IPC reads off the main actor so an account-store failure cannot
/// freeze rendering or control input.
private final class AppleMusicPlaybackReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.puppypower.Threshold.apple-music-reader", qos: .utility)
    private let pendingLock = NSLock()
    private var readPending = false
    private var player: MPMusicPlayerController?

    func readAuthorizationStatus(_ completion: @escaping @Sendable (Int) -> Void) {
        queue.async {
            completion(Int(MPMediaLibrary.authorizationStatus().rawValue))
        }
    }

    func read(_ completion: @escaping @Sendable (AppleMusicPlaybackSnapshot) -> Void) {
        pendingLock.lock()
        guard !readPending else {
            pendingLock.unlock()
            return
        }
        readPending = true
        pendingLock.unlock()

        queue.async {
            defer {
                self.pendingLock.lock()
                self.readPending = false
                self.pendingLock.unlock()
            }
            let player = self.systemPlayer()
            let item = player.nowPlayingItem
            let state = player.playbackState
            let bpm = (item?.value(forProperty: MPMediaItemPropertyBeatsPerMinute) as? NSNumber)?.floatValue ?? 120
            completion(AppleMusicPlaybackSnapshot(
                isPlaying: state == .playing,
                isStopped: state == .stopped,
                playbackTime: max(0, player.currentPlaybackTime),
                duration: max(0, item?.playbackDuration ?? 0),
                title: item?.title ?? "",
                artist: item?.artist ?? item?.albumTitle ?? "",
                album: item?.albumTitle ?? "",
                persistentID: item.map { $0.persistentID },
                beatsPerMinute: max(70, min(190, bpm))
            ))
        }
    }

    func perform(_ command: @escaping @Sendable (MPMusicPlayerController) -> Void) {
        queue.async { command(self.systemPlayer()) }
    }

    private func systemPlayer() -> MPMusicPlayerController {
        if let player { return player }
        let player = MPMusicPlayerController.systemMusicPlayer
        self.player = player
        return player
    }
}

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

    // Audio-reactive levels are written on the audio/analysis path and read on the
    // render thread every frame. @ObservationIgnored + nonisolated(unsafe) avoids
    // observation overhead and main-actor hops; the benign torn read of a single
    // Float/Bool on ARM64 is acceptable for these visual-only signals.
    @ObservationIgnored nonisolated(unsafe) private(set) var bassLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var midLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var trebleLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var beatIntensity: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var overallLevel: Float = 0
    @ObservationIgnored nonisolated(unsafe) private(set) var isActive: Bool = false

    private(set) var authorizationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined
    private(set) var nowPlayingTitle: String = ""
    private(set) var nowPlayingArtist: String = ""
    private(set) var nowPlayingAlbum: String = ""
    private(set) var nowPlayingPersistentID: UInt64?
    private(set) var isPlaying: Bool = false
    private(set) var playbackTimeSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var librarySongs: [LibrarySong] = []
    private(set) var libraryPlaylists: [LibraryPlaylist] = []
    private(set) var libraryAlbums: [LibraryAlbum] = []
    private(set) var libraryLoading: Bool = false
    private(set) var libraryErrorMessage: String?
    private(set) var isRequestingAuthorization = false
    private(set) var connectionErrorMessage: String?

    @ObservationIgnored var onStateDidChange: (() -> Void)?
    /// Live playback progress callback: `(currentTime, duration, isPlaying)`.
    var onPlaybackProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?

    /// Fired when playback naturally reaches the end of a track.
    var onPlaybackFinished: (() -> Void)?

    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    var progressFraction: Float {
        guard durationSeconds > 0 else { return 0 }
        return Float((playbackTimeSeconds / durationSeconds).clamped(to: 0...1))
    }

    var currentTimeString: String { formatTime(playbackTimeSeconds) }
    var totalTimeString: String { formatTime(durationSeconds) }

    private let playbackReader = AppleMusicPlaybackReader()
    private(set) var isMonitoringPlayer = false
    private var authorizationTimeoutTask: Task<Void, Never>?
    private var playbackMonitoringStartPending = false
    private var authorizationStatusReadPending = false
    private var lastUpdateTime: CFTimeInterval = 0
    private var monitorTask: Task<Void, Never>?
    private var songLookup: [UInt64: MPMediaItem] = [:]
    private var playlistLookup: [UInt64: MPMediaPlaylist] = [:]
    private var albumLookup: [UInt64: MPMediaItemCollection] = [:]
    private let logger = Logger(subsystem: "com.puppypower.Threshold", category: "AppleMusic")

    init() {
        #if targetEnvironment(simulator)
        // MediaPlayer's Apple-account backend is unavailable in Simulator.
        // Avoid touching it: on current runtimes it can block while repeatedly
        // reporting ICError -7013 (account-store entitlement denied).
        authorizationStatus = .restricted
        connectionErrorMessage = "Apple Music requires a physical device."
        return
        #else
        // MediaPlayer status checks can consult the Apple-account backend too;
        // defer them to the same background queue as playback polling.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.refreshAuthorizationStatus()
        }
        #endif
    }

    /// Starts asynchronous playback polling after media-library authorization.
    private func attachToPlayerIfNeeded() {
        guard !isMonitoringPlayer else { return }
        isMonitoringPlayer = true
    }

    /// Start observing playback after the user has granted media-library
    /// access. This also picks up Apple Music started outside Threshold, which
    /// otherwise never reached the metadata-driven audio-reactive source.
    private func startAuthorizedPlaybackMonitoring() {
        guard isAuthorized else { return }
        attachToPlayerIfNeeded()
        startMonitoring()
        updateFrame()
    }

    /// Defer the one-time player lookup until after the current frame/callback.
    /// The metadata source calls this while refreshing, so users who already
    /// granted Apple Music access still get external playback updates without
    /// needing to start a track from inside Threshold.
    func ensurePlaybackMonitoringIfAuthorized() {
        guard isAuthorized, !isMonitoringPlayer, !playbackMonitoringStartPending else { return }
        playbackMonitoringStartPending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.playbackMonitoringStartPending = false
            self.startAuthorizedPlaybackMonitoring()
        }
    }

    /// Reconcile permission changes made in Settings without showing a prompt.
    func refreshAuthorizationStatus() {
        #if !targetEnvironment(simulator)
        guard !isRequestingAuthorization, !authorizationStatusReadPending else { return }
        authorizationStatusReadPending = true
        playbackReader.readAuthorizationStatus { [weak self] rawStatus in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorizationStatusReadPending = false
                guard !self.isRequestingAuthorization,
                      let status = MPMediaLibraryAuthorizationStatus(rawValue: rawStatus),
                      status != self.authorizationStatus else { return }
                self.authorizationStatus = status
                self.connectionErrorMessage = nil
                if status == .authorized {
                    self.ensurePlaybackMonitoringIfAuthorized()
                } else {
                    self.stopMonitoring()
                    self.clearLibrary(reason: "Apple Music access is required to browse songs and playlists.")
                }
                self.onStateDidChange?()
            }
        }
        #endif
    }

    func requestAuthorization() {
        #if targetEnvironment(simulator)
        connectionErrorMessage = "Apple Music requires a physical device."
        onStateDidChange?()
        return
        #else
        guard !isRequestingAuthorization else { return }

        if authorizationStatus == .authorized {
            connectionErrorMessage = nil
            onStateDidChange?()
            ensurePlaybackMonitoringIfAuthorized()
            return
        }

        isRequestingAuthorization = true
        connectionErrorMessage = nil
        onStateDidChange?()

        authorizationTimeoutTask?.cancel()
        authorizationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, self?.isRequestingAuthorization == true else { return }
            self?.isRequestingAuthorization = false
            self?.connectionErrorMessage = "Apple Music did not respond. Verify MusicKit is enabled for this App ID, then try again on a physical device."
            self?.onStateDidChange?()
        }

        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationTimeoutTask?.cancel()
                self.authorizationTimeoutTask = nil
                self.isRequestingAuthorization = false
                self.authorizationStatus = status
                if status == .authorized {
                    // Do not initialize `systemMusicPlayer` here. Keeping the
                    // authorization callback lightweight prevents an account-
                    // store failure from blocking the Connect button/main actor.
                    self.connectionErrorMessage = nil
                    self.ensurePlaybackMonitoringIfAuthorized()
                } else {
                    self.stopMonitoring()
                    self.clearLibrary(reason: "Apple Music access is required to browse songs and playlists.")
                }
                self.onStateDidChange?()
            }
        }
        #endif
    }

    func refreshLibrary() {
        guard isAuthorized else {
            clearLibrary(reason: "Apple Music access is required to browse songs and playlists.")
            return
        }

        libraryLoading = true
        libraryErrorMessage = nil
        onStateDidChange?()

        let songItems = sanitizedMediaItems(MPMediaQuery.songs().items ?? [], kind: "songs")
        songLookup = Dictionary(songItems.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
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

        let playlists = sanitizedMediaItems((MPMediaQuery.playlists().collections as? [MPMediaPlaylist]) ?? [], kind: "playlists")
        playlistLookup = Dictionary(playlists.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
        libraryPlaylists = playlists
            .map {
                LibraryPlaylist(
                    id: $0.persistentID,
                    name: $0.name ?? "Untitled Playlist",
                    trackCount: $0.count
                )
            }
            .sorted { $0.name < $1.name }

        let albums = sanitizedMediaItems(MPMediaQuery.albums().collections ?? [], kind: "albums")
        albumLookup = Dictionary(albums.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
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
        onStateDidChange?()
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

        attachToPlayerIfNeeded()
        playbackReader.perform { player in
            player.setQueue(with: MPMediaItemCollection(items: [item]))
            player.play()
        }
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

        attachToPlayerIfNeeded()
        playbackReader.perform { player in
            player.shuffleMode = shuffle ? .songs : .off
            player.setQueue(with: playlist)
            player.play()
        }
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

        attachToPlayerIfNeeded()
        playbackReader.perform { player in
            player.shuffleMode = shuffle ? .songs : .off
            player.setQueue(with: album)
            player.play()
        }
        startMonitoring()
        updateFrame()
    }

    func startMonitoring(pollInterval: Duration = .milliseconds(200)) {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateFrame()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func togglePlayPause() {
        let shouldPlay = !isPlaying
        playbackReader.perform { player in shouldPlay ? player.play() : player.pause() }
        updateFrame()
    }

    func nextTrack() {
        playbackReader.perform { $0.skipToNextItem() }
        updateFrame()
    }

    func previousTrack() {
        playbackReader.perform { $0.skipToPreviousItem() }
        updateFrame()
    }

    func seek(to fraction: Float) {
        let position = Double(fraction) * durationSeconds
        playbackReader.perform { $0.currentPlaybackTime = position }
        updateFrame()
    }

    func updateFrame() {
        // Keep player IPC disabled until the user grants access. Reads run on
        // the dedicated playback queue, never on the UI actor.
        guard isAuthorized, isMonitoringPlayer else { return }
        playbackReader.read { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.isAuthorized, self.isMonitoringPlayer else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: AppleMusicPlaybackSnapshot) {
        let wasPlaying = isPlaying
        let previousPlaybackTime = playbackTimeSeconds
        let previousDuration = durationSeconds

        let isNowPlaying = snapshot.isPlaying
        isPlaying = isNowPlaying
        isActive = isNowPlaying
        nowPlayingTitle = snapshot.title
        nowPlayingArtist = snapshot.artist
        nowPlayingAlbum = snapshot.album
        nowPlayingPersistentID = snapshot.persistentID
        durationSeconds = snapshot.duration
        playbackTimeSeconds = snapshot.playbackTime

        if wasPlaying && !isNowPlaying && snapshot.isStopped {
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

        let phase = Float(snapshot.playbackTime) * (snapshot.beatsPerMinute / 60.0)

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

    private func sanitizedMediaItems<Item>(_ items: [Item], kind: String, persistentID: (Item) -> UInt64 = { item in
        guard let mediaEntity = item as? MPMediaEntity else { return 0 }
        return mediaEntity.persistentID
    }) -> [Item] {
        var seenIDs = Set<UInt64>()
        var invalidCount = 0
        var duplicateCount = 0

        let sanitizedItems = items.filter { item in
            let id = persistentID(item)
            guard id != 0 else {
                invalidCount += 1
                return false
            }

            guard seenIDs.insert(id).inserted else {
                duplicateCount += 1
                return false
            }

            return true
        }

        if invalidCount > 0 || duplicateCount > 0 {
            logger.warning(
                "Skipped \(invalidCount, privacy: .public) invalid and \(duplicateCount, privacy: .public) duplicate Apple Music \(kind, privacy: .public) during library refresh."
            )
        }

        return sanitizedItems
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
        onStateDidChange?()
    }

    private func formatTime(_ seconds: Double) -> String {
        DisplayFormat.minutesSeconds(seconds)
    }

    // ── Playlist Creation ────────────────────────────────────────────────

    /// Create a new playlist in the user's Apple Music library.
    /// Returns the playlist name on success, nil on failure.
    func createPlaylist(name: String, songIDs: [UInt64]) async -> String? {
        guard isAuthorized else { return nil }

        if songLookup.isEmpty { refreshLibrary() }

        let items = songIDs.compactMap { songLookup[$0] }
        guard !items.isEmpty else { return nil }

        let productIDs = items.compactMap { item -> String? in
            let storeID = item.playbackStoreID.trimmingCharacters(in: .whitespacesAndNewlines)
            return storeID.isEmpty ? nil : storeID
        }

        guard productIDs.count == items.count else {
            libraryErrorMessage = "Some Apple Music tracks can't be added to playlists because they don't have a store catalog ID."
            logger.warning(
                "Skipping Apple Music playlist creation because \(items.count - productIDs.count, privacy: .public) selected tracks lack playbackStoreID values."
            )
            return nil
        }

        let metadata = MPMediaPlaylistCreationMetadata(name: name)
        metadata.descriptionText = "Created by Threshold"

        return await withCheckedContinuation { continuation in
            MPMediaLibrary.default().getPlaylist(
                with: UUID(),
                creationMetadata: metadata
            ) { playlist, error in
                guard let playlist = playlist, error == nil else {
                    Task { @MainActor in
                        continuation.resume(returning: nil)
                    }
                    return
                }

                // Add items one at a time via Apple Music catalog product IDs.
                let group = DispatchGroup()
                let failCount = OSAllocatedUnfairLock(initialState: 0)
                for productID in productIDs {
                    group.enter()
                    playlist.addItem(
                        withProductID: productID,
                        completionHandler: { error in
                            if error != nil { failCount.withLock { $0 += 1 } }
                            group.leave()
                        }
                    )
                }
                group.notify(queue: .main) {
                    let failed = failCount.withLock { $0 > 0 }
                    Task { @MainActor in
                        continuation.resume(returning: failed ? nil : name)
                    }
                }
            }
        }
    }
}
