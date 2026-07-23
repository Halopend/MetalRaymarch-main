//
//  ParameterCatalog.swift
//  Threshold
//
//  Canonical parameter registry for routed core/effect/space controls.
//
//  Authors one `ParameterDescriptor` per routed control. Runtime nodes,
//  dispatcher bindings, gesture lists, and music metadata derive from these
//  descriptors; ControlCatalog supplies their shared static presentation/range
//  values. The descriptor is a non-Codable runtime facade and is never serialized.
//

import Foundation

// MARK: - Authored facets

/// Music-reactive defaults for a control, projected from the `MusicReactiveTarget`
/// switch bodies. nil for controls with no music target (e.g. the Twist params).
struct MusicFacet: Sendable {
    let category: MusicReactiveTargetCategory
    let defaultSource: MusicReactiveSource
    let defaultResponseCurve: ResponseCurve
    let hasFlashingRisk: Bool
}

/// Gesture-binding classification. `tripletGroupKey` groups xyz axes (consumed by a
/// later slice; nil for scalars).
struct GestureFacet: Sendable {
    let isMappable: Bool
    let tripletGroupKey: String?
    /// True when this scalar should appear in the finger-binding menu as a 1-D drag
    /// target. False for gesture-mappable scalars already reachable via a dedicated
    /// core gesture (fractalScale via orbit/zoom, colorMix), to avoid a duplicate
    /// entry. (Grafted from the class-branch design; drives gestureBindableCoreParameters.)
    let surfacesAsScalarGesture: Bool

    init(isMappable: Bool, tripletGroupKey: String? = nil, surfacesAsScalarGesture: Bool = false) {
        self.isMappable = isMappable
        self.tripletGroupKey = tripletGroupKey
        self.surfacesAsScalarGesture = surfacesAsScalarGesture
    }
}

/// Feature-enablement gate. Reuses the `FractalTypeDescriptor.supports` shape.
enum ParameterCapability: Sendable {
    case universal
    case requires(@Sendable (FractalModelType) -> Bool)

    func isAvailable(_ type: FractalModelType) -> Bool {
        switch self {
        case .universal: return true
        case .requires(let predicate): return predicate(type)
        }
    }
}

/// UI-path binding. `@MainActor` because it reads/writes the MainActor-isolated
/// `ControlStateStore`; only ever invoked on the cache dispatch path.
struct UIBinding: Sendable {
    let read: @MainActor @Sendable (ControlStateStore) -> Float
    let write: @MainActor @Sendable (ControlStateStore, Float) -> Void
    let persists: Bool
}

/// Off-main binding into the lock-protected `RenderSettings`. `@Sendable`; only ever
/// invoked on the off-main dispatch path. Carries the playback-relative music-offset
/// closures too, so this mirror is lossless for the eventual `coreDescriptors`
/// deletion (Slice 3).
struct SettingsBinding: Sendable {
    let read: @Sendable (RenderSettings) -> Float
    let write: @Sendable (RenderSettings, Float) -> Void
    /// During animation playback `applyKeyframe` owns the backing var, so the absolute
    /// `write` would be stomped — the dispatcher deposits the pure music delta here
    /// instead. nil → not keyframe-driven.
    let writeAudioOffset: (@Sendable (RenderSettings, Float) -> Void)?
    let audioOffsetActiveDuringPlayback: (@Sendable (RenderSettings) -> Bool)?
}

struct ControlPresentation: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt16

    static let fullControls    = Self(rawValue: 1 << 0)
    static let quickToggles    = Self(rawValue: 1 << 1)
    static let radial2D        = Self(rawValue: 1 << 2)
    static let spatialRadial   = Self(rawValue: 1 << 3)
    static let controlFinder   = Self(rawValue: 1 << 4)
    static let gestureBinding  = Self(rawValue: 1 << 5)
    static let musicMapping    = Self(rawValue: 1 << 6)

    static let all: Self = [
        .fullControls, .quickToggles, .radial2D, .spatialRadial,
        .controlFinder, .gestureBinding, .musicMapping
    ]
}

enum ControlPlacement: Hashable, Sendable {
    case presented(
        route: AppRoute,
        section: String,
        order: Int,
        presentations: ControlPresentation
    )
    case internalOnly

    var route: AppRoute? {
        guard case .presented(let route, _, _, _) = self else { return nil }
        return route
    }

    var presentations: ControlPresentation {
        guard case .presented(_, _, _, let presentations) = self else { return [] }
        return presentations
    }
}

/// The vertically-integrated node: authored metadata (via `spec`) + routing +
/// capability + gesture + music + both binding pairs. Non-Codable; never serialized.
/// Intentionally NON-Equatable (holds closures); `spec` stays Equatable for the
/// validator's range checks.
struct ParameterDescriptor: Sendable, Identifiable {
    let spec: ControlSpec
    let placement: ControlPlacement
    let requiredPlatformCapabilities: PlatformCapability
    let capability: ParameterCapability
    let gesture: GestureFacet?
    let music: MusicFacet?
    let ui: UIBinding
    let settings: SettingsBinding

