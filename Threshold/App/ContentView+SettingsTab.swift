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
                Picker("Settings section", selection: settingsSubTabBinding) {
                    ForEach(SettingsSubTab.visibleCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Choose a settings section")

                Button {
                    #if os(iOS)
                    isWelcomePresented = true
                    #else
                    openWindow(id: AppModel.onboardingWindowID)
                    #endif
                } label: {
                    Label("Show Welcome", systemImage: AppIcons.questionmarkCircle)
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
                    case .gestures:  settingsDisplayContent
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

    // MARK: - Quick Toggles pane

    /// A standalone pane (selected from the section rail) holding a flat,
    /// scannable page of master on/off switches for feature categories whose
    /// controls are otherwise scattered across the Effects, Shape, and Advanced
    /// tabs. Each switch binds to the same underlying enable flag the detailed
    /// control surfaces use, so flipping one here is identical to toggling it on
    /// its home tab — this is just one place to find them all.
    var quickTogglesTabContent: some View {
        let sections = quickToggleSections
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Quick Toggles", systemImage: "switch.2")
                    .font(.headline)
                Text("Tap a tile to flip a feature on or off. Lit tiles are on. Each tile is resolved from the same semantic control catalog as radial and spatial controls.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    quickToggleSection(section.name, descriptors: section.descriptors)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var quickToggleSections: [(name: String, descriptors: [ToggleDescriptor])] {
        let key = ControlCatalogProjectionKey(
            profile: appModel.platformProfile,
            route: nil,
            presentation: .quickToggles,
            fractalType: cache.fractalType,
            catalogRevision: 1,
            transformRevision: cache.spaceWarpStructureRevision,
            featureFlags: 0
        )
        return appModel.controlProjectionCache.sections(for: key).compactMap { section in
            let descriptors = section.controlIDs.compactMap { id -> ToggleDescriptor? in
                guard case .toggle(let descriptor) = ParameterCatalog.semanticByID[id] else { return nil }
                return descriptor
            }
            return descriptors.isEmpty ? nil : (section.name, descriptors)
        }
    }

    private func quickToggleSection(
        _ title: String,
        descriptors: [ToggleDescriptor]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(descriptors) { descriptor in quickToggleTile(descriptor) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickToggleOnFill: LinearGradient {
        LinearGradient(
            colors: [.red, .orange, .yellow, .green, .blue, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func quickToggleTile(_ descriptor: ToggleDescriptor) -> some View {
        let access = appModel.controlAccessService
        let available = descriptor.isAvailable(cache)
        let on = access.readToggle(descriptor.controlID) ?? false
        let home = descriptor.placement.route
        let tile = VStack(spacing: 6) {
            Image(systemName: descriptor.icon)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
            Text(descriptor.name)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(8)
        .foregroundStyle(on ? Color.white : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(on ? AnyShapeStyle(quickToggleOnFill) : AnyShapeStyle(Color.gray.opacity(0.16)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(on ? Color.white.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if home != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(on ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5))
                    .padding(6)
            }
        }
        .shadow(color: on ? .black.opacity(0.18) : .clear, radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .opacity(available ? 1 : 0.3)
        .animation(.easeInOut(duration: 0.18), value: on)
        .onLongPressGesture(minimumDuration: 0.4) {
            if let home { openQuickToggleRoute(home) }
        }
        .onTapGesture {
            access.writeToggle(!on, to: descriptor.controlID)
        }
        .disabled(!available)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(descriptor.name)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { access.writeToggle(!on, to: descriptor.controlID) }
        .help(home != nil ? "\(descriptor.name) — long-press to open its controls" : descriptor.name)

        if let home {
            return AnyView(tile.accessibilityAction(named: Text("Open controls")) {
                openQuickToggleRoute(home)
            })
        }
        return AnyView(tile)
    }

    // MARK: - Display sub-view

    /// Display-focused settings: Platform (visionOS), handedness, lighting,
    /// HUD toggles, and resolution. Extracted from the old "General" tab
    /// so the user has one place to find visual / display-related knobs.
    private var settingsDisplayContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            // Text size — Dynamic Type for the menu. visionOS only: Mac/iPad
            // already honor the system text-size setting, so an in-app knob would
            // be redundant there.
#if os(visionOS)
            textSizeSection
#endif

            // Touch indicators — only meaningful where fingers touch the
            // render view directly.
#if os(iOS)
            touchIndicatorsSection
#endif

#if os(macOS)
            macLauncherSection
            macPerformanceDisplaySection
#endif

            // Experimental display features (kept here, not in Advanced,
            // because they're visual toggles the user can flip while the
            // scene is running).
            experimentalDisplaySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

#if os(macOS)
    private var macPerformanceDisplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Performance Display", systemImage: AppIcons.chartBarFill)
                .font(.headline)

            Toggle("Show FPS in viewport", isOn: $showFPSInHUD)
            Text("The viewport indicator still identifies the active Native, Spatial, or Temporal path when FPS is hidden.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Show metrics in bottom menu", isOn: $showPerformanceInMenu)
            Text("Adds compact FPS, GPU frame time, and render quality to the bottom menu bar.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var macLauncherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Menu Navigation", systemImage: macTabLauncherStyle.systemImage)
                .font(.headline)

            Picker("Navigation style", selection: $macTabLauncherStyle) {
                ForEach(NavigationPresentationStyle.allCases, id: \.self) { style in
                    Label(style.displayName, systemImage: style.systemImage).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Text(macTabLauncherStyle.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
#endif

    /// VisionOS-only glass-floor platform settings. Mirrors the
    /// `ContentView+FractalTab` block but is the canonical home for these
    /// controls now that Settings has a Display sub-tab.
#if os(visionOS)
    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Platform", systemImage: AppIcons.circleHexagongridFill)
                    .font(.headline)
                Spacer()
                if cache.display.platformEnabled {
                    Text(String(format: "%.1f m", cache.display.platformRadius))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Show Platform", isOn: Binding(
                    get: { cache.display.platformEnabled },
                    set: { cache.setPlatformEnabled($0) }
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
                    ), range: ControlCatalog.platformRadius.range,
                    enabled: .constant(true),
                    onChanged: { cache.commitPlatformRadius() },
                    showToggle: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    Label("Touch Indicators", systemImage: AppIcons.handTapFill)
                        .font(.headline)
                    Text("Shows a glowing dot under each finger on the fractal view, tinted by gesture: cyan while orbiting, violet while panning or zooming.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.cyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Label("Handedness", systemImage: AppIcons.handPointUpLeftFill)
                .font(.headline)
            Picker("Dominant hand", selection: handedBinding) {
                Label("Right", systemImage: AppIcons.handRaisedFingersSpreadFill).tag(false)
                Label("Left",  systemImage: AppIcons.handRaisedFingersSpread).tag(true)
            }
            .pickerStyle(.segmented)
            Text("Choose your dominant hand. Some per-finger tap defaults are mirrored automatically.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.07)))
    }

    /// Menu text size (visionOS). Enlarges the menu's text via Dynamic Type so it
    /// stays crisp and reflows — icons and chrome geometry are left alone. Backed
    /// by `@AppStorage(DS.textSizeStorageKey)` on `ContentView` and applied on the
    /// menu body via `.dynamicTypeSize`, so text resizes live as the slider moves.
#if os(visionOS)
    private var textSizeSection: some View {
        // Discrete slider over DS.textSizeSteps via a Double proxy binding.
        let stepBinding = Binding<Double>(
            get: { Double(uiMenuTextSizeIndex) },
            set: { uiMenuTextSizeIndex = Int($0.rounded()) }
        )
        let lastIndex = DS.textSizeSteps.count - 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Text Size", systemImage: "textformat.size")
                    .font(.headline)
                Spacer()
                Text(DS.textSizeLabel(forIndex: uiMenuTextSizeIndex))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(value: stepBinding, in: 0...Double(lastIndex), step: 1)
                .tint(.indigo)

            HStack {
                Text("Enlarges the menu's text while keeping it sharp; the panels reflow to fit. Icons and buttons are left at their normal size.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Reset") { uiMenuTextSizeIndex = DS.defaultTextSizeIndex }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .disabled(uiMenuTextSizeIndex == DS.defaultTextSizeIndex)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.07)))
    }
#endif

    /// Display-flavored experimental toggles. The custom-shenes enable is
    /// a display-runtime knob (it gates whether the renderer tries to
    /// compile user-supplied shaders), so it lives here.
    private var experimentalDisplaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Experimental Display", systemImage: AppIcons.flaskFill)
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

            VStack(alignment: .leading, spacing: 4) {
                CompactValueSlider(
                    title: "Sphere Projection Mismatch (δ)",
                    value: Binding(
                        get: { cache.display.deIterationMismatch },
                        set: {
                            cache.display.deIterationMismatch = $0
                            cache.push(\.deIterationMismatch, value: $0)
                        }
                    ),
                    range: ControlCatalog.deIterationMismatch.range,
                    display: String(format: "%+.2f", cache.display.deIterationMismatch),
                    tint: .orange
                )
                Text("δ biases the geometry fold loop (FC_FRACTAL_ITERATIONS) while the distance estimator stays normalized to the base count — the faithful \"Accidental Sphere Projection\" under-fold. Negative → fewer folds → sphere. 0 = off. Saves with the scene.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
    }

    // MARK: - Gestures sub-view

    // MARK: - Sharing sub-view

    /// Sharing sub-view: aggregate usage, authored DE/scene sharing, and
    /// iCloud Drive backup. Every sharing category is optional and separate.
    private var settingsSharingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            storageLocationSection
            communitySharingSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Storage Location (On This Device / iCloud Drive)
    // ─────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var storageLocationSection: some View {
        let mode = StorageLocation.shared.mode
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Storage Location", systemImage: AppIcons.folder).font(.headline)
                Spacer()
                if mode == .iCloud && !StorageLocation.shared.isICloudAvailable {
                    ProgressView().controlSize(.small)
                }
            }

            Text("Where your scenes, animations, and presets live. Pick **iCloud Drive** to browse them in Files and sync across your devices; **On This Device** keeps them private to this device. A local safety backup is always kept either way, and switching merges both stores so nothing is lost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Storage", selection: Binding(
                get: { StorageLocation.shared.mode },
                set: { newMode in appModel.switchStorageMode(to: newMode) }
            )) {
                ForEach(StorageMode.allCases, id: \.self) { m in
                    Label(m.displayName, systemImage: m.iconName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if mode == .iCloud {
                if StorageLocation.shared.isICloudAvailable {
                    Text("Browse in Files → iCloud Drive → **Threshold**.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("iCloud Drive isn't available yet — sign in to iCloud in System Settings. Your data stays on this device until it resolves.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.07)))
    }

    private var communitySharingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Community Sharing", systemImage: AppIcons.person3Fill)
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

            Text("All sharing is optional. No account, Apple ID, email, or location is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { UsageAnalytics.shared.analyticsEnabled },
                set: { UsageAnalytics.shared.analyticsEnabled = $0 }
            )) {
                Label(
                    UsageAnalytics.shared.analyticsEnabled ? "Share aggregate usage signals" : "Aggregate usage sharing is off",
                    systemImage: UsageAnalytics.shared.analyticsEnabled ? AppIcons.person3Fill : AppIcons.personSlash
                )
            }
            .tint(.blue)

            Text("This covers anonymous aggregate signals only — such as time spent in an area or on a platform — viewed in aggregate to help refine the app for everyone. It does not share your scenes, distance estimators, names, or personal files.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Text("Share authored work with the creators (optional)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Distance estimators (DEs)", isOn: Binding(
                get: { UsageAnalytics.shared.distanceEstimatorSharingEnabled },
                set: { UsageAnalytics.shared.distanceEstimatorSharingEnabled = $0 }
            ))
            .disabled(!UsageAnalytics.shared.analyticsEnabled)
            Toggle("Scenes", isOn: Binding(
                get: { UsageAnalytics.shared.sceneSharingEnabled },
                set: { UsageAnalytics.shared.sceneSharingEnabled = $0 }
            ))
            .disabled(!UsageAnalytics.shared.analyticsEnabled)

            Picker("Specificity", selection: Binding(
                get: { UsageAnalytics.shared.sharingSpecificity },
                set: { UsageAnalytics.shared.sharingSpecificity = $0 }
            )) {
                ForEach(CommunitySharingSpecificity.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .disabled(!UsageAnalytics.shared.analyticsEnabled ||
                      (!UsageAnalytics.shared.distanceEstimatorSharingEnabled && !UsageAnalytics.shared.sceneSharingEnabled))

            Text(UsageAnalytics.shared.sharingSpecificity.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)

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
                Text("Used only for attribution if you allow featuring. Leave blank to share anonymously. It stays on this device until you explicitly share work.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("What you're opting into:", systemImage: AppIcons.checkmarkCircle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("• Aggregate usage is separate from authored work\n• DE and scene sharing are separate choices\n• Creator review does not automatically mean featuring\n• Featuring may include attribution when you provide a display name")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07)))
    }

    // (Old `settingsGeneralContent` removed — the settings tab now
    // dispatches to `settingsDisplayContent` / `settingsGesturesContent`
    // / `settingsSharingContent` / `settingsExportContent` /
    // `settingsAdvancedContent` based on the segmented sub-tab picker.)

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


    
    // MARK: - Export & Share Tab

    private var settingsExportContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Current Preset Export ────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Current Preset", systemImage: AppIcons.squareAndArrowUp)
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
                        Label("Export Preset (.threshscene)", systemImage: AppIcons.docBadgeArrowUp)
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
                        Label("Export Music Preset (.threshmp)", systemImage: AppIcons.musicNoteList)
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
                    Label("Saved Presets", systemImage: AppIcons.squareStack3dUp)
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
                                    Text(".\(ThresholdExportFormat.preset(hasMusic: hasMusic).ext)")
                                    if hasMusic {
                                        Label("Music", systemImage: AppIcons.musicNote)
                                    }
                                    if preset.embeddedFormula != nil {
                                        Label("Formula", systemImage: AppIcons.function)
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
                                Image(systemName: AppIcons.squareAndArrowUp)
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
                        Label("Custom Formula", systemImage: AppIcons.function)
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
                            Label("Export Formula (.threshfx)", systemImage: AppIcons.docBadgeArrowUp)
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
                    Label("Animation Scenes", systemImage: AppIcons.filmStack)
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
                                            Label("Music", systemImage: AppIcons.musicNote)
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
                                    Image(systemName: AppIcons.squareAndArrowUp)
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
                    Label("File Formats", systemImage: AppIcons.docText)
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
            // Use the same native share UI as the Presets library so the two
            // export paths behave identically. UIActivityViewController /
            // NSSharingServicePicker dismiss themselves once the user picks a
            // destination or cancels — the previous custom ShareLink sheet had
            // no dismiss control and could get stuck on visionOS/macOS.
            ShareSheet(activityItems: [item.url])
        }
        #if os(macOS)
        // NSSharingServicePicker presents as a child window, pulling the
        // pointer off the sidebar's hover region — hold the panel open while
        // it's up, same as the other Mac sheets/popovers.
        .onChange(of: exportShareItem != nil) { _, isPresented in
            updateMacSheetMenuAdjustment(isPresented, holding: &isHoldingExportSheetAdjustment)
        }
        #endif
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
    
    /// Reusable "EXPERIMENTAL" pill. Single source of truth for the badge that
    /// previously appeared copy-pasted on each Advanced raymarcher card.
    private var experimentalBadge: some View {
        Text("EXPERIMENTAL")
            .font(.caption2.bold())
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Grouped raymarcher acceleration controls (Advanced tab). Collects the
    /// distance-field march knobs — Smart Advance, Coherent Packet, and
    /// Foveation — into a single card with subtle dividers, replacing the three
    /// loose, badge-duplicating blocks that used to float in the Advanced list.
    private var raymarcherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: AppIcons.boltFill).foregroundStyle(themeColor)
                Text("Raymarcher").font(.headline)
                Spacer()
                experimentalBadge
            }
            Text("Acceleration controls for the distance-field raymarcher. Each trades a little detail for speed in a different way — safe to flip while the scene is running.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.4)

            // ── Smart Advance — every render path ────────────────────────
            Toggle(isOn: Binding(
                get: { appModel.renderSettings.smartAdvanceEnabled },
                set: { appModel.renderSettings.smartAdvanceEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Advance")
                    Text("Reads the gradient of the march to spot rays skimming nearly parallel to a surface, then leads ahead with larger steps where plain tracing would creep. Faster through open and grazing regions; can soften fine silhouette detail. Works on every render path.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.tint(themeColor)

            Divider().opacity(0.4)

            // ── Coherent Packet — 8×8 compute path only ──────────────────
            Toggle(isOn: Binding(
                get: { appModel.renderSettings.coherentPacketEnabled },
                set: { appModel.renderSettings.coherentPacketEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coherent Packet")
                    Text("Predict-validate warm-start: a single DE-eval safety probe with a normal-coherence shadow gate. Shows a layer-of-acceptance debug overlay while on (magenta = hit, green = tight, red = rejected, cyan = shadow fallback). 8×8 compute path only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.tint(themeColor)

            Divider().opacity(0.4)

            // ── Foveation — 8×8 compute path only ────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                CompactValueSlider(
                    title: "Foveation",
                    value: Binding(
                        get: { appModel.renderSettings.foveationStrength },
                        set: { appModel.renderSettings.foveationStrength = $0 }
                    ),
                    range: ControlCatalog.foveationStrength.range,
                    display: appModel.renderSettings.foveationStrength < 0.01 ? "Off" : "\(Int((appModel.renderSettings.foveationStrength * 100).rounded()))%",
                    tint: themeColor
                )
                Text("Peripheral 8×8 tiles march fewer ray steps, ramping from the center outward. 0 = off. Cuts GPU cost where peripheral vision can't resolve detail. 8×8 compute path only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var settingsAdvancedContent: some View {
        @Bindable var appModel = appModel
        return VStack(alignment: .leading, spacing: 16) {
            // Raymarcher acceleration toggles — Smart Advance, Coherent Packet,
            // and Foveation grouped into one card (see `raymarcherSection`).
            raymarcherSection

            VStack(alignment: .leading, spacing: 8) {
                RenderDiagnosticsView()
                Text("Live from the renderer. 'Drawable' is the actual per-eye render-target size the compositor granted — at 100% render quality it should reach the panel's native resolution. Render quality tracks the resolution slider.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            // ── Performance Sweep (per-build Vision Pro perf log) ──
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: AppIcons.timer).foregroundStyle(themeColor); Text("Performance Sweep").font(.headline) }
                let runner = appModel.perfSweepRunner
                Button {
                    if runner.isRunning { runner.cancel() }
                    else { runner.start(appModel: appModel) }
                } label: {
                    HStack {
                        Image(systemName: runner.isRunning ? AppIcons.stopCircleFill : AppIcons.playCircleFill)
                        Text(runner.isRunning ? "Cancel Sweep" : "Run Benchmark Sweep")
                    }
                }.buttonStyle(.borderedProminent).tint(runner.isRunning ? .red : themeColor)

                if runner.isRunning, runner.totalScenes > 0 {
                    ProgressView(value: Double(runner.currentScene), total: Double(runner.totalScenes))
                        .tint(themeColor)
                }
                Text(runner.progressText)
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Loads a curated set of scenes, measures GPU/CPU/FPS on this device, and appends one record to Documents/PerfLog/perf-log.jsonl (+ perf-log.md). Run it with the immersive view up. Pull the files via the Files app and append them to the repo's PERF_LOG.jsonl to track performance across builds.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
