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

private enum MusicInnerTab: String, CaseIterable {
    case music = "Music"
    case visualizations = "Visualizations"
}

struct MusicTabContent: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var cache: UISettingsCache

    private let musicService: MusicService
    private let audioAnalyzer: AudioAnalyzer
    private let renderSettings: RenderSettings

    @State private var viewModel: MusicTabViewModel
    @AppStorage("MusicTabContent.innerTab") private var innerTab: MusicInnerTab = .music

    private var activeMusicPermutationCount: Int {
        guard cache.audioReactive.fractalAudioReactiveEnabled else { return 0 }
        return cache.audioReactive.musicReactiveMappings.filter(\.isEnabled).count
    }

    init(cache: UISettingsCache, musicService: MusicService, audioAnalyzer: AudioAnalyzer, renderSettings: RenderSettings) {
        self.cache = cache
        self.musicService = musicService
        self.audioAnalyzer = audioAnalyzer
        self.renderSettings = renderSettings
        _viewModel = State(initialValue: MusicTabViewModel(musicService: musicService))
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Section", selection: $innerTab) {
                ForEach(MusicInnerTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    switch innerTab {
                    case .music:
                        // Service toggle / picker
                        serviceToggle

                        // Unified Now Playing
                        nowPlayingCard

                        // Open Library button (pops into its own window)
                        if let commandErrorMessage = viewModel.commandErrorMessage {
                            Text(commandErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if viewModel.hasConnectedProvider {
                            openLibraryButton
                        }

                        // Service connections (settings)
                        connectionsSection

                        // Fallback priority ordering
                        if viewModel.hasMultipleConnectedProviders {
                            servicePrioritySection
                        }

                    case .visualizations:
                        // Audio Reactivity (the main event)
                        reactivitySection

                        // Saved music presets
                        musicPresetsSection

                        // Level meters
                        levelMeters
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }



    private var libraryScopeBinding: Binding<MusicTabViewModel.LibraryScope> {
        Binding(get: { viewModel.libraryScope }, set: { viewModel.libraryScope = $0 })
    }

    private var libraryShuffleBinding: Binding<Bool> {
        Binding(get: { viewModel.libraryShuffle }, set: { viewModel.libraryShuffle = $0 })
    }

    private var librarySearchBinding: Binding<String> {
        Binding(get: { viewModel.librarySearch }, set: { viewModel.librarySearch = $0 })
    }

    private var musicPresetNameBinding: Binding<String> {
        Binding(get: { viewModel.musicPresetName }, set: { viewModel.musicPresetName = $0 })
    }

    // MARK: - Service Toggle

    private var serviceToggle: some View {
        let music = musicService
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
                        get: { viewModel.activeServiceSelectionID },
                        set: { newID in viewModel.setActiveService(newID) }
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
        let music = musicService
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
                    Button { viewModel.previousTrack() } label: {
                        Image(systemName: "backward.fill").font(.title3)
                    }
                    .buttonStyle(.plain)

                    Button { viewModel.togglePlayPause() } label: {
                        Image(systemName: music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                    .buttonStyle(.plain)
                    .tint(music.accentColor)

                    Button { viewModel.nextTrack() } label: {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                if viewModel.hasConnectedProvider {
                    Button {
                        openWindow(id: AppModel.libraryWindowID)
                    } label: {
                        HStack {
                            Label("Change Song", systemImage: "music.note.list")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
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
        let music = musicService
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
                Image(systemName: audioAnalyzer.isCapturing ? "mic.fill" : "mic.slash.fill")
                    .font(.caption)
                    .foregroundStyle(audioAnalyzer.isCapturing ? .green : .secondary)
                Text("Microphone")
                    .font(.subheadline)
                Spacer()
                Button(audioAnalyzer.isCapturing ? "Stop" : "Start") {
                    if audioAnalyzer.isCapturing {
                        audioAnalyzer.stopCapture()
                    } else {
                        audioAnalyzer.startCapture()
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
                        viewModel.disconnect(provider)
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
                    viewModel.connect(provider)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(provider.accentColor)
            }
        }
    }

    // MARK: - Service Priority

    private var servicePrioritySection: some View {
        let music = musicService
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
        let music = musicService
        let activeServiceName = music.activeProvider?.displayName ?? "Library"
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.showLibrary.toggle() }
            } label: {
                HStack {
                    Image(systemName: "music.note.list")
                        .font(.caption)
                    Text("\(activeServiceName) Library")
                        .font(.subheadline.bold())
                    Spacer()
                    Image(systemName: viewModel.showLibrary ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if viewModel.showLibrary {
                libraryBrowser
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var libraryBrowser: some View {
        let music = musicService
        let activeID = music.activeProvider?.serviceID
        return VStack(spacing: 8) {
            HStack {
                Picker("", selection: libraryScopeBinding) {
                    ForEach(MusicTabViewModel.LibraryScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if viewModel.libraryScope != .songs {
                    Toggle("", isOn: libraryShuffleBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Button {
                    viewModel.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextField("Search…", text: librarySearchBinding)
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
                        switch viewModel.libraryScope {
                        case .songs:
                            ForEach(Array(viewModel.filteredSongs(for: activeID).prefix(100)), id: \.id) { track in
                                unifiedSongRow(track)
                            }
                        case .playlists:
                            ForEach(Array(viewModel.filteredPlaylists(for: activeID).prefix(100)), id: \.id) { pl in
                                unifiedPlaylistRow(pl)
                            }
                        case .albums:
                            ForEach(Array(viewModel.filteredAlbums(for: activeID).prefix(100)), id: \.id) { album in
                                unifiedAlbumRow(album)
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
                viewModel.refreshLibrary()
            }
        }
    }

    // MARK: - Unified Library Rows

    private func unifiedSongRow(_ track: UnifiedTrack) -> some View {
        Button { viewModel.playSong(track) } label: {
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

    private func unifiedPlaylistRow(_ pl: UnifiedPlaylist) -> some View {
        Button { viewModel.playPlaylist(pl) } label: {
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

    private func unifiedAlbumRow(_ album: UnifiedAlbum) -> some View {
        Button { viewModel.playAlbum(album) } label: {
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
            HStack {
                Text("Music")
                    .font(.subheadline.bold())
                Spacer()
                HStack(spacing: 8) {
                    Label("React to Music", systemImage: cache.audioReactive.fractalAudioReactiveEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(cache.audioReactive.fractalAudioReactiveEnabled ? .blue : .secondary)
                    Text("\(activeMusicPermutationCount)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(cache.audioReactive.fractalAudioReactiveEnabled ? .blue : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((cache.audioReactive.fractalAudioReactiveEnabled ? Color.blue : Color.secondary).opacity(0.14)))
                }
                .accessibilityElement(children: .combine)
            }

            Toggle("React to Music", isOn: Binding(
                get: { cache.audioReactive.fractalAudioReactiveEnabled },
                set: { isOn in
                    cache.audioReactive.fractalAudioReactiveEnabled = isOn
                    cache.push(\.fractalAudioReactiveEnabled, value: isOn)
                    if isOn {
                        cache.display.lightingMode = .audioReactive
                        cache.push(\.lightingMode, value: .audioReactive)
                    }
                }
            ))

            Toggle("Show Music Shortcuts on Parameters", isOn: $cache.display.showMusicShortcuts)
                .onChange(of: cache.display.showMusicShortcuts) { _, v in cache.push(\.showMusicShortcuts, value: v) }

            if cache.audioReactive.fractalAudioReactiveEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Genre Presets")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(ReactivityPreset.allCases, id: \.self) { preset in
                            Button { applyPreset(preset) } label: {
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

                    sliderRow(label: "Amount", value: Binding(
                        get: { cache.audioReactive.fractalAudioAmount },
                        set: { v in cache.audioReactive.fractalAudioAmount = v; cache.push(\.fractalAudioAmount, value: v) }
                    ), range: 0...1)

                    sliderRow(label: "Beat Punch", value: Binding(
                        get: { cache.audioReactive.fractalBeatPunch },
                        set: { v in cache.audioReactive.fractalBeatPunch = v; cache.push(\.fractalBeatPunch, value: v) }
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
                                            Button { addMapping(target) } label: {
                                                Label(target.displayName, systemImage: target.icon)
                                            }
                                        }
                                    }
                                }

                                if !formulaTargets.isEmpty {
                                    Section("\(cache.fractalType.displayName) Params") {
                                        ForEach(formulaTargets, id: \.self) { target in
                                            Button { addMapping(target) } label: {
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

                        ForEach(Array(cache.audioReactive.musicReactiveMappings.enumerated()), id: \.element.id) { index, mapping in
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

                                    Button { removeMapping(at: index) } label: {
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

                                Picker("Curve", selection: Binding(
                                    get: { mappingAt(index)?.responseCurve ?? .sinusoidal },
                                    set: { newValue in updateMapping(index) { $0.responseCurve = newValue } }
                                )) {
                                    ForEach(ResponseCurve.allCases, id: \.self) { curve in
                                        Label(curve.displayName, systemImage: curve.icon).tag(curve)
                                    }
                                }
                                .pickerStyle(.segmented)

                                if (mappingAt(index)?.responseCurve ?? .sinusoidal) == .hybrid {
                                    sliderRow(label: "Hybrid Combo", value: Binding(
                                        get: { mappingAt(index)?.hybridCombo ?? 0.35 },
                                        set: { newValue in updateMapping(index) { $0.hybridCombo = newValue; $0.sanitizeInPlace() } }
                                    ), range: 0...1)

                                    HStack {
                                        Text("Drift")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("Vibration")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Text("Music modulation is always relative to the current animation or manual base value.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                sliderRow(label: "Intensity", value: Binding(
                                    get: { mappingAt(index)?.amount ?? 1.0 },
                                    set: { newValue in updateMapping(index) { $0.amount = newValue; $0.sanitizeInPlace() } }
                                ), range: 0...3)

                                sliderRow(label: "Smooth", value: Binding(
                                    get: { mappingAt(index)?.smoothingWindow ?? 0.0 },
                                    set: { newValue in updateMapping(index) { $0.smoothingWindow = newValue; $0.sanitizeInPlace() } }
                                ), range: 0...2)

                                DisclosureGroup {
                                    VStack(spacing: 6) {
                                        Toggle("Invert", isOn: Binding(
                                            get: { (mappingAt(index)?.amount ?? 1.0) < 0 },
                                            set: { invert in
                                                updateMapping(index) { $0.amount = invert ? -abs($0.amount) : abs($0.amount) }
                                            }
                                        ))
                                        .font(.caption2)
                                        .toggleStyle(.switch)
                                        .controlSize(.small)

                                        Divider()

                                        Toggle("LFO Oscillator", isOn: Binding(
                                            get: { mappingAt(index)?.lfo.enabled ?? false },
                                            set: { newValue in updateMapping(index) { $0.lfo.enabled = newValue } }
                                        ))
                                        .font(.caption2)
                                        .toggleStyle(.switch)
                                        .controlSize(.small)

                                        if mappingAt(index)?.lfo.enabled == true {
                                            Picker("Shape", selection: Binding(
                                                get: { mappingAt(index)?.lfo.shape ?? .sine },
                                                set: { newValue in updateMapping(index) { $0.lfo.shape = newValue } }
                                            )) {
                                                ForEach(LFOShape.allCases, id: \.self) { shape in
                                                    Image(systemName: shape.icon).tag(shape)
                                                }
                                            }
                                            .pickerStyle(.segmented)

                                            sliderRow(label: "Speed", value: Binding(
                                                get: { mappingAt(index)?.lfo.frequency ?? 0.1 },
                                                set: { newValue in updateMapping(index) { $0.lfo.frequency = newValue; $0.lfo.sanitizeInPlace() } }
                                            ), range: 0.01...5.0)

                                            sliderRow(label: "Depth", value: Binding(
                                                get: { mappingAt(index)?.lfo.amplitude ?? 0.2 },
                                                set: { newValue in updateMapping(index) { $0.lfo.amplitude = newValue; $0.lfo.sanitizeInPlace() } }
                                            ), range: 0...1)
                                        }
                                    }
                                } label: {
                                    Text("Advanced")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption2)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.22)))
                        }
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
                TextField("Preset Name", text: musicPresetNameBinding)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { viewModel.saveMusicPreset(using: cache) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.musicPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if viewModel.musicPresets.isEmpty {
                Text("No music presets saved yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.musicPresets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.caption.bold())
                            Text(preset.createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Load") { viewModel.loadMusicPreset(preset, into: cache) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button(role: .destructive) { viewModel.deleteMusicPreset(preset.id) } label: {
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
        cache.audioReactive.fractalAudioAmount = s.audioAmount
        cache.audioReactive.fractalBeatPunch = s.beatPunch
        cache.audioReactive.bassSensitivity = s.bassSensitivity
        cache.audioReactive.midSensitivity = s.midSensitivity
        cache.audioReactive.trebleSensitivity = s.trebleSensitivity
        cache.audioReactive.beatSensitivity = s.beatSensitivity
        cache.push(\.fractalAudioAmount, value: s.audioAmount)
        cache.push(\.fractalBeatPunch, value: s.beatPunch)
        cache.push(\.bassSensitivity, value: s.bassSensitivity)
        cache.push(\.midSensitivity, value: s.midSensitivity)
        cache.push(\.trebleSensitivity, value: s.trebleSensitivity)
        cache.push(\.beatSensitivity, value: s.beatSensitivity)
        
        let mappings = preset.defaultMappings(for: cache.fractalType)
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private var availableMappingTargetsToAdd: [MusicReactiveTarget] {
        let existing = Set(cache.audioReactive.musicReactiveMappings.map(\.target))
        return MusicReactiveTarget.availableCases(for: cache.fractalType).filter { target in
            !existing.contains(target)
        }
    }

    private func mappingAt(_ index: Int) -> MusicReactiveMapping? {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return nil }
        return cache.audioReactive.musicReactiveMappings[index]
    }

    private func updateMapping(_ index: Int, mutate: (inout MusicReactiveMapping) -> Void) {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return }
        var mappings = cache.audioReactive.musicReactiveMappings
        mutate(&mappings[index])
        mappings[index].sanitizeInPlace()
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func addMapping(_ target: MusicReactiveTarget) {
        var mappings = cache.audioReactive.musicReactiveMappings
        guard !mappings.contains(where: { $0.target == target }) else { return }
        mappings.append(target.defaultMapping(for: cache.fractalType, enabled: true))
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func removeMapping(at index: Int) {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return }
        var mappings = cache.audioReactive.musicReactiveMappings
        mappings.remove(at: index)
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    // MARK: - Level Meters

    private var levelMeters: some View {
        TimelineView(.animation) { _ in
            let rs = renderSettings
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

#if DEBUG
@MainActor
private final class PreviewMusicProvider: MusicServiceProvider {
    let serviceID: String
    let displayName: String
    let iconName: String
    let accentColor: Color

    var connectionStatus: MusicServiceConnectionStatus
    var nowPlaying: UnifiedTrack?
    var isPlaying: Bool

    var progressFraction: Float = 0.45
    var currentTimeString: String = "1:12"
    var totalTimeString: String = "3:40"

    var librarySongs: [UnifiedTrack] = []
    var libraryPlaylists: [UnifiedPlaylist] = []
    var libraryAlbums: [UnifiedAlbum] = []
    var isLibraryLoading: Bool = false
    var libraryError: String?

    var bassLevel: Float = 0.2
    var midLevel: Float = 0.35
    var trebleLevel: Float = 0.45
    var beatIntensity: Float = 0.4
    var overallLevel: Float = 0.33

    init(serviceID: String,
         displayName: String,
         iconName: String,
         accentColor: Color,
         connectionStatus: MusicServiceConnectionStatus,
         nowPlaying: UnifiedTrack? = nil,
         isPlaying: Bool = false,
         libraryError: String? = nil) {
        self.serviceID = serviceID
        self.displayName = displayName
        self.iconName = iconName
        self.accentColor = accentColor
        self.connectionStatus = connectionStatus
        self.nowPlaying = nowPlaying
        self.isPlaying = isPlaying
        self.libraryError = libraryError
    }

    func connect() { connectionStatus = .connected }
    func disconnect() { connectionStatus = .disconnected }
    func togglePlayPause() async { isPlaying.toggle() }
    func next() async {}
    func previous() async {}
    func seek(fraction: Float) async {}
    func refreshLibrary() async {}
    func playSong(_ track: UnifiedTrack) async { nowPlaying = track; isPlaying = true }
    func playSongByNativeID(_ nativeID: String) async -> Bool { true }
    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool) async {}
    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool) async {}
    func fetchPlaylistTracks(_ playlist: UnifiedPlaylist) async -> [UnifiedTrack] { [] }
    func searchTrack(title: String, artist: String) async -> UnifiedTrack? { nil }
    func updateFrame() {}
}

@MainActor
private struct MusicTabPreviewHarness: View {
    @State private var cache = UISettingsCache()

    let musicService: MusicService
    let title: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            MusicTabContent(
                cache: cache,
                musicService: musicService,
                audioAnalyzer: AudioAnalyzer(),
                renderSettings: RenderSettings()
            )
        }
        .frame(width: 460, height: 860)
    }
}

#Preview("No providers") {
    MusicTabPreviewHarness(
        musicService: MusicService(previewProviders: []),
        title: "No Connected Providers"
    )
}

#Preview("One provider") {
    let track = UnifiedTrack(
        id: "song-1",
        serviceID: "appleMusic",
        title: "Threshold Pulse",
        artist: "Codex",
        album: "Raymarch Dreams",
        artworkURL: nil,
        durationSeconds: 220
    )
    let provider = PreviewMusicProvider(
        serviceID: "appleMusic",
        displayName: "Apple Music",
        iconName: "apple.logo",
        accentColor: .pink,
        connectionStatus: .connected,
        nowPlaying: track,
        isPlaying: true
    )
    MusicTabPreviewHarness(
        musicService: MusicService(previewProviders: [provider], preferredServiceID: provider.serviceID),
        title: "Single Connected Provider"
    )
}

#Preview("Multiple providers") {
    let apple = PreviewMusicProvider(
        serviceID: "appleMusic",
        displayName: "Apple Music",
        iconName: "apple.logo",
        accentColor: .pink,
        connectionStatus: .connected,
        nowPlaying: UnifiedTrack(id: "song-2", serviceID: "appleMusic", title: "Synth Bloom", artist: "Skyline", album: "A", artworkURL: nil, durationSeconds: 210),
        isPlaying: true
    )
    let spotify = PreviewMusicProvider(
        serviceID: "spotify",
        displayName: "Spotify",
        iconName: "waveform",
        accentColor: .green,
        connectionStatus: .connected
    )
    MusicTabPreviewHarness(
        musicService: MusicService(previewProviders: [apple, spotify], preferredServiceID: apple.serviceID),
        title: "Multiple Connected Providers"
    )
}

#Preview("Disconnected + Error") {
    let disconnected = PreviewMusicProvider(
        serviceID: "appleMusic",
        displayName: "Apple Music",
        iconName: "apple.logo",
        accentColor: .pink,
        connectionStatus: .disconnected
    )
    let errorProvider = PreviewMusicProvider(
        serviceID: "spotify",
        displayName: "Spotify",
        iconName: "waveform",
        accentColor: .green,
        connectionStatus: .error("Token expired"),
        libraryError: "Refresh failed"
    )
    MusicTabPreviewHarness(
        musicService: MusicService(previewProviders: [disconnected, errorProvider]),
        title: "Disconnected / Error States"
    )
}
#endif
