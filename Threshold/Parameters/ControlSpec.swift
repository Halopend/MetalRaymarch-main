//
//  ControlSpec.swift
//  Threshold
//
//  Single source of truth for a tunable control's static metadata: its canonical
//  id, label, icon, value range, default, and motion strategy.
//
//  Background: the same logical control (e.g. "Fractal Scale") historically had
//  its range/default/name/icon redefined independently in ParameterNodeRegistry,
//  ParameterPipeline.coreDescriptors, MusicReactiveTarget, and inline
//  in the SwiftUI sliders. Those copies drifted — the Fractal Scale *manual*
//  slider read -3...5 while every automation layer (node, dispatcher, music)
//  used -5...8, so a value reachable by gesture/music could not be dialed in by
//  hand. Icons and labels had drifted too (glow was `sun.max` as a node but
//  `sparkles` in the music menu; the safety-bubble radius was "Inner Radius" in
//  one list and "Safety Bubble Radius" in another).
//
//  ControlSpec collapses that metadata into one declaration. Every consumer reads
//  from ControlCatalog, so they cannot disagree. The spec is intentionally a pure
//  value type (no closures, no live state): the live FloatParameterNode keeps its
//  read/write closures and layer stack and simply *sources* its range/default/
//  name/icon/motion from a ControlSpec.
//

import Foundation

struct ControlID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

/// Immutable, Sendable description of one tunable control — the single source of
/// truth for its range, default, label, icon, and motion strategy.
struct ControlSpec: Sendable, Equatable {
    /// Canonical target id (see `ParameterTargetID`), e.g. "core.fractalScale".
    let id: String
    /// Human-readable label for flat lists (gesture / music menus). In-context
    /// UI sliders may still pass a shorter contextual label of their own.
    let name: String
    /// SF Symbol name.
    let icon: String
    /// The authoritative value range for *every* layer — UI slider, gesture, and
    /// music automation. There is deliberately no separate "manual" range:
    /// automation can already drive the full span, so the manual slider matches.
    let range: ClosedRange<Float>
    /// Default value used when a parameter node bootstraps its base layer.
    let defaultValue: Float
    /// How layered changes to this control are smoothed.
    let motionStrategy: ParameterMotionStrategy

    var controlID: ControlID { ControlID(id) }

    init(id: String,
         name: String,
         icon: String,
         range: ClosedRange<Float>,
         defaultValue: Float,
         motionStrategy: ParameterMotionStrategy = .layerLerp) {
        self.id = id
        self.name = name
        self.icon = icon
        self.range = range
        self.defaultValue = defaultValue
        self.motionStrategy = motionStrategy
    }

    /// Clamp a value into this control's range.
    func clamp(_ v: Float) -> Float {
        min(range.upperBound, max(range.lowerBound, v))
    }
}

/// The registry of canonical engine-level controls (core geometry + post-process
/// effects). Per-fractal *formula* params are NOT here — those are catalog-driven
/// per fractal type by FormulaCatalog / ParameterNodeRegistry. This catalog owns
/// only the fixed, fractal-independent controls whose metadata previously had to
/// be kept in sync by hand across the node, dispatcher, music, and UI layers.
///
/// Canonicalization choices when sources had drifted (resolved here, once):
///   • fractalScale range → -5...8 (every automation layer already used it).
///   • glow/bloom/hueSpeed/saturation icons → the engine-node glyphs.
///   • safetyBubbleRadius label → "Safety Bubble Radius" (clearer in a flat list).
enum ControlCatalog {

    // MARK: Core geometry

    static let fractalScale = ControlSpec(
        id: ParameterTargetID.Core.fractalScale,
        name: "Fractal Scale",
        icon: "arrow.up.left.and.arrow.down.right",
        range: -5.0...8.0,
        defaultValue: 2.0,
        motionStrategy: .smoothDamp)

    static let colorMix = ControlSpec(
        id: ParameterTargetID.Core.colorMix,
        name: "Color Mix",
        icon: "paintpalette",
        range: 0.0...1.0,
        defaultValue: 0.5)

    static let iterations = ControlSpec(
        id: ParameterTargetID.Core.iterations,
        name: "Iterations",
        icon: "number",
        range: 2.0...24.0,
        defaultValue: 12.0)

