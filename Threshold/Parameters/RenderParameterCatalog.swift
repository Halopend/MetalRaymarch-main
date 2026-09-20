import Foundation

/// Engine bindings are independent of controls, navigation and application state.
struct SettingsBinding: Sendable {
    let read: @Sendable (RenderSettings) -> Float
    let write: @Sendable (RenderSettings, Float) -> Void
    /// During animation playback `applyKeyframe` owns the backing var, so the absolute
    /// `write` would be stomped — the dispatcher deposits the pure music delta here
    /// instead. nil → not keyframe-driven.
    let writeAudioOffset: (@Sendable (RenderSettings, Float) -> Void)?
    let audioOffsetActiveDuringPlayback: (@Sendable (RenderSettings) -> Bool)?
    let writeManualBase: (@Sendable (RenderSettings, Float) -> Void)?

    init(read: @escaping @Sendable (RenderSettings) -> Float,
         write: @escaping @Sendable (RenderSettings, Float) -> Void,
         writeAudioOffset: (@Sendable (RenderSettings, Float) -> Void)?,
         audioOffsetActiveDuringPlayback: (@Sendable (RenderSettings) -> Bool)?,
         writeManualBase: (@Sendable (RenderSettings, Float) -> Void)? = nil) {
        self.read = read
        self.write = write
        self.writeAudioOffset = writeAudioOffset
        self.audioOffsetActiveDuringPlayback = audioOffsetActiveDuringPlayback
        self.writeManualBase = writeManualBase
    }
}

struct MusicFacet: Sendable {
    let category: MusicReactiveTargetCategory
    let defaultSource: MusicReactiveSource
    let defaultResponseCurve: ResponseCurve
    let hasFlashingRisk: Bool
}

struct RenderParameterDescriptor: Sendable, Identifiable {
    let spec: ControlSpec
    let music: MusicFacet?
    let settings: SettingsBinding
    var id: String { spec.id }
    func clamp(_ value: Float) -> Float { spec.clamp(value) }
}

/// The single runtime binding table used by live rendering AND Quick Look.
/// ParameterCatalog adds presentation/UI facets to these same bindings.
enum RenderParameterCatalog {
    static let descriptors: [RenderParameterDescriptor] = [
        RenderParameterDescriptor(
            spec: ControlCatalog.fractalScale,
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .sinusoidal, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { $0.targetFractalScale },
                write: { settings, value in settings.targetFractalScale = value },
                writeAudioOffset: { settings, offset in settings.audioOffsetFractalScale = offset },
                audioOffsetActiveDuringPlayback: { _ in true },
                writeManualBase: { settings, value in settings.manualOffsetFractalScale = value - settings.animationBaseFractalScale })),

        RenderParameterDescriptor(
            spec: ControlCatalog.colorMix,
            music: MusicFacet(category: .color, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { $0.colorMix },
                write: { settings, value in settings.colorMix = value },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.iterations,
            music: MusicFacet(category: .geometry, defaultSource: .mid, defaultResponseCurve: .sinusoidal, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { Float($0.fractalIterations) },
                write: { settings, value in settings.fractalIterations = max(2, min(24, Int(round(value)))) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.glow,
            music: MusicFacet(category: .light, defaultSource: .beat, defaultResponseCurve: .pulse, hasFlashingRisk: true),
            settings: SettingsBinding(
                read: { $0.glowEffect.intensity },
                write: { settings, value in settings.audioModulateGlowIntensity(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetGlowIntensity = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesGlow },
                writeManualBase: { settings, value in settings.manualOffsetGlowIntensity = value - settings.animationBaseGlowIntensity })),

        RenderParameterDescriptor(
            spec: ControlCatalog.fog,
            music: MusicFacet(category: .light, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { $0.fogEffect.intensity },
                write: { settings, value in settings.audioModulateFogIntensity(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetFogIntensity = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesFog },
                writeManualBase: { settings, value in settings.manualOffsetFogIntensity = value - settings.animationBaseFogIntensity })),

        RenderParameterDescriptor(
            spec: ControlCatalog.bloom,
            music: MusicFacet(category: .light, defaultSource: .beat, defaultResponseCurve: .pulse, hasFlashingRisk: true),
            settings: SettingsBinding(
                read: { $0.bloomEffect.strength },
                write: { settings, value in settings.audioModulateBloomStrength(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetBloomStrength = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesBloom },
                writeManualBase: { settings, value in settings.manualOffsetBloomStrength = value - settings.animationBaseBloomStrength })),

        RenderParameterDescriptor(
            spec: ControlCatalog.hueSpeed,
            music: MusicFacet(category: .color, defaultSource: .treble, defaultResponseCurve: .drift, hasFlashingRisk: true),
            settings: SettingsBinding(
                read: { $0.hueRotationEffect.speed },
                write: { settings, value in settings.audioModulateHueSpeed(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetHueSpeed = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesHueSpeed },
                writeManualBase: { settings, value in settings.manualOffsetHueSpeed = value - settings.animationBaseHueSpeed })),

        RenderParameterDescriptor(
            spec: ControlCatalog.saturation,
            music: MusicFacet(category: .color, defaultSource: .mid, defaultResponseCurve: .drift, hasFlashingRisk: true),
            settings: SettingsBinding(
                read: { $0.colorSchemeSaturation },
                write: { settings, value in settings.audioModulateSaturation(value) },
                writeAudioOffset: { settings, offset in settings.audioOffsetSaturation = offset },
                audioOffsetActiveDuringPlayback: { $0.sceneDrivesSaturation },
                writeManualBase: { settings, value in settings.manualOffsetSaturation = value - settings.animationBaseSaturation })),

        RenderParameterDescriptor(
            spec: ControlCatalog.safetyBubbleRadius,
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { $0.safetyBubbleRadius },
                write: { settings, value in settings.audioModulateSafetyBubbleRadius(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.gradientOffset,
            music: MusicFacet(category: .color, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { $0.gradientOffset },
                write: { settings, value in settings.audioModulateGradientOffset(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.sphereProjectionBlend,
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { $0.sphereProjectionBlend },
                write: { settings, value in settings.audioModulateSphereProjectionBlend(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.sphereProjectionRadius,
            music: MusicFacet(category: .geometry, defaultSource: .bass, defaultResponseCurve: .drift, hasFlashingRisk: false),
            settings: SettingsBinding(
                read: { $0.sphereProjectionRadius },
                write: { settings, value in settings.audioModulateSphereProjectionRadius(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.spaceWarpStrength,
            music: nil,
            settings: SettingsBinding(
                read: { $0.spaceWarpStrength },
                write: { settings, value in settings.audioModulateSpaceWarpStrength(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.spaceWarpOriginX,
            music: nil,
            settings: SettingsBinding(
                read: { $0.spaceWarpParam1 },
                write: { settings, value in settings.audioModulateSpaceWarpOriginX(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.spaceWarpOriginY,
            music: nil,
            settings: SettingsBinding(
                read: { $0.spaceWarpParam2 },
                write: { settings, value in settings.audioModulateSpaceWarpOriginY(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),

        RenderParameterDescriptor(
            spec: ControlCatalog.spaceWarpOriginZ,
            music: nil,
            settings: SettingsBinding(
                read: { $0.spaceWarpParam3 },
                write: { settings, value in settings.audioModulateSpaceWarpOriginZ(value) },
                writeAudioOffset: nil,
                audioOffsetActiveDuringPlayback: nil)),
    ]
    static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
}
