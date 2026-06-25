//
//  ModuleRegistry.swift
//  Threshold
//
//  A module system for loading typed/keyed scene params, and the scene-side data
//  types that carry them.
//
//  Background: a `.threshscene` is a flat `FractalPreset` blob — every field is a
//  named property with no notion of which *domain* (space, lighting, color…) it
//  belongs to. This adds an additive, backward-compatible layer on top of that: a
//  scene can carry a `modules` dictionary keyed by a MODULE TYPE KEY, each holding
//  typed key/value params. On load those params are ROUTED to the right domain and
//  CAPABILITY-FILTERED against the active fractal before they are applied.
//
//  The domains themselves are class-based `Module` objects (see Module.swift):
//  each module owns its identity, UI route, params, capability gates, and apply
//  wiring. This file holds the scene-side value types (ModuleKey / ParamValue /
//  ModuleParamBlock / ModuleRoute) and a thin `ModuleRegistry` facade that builds
//  the module instances once and delegates apply/capability to them.
//
//  See FractalPreset.modules for the scene-side hook and apply(to:) for where
//  module blocks are applied (after the flat fields, so a module refines them).
//

import Foundation

// MARK: - Module type key

/// The "type key" a scene attaches to a block of params to say which module
/// (and therefore which domain + UI tab) the params belong to.
enum ModuleKey: String, Codable, CaseIterable, Sendable {
    case space
    case lighting
    case color
    case geometry
    case quality
    case display
    case audio
}

// MARK: - Typed param value

/// A single typed value carried by a module param. Decodes from a JSON
/// number / bool / string and offers loose accessors so an `apply` handler can
/// coerce it to the type it needs (e.g. a Float slider or an enum string).
enum ParamValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Order matters: a JSON bool must not be read as an int, and vice versa.
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported ParamValue (expected bool/number/string)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        }
    }

    var floatValue: Float? {
        switch self {
        case .double(let d): return Float(d)
        case .int(let i): return Float(i)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Float(s)
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int(s)
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return (s as NSString).boolValue
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Scene-side block

/// A module's params as they appear inside a scene's `modules` dictionary:
/// `{ "params": { name: value }, "enabled": bool? }`.
struct ModuleParamBlock: Codable, Equatable, Sendable {
    var enabled: Bool?
    var params: [String: ParamValue]

    init(enabled: Bool? = nil, params: [String: ParamValue] = [:]) {
        self.enabled = enabled
        self.params = params
    }
}

// MARK: - Routing metadata

/// Where a module surfaces in the UI: which tab + section. Owned by `Module.route`
/// and consumed by the data-driven tabs that render each module's controls at its
/// declared home.
struct ModuleRoute: Equatable, Sendable {
    let tab: String
    let section: String
}

// MARK: - Registry facade

/// The registry of class-based modules. A thin facade that builds the module
/// instances once and delegates capability/apply to the module objects. This is
/// the stable entry point used by FractalPreset's scene-apply path and the tests;
/// the behavior lives on the `Module` subclasses in Module.swift.
enum ModuleRegistry {

    /// All registered modules. Add a new domain by adding its subclass here.
    static let all: [Module] = [SpaceModule(), LightingModule()]

    private static let byKey: [ModuleKey: Module] = {
        var map: [ModuleKey: Module] = [:]
        for module in all { map[module.key] = module }
        return map
    }()

    /// The module owning a domain key, if any.
    static func module(for key: ModuleKey) -> Module? { byKey[key] }

    /// Modules whose route targets a given UI tab (consumed by the data-driven
    /// tabs that render module controls at their routes).
    static func modules(forTab tab: String) -> [Module] {
        all.filter { $0.route.tab == tab }
    }

    /// Apply a scene's module block to live settings, capability-filtered against
    /// the active fractal. No-op for domains without a registered module.
    static func apply(_ key: ModuleKey, block: ModuleParamBlock, to settings: RenderSettings) {
        byKey[key]?.apply(block, to: settings)
    }

    /// Whether a typed param applies to the active fractal. Universal params pass;
    /// fractal-specific ones (sphere projection, polar rotation, Julia drift)
    /// defer to the owning module's per-param capability gate.
    static func capability(_ key: ModuleKey, param: String, for fractal: FractalModelType) -> Bool {
        byKey[key]?.capability(param: param, for: fractal) ?? false
    }
}
