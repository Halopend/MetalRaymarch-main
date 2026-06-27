import SwiftUI

@MainActor
@Observable
final class MusicTabViewModel {
    let musicService: MusicService

    var librarySearch = ""
    var musicPresetName = ""
    var musicPresets: [MusicReactivePreset]
    var commandErrorMessage: String?

    init(musicService: MusicService) {
        self.musicService = musicService
        self.musicPresets = musicService.musicPresets
    }

    var connectedProviders: [MusicServiceProvider] { musicService.connectedProviders }
    var activeProvider: MusicServiceProvider? { musicService.activeProvider }
    var hasMultipleConnectedProviders: Bool { connectedProviders.count > 1 }
    var hasConnectedProvider: Bool { activeProvider?.isConnected == true }
    var activeServiceSelectionID: String {
        musicService.preferredServiceID ?? activeProvider?.serviceID ?? ""
    }

    var query: String {
        librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Connection + Transport Commands

    func setActiveService(_ serviceID: String) {
        musicService.setPreferredService(serviceID)
    }

    func connect(_ provider: MusicServiceProvider) {
        provider.connect()
        commandErrorMessage = nil
    }

    func disconnect(_ provider: MusicServiceProvider) {
        provider.disconnect()
        commandErrorMessage = nil
    }

    func previousTrack() {
        runTransportCommand(requiresActiveProvider: true) {
            self.musicService.previous()
        }
    }

    func togglePlayPause() {
        runTransportCommand(requiresActiveProvider: true) {
            self.musicService.togglePlayPause()
        }
    }

    func nextTrack() {
        runTransportCommand(requiresActiveProvider: true) {
            self.musicService.next()
        }
    }

    // MARK: - Library Commands

    func refreshLibrary() {
        guard let activeID = activeProvider?.serviceID else {
            commandErrorMessage = "Connect a service to load your library."
            return
        }
        runLibraryCommand {
            self.musicService.refreshLibrary(for: activeID)
        }
    }

    func playSong(_ track: UnifiedTrack) {
        runLibraryCommand { self.musicService.playSong(track) }
    }

    func playPlaylist(_ playlist: UnifiedPlaylist) {
        runLibraryCommand { self.musicService.playPlaylist(playlist, shuffle: false) }
    }

    func playAlbum(_ album: UnifiedAlbum) {
        runLibraryCommand { self.musicService.playAlbum(album, shuffle: false) }
    }

    // MARK: - Library Filtering

    func filteredSongs(for serviceID: String?) -> [UnifiedTrack] {
        let tracks = musicService.librarySongs(for: serviceID)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }

    func filteredPlaylists(for serviceID: String?) -> [UnifiedPlaylist] {
        let playlists = musicService.libraryPlaylists(for: serviceID)
        guard !query.isEmpty else { return playlists }
        return playlists.filter { $0.name.lowercased().contains(query) }
    }

    func filteredAlbums(for serviceID: String?) -> [UnifiedAlbum] {
        let albums = musicService.libraryAlbums(for: serviceID)
        guard !query.isEmpty else { return albums }
        return albums.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }

    // MARK: - Preset Persistence

    func saveMusicPreset(using cache: UISettingsCache) {
        let trimmed = musicPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = MusicReactivePreset(
            name: trimmed,
            audioAmount: cache.audioReactive.fractalAudioAmount,
            beatPunch: cache.audioReactive.fractalBeatPunch,
            audioDamping: cache.audioReactive.fractalAudioDamping,
            bassSensitivity: cache.audioReactive.bassSensitivity,
            midSensitivity: cache.audioReactive.midSensitivity,
            trebleSensitivity: cache.audioReactive.trebleSensitivity,
            beatSensitivity: cache.audioReactive.beatSensitivity,
            mappings: cache.audioReactive.musicReactiveMappings
        )
        musicPresets.append(preset)
        persistMusicPresets()
        musicPresetName = ""
    }

    func loadMusicPreset(_ preset: MusicReactivePreset, into cache: UISettingsCache) {
        cache.audioReactive.fractalAudioAmount = preset.audioAmount
        cache.audioReactive.fractalBeatPunch = preset.beatPunch
        cache.audioReactive.fractalAudioDamping = preset.audioDamping
        cache.audioReactive.bassSensitivity = preset.bassSensitivity
        cache.audioReactive.midSensitivity = preset.midSensitivity
        cache.audioReactive.trebleSensitivity = preset.trebleSensitivity
        cache.audioReactive.beatSensitivity = preset.beatSensitivity
        cache.audioReactive.musicReactiveMappings = preset.mappings

        cache.push(\.fractalAudioAmount, value: preset.audioAmount)
        cache.push(\.fractalBeatPunch, value: preset.beatPunch)
        cache.push(\.fractalAudioDamping, value: preset.audioDamping)
        cache.push(\.bassSensitivity, value: preset.bassSensitivity)
        cache.push(\.midSensitivity, value: preset.midSensitivity)
        cache.push(\.trebleSensitivity, value: preset.trebleSensitivity)
        cache.push(\.beatSensitivity, value: preset.beatSensitivity)
        cache.push(\.musicReactiveMappings, value: preset.mappings)
    }

    func deleteMusicPreset(_ id: UUID) {
        musicPresets.removeAll { $0.id == id }
        persistMusicPresets()
    }

    // MARK: - Command Standardization

    private func runTransportCommand(requiresActiveProvider: Bool, _ action: () -> Void) {
        guard !requiresActiveProvider || activeProvider != nil else {
            commandErrorMessage = "No active music provider."
            return
        }
        commandErrorMessage = nil
        action()
    }

    private func runLibraryCommand(_ action: () -> Void) {
        guard activeProvider != nil else {
            commandErrorMessage = "Connect a music provider to use library actions."
            return
        }
        commandErrorMessage = nil
        action()
    }

    private func persistMusicPresets() {
        musicService.saveMusicPresets(musicPresets)
    }
}