    // MARK: Post-process effects

    static let glow = ControlSpec(
        id: ParameterTargetID.Effect.glow,
        name: "Glow",
        icon: "sun.max",
        range: 0.0...2.0,
        defaultValue: 0.0)

    static let fog = ControlSpec(
        id: ParameterTargetID.Effect.fog,
        name: "Fog",
        icon: "cloud.fog",
        range: 0.0...1.0,
        defaultValue: 0.32)

    static let bloom = ControlSpec(
        id: ParameterTargetID.Effect.bloom,
        name: "Bloom",
        icon: "sparkle",
        range: 0.0...2.0,
        defaultValue: 0.0)

    static let hueSpeed = ControlSpec(
        id: ParameterTargetID.Effect.hueSpeed,
        name: "Hue Speed",
        icon: "arrow.trianglehead.2.clockwise.rotate.90",
        range: 0.0...0.5,
        defaultValue: 0.0)

    static let saturation = ControlSpec(
        id: ParameterTargetID.Effect.saturation,
        name: "Saturation",
        icon: "drop.halffull",
        range: 0.0...3.0,
        defaultValue: 2.0)

    static let safetyBubbleRadius = ControlSpec(
        id: ParameterTargetID.Effect.safetyBubbleRadius,
        name: "Safety Bubble Radius",
        icon: "circle.dashed",
        range: 0.5...2.5,
        defaultValue: 1.8)

    /// Gradient phase offset (rotates colors through the gradient). Wraps 0…1;
    /// exposed as a music-bindable "Color Offset".
    static let gradientOffset = ControlSpec(
        id: ParameterTargetID.Effect.gradientOffset,
        name: "Color Offset",
        icon: "arrow.right",
        range: 0.0...1.0,
        defaultValue: 0.0)

    // MARK: Space transforms
    //
    // Cross-fractal sphere-projection blend + radius. Canonical (in `allSpecs`) so
    // they route through the node/dispatcher/music layers and can be driven by
    // gesture and music — not just the slider.

    /// 0 = no projection, 1 = full sphere melt.
    static let sphereProjectionBlend = ControlSpec(
        id: ParameterTargetID.Space.sphereProjectionBlend,
        name: "Projection Blend",
        icon: "circle.lefthalf.filled",
        range: 0.0...1.0,
        defaultValue: 1.0)

    /// Radius of the sphere detail is projected onto. Setter clamps 0.2…12.
    static let sphereProjectionRadius = ControlSpec(
        id: ParameterTargetID.Space.sphereProjectionRadius,
        name: "Projection Radius",
        icon: "circle",
        range: 0.2...12.0,
        defaultValue: 1.0)

    /// Built-in Twist strength. 0 = off. Setter clamps 0…2.
    static let spaceWarpStrength = ControlSpec(
        id: ParameterTargetID.Space.spaceWarpStrength,
        name: "Twist",
        icon: "tornado",
        range: 0.0...2.0,
        defaultValue: 0.0)

    /// Built-in Twist origin point components (x, y, z).
    static let spaceWarpOriginX = ControlSpec(
        id: ParameterTargetID.Space.spaceWarpOriginX,
        name: "Twist Origin X",
        icon: "arrow.left.and.right",
        range: -4.0...4.0,
        defaultValue: 0.0)
    static let spaceWarpOriginY = ControlSpec(
        id: ParameterTargetID.Space.spaceWarpOriginY,
        name: "Twist Origin Y",
        icon: "arrow.up.and.down",
        range: -4.0...4.0,
        defaultValue: 0.0)
    static let spaceWarpOriginZ = ControlSpec(
        id: ParameterTargetID.Space.spaceWarpOriginZ,
        name: "Twist Origin Z",
        icon: "arrow.up.left.and.arrow.down.right",
        range: -4.0...4.0,
        defaultValue: 0.0)

    // MARK: Long-tail controls
    //
    // Controls consumed by the property setter + config clamp + UI slider but NOT
    // the music/gesture node layers — so they are deliberately NOT in `allSpecs`
    // / `all` (the startup node-agreement validation only covers the canonical
    // set above). These were each a range/clamp drift bug: the setter clamp and
    // the slider range had diverged, leaving dead UI range (or, for colorIterations,
    // an unclamped GPU-loop-count that could hang the watchdog). Canonical values
    // adversarially verified GPU-safe.

