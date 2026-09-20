import Foundation

// LOCAL STUB for PresetManager members referenced by EmbeddedFormula.swift.
// The real PresetManager (Parameters/PresetManager.swift) `import SwiftUI`s and
// pulls in the app UI. The headless tool only needs two pure helpers, copied
// verbatim below, so we avoid the whole SwiftUI dependency.

enum ThresholdExportFormat: CaseIterable, Sendable {
    case scenePreset
    case animationScene
    case customFormula

    var ext: String {
        switch self {
        case .scenePreset: return "thresh"
        case .animationScene: return "threshanim"
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

// UI-only gesture registry stand-ins. Runtime parameter bindings and music
// metadata are the real RenderParameterCatalog shared with the application.

// Minimal stand-in for the node type keyed in coreNodes/effectNodes.
final class FloatParameterNode: @unchecked Sendable {
    let range: ClosedRange<Float> = 0...1
}

// Minimal stand-in for the per-fractal formula node batch consumed by the
// formula-range tripwire in validateStartupRouting (never called in QL).
struct ParameterNodeBatch {
    let floatNodeByFormulaIndex: [Int: FloatParameterNode] = [:]
}

final class ParameterNodeRegistry: @unchecked Sendable {
    static let shared = ParameterNodeRegistry()
    let coreNodes: [String: FloatParameterNode] = [:]
    let effectNodes: [String: FloatParameterNode] = [:]
    func formulaBatch(for type: FractalModelType) -> ParameterNodeBatch { ParameterNodeBatch() }
    func gestureBindableParameters(for type: FractalModelType) -> [GestureBindableParameter] { [] }
    func gestureBindableTriplets(for type: FractalModelType) -> [GestureBindableTriplet] { [] }
    func gestureBindableCoreParameters(for type: FractalModelType) -> [GestureBindableParameter] { [] }
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
