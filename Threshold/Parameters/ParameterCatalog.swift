//
//  ParameterCatalog.swift
//  Threshold
//
//  A vertically-integrated parameter node hierarchy. Each `ParameterNode` owns the
//  full vertical stack of a tunable control — its metadata (via ControlSpec), where
//  it appears in the UI (route), whether it is enabled for a given fractal
//  (capability), how it binds to gestures (isGestureMappable / triplet grouping),
//  how it reacts to music (MusicFacet), and BOTH input/output wirings: the
//  @MainActor UI path (UISettingsCache) and the off-main settings path
//  (RenderSettings), side by side so they cannot drift.
//
//  Background: the same scalar (e.g. sphere-projection blend) historically had to be
//  declared in SIX parallel registries kept in lockstep by a launch-time tripwire —
//  ParameterTargetID.coreAndEffect, ControlCatalog, the dispatcher coreDescriptors,
//  the ParameterNodeRegistry node closures, the MusicReactiveTarget switches, and the
//  RenderSettings audioModulate clamp. ParameterCatalog is the single authored
//  surface those registries now DERIVE from. Adding a routed scalar = one entry here.
//
//  This file is the metadata/wiring source. The LIVE, mutable layer-stack node
//  (`FloatParameterNode`, ParameterNodeSystem.swift) is constructed FROM a
//  `ScalarParameter` — immutable authored description vs. mutable runtime instance.
//

import Foundation

// MARK: - Facets ("different layers handling different areas")

/// Where a parameter appears in the UI. Reserved for data-driven tab/section
/// rendering; not yet consumed by the SwiftUI tabs (those still place controls by
/// hand). Carried on the node now so the model is complete.
struct ParameterRoute: Sendable {
    let tab: String
    let section: String
    let order: Int
}

/// Feature-enablement gate. Mirrors `FractalTypeDescriptor.supports(_:)`.
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

/// Music-reactive defaults for a parameter. Projected into `MusicReactiveTarget`.
struct MusicFacet: Sendable {
    let category: MusicReactiveTargetCategory
    let defaultSource: MusicReactiveSource
    let defaultResponseCurve: ResponseCurve
    let hasFlashingRisk: Bool
}

/// The off-main input/output function pair (gesture + audio drive parameters over
/// the lock-protected `RenderSettings`). Some are simple field read/writes; others
/// orchestrate (clamp+round, multi-field commits) — that orchestration lives here.
struct SettingsBinding: Sendable {
    let read: @Sendable (RenderSettings) -> Float
    let write: @Sendable (RenderSettings, Float) -> Void
}

/// The @MainActor input/output function pair for the UI/slider path (over the
/// MainActor-isolated `UISettingsCache`). Kept structurally separate from
/// `SettingsBinding` so the @MainActor closure can never be invoked off-main.
struct UICacheBinding: Sendable {
    let read: @MainActor @Sendable (UISettingsCache) -> Float
    let write: @MainActor @Sendable (UISettingsCache, Float) -> Void
}

/// Which registry dictionary a routed scalar lands in (preserves the historical
/// core-geometry vs post-process split used by ParameterNodeRegistry).
enum ParameterDomain: Sendable { case core, effect }

// MARK: - Node class hierarchy

/// Base of the authored parameter-node hierarchy. Immutable metadata only, so it is
/// freely shareable across the @MainActor UI and the off-main dispatcher/renderer.
/// (@unchecked Sendable mirrors `AnyParameterNodeBase`: the stored closures on
/// subclasses are isolation-tagged, the metadata here is plain immutable values.)
class ParameterNode: @unchecked Sendable, Identifiable {
    let id: String
    let displayName: String
    let icon: String
    let route: ParameterRoute?
    let capability: ParameterCapability
    let isGestureMappable: Bool
    let music: MusicFacet?

    init(id: String,
         displayName: String,
         icon: String,
         route: ParameterRoute?,
         capability: ParameterCapability,
         isGestureMappable: Bool,
         music: MusicFacet?) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.route = route
        self.capability = capability
        self.isGestureMappable = isGestureMappable
        self.music = music
    }

    /// Composite nodes (groups, xyz vectors) override this. Leaves return [].
    var children: [ParameterNode] { [] }
}

/// A single tunable Float — the common case. Sources range/default/name/icon/motion
/// from a `ControlSpec` and carries both IO bindings + the routing/music facets.
final class ScalarParameter: ParameterNode, @unchecked Sendable {
    let spec: ControlSpec
    let domain: ParameterDomain
    let group: ParameterGroup
    let ui: UICacheBinding
    let settings: SettingsBinding
    /// True when this scalar should appear in the finger-binding menu as a 1-D drag
    /// target. False for scalars already reachable via a dedicated core gesture
    /// action (e.g. fractalScale), to avoid a duplicate menu entry.
    let surfacesAsScalarGesture: Bool

