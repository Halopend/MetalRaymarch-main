//
//  Module.swift
//  Threshold
//
//  Class-based module hierarchy. A `Module` is a self-contained unit that owns:
//    • its domain key (the key a scene attaches to its param block)
//    • the typed params it routes (name + capability gate + apply wiring)
//  and knows how to apply a scene's param block and answer capability questions.
//
//  This replaces the previous enum + static `ModuleDescriptor` table + the two
//  giant `applySpaceParam` / `applyLightingParam` switch statements. Application
//  is now data-driven: each param carries its own writer closure, so adding a
//  param is adding one `ModuleParam`, and adding a domain is adding one subclass —
//  no central switch to edit.
//

import Foundation

// MARK: - A single routed param

/// One typed parameter a module owns: its scene key, an optional capability gate,
/// and the writer that applies a `ParamValue` to live `RenderSettings`. The
/// writer coerces the loosely-typed value itself.
struct ModuleParam {
    let name: String
    /// nil = universal (always applies). Otherwise the param is gated on the
    /// active fractal advertising the relevant capability (e.g. sphere projection,
    /// polar rotation).
    let requires: ((FractalModelType) -> Bool)?
    let apply: (RenderSettings, ParamValue) -> Void

    init(_ name: String,
         requires: ((FractalModelType) -> Bool)? = nil,
         apply: @escaping (RenderSettings, ParamValue) -> Void) {
        self.name = name
        self.requires = requires
        self.apply = apply
    }
}

// MARK: - Module base class

/// Base class for a module domain. Concrete domains (Space, Lighting, …)
/// subclass it and supply their params. The base owns the apply + capability
/// logic so subclasses are pure declarations.
///
/// @unchecked Sendable justification: all stored state is immutable after init;
/// the param writer/capability closures are pure mappings over their arguments
/// and capture no shared mutable state.
class Module: @unchecked Sendable {
    /// Scene-block domain bucket (the key a scene attaches to its param block).
    let key: ModuleKey
    let params: [ModuleParam]
    private let index: [String: ModuleParam]

    init(key: ModuleKey,
         params: [ModuleParam]) {
        self.key = key
        self.params = params
        var idx: [String: ModuleParam] = [:]
        for p in params { idx[p.name] = p }
        self.index = idx
    }

    /// Whether a specific param applies to the active fractal. Unknown params
    /// (not owned by this module) are not applicable; universal params always
    /// pass; gated params defer to their `requires` capability check.
    func capability(param: String, for fractal: FractalModelType) -> Bool {
        guard let p = index[param] else { return false }
        guard let requires = p.requires else { return true }
        return requires(fractal)
    }

    /// Apply a scene's param block to live settings, capability-filtering each
    /// param against the current fractal type.
    func apply(_ block: ModuleParamBlock, to settings: RenderSettings) {
        let fractal = settings.fractalType
        for (name, value) in block.params {
            guard let p = index[name], capability(param: name, for: fractal) else { continue }
            p.apply(settings, value)
        }
    }
}

// MARK: - Loose value coercion helpers

@inline(__always) private func setFloat(_ v: ParamValue, _ body: (Float) -> Void) {
    if let f = v.floatValue { body(f) }
}
@inline(__always) private func setBool(_ v: ParamValue, _ body: (Bool) -> Void) {
    if let b = v.boolValue { body(b) }
}
@inline(__always) private func setString(_ v: ParamValue, _ body: (String) -> Void) {
    if let s = v.stringValue { body(s) }
}

// MARK: - Space module

/// Cross-fractal "Space" transforms: global spherical inversion (universal),
/// sphere projection (gated on the fractal advertising `.sphereProjection`), and
/// the custom space warp (universal, incl. Mandelbox).
final class SpaceModule: Module, @unchecked Sendable {
    init() {
        super.init(
            key: .space,
            params: SpaceModule.makeParams())
    }

