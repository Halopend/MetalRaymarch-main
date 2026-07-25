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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.menuAdjustmentActions) private var menuAdjustmentActions
    @Bindable var cache: ControlStateStore

    private let musicService: MusicService
    private let audioHub: AudioHub
    private let renderSettings: RenderSettings

    @State private var viewModel: MusicTabViewModel
    var tabSelection: Binding<MusicRailSection>? = nil
    @State private var localTabSelection: MusicRailSection = .playback
    @AppStorage(TransformationExperienceMode.defaultsKey)
    private var transformationExperienceModeRaw = TransformationExperienceMode.justUse.rawValue
    @AppStorage(TransformationUnlockProgress.defaultsKey)
    private var mappedLessonIDsRaw = ""
    @AppStorage(TransformationUnlockProgress.legacyDefaultsKey)
    private var legacyMappedTransformationIDsRaw = ""
    @State private var isShowingVisualizationAddPopover = false
    @State private var isHoldingVisualizationAddAdjustment = false

    private var transformationExperienceMode: TransformationExperienceMode {
        TransformationExperienceMode.decode(transformationExperienceModeRaw)
    }

    private var mappedTransformationIDs: Set<Int32> {
        TransformationUnlockProgress.runtimeKindIDs(
            from: TransformationUnlockProgress.decode(
                mappedLessonIDsRaw,
                legacyEncoded: legacyMappedTransformationIDsRaw
            )
        )
    }

    private var effectiveTabSelection: Binding<MusicRailSection> {
        Binding(
            get: { normalizedMusicSection(tabSelection?.wrappedValue ?? localTabSelection) },
            set: { newValue in
                let normalized = normalizedMusicSection(newValue)
                localTabSelection = normalized
                tabSelection?.wrappedValue = normalized
            }
        )
    }

    private func normalizedMusicSection(_ tab: MusicRailSection) -> MusicRailSection {
        let canonical = tab.canonical
        #if os(macOS)
        switch canonical {
        case .songs, .playlists, .albums:
            return .playback
        case .playback, .reactive, .mappings, .presets:
            return canonical
        }
        #else
        return canonical
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

    init(
        cache: ControlStateStore,
        musicService: MusicService,
        audioHub: AudioHub,
        renderSettings: RenderSettings,
        tabSelection: Binding<MusicRailSection>? = nil
    ) {
        self.cache = cache
        self.musicService = musicService
        self.audioHub = audioHub
        self.renderSettings = renderSettings
        self.tabSelection = tabSelection
        _viewModel = State(initialValue: MusicTabViewModel(musicService: musicService))
    }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                switch effectiveTabSelection.wrappedValue {
                case .playback:
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

                case .reactive, .mappings, .presets:
                    inputReactivePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: isShowingVisualizationAddPopover) { _, isPresented in
            updateVisualizationAddPopoverAdjustment(isPresented: isPresented)
            // Expand/collapse state now lives inside VisualizationAddPopover, so it
            // resets to compact automatically each time the popover is re-presented.
        }
        #if os(macOS)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { @MainActor in
                    await audioHub.stopTransientSources()
                }
            }
        }
        #endif
        .onDisappear {
            updateVisualizationAddPopoverAdjustment(isPresented: false)
        }
    }

    private var inputReactivePage: some View {
        VStack(spacing: 10) {
            visualizationHeaderSection

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    reactivitySection
                    presetsSection
                    #if !os(macOS)
                    // Source owns the live signal monitor on Mac. Other
                    // platforms do not expose that capture dashboard, so keep
                    // the meters here for them.
                    levelMeters
                    #endif
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                levelMeters
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var macAudioInputHero: some View {
        let microphone = descriptor(for: .microphone)
        let microphoneIsStarting = audioHub.isStarting(.microphone)
        let microphoneCanStart = audioHub.canStart(.microphone)
        let isLive = audioHub.sourceDescriptors.contains { $0.kind == .capture && $0.isActive }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Input Visualizer")
                        .font(.headline)
                    Text("Use the Mac microphone or a policy-approved application source for reactive visuals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                // Freshness-aware status: a capture source can claim to be live
                // while its route has stalled (device unplugged, stream dead).
                // The snapshot goes inactive within 0.35 s of samples stopping,
                // so "Live but inactive snapshot" means no signal is arriving.
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let hasFreshSignal = audioHub.latestSnapshot().isActive
                    Label(isLive ? (hasFreshSignal ? "Live" : "No Signal") : "Ready",
                          systemImage: isLive ? AppIcons.waveformCircleFill : AppIcons.circleDashed)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isLive ? (hasFreshSignal ? AnyShapeStyle(.green) : AnyShapeStyle(.orange)) : AnyShapeStyle(.secondary))
                }
            }

            HStack(spacing: 8) {
                Button(microphone?.isActive == true ? "Stop Input" : (microphoneIsStarting ? "Starting…" : "Start Input")) {
                    toggleAudioSource(.microphone, preset: .electronic)
                }
                .buttonStyle(.borderedProminent)
                .disabled(microphone?.isActive != true && !microphoneCanStart)

                Button("Reactivity") {
                    effectiveTabSelection.wrappedValue = .reactive
                }
                .buttonStyle(.bordered)
            }

            if let microphone, case .failed(let message) = microphone.availability {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let microphone, case .unavailable(let message) = microphone.availability {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") {
                        audioHub.openSettings(for: .microphone)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()

            if let systemOutput = descriptor(for: .systemOutput) {
                audioCaptureSourceRow(systemOutput)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
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
            isShowingVisualizationAddPopover.toggle()
        } label: {
            Label("Add Control", systemImage: AppIcons.plusCircleFill)
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
        .popover(isPresented: $isShowingVisualizationAddPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            // The popover owns its expand/collapse state internally (see
            // VisualizationAddPopover). Critically, toggling a category must NOT
            // mutate state on *this* view — doing so re-renders the anchor button
            // and macOS dismisses the popover mid-interaction (the bug this fixes).
            VisualizationAddPopover(
                available: availableMappingTargetsToAdd,
                fractalType: cache.fractalType,
                onPick: { target in
                    addMapping(target)
                    isShowingVisualizationAddPopover = false
                },
                onClose: { isShowingVisualizationAddPopover = false }
            )
            .interactiveDismissDisabled()
        }
    }


    private var visualizationHeaderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio Reactivity")
                .font(.subheadline.bold())
            Text("Enable response, tune the mix, and map audio to scene controls")
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
                Text("Enable React to Audio to add parameter mappings.")
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

    // MARK: - Saved Reactivity Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Saved Reactivity Presets", systemImage: AppIcons.squareStack3dUp)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(viewModel.musicPresets.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Save row: name field + save button
            HStack(spacing: 8) {
                TextField("Preset name", text: $viewModel.musicPresetName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { viewModel.saveMusicPreset(using: cache) }

                Button {
                    viewModel.saveMusicPreset(using: cache)
                } label: {
                    Label("Save", systemImage: AppIcons.plusCircleFill)
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.musicPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if viewModel.musicPresets.isEmpty {
                Text("Save the current amount, drop, damping, sensitivities, and parameter mappings as a reusable preset.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.musicPresets) { preset in
                        presetRow(preset)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.10)))
    }

    private func presetRow(_ preset: MusicReactivePreset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: AppIcons.waveform)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text("\(preset.mappings.count) mapping\(preset.mappings.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Load") {
                viewModel.loadMusicPreset(preset, into: cache)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                viewModel.deleteMusicPreset(preset.id)
            } label: {
                Image(systemName: AppIcons.trash)
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
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

            sliderRow(label: "Drop", value: Binding(
                get: { cache.audioReactive.fractalBeatPunch },
                set: { v in cache.audioReactive.fractalBeatPunch = v; cache.push(\.fractalBeatPunch, value: v) }
            ), range: 0...1)

            sliderRow(label: "Damping", value: Binding(
                get: { cache.audioReactive.fractalAudioDamping },
                set: { v in cache.audioReactive.fractalAudioDamping = v; cache.push(\.fractalAudioDamping, value: v) }
            ), range: 0...3)
        }
        .padding(12)
        .frame(minHeight: 148, alignment: .topLeading)
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
                        Image(systemName: cache.audioReactive.fractalAudioReactiveEnabled ? AppIcons.waveformCircleFill : AppIcons.waveformCircle)
                            .font(.caption)
                        Text("\(activeMusicPermutationCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(cache.audioReactive.fractalAudioReactiveEnabled ? .blue : .secondary)
                }

                Spacer(minLength: 0)

                Toggle("React to Audio", isOn: reactToMusicBinding)
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
                        Image(systemName: AppIcons.backwardFill).font(.title3)
                    }
                    .buttonStyle(.plain)

                    Button { viewModel.togglePlayPause() } label: {
                        Image(systemName: music.isPlaying ? AppIcons.pauseCircleFill : AppIcons.playCircleFill)
                            .font(.system(size: IconSize.hero))
                    }
                    .buttonStyle(.plain)
                    .tint(music.accentColor)

                    Button { viewModel.nextTrack() } label: {
                        Image(systemName: AppIcons.forwardFill).font(.title3)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                if viewModel.hasConnectedProvider {
                    #if os(macOS)
                    Button {
                        openWindow(id: AppModel.libraryWindowID)
                    } label: {
                        HStack {
                            Label("Change Song", systemImage: AppIcons.musicNoteList)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: AppIcons.arrowUpRightSquare)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    #else
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Browse & Controls")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            musicQuickActionButton(title: "Songs", systemImage: AppIcons.musicNote, tab: .songs)
                            musicQuickActionButton(title: "Playlists", systemImage: AppIcons.musicNoteList, tab: .playlists)
                            musicQuickActionButton(title: "Albums", systemImage: AppIcons.squareStack, tab: .albums)
                            musicQuickActionButton(title: "Reactivity", systemImage: AppIcons.waveformPathEcg, tab: .reactive)
                        }
                    }
                    #endif
                }
            } else {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: AppIcons.musicNote)
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

    #if !os(macOS)
    private func musicQuickActionButton(title: String, systemImage: String, tab: MusicRailSection) -> some View {
        Button {
            effectiveTabSelection.wrappedValue = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    #endif

    private func artPlaceholder(for source: SongSource) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay(
                Image(systemName: source == .appleMusic ? AppIcons.appleLogo : AppIcons.musicNote)
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
                        Label(cache.display.showMusicShortcuts ? "Hide Parameter Shortcuts" : "Show Parameter Shortcuts", systemImage: cache.display.showMusicShortcuts ? AppIcons.checkmarkCircleFill : AppIcons.circle)
                    }
                } label: {
                    Label("Settings", systemImage: AppIcons.gearshape)
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

            ForEach(audioHub.sourceDescriptors.filter { $0.kind == .capture }) { source in
                audioCaptureSourceRow(source)
                if source.id != audioHub.sourceDescriptors.last(where: { $0.kind == .capture })?.id {
                    Divider()
                }
            }

            let mediaContexts = audioHub.sourceDescriptors.filter { $0.kind == .mediaContext }
            if !mediaContexts.isEmpty {
                Divider()
                Text("Media Context")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(mediaContexts) { context in
                    mediaContextRow(context)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
    }

    /// One data-driven row for any real capture adapter. Adding a USB, file, or
    /// shared-content source now means registering a descriptor with AudioHub;
    /// the music tab does not gain another platform-specific branch.
    private func audioCaptureSourceRow(_ source: AudioSourceDescriptor) -> some View {
        let isStarting = audioHub.isStarting(source.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: source.systemImage)
                    .font(.caption)
                    .foregroundStyle(source.isActive ? .green : .secondary)
                Text(source.displayName)
                    .font(.subheadline)
                Spacer()
                Button(source.isActive ? "Stop" : (isStarting ? "Starting…" : "Start")) {
                    toggleAudioSource(source.id, preset: .electronic)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!source.isActive && !audioHub.canStart(source.id))
            }

            if let message = source.availability.detail {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if source.availability.isUnavailable && audioHub.canOpenSettings(for: source.id) {
                    Button("Open Settings") {
                        audioHub.openSettings(for: source.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if source.id == .systemOutput {
                Text(source.isActive
                     ? "Capturing a policy-approved application's audio."
                     : "Uses ScreenCaptureKit with a policy-approved application allowlist.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Uses microphone permission. Select a system or virtual audio input in device settings when needed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await audioHub.refreshAvailability()
        }
    }

    private func descriptor(for sourceID: AudioSourceID) -> AudioSourceDescriptor? {
        audioHub.sourceDescriptors.first { $0.id == sourceID }
    }

    private func mediaContextRow(_ context: AudioSourceDescriptor) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: context.systemImage)
                .font(.caption)
                .foregroundStyle(context.availability.isPolicyBlocked ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.displayName)
                    .font(.subheadline)
                Text(context.availability.detail ?? "Transport and now-playing context; not a raw audio capture source.")
                    .font(.caption2)
                    .foregroundStyle(context.availability.detail == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(context.provenance == .metadataSynthetic ? "Metadata" : "Context")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func toggleAudioSource(_ sourceID: AudioSourceID, preset: ReactivityPreset) {
        Task { @MainActor in
            if descriptor(for: sourceID)?.isActive == true {
                await audioHub.stop(sourceID)
            } else if await audioHub.start(sourceID) {
                configureMusicAppVisualizer(using: preset)
            }
        }
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
                            Image(systemName: AppIcons.chevronUp)
                                .font(.caption2)
                        }
                        .disabled(idx == 0)
                        .buttonStyle(.plain)
                        .foregroundStyle(idx == 0 ? .quaternary : .secondary)
                        Button {
                            music.moveServiceDown(serviceID)
                        } label: {
                            Image(systemName: AppIcons.chevronDown)
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
            systemImage: AppIcons.musicNote,
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
            systemImage: AppIcons.musicNoteList,
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
            systemImage: AppIcons.squareStack,
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
                    Image(systemName: AppIcons.arrowClockwise)
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
                        Image(systemName: AppIcons.musicNote).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: AppIcons.musicNote).font(.caption2).foregroundStyle(.secondary)
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
                        Image(systemName: AppIcons.musicNoteList).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: AppIcons.musicNoteList).font(.caption2).foregroundStyle(.secondary)
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
                        Image(systemName: AppIcons.squareStack).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: AppIcons.squareStack).font(.caption2).foregroundStyle(.secondary)
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
                            Section("Built-In Presets") {
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
                            Label("Presets", systemImage: AppIcons.sparkles)
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("\(activeMusicPermutationCount) active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Flowed directly into the outer ScrollView (line ~161) — no nested
                    // same-axis scroll. LazyVStack, NOT VStack: users can add many mappings,
                    // and a plain VStack hosts every card's segmented Pickers synchronously
                    // when the tab opens, which HANGS on a long list. Lazy hosts only visible
                    // cards. (Remaining scroll cost is re-hosting the AppKit segmented Pickers
                    // as cards scroll in; the real fix is lighter pure-SwiftUI segments.)
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
                                }

                                if canEditMappingTarget(mapping.target) {
                                    // Transform slots can drive any field of the op, not
                                    // just its strength — pick from the fields the live
                                    // transform at this slot actually has.
                                    if mapping.target.isSpaceWarp,
                                       let slot = mapping.target.spaceWarpSlot,
                                       let stack = cache.renderSettings?.spaceWarpStack,
                                       slot < stack.count {
                                        let kind = stack[slot].kind
                                        let fields = kind.musicFields
                                        if fields.count > 1 {
                                            Picker("Drives", selection: Binding(
                                                get: { mappingAt(index)?.spaceWarpField ?? .strength },
                                                set: { newValue in updateMapping(index) { $0.spaceWarpField = newValue } }
                                            )) {
                                                ForEach(fields, id: \.self) { f in
                                                    Text(kind.musicFieldLabel(f)).tag(f)
                                                }
                                            }
                                            .pickerStyle(.menu)
                                            .font(.caption)
                                        }
                                    }

                                    Picker("Source", selection: Binding(
                                        get: { mappingAt(index)?.source ?? .composite },
                                        set: { newValue in updateMapping(index) { $0.source = newValue } }
                                    )) {
                                        ForEach(MusicReactiveSource.pickerCases, id: \.self) { source in
                                            Text(source.displayName).tag(source)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    Picker("Curve", selection: Binding(
                                        get: { mappingAt(index)?.responseCurve ?? .drift },
                                        set: { newValue in updateMapping(index) { $0.responseCurve = newValue } }
                                    )) {
                                        ForEach(ResponseCurve.pickerCases, id: \.self) { curve in
                                            Label(curve.displayName, systemImage: curve.icon).tag(curve)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    if (mappingAt(index)?.responseCurve ?? .drift) == .hybrid {
                                        sliderRow(label: "Living", value: Binding(
                                            get: { mappingAt(index)?.hybridCombo ?? 0.35 },
                                            set: { newValue in updateMapping(index) { $0.hybridCombo = newValue; $0.sanitizeInPlace() } }
                                        ), range: 0...1)
                                    }

                                    sliderRow(label: "Intensity", value: Binding(
                                        get: { mappingAt(index)?.amount ?? 1.0 },
                                        set: { newValue in updateMapping(index) { $0.amount = newValue; $0.sanitizeInPlace() } }
                                    ), range: 0...3)

                                    sliderRow(label: "Input Scale", value: Binding(
                                        get: { mappingAt(index)?.inputScale ?? 1.0 },
                                        set: { newValue in
                                            updateMapping(index) { $0.inputScale = newValue; $0.sanitizeInPlace() }
                                        }
                                    ), range: 0...3)

                                    sliderRow(label: "Input Offset", value: Binding(
                                        get: { mappingAt(index)?.inputOffset ?? 0.0 },
                                        set: { newValue in
                                            updateMapping(index) { $0.inputOffset = newValue; $0.sanitizeInPlace() }
                                        }
                                    ), range: -1...1)

                                    sliderRow(label: "Smooth", value: Binding(
                                        get: { mappingAt(index)?.smoothingWindow ?? 0.0 },
                                        set: { newValue in updateMapping(index) { $0.smoothingWindow = newValue; $0.sanitizeInPlace() } }
                                    ), range: 0...2)
                                } else {
                                    Label("Map this transformation to unlock its audio mapping",
                                          systemImage: "lock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                // Remove control: comfortably sized and bottom-leading so it's
                                // an easy tap target and stays clear of the right-edge scrollbar.
                                HStack(spacing: 8) {
                                    Button(role: .destructive) {
                                        removeMapping(at: index)
                                    } label: {
                                        Label("Remove", systemImage: AppIcons.trash)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.red)

                                    Spacer()
                                }
                                .padding(.top, 4)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.22)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.10)))
            } else {
                Text("Enable React to Audio above to start parameter mappings.")
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
        cache.audioReactive.fractalAudioDamping = s.audioDamping
        cache.audioReactive.bassSensitivity = s.bassSensitivity
        cache.audioReactive.midSensitivity = s.midSensitivity
        cache.audioReactive.trebleSensitivity = s.trebleSensitivity
        cache.audioReactive.beatSensitivity = s.beatSensitivity
        cache.push(\.fractalAudioAmount, value: s.audioAmount)
        cache.push(\.fractalBeatPunch, value: s.beatPunch)
        cache.push(\.fractalAudioDamping, value: s.audioDamping)
        cache.push(\.bassSensitivity, value: s.bassSensitivity)
        cache.push(\.midSensitivity, value: s.midSensitivity)
        cache.push(\.trebleSensitivity, value: s.trebleSensitivity)
        cache.push(\.beatSensitivity, value: s.beatSensitivity)
        
        let mappings = preset.defaultMappings(for: cache.fractalType).filter {
            canEditMappingTarget($0.target)
        }
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private var availableMappingTargetsToAdd: [MusicReactiveTarget] {
        let existing = Set(cache.audioReactive.musicReactiveMappings.map(\.target))
        // One transform-stack slot per active op (slot N = transform card #N+1).
        let warpCount = cache.renderSettings?.spaceWarpStack.count ?? 0
        let all = MusicReactiveTarget.availableCases(for: cache.fractalType)
                + MusicReactiveTarget.availableSpaceWarpCases(count: warpCount)
        return all.filter {
            !existing.contains($0) && canEditMappingTarget($0)
        }
    }

    private func canEditMappingTarget(_ target: MusicReactiveTarget) -> Bool {
        guard let slot = target.spaceWarpSlot else { return true }
        guard let stack = cache.renderSettings?.spaceWarpStack,
              stack.indices.contains(slot) else { return false }
        return TransformationAccessPolicy.canInteract(
            withRawKindID: stack[slot].type,
            mode: transformationExperienceMode,
            mappedIDs: mappedTransformationIDs
        )
    }

    private func mappingAt(_ index: Int) -> MusicReactiveMapping? {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return nil }
        return cache.audioReactive.musicReactiveMappings[index]
    }

    private func updateMapping(_ index: Int, mutate: (inout MusicReactiveMapping) -> Void) {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return }
        var mappings = cache.audioReactive.musicReactiveMappings
        guard canEditMappingTarget(mappings[index].target) else { return }
        mutate(&mappings[index])
        mappings[index].sanitizeInPlace()
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func addMapping(_ target: MusicReactiveTarget) {
        var mappings = cache.audioReactive.musicReactiveMappings
        guard canEditMappingTarget(target),
              !mappings.contains(where: { $0.target == target }) else { return }
        var mapping = target.defaultMapping(for: cache.fractalType, enabled: true)
        // Newly added controls default to Follow (the calm, drift response).
        mapping.responseCurve = .drift
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
        // 20 Hz rather than display-rate (~90 Hz): audio level bars read perfectly
        // smooth at 20 Hz, and a full-rate redraw of these meters while the window is
        // open spends GPU/CPU that the immersive raymarch needs on this device.
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            // Read the hub snapshot directly rather than renderSettings: the
            // snapshot stays live (hub fallback timer) even when rendering is
            // paused or the visuals aren't in an audio-reactive mode. Apply
            // the same sensitivity scaling the renderer applies, so the
            // meters show the signal that actually drives the visuals.
            let mixed = audioHub.latestSnapshot().mixed
            let reactive = cache.audioReactive
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio Levels")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    meterBar(label: "Bass",
                             level: min(1, max(0, mixed.bass * reactive.bassSensitivity)),
                             color: .red)
                    meterBar(label: "Mid",
                             level: min(1, max(0, mixed.mid * reactive.midSensitivity)),
                             color: .green)
                    meterBar(label: "Treble",
                             level: min(1, max(0, mixed.treble * reactive.trebleSensitivity)),
                             color: .blue)
                    meterBar(label: "Drop",
                             level: min(1, max(0, mixed.onset * reactive.beatSensitivity)),
                             color: .purple)
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
    @State private var cache = ControlStateStore()

    let musicService: MusicService
    let audioHub: AudioHub
    let title: String

    init(musicService: MusicService, title: String) {
        self.musicService = musicService
        self.audioHub = AudioHub(microphoneAnalyzer: AudioAnalyzer(),
                                 appleMusicManager: musicService.appleMusic)
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            MusicTabContent(
                cache: cache,
                musicService: musicService,
                audioHub: audioHub,
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

/// Body of the "Add Music Control" popover.
///
/// Extracted into its own view so that expanding/collapsing a category mutates
/// *this* view's local `@State`, not the presenting `MusicTabView`. That matters
/// on macOS: when the disclosure state lived on the parent, every tap re-rendered
/// the popover's anchor button and AppKit dismissed the popover before the user
/// could pick a parameter. Owning the state here keeps the anchor stable, so the
/// popover stays open while the user browses. It also resets to all-collapsed
/// automatically on each present (fresh `@State` per instance).
private struct VisualizationAddPopover: View {
    let available: [MusicReactiveTarget]
    let fractalType: FractalModelType
    let onPick: (MusicReactiveTarget) -> Void
    let onClose: () -> Void

    @State private var expandedSections: Set<String> = []

    var body: some View {
        let formulaTargets = available.filter { $0.isFormulaParam }
        let universalTargets = available.filter { !$0.isFormulaParam }

        return AutoExpandingPopover(idealWidth: 300, maxHeight: 460, reservesMaxHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Add Music Control")
                        .font(.title3.bold())
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: AppIcons.xmarkCircleFill)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if available.isEmpty {
                    Text("All targets added")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pick a category, then a parameter to map.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    // Plain VStack (no inner ScrollView): AutoExpandingPopover grows
                    // the whole popover as categories expand, so revealed rows become
                    // fully visible, and only caps + scrolls past maxHeight.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(MusicReactiveTargetCategory.universalOrder, id: \.self) { category in
                            let targets = universalTargets.filter { $0.category == category }
                            if !targets.isEmpty {
                                disclosure(title: category.rawValue, systemImage: category.icon, targets: targets)
                            }
                        }

                        if !formulaTargets.isEmpty {
                            disclosure(title: "\(fractalType.displayName) Params",
                                       systemImage: AppIcons.function,
                                       targets: formulaTargets)
                        }
                    }
                }
            }
        }
    }

    /// One collapsible category. Custom disclosure (not `DisclosureGroup`) so the
    /// entire header row — label, count, chevron — toggles expansion.
    @ViewBuilder
    private func disclosure(title: String, systemImage: String, targets: [MusicReactiveTarget]) -> some View {
        let isExpanded = expandedSections.contains(title)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded { expandedSections.remove(title) } else { expandedSections.insert(title) }
                }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(targets.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Image(systemName: AppIcons.chevronRight)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())   // whole row is the tap target
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(targets, id: \.self) { target in
                        Button { onPick(target) } label: {
                            HStack(spacing: 8) {
                                Label(target.displayName(for: fractalType),
                                      systemImage: target.icon(for: fractalType))
                                    .font(.callout)
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
                .padding(.top, 2)
            }
        }
    }
}
