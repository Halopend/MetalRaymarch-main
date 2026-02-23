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

// MARK: - Music Tab Content

struct MusicTabContent: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var cache: UISettingsCache
    @State private var musicSubTab: MusicSubTab = .nowPlaying
    
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
    
    // MARK: - Now Playing
    
    private var nowPlayingContent: some View {
        VStack(spacing: 16) {
            // Connection status
            spotifyConnectionSection
            
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
                        case .spotifyOnly:
                            appModel.audioAnalyzer.stopCapture()
                            if appModel.spotifyManager.isConnected {
                                appModel.spotifyManager.startPolling()
                            }
                        case .both:
                            appModel.audioAnalyzer.startCapture()
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Real-Time Levels")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    levelMeter(label: "Bass", level: appModel.audioAnalyzer.bassLevel, color: .red)
                    levelMeter(label: "Mid", level: appModel.audioAnalyzer.midLevel, color: .green)
                    levelMeter(label: "Treble", level: appModel.audioAnalyzer.trebleLevel, color: .blue)
                    levelMeter(label: "Beat", level: appModel.spotifyManager.beatSync.beatIntensity, color: .purple)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
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