    private static func makeParams() -> [ModuleParam] {
        let needsProjection: (FractalModelType) -> Bool = { $0.supports(.sphereProjection) }
        return [
            ModuleParam("sphericalInversionMode", apply: { s, v in
                // Matches SphericalInversionMode.codableString, with int fallback.
                if let str = v.stringValue {
                    if str == "outwardIn" { s.sphericalInversionMode = .outwardIn }
                    else if str == "off" { s.sphericalInversionMode = .off }
                } else if let i = v.intValue, let mode = SphericalInversionMode(rawValue: Int32(i)) {
                    s.sphericalInversionMode = mode
                }
            }),
            ModuleParam("sphericalInversionRadius", apply: { s, v in
                setFloat(v) { s.sphericalInversionRadius = $0 }
            }),
            ModuleParam("sphereProjectionEnabled", requires: needsProjection, apply: { s, v in
                setBool(v) { s.sphereProjectionEnabled = $0 }
            }),
            ModuleParam("sphereProjectionBlend", requires: needsProjection, apply: { s, v in
                setFloat(v) { s.sphereProjectionBlend = $0 }
            }),
            ModuleParam("sphereProjectionRadius", requires: needsProjection, apply: { s, v in
                setFloat(v) { s.sphereProjectionRadius = $0 }
            }),
            ModuleParam("spaceWarpStrength", apply: { s, v in
                setFloat(v) { s.spaceWarpStrength = $0 }
            }),
            ModuleParam("spaceWarpParam1", apply: { s, v in setFloat(v) { s.spaceWarpParam1 = $0 } }),
            ModuleParam("spaceWarpParam2", apply: { s, v in setFloat(v) { s.spaceWarpParam2 = $0 } }),
            ModuleParam("spaceWarpParam3", apply: { s, v in setFloat(v) { s.spaceWarpParam3 = $0 } }),
        ]
    }
}

// MARK: - Lighting module

/// Post-process + animated lighting effects. Most are universal; polar rotation
/// and Julia drift are gated on the fractal advertising the matching capability.
/// Each effect is a value-typed struct on RenderSettings, so params read-modify-
/// write the whole effect (correct even when a scene sets several fields).
final class LightingModule: Module, @unchecked Sendable {
    init() {
        super.init(
            key: .lighting,
            params: LightingModule.makeParams())
    }

