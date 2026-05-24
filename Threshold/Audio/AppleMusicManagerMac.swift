#if os(macOS)
import Foundation
import Observation

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

    private(set) var nowPlayingTitle: String = ""
    private(set) var nowPlayingArtist: String = ""
    private(set) var isPlaying: Bool = false
    private(set) var playbackTimeSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var librarySongs: [LibrarySong] = []
    private(set) var libraryPlaylists: [LibraryPlaylist] = []
    private(set) var libraryAlbums: [LibraryAlbum] = []
    private(set) var libraryLoading: Bool = false
    private(set) var libraryErrorMessage: String? = "Apple Music library playback is unavailable in the macOS build."

    var onPlaybackProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    var isAuthorized: Bool { false }
    var authorizationDescription: String { "Unavailable on macOS" }

    var progressFraction: Float {
        guard durationSeconds > 0 else { return 0 }
        return Float(max(0, min(1, playbackTimeSeconds / durationSeconds)))
    }

    var currentTimeString: String { formatTime(playbackTimeSeconds) }
    var totalTimeString: String { formatTime(durationSeconds) }

    func requestAuthorization() {
        clearLibrary(reason: "Apple Music library playback is unavailable in the macOS build.")
    }

    func refreshLibrary() {
        clearLibrary(reason: "Apple Music library playback is unavailable in the macOS build.")
    }

    func playSong(id: UInt64) {
        clearLibrary(reason: "Apple Music library playback is unavailable in the macOS build.")
    }

    func playlistTracks(id: UInt64) -> [LibrarySong] { [] }

    func playPlaylist(id: UInt64, shuffle: Bool = false) {
        clearLibrary(reason: "Apple Music library playback is unavailable in the macOS build.")
    }

    func playAlbum(id: UInt64, shuffle: Bool = false) {
        clearLibrary(reason: "Apple Music library playback is unavailable in the macOS build.")
    }

    func startMonitoring(pollInterval: Duration = .milliseconds(200)) {}

    func stopMonitoring() {}

    func togglePlayPause() {
        updateFrame()
    }

    func nextTrack() {
        updateFrame()
    }

    func previousTrack() {
        updateFrame()
    }

    func updateFrame() {
        isPlaying = false
        isActive = false
        playbackTimeSeconds = 0
        durationSeconds = 0
        decayToZero()
        onPlaybackProgress?(playbackTimeSeconds, durationSeconds, false)
    }

    func createPlaylist(name: String, songIDs: [UInt64]) async -> String? {
        clearLibrary(reason: "Apple Music playlist creation is unavailable in the macOS build.")
        return nil
    }

    private func clearLibrary(reason: String? = nil) {
        librarySongs = []
        libraryPlaylists = []
        libraryAlbums = []
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
#endif