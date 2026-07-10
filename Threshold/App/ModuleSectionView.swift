//
//  ModuleSectionView.swift
//  Threshold
//
//  Stage 4 of the class-based module refactor: the UI consumer. The hand-written
//  Space/Effects sections all repeated the same scaffolding — a titled box with an
//  optional enable toggle, a description, an optional capability fallback, and a
//  list of slider rows. That scaffolding now lives ONCE here (`ModuleSectionView`),
//  and each box's content is declared as data (`ModuleUISection`).
//
//  Layering: the `Module` data type (Parameters/Module.swift) owns identity, route,
//  params, capability, and scene-apply. This App-tier layer owns the *presentation*
//  of a module's route — the live `UISettingsCache` / `RenderSettings` bindings and
//  the SwiftUI rendering — so the Parameters layer stays free of SwiftUI.
//
//  A `ModuleUISection` is one box. A module's route may surface as several boxes
//  (Space → inversion, projection, warp); each is a `ModuleUISection`. Converting a
//  hand-written section is: declare its `ModuleUISection` factory + render it.
//
//  Closures are `@MainActor` (the live store, UISettingsCache, is MainActor-
//  isolated) — mirroring the FloatParameterNode read/write closure pattern.
//

import SwiftUI

extension View {
    /// The shared "module card" chrome: padded rounded rect tinted by an accent.
    /// This is the box wrapper that was copy-pasted ~15× across the control tabs
    /// (`.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(...))`).
    func moduleCard(_ accent: Color, opacity: Double = 0.06) -> some View {
        self
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(opacity)))
    }
}

/// A live on/off binding for a module control or section.
struct ModuleToggle {
    let get: @MainActor () -> Bool
    let set: @MainActor (Bool) -> Void
}

/// One slider control inside a data-driven module section. Carries its own live
/// get/set into the UI store plus the commit hook that pushes to the renderer.
struct ModuleSliderControl: Identifiable {
    var id: String { label }
    let label: String
    let icon: String
    let range: ClosedRange<Float>
    let get: @MainActor () -> Float
    let set: @MainActor (Float) -> Void
    /// Pushed to the renderer after an edit (e.g. `cache.commitSphereProjection()`).
    var commit: @MainActor () -> Void = {}
    /// Only rendered when true (e.g. sub-sliders shown once the box is enabled).
    var isVisible: @MainActor () -> Bool = { true }
    /// Disabled (greyed) when this returns false. Default: always enabled.
    var isEnabled: @MainActor () -> Bool = { true }
    /// When set, an inline switch is shown bound to this (writes the enable state).
    var toggle: ModuleToggle? = nil
    /// Live "derived value" ghost marker target while music drives this param.
    var musicTargetID: String? = nil
}

/// A data-driven UI section ("box") for a module route. Replaces the hand-written
/// header + toggle + description + capability-fallback + sliders scaffolding.
struct ModuleUISection {
    /// nil = headerless box (just controls in a card).
    var title: String? = nil
    var icon: String = ""
    var description: String? = nil
    /// nil = always available; else the header dims and a fallback note replaces
    /// the controls when this returns false.
    var isAvailable: @MainActor () -> Bool = { true }
    var unavailableNote: String = "Not available for this fractal."
    /// Optional master enable toggle shown in the header.
    var enabled: ModuleToggle? = nil
    let controls: [ModuleSliderControl]
    var accent: Color = .teal
    /// Vertical spacing between rows (boxes historically used 4 / 6 / 8).
    var rowSpacing: CGFloat = 8
}

/// Renders any `ModuleUISection` with the shared box styling. The single home for
/// the copy-pasted VStack/Toggle/background scaffolding.
struct ModuleSectionView: View {
    let section: ModuleUISection

