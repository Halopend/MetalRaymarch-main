//
//  SpaceWarpStackModel.swift
//  Threshold
//
//  The composable domain-transform ("Transformations") stack and its SINGLE SOURCE
//  OF TRUTH. Every transform is declared exactly once in `WarpCatalog` as a
//  `WarpDescriptor`; the UI, parameter seeding, and the CPU↔GPU bridge (Metal
//  function names) all derive from that one table. To add a transform you
//  touch four obvious spots and nothing else:
//    1. add a `SpaceWarpKind` case (raw value MUST match the GPU),
//    2. add its `WarpDescriptor` to `WarpCatalog.all`,
//    3. add the Metal `warp<Name>` (+ optional `warp<Name>DEScale`) function,
//    4. add the matching `applyWarpOp` / `warpOpDEScale` switch case in Shaders.metal.
//  Steps 3–4 are the only GPU-side edits; everything CPU-side flows from step 2.
//

import Foundation
import simd

/// The built-in domain-warp catalog. Raw values MUST match the GPU `applyWarpOp`
/// switch + `warp<Name>` functions in Shaders.metal.
enum SpaceWarpKind: Int32, CaseIterable, Identifiable, Codable, Sendable {
    case twist = 0
    case bend = 1
    case mirror = 2
    case boxFold = 3
    case sphereFold = 4
    case inversion = 5
    case kaleidoscope = 6
    case ripple = 7
    // Radial / nested / self-similar family.
    case circle = 8        // 2D radial fold in the XZ plane
    case shells = 9        // concentric spherical shells — radial repetition
    case scaleRepeat = 10  // log-radial Droste — self-similar repetition at growing scales
    // Reflection-group family (Coxeter).
    case coxeter = 11      // [p,q] rank-3 reflection group fold — kaleidoscopic / polyhedral symmetry
    // Plane-fold family (Mandelbulber kaleidoscopic IFS).
    case planeFold = 12    // reflect across a plane aimed by a normal VECTOR — the kIFS mirror
    // Mandelbulber-lineage primitives (abs-sort / lattice / scale / offset fold).
    case mengerFold = 13   // abs + descending-sort fold — Menger-sponge octahedral prep
    case tiling = 14       // domain repeat — infinite identical cells (round-lattice)
    case scale = 15        // uniform domain scale (IFS glue; strength = factor, deScale = factor)
    case offsetFold = 16   // p ↦ |p + c| — mirror fold about an off-origin centre
    case mandelboxStep = 17 // one exact box-fold → sphere-fold → scale → +original-p recurrence
    case icosahedralCut = 18 // fixed {5,3} reflection chamber — named icosahedral space cut
    case compressionShells = 19 // alternating signed radial regions at proportional scales

    var id: Int32 { rawValue }

    /// The single descriptor for this kind (all metadata + GPU bridge).
    var descriptor: WarpDescriptor { WarpCatalog.descriptor(for: self) }

    // Thin delegating accessors so call sites read `kind.displayName` etc.
    var displayName: String { descriptor.displayName }
    var icon: String { descriptor.icon }
    var amountLabel: String { descriptor.amountLabel }
    var usesAxis: Bool { descriptor.usesAxis }
    var axisLabel: String { descriptor.axisLabel }
    var defaultStrength: Float { descriptor.defaultStrength }
    var strengthRange: ClosedRange<Float> { descriptor.strengthRange }
    var params: [WarpParamSpec] { descriptor.params }
    var toggle: WarpToggleSpec? { descriptor.toggle }
    var sourceAngle: WarpAngleSpec? { descriptor.sourceAngle }
    var tagline: String { descriptor.tagline }
    var family: WarpFamily { descriptor.family }

    /// The fields of this transform that make sense to music-drive: always the master
    /// amount, plus whichever scalar slots and axis it actually uses. Drives the
    /// Music-tab field picker so users can't bind a param a transform doesn't have.
    var musicFields: [SpaceWarpField] {
        var fields: [SpaceWarpField] = [.strength]
        if params.contains(where: { $0.slot == 1 }) { fields.append(.param1) }
        if params.contains(where: { $0.slot == 2 }) { fields.append(.param2) }
        if usesAxis {
            fields += [.axisX, .axisY, .axisZ]
        } else if sourceAngle != nil {
            fields.append(.axisZ)
        }
        return fields
    }

    /// Human label for one music-drivable field, using this transform's own naming
    /// (e.g. `.strength` → "Twist", `.param1` → "Fold Limit", `.axisX` → "Offset X").
    func musicFieldLabel(_ field: SpaceWarpField) -> String {
        switch field {
        case .strength: return amountLabel
        case .param1:   return params.first(where: { $0.slot == 1 })?.label ?? "Param 1"
        case .param2:   return params.first(where: { $0.slot == 2 })?.label ?? "Param 2"
        case .axisX:    return "\(axisLabel) X"
        case .axisY:    return "\(axisLabel) Y"
        case .axisZ:    return sourceAngle?.label ?? "\(axisLabel) Z"
        }
    }

    /// Valid range for a music-driven field (used to clamp the audio-folded value).
    func range(for field: SpaceWarpField) -> ClosedRange<Float> {
        switch field {
        case .strength: return strengthRange
        case .param1:   return params.first(where: { $0.slot == 1 })?.range ?? 0...1
        case .param2:   return params.first(where: { $0.slot == 2 })?.range ?? 0...1
        case .axisZ:
            return sourceAngle?.range ?? -1...1
        case .axisX, .axisY:
            return -1...1   // matches the axis sliders
        }
    }

