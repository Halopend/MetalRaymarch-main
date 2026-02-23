//
//  MusicTabView.swift
//  MetalRaymarch
//
//  Full music sidebar tab with three sub-tabs:
//  - Now Playing: Spotify connection, track info, transport controls
//  - Visualizer: Mode selection, intensity, sensitivity sliders
//  - Settings: Account info, mic permissions, polling config
//

import SwiftUI

// MARK: - Music Sub-Tab Enum

enum MusicSubTab: String, CaseIterable {
    case nowPlaying = "Now Playing"
    case visualizer = "Visualizer"
    case settings = "Settings"
}

private enum AppleLibraryScope: String, CaseIterable {
    case songs = "Songs"
    case playlists = "Playlists"
    case albums = "Albums"
}

// MARK: - Music Tab Content

struct MusicTabContent: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var cache: UISettingsCache
    @State private var musicSubTab: MusicSubTab = .nowPlaying
    @State private var appleLibraryScope: AppleLibraryScope = .songs
    @State private var appleLibrarySearchText: String = ""
    @State private var appleLibraryShuffle: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $musicSubTab) {
                ForEach(MusicSubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch musicSubTab {
                    case .nowPlaying: nowPlayingContent
                    case .visualizer: visualizerContent
                    case .settings:   musicSettingsContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private var appleMusicStatusText: String {
        if !appModel.appleMusicManager.isAuthorized {
            return appModel.appleMusicManager.authorizationDescription
        }
        if appModel.appleMusicManager.isPlaying {
            return "Playing"
        }
        if !appModel.appleMusicManager.nowPlayingTitle.isEmpty {
            return "Paused"
        }
        return "No track detected"
    }

    private var normalizedAppleLibraryQuery: String {
        appleLibrarySearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var filteredAppleSongs: [AppleMusicManager.LibrarySong] {
        let songs = appModel.appleMusicManager.librarySongs
        guard !normalizedAppleLibraryQuery.isEmpty else { return songs }
        return songs.filter {
            $0.title.lowercased().contains(normalizedAppleLibraryQuery) ||
            $0.artist.lowercased().contains(normalizedAppleLibraryQuery) ||
            $0.album.lowercased().contains(normalizedAppleLibraryQuery)
        }
    }

    private var filteredApplePlaylists: [AppleMusicManager.LibraryPlaylist] {
        let playlists = appModel.appleMusicManager.libraryPlaylists
        guard !normalizedAppleLibraryQuery.isEmpty else { return playlists }
        return playlists.filter {
            $0.name.lowercased().contains(normalizedAppleLibraryQuery)
        }
    }

    private var filteredAppleAlbums: [AppleMusicManager.LibraryAlbum] {
        let albums = appModel.appleMusicManager.libraryAlbums
        guard !normalizedAppleLibraryQuery.isEmpty else { return albums }
        return albums.filter {
            $0.title.lowercased().contains(normalizedAppleLibraryQuery) ||
            $0.artist.lowercased().contains(normalizedAppleLibraryQuery)
        }
    }

    private var appleMusicConnectionSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "apple.logo")
                    .font(.title3)
                    .foregroundStyle(appModel.appleMusicManager.isAuthorized ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Music")
                        .font(.headline)
                    Text(appleMusicStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appModel.appleMusicManager.requestAuthorization()
                    appModel.appleMusicManager.updateFrame()
                } label: {
                    Text(appModel.appleMusicManager.isAuthorized ? "Refresh" : "Authorize")
                }
                .buttonStyle(.bordered)
                .tint(appModel.appleMusicManager.isAuthorized ? .green : .blue)
            }

            if !appModel.appleMusicManager.isAuthorized {
                Text("Allow Music Library access so Apple Music playback can drive the visualizer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var appleMusicLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apple Music Library")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Spacer()

                if appleLibraryScope != .songs {
                    Toggle("Shuffle", isOn: $appleLibraryShuffle)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Button {
                    appModel.appleMusicManager.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            Picker("Library Scope", selection: $appleLibraryScope) {
                ForEach(AppleLibraryScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            TextField("Search songs, playlists, albums", text: $appleLibrarySearchText)
                .textFieldStyle(.roundedBorder)

            if appModel.appleMusicManager.libraryLoading {
                ProgressView("Loading Apple Music library…")
                    .font(.caption)
            } else {
                if let err = appModel.appleMusicManager.libraryErrorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        switch appleLibraryScope {
                        case .songs:
                            if filteredAppleSongs.isEmpty {
                                appleLibraryEmptyState("No songs found")
                            } else {
                                ForEach(Array(filteredAppleSongs.prefix(120)), id: \.id) { song in
                                    appleSongRow(song)
                                }
                            }
                        case .playlists:
                            if filteredApplePlaylists.isEmpty {
                                appleLibraryEmptyState("No playlists found")
                            } else {
                                ForEach(Array(filteredApplePlaylists.prefix(120)), id: \.id) { playlist in
                                    applePlaylistRow(playlist)
                                }
                            }
                        case .albums:
                            if filteredAppleAlbums.isEmpty {
                                appleLibraryEmptyState("No albums found")
                            } else {
                                ForEach(Array(filteredAppleAlbums.prefix(120)), id: \.id) { album in
                                    appleAlbumRow(album)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .onAppear {
            if appModel.appleMusicManager.isAuthorized,
               appModel.appleMusicManager.librarySongs.isEmpty,
               appModel.appleMusicManager.libraryPlaylists.isEmpty,
               appModel.appleMusicManager.libraryAlbums.isEmpty,
               !appModel.appleMusicManager.libraryLoading {
                appModel.appleMusicManager.refreshLibrary()
            }
        }
    }

    private func appleSongRow(_ song: AppleMusicManager.LibrarySong) -> some View {
        Button {
            appModel.appleMusicManager.playSong(id: song.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("\(song.artist) • \(song.album)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func applePlaylistRow(_ playlist: AppleMusicManager.LibraryPlaylist) -> some View {
        Button {
            appModel.appleMusicManager.playPlaylist(id: playlist.id, shuffle: appleLibraryShuffle)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("\(playlist.trackCount) tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: appleLibraryShuffle ? "shuffle" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appleAlbumRow(_ album: AppleMusicManager.LibraryAlbum) -> some View {
        Button {
            appModel.appleMusicManager.playAlbum(id: album.id, shuffle: appleLibraryShuffle)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.stack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("\(album.artist) • \(album.trackCount) tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: appleLibraryShuffle ? "shuffle" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appleLibraryEmptyState(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private var appleMusicNowPlayingSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "apple.logo").foregroundStyle(.secondary))
                    .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appModel.appleMusicManager.nowPlayingTitle.isEmpty ? "No Apple Music track" : appModel.appleMusicManager.nowPlayingTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(appModel.appleMusicManager.nowPlayingArtist.isEmpty ? "Play a song in Apple Music" : appModel.appleMusicManager.nowPlayingArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                VStack(spacing: 4) {
                    ProgressView(value: Double(appModel.appleMusicManager.progressFraction))
                        .tint(.pink)

                    HStack {
                        Text(appModel.appleMusicManager.currentTimeString)
                            .font(.caption2).monospacedDigit()
                        Spacer()
                        Text(appModel.appleMusicManager.totalTimeString)
                            .font(.caption2).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }

            appleMusicTransportControls
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var appleMusicTransportControls: some View {
        HStack(spacing: 20) {
            Spacer()

            Button {
                appModel.appleMusicManager.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Button {
                appModel.appleMusicManager.togglePlayPause()
            } label: {
                Image(systemName: appModel.appleMusicManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)
            .tint(.pink)

            Button {
                appModel.appleMusicManager.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Now Playing
    
    private var nowPlayingContent: some View {
        VStack(spacing: 16) {
            // Connection status
            spotifyConnectionSection
            appleMusicConnectionSection

            if appModel.appleMusicManager.isAuthorized {
                appleMusicNowPlayingSection
                appleMusicLibrarySection
            }
            
            if appModel.spotifyManager.isConnected {
                // Track info
                if let track = appModel.spotifyManager.currentTrack {
                    trackInfoSection(track: track)
                } else {
                    noTrackPlaceholder
                }
                
                // Transport controls
                transportControls
                
                // Audio features badges
                if let features = appModel.spotifyManager.audioFeatures {
                    audioFeaturesBadges(features: features)
                }
            }
        }
    }
    
    private var spotifyConnectionSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "music.note.tv")
                    .font(.title3)
                    .foregroundStyle(appModel.spotifyManager.isConnected ? .green : .secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify")
                        .font(.headline)
                    Text(appModel.spotifyManager.isConnected ? "Connected" : "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    if appModel.spotifyManager.isConnected {
                        appModel.spotifyManager.disconnect()
                    } else {
                        appModel.spotifyManager.connect()
                    }
                } label: {
                    Text(appModel.spotifyManager.isConnected ? "Disconnect" : "Connect")
                }
                .buttonStyle(.bordered)
                .tint(appModel.spotifyManager.isConnected ? .red : .green)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            
            if let error = appModel.spotifyManager.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
        }
    }
    
    private func trackInfoSection(track: SpotifyTrack) -> some View {
        VStack(spacing: 10) {
            // Album art + track info
            HStack(spacing: 12) {
                // Album art placeholder (async image loading)
                if let artURL = track.album.thumbnailURL {
                    AsyncImage(url: artURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                        .frame(width: 60, height: 60)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(track.album.name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            
            // Progress bar (TimelineView for smooth interpolation between polls)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                VStack(spacing: 4) {
                    ProgressView(value: Double(appModel.spotifyManager.progressFraction))
                        .tint(.green)
                    
                    HStack {
                        Text(appModel.spotifyManager.currentTimeString)
                            .font(.caption2).monospacedDigit()
                        Spacer()
                        Text(appModel.spotifyManager.totalTimeString)
                            .font(.caption2).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    private var noTrackPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No track playing")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Play something on Spotify to get started")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    private var transportControls: some View {
        HStack(spacing: 20) {
            Spacer()
            
            Button {
                Task { await appModel.spotifyManager.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            
            Button {
                Task { await appModel.spotifyManager.togglePlayPause() }
            } label: {
                Image(systemName: appModel.spotifyManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)
            .tint(.green)
            
            Button {
                Task { await appModel.spotifyManager.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    private func audioFeaturesBadges(features: SpotifyAudioFeatures) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Features")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
            ], spacing: 8) {
                featureBadge(label: "Energy", value: features.energy, color: .orange)
                featureBadge(label: "Tempo", value: features.normalizedTempo, color: .blue, detail: "\(Int(features.tempo)) BPM")
                featureBadge(label: "Dance", value: features.danceability, color: .pink)
                featureBadge(label: "Valence", value: features.valence, color: .yellow)
                featureBadge(label: "Acoustic", value: features.acousticness, color: .green)
                featureBadge(label: "Loud", value: features.normalizedLoudness, color: .red)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    private func featureBadge(label: String, value: Float, color: Color, detail: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            ZStack {
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(value))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                Text(detail ?? "\(Int(value * 100))%")
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
            }
            .frame(width: 44, height: 44)
        }
    }
    
    // MARK: - Visualizer
    
    private var visualizerContent: some View {
        VStack(spacing: 16) {
            // Visualizer mode picker
            visualizerModePicker
            
            // Audio source picker
            audioSourcePicker
            
            // Intensity
            intensitySection
            
            // Per-band sensitivity
            sensitivitySection

            // Fractal geometry modulation
            fractalAudioMotionSection
            
            // Real-time level meters
            levelMeters
            
            // Quick presets
            presetButtons
        }
    }
    
    private var visualizerModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visualizer Mode")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                ForEach(VisualizerMode.allCases, id: \.self) { mode in
                    Button {
                        cache.visualizerMode = mode
                        cache.push(\.visualizerMode, value: mode.rawValue)
                        if mode != .off {
                            // Auto-switch to visualizer lighting mode
                            cache.lightingMode = .visualizer
                            cache.push(\.lightingMode, value: .visualizer)
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.icon)
                                .font(.title3)
                            Text(mode.displayName)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(cache.visualizerMode == mode ? Color.blue.opacity(0.3) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    private var audioSourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Source")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                ForEach(AudioSource.allCases, id: \.self) { source in
                    Button {
                        cache.audioSource = source
                        cache.push(\.audioSource, value: source.int32Value)
                        // Start/stop audio sources accordingly
                        switch source {
                        case .micOnly:
                            appModel.audioAnalyzer.startCapture()
                            appModel.appleMusicManager.stopMonitoring()
                        case .spotifyOnly:
                            appModel.audioAnalyzer.stopCapture()
                            appModel.appleMusicManager.stopMonitoring()
                            if appModel.spotifyManager.isConnected {
                                appModel.spotifyManager.startPolling()
                            }
                        case .appleMusicOnly:
                            appModel.audioAnalyzer.stopCapture()
                            appModel.appleMusicManager.requestAuthorization()
                        case .both:
                            appModel.audioAnalyzer.startCapture()
                            appModel.appleMusicManager.stopMonitoring()
                            if appModel.spotifyManager.isConnected {
                                appModel.spotifyManager.startPolling()
                            }
                        case .allSources:
                            appModel.audioAnalyzer.startCapture()
                            appModel.appleMusicManager.requestAuthorization()
                            if appModel.spotifyManager.isConnected {
                                appModel.spotifyManager.startPolling()
                            }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: source.icon)
                                .font(.title3)
                            Text(source.rawValue)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(cache.audioSource == source ? Color.green.opacity(0.3) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    private var intensitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visualizer Intensity")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            
            HStack {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Slider(value: Binding(
                    get: { cache.visualizerIntensity },
                    set: { newValue in
                        cache.visualizerIntensity = newValue
                        cache.push(\.visualizerIntensity, value: newValue)
                    }
                ), in: 0...1)
                
                Text("\(Int(cache.visualizerIntensity * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    private var sensitivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Band Sensitivity")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            
            sensitivitySlider(label: "Bass", cacheKeyPath: \.bassSensitivity, renderKeyPath: \.bassSensitivity, color: .red)
            sensitivitySlider(label: "Mids", cacheKeyPath: \.midSensitivity, renderKeyPath: \.midSensitivity, color: .green)
            sensitivitySlider(label: "Treble", cacheKeyPath: \.trebleSensitivity, renderKeyPath: \.trebleSensitivity, color: .blue)
            sensitivitySlider(label: "Beat", cacheKeyPath: \.beatSensitivity, renderKeyPath: \.beatSensitivity, color: .purple)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    private func sensitivitySlider(
        label: String,
        cacheKeyPath: ReferenceWritableKeyPath<UISettingsCache, Float>,
        renderKeyPath: ReferenceWritableKeyPath<RenderSettings, Float>,
        color: Color
    ) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 45, alignment: .leading)
            
            Slider(value: Binding(
                get: { cache[keyPath: cacheKeyPath] },
                set: { newValue in
                    cache[keyPath: cacheKeyPath] = newValue
                    cache.push(renderKeyPath, value: newValue)
                }
            ), in: 0...2)
                .tint(color)
            
            Text(String(format: "%.1f×", cache[keyPath: cacheKeyPath]))
                .font(.caption.monospacedDigit())
                .frame(width: 40)
        }
    }
    
    private var levelMeters: some View {
        // TimelineView forces redraws since audio levels are @ObservationIgnored
        TimelineView(.animation) { timeline in
            let renderSettings = appModel.renderSettings
            VStack(alignment: .leading, spacing: 8) {
                Text("Real-Time Levels")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    levelMeter(label: "Bass", level: renderSettings.bassLevel, color: .red)
                    levelMeter(label: "Mid", level: renderSettings.midLevel, color: .green)
                    levelMeter(label: "Treble", level: renderSettings.trebleLevel, color: .blue)
                    levelMeter(label: "Beat", level: renderSettings.beatIntensity, color: .purple)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        }
    }

    private var fractalAudioMotionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fractal Audio Motion")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Toggle("Enable Fractal Motion", isOn: Binding(
                get: { cache.fractalAudioReactiveEnabled },
                set: { isOn in
                    cache.fractalAudioReactiveEnabled = isOn
                    cache.push(\.fractalAudioReactiveEnabled, value: isOn)
                }
            ))

            audioAmountSlider(
                label: "Geometry Amount",
                value: Binding(
                    get: { cache.fractalAudioAmount },
                    set: { newValue in
                        cache.fractalAudioAmount = newValue
                        cache.push(\.fractalAudioAmount, value: newValue)
                    }
                )
            )

            audioAmountSlider(
                label: "Beat Punch",
                value: Binding(
                    get: { cache.fractalBeatPunch },
                    set: { newValue in
                        cache.fractalBeatPunch = newValue
                        cache.push(\.fractalBeatPunch, value: newValue)
                    }
                )
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Affects")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Scale", isOn: Binding(
                    get: { cache.fractalAudioAffectsScale },
                    set: { isOn in
                        cache.fractalAudioAffectsScale = isOn
                        cache.push(\.fractalAudioAffectsScale, value: isOn)
                    }
                ))
                Toggle("Folding", isOn: Binding(
                    get: { cache.fractalAudioAffectsFolding },
                    set: { isOn in
                        cache.fractalAudioAffectsFolding = isOn
                        cache.push(\.fractalAudioAffectsFolding, value: isOn)
                    }
                ))
                Toggle("Radius", isOn: Binding(
                    get: { cache.fractalAudioAffectsRadius },
                    set: { isOn in
                        cache.fractalAudioAffectsRadius = isOn
                        cache.push(\.fractalAudioAffectsRadius, value: isOn)
                    }
                ))
                Toggle("Color Mix", isOn: Binding(
                    get: { cache.fractalAudioAffectsColorMix },
                    set: { isOn in
                        cache.fractalAudioAffectsColorMix = isOn
                        cache.push(\.fractalAudioAffectsColorMix, value: isOn)
                    }
                ))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private func audioAmountSlider(label: String, value: Binding<Float>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40)
        }
    }
    
    private func levelMeter(label: String, level: Float, color: Color) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(height: geo.size.height * CGFloat(min(1.0, level)))
                }
            }
            .frame(height: 60)
            
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var presetButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Presets")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                ForEach(VisualizerPreset.allCases, id: \.self) { preset in
                    Button {
                        let s = preset.settings
                        cache.visualizerIntensity = s.intensity
                        cache.bassSensitivity = s.bassSensitivity
                        cache.midSensitivity = s.midSensitivity
                        cache.trebleSensitivity = s.trebleSensitivity
                        cache.beatSensitivity = s.beatSensitivity
                        cache.push(\.visualizerIntensity, value: s.intensity)
                        cache.push(\.bassSensitivity, value: s.bassSensitivity)
                        cache.push(\.midSensitivity, value: s.midSensitivity)
                        cache.push(\.trebleSensitivity, value: s.trebleSensitivity)
                        cache.push(\.beatSensitivity, value: s.beatSensitivity)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.icon)
                                .font(.title3)
                            Text(preset.rawValue)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
    
    // MARK: - Music Settings
    
    private var musicSettingsContent: some View {
        VStack(spacing: 16) {
            // Spotify account
            VStack(alignment: .leading, spacing: 8) {
                Text("Spotify Account")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(appModel.spotifyManager.isConnected ? .green : .secondary)
                    Text(appModel.spotifyManager.isConnected ? "Connected" : "Not logged in")
                    Spacer()
                    if appModel.spotifyManager.isConnected {
                        Button("Log Out") {
                            appModel.spotifyManager.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))

            // Apple Music authorization
            VStack(alignment: .leading, spacing: 8) {
                Text("Apple Music Access")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "apple.logo")
                        .foregroundStyle(appModel.appleMusicManager.isAuthorized ? .green : .secondary)
                    Text(appModel.appleMusicManager.authorizationDescription)
                    Spacer()
                    Button(appModel.appleMusicManager.isAuthorized ? "Refresh" : "Authorize") {
                        appModel.appleMusicManager.requestAuthorization()
                        appModel.appleMusicManager.updateFrame()
                    }
                    .buttonStyle(.bordered)
                }

                if !appModel.appleMusicManager.isAuthorized {
                    Text("Authorization is required for Apple Music reactive visualizer input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            
            // Microphone permissions
            VStack(alignment: .leading, spacing: 8) {
                Text("Microphone")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                HStack {
                    Image(systemName: appModel.audioAnalyzer.isCapturing ? "mic.fill" : "mic.slash.fill")
                        .foregroundStyle(appModel.audioAnalyzer.isCapturing ? .green : .secondary)
                    Text(appModel.audioAnalyzer.isCapturing ? "Active" : "Inactive")
                    Spacer()
                    Button(appModel.audioAnalyzer.isCapturing ? "Stop" : "Start") {
                        if appModel.audioAnalyzer.isCapturing {
                            appModel.audioAnalyzer.stopCapture()
                        } else {
                            appModel.audioAnalyzer.startCapture()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                if let err = appModel.audioAnalyzer.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            
            // Lighting mode
            VStack(alignment: .leading, spacing: 8) {
                Text("Lighting Mode")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                Picker("Mode", selection: Binding(
                    get: { cache.lightingMode },
                    set: { newValue in
                        cache.lightingMode = newValue
                        cache.push(\.lightingMode, value: newValue)
                    }
                )) {
                    ForEach(LightingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        }
    }
}