    init(spec: ControlSpec,
         domain: ParameterDomain,
         group: ParameterGroup,
         capability: ParameterCapability = .universal,
         isGestureMappable: Bool,
         surfacesAsScalarGesture: Bool = false,
         music: MusicFacet?,
         route: ParameterRoute? = nil,
         ui: UICacheBinding,
         settings: SettingsBinding) {
        self.spec = spec
        self.domain = domain
        self.group = group
        self.ui = ui
        self.settings = settings
        self.surfacesAsScalarGesture = surfacesAsScalarGesture
        super.init(id: spec.id,
                   displayName: spec.name,
                   icon: spec.icon,
                   route: route,
                   capability: capability,
                   isGestureMappable: isGestureMappable,
                   music: music)
    }
}

/// A Bool toggle parameter. Defined for completeness of the hierarchy; not yet
/// populated by the catalog (toggles still live on their Config structs).
final class ToggleParameter: ParameterNode, @unchecked Sendable {}

/// A group of child nodes that share a UI section. The grouping primitive behind
/// "which section to appear in" and composite gesture targets.
class GroupParameter: ParameterNode, @unchecked Sendable {
    private let storedChildren: [ParameterNode]
    override var children: [ParameterNode] { storedChildren }

    init(id: String,
         displayName: String,
         icon: String,
         route: ParameterRoute?,
         children: [ParameterNode]) {
        self.storedChildren = children
        super.init(id: id,
                   displayName: displayName,
                   icon: icon,
                   route: route,
                   capability: .universal,
                   isGestureMappable: false,
                   music: nil)
    }
}

/// An x/y/z triplet bound and gestured as a unit (e.g. Mandelbox `Mins.xyz`). The
/// first-class home for what `GestureBindableTriplet` detects by name today.
final class VectorParameter: GroupParameter, @unchecked Sendable {
    let x: ScalarParameter
    let y: ScalarParameter
    let z: ScalarParameter

    init(id: String,
         displayName: String,
         icon: String,
         route: ParameterRoute?,
         x: ScalarParameter,
         y: ScalarParameter,
         z: ScalarParameter) {
        self.x = x
        self.y = y
        self.z = z
        super.init(id: id, displayName: displayName, icon: icon, route: route, children: [x, y, z])
    }
}

// MARK: - The authored catalog

/// The single authored list of routed core/effect/space scalars. Every parallel
/// registry derives from this — see `ParameterTargetID.coreAndEffect`,
/// `ParameterOperationDispatcher.coreDescriptors`,
/// `ParameterNodeRegistry.buildCoreAndEffectNodes`, and the `MusicReactiveTarget`
/// metadata projection. Long-tail (UI-only) controls remain in `ControlCatalog`.
enum ParameterCatalog {

    static let coreGroup = ParameterGroup(id: "core.geometry", title: "Fractal Geometry")
    static let effectGroup = ParameterGroup(id: "effect.postprocess", title: "Post-Processing")
    static let spaceGroup = ParameterGroup(id: "space.transform", title: "Space Transform")

    static let routed: [ScalarParameter] = [
        // ── Core geometry ──────────────────────────────────────────────────────
        ScalarParameter(
            spec: ControlCatalog.fractalScale, domain: .core, group: coreGroup,
            isGestureMappable: true,
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .sinusoidal, hasFlashingRisk: false),
            ui: UICacheBinding(read: { $0.fractalScale },
                               write: { cache, v in cache.fractalScale = v; cache.push(\.targetFractalScale, value: v) }),
            settings: SettingsBinding(read: { $0.targetFractalScale },
                                      write: { settings, v in settings.targetFractalScale = v })),