    private static func makeParams() -> [ModuleParam] {
        let needsPolar: (FractalModelType) -> Bool = { $0.supports(.polarRotation) }
        let needsJulia: (FractalModelType) -> Bool = { $0.supports(.juliaDrift) }

        return [
            // ── Master ──
            ModuleParam("lightVariationRate", apply: { s, v in setFloat(v) { s.lightVariationRate = $0 } }),
            ModuleParam("lightingMode", apply: { s, v in
                setString(v) { if let m = lightingMode(from: $0) { s.lightingMode = m } }
            }),

            // ── Hue Rotation ──
            ModuleParam("hueRotationEnabled", apply: { s, v in setBool(v) { b in var e = s.hueRotationEffect; e.enabled = b; s.hueRotationEffect = e } }),
            ModuleParam("hueRotationSpeed", apply: { s, v in setFloat(v) { f in var e = s.hueRotationEffect; e.speed = f; s.hueRotationEffect = e } }),
            ModuleParam("hueRotationIntensity", apply: { s, v in setFloat(v) { f in var e = s.hueRotationEffect; e.intensity = f; s.hueRotationEffect = e } }),

            // ── Pulse ──
            ModuleParam("pulseEnabled", apply: { s, v in setBool(v) { b in var e = s.pulseEffect; e.enabled = b; s.pulseEffect = e } }),
            ModuleParam("pulseSpeed", apply: { s, v in setFloat(v) { f in var e = s.pulseEffect; e.speed = f; s.pulseEffect = e } }),
            ModuleParam("pulseAmount", apply: { s, v in setFloat(v) { f in var e = s.pulseEffect; e.amount = f; s.pulseEffect = e } }),

            // ── Glow ──
            ModuleParam("glowEnabled", apply: { s, v in setBool(v) { b in var e = s.glowEffect; e.enabled = b; s.glowEffect = e } }),
            ModuleParam("glowIntensity", apply: { s, v in setFloat(v) { f in var e = s.glowEffect; e.intensity = f; s.glowEffect = e } }),

            // ── Bloom ──
            ModuleParam("bloomEnabled", apply: { s, v in setBool(v) { b in var e = s.bloomEffect; e.enabled = b; s.bloomEffect = e } }),
            ModuleParam("bloomStrength", apply: { s, v in setFloat(v) { f in var e = s.bloomEffect; e.strength = f; s.bloomEffect = e } }),

            // ── Fog ──
            ModuleParam("fogEnabled", apply: { s, v in setBool(v) { b in var e = s.fogEffect; e.enabled = b; s.fogEffect = e } }),
            ModuleParam("fogIntensity", apply: { s, v in setFloat(v) { f in var e = s.fogEffect; e.intensity = f; s.fogEffect = e } }),
            ModuleParam("fogHueRotateEnabled", apply: { s, v in setBool(v) { b in var e = s.fogEffect; e.hueRotateEnabled = b; s.fogEffect = e } }),
            ModuleParam("fogHueRotateSpeed", apply: { s, v in setFloat(v) { f in var e = s.fogEffect; e.hueRotateSpeed = f; s.fogEffect = e } }),
            ModuleParam("fogColorR", apply: { s, v in setFloat(v) { f in var e = s.fogEffect; e.color.x = f; s.fogEffect = e } }),
            ModuleParam("fogColorG", apply: { s, v in setFloat(v) { f in var e = s.fogEffect; e.color.y = f; s.fogEffect = e } }),
            ModuleParam("fogColorB", apply: { s, v in setFloat(v) { f in var e = s.fogEffect; e.color.z = f; s.fogEffect = e } }),

            // ── Gradient Cycle ──
            ModuleParam("gradientCycleEnabled", apply: { s, v in setBool(v) { b in var e = s.gradientCycleEffect; e.enabled = b; s.gradientCycleEffect = e } }),
            ModuleParam("gradientCycleSpeed", apply: { s, v in setFloat(v) { f in var e = s.gradientCycleEffect; e.speed = f; s.gradientCycleEffect = e } }),
            ModuleParam("gradientCycleMirrorLoop", apply: { s, v in setBool(v) { b in var e = s.gradientCycleEffect; e.mirrorLoop = b; s.gradientCycleEffect = e } }),

            // ── Linear Rail ──
            ModuleParam("linearRailEnabled", apply: { s, v in setBool(v) { b in var e = s.linearRailEffect; e.enabled = b; s.linearRailEffect = e } }),
            ModuleParam("linearRailAxis", apply: { s, v in setString(v) { str in if let axis = LinearRailAxis(rawValue: str) { var e = s.linearRailEffect; e.axis = axis; s.linearRailEffect = e } } }),
            ModuleParam("linearRailSpeed", apply: { s, v in setFloat(v) { f in var e = s.linearRailEffect; e.speed = f; s.linearRailEffect = e } }),
            ModuleParam("linearRailAmplitude", apply: { s, v in setFloat(v) { f in var e = s.linearRailEffect; e.amplitude = f; s.linearRailEffect = e } }),
            ModuleParam("linearRailMultiplier", apply: { s, v in setFloat(v) { f in var e = s.linearRailEffect; e.multiplier = f; s.linearRailEffect = e } }),
            ModuleParam("linearRailOrbitAmount", apply: { s, v in setFloat(v) { f in var e = s.linearRailEffect; e.orbitAmount = f; s.linearRailEffect = e } }),
            ModuleParam("linearRailOrbitSpeed", apply: { s, v in setFloat(v) { f in var e = s.linearRailEffect; e.orbitSpeed = f; s.linearRailEffect = e } }),

            // ── Beat Flash ──
            ModuleParam("beatFlashEnabled", apply: { s, v in setBool(v) { b in var e = s.beatFlashEffect; e.enabled = b; s.beatFlashEffect = e } }),
            ModuleParam("beatFlashIntensity", apply: { s, v in setFloat(v) { f in var e = s.beatFlashEffect; e.intensity = f; s.beatFlashEffect = e } }),

            // ── Polar Rotation (fractal-gated) ──
            ModuleParam("polarRotationDirection", requires: needsPolar, apply: { s, v in setString(v) { str in if let d = PolarRotationDirection(rawValue: str) { var e = s.polarRotationEffect; e.direction = d; s.polarRotationEffect = e } } }),
            ModuleParam("polarRotationSpeed", requires: needsPolar, apply: { s, v in setFloat(v) { f in var e = s.polarRotationEffect; e.speed = f; s.polarRotationEffect = e } }),

            // ── Julia Drift (fractal-gated) ──
            ModuleParam("juliaDriftEnabled", requires: needsJulia, apply: { s, v in setBool(v) { b in var e = s.juliaDriftEffect; e.enabled = b; s.juliaDriftEffect = e } }),
            ModuleParam("juliaDriftSpeed", requires: needsJulia, apply: { s, v in setFloat(v) { f in var e = s.juliaDriftEffect; e.speed = f; s.juliaDriftEffect = e } }),
        ]
    }
}

/// Maps a scene's lighting-mode string to the enum (mirrors
/// LightingMode.codableString, with the legacy "static" alias).
private func lightingMode(from s: String) -> LightingMode? {
    switch s {
    case "staticLight", "static": return .staticLight
    case "animated":              return .animated
    case "audioReactive":         return .audioReactive
    case "visualizer":            return .visualizer
    default:                      return nil
    }
}
