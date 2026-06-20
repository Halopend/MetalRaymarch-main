//
//  FormulaCatalog.swift
//  Threshold
//
//  Loads formula metadata from catalog.json and builds FormulaParams.
//

import Foundation
import simd

// MARK: - Catalog Models

/// Metadata for a single adjustable parameter within a formula.
struct FormulaParamDescriptor: Codable, Identifiable {
    let index: Int
    let name: String
    let `default`: Float
    let min: Float
    let max: Float
    let step: Float
    var isBool: Bool?
    var isHidden: Bool?
    
    var id: String { "\(index)-\(name)" }
}

/// Full description of a fractal formula loaded from the catalog.
struct FormulaDescriptor: Codable, Identifiable {
    let id: String
    let name: String
    let fractalType: Int32
    let category: String
    let description: String
    let params: [FormulaParamDescriptor]
    /// Name(s) of the mathematician or artist who originated or popularized this formula.
    var author: String?
}

private struct CatalogRoot: Codable {
    let version: Int
    let formulas: [FormulaDescriptor]
}

// MARK: - FormulaCatalog

/// Thread-safe, lazily-loaded formula catalog. Reads `Formulas/catalog.json` from the bundle.
final class FormulaCatalog: @unchecked Sendable {
    
    static let shared = FormulaCatalog()
    private static let rot1NonIdentityFlag: UInt32 = UInt32(FormulaRotationFlagRot1NonIdentity)
    private static let rot2NonIdentityFlag: UInt32 = UInt32(FormulaRotationFlagRot2NonIdentity)
    
    /// All formula descriptors in declaration order.
    private(set) var formulas: [FormulaDescriptor] = []
    
    /// Lookup by `FractalModelType.rawValue`.
    private var byType: [Int32: FormulaDescriptor] = [:]
    
    /// Lookup by string id (e.g. "mandelbulb").
    private var byId: [String: FormulaDescriptor] = [:]    
    /// Lookup by category (prebuilt index for O(1) access).
    private var byCategory: [String: [FormulaDescriptor]] = [:]
    
    /// Ordered unique category names.
    private(set) var categories: [String] = []    
    private init() {
        load()
    }
    
    // MARK: - Loading
    
    private func load() {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Formulas") ??
                Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            print("[FormulaCatalog] catalog.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let root = try JSONDecoder().decode(CatalogRoot.self, from: data)
            self.formulas = root.formulas
            var catOrder: [String] = []
            var catSeen = Set<String>()
            for f in root.formulas {
                byType[f.fractalType] = f
                byId[f.id] = f
                byCategory[f.category, default: []].append(f)
                if catSeen.insert(f.category).inserted { catOrder.append(f.category) }
            }
            self.categories = catOrder
        } catch {
            print("[FormulaCatalog] Failed to decode catalog.json: \(error)")
        }
    }
    
    // MARK: - Queries
    
    /// Descriptor for a given `FractalModelType`.
    func descriptor(for type: FractalModelType) -> FormulaDescriptor? {
        byType[type.rawValue]
    }
    
    /// Unique category names in declaration order (prebuilt at load time).

    // MARK: - FormulaParams Builder
    
    /// Build a `FormulaParams` from an array of `(paramIndex, value)` overrides.
    /// Missing params get their catalog default. Falls back to `FractalModelType.defaultFormulaParams()`.
    func buildParams(for type: FractalModelType, overrides: [(Int, Float)] = []) -> FormulaParams {
        guard let desc = byType[type.rawValue] else {
            return type.defaultFormulaParams()
        }
        
        var fp = FormulaParams()
        fp.rotMatrix1 = matrix_identity_float3x3
        fp.rotMatrix2 = matrix_identity_float3x3
        fp.params = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
        
        // Apply catalog defaults
        for p in desc.params {
            setParam(&fp, index: p.index, value: p.`default`)
        }
        
        // Apply overrides
        for (idx, val) in overrides {
            setParam(&fp, index: idx, value: val)
        }

        Self.normalizeRotationFlags(&fp)
        
        return fp
    }

    // MARK: - Param Accessors

