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

enum MusicPanelTab: String, CaseIterable {
    case music = "Music"
    case songs = "Songs"
    case playlists = "Playlists"
    case albums = "Albums"
    case visualizations = "Visualizations"
}

struct MusicTabContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.menuAdjustmentActions) private var menuAdjustmentActions
    @Bindable var cache: UISettingsCache

    private let musicService: MusicService
    private let audioAnalyzer: AudioAnalyzer
    private let renderSettings: RenderSettings
    #if os(macOS)
    private let musicAppCapture: MusicAppAudioCapture
    #endif

    @State private var viewModel: MusicTabViewModel
    var tabSelection: Binding<MusicPanelTab>? = nil
    @AppStorage("MusicTabContent.innerTab") private var storedTabSelection: MusicPanelTab = .music
    #if os(macOS)
    @AppStorage("macMusicAppAudioCaptureEnabled") private var macMusicAppAudioCaptureEnabled = false
    #endif
    @State private var isShowingVisualizationAddPopover = false
    @State private var isHoldingVisualizationAddAdjustment = false

    private var effectiveTabSelection: Binding<MusicPanelTab> {
        Binding(
            get: { normalizedMusicPanelTab(tabSelection?.wrappedValue ?? storedTabSelection) },
            set: { newValue in
                let normalized = normalizedMusicPanelTab(newValue)
                storedTabSelection = normalized
                tabSelection?.wrappedValue = normalized
            }
        )
    }

    private func normalizedMusicPanelTab(_ tab: MusicPanelTab) -> MusicPanelTab {
        #if os(macOS)
        switch tab {
        case .songs, .playlists, .albums:
            return .music
        case .music, .visualizations:
            return tab
        }
        #else
        return tab
        #endif
    }

    private var activeMusicPermutationCount: Int {
        guard cache.audioReactive.fractalAudioReactiveEnabled else { return 0 }
        return cache.audioReactive.musicReactiveMappings.count
    }

    private var hasFlashingVisualMappings: Bool {
        cache.audioReactive.musicReactiveMappings.contains(where: \.hasFlashingRisk)
    }

    private var canAddVisualizationMapping: Bool {
        cache.audioReactive.fractalAudioReactiveEnabled && !availableMappingTargetsToAdd.isEmpty
    }

    #if os(macOS)
    init(
        cache: UISettingsCache,
        musicService: MusicService,
        audioAnalyzer: AudioAnalyzer,
        renderSettings: RenderSettings,
        musicAppCapture: MusicAppAudioCapture,
        tabSelection: Binding<MusicPanelTab>? = nil
    ) {
        self.cache = cache
        self.musicService = musicService
        self.audioAnalyzer = audioAnalyzer
        self.renderSettings = renderSettings
        self.musicAppCapture = musicAppCapture
        self.tabSelection = tabSelection
        _viewModel = State(initialValue: MusicTabViewModel(musicService: musicService))
    }
    #else
    init(
        cache: UISettingsCache,
        musicService: MusicService,
        audioAnalyzer: AudioAnalyzer,
        renderSettings: RenderSettings,
        tabSelection: Binding<MusicPanelTab>? = nil
    ) {
        self.cache = cache
        self.musicService = musicService
        self.audioAnalyzer = audioAnalyzer
        self.renderSettings = renderSettings
        self.tabSelection = tabSelection
        _viewModel = State(initialValue: MusicTabViewModel(musicService: musicService))
    }
    #endif

    var body: some View {
        VStack(spacing: 10) {
            Group {
                switch effectiveTabSelection.wrappedValue {
                case .music:
                    #if os(macOS)
                    macAudioVisualizerDashboard
                    #else
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 10) {
                            serviceToggle

                            nowPlayingCard

                            if let commandErrorMessage = viewModel.commandErrorMessage {
                                Text(commandErrorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            connectionsSection

                            if viewModel.hasMultipleConnectedProviders {
                                servicePrioritySection
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    #endif

                case .songs:
                    librarySongsSection

                case .playlists:
                    libraryPlaylistsSection

                case .albums:
                    libraryAlbumsSection

                case .visualizations:
                    VStack(spacing: 10) {
                        visualizationHeaderSection

                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 10) {
                                reactivitySection
                                levelMeters
                            }
                            .padding(.bottom, 10)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: isShowingVisualizationAddPopover) { _, isPresented in
            updateVisualizationAddPopoverAdjustment(isPresented: isPresented)
        }
        .onDisappear {
            updateVisualizationAddPopoverAdjustment(isPresented: false)
        }
    }

    private func updateVisualizationAddPopoverAdjustment(isPresented: Bool) {
#if os(macOS)
        if isPresented {
            guard !isHoldingVisualizationAddAdjustment else { return }
            isHoldingVisualizationAddAdjustment = true
            menuAdjustmentActions.begin()
        } else {
            guard isHoldingVisualizationAddAdjustment else { return }
            isHoldingVisualizationAddAdjustment = false
            menuAdjustmentActions.end()
        }
#endif
    }

    #if os(macOS)
    private var macAudioVisualizerDashboard: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 10) {
                macAudioInputHero
                if macMusicAppAudioCaptureEnabled {
                    musicAppVisualizerHero
                }
                levelMeters
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var macAudioInputHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Input Visualizer")
                        .font(.headline)
                    Text("Use the Mac microphone or selected audio input for reactive visuals. Music.app audio capture is available as an advanced opt-in below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Label(audioAnalyzer.isCapturing ? "Live" : "Ready",
                      systemImage: audioAnalyzer.isCapturing ? "waveform.circle.fill" : "circle.dashed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(audioAnalyzer.isCapturing ? .green : .secondary)
            }

            HStack(spacing: 8) {
                Button(audioAnalyzer.isMicrophoneCapturing ? "Stop Input" : "Start Input") {
                    if audioAnalyzer.isMicrophoneCapturing {
                        audioAnalyzer.stopCapture()
                    } else {
                        startAudioInputVisualizer(using: .electronic)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Reactive Controls") {
                    effectiveTabSelection.wrappedValue = .visualizations
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Presets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach([ReactivityPreset.electronic, .ambient, .hiphop], id: \.self) { preset in
                        Button(preset.rawValue) {
                            startAudioInputVisualizer(using: preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let message = audioAnalyzer.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Advanced Music.app audio capture", isOn: $macMusicAppAudioCaptureEnabled)
                .font(.caption)
                .onChange(of: macMusicAppAudioCaptureEnabled) { _, isEnabled in
                    guard !isEnabled else { return }
                    Task { await musicAppCapture.stop() }
                }

            if !macMusicAppAudioCaptureEnabled {
                Text("Optional Music.app capture uses ScreenCaptureKit and may require Screen Recording or Screen & System Audio Recording permission. It captures Music.app process audio, not a specific window.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
    }

    private var musicAppVisualizerHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Music.app Audio Capture")
                        .font(.headline)
                    Text("Advanced opt-in capture listens to Music.app process audio through ScreenCaptureKit. macOS may ask for Screen Recording or Screen & System Audio Recording permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Label(musicAppCapture.isCapturing ? "Live" : "Ready",
                      systemImage: musicAppCapture.isCapturing ? "waveform.circle.fill" : "circle.dashed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(musicAppCapture.isCapturing ? .green : .secondary)
            }

            HStack(spacing: 8) {
                Button(musicAppCapture.isCapturing ? "Refresh Capture" : "Start Capture") {
                    startMusicAppVisualizer(using: .electronic)
                }
                .buttonStyle(.borderedProminent)

                Button("Reactive Controls") {
                    effectiveTabSelection.wrappedValue = .visualizations
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Presets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach([ReactivityPreset.electronic, .ambient, .hiphop], id: \.self) { preset in
                        Button(preset.rawValue) {
                            startMusicAppVisualizer(using: preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Text("ScreenCaptureKit can target Music.app as a process, but macOS does not provide reliable per-window audio isolation.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            musicAppCaptureRow
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.indigo.opacity(0.08)))
    }
    #endif

    private var reactToMusicBinding: Binding<Bool> {
        Binding(
            get: { cache.audioReactive.fractalAudioReactiveEnabled },
            set: { isOn in
                cache.audioReactive.fractalAudioReactiveEnabled = isOn
                cache.push(\.fractalAudioReactiveEnabled, value: isOn)
                if isOn {
                    cache.display.lightingMode = .audioReactive
                    cache.push(\.lightingMode, value: .audioReactive)
                }
            }
        )
    }

    private var visualizationAddButton: some View {
        Button {
            isShowingVisualizationAddPopover = true
        } label: {
            Label("Add Control", systemImage: "plus.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(canAddVisualizationMapping ? .blue : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill((canAddVisualizationMapping ? Color.blue : Color.secondary).opacity(0.12))
                )
                .overlay(
                    Capsule()
                        .stroke((canAddVisualizationMapping ? Color.blue : Color.secondary).opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canAddVisualizationMapping)
        .opacity(canAddVisualizationMapping ? 1.0 : 0.72)
        .popover(isPresented: $isShowingVisualizationAddPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            visualizationAddPopoverContent
        }
    }

    private var visualizationAddPopoverContent: some View {
        let available = availableMappingTargetsToAdd
        let formulaTargets = available.filter { $0.isFormulaParam }
        let universalTargets = available.filter { !$0.isFormulaParam }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Add Music Control")
                .font(.headline)

            if available.isEmpty {
                Text("All targets added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !formulaTargets.isEmpty {
                    addTargetSection(
                        title: "\(cache.fractalType.displayName) Params",
                        targets: formulaTargets,
                        label: { target in
                            target.displayName(for: cache.fractalType)
                        },
                        icon: { target in
                            target.icon(for: cache.fractalType)
                        }
                    )
                }

                if !universalTargets.isEmpty {
                    addTargetSection(
                        title: "Universal",
                        targets: universalTargets,
                        label: { target in
                            target.displayName
                        },
                        icon: { target in
                            target.icon
                        }
                    )
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func addTargetSection(
        title: String,
        targets: [MusicReactiveTarget],
        label: @escaping (MusicReactiveTarget) -> String,
        icon: @escaping (MusicReactiveTarget) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(targets, id: \.self) { target in
                Button {
                    addMapping(target)
                    isShowingVisualizationAddPopover = false
                } label: {
                    HStack(spacing: 8) {
                        Label(label(target), systemImage: icon(target))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if target.hasFlashingRisk {
                            FlashingLightIndicator()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.22)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var visualizationHeaderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Music Reactive Visuals")
                .font(.subheadline.bold())
            Text("Toggle and map audio-driven modulation")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 10) {
                // Quick Mix — only visible when reactive is on
                if cache.audioReactive.fractalAudioReactiveEnabled {
                    quickMixTile
                }

                Spacer(minLength: 0)

                visualizationControlTile
            }

            if !cache.audioReactive.fractalAudioReactiveEnabled {
                Text("Enable React to Music to add parameter mappings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if availableMappingTargetsToAdd.isEmpty {
                Text("All available parameters are already mapped.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
    }

    private var quickMixTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Mix")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            sliderRow(label: "Amount", value: Binding(
                get: { cache.audioReactive.fractalAudioAmount },
                set: { v in cache.audioReactive.fractalAudioAmount = v; cache.push(\.fractalAudioAmount, value: v) }
            ), range: 0...1, showsFlashingWarning: hasFlashingVisualMappings)

            sliderRow(label: "Beat", value: Binding(
                get: { cache.audioReactive.fractalBeatPunch },
                set: { v in cache.audioReactive.fractalBeatPunch = v; cache.push(\.fractalBeatPunch, value: v) }
            ), range: 0...1)
        }
        .padding(12)
        .frame(height: 112, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.blue.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
        )
    }

    private var visualizationControlTile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Reactive")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Image(systemName: cache.audioReactive.fractalAudioReactiveEnabled ? "waveform.circle.fill" : "waveform.circle")
                            .font(.caption)
                        Text("\(activeMusicPermutationCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(cache.audioReactive.fractalAudioReactiveEnabled ? .blue : .secondary)
                }

                Spacer(minLength: 0)

                Toggle("React to Music", isOn: reactToMusicBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Spacer(minLength: 0)

            if cache.audioReactive.fractalAudioReactiveEnabled {
                visualizationAddButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(width: 148, height: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((cache.audioReactive.fractalAudioReactiveEnabled ? Color.blue : Color.secondary).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder((cache.audioReactive.fractalAudioReactiveEnabled ? Color.blue : Color.secondary).opacity(0.18), lineWidth: 1)
        )
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
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
            }
        }
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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.indigo.opacity(0.08)))
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
                Menu {
                    Button {
                        cache.display.showMusicShortcuts.toggle()
                        cache.push(\.showMusicShortcuts, value: cache.display.showMusicShortcuts)
                    } label: {
                        Label(cache.display.showMusicShortcuts ? "Hide Parameter Shortcuts" : "Show Parameter Shortcuts", systemImage: cache.display.showMusicShortcuts ? "checkmark.circle.fill" : "circle")
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Dynamic rows for every registered provider
            ForEach(music.providers, id: \.serviceID) { provider in
                serviceRow(provider)
                if provider.serviceID != music.providers.last?.serviceID {
                    Divider()
                }
            }

            Divider()

            #if os(macOS)
            macMicrophoneCaptureRow
            if macMusicAppAudioCaptureEnabled {
                Divider()
                musicAppCaptureRow
            }
            #else
            // Microphone row
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: audioAnalyzer.isMicrophoneCapturing ? "mic.fill" : "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(audioAnalyzer.isMicrophoneCapturing ? .green : .secondary)
                    Text("Microphone")
                        .font(.subheadline)
                    Spacer()
                    Button(audioAnalyzer.isMicrophoneCapturing ? "Stop" : "Start") {
                        if audioAnalyzer.isMicrophoneCapturing {
                            audioAnalyzer.stopCapture()
                        } else {
                            audioAnalyzer.startCapture()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let message = audioAnalyzer.errorMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #endif
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
    }

    #if os(macOS)
    private var macMicrophoneCaptureRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: audioAnalyzer.isMicrophoneCapturing ? "mic.fill" : "mic.slash.fill")
                    .font(.caption)
                    .foregroundStyle(audioAnalyzer.isMicrophoneCapturing ? .green : .secondary)
                Text("Audio Input")
                    .font(.subheadline)
                Spacer()
                Button(audioAnalyzer.isMicrophoneCapturing ? "Stop" : "Start") {
                    if audioAnalyzer.isMicrophoneCapturing {
                        audioAnalyzer.stopCapture()
                    } else {
                        audioAnalyzer.startCapture()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let message = audioAnalyzer.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Uses microphone permission only. Select a system or virtual audio input in macOS Sound settings when needed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Row that lets the user start/stop capturing audio from the native Music.app.
    @ViewBuilder
    private var musicAppCaptureRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: musicAppCapture.isCapturing ? "speaker.wave.2.fill" : "music.note")
                    .font(.caption)
                    .foregroundStyle(musicAppCapture.isCapturing ? .green : .secondary)
                Text("Music.app")
                    .font(.subheadline)
                Spacer()
                Button(musicAppCapture.isCapturing ? "Stop" : "Start") {
                    if musicAppCapture.isCapturing {
                        Task {
                            await musicAppCapture.stop()
                        }
                    } else {
                        startMusicAppVisualizer(using: .electronic)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let message = musicAppCapture.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !musicAppCapture.isMusicAppRunning {
                Text("Open Music.app to capture its process audio. This cannot isolate one Music window from another.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if musicAppCapture.isCapturing {
                Text("Capturing Music.app audio. Start playback to drive the visualizer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: musicAppCapture.isCapturing) {
            if !musicAppCapture.isCapturing {
                await musicAppCapture.refreshAvailability()
            }
        }
    }

    private func startMusicAppVisualizer(using preset: ReactivityPreset) {
        Task {
            guard macMusicAppAudioCaptureEnabled else { return }
            if !musicAppCapture.isCapturing {
                await musicAppCapture.start()
            }
            guard musicAppCapture.isCapturing else { return }
            configureMusicAppVisualizer(using: preset)
        }
    }

    private func startAudioInputVisualizer(using preset: ReactivityPreset) {
        if !audioAnalyzer.isMicrophoneCapturing {
            audioAnalyzer.startCapture()
        }
        configureMusicAppVisualizer(using: preset)
    }

    private func configureMusicAppVisualizer(using preset: ReactivityPreset) {
        if cache.display.lightingMode != .visualizer {
            cache.display.lightingMode = .visualizer
            cache.push(\.lightingMode, value: .visualizer)
        }
        if !cache.audioReactive.fractalAudioReactiveEnabled {
            cache.audioReactive.fractalAudioReactiveEnabled = true
            cache.push(\.fractalAudioReactiveEnabled, value: true)
        }
        applyPreset(preset)
    }
    #endif

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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
    }

    // MARK: - Unified Library Browser

    // MARK: - Inline Library Sections

    private var librarySongsSection: some View {
        let music = musicService
        let activeID = music.activeProvider?.serviceID
        let songs = viewModel.filteredSongs(for: activeID)
        return libraryPane(
            title: "Songs",
            systemImage: "music.note",
            accent: music.activeProvider?.accentColor ?? .blue,
            isLoading: music.isLibraryLoading(for: activeID),
            errorMessage: music.libraryError(for: activeID),
            isEmpty: songs.isEmpty,
            emptyTitle: "No Songs",
            emptySystemImage: "music.note",
            emptyDescription: "No songs match your search."
        ) {
            ForEach(songs, id: \.id) { track in
                unifiedSongRow(track)
            }
        }
    }

    private var libraryPlaylistsSection: some View {
        let music = musicService
        let activeID = music.activeProvider?.serviceID
        let playlists = viewModel.filteredPlaylists(for: activeID)
        return libraryPane(
            title: "Playlists",
            systemImage: "music.note.list",
            accent: .pink,
            isLoading: music.isLibraryLoading(for: activeID),
            errorMessage: music.libraryError(for: activeID),
            isEmpty: playlists.isEmpty,
            emptyTitle: "No Playlists",
            emptySystemImage: "music.note.list",
            emptyDescription: "No playlists match your search."
        ) {
            ForEach(playlists, id: \.id) { playlist in
                unifiedPlaylistRow(playlist)
            }
        }
    }

    private var libraryAlbumsSection: some View {
        let music = musicService
        let activeID = music.activeProvider?.serviceID
        let albums = viewModel.filteredAlbums(for: activeID)
        return libraryPane(
            title: "Albums",
            systemImage: "square.stack",
            accent: .teal,
            isLoading: music.isLibraryLoading(for: activeID),
            errorMessage: music.libraryError(for: activeID),
            isEmpty: albums.isEmpty,
            emptyTitle: "No Albums",
            emptySystemImage: "square.stack",
            emptyDescription: "No albums match your search."
        ) {
            ForEach(albums, id: \.id) { album in
                unifiedAlbumRow(album)
            }
        }
    }

    private func libraryPane<Rows: View>(
        title: String,
        systemImage: String,
        accent: Color,
        isLoading: Bool,
        errorMessage: String?,
        isEmpty: Bool,
        emptyTitle: String,
        emptySystemImage: String,
        emptyDescription: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        let music = musicService
        let activeID = music.activeProvider?.serviceID
        return VStack(alignment: .leading, spacing: 10) {
            libraryPaneHeader(title: title, systemImage: systemImage, accent: accent)

            if isLoading {
                Spacer(minLength: 0)
                ProgressView("Loading library…")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else if let errorMessage {
                Spacer(minLength: 0)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else if isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySystemImage, description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        rows()
                    }
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(0.16), lineWidth: 1)
        )
        .onAppear {
            if music.librarySongs(for: activeID).isEmpty,
               !music.isLibraryLoading(for: activeID) {
                viewModel.refreshLibrary()
            }
        }
    }

    private func libraryPaneHeader(title: String, systemImage: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                if let serviceName = musicService.activeProvider?.displayName {
                    Text(serviceName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(accent.opacity(0.14)))
                }
            }

            HStack(spacing: 8) {
                TextField("Search", text: librarySearchBinding)
                    .textFieldStyle(.roundedBorder)
                Button { viewModel.refreshLibrary() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(accent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
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
            if cache.audioReactive.fractalAudioReactiveEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mapped Parameters")
                            .font(.subheadline.bold())
                        Spacer()

                        Menu {
                            Section("Preset Shortcuts") {
                                ForEach(ReactivityPreset.allCases, id: \.self) { preset in
                                    Button {
                                        applyPreset(preset)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Label(preset.rawValue, systemImage: preset.icon)
                                            if preset.hasFlashingRisk {
                                                FlashingLightIndicator()
                                            }
                                        }
                                    }
                                }
                            }

                            if !cache.audioReactive.musicReactiveMappings.isEmpty {
                                Divider()
                                Button("Clear Mappings", role: .destructive) {
                                    cache.audioReactive.musicReactiveMappings = []
                                    cache.push(\.musicReactiveMappings, value: [])
                                }
                            }
                        } label: {
                            Label("Shortcuts", systemImage: "sparkles")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("\(activeMusicPermutationCount) active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(cache.audioReactive.musicReactiveMappings.enumerated()), id: \.element.id) { index, mapping in
                                VStack(spacing: 4) {
                                    HStack(spacing: 8) {
                                        Image(systemName: mapping.target.icon(for: cache.fractalType))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Text(mapping.target.displayName(for: cache.fractalType))
                                            .font(.caption.bold())

                                        if mapping.hasFlashingRisk {
                                            FlashingLightIndicator()
                                                .help("Can produce flashing or rapidly changing light.")
                                        }

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
                                        sliderRow(label: "Hybrid", value: Binding(
                                            get: { mappingAt(index)?.hybridCombo ?? 0.35 },
                                            set: { newValue in updateMapping(index) { $0.hybridCombo = newValue; $0.sanitizeInPlace() } }
                                        ), range: 0...1)
                                    }

                                    sliderRow(label: "Intensity", value: Binding(
                                        get: { mappingAt(index)?.amount ?? 1.0 },
                                        set: { newValue in updateMapping(index) { $0.amount = newValue; $0.sanitizeInPlace() } }
                                    ), range: 0...3)

                                    sliderRow(label: "Smooth", value: Binding(
                                        get: { mappingAt(index)?.smoothingWindow ?? 0.0 },
                                        set: { newValue in updateMapping(index) { $0.smoothingWindow = newValue; $0.sanitizeInPlace() } }
                                    ), range: 0...2)
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.22)))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .frame(minHeight: 260, maxHeight: .infinity, alignment: .top)
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.10)))
            } else {
                Text("Enable React to Music above to start visualization mappings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
            }
        }
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
        let mapping = target.defaultMapping(for: cache.fractalType, enabled: true)
        mappings.append(mapping)
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

    private func sliderRow(label: String, value: Binding<Float>, range: ClosedRange<Float>, showsFlashingWarning: Bool = false) -> some View {
        HStack {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                if showsFlashingWarning {
                    FlashingLightIndicator()
                        .help("Can produce flashing or rapidly changing light.")
                }
            }
            .frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
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
            #if os(macOS)
            MusicTabContent(
                cache: cache,
                musicService: musicService,
                audioAnalyzer: AudioAnalyzer(),
                renderSettings: RenderSettings(),
                musicAppCapture: MusicAppAudioCapture(analyzer: AudioAnalyzer())
            )
            #else
            MusicTabContent(
                cache: cache,
                musicService: musicService,
                audioAnalyzer: AudioAnalyzer(),
                renderSettings: RenderSettings()
            )
            #endif
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
