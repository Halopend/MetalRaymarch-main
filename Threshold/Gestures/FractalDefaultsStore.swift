//
//  FractalDefaultsStore.swift
//  Threshold
//
//  Per-fractal-type parameter snapshot persistence.
//  Extracted from GestureController as part of Phase 6 decomposition.
//

import Foundation
import simd

private let customFractalDefaultsKey = "customFractalDefaults.v1"

// MARK: - Stored Fractal Defaults

/// Codable snapshot of per-fractal-type parameter defaults.
struct StoredFractalDefaults: Codable {
    var minDistance: Float
    var foldingLimit: Float
    var sphereRadius: Float
    var fractalScale: Float
    var formulaParamsData: Data
    var detailScale: Float
    var position: [Float]
    var worldRotation: [Float]
    var safetyBubbleEnabled: Bool?
}

// MARK: - FractalDefaultsStore

/// Manages loading, saving, and applying per-fractal-type parameter defaults.
@MainActor
enum FractalDefaultsStore {

    // MARK: - FormulaParams Serialization

    static func serializeFormulaParams(_ formulaParams: FormulaParams) -> Data {
        var copy = formulaParams
        return withUnsafeBytes(of: &copy) { Data($0) }
    }

    static func deserializeFormulaParams(_ data: Data) -> FormulaParams? {
        let size = MemoryLayout<FormulaParams>.size
        guard data.count == size else { return nil }
        var formulaParams = FormulaParams()
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(&formulaParams, baseAddress, size)
        }
        FormulaCatalog.normalizeRotationFlags(&formulaParams)
        return formulaParams
    }

    // MARK: - Defaults Map I/O

    static func loadStoredDefaultsMap() -> [String: StoredFractalDefaults] {
        guard let data = UserDefaults.standard.data(forKey: customFractalDefaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredFractalDefaults].self, from: data)) ?? [:]
    }

    static func saveStoredDefaultsMap(_ defaultsMap: [String: StoredFractalDefaults]) {
        guard let data = try? JSONEncoder().encode(defaultsMap) else { return }
        UserDefaults.standard.set(data, forKey: customFractalDefaultsKey)
    }

    // MARK: - Factory Defaults

    /// Create factory defaults for a fractal type using its descriptor.
    static func makeFactoryDefaults(for fractalType: FractalModelType) -> StoredFractalDefaults {
        let desc = FractalTypeRegistry.descriptor(for: fractalType)
        var formulaParams = desc.defaultFormulaParams()
        let viewState = desc.defaultViewState
        let shape = desc.defaultShapeParams

        FormulaCatalog.normalizeRotationFlags(&formulaParams)
        return StoredFractalDefaults(
            minDistance: shape.minDistance,
            foldingLimit: shape.foldingLimit,
            sphereRadius: shape.sphereRadius,
            fractalScale: shape.fractalScale,
            formulaParamsData: serializeFormulaParams(formulaParams),
            detailScale: viewState.detailScale,
            position: [viewState.position.x, viewState.position.y, viewState.position.z],
            worldRotation: [viewState.rotation.vector.x, viewState.rotation.vector.y, viewState.rotation.vector.z, viewState.rotation.vector.w],
            safetyBubbleEnabled: viewState.safetyBubbleEnabled
        )
    }

    // MARK: - Apply / Save

    /// Apply stored defaults to a RenderSettings instance.
    static func applyStoredDefaults(_ stored: StoredFractalDefaults, to settings: RenderSettings) {
        settings.targetMinDistance = stored.minDistance
        settings.targetFoldingLimit = stored.foldingLimit
        settings.targetSphereRadius = stored.sphereRadius
        settings.targetFractalScale = stored.fractalScale

        settings.minDistance = stored.minDistance
        settings.foldingLimit = stored.foldingLimit
        settings.sphereRadius = stored.sphereRadius
        settings.fractalScale = stored.fractalScale

        if let formulaParams = deserializeFormulaParams(stored.formulaParamsData) {
            settings.formulaParams = formulaParams
        }

        if stored.position.count == 3 {
            let position = SIMD3<Float>(stored.position[0], stored.position[1], stored.position[2])
            settings.position = position
            settings.targetPosition = position
        }

        if stored.worldRotation.count == 4 {
            let rotation = simd_quatf(ix: stored.worldRotation[0],
                                      iy: stored.worldRotation[1],
                                      iz: stored.worldRotation[2],
                                      r: stored.worldRotation[3]).normalized
            settings.worldRotation = rotation
            settings.targetWorldRotation = rotation
        }

        settings.detailScale = stored.detailScale
        settings.targetDetailScale = stored.detailScale

        if let safetyBubbleEnabled = stored.safetyBubbleEnabled {
            settings.safetyBubbleEnabled = safetyBubbleEnabled
        }
    }

    /// Capture the current state of settings as stored defaults for the active fractal type.
    @discardableResult
    static func saveCurrentAsFractalDefaults(from settings: RenderSettings) -> Bool {
        let fractalType = settings.fractalType
        let stored = StoredFractalDefaults(
            minDistance: settings.minDistance,
            foldingLimit: settings.foldingLimit,
            sphereRadius: settings.sphereRadius,
            fractalScale: settings.fractalScale,
            formulaParamsData: serializeFormulaParams(settings.formulaParams),
            detailScale: settings.detailScale,
            position: [settings.position.x, settings.position.y, settings.position.z],
            worldRotation: [settings.worldRotation.vector.x,
                            settings.worldRotation.vector.y,
                            settings.worldRotation.vector.z,
                            settings.worldRotation.vector.w],
            safetyBubbleEnabled: settings.safetyBubbleEnabled
        )

        var defaultsMap = loadStoredDefaultsMap()
        defaultsMap[String(fractalType.rawValue)] = stored
        saveStoredDefaultsMap(defaultsMap)
        return true
    }

    /// Load stored defaults (or factory defaults) for a fractal type and apply them.
    static func applyFractalDefaults(for fractalType: FractalModelType, to settings: RenderSettings) {
        let defaultsMap = loadStoredDefaultsMap()
        let stored = defaultsMap[String(fractalType.rawValue)]
            ?? makeFactoryDefaults(for: fractalType)
        applyStoredDefaults(stored, to: settings)
    }
}