    var id: String { spec.id }
    var controlID: ControlID { spec.controlID }
    func clamp(_ value: Float) -> Float { spec.clamp(value) }
}

struct ToggleDescriptor: Sendable, Identifiable {
    let controlID: ControlID
    let name: String
    let icon: String
    let placement: ControlPlacement
    let requiredPlatformCapabilities: PlatformCapability
    let isAvailable: @MainActor @Sendable (ControlStateStore) -> Bool
    let read: @MainActor @Sendable (ControlStateStore) -> Bool
    let write: @MainActor @Sendable (ControlStateStore, Bool) -> Void
    var id: ControlID { controlID }

    init(
        controlID: ControlID,
        name: String,
        icon: String,
        placement: ControlPlacement,
        requiredPlatformCapabilities: PlatformCapability,
        isAvailable: @escaping @MainActor @Sendable (ControlStateStore) -> Bool = { _ in true },
        read: @escaping @MainActor @Sendable (ControlStateStore) -> Bool,
        write: @escaping @MainActor @Sendable (ControlStateStore, Bool) -> Void
    ) {
        self.controlID = controlID
        self.name = name
        self.icon = icon
        self.placement = placement
        self.requiredPlatformCapabilities = requiredPlatformCapabilities
        self.isAvailable = isAvailable
        self.read = read
        self.write = write
    }
}

struct ActionDescriptor: Sendable, Identifiable {
    let controlID: ControlID
    let name: String
    let icon: String
    let placement: ControlPlacement
    let requiredPlatformCapabilities: PlatformCapability
    let command: AppCommand
    var id: ControlID { controlID }
}

enum SemanticControlDescriptor: Sendable, Identifiable {
    case scalar(ParameterDescriptor)
    case toggle(ToggleDescriptor)
    case action(ActionDescriptor)

    var id: ControlID {
        switch self {
        case .scalar(let descriptor): return descriptor.controlID
        case .toggle(let descriptor): return descriptor.controlID
        case .action(let descriptor): return descriptor.controlID
        }
    }

    var placement: ControlPlacement {
        switch self {
        case .scalar(let descriptor): return descriptor.placement
        case .toggle(let descriptor): return descriptor.placement
        case .action(let descriptor): return descriptor.placement
        }
    }

    var requiredPlatformCapabilities: PlatformCapability {
        switch self {
        case .scalar(let descriptor): return descriptor.requiredPlatformCapabilities
        case .toggle(let descriptor): return descriptor.requiredPlatformCapabilities
        case .action(let descriptor): return descriptor.requiredPlatformCapabilities
        }
    }

    func isAvailable(for fractalType: FractalModelType) -> Bool {
        guard case .scalar(let descriptor) = self else { return true }
        return descriptor.capability.isAvailable(fractalType)
    }
}

// MARK: - The authored catalog

/// The single authored surface for routed core/effect/space controls. Declaration
/// Declaration order matches `ControlCatalog.allSpecs`.
enum ParameterCatalog {

    static let routedDescriptors: [ParameterDescriptor] = [

        // MARK: Core geometry

        ParameterDescriptor(
            spec: ControlCatalog.fractalScale,
            placement: .presented(route: .shape(.parameters), section: "Geometry", order: 0, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, tripletGroupKey: nil),
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .sinusoidal, hasFlashingRisk: false),
            ui: UIBinding(
                read: { $0.fractalScale },
                write: { cache, v in cache.fractalScale = v; cache.push(\.targetFractalScale, value: v) },
                persists: true),
            settings: SettingsBinding(
                read: { $0.targetFractalScale },
                write: { settings, value in settings.targetFractalScale = value },
                writeAudioOffset: { settings, offset in settings.audioOffsetFractalScale = offset },
                audioOffsetActiveDuringPlayback: { _ in true })),