    /// One-line readable math for the "Under the hood" panel — what the GPU actually
    /// computes for this transform (p = sample point, op fields as labelled in the UI).
    var formula: String {
        switch self {
        case .twist:        return "p ↦ rotate p about axis by θ = strength · (p·axis) · 1.5"
        case .bend:         return "p ↦ bow p around axis by angle ∝ strength · |p⊥|"
        case .mirror:       return "p ↦ mix(p, |p|, strength)   — fold into the positive octant"
        case .boxFold:      return "p ↦ clamp(p, −L, L)·2 − p   — Mandelbox box fold (Hall of Mirrors → triangle-wave mirror tiling, cells 2L wide)"
        case .sphereFold:   return "if |p|<min: p·(max/min);  elif |p|<max: p·(max/|p|²)   — inflate the inner region"
        case .inversion:    return "p ↦ p · clamp(R² / |p|², 0.05, 20)   — turn space inside-out through a sphere"
        case .kaleidoscope: return "fold the polar angle of p.xz into one wedge of π / segments"
        case .ripple:       return "p ↦ p + axis · strength · sin((p·axis) · frequency)"
        case .circle:       return "sphere fold confined to the XZ plane (inner/outer radius)"
        case .shells:       return "r = |p|;  p ↦ p · (|r − d·round(r/d)| / r)   — fold radius to nearest shell"
        case .scaleRepeat:  return "p ↦ p · s^(−⌊log_s|p|⌋)   — map |p| into the base octave [1, s) (log-radial Droste)"
        case .coxeter:      return "rotate by −α; reflect into the {p,q} fundamental domain; rotate back by α; blend by strength"
        case .planeFold:    return "if p·n < d:  p −= 2 (p·n − d) · n · strength   — reflect when behind the plane"
        case .mengerFold:   return "p ↦ abs(p), then sort so |x|≥|y|≥|z|   — fold + permute into one octant (Menger prep)"
        case .tiling:       return "p ↦ p − size · round(p / size)   — wrap into an infinite lattice of size-wide cells"
        case .scale:        return "p ↦ p · scale   — uniform domain scale (DE ÷ scale); the fold→scale IFS step"
        case .offsetFold:   return "p ↦ mix(p, |p + c|, strength)   — mirror fold about an off-origin centre c"
        case .mandelboxStep:return "z ↦ scale · sphereFold(boxFold(z)) + p₀   — one Mandelbox recurrence step"
        case .icosahedralCut:return "reflect p into the fixed {5,3} icosahedral chamber across 3 mirror normals"
        case .compressionShells:
            return "cᵢ = R·{1−1/√2, φ⁻², φ⁻¹, 1};  bᵢ = 1−smoothstep(½,1,|r−cᵢ|/(wcᵢ));  r′ = r + (s/3)Σ(−1)ⁱwcᵢbᵢ"
        }
    }
}

/// Which field of a stack op the music layer drives. Music bindings default to
/// `.strength` (the only field bindable before this existed), so old scenes decode
/// unchanged. `param1`/`param2` map to the op's two scalar slots; `axisX/Y/Z` to the
/// direction/offset vector.
enum SpaceWarpField: String, Codable, CaseIterable, Sendable {
    case strength, param1, param2, axisX, axisY, axisZ

    var displayName: String {
        switch self {
        case .strength: return "Strength"
        case .param1:   return "Param 1"
        case .param2:   return "Param 2"
        case .axisX:    return "Axis X"
        case .axisY:    return "Axis Y"
        case .axisZ:    return "Axis Z"
        }
    }
}

/// Identifies one music-driven field of one stack slot (the key the audio engine
/// publishes offsets under, folded into the live op at snapshot time).
struct SpaceWarpFieldKey: Hashable, Sendable {
    let slot: Int
    let field: SpaceWarpField
}

/// A per-operator scalar slider, bound to op.p1 (slot 1) or op.p2 (slot 2).
struct WarpParamSpec: Identifiable {
    let slot: Int
    let label: String
    let icon: String
    let range: ClosedRange<Float>
    let defaultValue: Float
    var id: Int { slot }
}

/// A per-operator boolean OPTION (e.g. Box Fold "Hall of Mirrors"). Stored in the
/// op's `p2` slot as 0/1, so it only applies to transforms that don't use a slot-2
/// param. Flows live through the uniforms (no recompile) — the GPU warp fn branches.
struct WarpToggleSpec {
    let label: String
    let icon: String
}

/// Optional one-angle orientation control stored in the op's otherwise-unused
/// `axis.z` field. Coxeter uses it to rotate the complete mirror arrangement
/// around the vertical axis without changing the persisted or GPU struct layout.
struct WarpAngleSpec {
    let label: String
    let icon: String
    let range: ClosedRange<Float>
    let defaultValue: Float
}

/// Coarse family grouping for the add-menu, so related transforms cluster together
/// and the look-alikes are visibly distinguished (the radial trio Sphere Fold /
/// Sphere Inversion / Tube Fold sit side by side under one heading, etc.).
enum WarpFamily: String, CaseIterable {
    case mirror      = "Mirrors & Folds"
    case spaceCutting = "Space Cutting"
    case spherical   = "Spherical & Radial"
    case selfSimilar = "Self-Similar Repeats"
    case distortion  = "Bend & Wave"
}

/// Everything about one transform kind — the single source of truth bridging the
/// CPU (UI, params, codegen) and the GPU (`gpuApplyFn` / `gpuDEScaleFn`).
struct WarpDescriptor {
    let kind: SpaceWarpKind
    let displayName: String
    let icon: String
    let family: WarpFamily       // add-menu grouping
    let tagline: String          // one-line plain-language "what it does" (shown on the card)
    let amountLabel: String      // verb for the master-amount slider
    let usesAxis: Bool           // whether the direction axis is meaningful
    let axisLabel: String        // noun for the 3 axis sliders ("Axis" / "Offset" / …)
    let defaultAxis: SIMD3<Float> // seed axis/normal for a fresh op of this kind
    let defaultStrength: Float
    let strengthRange: ClosedRange<Float>
    let params: [WarpParamSpec]
    let toggle: WarpToggleSpec?  // optional boolean option (stored in op.p2)
    let sourceAngle: WarpAngleSpec? // optional vertical orientation (stored in op.axis.z)
    let gpuApplyFn: String       // Metal function name (must exist in Shaders.metal)
    let gpuDEScaleFn: String?    // Metal DE-divisor fn, or nil → contributes 1.0
    let blurb: String            // longer, contrastive description (shown under the hood)

    init(_ kind: SpaceWarpKind, _ displayName: String, icon: String, family: WarpFamily, tagline: String,
         amountLabel: String = "Amount",
         usesAxis: Bool = false, axisLabel: String = "Axis", defaultAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
         defaultStrength: Float = 1.0, strengthRange: ClosedRange<Float> = 0.0...2.0,
         params: [WarpParamSpec] = [], toggle: WarpToggleSpec? = nil,
         sourceAngle: WarpAngleSpec? = nil,
         gpuApplyFn: String, gpuDEScaleFn: String? = nil, blurb: String) {
        self.kind = kind; self.displayName = displayName; self.icon = icon
        self.family = family; self.tagline = tagline
        self.amountLabel = amountLabel; self.usesAxis = usesAxis; self.axisLabel = axisLabel; self.defaultAxis = defaultAxis
        self.defaultStrength = defaultStrength; self.strengthRange = strengthRange
        self.params = params; self.toggle = toggle; self.sourceAngle = sourceAngle
        self.gpuApplyFn = gpuApplyFn; self.gpuDEScaleFn = gpuDEScaleFn
        self.blurb = blurb
    }
}