    /// Setter clamped 0.2…12 but the slider only reached 0.5…6 (dead range).
    static let sphericalInversionRadius = ControlSpec(
        id: "space.sphericalInversionRadius",
        name: "Inversion Radius",
        icon: "circle",
        range: 0.2...12.0,
        defaultValue: 2.0)

    /// Was UNCLAMPED in the setter + raw on restore; feeds a per-pixel GPU loop
    /// (`steps = max(int(colorIters*quality), 2)`), so an out-of-band persisted
    /// value was a watchdog-hang vector. Clamp = the slider span 4…16.
    static let colorIterations = ControlSpec(
        id: "color.colorIterations",
        name: "Iterations",
        icon: "number",
        range: 4.0...16.0,
        defaultValue: 8.0)

    /// Setter clamped 0.33…1 but the slider floored at 0.34 (dead sliver).
    static let resolutionScale = ControlSpec(
        id: "quality.resolutionScale",
        name: "Resolution Scale",
        icon: "rectangle.compress.vertical",
        range: 0.33...1.0,
        defaultValue: 0.5)

    // Color-grading controls — not drift bugs (setter / ColorConfig.clamp / slider
    // already agreed), folded onto specs so their range lives in ONE place and the
    // three consumers can't diverge in future.

    static let colorSchemeContrast = ControlSpec(
        id: "color.contrast", name: "Contrast", icon: "circle.righthalf.filled",
        // Built-in gradient presets already author values up to 1.4. The old
        // 0.95...1.15 slider could not reproduce those shipped looks by hand.
        range: 0.75...1.5, defaultValue: 1.08)

    static let colorSchemeVibrance = ControlSpec(
        id: "color.vibrance", name: "Vibrance", icon: "drop.fill",
        range: 0.0...1.0, defaultValue: 0.8)

    static let colorSchemeCurve = ControlSpec(
        id: "color.curve", name: "Curve", icon: "scribble.variable",
        range: -1.0...1.0, defaultValue: 0.0)

    static let colorSchemeShadows = ControlSpec(
        id: "color.shadows", name: "Shadows", icon: "moon.fill",
        range: -0.05...0.05, defaultValue: -0.018)

    static let colorSchemeHighlights = ControlSpec(
        id: "color.highlights", name: "Highlights", icon: "sun.max.fill",
        range: -0.5...1.0, defaultValue: 0.02)

    // More color/lighting controls whose range was open-coded in BOTH the
    // RenderSettings setter AND ColorConfig.clamp() (and the UI slider) — folded
    // onto specs so the bound lives in ONE place and the consumers can't diverge.

    static let colorSchemeGamma = ControlSpec(
        id: "color.gamma", name: "Gamma", icon: "circle.lefthalf.filled",
        // Values below 1 brighten; values above 1 darken. The previous upper
        // bound of 1 exposed only half of the useful grading response.
        range: 0.2...2.0, defaultValue: 0.85)

    static let lightingSoftness = ControlSpec(
        id: "color.lightingSoftness", name: "Lighting Softness", icon: "sun.max",
        range: 0.0...1.0, defaultValue: 0.5)

    static let cellShadingLevels = ControlSpec(
        id: "color.cellShadingLevels", name: "Cell Shading Levels", icon: "square.stack.3d.up",
        range: 2.0...8.0, defaultValue: 4.0)

    static let aoStrength = ControlSpec(
        id: "color.aoStrength", name: "Ambient Occlusion", icon: "circle.lefthalf.striped.horizontal",
        range: 0.0...1.0, defaultValue: 0.0)

    static let tonemapStrength = ControlSpec(
        id: "color.tonemapStrength", name: "Filmic Tonemap", icon: "camera.aperture",
        range: 0.0...1.0, defaultValue: 0.0)

    /// Strength of the existing output vignette. 1 preserves the historical
    /// always-on look; 0 is a true identity/off value.
    static let vignetteStrength = ControlSpec(
        id: "post.vignette.strength", name: "Vignette", icon: "viewfinder",
        range: 0.0...1.5, defaultValue: 1.0)

