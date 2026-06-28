//
//  ParameterCatalog.swift
//  Threshold
//
//  Slice 1 of the parameter-node hierarchy migration
//  (Context/PARAMETER_NODE_HIERARCHY_DESIGN.md).
//
//  Authors ONE `ParameterDescriptor` per routed core/effect/space control,
//  co-locating the metadata that today lives in 6 parallel registries kept in
//  lockstep by a runtime tripwire:
//    • ControlSpec/ControlCatalog        — range/default/name/icon/motion
//    • ParameterTargetID.coreAndEffect   — the routed id list
//    • ParameterOperationDispatcher.coreDescriptors — off-main RenderSettings binding
//    • buildCoreAndEffectNodes           — @MainActor UISettingsCache binding + gesture flag
//    • MusicReactiveTarget switches       — music defaults (category/source/curve/flashing)
//
//  In Slice 1 this catalog merely COEXISTS: nothing reads it yet. A DEBUG golden
//  net in `validateStartupRouting` proves every descriptor equals its live source
//  before any later slice makes a registry DERIVE from the catalog. The descriptor
//  is a non-Codable runtime facade (like FractalTypeDescriptor over FractalModelType)
//  and is never serialized.
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
/// `UISettingsCache`; only ever invoked on the cache dispatch path.
struct UIBinding: Sendable {
    let read: @MainActor @Sendable (UISettingsCache) -> Float
    let write: @MainActor @Sendable (UISettingsCache, Float) -> Void
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

/// UI placement. Unused in Slice 1 (route is nil everywhere); a later slice activates
/// data-driven section rendering from it.
struct ParameterRoute: Sendable {
    let tab: String
    let section: String
    let order: Int
}

/// The vertically-integrated node: authored metadata (via `spec`) + routing +
/// capability + gesture + music + both binding pairs. Non-Codable; never serialized.
/// Intentionally NON-Equatable (holds closures); `spec` stays Equatable for the
/// validator's range checks.
struct ParameterDescriptor: Sendable, Identifiable {
    let spec: ControlSpec
    let route: ParameterRoute?
    let capability: ParameterCapability
    let gesture: GestureFacet?
    let music: MusicFacet?
    let ui: UIBinding
    let settings: SettingsBinding

    var id: String { spec.id }
    func clamp(_ value: Float) -> Float { spec.clamp(value) }
}

// MARK: - The authored catalog

/// The single authored surface for routed core/effect/space controls. Declaration
/// order matches `ControlCatalog.allSpecs` / `ParameterTargetID.coreAndEffect`.
enum ParameterCatalog {

    static let routedDescriptors: [ParameterDescriptor] = [

        // MARK: Core geometry

        ParameterDescriptor(
            spec: ControlCatalog.fractalScale,
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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

        // MARK: Space transforms (cross-fractal)

        ParameterDescriptor(
            spec: ControlCatalog.sphereProjectionBlend,
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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
            route: nil,
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

    /// Routed descriptors keyed by id.
    static let byID: [String: ParameterDescriptor] =
        Dictionary(uniqueKeysWithValues: routedDescriptors.map { ($0.id, $0) })

    /// Routed + (future) unrouted long-tail. Identical to `routedDescriptors` today.
    static let allDescriptors: [ParameterDescriptor] = routedDescriptors

    /// Narrowed off-main projection: the dispatch path looks up ONLY the `@Sendable`
    /// settings pair, never the full descriptor (which carries the @MainActor ui pair).
    static func settingsBinding(for id: String) -> SettingsBinding? { byID[id]?.settings }
}