enum WarpCatalog {
    /// The one place every transform is declared. Order = UI menu order.
    static let all: [WarpDescriptor] = [
        // ── Mirrors & Folds ─────────────────────────────────────────────────
        WarpDescriptor(.mirror, "Mirror Fold", icon: "square.on.square",
                       family: .mirror, tagline: "Fold every axis into one octant",
                       gpuApplyFn: "warpMirror",
                       blurb: "Folds each axis with abs() so the whole scene mirrors into one positive octant — the simplest reflection fold, applied on all three axes at once. Contrast: Plane Fold mirrors across ONE plane you aim; Kaleidoscope/Coxeter build repeating symmetry."),
        WarpDescriptor(.boxFold, "Box Fold", icon: "cube",
                       family: .mirror, tagline: "Fold back inside a box (Mandelbox)",
                       params: [WarpParamSpec(slot: 1, label: "Fold Limit", icon: "cube", range: 0.1...3.0, defaultValue: 1.0)],
                       toggle: WarpToggleSpec(label: "Hall of Mirrors", icon: "square.split.2x2"),
                       gpuApplyFn: "warpBoxFold",   // both modes isometric → no DE divisor
                       blurb: "The Mandelbox box fold: any coordinate past ±Fold-Limit is reflected back inside the box (once) — the classic Mandelbox building block. Turn on Hall of Mirrors to instead tile space into infinite IDENTICAL mirrored copies (the classic two-parallel-mirrors effect), each cell 2×Fold-Limit wide."),
        WarpDescriptor(.planeFold, "Plane Fold", icon: "triangle",
                       family: .mirror, tagline: "Reflect across a plane you aim",
                       amountLabel: "Fold",
                       usesAxis: true, defaultAxis: SIMD3<Float>(1, -1, 0),
                       defaultStrength: 1.0, strengthRange: 0.0...1.0,
                       params: [WarpParamSpec(slot: 1, label: "Distance", icon: "ruler", range: -2.0...2.0, defaultValue: 0.0)],
                       gpuApplyFn: "warpPlaneFold",   // conditional reflection (isometric) → no DE divisor
                       blurb: "Reflects space across ONE plane you aim with a normal vector (the Axis sliders) at the given Distance — Mandelbulber's kaleidoscopic-IFS fold (only points behind the plane are reflected). Stack several, each a mirror plane, to build Sierpinski / kaleidoscopic symmetry; add a Scale Repeat for self-similar depth. Contrast: Mirror Fold is fixed to the coordinate axes; this one points anywhere."),
        WarpDescriptor(.kaleidoscope, "Kaleidoscope", icon: "snowflake",
                       family: .mirror, tagline: "Fold the view into N wedges",
                       params: [WarpParamSpec(slot: 1, label: "Segments", icon: "snowflake", range: 2.0...16.0, defaultValue: 6.0)],
                       gpuApplyFn: "warpKaleido",
                       blurb: "Folds the angle around the vertical (Y) axis into N identical pie-slice wedges — classic flat kaleidoscope symmetry in the XZ plane. Contrast: Coxeter is full 3-D polyhedral symmetry; this is 2-D rotational."),
        WarpDescriptor(.coxeter, "Coxeter", icon: "hexagon",
                       family: .spaceCutting, tagline: "{p,q} polyhedral mirror symmetry",
                       amountLabel: "Mirror",
                       defaultStrength: 1.0, strengthRange: 0.0...1.0,
                       params: [WarpParamSpec(slot: 1, label: "p", icon: "hexagon", range: 2.0...8.0, defaultValue: 5.0),
                                WarpParamSpec(slot: 2, label: "q", icon: "hexagon", range: 2.0...8.0, defaultValue: 3.0)],
                       sourceAngle: WarpAngleSpec(
                           label: "Source Angle", icon: "rotate.3d",
                           range: -Float.pi...Float.pi, defaultValue: 0
                       ),
                       gpuApplyFn: "warpCoxeter",   // isometric (reflections) → no DE divisor
                       blurb: "Folds space into a {p,q} reflection group — full 3-D polyhedral mirror symmetry. {5,3}=icosahedral, {4,3}=octahedral, {3,3}=tetrahedral; 1/p+1/q<1/2 goes hyperbolic. Source Angle rotates the complete mirror arrangement around the vertical axis, while Mirror blends between untouched and fully folded space. Contrast: Kaleidoscope is flat N-fold; this is the polyhedral generalization."),
        WarpDescriptor(.icosahedralCut, "Icosahedral Space Cut", icon: "hexagon.fill",
                       family: .spaceCutting, tagline: "Cut space into a fixed {5,3} chamber",
                       amountLabel: "Cut",
                       defaultStrength: 1.0, strengthRange: 0.0...1.0,
                       gpuApplyFn: "warpCoxeter",   // fixed {5,3}; shares the reflection kernel
                       blurb: "Folds the entire domain into one fundamental chamber of icosahedral {5,3} symmetry. Its three mirror planes create twenty-face spatial repetition without exposing Coxeter notation. Cut blends from the untouched domain to the fully reflected chamber; use the general Coxeter option when you want tetrahedral, octahedral, Euclidean, or hyperbolic groups."),
        WarpDescriptor(.mengerFold, "Menger Fold", icon: "square.grid.3x3",
                       family: .mirror, tagline: "Fold + sort into one octant (Menger)",
                       gpuApplyFn: "warpMengerFold",   // abs + permutation → isometric, no DE divisor
                       blurb: "Folds every axis into the positive octant (abs) then sorts the coordinates so the largest is on X — the octahedral prep the Menger sponge is built from. Alone it mirrors the scene into one wedge; stack a Scale + Offset Fold after it to grow true Menger / Sierpinski self-similarity. Contrast: Mirror Fold folds without sorting; this adds the 3-way symmetry the sponge needs."),
        WarpDescriptor(.offsetFold, "Offset Fold", icon: "square.on.square.dashed",
                       family: .mirror, tagline: "Mirror fold about an off-centre point",
                       usesAxis: true, axisLabel: "Offset", defaultAxis: SIMD3<Float>(0.5, 0.0, 0.0),
                       defaultStrength: 1.0, strengthRange: 0.0...1.0,
                       gpuApplyFn: "warpOffsetFold",   // fold + translate → isometric, no DE divisor
                       blurb: "p ↦ |p + Offset|: a mirror fold whose crease is shifted off the origin by the Offset vector, so the two sides fold ASYMMETRICALLY. This broken symmetry is what turns a plain octant fold into Mandelbox-like structure. Contrast: Mirror Fold creases exactly on the axes; this one you can slide."),
        WarpDescriptor(.mandelboxStep, "Mandelbox Step", icon: "cube.transparent",
                       family: .selfSimilar,
                       tagline: "One complete Mandelbox recurrence",
                       amountLabel: "Scale",
                       defaultStrength: -1.5, strengthRange: -3.0...3.0,
                       params: [WarpParamSpec(slot: 1, label: "Fold Limit", icon: "cube", range: 0.1...3.0, defaultValue: 1.0),
                                WarpParamSpec(slot: 2, label: "Min Radius", icon: "smallcircle.filled.circle", range: 0.05...1.0, defaultValue: 0.5)],
                       gpuApplyFn: "warpMandelboxStep", gpuDEScaleFn: "warpMandelboxDEUpdate",
                       blurb: "Performs one full Mandelbox iteration: box fold, sphere fold, signed scale, then adds the ORIGINAL sample point p₀. Stack several identical steps over the Mandelbox Seed primitive to reveal the fractal one recurrence at a time. Unlike separately stacking Box Fold, Sphere Fold and Scale, this op retains p₀ and updates the derivative with the required +1 term."),
        // ── Spherical & Radial ──────────────────────────────────────────────
        WarpDescriptor(.sphereFold, "Sphere Fold", icon: "circle.circle",
                       family: .spherical, tagline: "Inflate the core outward (Mandelbox)",
                       params: [WarpParamSpec(slot: 1, label: "Min Radius", icon: "smallcircle.filled.circle", range: 0.05...2.0, defaultValue: 0.5),
                                WarpParamSpec(slot: 2, label: "Max Radius", icon: "circle.circle", range: 0.1...4.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpSphereFold", gpuDEScaleFn: "warpSphereFoldDEScale",
                       blurb: "Pushes points NEAR the origin outward — inflating/thickening the core — while leaving the region past Max Radius untouched. The Mandelbox 'sphere fold'. Contrast: Sphere Inversion SWAPS near↔far everywhere; Tube Fold does this only in the XZ plane."),
        WarpDescriptor(.inversion, "Sphere Inversion", icon: "globe",
                       family: .spherical, tagline: "Turn space inside-out (near ↔ far)",
                       params: [WarpParamSpec(slot: 1, label: "Radius", icon: "globe", range: 0.1...3.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpInversion", gpuDEScaleFn: "warpInversionDEScale",
                       blurb: "A true conformal inversion through a sphere of the given Radius: points inside fly outward and points outside collapse inward — space turned inside-out. Contrast: Sphere Fold only inflates the inside (the outside stays put); this one SWAPS near and far across the whole field."),
        WarpDescriptor(.circle, "Tube Fold", icon: "cylinder",
                       family: .spherical, tagline: "Sphere fold in the XZ plane → tubes",
                       params: [WarpParamSpec(slot: 1, label: "Inner Radius", icon: "smallcircle.filled.circle", range: 0.05...2.0, defaultValue: 0.5),
                                WarpParamSpec(slot: 2, label: "Outer Radius", icon: "circle.circle", range: 0.1...4.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpCircle", gpuDEScaleFn: "warpCircleDEScale",
                       blurb: "Sphere Fold restricted to the horizontal XZ plane — the vertical (Y) axis is left untouched — so it carves vertical tube / cylinder structure instead of spherical blobs. Contrast: Sphere Fold is fully 3-D; this is its 2-D-in-the-plane sibling. (Formerly labelled 'Circle'.)"),
        WarpDescriptor(.shells, "Shells", icon: "circle.dotted",
                       family: .spherical, tagline: "Repeat in concentric shells",
                       params: [WarpParamSpec(slot: 1, label: "Spacing", icon: "circle.dotted", range: 0.1...4.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpShells",
                       blurb: "Folds the radius into evenly-spaced concentric shells, repeating the fractal outward like onion layers at a FIXED spacing. Contrast: Scale Repeat spaces its copies so they GROW; these shells are equal thickness."),
        WarpDescriptor(.compressionShells, "Compression Shells", icon: "circle.hexagongrid",
                       family: .spherical, tagline: "Alternate positive and negative scale regions",
                       amountLabel: "Compression",
                       defaultStrength: 0.7, strengthRange: 0.0...1.5,
                       params: [
                           WarpParamSpec(slot: 1, label: "Outer Radius", icon: "circle", range: 0.1...4.0, defaultValue: 1.0),
                           WarpParamSpec(slot: 2, label: "Region Width", icon: "arrow.left.and.right", range: 0.02...0.12, defaultValue: 0.08),
                       ],
                       gpuApplyFn: "warpCompressionShells",
                       gpuDEScaleFn: "warpCompressionShellsDEScale",
                       blurb: "Places four flat-core radial regions at proportional radii: the outer size, two nested golden/Fibonacci scales (φ⁻¹ and φ⁻²), and 1−1/√2 ≈ 0.292893. Their signs alternate positive/negative, so one shell compresses while the next releases. Space between the regions is untouched; this is not a continuous ripple."),
        // ── Self-Similar Repeats ────────────────────────────────────────────
        WarpDescriptor(.scaleRepeat, "Scale Repeat", icon: "infinity",
                       family: .selfSimilar, tagline: "Self-similar copies at growing scale",
                       params: [WarpParamSpec(slot: 1, label: "Scale Factor", icon: "infinity", range: 1.1...4.0, defaultValue: 2.0)],
                       gpuApplyFn: "warpScaleRepeat", gpuDEScaleFn: "warpScaleRepeatDEScale",
                       blurb: "Repeats the fractal self-similarly at exponentially GROWING scales (log-radial Droste) — each ring ×Scale-Factor bigger than the last, an infinite-zoom nesting. Contrast: Shells repeat at a FIXED spacing; this one grows."),
        WarpDescriptor(.tiling, "Tiling", icon: "grid",
                       family: .selfSimilar, tagline: "Repeat space into an infinite lattice",
                       params: [WarpParamSpec(slot: 1, label: "Cell Size", icon: "grid", range: 0.2...6.0, defaultValue: 2.0)],
                       gpuApplyFn: "warpTiling",   // per-cell translation → isometric, no DE divisor
                       blurb: "Wraps space into an infinite grid of identical cells of the given Cell Size, tiling the whole fractal in every direction like a crystal lattice. Contrast: Shells/Scale Repeat tile RADIALLY (outward rings); this tiles the CARTESIAN grid."),
        WarpDescriptor(.scale, "Scale", icon: "arrow.up.left.and.arrow.down.right.circle",
                       family: .selfSimilar, tagline: "Uniform zoom — the IFS fold→scale step",
                       amountLabel: "Scale", defaultStrength: 2.0, strengthRange: -3.0...3.0,
                       gpuApplyFn: "warpScale", gpuDEScaleFn: "warpScaleDEScale",
                       blurb: "A plain uniform scale of the domain (the master slider IS the factor). On its own it just zooms; its real job is BETWEEN folds — a fold then a Scale then another fold is the Iterated-Function-System step that grows Sierpinski / Menger structure. Stack fold→Scale→fold→Scale for a few levels of true self-similarity. Contrast: Scale Repeat bakes infinite growing copies in one op; this is the single, composable scale you place by hand."),
        // ── Bend & Wave (non-fold distortions) ──────────────────────────────
        WarpDescriptor(.twist, "Twist", icon: "tornado",
                       family: .distortion, tagline: "Screw space around an axis",
                       amountLabel: "Twist", usesAxis: true, defaultStrength: 0.6,
                       gpuApplyFn: "warpTwist",
                       blurb: "Rotates space progressively along an axis — the further along the axis, the more rotation — for a screw / vortex shear. Contrast: Bend curves around an axis; Twist spins around it."),
        WarpDescriptor(.bend, "Bend", icon: "wind",
                       family: .distortion, tagline: "Bow space around an axis",
                       amountLabel: "Bend", usesAxis: true, defaultStrength: 0.6,
                       gpuApplyFn: "warpBend",
                       blurb: "Bows space around an axis, curving straight structure into arcs. Contrast: Twist rotates about the axis; Bend curves toward it."),
        WarpDescriptor(.ripple, "Ripple", icon: "waveform.path",
                       family: .distortion, tagline: "Wavy displacement along an axis",
                       amountLabel: "Ripple", usesAxis: true, defaultStrength: 0.6,
                       params: [WarpParamSpec(slot: 1, label: "Frequency", icon: "waveform.path", range: 0.1...8.0, defaultValue: 2.0)],
                       gpuApplyFn: "warpRipple",
                       blurb: "Displaces space back and forth along an axis in a sine wave — a corrugated / accordion ripple at the given Frequency."),
    ]

    private static let byKind: [SpaceWarpKind: WarpDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    static func descriptor(for kind: SpaceWarpKind) -> WarpDescriptor {
        byKind[kind] ?? all[0]
    }

    // MARK: - Pack recipes (not exposed by the first-run equation mapper)

    /// Curated stacks retained for a future optional transformations pack. The base
    /// experience does not surface them: users map individual equations first. Each
    /// `make()` returns a fresh set of editable ops with new UUIDs.
    static let recipes: [WarpRecipe] = [
        WarpRecipe(id: "core.icosahedral-bloom", "Icosahedral Bloom",
                   icon: "hexagon.fill",
                   blurb: "A {5,3} icosahedral reflection group with a soft sphere-fold core — dense polyhedral mirror symmetry.") {
            [ warpOp(.icosahedralCut),
              warpOp(.sphereFold, strength: 0.6, p1: 0.5, p2: 1.4),
              warpOp(.scaleRepeat, strength: 1.0, p1: 2.0) ]
        },
        WarpRecipe(id: "core.menger-blocks", "Menger Blocks",
                   icon: "square.grid.3x3.fill",
                   blurb: "Abs-sort fold → scale → offset → fold: two levels of the Menger sponge's boxy self-similarity.") {
            [ warpOp(.mengerFold),
              warpOp(.scale, strength: 2.6),
              warpOp(.offsetFold, strength: 1.0, axis: SIMD3<Float>(1, 1, 0)),
              warpOp(.mengerFold) ]
        },
        WarpRecipe(id: "core.kaleido-tunnel", "Kaleido Tunnel",
                   icon: "snowflake",
                   blurb: "Lattice repeat → 6-fold kaleidoscope → a slow twist: a receding tunnel with rotational symmetry.") {
            [ warpOp(.tiling, strength: 1.0, p1: 3.0),
              warpOp(.kaleidoscope, strength: 1.0, p1: 6.0),
              warpOp(.twist, strength: 0.4, axis: SIMD3<Float>(0, 1, 0)) ]
        },
        WarpRecipe(id: "core.nested-spheres", "Nested Spheres",
                   icon: "circle.circle.fill",
                   blurb: "Turn space inside-out, then repeat it in concentric shells — Apollonian-flavoured nested bubbles.") {
            [ warpOp(.inversion, strength: 1.0, p1: 1.0),
              warpOp(.shells, strength: 1.0, p1: 1.0),
              warpOp(.mirror, strength: 1.0) ]
        },
        WarpRecipe(id: "core.sierpinski-web", "Sierpinski Web",
                   icon: "triangle.fill",
                   blurb: "Three aimed plane-fold mirrors then a ×2 scale — the classic tetrahedral kaleidoscopic-IFS step, a couple levels deep.") {
            [ warpOp(.planeFold, strength: 1.0, p1: 0.0, axis: SIMD3<Float>(1, -1, 0)),
              warpOp(.planeFold, strength: 1.0, p1: 0.0, axis: SIMD3<Float>(0, 1, -1)),
              warpOp(.planeFold, strength: 1.0, p1: 0.0, axis: SIMD3<Float>(1, 0, -1)),
              warpOp(.scale, strength: 2.0) ]
        },
    ]

    /// A random "Surprise Me" stack (2–4 ops) drawn from a palette weighted toward the
    /// structure-forming folds/repeats so the result reliably looks like *something*.
    /// Params and axes are randomized within each op's valid ranges.
    static let randomPalette: [SpaceWarpKind] = [
            .mirror, .boxFold, .sphereFold, .inversion, .kaleidoscope, .mengerFold,
            .tiling, .scaleRepeat, .shells, .compressionShells, .coxeter, .twist,
            .offsetFold, .circle,
        ]

    /// Eligibility is mandatory so a future pack UI cannot accidentally construct
    /// locked Education operators. Just Use can pass the complete palette.
    static func randomStack(
        from eligibleKinds: Set<SpaceWarpKind>
    ) -> [SpaceWarpOpValue]? {
        let palette = randomPalette.filter(eligibleKinds.contains)
        guard !palette.isEmpty else { return nil }
        let n = Int.random(in: 2...4)
        return (0..<n).map { _ in
            let kind = palette.randomElement()!
            var op = SpaceWarpOpValue(kind: kind)
            let sr = kind.strengthRange
            op.strength = Float.random(in: Swift.max(sr.lowerBound, 0.4)...sr.upperBound)
            for spec in kind.params {
                let v = Float.random(in: spec.range)
                if spec.slot == 1 { op.p1 = v } else { op.p2 = v }
            }
            if kind.usesAxis {
                op.axis = SIMD3<Float>(.random(in: -1...1), .random(in: -1...1), .random(in: -1...1))
            }
            return op
        }
    }
}

/// A named, curated starting stack reserved for an optional transformations pack.
struct WarpRecipeID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct WarpRecipe: Identifiable, Sendable {
    let id: WarpRecipeID
    let name: String
    let icon: String
    let blurb: String
    private let build: @Sendable () -> [SpaceWarpOpValue]

    /// Ordered unique requirements are derived from the actual constructed stack,
    /// so a pack author cannot accidentally omit a produced operator from gating.
    var requiredKinds: [SpaceWarpKind] {
        var seen: Set<SpaceWarpKind> = []
        return build().compactMap { op in
            guard let kind = SpaceWarpKind(rawValue: op.type),
                  seen.insert(kind).inserted else { return nil }
            return kind
        }
    }

    init(id: String, _ name: String, icon: String, blurb: String,
         make: @escaping @Sendable () -> [SpaceWarpOpValue]) {
        self.id = WarpRecipeID(rawValue: id)
        self.name = name
        self.icon = icon
        self.blurb = blurb
        self.build = make
    }

    /// Construction requires an explicit per-kind authorization. Validation uses
    /// each produced op's raw discriminator, so unknown imported kinds fail closed.
    func instantiate(
        ifAllowed isAllowed: (SpaceWarpKind) -> Bool
    ) -> [SpaceWarpOpValue]? {
        let ops = build()
        guard ops.allSatisfy({ op in
            guard let kind = SpaceWarpKind(rawValue: op.type) else { return false }
            return isAllowed(kind)
        }) else { return nil }
        return ops
    }
}

/// How a repeat group feeds one pass into the next. Ordinary groups simply repeat
/// their child pipeline. A Mandelbox recurrence additionally adds the point that
/// entered the group after each pass (the visible group-level `+ p₀` feedback).
enum SpaceWarpGroupMode: String, Codable, Hashable, Sendable {
    case repeatOutput
    case mandelboxRecurrence
}

/// Pack-ready snapshots for constructing a Mandelbox from a terminal sphere.
/// The first four stages expose the individual techniques. The last two place the
/// same three editable transforms in a recurrence group and iterate that series.
enum MandelboxConstructionStage: Int, CaseIterable, Identifiable {
    case primitive
    case boxFold
    case sphereFold
    case scaled
    case threeIterations
    case sixIterations

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .primitive: return "0 · Terminal Sphere"
        case .boxFold: return "1 · Add Box Fold"
        case .sphereFold: return "2 · Add Sphere Fold"
        case .scaled: return "3 · Add Scale"
        case .threeIterations: return "4 · Repeat 3 Times"
        case .sixIterations: return "5 · Final Mandelbox (6×)"
        }
    }

    var icon: String {
        switch self {
        case .primitive: return "circle.fill"
        case .boxFold: return "cube"
        case .sphereFold: return "circle.circle"
        case .scaled: return "arrow.up.left.and.arrow.down.right"
        case .threeIterations, .sixIterations: return "cube.transparent"
        }
    }

    var stack: [SpaceWarpOpValue] {
        switch self {
        case .primitive:
            return []
        case .boxFold:
            return [warpOp(.boxFold, p1: 1.0)]
        case .sphereFold:
            return [warpOp(.boxFold, p1: 1.0),
                    warpOp(.sphereFold, strength: 1.0, p1: 0.5, p2: 1.0)]
        case .scaled:
            return [warpOp(.boxFold, p1: 1.0),
                    warpOp(.sphereFold, strength: 1.0, p1: 0.5, p2: 1.0),
                    warpOp(.scale, strength: -1.5)]
        case .threeIterations:
            return Self.recurrence(count: 3)
        case .sixIterations:
            return Self.recurrence(count: 6)
        }
    }

    private static func recurrence(count: Int) -> [SpaceWarpOpValue] {
        warpGroup([
            warpOp(.boxFold, p1: 1.0),
            warpOp(.sphereFold, strength: 1.0, p1: 0.5, p2: 1.0),
            warpOp(.scale, strength: -1.5),
        ], iterations: count, mode: .mandelboxRecurrence)
    }
}

/// Mark a contiguous series as one repeat group. The flat editable array remains
/// backward-compatible; shared metadata tells the packer/GPU to feed each pass's
/// output into the next without duplicating the operators.
func warpGroup(_ ops: [SpaceWarpOpValue], iterations: Int,
               mode: SpaceWarpGroupMode = .repeatOutput) -> [SpaceWarpOpValue] {
    guard !ops.isEmpty else { return [] }
    let groupID = UUID()
    let clamped = min(max(iterations, 1), Int(kMaxSpaceWarpGroupIterations))
    return ops.map { value in
        var op = value
        op.groupID = groupID
        op.groupIterations = clamped
        op.groupMode = mode
        return op
    }
}

/// Build one recipe op from its kind defaults, overriding only the fields a recipe
/// cares about. Each call mints a fresh UUID so a recipe can be applied repeatedly
/// without ForEach id collisions.
func warpOp(_ kind: SpaceWarpKind, strength: Float? = nil,
            p1: Float? = nil, p2: Float? = nil, axis: SIMD3<Float>? = nil) -> SpaceWarpOpValue {
    var op = SpaceWarpOpValue(kind: kind)
    if let strength { op.strength = strength }
    if let p1 { op.p1 = p1 }
    if let p2 { op.p2 = p2 }
    if let axis { op.axis = axis }
    return op
}

/// One operator instance in the stack (Swift-side editable model). Mirrors the
/// packed C `SpaceWarpOp`.
struct SpaceWarpOpValue: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var type: Int32
    var strength: Float
    var p1: Float
    var p2: Float
    var axis: SIMD3<Float>
    var isEnabled: Bool
    /// Contiguous ops sharing an id execute as one repeat group. Optional fields
    /// make pre-group scene files decode as the original flat, one-pass stack.
    var groupID: UUID?
    var groupIterations: Int?
    var groupMode: SpaceWarpGroupMode?

    var kind: SpaceWarpKind { SpaceWarpKind(rawValue: type) ?? .twist }

    /// A fresh op seeded with sensible defaults for `kind` (from its descriptor).
    init(kind: SpaceWarpKind) {
        let d = kind.descriptor
        self.id = UUID()
        self.type = kind.rawValue
        self.strength = d.defaultStrength
        self.p1 = d.params.first(where: { $0.slot == 1 })?.defaultValue ?? 0
        self.p2 = d.params.first(where: { $0.slot == 2 })?.defaultValue ?? 0
        self.axis = d.defaultAxis
        if let sourceAngle = d.sourceAngle {
            self.axis.z = sourceAngle.defaultValue
        }
        self.isEnabled = true
        self.groupID = nil
        self.groupIterations = nil
        self.groupMode = nil
    }

    init(id: UUID = UUID(), type: Int32, strength: Float, p1: Float, p2: Float,
         axis: SIMD3<Float>, isEnabled: Bool, groupID: UUID? = nil,
         groupIterations: Int? = nil, groupMode: SpaceWarpGroupMode? = nil) {
        self.id = id; self.type = type; self.strength = strength
        self.p1 = p1; self.p2 = p2; self.axis = axis; self.isEnabled = isEnabled
        self.groupID = groupID; self.groupIterations = groupIterations
        self.groupMode = groupMode
    }

    var effectiveGroupIterations: Int {
        min(max(groupIterations ?? 1, 1), Int(kMaxSpaceWarpGroupIterations))
    }

    var effectiveGroupMode: SpaceWarpGroupMode {
        groupMode ?? .repeatOutput
    }

    /// Add a music offset to one field, clamped to that field's range for this kind.
    /// Used by the snapshot fold so audio modulation stays inside valid bounds.
    mutating func applyAudioDelta(_ delta: Float, field: SpaceWarpField) {
        let r = kind.range(for: field)
        let clamp = { (v: Float) in min(r.upperBound, max(r.lowerBound, v + delta)) }
        switch field {
        case .strength: strength = clamp(strength)
        case .param1:   p1 = clamp(p1)
        case .param2:   p2 = clamp(p2)
        case .axisX:    axis.x = clamp(axis.x)
        case .axisY:    axis.y = clamp(axis.y)
        case .axisZ:    axis.z = clamp(axis.z)
        }
    }
}

extension Array where Element == SpaceWarpOpValue {
    /// Re-establish the "one groupID names ONE contiguous run" invariant on a stack
    /// decoded from a file. Every in-app edit preserves contiguity (grouping requires
    /// adjacency, moves carry whole units, `warpGroup` mints a fresh id per slice),
    /// but scene/preset JSON is external input: a hand-edited, merged, or foreign
    /// file can repeat a groupID after an interloper op. The Transformations editor
    /// (StackUnit ForEach identity, group cards, groupID-scoped mutations) all assume
    /// the invariant, so heal at decode instead of trusting it: each later fragment
    /// keeps its ops and repeat metadata but becomes its OWN group with a fresh id
    /// ([G, x, G] → [G, x, G′]). The GPU packer already encodes non-adjacent runs as
    /// independent groups, so this changes nothing about how the stack renders.
    func normalizingGroupContiguity() -> [SpaceWarpOpValue] {
        var healed: [SpaceWarpOpValue] = []
        healed.reserveCapacity(count)
        var closedGroups: Set<UUID> = []  // ids whose contiguous run has already ended
        var currentRun: UUID?             // groupID of the run being walked (nil = ungrouped)
        var replacementID: UUID?          // fresh id while the current run re-uses a closed id
        for var op in self {
            if op.groupID != currentRun {
                // Run boundary: the group that just ended can never legally continue.
                if let finished = currentRun { closedGroups.insert(finished) }
                currentRun = op.groupID
                // Per-FRAGMENT replacement (not a per-groupID map): [G, x, G, y, G]
                // must yield THREE distinct groups, or the heal re-splits itself.
                replacementID = nil
                if let groupID = op.groupID, closedGroups.contains(groupID) {
                    replacementID = UUID()
                }
            }
            if let replacementID { op.groupID = replacementID }
            healed.append(op)
        }
        return healed
    }
}

// The warp stack renders via the bundled, count-driven runtime loop
// (`spaceWarpStackTransform` in Shaders.metal), driven entirely by the per-frame
// `cSpaceWarpStack` pack below — so EVERY edit (structural or slider) is a live
// uniform write and nothing recompiles a shader.
//
// A former `SpaceWarpStackCodegen` emitted an UNROLLED, type-specialized variant
// compiled into a swapped-in library on each structural edit. It was removed: that
// unroll FROZE the op count at edit time, while the live per-frame pack's count
// depends on slider values (the simplifier drops strength≤0 ops and coalesces
// full-strength folds). The two desynced, so slider drags fed array slots the
// frozen shader never read — the sliders went dead. Uniform-driven removes the
// freeze (and the per-edit recompile hitch). If a specialized variant is ever
// reintroduced for speed, its op count must NOT depend on live-edited values.

/// Convert a model op into a GPU-READY op. All frame-uniform math that the Metal
/// warp functions used to redo every march step — axis normalization, the `max()`
/// floor clamps, squared radii, `π/N`, `log(scale)` — is done HERE, once per frame.
/// The GPU functions then just read the precomputed scalars (see `SpaceWarpOp` in
/// ShaderTypes.h). Field meanings become precomputed/type-specific:
///   • axisX/Y/Z = normalized axis (twist/bend/ripple)
///   • Coxeter axisZ = user-authored vertical source angle (radians)
///   • p1 = boxFold L · sphereFold/circle minR² · inversion R² · kaleido seg(π/N)
///          · ripple freq · shells spacing · scaleRepeat log(scale)
///   • p2 = sphereFold/circle maxR²
/// The clamps MUST stay byte-for-byte identical to the (now-removed) GPU clamps.
private func precomputedGPUOp(from v: SpaceWarpOpValue) -> SpaceWarpOp {
    let aLen = simd_length(v.axis)
    let n = aLen > 1e-6 ? v.axis / aLen : SIMD3<Float>(0, 1, 0)   // pre-normalized axis
    var p1 = v.p1
    var p2 = v.p2
    switch v.kind {
    case .twist, .bend, .mirror, .planeFold, .mengerFold, .scale:
        break                  // axis pre-normalized at top; planeFold p1 = plane distance;
                               // mengerFold uses no fields; scale reads strength as the factor
    case .tiling:
        p1 = max(v.p1, 0.05)                                    // cell size
    case .offsetFold:
        // Offset fold uses the axis as a RAW translation (crease centre), NOT a
        // normalized direction — return it unchanged, bypassing the normalize below.
        return SpaceWarpOp(type: v.type, strength: v.strength, p1: v.p1, p2: v.p2,
                           axisX: v.axis.x, axisY: v.axis.y, axisZ: v.axis.z, groupControl: 0)
    case .mandelboxStep:
        p1 = max(v.p1, 0.01)                                    // box-fold limit
        let minR = min(max(v.p2, 0.01), 0.99)
        p2 = minR * minR                                        // min radius squared; fixed radius² = 1
    case .ripple:
        p1 = max(v.p1, 0.01)                                     // freq
    case .boxFold:
        p1 = max(v.p1, 0.01)                                     // fold limit L
    case .sphereFold:
        let minR = max(v.p1, 0.01); let maxR = max(v.p2, minR + 0.01)
        p1 = minR * minR; p2 = maxR * maxR
    case .inversion:
        let r = max(v.p1, 0.05); p1 = r * r                      // R²
    case .kaleidoscope:
        let segments = max(v.p1.rounded(), 2); p1 = Float.pi / segments   // seg
    case .circle:
        let minR = max(v.p1, 0.05); let maxR = max(v.p2, minR + 0.05)
        p1 = minR * minR; p2 = maxR * maxR
    case .shells:
        p1 = max(v.p1, 0.1)                                      // spacing d
    case .compressionShells:
        p1 = max(v.p1, 0.1)                                      // outer radius R
        p2 = min(max(v.p2, 0.02), 0.12)                          // relative half-width w
    case .scaleRepeat:
        p1 = logf(max(v.p1, 1.1))                                // log(scale), float-precision (matches GPU log)
    case .coxeter, .icosahedralCut:
        // [p,q] rank-3 reflection group → the 3 mirror normals (through the origin):
        //   n0 = (1, 0, 0)                            [implicit in the shader]
        //   n1 = (−cos π/p, sin π/p, 0)               → p1, p2
        //   n2 = (0, −cos(π/q)/sin(π/p), √(1−a²))      → axisX, axisY
        //   source angle around Y                       → axisZ (Coxeter only)
        // Their Gram inner products encode the dihedral orders (n0·n1→p, n1·n2→q,
        // n0·n2 = 0). Real n2.z needs 1/p+1/q ≥ 1/2 (finite/Euclidean); the hyperbolic
        // case clamps to 0 and still folds gracefully (just no convergence).
        let pp: Float = v.kind == .icosahedralCut ? 5 : max(v.p1.rounded(), 2)
        let qq: Float = v.kind == .icosahedralCut ? 3 : max(v.p2.rounded(), 2)
        let sp = sinf(Float.pi / pp)
        let cp = cosf(Float.pi / pp)
        let cq = cosf(Float.pi / qq)
        let a = -cq / sp
        let b = (1 - a * a > 0) ? sqrtf(1 - a * a) : 0
        let sourceAngle = v.kind == .coxeter ? v.axis.z : 0
        return SpaceWarpOp(type: v.type, strength: v.strength,
                           p1: -cp, p2: sp, axisX: a, axisY: b,
                           axisZ: sourceAngle, groupControl: 0)
    }
    return SpaceWarpOp(type: v.type, strength: v.strength, p1: p1, p2: p2,
                       axisX: n.x, axisY: n.y, axisZ: n.z, groupControl: 0)
}

/// Pack the enabled ops (in order) into the GPU `SpaceWarpStack`, precomputing each
/// (`precomputedGPUOp`). Disabled ops are dropped; the list is capped at `kMaxSpaceWarpOps`.
func cSpaceWarpStack(from ops: [SpaceWarpOpValue]) -> SpaceWarpStack {
    var stack = SpaceWarpStack()
    let maxN = Int(kMaxSpaceWarpOps)
    // Same collapse the codegen path applies, so the packed buffer and the unrolled
    // shader index identical ops (SpaceWarpStackSimplifier is pure → both agree).
    let active = SpaceWarpStackSimplifier.simplify(ops.filter { $0.isEnabled }).prefix(maxN)
    withUnsafeMutablePointer(to: &stack.ops) { tuplePtr in
        tuplePtr.withMemoryRebound(to: SpaceWarpOp.self, capacity: maxN) { base in
            for (i, v) in active.enumerated() {
                base[i] = precomputedGPUOp(from: v)
            }
            // Encode each contiguous repeat group on its first packed operator.
            // Disabled/identity operators have already been removed, so the encoded
            // length describes exactly the operators the GPU will execute.
            var start = 0
            while start < active.count {
                guard let groupID = active[start].groupID else { start += 1; continue }
                var end = start + 1
                while end < active.count && active[end].groupID == groupID { end += 1 }
                let length = min(end - start, 0xff)
                let iterations = active[start].effectiveGroupIterations
                // Layout stays inside the former 32-bit padding slot:
                // low byte = group length, next byte = passes, bit 16 = +p₀ feedback.
                let feedback = active[start].effectiveGroupMode == .mandelboxRecurrence
                    ? (1 << 16) : 0
                base[start].groupControl = Int32(feedback | (iterations << 8) | length)
                start = end
            }
        }
    }
    stack.count = Int32(active.count)
    return stack
}

/// Traditional name for the rank-3 Coxeter group [p,q] (Schläfli {p,q}). Spherical
/// (1/p+1/q > 1/2) names the polyhedral families; = 1/2 is Euclidean, < 1/2 hyperbolic.
func coxeterSymmetryName(p: Int, q: Int) -> String {
    let recip = 1.0 / Double(p) + 1.0 / Double(q)
    if recip > 0.5 + 1e-9 {
        if p == 2 || q == 2 { return "Dihedral" }
        switch Set([p, q]) {
        case [3]:    return "Tetrahedral"
        case [3, 4]: return "Octahedral"
        case [3, 5]: return "Icosahedral"
        default:     return "Spherical"
        }
    } else if abs(recip - 0.5) < 1e-9 {
        return "Euclidean"
    } else {
        return "Hyperbolic"
    }
}