        ParameterDescriptor(
            spec: ControlCatalog.colorMix,
            placement: .presented(route: .look(.mapping), section: "Gradient Mapping", order: 0, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, tripletGroupKey: nil),
            music: MusicFacet(category: .color, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UIBinding(
                read: { $0.color.colorMix },
                write: { cache, v in cache.color.colorMix = v; cache.push(\.colorMix, value: v) },
                persists: true),
            settings: SettingsBinding(
                read: { $0.colorMix },
                write: { settings, value in settings.colorMix = value },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        ParameterDescriptor(
            spec: ControlCatalog.iterations,
            placement: .presented(route: .quality(.tuning), section: "Render Budget", order: 0, presentations: [.fullControls, .radial2D, .spatialRadial, .controlFinder, .musicMapping]),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .geometry, defaultSource: .mid, defaultResponseCurve: .sinusoidal, hasFlashingRisk: false),
            ui: UIBinding(
                read: { Float($0.liveFractalIterations) },
                write: { cache, v in
                    let rounded = max(2, min(24, Int(round(v))))
                    cache.liveFractalIterations = rounded
                    cache.push(\.fractalIterations, value: rounded)
                },
                persists: true),
            settings: SettingsBinding(
                read: { Float($0.fractalIterations) },
                write: { settings, value in settings.fractalIterations = max(2, min(24, Int(round(value)))) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        // MARK: Post-process effects

        ParameterDescriptor(
            spec: ControlCatalog.glow,
            placement: .presented(route: .look(.atmosphere), section: "Atmosphere", order: 0, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .light, defaultSource: .beat, defaultResponseCurve: .pulse, hasFlashingRisk: true),
            ui: UIBinding(
                read: { $0.lighting.glowEffect.intensity },
                write: { cache, v in cache.lighting.glowEffect.intensity = v; cache.commitGlowEffect() },
                persists: true),
            settings: SettingsBinding(
                read: { $0.glowEffect.intensity },
                write: { settings, value in settings.audioModulateGlowIntensity(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetGlowIntensity = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesGlow })),

        ParameterDescriptor(
            spec: ControlCatalog.fog,
            placement: .presented(route: .look(.atmosphere), section: "Atmosphere", order: 2, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .light, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UIBinding(
                read: { $0.lighting.fogEffect.intensity },
                write: { cache, v in cache.lighting.fogEffect.intensity = v; cache.commitFogEffect() },
                persists: true),
            settings: SettingsBinding(
                read: { $0.fogEffect.intensity },
                write: { settings, value in settings.audioModulateFogIntensity(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetFogIntensity = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesFog })),

        ParameterDescriptor(
            spec: ControlCatalog.bloom,
            placement: .presented(route: .look(.atmosphere), section: "Atmosphere", order: 1, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .light, defaultSource: .beat, defaultResponseCurve: .pulse, hasFlashingRisk: true),
            ui: UIBinding(
                read: { $0.lighting.bloomEffect.strength },
                write: { cache, v in cache.lighting.bloomEffect.strength = v; cache.commitBloomEffect() },
                persists: true),
            settings: SettingsBinding(
                read: { $0.bloomEffect.strength },
                write: { settings, value in settings.audioModulateBloomStrength(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetBloomStrength = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesBloom })),

        ParameterDescriptor(
            spec: ControlCatalog.hueSpeed,
            placement: .presented(route: .look(.motion), section: "Color Motion", order: 0, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .color, defaultSource: .treble, defaultResponseCurve: .drift, hasFlashingRisk: true),
            ui: UIBinding(
                read: { $0.lighting.hueRotationEffect.speed },
                write: { cache, v in cache.lighting.hueRotationEffect.speed = v; cache.commitHueRotationEffect() },
                persists: true),
            settings: SettingsBinding(
                read: { $0.hueRotationEffect.speed },
                write: { settings, value in settings.audioModulateHueSpeed(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetHueSpeed = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesHueSpeed })),

        ParameterDescriptor(
            spec: ControlCatalog.saturation,
            placement: .presented(route: .look(.grading), section: "Color Grade", order: 0, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .color, defaultSource: .mid, defaultResponseCurve: .drift, hasFlashingRisk: true),
            ui: UIBinding(
                read: { $0.color.colorSchemeSaturation },
                write: { cache, v in cache.color.colorSchemeSaturation = v; cache.commitColorSchemeSaturation() },
                persists: true),
            settings: SettingsBinding(
                read: { $0.colorSchemeSaturation },
                write: { settings, value in settings.audioModulateSaturation(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetSaturation = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesSaturation })),

        ParameterDescriptor(
            spec: ControlCatalog.safetyBubbleRadius,
            placement: .presented(route: .shape(.space), section: "Safety", order: 0, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UIBinding(
                read: { $0.safetyBubble.radius },
                write: { cache, v in cache.safetyBubble.radius = v; cache.push(\.safetyBubbleRadius, value: v) },
                persists: true),
            settings: SettingsBinding(
                read: { $0.safetyBubbleRadius },
                write: { settings, value in settings.audioModulateSafetyBubbleRadius(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        // Gradient phase offset ("Color Offset"). Routed like saturation but without
        // the animation-playback offset path (no writeAudioOffset), matching colorMix.
        ParameterDescriptor(
            spec: ControlCatalog.gradientOffset,
            placement: .presented(route: .look(.mapping), section: "Gradient Mapping", order: 1, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: false, tripletGroupKey: nil),
            music: MusicFacet(category: .color, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UIBinding(
                read: { $0.color.gradientState.gradient.offset },
                write: { cache, v in cache.color.gradientState.gradient.offset = v; cache.push(\.gradientOffset, value: v) },
                persists: true),
            settings: SettingsBinding(
                read: { $0.gradientOffset },
                write: { settings, value in settings.audioModulateGradientOffset(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        // MARK: Space transforms (cross-fractal)

        ParameterDescriptor(
            spec: ControlCatalog.sphereProjectionBlend,
            placement: .presented(route: .shape(.transformations), section: "Sphere Projection", order: 0, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, surfacesAsScalarGesture: true),
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UIBinding(
                read: { $0.display.sphereProjectionBlend },
                write: { cache, v in cache.display.sphereProjectionBlend = v; cache.commitSphereProjection() },
                persists: true),
            settings: SettingsBinding(
                read: { $0.sphereProjectionBlend },
                write: { settings, value in settings.audioModulateSphereProjectionBlend(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        ParameterDescriptor(
            spec: ControlCatalog.sphereProjectionRadius,
            placement: .presented(route: .shape(.transformations), section: "Sphere Projection", order: 1, presentations: .all),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, surfacesAsScalarGesture: true),
            music: MusicFacet(category: .geometry, defaultSource: .bass, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UIBinding(
                read: { $0.display.sphereProjectionRadius },
                write: { cache, v in cache.display.sphereProjectionRadius = v; cache.commitSphereProjection() },
                persists: true),
            settings: SettingsBinding(
                read: { $0.sphereProjectionRadius },
                write: { settings, value in settings.audioModulateSphereProjectionRadius(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        // Twist (built-in space warp): strength + xyz origin. Gesture-mappable but
        // NOT music-reactive (no MusicReactiveTarget case), so `music` is nil.
        ParameterDescriptor(
            spec: ControlCatalog.spaceWarpStrength,
            placement: .presented(route: .shape(.transformations), section: "Transform Stack", order: 0, presentations: [.fullControls, .radial2D, .spatialRadial, .gestureBinding]),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, surfacesAsScalarGesture: true),
            music: nil,
            ui: UIBinding(
                read: { $0.renderSettings?.spaceWarpStrength ?? 0 },
                write: { cache, v in cache.renderSettings?.spaceWarpStrength = v },
                persists: false),
            settings: SettingsBinding(
                read: { $0.spaceWarpStrength },
                write: { settings, value in settings.audioModulateSpaceWarpStrength(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        ParameterDescriptor(
            spec: ControlCatalog.spaceWarpOriginX,
            placement: .presented(route: .shape(.transformations), section: "Transform Stack", order: 1, presentations: [.fullControls, .radial2D, .spatialRadial, .gestureBinding]),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, tripletGroupKey: "space.spaceWarpOrigin", surfacesAsScalarGesture: true),
            music: nil,
            ui: UIBinding(
                read: { $0.renderSettings?.spaceWarpParam1 ?? 0 },
                write: { cache, v in cache.renderSettings?.spaceWarpParam1 = v },
                persists: false),
            settings: SettingsBinding(
                read: { $0.spaceWarpParam1 },
                write: { settings, value in settings.audioModulateSpaceWarpOriginX(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        ParameterDescriptor(
            spec: ControlCatalog.spaceWarpOriginY,
            placement: .presented(route: .shape(.transformations), section: "Transform Stack", order: 2, presentations: [.fullControls, .radial2D, .spatialRadial, .gestureBinding]),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, tripletGroupKey: "space.spaceWarpOrigin", surfacesAsScalarGesture: true),
            music: nil,
            ui: UIBinding(
                read: { $0.renderSettings?.spaceWarpParam2 ?? 0 },
                write: { cache, v in cache.renderSettings?.spaceWarpParam2 = v },
                persists: false),
            settings: SettingsBinding(
                read: { $0.spaceWarpParam2 },
                write: { settings, value in settings.audioModulateSpaceWarpOriginY(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        ParameterDescriptor(
            spec: ControlCatalog.spaceWarpOriginZ,
            placement: .presented(route: .shape(.transformations), section: "Transform Stack", order: 3, presentations: [.fullControls, .radial2D, .spatialRadial, .gestureBinding]),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: GestureFacet(isMappable: true, tripletGroupKey: "space.spaceWarpOrigin", surfacesAsScalarGesture: true),
            music: nil,
            ui: UIBinding(
                read: { $0.renderSettings?.spaceWarpParam3 ?? 0 },
                write: { cache, v in cache.renderSettings?.spaceWarpParam3 = v },
                persists: false),
            settings: SettingsBinding(
                read: { $0.spaceWarpParam3 },
                write: { settings, value in settings.audioModulateSpaceWarpOriginZ(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil))
    ]

    private static let standardPresentations: ControlPresentation = [
        .fullControls, .radial2D, .spatialRadial, .controlFinder
    ]

    private static func staticDescriptor(
        _ spec: ControlSpec,
        route: AppRoute,
        section: String,
        order: Int,
        uiRead: @escaping @MainActor @Sendable (ControlStateStore) -> Float,
        uiWrite: @escaping @MainActor @Sendable (ControlStateStore, Float) -> Void,
        settingsRead: @escaping @Sendable (RenderSettings) -> Float,
        settingsWrite: @escaping @Sendable (RenderSettings, Float) -> Void
    ) -> ParameterDescriptor {
        ParameterDescriptor(
            spec: spec,
            placement: .presented(
                route: route,
                section: section,
                order: order,
                presentations: standardPresentations
            ),
            requiredPlatformCapabilities: [],
            capability: .universal,
            gesture: nil,
            music: nil,
            ui: UIBinding(read: uiRead, write: uiWrite, persists: true),
            settings: SettingsBinding(
                read: settingsRead,
                write: settingsWrite,
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil
            )
        )
    }

    /// Static UI scalars that previously had a ControlSpec but were excluded
    /// from the vertically integrated descriptor catalog. They remain outside
    /// automation layer stacks while sharing IDs, placement, bindings, and
    /// presentation metadata with every UI surface.
    static let presentationDescriptors: [ParameterDescriptor] = [
        staticDescriptor(
            ControlCatalog.sphericalInversionRadius,
            route: .shape(.transformations), section: "Spherical Inversion", order: 0,
            uiRead: { $0.display.sphericalInversionRadius },
            uiWrite: { cache, value in cache.display.sphericalInversionRadius = value; cache.commitSphericalInversion() },
            settingsRead: { $0.sphericalInversionRadius },
            settingsWrite: { $0.sphericalInversionRadius = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorIterations,
            route: .look(.mapping), section: "Color Detail", order: 0,
            uiRead: { $0.color.colorIterations },
            uiWrite: { cache, value in cache.color.colorIterations = value; cache.push(\.colorIterations, value: value) },
            settingsRead: { $0.colorIterations },
            settingsWrite: { $0.colorIterations = $1 }
        ),
        staticDescriptor(
            ControlCatalog.resolutionScale,
            route: .quality(.tuning), section: "Resolution", order: 0,
            uiRead: { $0.quality.resolutionScale },
            uiWrite: { cache, value in cache.quality.resolutionScale = value; cache.push(\.resolutionScale, value: value) },
            settingsRead: { $0.resolutionScale },
            settingsWrite: { $0.resolutionScale = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeContrast,
            route: .look(.grading), section: "Color Grade", order: 1,
            uiRead: { $0.color.colorSchemeContrast },
            uiWrite: { cache, value in cache.color.colorSchemeContrast = value; cache.push(\.colorSchemeContrast, value: value) },
            settingsRead: { $0.colorSchemeContrast }, settingsWrite: { $0.colorSchemeContrast = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeVibrance,
            route: .look(.grading), section: "Color Grade", order: 2,
            uiRead: { $0.color.colorSchemeVibrance },
            uiWrite: { cache, value in cache.color.colorSchemeVibrance = value; cache.push(\.colorSchemeVibrance, value: value) },
            settingsRead: { $0.colorSchemeVibrance }, settingsWrite: { $0.colorSchemeVibrance = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeCurve,
            route: .look(.grading), section: "Color Grade", order: 3,
            uiRead: { $0.color.colorSchemeCurve },
            uiWrite: { cache, value in cache.color.colorSchemeCurve = value; cache.push(\.colorSchemeCurve, value: value) },
            settingsRead: { $0.colorSchemeCurve }, settingsWrite: { $0.colorSchemeCurve = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeShadows,
            route: .look(.grading), section: "Color Grade", order: 4,
            uiRead: { $0.color.colorSchemeShadows },
            uiWrite: { cache, value in cache.color.colorSchemeShadows = value; cache.push(\.colorSchemeShadows, value: value) },
            settingsRead: { $0.colorSchemeShadows }, settingsWrite: { $0.colorSchemeShadows = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeHighlights,
            route: .look(.grading), section: "Color Grade", order: 5,
            uiRead: { $0.color.colorSchemeHighlights },
            uiWrite: { cache, value in cache.color.colorSchemeHighlights = value; cache.push(\.colorSchemeHighlights, value: value) },
            settingsRead: { $0.colorSchemeHighlights }, settingsWrite: { $0.colorSchemeHighlights = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeGamma,
            route: .look(.grading), section: "Color Grade", order: 6,
            uiRead: { $0.color.colorSchemeGamma },
            uiWrite: { cache, value in cache.color.colorSchemeGamma = value; cache.push(\.colorSchemeGamma, value: value) },
            settingsRead: { $0.colorSchemeGamma }, settingsWrite: { $0.colorSchemeGamma = $1 }
        ),
        staticDescriptor(
            ControlCatalog.lightingSoftness,
            route: .look(.grading), section: "Lighting Finish", order: 0,
            uiRead: { $0.color.lightingSoftness },
            uiWrite: { cache, value in cache.color.lightingSoftness = value; cache.push(\.lightingSoftness, value: value) },
            settingsRead: { $0.lightingSoftness }, settingsWrite: { $0.lightingSoftness = $1 }
        ),
        staticDescriptor(
            ControlCatalog.cellShadingLevels,
            route: .look(.grading), section: "Lighting Finish", order: 1,
            uiRead: { $0.color.cellShadingLevels },
            uiWrite: { cache, value in cache.color.cellShadingLevels = value; cache.push(\.cellShadingLevels, value: value) },
            settingsRead: { $0.cellShadingLevels }, settingsWrite: { $0.cellShadingLevels = $1 }
        ),
        staticDescriptor(
            ControlCatalog.aoStrength,
            route: .look(.grading), section: "Lighting Finish", order: 2,
            uiRead: { $0.color.aoStrength },
            uiWrite: { cache, value in cache.color.aoStrength = value; cache.push(\.aoStrength, value: value) },
            settingsRead: { $0.aoStrength }, settingsWrite: { $0.aoStrength = $1 }
        ),
        staticDescriptor(
            ControlCatalog.tonemapStrength,
            route: .look(.grading), section: "Lighting Finish", order: 3,
            uiRead: { $0.color.tonemapStrength },
            uiWrite: { cache, value in cache.color.tonemapStrength = value; cache.push(\.tonemapStrength, value: value) },
            settingsRead: { $0.tonemapStrength }, settingsWrite: { $0.tonemapStrength = $1 }
        ),
        staticDescriptor(
            ControlCatalog.vignetteStrength,
            route: .look(.grading), section: "Lighting Finish", order: 4,
            uiRead: { $0.color.vignetteStrength },
            uiWrite: { cache, value in cache.color.vignetteStrength = value; cache.push(\.vignetteStrength, value: value) },
            settingsRead: { $0.vignetteStrength }, settingsWrite: { $0.vignetteStrength = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeAutoInterval,
            route: .look(.motion), section: "Automatic Color", order: 0,
            uiRead: { $0.color.colorSchemeAutoInterval },
            uiWrite: { cache, value in cache.color.colorSchemeAutoInterval = value; cache.push(\.colorSchemeAutoInterval, value: value) },
            settingsRead: { $0.colorSchemeAutoInterval }, settingsWrite: { $0.colorSchemeAutoInterval = $1 }
        ),
        staticDescriptor(
            ControlCatalog.colorSchemeTransitionDuration,
            route: .look(.motion), section: "Automatic Color", order: 1,
            uiRead: { $0.color.colorSchemeTransitionDuration },
            uiWrite: { cache, value in cache.color.colorSchemeTransitionDuration = value; cache.push(\.colorSchemeTransitionDuration, value: value) },
            settingsRead: { $0.colorSchemeTransitionDuration }, settingsWrite: { $0.colorSchemeTransitionDuration = $1 }
        ),
        staticDescriptor(
            ControlCatalog.edgeStrength,
            route: .look(.grading), section: "Edge Detection", order: 0,
            uiRead: { $0.lighting.edgeDetectionEffect.strength },
            uiWrite: { cache, value in cache.lighting.edgeDetectionEffect.setStrength(value); cache.commitEdgeDetectionEffect() },
            settingsRead: { $0.edgeDetectionEffect.strength },
            settingsWrite: { settings, value in var effect = settings.edgeDetectionEffect; effect.setStrength(value); settings.edgeDetectionEffect = effect }
        ),
        staticDescriptor(
            ControlCatalog.edgeThreshold,
            route: .look(.grading), section: "Edge Detection", order: 1,
            uiRead: { $0.lighting.edgeDetectionEffect.threshold },
            uiWrite: { cache, value in cache.lighting.edgeDetectionEffect.threshold = value; cache.commitEdgeDetectionEffect() },
            settingsRead: { $0.edgeDetectionEffect.threshold },
            settingsWrite: { settings, value in var effect = settings.edgeDetectionEffect; effect.threshold = value; settings.edgeDetectionEffect = effect }
        ),
        staticDescriptor(
            ControlCatalog.edgeSoftness,
            route: .look(.grading), section: "Edge Detection", order: 2,
            uiRead: { $0.lighting.edgeDetectionEffect.softness },
            uiWrite: { cache, value in cache.lighting.edgeDetectionEffect.softness = value; cache.commitEdgeDetectionEffect() },
            settingsRead: { $0.edgeDetectionEffect.softness },
            settingsWrite: { settings, value in var effect = settings.edgeDetectionEffect; effect.softness = value; settings.edgeDetectionEffect = effect }
        ),
        staticDescriptor(
            ControlCatalog.edgeWindowRadius,
            route: .look(.grading), section: "Edge Detection", order: 3,
            uiRead: { Float($0.lighting.edgeDetectionEffect.windowRadius) },
            uiWrite: { cache, value in cache.lighting.edgeDetectionEffect.windowRadius = Int(value.rounded()); cache.commitEdgeDetectionEffect() },
            settingsRead: { Float($0.edgeDetectionEffect.windowRadius) },
            settingsWrite: { settings, value in var effect = settings.edgeDetectionEffect; effect.windowRadius = Int(value.rounded()); settings.edgeDetectionEffect = effect }
        )
    ]

    static let allDescriptors: [ParameterDescriptor] = routedDescriptors + presentationDescriptors

    static let toggleDescriptors: [ToggleDescriptor] = [
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.glow"), name: "Glow", icon: "sun.max",
            placement: .presented(route: .look(.atmosphere), section: "Lighting & Color", order: 0, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.glowEffect.enabled },
            write: { cache, value in cache.lighting.glowEffect.enabled = value; cache.commitGlowEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.bloom"), name: "Bloom", icon: "sparkles",
            placement: .presented(route: .look(.atmosphere), section: "Lighting & Color", order: 1, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.bloomEffect.enabled },
            write: { cache, value in cache.lighting.bloomEffect.enabled = value; cache.commitBloomEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.fog"), name: "Fog", icon: "cloud.fog",
            placement: .presented(route: .look(.atmosphere), section: "Lighting & Color", order: 2, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.fogEffect.enabled },
            write: { cache, value in cache.lighting.fogEffect.enabled = value; cache.commitFogEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.input.audioReactive"), name: "Audio Reactive", icon: "waveform",
            placement: .presented(route: .input(.reactive), section: "Audio", order: 0, presentations: [.fullControls, .quickToggles, .radial2D, .spatialRadial]),
            requiredPlatformCapabilities: [],
            read: { $0.audioReactive.fractalAudioReactiveEnabled },
            write: { cache, value in
                cache.audioReactive.fractalAudioReactiveEnabled = value
                cache.push(\.fractalAudioReactiveEnabled, value: value)
            }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.quality.smartAdvance"), name: "Smart Advance", icon: "bolt",
            placement: .presented(route: .quality(.tuning), section: "Performance", order: 0, presentations: [.fullControls, .quickToggles, .radial2D, .spatialRadial]),
            requiredPlatformCapabilities: [],
            read: { $0.quality.smartAdvanceEnabled },
            write: { cache, value in cache.quality.smartAdvanceEnabled = value; cache.push(\.smartAdvanceEnabled, value: value) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.quality.selfShadows"), name: "Self-Shadows", icon: "moon",
            placement: .presented(route: .quality(.tuning), section: "Performance", order: 2, presentations: [.fullControls, .quickToggles, .radial2D, .spatialRadial]),
            requiredPlatformCapabilities: [],
            read: { $0.quality.shadowsEnabled },
            write: { cache, value in cache.quality.shadowsEnabled = value; cache.push(\.shadowsEnabled, value: value) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.formula.polarRotation"), name: "Polar Rotation", icon: AppIcons.arrowTriangleheadCounterclockwiseRotate90,
            placement: .presented(route: .look(.motion), section: "Formula", order: 0, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            isAvailable: { $0.fractalType.supports(.polarRotation) },
            read: { $0.lighting.polarRotationEffect.enabled },
            write: { cache, value in cache.lighting.polarRotationEffect.enabled = value; cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.formula.juliaDrift"), name: "Julia Drift", icon: "wind",
            placement: .presented(route: .look(.motion), section: "Formula", order: 1, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            isAvailable: { $0.fractalType.supports(.juliaDrift) },
            read: { $0.lighting.juliaDriftEffect.enabled },
            write: { cache, value in cache.lighting.juliaDriftEffect.enabled = value; cache.commitJuliaDriftEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.hueRotation"), name: "Hue Rotation", icon: "paintpalette",
            placement: .presented(route: .look(.motion), section: "Lighting & Color", order: 3, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.hueRotationEffect.enabled },
            write: { cache, value in cache.lighting.hueRotationEffect.enabled = value; cache.commitHueRotationEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.pulse"), name: "Pulse", icon: "waveform.path.ecg",
            placement: .presented(route: .look(.motion), section: "Lighting & Color", order: 4, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.pulseEffect.enabled },
            write: { cache, value in cache.lighting.pulseEffect.enabled = value; cache.commitPulseEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.gradientCycle"), name: "Gradient Cycle", icon: "circle.hexagongrid",
            placement: .presented(route: .look(.motion), section: "Lighting & Color", order: 5, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.gradientCycleEffect.enabled },
            write: { cache, value in cache.lighting.gradientCycleEffect.enabled = value; cache.commitGradientCycleEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.linearRail"), name: "Linear Rail", icon: "slider.horizontal.below.rectangle",
            placement: .presented(route: .look(.motion), section: "Lighting & Color", order: 6, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.linearRailEffect.enabled },
            write: { cache, value in cache.lighting.linearRailEffect.enabled = value; cache.commitLinearRailEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.space.sphereProjection"), name: "Sphere Projection", icon: "globe.asia.australia",
            placement: .presented(route: .shape(.transformations), section: "Space", order: 0, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            isAvailable: { $0.fractalType.supports(.sphereProjection) },
            read: { $0.display.sphereProjectionEnabled },
            write: { cache, value in cache.display.sphereProjectionEnabled = value; cache.commitSphereProjection() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.space.boundToSpace"), name: "Bound to Space", icon: "house",
            placement: .presented(route: .shape(.bounding), section: "Space", order: 1, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.quality.boundToSpaceEnabled },
            write: { $0.setBoundToSpaceEnabled($1) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.space.boundingShape"), name: "Bounding Shape", icon: "circle.dashed",
            placement: .presented(route: .shape(.bounding), section: "Space", order: 2, presentations: [.fullControls, .quickToggles, .radial2D, .spatialRadial]),
            requiredPlatformCapabilities: [],
            read: { $0.quality.boundingSphereSkipEnabled },
            write: { $0.setBoundingShapeEnabled($1) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.space.surroundings"), name: "Surroundings", icon: "square.3.layers.3d",
            placement: .presented(route: .shape(.bounding), section: "Space", order: 3, presentations: [.fullControls, .quickToggles, .spatialRadial]),
            requiredPlatformCapabilities: [.spatialMenu],
            read: { $0.quality.envScrunchEnabled },
            write: { $0.setScrunchEnabled($1) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.effect.beatFlash"), name: "Beat Flash", icon: "bolt",
            placement: .presented(route: .look(.motion), section: "Audio", order: 1, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.lighting.beatFlashEffect.enabled },
            write: { cache, value in cache.lighting.beatFlashEffect.enabled = value; cache.commitBeatFlashEffect() }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.audio.bass"), name: "Bass", icon: "speaker.wave.1",
            placement: .presented(route: .input(.reactive), section: "Audio", order: 2, presentations: [.quickToggles]),
            requiredPlatformCapabilities: [],
            isAvailable: { $0.audioReactive.fractalAudioReactiveEnabled },
            read: { $0.audioReactive.bassSensitivity > 0 },
            write: { cache, value in cache.audioReactive.bassSensitivity = value ? 1 : 0; cache.push(\.bassSensitivity, value: value ? 1 : 0) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.audio.mid"), name: "Mid", icon: "speaker.wave.2",
            placement: .presented(route: .input(.reactive), section: "Audio", order: 3, presentations: [.quickToggles]),
            requiredPlatformCapabilities: [],
            isAvailable: { $0.audioReactive.fractalAudioReactiveEnabled },
            read: { $0.audioReactive.midSensitivity > 0 },
            write: { cache, value in cache.audioReactive.midSensitivity = value ? 1 : 0; cache.push(\.midSensitivity, value: value ? 1 : 0) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.audio.treble"), name: "Treble", icon: "speaker.wave.3",
            placement: .presented(route: .input(.reactive), section: "Audio", order: 4, presentations: [.quickToggles]),
            requiredPlatformCapabilities: [],
            isAvailable: { $0.audioReactive.fractalAudioReactiveEnabled },
            read: { $0.audioReactive.trebleSensitivity > 0 },
            write: { cache, value in cache.audioReactive.trebleSensitivity = value ? 1 : 0; cache.push(\.trebleSensitivity, value: value ? 1 : 0) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.audio.beat"), name: "Beat", icon: "metronome",
            placement: .presented(route: .input(.reactive), section: "Audio", order: 5, presentations: [.quickToggles]),
            requiredPlatformCapabilities: [],
            isAvailable: { $0.audioReactive.fractalAudioReactiveEnabled },
            read: { $0.audioReactive.beatSensitivity > 0 },
            write: { cache, value in cache.audioReactive.beatSensitivity = value ? 1 : 0; cache.push(\.beatSensitivity, value: value ? 1 : 0) }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.quality.coherentPacket"), name: "Coherent Packet", icon: "square.grid.3x3",
            placement: .presented(route: .quality(.tuning), section: "Performance", order: 1, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.renderSettings?.coherentPacketEnabled ?? false },
            write: { $0.renderSettings?.coherentPacketEnabled = $1 }
        ),
        ToggleDescriptor(
            controlID: ControlID("toggle.quality.zoomFog"), name: "Zoom Fog Comp", icon: "cloud.fog",
            placement: .presented(route: .quality(.tuning), section: "Performance", order: 3, presentations: [.fullControls, .quickToggles, .radial2D]),
            requiredPlatformCapabilities: [],
            read: { $0.quality.zoomFogCompensationEnabled },
            write: { cache, value in cache.quality.zoomFogCompensationEnabled = value; cache.push(\.zoomFogCompensationEnabled, value: value) }
        )
    ]

    static let actionDescriptors: [ActionDescriptor] = [
        ActionDescriptor(
            controlID: ControlID("action.viewport.reset"), name: "Reset View", icon: "arrow.counterclockwise",
            placement: .presented(route: .shape(.space), section: "Viewport", order: 0, presentations: [.fullControls, .radial2D, .spatialRadial]),
            requiredPlatformCapabilities: [], command: .resetViewport
        ),
        ActionDescriptor(
            controlID: ControlID("action.animation.editor"), name: "Animation Editor", icon: AppIcons.pencilAndListClipboard,
            placement: .presented(route: .animationLibrary, section: "Animation", order: 0, presentations: [.fullControls, .radial2D, .spatialRadial, .controlFinder]),
            requiredPlatformCapabilities: [], command: .openAnimationEditor
        )
    ]

    static let semanticDescriptors: [SemanticControlDescriptor] =
        allDescriptors.map(SemanticControlDescriptor.scalar)
        + toggleDescriptors.map(SemanticControlDescriptor.toggle)
        + actionDescriptors.map(SemanticControlDescriptor.action)

    static let semanticByID: [ControlID: SemanticControlDescriptor] =
        Dictionary(uniqueKeysWithValues: semanticDescriptors.map { ($0.id, $0) })

    /// Routed descriptors keyed by id.
    static let byID: [String: ParameterDescriptor] =
        Dictionary(uniqueKeysWithValues: routedDescriptors.map { ($0.id, $0) })

    static let allByID: [String: ParameterDescriptor] =
        Dictionary(uniqueKeysWithValues: allDescriptors.map { ($0.id, $0) })

    /// Narrowed off-main projection: the dispatch path looks up ONLY the `@Sendable`
    /// settings pair, never the full descriptor (which carries the @MainActor ui pair).
    static func settingsBinding(for id: String) -> SettingsBinding? { byID[id]?.settings }
}
