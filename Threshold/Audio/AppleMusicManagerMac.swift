#if os(macOS) || os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class AppleMusicManager {
    enum AuthorizationStatus {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

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

    private(set) var authorizationStatus: AuthorizationStatus = .restricted
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

    @ObservationIgnored var onStateDidChange: (() -> Void)?
    var onPlaybackProgress: ((TimeInterval, TimeInterval, Bool) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    var isAuthorized: Bool { false }
    var authorizationDescription: String { "Unavailable" }
    var progressFraction: Float { 0 }
    var currentTimeString: String { "0:00" }
    var totalTimeString: String { "0:00" }

    func requestAuthorization() {
        libraryErrorMessage = "Apple Music playback and library access aren't included in the macOS build. Use microphone input by default, or enable Music.app audio capture in Advanced."
        notifyStateDidChange()
    }

    func refreshLibrary() async {
        clearLibrary(reason: "Apple Music library browsing isn't included in the macOS build.")
    }

    func playSong(id: String) async {
        libraryErrorMessage = "Apple Music playback isn't included in the macOS build."
        notifyStateDidChange()
    }

    func playlistTracks(id: String) async -> [LibrarySong] { [] }

    func playPlaylist(id: String, shuffle: Bool = false) async {
        libraryErrorMessage = "Apple Music playback isn't included in the macOS build."
        notifyStateDidChange()
    }

    func playAlbum(id: String, shuffle: Bool = false) async {
        libraryErrorMessage = "Apple Music playback isn't included in the macOS build."
        notifyStateDidChange()
    }

    func startMonitoring(pollInterval: Duration = .milliseconds(200)) {}
    func stopMonitoring() {}
    func togglePlayPause() async {}
    func nextTrack() async {}
    func previousTrack() async {}
    func seek(fraction: Float) {}
    func updateFrame() {}

    func createPlaylist(name: String, songIDs: [String]) async -> String? {
        libraryErrorMessage = "Creating Apple Music playlists isn't included in the macOS build."
        notifyStateDidChange()
        return nil
    }

    private func clearLibrary(reason: String? = nil) {
        librarySongs = []
        libraryPlaylists = []
        libraryAlbums = []
        libraryLoading = false
        libraryErrorMessage = reason
        notifyStateDidChange()
    }

    private func notifyStateDidChange() {
        onStateDidChange?()
    }
}
#endif