    /// Precompute matrix identity flags once on CPU so shader hot loops can avoid
    /// per-call epsilon identity checks.
    @inline(__always)
    private static func isIdentityRotation3(_ m: simd_float3x3, epsilon: Float = 1e-6) -> Bool {
        abs(m.columns.0.x - 1.0) <= epsilon &&
        abs(m.columns.0.y) <= epsilon &&
        abs(m.columns.0.z) <= epsilon &&
        abs(m.columns.1.x) <= epsilon &&
        abs(m.columns.1.y - 1.0) <= epsilon &&
        abs(m.columns.1.z) <= epsilon &&
        abs(m.columns.2.x) <= epsilon &&
        abs(m.columns.2.y) <= epsilon &&
        abs(m.columns.2.z - 1.0) <= epsilon
    }

    static func normalizeRotationFlags(_ fp: inout FormulaParams) {
        var flags: UInt32 = 0
        if !isIdentityRotation3(fp.rotMatrix1) {
            flags |= rot1NonIdentityFlag
        }
        if !isIdentityRotation3(fp.rotMatrix2) {
            flags |= rot2NonIdentityFlag
        }
        fp.rotationFlags = flags
    }
    
    /// Read a single param from FormulaParams by slot index (0-15).
    static func getParam(_ fp: FormulaParams, index: Int) -> Float {
        withUnsafePointer(to: fp.params) { ptr in
            let base = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
            guard index >= 0 && index < 16 else { return 0 }
            return base[index]
        }
    }
    
    /// Write a single param into FormulaParams by slot index (0-15).
    static func setParam(_ fp: inout FormulaParams, index: Int, value: Float) {
        withUnsafeMutablePointer(to: &fp.params) { ptr in
            let base = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Float.self)
            guard index >= 0 && index < 16 else { return }
            base[index] = value
        }
    }
    
    /// Convenience instance wrapper.
    private func setParam(_ fp: inout FormulaParams, index: Int, value: Float) {
        Self.setParam(&fp, index: index, value: value)
    }

    // MARK: - Ephemeral (custom) formula registration

    /// Register a formula descriptor at runtime under `FractalModelType.custom`.
    /// Replaces any previously-registered ephemeral formula. Thread-safe.
    func registerEphemeral(_ formula: EmbeddedFormula) {
        let descriptor = FormulaDescriptor(
            id: formula.id,
            name: formula.name,
            fractalType: FractalModelType.custom.rawValue,
            category: formula.category ?? "Custom",
            description: formula.formulaDescription ?? "",
            params: formula.params,
            author: formula.author
        )
        // Mutate caches under serial access. `FormulaCatalog` is otherwise read-only
        // after `init`, so we just synchronize through a private NSLock.
        Self.ephemeralLock.lock()
        defer { Self.ephemeralLock.unlock() }

        // Drop any previous custom registration first.
        unregisterEphemeralLocked()

        formulas.append(descriptor)
        byType[descriptor.fractalType] = descriptor
        byId[descriptor.id] = descriptor
        byCategory[descriptor.category, default: []].append(descriptor)
        if !categories.contains(descriptor.category) {
            categories.append(descriptor.category)
        }
        ephemeralCustomId = descriptor.id
        ephemeralCategory = descriptor.category
    }

    /// Remove the active ephemeral formula registration, if any.
    func unregisterEphemeral() {
        Self.ephemeralLock.lock()
        defer { Self.ephemeralLock.unlock() }
        unregisterEphemeralLocked()
    }

    private func unregisterEphemeralLocked() {
        guard let id = ephemeralCustomId else { return }
        if let cat = ephemeralCategory {
            byCategory[cat]?.removeAll { $0.id == id }
            if byCategory[cat]?.isEmpty == true {
                byCategory.removeValue(forKey: cat)
                categories.removeAll { $0 == cat }
            }
        }
        formulas.removeAll { $0.id == id }
        byId.removeValue(forKey: id)
        byType.removeValue(forKey: FractalModelType.custom.rawValue)
        ephemeralCustomId = nil
        ephemeralCategory = nil
    }

    private static let ephemeralLock = NSLock()
    private var ephemeralCustomId: String?
    private var ephemeralCategory: String?
}
