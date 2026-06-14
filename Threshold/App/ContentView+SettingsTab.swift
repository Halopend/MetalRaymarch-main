//
//  ContentView+SettingsTab.swift
//  Threshold
//
//  Settings tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties remain on the main `ContentView` struct; only computed
//  views and helper methods live here.
//

import SwiftUI

/// Identifiable wrapper so the export share sheet is presented via
/// `sheet(item:)` — guarantees the URL exists when the sheet body builds.
struct ExportShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Settings Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Settings tab — split into five inner sub-tabs (Display, Gestures,
    /// Sharing, Export, Advanced) for faster navigation. Driven by
    /// `@AppStorage("ContentView.settingsSubTab") settingsSubTab` on
    /// `ContentView` so the user's last selection persists across launches.
    var settingsTabContent: some View {
        VStack(spacing: 0) {
            // Segmented tab picker. Wrapped in a top bar with a small
            // "Show Welcome Again" affordance on the trailing edge so users
            // can replay the onboarding from settings.
            HStack(spacing: 12) {
                Picker("Settings section", selection: $settingsSubTab) {
                    ForEach(SettingsSubTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Choose a settings section")

                Button {
                    openWindow(id: AppModel.onboardingWindowID)
                } label: {
                    Label("Show Welcome", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Replay the welcome and onboarding")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    switch settingsSubTab {
                    case .display:   settingsDisplayContent
                    case .gestures:  settingsGesturesContent
                    case .sharing:   settingsSharingContent
                    case .export:    settingsExportContent
                    case .advanced:  settingsAdvancedContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Display sub-view

    /// Display-focused settings: Platform (visionOS), handedness, lighting,
    /// HUD toggles, and resolution. Extracted from the old "General" tab
    /// so the user has one place to find visual / display-related knobs.
    private var settingsDisplayContent: some View {
        VStack(spacing: 12) {
            // Platform — only relevant on visionOS. On iOS/macOS the
            // immersive floor field is never rendered, so the section is
            // hidden entirely.
#if os(visionOS)
            platformSection
#endif

            // Handedness lives in display, not gestures: it affects which
            // hand the renderer treats as the dominant one and the user
            // expects to find it next to other "how I look at the scene"
            // controls.
            handednessSection

            // Touch indicators — only meaningful where fingers touch the
            // render view directly.
#if os(iOS)
            touchIndicatorsSection
#endif

            // Experimental display features (kept here, not in Advanced,
            // because they're visual toggles the user can flip while the
            // scene is running).
            experimentalDisplaySection
        }
    }

    /// VisionOS-only glass-floor platform settings. Mirrors the
    /// `ContentView+FractalTab` block but is the canonical home for these
    /// controls now that Settings has a Display sub-tab.
#if os(visionOS)
    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Platform", systemImage: "circle.hexagongrid.fill")
                    .font(.headline)
                Spacer()
                if cache.display.platformEnabled {
                    Text(String(format: "%.1f m", cache.display.platformRadius))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Show Platform", isOn: Binding(
                    get: { cache.display.platformEnabled },
                    set: { cache.display.platformEnabled = $0 }
                ))
                .labelsHidden()
                .tint(.cyan)
            }

            Text("Renders a glass floor in the immersive space. The fractal color blends through it so the platform reads as a thick transparent surface. Disable for a clean floor-less view.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if cache.display.platformEnabled {
                EffectSliderRow(icon: "circle.dotted", label: "Radius",
                    value: Binding(
                        get: { cache.display.platformRadius },
                        set: { cache.display.platformRadius = $0 }
                    ), range: 0.5...3.0,
                    enabled: .constant(true),
                    onChanged: { cache.commitPlatformRadius() },
                    showToggle: false)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.07)))
    }
#endif

    /// iOS-only toggle for the fingertip glow indicators drawn over the
    /// render view (cyan = orbit, violet = pan/zoom).
#if os(iOS)
    private var touchIndicatorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $showTouchIndicators) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Touch Indicators", systemImage: "hand.tap.fill")
                        .font(.headline)
                    Text("Shows a glowing dot under each finger on the fractal view, tinted by gesture: cyan while orbiting, violet while panning or zooming.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.cyan)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.07)))
    }
#endif

    /// Hand-dominance picker. Affects which hand the renderer treats as
    /// the dominant one for asymmetric controls (e.g. the "menu" hand).
    private var handednessSection: some View {
        let handedBinding = Binding<Bool>(
            get: { appModel.renderSettings.leftHandedMode },
            set: { appModel.renderSettings.leftHandedMode = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Label("Handedness", systemImage: "hand.point.up.left.fill")
                .font(.headline)
            Picker("Dominant hand", selection: handedBinding) {
                Label("Right", systemImage: "hand.raised.fingers.spread.fill").tag(false)
                Label("Left",  systemImage: "hand.raised.fingers.spread").tag(true)
            }
            .pickerStyle(.segmented)
            Text("Choose your dominant hand. Some per-finger tap defaults are mirrored automatically.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.07)))
    }

    /// Display-flavored experimental toggles. The custom-shenes enable is
    /// a display-runtime knob (it gates whether the renderer tries to
    /// compile user-supplied shaders), so it lives here.
    private var experimentalDisplaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Experimental Display", systemImage: "flask.fill")
                    .font(.headline)
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .foregroundStyle(.orange)
                Spacer()
            }

            Toggle(isOn: $allowCustomScenes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow custom scenes")
                        .font(.subheadline.weight(.semibold))
                    Text("Enables loading .threshfx files and custom shader formulas. Default parameters may not be ideal and some scenes may not render correctly yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.orange)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
    }

    // MARK: - Gestures sub-view

    /// Gestures sub-view. Hands off to the dedicated gestures tab for
    /// the full per-finger / per-hand editor; this surface only shows a
    /// pointer to where the user can find it. A future iteration can
    /// inline the most-used controls here.
    private var settingsGesturesContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Gesture editor lives in its own tab", systemImage: "hand.draw.fill")
                    .font(.headline)
                Text("Per-hand, per-finger, and gesture-sensitivity controls are grouped in the dedicated Gestures tab. Use the tab bar to jump there directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    selectedTab = .gestures
                } label: {
                    Label("Open Gestures Tab", systemImage: "hand.draw")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.07)))
        }
    }

    // MARK: - Sharing sub-view

    /// Sharing sub-view: Community Sharing (analytics + username) and
    /// iCloud Drive backup. Sharing is **on by default** — the user must
    /// opt out by turning the toggle off. The username is independent
    /// and is always shown so the user can set an attribution handle
    /// without enabling sharing.
    private var settingsSharingContent: some View {
        VStack(spacing: 12) {
            communitySharingSection
            iCloudDriveSection
        }
    }

    private var communitySharingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Community Sharing", systemImage: "person.3.fill")
                    .font(.headline)
                Spacer()
                Image(systemName: UsageAnalytics.shared.analyticsEnabled
                      ? "checkmark.circle.fill"
                      : "minus.circle")
                    .foregroundStyle(UsageAnalytics.shared.analyticsEnabled ? .green : .secondary)
                    .help(UsageAnalytics.shared.analyticsEnabled
                          ? "Sharing is on"
                          : "Sharing is off")
            }

            // Flipped copy: "on by default" is the headline.
            Text("On by default. Disable below to opt out. No account is created and no Apple ID, email, or location is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { UsageAnalytics.shared.analyticsEnabled },
                set: { UsageAnalytics.shared.analyticsEnabled = $0 }
            )) {
                Label(
                    UsageAnalytics.shared.analyticsEnabled ? "Sharing with the community" : "Sharing is off",
                    systemImage: UsageAnalytics.shared.analyticsEnabled ? "person.3.fill" : "person.slash"
                )
            }
            .tint(.blue)

            VStack(alignment: .leading, spacing: 6) {
                Text("Display Name (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Leave blank to share anonymously", text: Binding(
                    get: { UsageAnalytics.shared.communityDisplayName },
                    set: { UsageAnalytics.shared.communityDisplayName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                Text("Used only for community credits. Stays on this device — never leaves your Mac. Leave blank to share anonymously.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("What you're opting into:", systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("• Your settings can be reviewed for future community features\n• Shared setups may appear later in original or altered form\n• If you add a user name, it can be used for attribution\n• Aggregated usage stats help us improve performance and features")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07)))
    }

    // (Old `settingsGeneralContent` removed — the settings tab now
    // dispatches to `settingsDisplayContent` / `settingsGesturesContent`
    // / `settingsSharingContent` / `settingsExportContent` /
    // `settingsAdvancedContent` based on the segmented sub-tab picker.)

    // ─────────────────────────────────────────────────────────────────
    // MARK: iCloud Drive
    // ─────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var iCloudDriveSection: some View {
        let cloud = appModel.iCloudBackup
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("iCloud Drive", systemImage: "icloud").font(.headline)
                Spacer()
                if cloud.isBusy { ProgressView().controlSize(.small) }
            }

            if cloud.isAvailable {
                Text("Sync your scenes, animations, and settings to iCloud Drive. Files are stored in a public **Threshold** folder visible in the Files app and on your Mac in Finder under iCloud Drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Sync to iCloud Drive", isOn: Binding(
                    get: { appModel.iCloudBackup.isSyncEnabled },
                    set: { newValue in
                        appModel.iCloudBackup.isSyncEnabled = newValue
                        if newValue {
                            // Push current state immediately on enable.
                            appModel.iCloudBackup.syncToCloud(
                                settings: appModel.renderSettings,
                                presetManager: appModel.presetManager,
                                animationManager: appModel.animationManager
                            )
                        }
                    }
                ))
                .tint(.cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder structure:").font(.caption2).foregroundStyle(.tertiary)
                    Text("Threshold/Settings/   • settings.json").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text("Threshold/Scenes/     • <name>.threshscene").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text("Threshold/Animations/ • <name>.threshanim").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)

                HStack(spacing: 8) {
                    Button {
                        appModel.iCloudBackup.syncToCloud(
                            settings: appModel.renderSettings,
                            presetManager: appModel.presetManager,
                            animationManager: appModel.animationManager
                        )
                    } label: {
                        Label("Back Up Now", systemImage: "arrow.up.to.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(cloud.isBusy || !cloud.isSyncEnabled)

                    Button(role: .destructive) {
                        showICloudRestoreConfirm = true
                    } label: {
                        Label("Restore", systemImage: "arrow.down.to.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(cloud.isBusy || !cloud.isSyncEnabled)
                    .confirmationDialog(
                        "Restore from iCloud?",
                        isPresented: $showICloudRestoreConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Replace Local Scenes", role: .destructive) {
                            appModel.iCloudBackup.restoreFromCloud(
                                into: appModel.renderSettings,
                                presetManager: appModel.presetManager,
                                animationManager: appModel.animationManager
                            )
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This replaces your local scenes, animations, and settings with the copy in iCloud. Local-only scenes that aren't backed up will be overwritten. A safety backup of your current scenes is saved first.")
                    }
                }

                Button {
                    appModel.iCloudBackup.openInFilesApp()
                } label: {
                    Label("Open Threshold Folder in Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let date = cloud.lastSyncDate {
                    Text("Last sync: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let error = cloud.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("iCloud Drive isn't available. Sign in to iCloud and enable iCloud Drive in System Settings to back up your scenes and animations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    appModel.iCloudBackup.resolveContainer()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.06)))
    }
    
    private var themeColor: Color {
        // Derive theme color from the current gradient preset
        switch cache.color.gradientState.gradientPreset {
        case .classic:    return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .ocean:      return Color(red: 0.1, green: 0.5, blue: 0.9)
        case .fire:       return Color(red: 1.0, green: 0.4, blue: 0.1)
        case .forest:     return Color(red: 0.2, green: 0.7, blue: 0.3)
        case .nebula:     return Color(red: 0.6, green: 0.3, blue: 0.9)
        case .mono:       return Color(red: 0.5, green: 0.5, blue: 0.55)
        case .aurora:     return Color(red: 0.2, green: 0.9, blue: 0.6)
        case .volcanic:   return Color(red: 0.9, green: 0.3, blue: 0.1)
        case .neonCyber:  return Color(red: 1.0, green: 0.2, blue: 0.8)
        case .neonSunset: return Color(red: 1.0, green: 0.5, blue: 0.3)
        case .neonMatrix: return Color(red: 0.0, green: 1.0, blue: 0.4)
        case .rainbow:    return Color(red: 0.9, green: 0.4, blue: 0.5)
        case .infrared:   return Color(red: 0.8, green: 0.2, blue: 0.2)
        case .twilight:   return Color(red: 0.5, green: 0.3, blue: 0.7)
        case .none:       return Color(red: 0.6, green: 0.3, blue: 0.9)  // default nebula
        }
    }


    
    private var fpsColor: Color {
        // Use cache.liveFPS for the settings panel to avoid observation of RenderMetrics
        let fps = cache.liveFPS
        if fps >= 85 { return .green }; if fps >= 60 { return .yellow }; return .red
    }

    // MARK: - Export & Share Tab

    private var settingsExportContent: some View {
        VStack(spacing: 12) {
            // ── Current Preset Export ────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Current Preset", systemImage: "square.and.arrow.up")
                        .font(.headline)
                    Spacer()
                }
                Text("Export the current render settings as a shareable preset file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        let preset = FractalPreset.fromSettings(
                            appModel.renderSettings,
                            name: "Export",
                            embeddedFormula: appModel.activeEmbeddedFormula
                        )
                        exportOffMain({ PresetManager.exportPresetFile(preset) }) { url in
                            exportShareItem = ExportShareItem(url: url)
                        }
                    } label: {
                        Label("Export Preset (.threshscene)", systemImage: "doc.badge.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeColor)
                }

                let hasMusicMappings = !(appModel.renderSettings.musicReactiveMappings.isEmpty)
                if hasMusicMappings {
                    Button {
                        var preset = FractalPreset.fromSettings(
                            appModel.renderSettings,
                            name: "Music Export",
                            embeddedFormula: appModel.activeEmbeddedFormula
                        )
                        preset.musicReactiveMappings = appModel.renderSettings.musicReactiveMappings
                        let musicPreset = preset
                        exportOffMain({ PresetManager.exportPresetFile(musicPreset) }) { url in
                            exportShareItem = ExportShareItem(url: url)
                        }
                    } label: {
                        Label("Export Music Preset (.threshmp)", systemImage: "music.note.list")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(themeColor.opacity(0.06)))

            // ── Saved Presets Export ─────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Saved Presets", systemImage: "square.stack.3d.up")
                        .font(.headline)
                    Spacer()
                }
                Text("Export saved presets. Presets with audio mappings export as music presets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if appModel.presetManager.presets.isEmpty {
                    Text("No saved presets.")
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                        .padding(.vertical, 4)
                } else {
                    ForEach(appModel.presetManager.presets) { preset in
                        let hasMusic = !(preset.musicReactiveMappings?.isEmpty ?? true)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.subheadline.weight(.medium))
                                HStack(spacing: 6) {
                                    Text(hasMusic ? ".threshmp" : ".threshscene")
                                    if hasMusic {
                                        Label("Music", systemImage: "music.note")
                                    }
                                    if preset.embeddedFormula != nil {
                                        Label("Formula", systemImage: "function")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                exportOffMain({ PresetManager.exportPresetFile(preset) }) { url in
                                    exportShareItem = ExportShareItem(url: url)
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(themeColor.opacity(0.06)))

            // ── Custom Formula Export ────────────────────────────────────
            if let formula = appModel.activeEmbeddedFormula {
                VStack(spacing: 8) {
                    HStack {
                        Label("Custom Formula", systemImage: "function")
                            .font(.headline)
                        Spacer()
                    }
                    Text("Export the active custom formula as a standalone shader file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formula.name).font(.subheadline.weight(.medium))
                            if let author = formula.author, !author.isEmpty {
                                Text("by \(author)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            let container = EmbeddedFormulaContainer(formula: formula)
                            exportOffMain({ container.exportToFile() }) { url in
                                exportShareItem = ExportShareItem(url: url)
                            }
                        } label: {
                            Label("Export Formula (.threshfx)", systemImage: "doc.badge.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
            }

            // ── Animation Scene Export ───────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Animation Scenes", systemImage: "film.stack")
                        .font(.headline)
                    Spacer()
                }
                Text("Export animation scenes. Scenes with attached songs export as music videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let mgr = appModel.animationManager {
                    if mgr.scenes.isEmpty {
                        Text("No scenes available.")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(mgr.scenes) { scene in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scene.name).font(.subheadline.weight(.medium))
                                    HStack(spacing: 6) {
                                        Text("\(scene.keyframes.count) keyframes")
                                        if scene.attachedSong != nil {
                                            Label("Music", systemImage: "music.note")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    exportOffMain({ AnimationManager.exportSceneFile(scene) }) { url in
                                        exportShareItem = ExportShareItem(url: url)
                                    }
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    Text("Animation manager not available.")
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // ── File Format Reference ───────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("File Formats", systemImage: "doc.text")
                        .font(.headline)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    // Single source of truth shared with the export writers.
                    ForEach(ThresholdExportFormat.allCases, id: \.ext) { format in
                        formatRow(ext: ".\(format.ext)", desc: format.summary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        }
        .sheet(item: $exportShareItem) { item in
            VStack(spacing: 12) {
                Text(item.url.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                ShareLink(item: item.url) {
                    Label("Share File", systemImage: "square.and.arrow.up")
                }
            }
            .padding()
        }
    }

    private func formatRow(ext: String, desc: String) -> some View {
        HStack(spacing: 8) {
            Text(ext)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(themeColor)
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    
    private var settingsAdvancedContent: some View {
        @Bindable var appModel = appModel
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(themeColor); Text("Pipeline Profiler").font(.headline) }
                HStack {
                    Button {
                        isProfilerRunning = true; appModel.runProfiler()
                        Task { try? await Task.sleep(for: .seconds(3)); await MainActor.run { isProfilerRunning = false; lastProfileTime = Date() } }
                    } label: {
                        HStack {
                            if isProfilerRunning { ProgressView().scaleEffect(0.7).frame(width: 16, height: 16) } else { Image(systemName: "play.fill") }
                            Text(isProfilerRunning ? "Profiling..." : "Run Profiler")
                        }
                    }.buttonStyle(.borderedProminent).tint(themeColor).disabled(isProfilerRunning)
                }
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "chart.bar.fill").foregroundStyle(themeColor); Text("Live Stats").font(.headline) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatBox(label: "FPS", value: String(format: "%.0f", cache.liveFPS), color: fpsColor)
                    StatBox(label: "Iterations", value: "\(cache.liveFractalIterations)", color: themeColor)
                    StatBox(label: "Ray Steps", value: "\(cache.liveMaxRaySteps)", color: themeColor.opacity(0.8))
                    StatBox(label: "Scale", value: String(format: "%.2f", cache.liveFractalScale), color: themeColor.opacity(0.6))
                }
            }.padding().background(themeColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "film.fill").foregroundStyle(themeColor); Text("Animation Test").font(.headline) }
                Button {
                    if isTestAnimationPlaying { appModel.animationManager?.stop(); isTestAnimationPlaying = false }
                    else if let mgr = appModel.animationManager {
                        mgr.currentScene = AdvancedTestScene.create(startPosition: cache.livePosition)
                        mgr.play(); isTestAnimationPlaying = true
                    }
                } label: {
                    HStack { Image(systemName: isTestAnimationPlaying ? "stop.fill" : "play.fill"); Text(isTestAnimationPlaying ? "Stop" : "Play Test") }
                }.buttonStyle(.borderedProminent).tint(isTestAnimationPlaying ? .red : themeColor)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            // === EXPERIMENTAL: COHERENT PACKET RAYMARCH (Stages 0-3 prototype) ===
            // Replaces prevDepth*0.9 warm-start with single-DE-eval safety probe per
            // pixel; gates shared shadows on local normal coherence. Only takes effect
            // on the 8x8 adaptive compute path (Renderer Mode = Adaptive Compute).
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "atom").foregroundStyle(themeColor)
                    Text("Coherent Packet Raymarch")
                        .font(.headline)
                    Spacer()
                    Text("EXPERIMENTAL")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                Toggle(isOn: Binding(
                    get: { appModel.renderSettings.coherentPacketEnabled },
                    set: { appModel.renderSettings.coherentPacketEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Predict-validate warm-start")
                        Text("Single DE-eval safety probe + normal-coherence shadow gate. 8x8 compute path only.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }.tint(themeColor)
                Text("Layer-of-acceptance overlay shows immediately when this toggle is on (no other debug flag needed): magenta = warm-start hit, green = warm-start tight, red = warm-start rejected, cyan = shadow fallback. Untinted = legacy coarse path. 8x8 compute path only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

#if DEBUG
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "timer").foregroundStyle(themeColor); Text("Benchmarking").font(.headline) }
                HStack {
                    Button {
                        isBenchmarking.toggle()
                        BenchmarkManager.shared.toggleBenchmarking()
                    } label: {
                        HStack {
                            Image(systemName: isBenchmarking ? "stop.circle.fill" : "play.circle.fill")
                            Text(isBenchmarking ? "Stop Benchmarking" : "Start Benchmarking")
                        }
                    }.buttonStyle(.borderedProminent).tint(isBenchmarking ? .red : themeColor)
                    
                    if !isBenchmarking {
                        Button {
                            BenchmarkManager.shared.clearStats()
                        } label: {
                            Text("Clear Stats")
                        }.buttonStyle(.bordered)
                    }
                }
                Text("Check Xcode console for results.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
#endif
        }
    }
}