    var body: some View {
        let available = section.isAvailable()
        VStack(alignment: .leading, spacing: section.rowSpacing) {
            if section.title != nil || section.enabled != nil {
                HStack {
                    if let title = section.title {
                        Label(title, systemImage: section.icon)
                            .font(.headline)
                            .foregroundStyle(available ? .primary : .secondary)
                    }
                    Spacer()
                    if available, let enabled = section.enabled {
                        Toggle("", isOn: Binding(get: { enabled.get() }, set: { enabled.set($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }
            }

            if let description = section.description {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if available {
                ForEach(section.controls.filter { $0.isVisible() }) { control in
                    EffectSliderRow(icon: control.icon, label: control.label,
                        value: Binding(get: { control.get() }, set: { control.set($0) }),
                        range: control.range,
                        enabled: Binding(get: { control.isEnabled() }, set: { control.toggle?.set($0) }),
                        onChanged: { control.commit() },
                        showToggle: control.toggle != nil,
                        musicTargetID: control.musicTargetID)
                }
            } else {
                Label(section.unavailableNote, systemImage: AppIcons.infoCircle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .moduleCard(section.accent)
    }
}

// MARK: - Space-module section factories
//
// These declare the live bindings for the SpaceModule's UI boxes. They render the
// same params SpaceModule routes on scene-load (sphereProjection*, spaceWarpStrength)
// at its declared route — the UI and the module now describe the same controls.

extension ModuleUISection {

    /// Sphere Projection box — capability-gated on `.sphereProjection`, with an
    /// enable toggle and two sliders shown once enabled. Behavior-identical to the
    /// former hand-written `sphereProjectionSection`.
    @MainActor
    static func sphereProjection(cache: UISettingsCache) -> ModuleUISection {
        let isMandelbox = cache.fractalType == .mandelbox
        return ModuleUISection(
            title: "Sphere Projection",
            icon: AppIcons.globeAsiaAustralia,
            description: isMandelbox
                ? "Radially projects each fold onto a sphere right after the sphere-fold step — the \u{201C}accidental sphere\u{201D} look. Box detail melts into a glowing spherical shell."
                : "Warps space radially toward a sphere before the fractal is evaluated — pulls this shape\u{2019}s detail onto a spherical shell. Blend low for a subtle bulge, high for a full sphere melt.",
            isAvailable: { cache.fractalType.supports(.sphereProjection) },
            enabled: ModuleToggle(get: { cache.display.sphereProjectionEnabled },
                                  set: { newValue in
                                      cache.display.sphereProjectionEnabled = newValue
                                      cache.commitSphereProjection()
                                  }),
            controls: [
                ModuleSliderControl(
                    label: "Projection", icon: "circle.lefthalf.filled",
                    range: ControlCatalog.sphereProjectionBlend.range,
                    get: { cache.display.sphereProjectionBlend },
                    set: { cache.display.sphereProjectionBlend = $0 },
                    commit: { cache.commitSphereProjection() },
                    isVisible: { cache.display.sphereProjectionEnabled },
                    musicTargetID: ParameterTargetID.Space.sphereProjectionBlend),
                ModuleSliderControl(
                    label: "Projection Radius", icon: "circle",
                    range: ControlCatalog.sphereProjectionRadius.range,
                    get: { cache.display.sphereProjectionRadius },
                    set: { cache.display.sphereProjectionRadius = $0 },
                    commit: { cache.commitSphereProjection() },
                    isVisible: { cache.display.sphereProjectionEnabled },
                    musicTargetID: ParameterTargetID.Space.sphereProjectionRadius),
            ],
            accent: .teal)
    }

    /// Space Warp box — the cross-platform space-module seam (built-in "Twist";
    /// loadable `.threshfx` space effects override the GPU function). Binds the
    /// warp strength straight to RenderSettings.
    @MainActor
    static func spaceWarp(renderSettings: RenderSettings) -> ModuleUISection {
        ModuleUISection(
            title: "Space Warp",
            icon: "tornado",
            description: "A domain-space twist applied to this fractal before it is evaluated. The built-in default twists about the vertical axis; loadable space-effect plugins replace it. 0 = off.",
            controls: [
                ModuleSliderControl(
                    label: "Twist", icon: "tornado",
                    range: ControlCatalog.spaceWarpStrength.range,
                    get: { renderSettings.spaceWarpStrength },
                    set: { renderSettings.spaceWarpStrength = $0 }),
            ],
            accent: .purple)
    }

    // MARK: - Lighting-module section factories

    /// Pulse box (Effects → Dynamic): two sliders sharing the pulse enable. The
    /// "Pulse Speed" slider shows the enable switch; "Pulse Amount" greys with it.
    @MainActor
    static func pulse(cache: UISettingsCache) -> ModuleUISection {
        let pulseEnabled = ModuleToggle(
            get: { cache.lighting.pulseEffect.enabled },
            set: { cache.lighting.pulseEffect.enabled = $0 })
        return ModuleUISection(
            controls: [
                ModuleSliderControl(
                    label: "Pulse Speed", icon: "waveform.path.ecg", range: 0...2,
                    get: { cache.lighting.pulseEffect.speed },
                    set: { cache.lighting.pulseEffect.speed = $0 },
                    commit: { cache.commitPulseEffect() },
                    isEnabled: { cache.lighting.pulseEffect.enabled },
                    toggle: pulseEnabled),
                ModuleSliderControl(
                    label: "Pulse Amount", icon: "waveform.path", range: 0...1,
                    get: { cache.lighting.pulseEffect.amount },
                    set: { cache.lighting.pulseEffect.amount = $0 },
                    commit: { cache.commitPulseEffect() },
                    isEnabled: { cache.lighting.pulseEffect.enabled }),
            ],
            accent: .purple,
            rowSpacing: 4)
    }
}