    // Edge detection is output-space and deliberately remains long-tail: it is
    // scene-authored but not music/gesture routed. Keeping every bound here lets
    // the full panel, radial menu, decode normalization, and GPU bridge agree.
    static let edgeStrength = ControlSpec(
        id: "post.edge.strength", name: "Edge Strength", icon: "circle.lefthalf.filled",
        range: 0.0...1.0, defaultValue: 0.0)

    static let edgeThreshold = ControlSpec(
        id: "post.edge.threshold", name: "Edge Threshold", icon: "line.3.horizontal.decrease",
        range: 0.0...0.25, defaultValue: 0.12)

    static let edgeSoftness = ControlSpec(
        id: "post.edge.softness", name: "Edge Softness", icon: "line.3.horizontal",
        range: 0.001...0.15, defaultValue: 0.08)

    static let edgeWindowRadius = ControlSpec(
        id: "post.edge.windowRadius", name: "Edge Window Size", icon: "square.grid.3x3",
        range: 1.0...3.0, defaultValue: 1.0)

    static let colorSchemeAutoInterval = ControlSpec(
        id: "color.autoInterval", name: "Auto Transition Interval", icon: "timer",
        range: 5.0...120.0, defaultValue: 30.0)

    static let colorSchemeTransitionDuration = ControlSpec(
        id: "color.transitionDuration", name: "Transition Duration", icon: "clock",
        range: 0.1...10.0, defaultValue: 2.0)

    /// Every canonical spec in declaration order.
    static let allSpecs: [ControlSpec] = [
        fractalScale, colorMix, iterations,
        glow, fog, bloom, hueSpeed, saturation, safetyBubbleRadius, gradientOffset,
        sphereProjectionBlend, sphereProjectionRadius,
        spaceWarpStrength, spaceWarpOriginX, spaceWarpOriginY, spaceWarpOriginZ
    ]

    /// Long-tail controls: each has a ControlSpec (so its range lives in ONE place,
    /// read by the property setter + the domain `Config.clamp()` + any slider) but is
    /// NOT routed through the node/dispatcher/music layers — hence deliberately
    /// excluded from `allSpecs` and from `validateStartupRouting`'s node-agreement
    /// check (PARAMETER_NODE_HIERARCHY_DESIGN §3.1 / §8). Enumerated here so they are
    /// (a) the basis for promoting them into `allDescriptors` later, and (b) covered
    /// by the id-uniqueness invariant below — a duplicate/typo'd id is the exact drift
    /// the spec system exists to prevent.
    static let longTailSpecs: [ControlSpec] = [
        sphericalInversionRadius, colorIterations, resolutionScale,
        colorSchemeContrast, colorSchemeVibrance, colorSchemeCurve,
        colorSchemeShadows, colorSchemeHighlights,
        colorSchemeGamma, lightingSoftness, cellShadingLevels,
        colorSchemeAutoInterval, colorSchemeTransitionDuration,
        aoStrength, tonemapStrength, vignetteStrength,
        edgeStrength, edgeThreshold, edgeSoftness, edgeWindowRadius
    ]

    /// Routed + long-tail. Every spec the catalog declares.
    static let everySpec: [ControlSpec] = allSpecs + longTailSpecs

    /// Canonical specs keyed by id.
    static let all: [String: ControlSpec] = {
        var map: [String: ControlSpec] = [:]
        for spec in allSpecs { map[spec.id] = spec }
        return map
    }()

    /// Lookup a spec by canonical id, or nil for non-core/effect ids
    /// (e.g. per-fractal formula params, which live in FormulaCatalog).
    static func spec(_ id: String) -> ControlSpec? { all[id] }
}

extension Comparable {
    /// Clamp into a closed range. Shared replacement for the `max(lo, min(hi, x))`
    /// idiom that was open-coded ~150× across RenderSettings and the Config types
    /// (and a `private` copy that used to live in `GestureConfig`). Generic over
    /// `Comparable` so it also covers the `Int` quality knobs.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

extension Float {
    /// Clamp into a control's authoritative range — the single source of truth.
    /// Prefer this over re-typing the numeric bounds at the setter / config / slider.
    func clamped(to spec: ControlSpec) -> Float {
        spec.clamp(self)
    }
}
