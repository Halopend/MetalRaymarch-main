//
//  MusicTabView.swift
//  MetalRaymarch
//
//  Unified music sidebar tab.
//  Shows a single "Now Playing" card (auto-selects Apple Music or Spotify),
//  playback controls, and fractal audio-reactivity settings.
//

import SwiftUI

// MARK: - Music Tab Content

struct MusicTabContent: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var cache: UISettingsCache

    // Apple Music library browsing state
    @State private var showLibrary = false
    @State private var libraryScope: LibraryScope = .songs
    @State private var librarySearch = ""
    @State private var libraryShuffle = false

    private enum LibraryScope: String, CaseIterable {
        case songs = "Songs"
        case playlists = "Playlists"
        case albums = "Albums"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
                // 1. Unified Now Playing
                nowPlayingCard

                // 2. Service connections (compact)
                connectionsSection

                // 3. Apple Music library browser (expandable)
                if appModel.appleMusicManager.isAuthorized {
                    librarySection
                }

                // 4. Audio Reactivity (the main event)
                reactivitySection

                // 5. Level meters
                levelMeters
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Unified Now Playing

    /// Prefer Apple Music if it's playing; otherwise show Spotify.
    private var activeSource: ActiveMusicSource {
        if appModel.appleMusicManager.isPlaying || (!appModel.spotifyManager.isPlaying && !appModel.appleMusicManager.nowPlayingTitle.isEmpty) {
            if appModel.appleMusicManager.isAuthorized && !appModel.appleMusicManager.nowPlayingTitle.isEmpty {
                return .appleMusic
            }
        }
        if appModel.spotifyManager.isConnected, appModel.spotifyManager.currentTrack != nil {
            return .spotify
        }
        if appModel.appleMusicManager.isAuthorized, !appModel.appleMusicManager.nowPlayingTitle.isEmpty {
            return .appleMusic
        }
        return .none
    }

    private enum ActiveMusicSource { case appleMusic, spotify, none }

    private var nowPlayingCard: some View {
        VStack(spacing: 10) {
            switch activeSource {
            case .appleMusic:
                appleMusicNowPlaying
            case .spotify:
                spotifyNowPlaying
            case .none:
                emptyNowPlaying
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var emptyNowPlaying: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing Playing")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Connect to Apple Music or Spotify below")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: Apple Music Now Playing

    private var appleMusicNowPlaying: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Album art placeholder
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "apple.logo")
                            .foregroundStyle(.pink.opacity(0.6))
                    )
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text(appModel.appleMusicManager.nowPlayingTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(appModel.appleMusicManager.nowPlayingArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                Image(systemName: "apple.logo")
                    .font(.caption)
                    .foregroundStyle(.pink)
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

            // Transport
            HStack(spacing: 24) {
                Spacer()
                Button { appModel.appleMusicManager.previousTrack() } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .buttonStyle(.plain)

                Button { appModel.appleMusicManager.togglePlayPause() } label: {
                    Image(systemName: appModel.appleMusicManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                }
                .buttonStyle(.plain)
                .tint(.pink)

                Button { appModel.appleMusicManager.nextTrack() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }

    // MARK: Spotify Now Playing

    private var spotifyNowPlaying: some View {
        VStack(spacing: 10) {
            if let track = appModel.spotifyManager.currentTrack {
                HStack(spacing: 12) {
                    // Album art
                    if let artURL = track.album.thumbnailURL {
                        AsyncImage(url: artURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                            .frame(width: 56, height: 56)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(track.artistNames)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()

                    Image(systemName: "music.note.tv")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

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

                // Transport
                HStack(spacing: 24) {
                    Spacer()
                    Button { Task { await appModel.spotifyManager.previous() } } label: {
                        Image(systemName: "backward.fill").font(.title3)
                    }
                    .buttonStyle(.plain)

                    Button { Task { await appModel.spotifyManager.togglePlayPause() } } label: {
                        Image(systemName: appModel.spotifyManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                    .buttonStyle(.plain)
                    .tint(.green)

                    Button { Task { await appModel.spotifyManager.next() } } label: {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Service Connections

    private var connectionsSection: some View {
        VStack(spacing: 6) {
            // Apple Music row
            HStack {
                Image(systemName: "apple.logo")
                    .font(.caption)
                    .foregroundStyle(appModel.appleMusicManager.isAuthorized ? .green : .secondary)
                Text("Apple Music")
                    .font(.subheadline)
                Spacer()
                if appModel.appleMusicManager.isAuthorized {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Authorize") {
                        appModel.appleMusicManager.requestAuthorization()
                        appModel.appleMusicManager.updateFrame()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()

            // Spotify row
            HStack {
                Image(systemName: "music.note.tv")
                    .font(.caption)
                    .foregroundStyle(appModel.spotifyManager.isConnected ? .green : .secondary)
                Text("Spotify")
                    .font(.subheadline)
                Spacer()
                if appModel.spotifyManager.isConnected {
                    Button("Disconnect") {
                        appModel.spotifyManager.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                } else {
                    Button("Connect") {
                        appModel.spotifyManager.connect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                }
            }

            if let error = appModel.spotifyManager.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Divider()

            // Microphone row
            HStack {
                Image(systemName: appModel.audioAnalyzer.isCapturing ? "mic.fill" : "mic.slash.fill")
                    .font(.caption)
                    .foregroundStyle(appModel.audioAnalyzer.isCapturing ? .green : .secondary)
                Text("Microphone")
                    .font(.subheadline)
                Spacer()
                Button(appModel.audioAnalyzer.isCapturing ? "Stop" : "Start") {
                    if appModel.audioAnalyzer.isCapturing {
                        appModel.audioAnalyzer.stopCapture()
                    } else {
                        appModel.audioAnalyzer.startCapture()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    // MARK: - Apple Music Library Browser

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showLibrary.toggle() }
            } label: {
                HStack {
                    Image(systemName: "music.note.list")
                        .font(.caption)
                    Text("Apple Music Library")
                        .font(.subheadline.bold())
                    Spacer()
                    Image(systemName: showLibrary ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showLibrary {
                libraryBrowser
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var libraryBrowser: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $libraryScope) {
                    ForEach(LibraryScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if libraryScope != .songs {
                    Toggle("", isOn: $libraryShuffle)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Button {
                    appModel.appleMusicManager.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextField("Search…", text: $librarySearch)
                .textFieldStyle(.roundedBorder)

            if appModel.appleMusicManager.libraryLoading {
                ProgressView("Loading…")
                    .font(.caption)
            } else {
                if let err = appModel.appleMusicManager.libraryErrorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                ScrollView {
                    LazyVStack(spacing: 6) {
                        switch libraryScope {
                        case .songs:
                            ForEach(Array(filteredSongs.prefix(100)), id: \.id) { song in
                                songRow(song)
                            }
                        case .playlists:
                            ForEach(Array(filteredPlaylists.prefix(100)), id: \.id) { pl in
                                playlistRow(pl)
                            }
                        case .albums:
                            ForEach(Array(filteredAlbums.prefix(100)), id: \.id) { album in
                                albumRow(album)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .onAppear {
            if appModel.appleMusicManager.librarySongs.isEmpty,
               !appModel.appleMusicManager.libraryLoading {
                appModel.appleMusicManager.refreshLibrary()
            }
        }
    }

    // Filtered helpers
    private var query: String { librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var filteredSongs: [AppleMusicManager.LibrarySong] {
        let s = appModel.appleMusicManager.librarySongs
        guard !query.isEmpty else { return s }
        return s.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }
    private var filteredPlaylists: [AppleMusicManager.LibraryPlaylist] {
        let p = appModel.appleMusicManager.libraryPlaylists
        guard !query.isEmpty else { return p }
        return p.filter { $0.name.lowercased().contains(query) }
    }
    private var filteredAlbums: [AppleMusicManager.LibraryAlbum] {
        let a = appModel.appleMusicManager.libraryAlbums
        guard !query.isEmpty else { return a }
        return a.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }

    // Row views
    private func songRow(_ song: AppleMusicManager.LibrarySong) -> some View {
        Button { appModel.appleMusicManager.playSong(id: song.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "music.note").font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.caption).lineLimit(1)
                    Text(song.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ pl: AppleMusicManager.LibraryPlaylist) -> some View {
        Button { appModel.appleMusicManager.playPlaylist(id: pl.id, shuffle: libraryShuffle) } label: {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list").font(.caption2).foregroundStyle(.secondary)
                Text(pl.name).font(.caption).lineLimit(1)
                Spacer()
                Text("\(pl.trackCount)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func albumRow(_ album: AppleMusicManager.LibraryAlbum) -> some View {
        Button { appModel.appleMusicManager.playAlbum(id: album.id, shuffle: libraryShuffle) } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack").font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).font(.caption).lineLimit(1)
                    Text(album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(album.trackCount)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Audio Reactivity

    private var reactivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio Reactivity")
                .font(.subheadline.bold())

            // Master toggle
            Toggle("React to Music", isOn: Binding(
                get: { cache.fractalAudioReactiveEnabled },
                set: { isOn in
                    cache.fractalAudioReactiveEnabled = isOn
                    cache.push(\.fractalAudioReactiveEnabled, value: isOn)
                    if isOn {
                        // Auto-enable audio-reactive lighting
                        cache.lightingMode = .audioReactive
                        cache.push(\.lightingMode, value: .audioReactive)
                    }
                }
            ))

            if cache.fractalAudioReactiveEnabled {
                // Quick presets
                HStack(spacing: 8) {
                    ForEach(ReactivityPreset.allCases, id: \.self) { preset in
                        Button {
                            applyPreset(preset)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: preset.icon).font(.caption)
                                Text(preset.rawValue).font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Amount slider
                sliderRow(label: "Amount", value: Binding(
                    get: { cache.fractalAudioAmount },
                    set: { v in cache.fractalAudioAmount = v; cache.push(\.fractalAudioAmount, value: v) }
                ), range: 0...1)

                // Beat Punch slider
                sliderRow(label: "Beat Punch", value: Binding(
                    get: { cache.fractalBeatPunch },
                    set: { v in cache.fractalBeatPunch = v; cache.push(\.fractalBeatPunch, value: v) }
                ), range: 0...1)

                // What audio affects (compact toggles)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Affects")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        compactToggle("Scale",  isOn: Binding(
                            get: { cache.fractalAudioAffectsScale },
                            set: { v in cache.fractalAudioAffectsScale = v; cache.push(\.fractalAudioAffectsScale, value: v) }
                        ))
                        compactToggle("Fold",   isOn: Binding(
                            get: { cache.fractalAudioAffectsFolding },
                            set: { v in cache.fractalAudioAffectsFolding = v; cache.push(\.fractalAudioAffectsFolding, value: v) }
                        ))
                        compactToggle("Radius", isOn: Binding(
                            get: { cache.fractalAudioAffectsRadius },
                            set: { v in cache.fractalAudioAffectsRadius = v; cache.push(\.fractalAudioAffectsRadius, value: v) }
                        ))
                        compactToggle("Color",  isOn: Binding(
                            get: { cache.fractalAudioAffectsColorMix },
                            set: { v in cache.fractalAudioAffectsColorMix = v; cache.push(\.fractalAudioAffectsColorMix, value: v) }
                        ))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private func applyPreset(_ preset: ReactivityPreset) {
        let s = preset.settings
        cache.fractalAudioAmount = s.audioAmount
        cache.fractalBeatPunch = s.beatPunch
        cache.bassSensitivity = s.bassSensitivity
        cache.midSensitivity = s.midSensitivity
        cache.trebleSensitivity = s.trebleSensitivity
        cache.beatSensitivity = s.beatSensitivity
        cache.push(\.fractalAudioAmount, value: s.audioAmount)
        cache.push(\.fractalBeatPunch, value: s.beatPunch)
        cache.push(\.bassSensitivity, value: s.bassSensitivity)
        cache.push(\.midSensitivity, value: s.midSensitivity)
        cache.push(\.trebleSensitivity, value: s.trebleSensitivity)
        cache.push(\.beatSensitivity, value: s.beatSensitivity)
    }

    // MARK: - Level Meters

    private var levelMeters: some View {
        TimelineView(.animation) { _ in
            let rs = appModel.renderSettings
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio Levels")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    meterBar(label: "Bass",   level: rs.bassLevel,      color: .red)
                    meterBar(label: "Mid",    level: rs.midLevel,       color: .green)
                    meterBar(label: "Treble", level: rs.trebleLevel,    color: .blue)
                    meterBar(label: "Beat",   level: rs.beatIntensity,  color: .purple)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        }
    }

    // MARK: - Helpers

    private func sliderRow(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 36)
        }
    }

    private func compactToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn.wrappedValue ? Color.blue.opacity(0.3) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isOn.wrappedValue ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func meterBar(label: String, level: Float, color: Color) -> some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(height: geo.size.height * CGFloat(min(1.0, level)))
                }
            }
            .frame(height: 50)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
