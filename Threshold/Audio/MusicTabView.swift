//
//  MusicTabView.swift
//  Threshold
//
//  Unified music sidebar tab.
//  Shows a single "Now Playing" card, service toggle, unified library
//  browser (works for any registered MusicServiceProvider), playback
//  controls, and fractal audio-reactivity settings.
//

import SwiftUI

// MARK: - Music Tab Content

struct MusicTabContent: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Bindable var cache: UISettingsCache

    // Library browsing state
    @State private var showLibrary = false
    @State private var libraryScope: LibraryScope = .songs
    @State private var librarySearch = ""
    @State private var libraryShuffle = false
    @State private var musicPresetName = ""
    @State private var musicPresets: [MusicReactivePreset] = Self.loadMusicPresets()

    private enum LibraryScope: String, CaseIterable {
        case songs = "Songs"
        case playlists = "Playlists"
        case albums = "Albums"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
                // 1. Service toggle / picker
                serviceToggle

                // 2. Unified Now Playing
                nowPlayingCard

                // 3. Open Library button (pops into its own window)
                if appModel.musicService.activeProvider?.isConnected == true {
                    openLibraryButton
                }

                // 4. Audio Reactivity (the main event)
                reactivitySection

                // 5. Saved music presets
                musicPresetsSection

                // 6. Level meters
                levelMeters

                // 7. Service connections (settings)
                connectionsSection

                // 8. Fallback priority ordering
                if appModel.musicService.connectedProviders.count > 1 {
                    servicePrioritySection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Service Toggle

    private var serviceToggle: some View {
        let music = appModel.musicService!
        let connected = music.connectedProviders
        return Group {
            if connected.count > 1 {
                VStack(spacing: 6) {
                    HStack {
                        Text("Active Service")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    Picker("Service", selection: Binding(
                        get: { music.preferredServiceID ?? music.activeProvider?.serviceID ?? "" },
                        set: { newID in music.setPreferredService(newID) }
                    )) {
                        ForEach(connected, id: \.serviceID) { provider in
                            Label(provider.displayName, systemImage: provider.iconName)
                                .tag(provider.serviceID)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            } else if connected.count == 1, let single = connected.first {
                HStack {
                    Image(systemName: single.iconName)
                        .foregroundStyle(single.accentColor)
                    Text(single.displayName)
                        .font(.subheadline.bold())
                    Spacer()
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            }
        }
    }

    // MARK: - Open Library Button

    private var openLibraryButton: some View {
        Button {
            openWindow(id: AppModel.libraryWindowID)
        } label: {
            HStack {
                Image(systemName: "music.note.list")
                    .font(.subheadline)
                Text("Open Library")
                    .font(.subheadline.bold())
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Unified Now Playing

    private var nowPlayingCard: some View {
        let music = appModel.musicService!
        return VStack(spacing: 10) {
            if let track = music.nowPlaying {
                // Track info
                HStack(spacing: 12) {
                    // Album art
                    if let artURL = track.artworkURL {
                        AsyncImage(url: artURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            artPlaceholder(for: track.source)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        artPlaceholder(for: track.source)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()

                    Image(systemName: music.sourceIcon)
                        .font(.caption)
                        .foregroundStyle(music.accentColor)
                }

                // Progress bar
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(spacing: 4) {
                        ProgressView(value: Double(music.progressFraction))
                            .tint(music.accentColor)
                        HStack {
                            Text(music.currentTimeString)
                                .font(.caption2).monospacedDigit()
                            Spacer()
                            Text(music.totalTimeString)
                                .font(.caption2).monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                // Transport
                HStack(spacing: 24) {
                    Spacer()
                    Button { music.previous() } label: {
                        Image(systemName: "backward.fill").font(.title3)
                    }
                    .buttonStyle(.plain)

                    Button { music.togglePlayPause() } label: {
                        Image(systemName: music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                    .buttonStyle(.plain)
                    .tint(music.accentColor)

                    Button { music.next() } label: {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            } else {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Nothing Playing")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Connect a music service below")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private func artPlaceholder(for source: SongSource) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay(
                Image(systemName: source == .appleMusic ? "apple.logo" : "music.note")
                    .foregroundStyle(source == .appleMusic ? .pink.opacity(0.6) : .secondary)
            )
            .frame(width: 56, height: 56)
    }

    // MARK: - Service Connections

    private var connectionsSection: some View {
        let music = appModel.musicService!
        return VStack(spacing: 6) {
            HStack {
                Text("Services")
                    .font(.subheadline.bold())
                Spacer()
            }

            // Dynamic rows for every registered provider
            ForEach(music.providers, id: \.serviceID) { provider in
                serviceRow(provider)
                if provider.serviceID != music.providers.last?.serviceID {
                    Divider()
                }
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

    /// A single service connection row — works for any provider.
    private func serviceRow(_ provider: MusicServiceProvider) -> some View {
        HStack {
            Image(systemName: provider.iconName)
                .font(.caption)
                .foregroundStyle(provider.isConnected ? provider.accentColor : .secondary)
            Text(provider.displayName)
                .font(.subheadline)
            Spacer()
            switch provider.connectionStatus {
            case .connected:
                if provider.serviceID == "appleMusic" {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Disconnect") {
                        provider.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            case .error(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            case .connecting:
                ProgressView()
                    .controlSize(.small)
            case .disconnected:
                Button("Connect") {
                    provider.connect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(provider.accentColor)
            }
        }
    }

    // MARK: - Service Priority

    private var servicePrioritySection: some View {
        let music = appModel.musicService!
        let order = music.servicePriority

        return VStack(spacing: 6) {
            HStack {
                Text("Fallback Priority")
                    .font(.subheadline.bold())
                Spacer()
                Text("Drag to reorder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("When a song is attached, playback tries services in this order.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(order.enumerated()), id: \.element) { idx, serviceID in
                if let provider = music.provider(for: serviceID) {
                    HStack(spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Image(systemName: provider.iconName)
                            .font(.caption)
                            .foregroundStyle(provider.isConnected ? provider.accentColor : .secondary)
                        Text(provider.displayName)
                            .font(.subheadline)
                        Spacer()
                        Button {
                            music.moveServiceUp(serviceID)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                        }
                        .disabled(idx == 0)
                        .buttonStyle(.plain)
                        .foregroundStyle(idx == 0 ? .quaternary : .secondary)
                        Button {
                            music.moveServiceDown(serviceID)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .disabled(idx == order.count - 1)
                        .buttonStyle(.plain)
                        .foregroundStyle(idx == order.count - 1 ? .quaternary : .secondary)
                    }
                    .padding(.vertical, 4)
                    if idx < order.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    // MARK: - Unified Library Browser

    private var librarySection: some View {
        let music = appModel.musicService!
        let activeServiceName = music.activeProvider?.displayName ?? "Library"
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showLibrary.toggle() }
            } label: {
                HStack {
                    Image(systemName: "music.note.list")
                        .font(.caption)
                    Text("\(activeServiceName) Library")
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
        let music = appModel.musicService!
        let activeID = music.activeProvider?.serviceID
        return VStack(spacing: 8) {
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
                    music.refreshLibrary(for: activeID)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextField("Search…", text: $librarySearch)
                .textFieldStyle(.roundedBorder)

            if music.isLibraryLoading(for: activeID) {
                ProgressView("Loading…")
                    .font(.caption)
            } else {
                if let err = music.libraryError(for: activeID) {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                ScrollView {
                    LazyVStack(spacing: 6) {
                        switch libraryScope {
                        case .songs:
                            ForEach(Array(filteredSongs(for: activeID).prefix(100)), id: \.id) { track in
                                unifiedSongRow(track, music: music)
                            }
                        case .playlists:
                            ForEach(Array(filteredPlaylists(for: activeID).prefix(100)), id: \.id) { pl in
                                unifiedPlaylistRow(pl, music: music)
                            }
                        case .albums:
                            ForEach(Array(filteredAlbums(for: activeID).prefix(100)), id: \.id) { album in
                                unifiedAlbumRow(album, music: music)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .onAppear {
            if music.librarySongs(for: activeID).isEmpty,
               !music.isLibraryLoading(for: activeID) {
                music.refreshLibrary(for: activeID)
            }
        }
    }

    // MARK: - Unified Library Filters

    private var query: String {
        librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func filteredSongs(for serviceID: String?) -> [UnifiedTrack] {
        let s = appModel.musicService.librarySongs(for: serviceID)
        guard !query.isEmpty else { return s }
        return s.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }

    private func filteredPlaylists(for serviceID: String?) -> [UnifiedPlaylist] {
        let p = appModel.musicService.libraryPlaylists(for: serviceID)
        guard !query.isEmpty else { return p }
        return p.filter { $0.name.lowercased().contains(query) }
    }

    private func filteredAlbums(for serviceID: String?) -> [UnifiedAlbum] {
        let a = appModel.musicService.libraryAlbums(for: serviceID)
        guard !query.isEmpty else { return a }
        return a.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }

    // MARK: - Unified Library Rows

    private func unifiedSongRow(_ track: UnifiedTrack, music: MusicService) -> some View {
        Button { music.playSong(track) } label: {
            HStack(spacing: 8) {
                if let url = track.artworkURL {
                    AsyncImage(url: url) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "music.note").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "music.note").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.caption).lineLimit(1)
                    Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if track.durationSeconds > 0 {
                    Text(track.durationString).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unifiedPlaylistRow(_ pl: UnifiedPlaylist, music: MusicService) -> some View {
        Button { music.playPlaylist(pl, shuffle: libraryShuffle) } label: {
            HStack(spacing: 8) {
                if let url = pl.artworkURL {
                    AsyncImage(url: url) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "music.note.list").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "music.note.list").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(pl.name).font(.caption).lineLimit(1)
                    if let owner = pl.ownerName {
                        Text(owner).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text("\(pl.trackCount)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unifiedAlbumRow(_ album: UnifiedAlbum, music: MusicService) -> some View {
        Button { music.playAlbum(album, shuffle: libraryShuffle) } label: {
            HStack(spacing: 8) {
                if let url = album.artworkURL {
                    AsyncImage(url: url) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "square.stack").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "square.stack").font(.caption2).foregroundStyle(.secondary)
                }
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
                // Genre presets (Fractal Forge–inspired)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Genre Presets")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 6) {
                        ForEach(ReactivityPreset.allCases, id: \.self) { preset in
                            Button {
                                applyPreset(preset)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: preset.icon).font(.caption2)
                                    Text(preset.rawValue).font(.system(size: 9))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
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

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mapped Parameters")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            let available = availableMappingTargetsToAdd
                            let universalTargets = available.filter { !$0.isFormulaParam }
                            let formulaTargets = available.filter { $0.isFormulaParam }

                            if !universalTargets.isEmpty {
                                Section("Universal") {
                                    ForEach(universalTargets, id: \.self) { target in
                                        Button {
                                            addMapping(target)
                                        } label: {
                                            Label(target.displayName, systemImage: target.icon)
                                        }
                                    }
                                }
                            }

                            if !formulaTargets.isEmpty {
                                Section("\(cache.fractalType.displayName) Params") {
                                    ForEach(formulaTargets, id: \.self) { target in
                                        Button {
                                            addMapping(target)
                                        } label: {
                                            Label(target.displayName(for: cache.fractalType), systemImage: target.icon(for: cache.fractalType))
                                        }
                                    }
                                }
                            }

                            if available.isEmpty {
                                Text("All targets added")
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    ForEach(Array(cache.musicReactiveMappings.enumerated()), id: \.element.id) { index, mapping in
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { mappingAt(index)?.isEnabled ?? false },
                                    set: { newValue in updateMapping(index) { $0.isEnabled = newValue } }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                Image(systemName: mapping.target.icon(for: cache.fractalType))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(mapping.target.displayName(for: cache.fractalType))
                                    .font(.caption.bold())

                                Spacer()

                                Button {
                                    removeMapping(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }

                            Picker("Source", selection: Binding(
                                get: { mappingAt(index)?.source ?? .composite },
                                set: { newValue in updateMapping(index) { $0.source = newValue } }
                            )) {
                                ForEach(MusicReactiveSource.allCases, id: \.self) { source in
                                    Text(source.displayName).tag(source)
                                }
                            }
                            .pickerStyle(.segmented)

                            sliderRow(label: "Min", value: Binding(
                                get: { mappingAt(index)?.rangeMin ?? mapping.target.defaultRange(for: cache.fractalType).lowerBound },
                                set: { newValue in
                                    updateMapping(index) { m in
                                        m.rangeMin = newValue
                                        m.sanitizeInPlace(for: cache.fractalType)
                                    }
                                }
                            ), range: mapping.target.allowedRange(for: cache.fractalType))

                            sliderRow(label: "Max", value: Binding(
                                get: { mappingAt(index)?.rangeMax ?? mapping.target.defaultRange(for: cache.fractalType).upperBound },
                                set: { newValue in
                                    updateMapping(index) { m in
                                        m.rangeMax = newValue
                                        m.sanitizeInPlace(for: cache.fractalType)
                                    }
                                }
                            ), range: mapping.target.allowedRange(for: cache.fractalType))

                            sliderRow(label: "Response", value: Binding(
                                get: { mappingAt(index)?.responseSpeed ?? 0.12 },
                                set: { newValue in updateMapping(index) { $0.responseSpeed = newValue; $0.sanitizeInPlace() } }
                            ), range: 0.01...0.6)

                            sliderRow(label: "Amount", value: Binding(
                                get: { mappingAt(index)?.amount ?? 1.0 },
                                set: { newValue in updateMapping(index) { $0.amount = newValue; $0.sanitizeInPlace() } }
                            ), range: -2...2)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.22)))
                    }

                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var musicPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Music Presets")
                .font(.subheadline.bold())

            HStack(spacing: 6) {
                TextField("Preset Name", text: $musicPresetName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveMusicPreset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(musicPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if musicPresets.isEmpty {
                Text("No music presets saved yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(musicPresets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.caption.bold())
                            Text(preset.createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Load") { loadMusicPreset(preset) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button(role: .destructive) { deleteMusicPreset(preset.id) } label: {
                            Image(systemName: "trash")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private func applyPreset(_ preset: ReactivityPreset) {
        // Core sensitivity settings
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
        
        let mappings = preset.defaultMappings(for: cache.fractalType)
        cache.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private var availableMappingTargetsToAdd: [MusicReactiveTarget] {
        let existing = Set(cache.musicReactiveMappings.map(\.target))
        let formulaCount = MusicReactiveTarget.floatFormulaParams(for: cache.fractalType).count
        return MusicReactiveTarget.availableCases.filter { target in
            if existing.contains(target) { return false }
            // Hide formula param slots beyond what this fractal supports
            if let slot = target.formulaParamSlot, slot >= formulaCount { return false }
            return true
        }
    }

    private func mappingAt(_ index: Int) -> MusicReactiveMapping? {
        guard cache.musicReactiveMappings.indices.contains(index) else { return nil }
        return cache.musicReactiveMappings[index]
    }

    private func updateMapping(_ index: Int, mutate: (inout MusicReactiveMapping) -> Void) {
        guard cache.musicReactiveMappings.indices.contains(index) else { return }
        var mappings = cache.musicReactiveMappings
        mutate(&mappings[index])
        mappings[index].sanitizeInPlace()
        cache.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func addMapping(_ target: MusicReactiveTarget) {
        var mappings = cache.musicReactiveMappings
        guard !mappings.contains(where: { $0.target == target }) else { return }
        mappings.append(target.defaultMapping(for: cache.fractalType, enabled: true))
        cache.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func removeMapping(at index: Int) {
        guard cache.musicReactiveMappings.indices.contains(index) else { return }
        var mappings = cache.musicReactiveMappings
        mappings.remove(at: index)
        cache.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private static let musicPresetStorageKey = "musicReactivePresets"

    private static func loadMusicPresets() -> [MusicReactivePreset] {
        guard let data = UserDefaults.standard.data(forKey: musicPresetStorageKey),
              let decoded = try? JSONDecoder().decode([MusicReactivePreset].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistMusicPresets() {
        if let encoded = try? JSONEncoder().encode(musicPresets) {
            UserDefaults.standard.set(encoded, forKey: Self.musicPresetStorageKey)
        }
    }

    private func saveMusicPreset() {
        let trimmed = musicPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = MusicReactivePreset(
            name: trimmed,
            audioAmount: cache.fractalAudioAmount,
            beatPunch: cache.fractalBeatPunch,
            bassSensitivity: cache.bassSensitivity,
            midSensitivity: cache.midSensitivity,
            trebleSensitivity: cache.trebleSensitivity,
            beatSensitivity: cache.beatSensitivity,
            mappings: cache.musicReactiveMappings
        )
        musicPresets.append(preset)
        persistMusicPresets()
        musicPresetName = ""
    }

    private func loadMusicPreset(_ preset: MusicReactivePreset) {
        cache.fractalAudioAmount = preset.audioAmount
        cache.fractalBeatPunch = preset.beatPunch
        cache.bassSensitivity = preset.bassSensitivity
        cache.midSensitivity = preset.midSensitivity
        cache.trebleSensitivity = preset.trebleSensitivity
        cache.beatSensitivity = preset.beatSensitivity
        cache.musicReactiveMappings = preset.mappings

        cache.push(\.fractalAudioAmount, value: preset.audioAmount)
        cache.push(\.fractalBeatPunch, value: preset.beatPunch)
        cache.push(\.bassSensitivity, value: preset.bassSensitivity)
        cache.push(\.midSensitivity, value: preset.midSensitivity)
        cache.push(\.trebleSensitivity, value: preset.trebleSensitivity)
        cache.push(\.beatSensitivity, value: preset.beatSensitivity)
        cache.push(\.musicReactiveMappings, value: preset.mappings)
    }

    private func deleteMusicPreset(_ id: UUID) {
        musicPresets.removeAll { $0.id == id }
        persistMusicPresets()
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
                .frame(width: 120, alignment: .leading)
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
