import Foundation

// LOCAL STUB for PresetManager members referenced by EmbeddedFormula.swift.
// The real PresetManager (Parameters/PresetManager.swift) `import SwiftUI`s and
// pulls in the app UI. The headless tool only needs two pure helpers, copied
// verbatim below, so we avoid the whole SwiftUI dependency.

enum ThresholdExportFormat: CaseIterable, Sendable {
    case scenePreset
    case musicPreset
    case animationScene
    case musicVideoScene
    case customFormula

    var ext: String {
        switch self {
        case .scenePreset: return "threshscene"
        case .musicPreset: return "threshmp"
        case .animationScene: return "threshanim"
        case .musicVideoScene: return "threshanimv"
        case .customFormula: return "threshfx"
        }
    }
}

enum PresetManager {
    nonisolated static func sanitizedExportFileNameStem(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r")
        let cleaned = name.components(separatedBy: invalid).joined()
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(64))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOCAL STUBS for the parameter-catalog / node-registry surface.
//
// The real ParameterCatalog.swift and ParameterNodeSystem.swift transitively
// require UISettingsCache, which `import SwiftUI`s and drags in AppModel /
// ParameterPipeline / GestureController — none of which the still-frame render
// path (preset.apply → snapshot → packUniforms) ever executes. RenderSettings
// only references `ParameterCatalog.byID` (in `audioModulate`, never called
// here) and FingerGestureAction references `ParameterNodeRegistry.shared`
// (in `bindableActions`, also never called here). So we provide minimal,
// empty, correctly-typed stand-ins purely to satisfy the type checker.

struct SettingsBinding: Sendable {
    let read: @Sendable (RenderSettings) -> Float
    let write: @Sendable (RenderSettings, Float) -> Void
    let writeAudioOffset: (@Sendable (RenderSettings, Float) -> Void)?
    let audioOffsetActiveDuringPlayback: (@Sendable (RenderSettings) -> Bool)?
}

struct MusicFacet: Sendable {
    let category: MusicReactiveTargetCategory
    let defaultSource: MusicReactiveSource
    let defaultResponseCurve: ResponseCurve
    let hasFlashingRisk: Bool
}

struct ParameterDescriptor: Sendable, Identifiable {
    let spec: ControlSpec
    let settings: SettingsBinding
    let music: MusicFacet?
    var id: String { spec.id }
    func clamp(_ value: Float) -> Float { spec.clamp(value) }
}

enum ParameterCatalog {
    // Empty: audioModulate() (the only reader) is never invoked by the headless
    // render path, so no descriptors need to be authored here.
    static let byID: [String: ParameterDescriptor] = [:]
    // Referenced only by ParameterTargetID.coreAndEffect (a static shim) and
    // ParameterRoutingValidation.validateStartupRouting() — neither runs here.
    static let routedDescriptors: [ParameterDescriptor] = []
}

// Minimal stand-in for the node type keyed in coreNodes/effectNodes; only
// `.range` is ever read, and only inside validateStartupRouting (never called).
final class FloatParameterNode: @unchecked Sendable {
    let range: ClosedRange<Float> = 0...1
}

final class ParameterNodeRegistry: @unchecked Sendable {
    static let shared = ParameterNodeRegistry()
    let coreNodes: [String: FloatParameterNode] = [:]
    let effectNodes: [String: FloatParameterNode] = [:]
    func gestureBindableParameters(for type: FractalModelType) -> [GestureBindableParameter] { [] }
    func gestureBindableTriplets(for type: FractalModelType) -> [GestureBindableTriplet] { [] }
    func gestureBindableCoreParameters(for type: FractalModelType) -> [GestureBindableParameter] { [] }
}

// LOCAL STUB: ParameterMotionStrategy lives in the excluded ParameterNodeSystem.swift
// but is referenced by ControlSpec.swift. Verbatim copy of the plain enum.
enum ParameterMotionStrategy: String, Codable, Sendable {
    case none
    case layerLerp
    case smoothDamp
}

// LOCAL STUB: PerFingerTapAction lives in Gestures/PerFingerTapGestureEngine.swift,
// which drags in the live gesture engine (GestureContext / GestureOperation /
// HandData). GestureConfig/GestureDefaults only need the plain enum cases; the
// `isMenuEssentialAction` extension in FingerGestureAction.swift only touches
// .toggleMenu/.openShapeMenu/.openRenderMenu (all present). Verbatim case list.
enum PerFingerTapAction: Int32, CaseIterable, Codable, Hashable, Sendable {
    case none         = 0
    case toggleMenu   = 1
    case toggleAnimationPlayer = 2
    case openShapeMenu = 3
    case openRenderMenu = 4
    case openQuickToggles = 5
}