        ScalarParameter(
            spec: ControlCatalog.colorMix, domain: .core, group: coreGroup,
            isGestureMappable: true,
            music: MusicFacet(category: .color, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UICacheBinding(read: { $0.color.colorMix },
                               write: { cache, v in cache.color.colorMix = v; cache.push(\.colorMix, value: v) }),
            settings: SettingsBinding(read: { $0.colorMix },
                                      write: { settings, v in settings.colorMix = v })),

        ScalarParameter(
            spec: ControlCatalog.iterations, domain: .core, group: coreGroup,
            isGestureMappable: false,
            music: MusicFacet(category: .geometry, defaultSource: .mid, defaultResponseCurve: .sinusoidal, hasFlashingRisk: false),
            ui: UICacheBinding(read: { Float($0.liveFractalIterations) },
                               write: { cache, v in
                                   let rounded = max(2, min(24, Int(v.rounded())))
                                   cache.liveFractalIterations = rounded
                                   cache.push(\.fractalIterations, value: rounded)
                               }),
            settings: SettingsBinding(read: { Float($0.fractalIterations) },
                                      write: { settings, v in settings.fractalIterations = max(2, min(24, Int(v.rounded()))) })),

        // ── Post-process effects ────────────────────────────────────────────────
        ScalarParameter(
            spec: ControlCatalog.glow, domain: .effect, group: effectGroup,
            isGestureMappable: false,
            music: MusicFacet(category: .light, defaultSource: .beat, defaultResponseCurve: .pulse, hasFlashingRisk: true),
            ui: UICacheBinding(read: { $0.lighting.glowEffect.intensity },
                               write: { cache, v in cache.lighting.glowEffect.intensity = v; cache.commitGlowEffect() }),
            settings: SettingsBinding(read: { $0.glowEffect.intensity },
                                      write: { settings, v in settings.audioModulateGlowIntensity(v) })),

        ScalarParameter(
            spec: ControlCatalog.fog, domain: .effect, group: effectGroup,
            isGestureMappable: false,
            music: MusicFacet(category: .light, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UICacheBinding(read: { $0.lighting.fogEffect.intensity },
                               write: { cache, v in cache.lighting.fogEffect.intensity = v; cache.commitFogEffect() }),
            settings: SettingsBinding(read: { $0.fogEffect.intensity },
                                      write: { settings, v in settings.audioModulateFogIntensity(v) })),

        ScalarParameter(
            spec: ControlCatalog.bloom, domain: .effect, group: effectGroup,
            isGestureMappable: false,
            music: MusicFacet(category: .light, defaultSource: .beat, defaultResponseCurve: .pulse, hasFlashingRisk: true),
            ui: UICacheBinding(read: { $0.lighting.bloomEffect.strength },
                               write: { cache, v in cache.lighting.bloomEffect.strength = v; cache.commitBloomEffect() }),
            settings: SettingsBinding(read: { $0.bloomEffect.strength },
                                      write: { settings, v in settings.audioModulateBloomStrength(v) })),

        ScalarParameter(
            spec: ControlCatalog.hueSpeed, domain: .effect, group: effectGroup,
            isGestureMappable: false,
            music: MusicFacet(category: .color, defaultSource: .treble, defaultResponseCurve: .drift, hasFlashingRisk: true),
            ui: UICacheBinding(read: { $0.lighting.hueRotationEffect.speed },
                               write: { cache, v in cache.lighting.hueRotationEffect.speed = v; cache.commitHueRotationEffect() }),
            settings: SettingsBinding(read: { $0.hueRotationEffect.speed },
                                      write: { settings, v in settings.audioModulateHueSpeed(v) })),

        ScalarParameter(
            spec: ControlCatalog.saturation, domain: .effect, group: effectGroup,
            isGestureMappable: false,
            music: MusicFacet(category: .color, defaultSource: .mid, defaultResponseCurve: .drift, hasFlashingRisk: true),
            ui: UICacheBinding(read: { $0.color.colorSchemeSaturation },
                               write: { cache, v in cache.color.colorSchemeSaturation = v; cache.commitColorSchemeSaturation() }),
            settings: SettingsBinding(read: { $0.colorSchemeSaturation },
                                      write: { settings, v in settings.audioModulateSaturation(v) })),

        ScalarParameter(
            spec: ControlCatalog.safetyBubbleRadius, domain: .effect, group: effectGroup,
            isGestureMappable: false,
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UICacheBinding(read: { $0.safetyBubble.radius },
                               write: { cache, v in cache.safetyBubble.radius = v; cache.push(\.safetyBubbleRadius, value: v) }),
            settings: SettingsBinding(read: { $0.safetyBubbleRadius },
                                      write: { settings, v in settings.audioModulateSafetyBubbleRadius(v) })),

        // ── Space transforms (cross-fractal sphere projection) ───────────────────
        ScalarParameter(
            spec: ControlCatalog.sphereProjectionBlend, domain: .core, group: spaceGroup,
            isGestureMappable: true, surfacesAsScalarGesture: true,
            music: MusicFacet(category: .geometry, defaultSource: .composite, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UICacheBinding(read: { $0.display.sphereProjectionBlend },
                               write: { cache, v in cache.display.sphereProjectionBlend = v; cache.commitSphereProjection() }),
            settings: SettingsBinding(read: { $0.sphereProjectionBlend },
                                      write: { settings, v in settings.audioModulateSphereProjectionBlend(v) })),

        ScalarParameter(
            spec: ControlCatalog.sphereProjectionRadius, domain: .core, group: spaceGroup,
            isGestureMappable: true, surfacesAsScalarGesture: true,
            music: MusicFacet(category: .geometry, defaultSource: .bass, defaultResponseCurve: .drift, hasFlashingRisk: false),
            ui: UICacheBinding(read: { $0.display.sphereProjectionRadius },
                               write: { cache, v in cache.display.sphereProjectionRadius = v; cache.commitSphereProjection() }),
            settings: SettingsBinding(read: { $0.sphereProjectionRadius },
                                      write: { settings, v in settings.audioModulateSphereProjectionRadius(v) })),
    ]

    /// Routed descriptors keyed by canonical id.
    static let byID: [String: ScalarParameter] = Dictionary(uniqueKeysWithValues: routed.map { ($0.id, $0) })

    /// Canonical ids in declaration order (drives `ParameterTargetID.coreAndEffect`).
    static var ids: [String] { routed.map(\.id) }

    /// The off-main IO for a routed scalar, or nil if not a routed core/effect id.
    static func settingsBinding(for id: String) -> SettingsBinding? { byID[id]?.settings }

    /// Music facet for a routed scalar, or nil. (Formula/legacy targets resolve
    /// their music metadata elsewhere.)
    static func musicFacet(for id: String) -> MusicFacet? { byID[id]?.music }
}
