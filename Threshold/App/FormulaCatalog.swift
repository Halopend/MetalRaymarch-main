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
    /// Optional bundle tag — maps to ParameterBundle for consistent grouping across
    /// UI, gestures, and modulation layers.  Falls back to `.custom` when absent.
    var bundle: ParameterBundle?
    
    var id: String { "\(index)-\(name)" }

    /// Resolved bundle, defaulting to `.custom` when the catalog entry omits the field.
    var resolvedBundle: ParameterBundle { bundle ?? .custom }
}

/// Full description of a fractal formula loaded from the catalog.
struct FormulaDescriptor: Codable, Identifiable {
    let id: String
    let name: String
    let fractalType: Int32
    let category: String
    let description: String
    let params: [FormulaParamDescriptor]
}

private struct CatalogRoot: Codable {
    let version: Int
    let formulas: [FormulaDescriptor]
}

// MARK: - FormulaCatalog

/// Thread-safe, lazily-loaded formula catalog. Reads `Formulas/catalog.json` from the bundle.
final class FormulaCatalog: @unchecked Sendable {
    
    static let shared = FormulaCatalog()
    
    /// All formula descriptors in declaration order.
    private(set) var formulas: [FormulaDescriptor] = []
    
    /// Lookup by `FractalModelType.rawValue`.
    private var byType: [Int32: FormulaDescriptor] = [:]
    
    /// Lookup by string id (e.g. "mandelbulb").
    private var byId: [String: FormulaDescriptor] = [:]
    
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
            for f in root.formulas {
                byType[f.fractalType] = f
                byId[f.id] = f
            }
        } catch {
            print("[FormulaCatalog] Failed to decode catalog.json: \(error)")
        }
    }
    
    // MARK: - Queries
    
    /// Descriptor for a given `FractalModelType`.
    func descriptor(for type: FractalModelType) -> FormulaDescriptor? {
        byType[type.rawValue]
    }
    
    /// Descriptor by string id.
    func descriptor(id: String) -> FormulaDescriptor? {
        byId[id]
    }
    
    /// All formulas in a given category.
    func formulas(inCategory category: String) -> [FormulaDescriptor] {
        formulas.filter { $0.category == category }
    }
    
    /// Unique category names in declaration order.
    var categories: [String] {
        var seen = Set<String>()
        return formulas.compactMap { f in
            if seen.insert(f.category).inserted { return f.category }
            return nil
        }
    }
    
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
        
        return fp
    }
    
    /// Build a `FormulaParams` from a dictionary of param name → value.
    func buildParams(for type: FractalModelType, namedOverrides: [String: Float]) -> FormulaParams {
        guard let desc = byType[type.rawValue] else {
            return type.defaultFormulaParams()
        }
        let indexed = namedOverrides.compactMap { (name, value) -> (Int, Float)? in
            guard let p = desc.params.first(where: { $0.name == name }) else { return nil }
            return (p.index, value)
        }
        return buildParams(for: type, overrides: indexed)
    }
    
    // MARK: - Param Accessors
    
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
}
