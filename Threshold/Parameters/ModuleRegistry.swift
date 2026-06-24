//
//  ModuleRegistry.swift
//  Threshold
//
//  A lightweight module system for loading typed/keyed scene params.
//
//  Background: a `.threshscene` is a flat `FractalPreset` blob — every field is a
//  named property with no notion of which *domain* (space, lighting, color…) it
//  belongs to. This file adds an additive, backward-compatible layer on top of
//  that: a scene can carry a `modules` dictionary keyed by a MODULE TYPE KEY,
//  each holding typed key/value params. On load those params are ROUTED to the
//  right domain and CAPABILITY-FILTERED against the active fractal before they
//  are applied.
//
//  This is deliberately thin. It reuses the registries that already exist rather
//  than inventing parallel ones:
//    • capability  → FractalTypeDescriptor.supports(_:)  (e.g. .sphereProjection)
//    • storage     → the existing RenderSettings setters / Config domains
//  The first registered module is `space` (sphere inversion + projection), which
//  is also the first cross-fractal "Space" capability. New modules (lighting,
//  etc.) register here without touching FractalPreset's flat schema.
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

/// Where a module surfaces in the UI. Not yet consumed by the (enum-based) tab
/// system — it documents the intended home and is the seam for future
/// data-driven "divvy the scene's params into the right tabs" routing.
struct ModuleRoute: Equatable, Sendable {
    let tab: String
    let section: String
}

/// Static description of a module: its key, display metadata, route, and the
/// param names it owns. Pure value type (no stored closures) so it stays
/// Sendable and the registry can be a plain `static let` table.
struct ModuleDescriptor: Sendable {
    let key: ModuleKey
    let displayName: String
    let icon: String
    let route: ModuleRoute
    /// Canonical param names this module owns (source of truth for routing /
    /// future ControlSpec consolidation).
    let paramNames: [String]
}

// MARK: - Registry

/// The module table + the apply/capability logic. Kept thin and delegating:
/// capability defers to `FractalTypeDescriptor.supports(_:)` and application
/// defers to the existing `RenderSettings` setters.
enum ModuleRegistry {

    static let space = ModuleDescriptor(
        key: .space,
        displayName: "Space",
        icon: "globe.asia.australia",
        route: ModuleRoute(tab: "Shape", section: "Space"),
        paramNames: [
            "sphericalInversionMode",
            "sphericalInversionRadius",
            "sphereProjectionEnabled",
            "sphereProjectionBlend",
            "sphereProjectionRadius",
        ]
    )

    /// All registered modules. Add new domains here.
    static let all: [ModuleDescriptor] = [space]

    static func descriptor(for key: ModuleKey) -> ModuleDescriptor? {
        all.first { $0.key == key }
    }

    /// Whether a typed param applies to the active fractal. Universal params
    /// (e.g. the global spherical inversion) always pass; fractal-specific ones
    /// defer to the capability key so a scene that sets sphere projection on a
    /// fractal you've pruned it from is silently ignored rather than misapplied.
    static func capability(_ key: ModuleKey, param: String, for fractal: FractalModelType) -> Bool {
        switch (key, param) {
        case (.space, "sphereProjectionEnabled"),
             (.space, "sphereProjectionBlend"),
             (.space, "sphereProjectionRadius"):
            return fractal.supports(.sphereProjection)
        default:
            return true
        }
    }

    /// Apply a scene's module block to live settings, filtering each param by
    /// capability against the current fractal type.
    static func apply(_ key: ModuleKey, block: ModuleParamBlock, to settings: RenderSettings) {
        let fractal = settings.fractalType
        for (name, value) in block.params {
            guard capability(key, param: name, for: fractal) else { continue }
            applyParam(key, name: name, value: value, to: settings)
        }
    }

    private static func applyParam(_ key: ModuleKey, name: String, value: ParamValue, to settings: RenderSettings) {
        switch key {
        case .space:
            applySpaceParam(name: name, value: value, to: settings)
        default:
            // Other domains route through the flat FractalPreset fields for now;
            // they get module handlers here as they are converted.
            break
        }
    }

    private static func applySpaceParam(name: String, value: ParamValue, to settings: RenderSettings) {
        switch name {
        case "sphericalInversionMode":
            if let s = value.stringValue {
                // Matches SphericalInversionMode.codableString.
                if s == "outwardIn" { settings.sphericalInversionMode = .outwardIn }
                else if s == "off" { settings.sphericalInversionMode = .off }
            } else if let i = value.intValue, let mode = SphericalInversionMode(rawValue: Int32(i)) {
                settings.sphericalInversionMode = mode
            }
        case "sphericalInversionRadius":
            if let f = value.floatValue { settings.sphericalInversionRadius = f }
        case "sphereProjectionEnabled":
            if let b = value.boolValue { settings.sphereProjectionEnabled = b }
        case "sphereProjectionBlend":
            if let f = value.floatValue { settings.sphereProjectionBlend = f }
        case "sphereProjectionRadius":
            if let f = value.floatValue { settings.sphereProjectionRadius = f }
        default:
            break
        }
    }
}
