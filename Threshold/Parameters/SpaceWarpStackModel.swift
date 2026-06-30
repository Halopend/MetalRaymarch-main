//
//  SpaceWarpStackModel.swift
//  Threshold
//
//  The composable domain-transform ("Transformations") stack and its SINGLE SOURCE
//  OF TRUTH. Every transform is declared exactly once in `WarpCatalog` as a
//  `WarpDescriptor`; the UI, parameter seeding, codegen, and the CPU↔GPU bridge
//  (Metal function names) all derive from that one table. To add a transform you
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
enum SpaceWarpKind: Int32, CaseIterable, Identifiable, Codable {
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

    var id: Int32 { rawValue }

    /// The single descriptor for this kind (all metadata + GPU bridge).
    var descriptor: WarpDescriptor { WarpCatalog.descriptor(for: self) }

    // Thin delegating accessors so call sites read `kind.displayName` etc.
    var displayName: String { descriptor.displayName }
    var icon: String { descriptor.icon }
    var amountLabel: String { descriptor.amountLabel }
    var usesAxis: Bool { descriptor.usesAxis }
    var defaultStrength: Float { descriptor.defaultStrength }
    var strengthRange: ClosedRange<Float> { descriptor.strengthRange }
    var params: [WarpParamSpec] { descriptor.params }
    var toggle: WarpToggleSpec? { descriptor.toggle }
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

/// Everything about one transform kind — the single source of truth bridging the
/// CPU (UI, params, codegen) and the GPU (`gpuApplyFn` / `gpuDEScaleFn`).
struct WarpDescriptor {
    let kind: SpaceWarpKind
    let displayName: String
    let icon: String
    let amountLabel: String      // verb for the master-amount slider
    let usesAxis: Bool           // whether the direction axis is meaningful
    let defaultStrength: Float
    let strengthRange: ClosedRange<Float>
    let params: [WarpParamSpec]
    let toggle: WarpToggleSpec?  // optional boolean option (stored in op.p2)
    let gpuApplyFn: String       // Metal function name (must exist in Shaders.metal)
    let gpuDEScaleFn: String?    // Metal DE-divisor fn, or nil → contributes 1.0
    let blurb: String

    init(_ kind: SpaceWarpKind, _ displayName: String, icon: String, amountLabel: String = "Amount",
         usesAxis: Bool = false, defaultStrength: Float = 1.0, strengthRange: ClosedRange<Float> = 0.0...2.0,
         params: [WarpParamSpec] = [], toggle: WarpToggleSpec? = nil, gpuApplyFn: String, gpuDEScaleFn: String? = nil, blurb: String) {
        self.kind = kind; self.displayName = displayName; self.icon = icon
        self.amountLabel = amountLabel; self.usesAxis = usesAxis
        self.defaultStrength = defaultStrength; self.strengthRange = strengthRange
        self.params = params; self.toggle = toggle
        self.gpuApplyFn = gpuApplyFn; self.gpuDEScaleFn = gpuDEScaleFn
        self.blurb = blurb
    }
}

enum WarpCatalog {
    /// The one place every transform is declared. Order = UI menu order.
    static let all: [WarpDescriptor] = [
        WarpDescriptor(.twist, "Twist", icon: "tornado", amountLabel: "Twist", usesAxis: true, defaultStrength: 0.6,
                       gpuApplyFn: "warpTwist",
                       blurb: "Rotate space progressively along an axis."),
        WarpDescriptor(.bend, "Bend", icon: "wind", amountLabel: "Bend", usesAxis: true, defaultStrength: 0.6,
                       gpuApplyFn: "warpBend",
                       blurb: "Bow space around an axis."),
        WarpDescriptor(.mirror, "Mirror Fold", icon: "square.on.square",
                       gpuApplyFn: "warpMirror",
                       blurb: "Reflect space into mirror-symmetric copies."),
        WarpDescriptor(.boxFold, "Box Fold", icon: "cube",
                       params: [WarpParamSpec(slot: 1, label: "Fold Limit", icon: "cube", range: 0.1...3.0, defaultValue: 1.0)],
                       toggle: WarpToggleSpec(label: "Hall of Mirrors", icon: "square.split.2x2"),
                       gpuApplyFn: "warpBoxFold",
                       blurb: "Fold coordinates back inside a box (the Mandelbox fold), once — or infinitely with Hall of Mirrors (mirror-tiled copies in every direction)."),
        WarpDescriptor(.sphereFold, "Sphere Fold", icon: "circle.circle",
                       params: [WarpParamSpec(slot: 1, label: "Min Radius", icon: "smallcircle.filled.circle", range: 0.05...2.0, defaultValue: 0.5),
                                WarpParamSpec(slot: 2, label: "Max Radius", icon: "circle.circle", range: 0.1...4.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpSphereFold", gpuDEScaleFn: "warpSphereFoldDEScale",
                       blurb: "Inflate the inner region radially (Mandelbox sphere fold)."),
        WarpDescriptor(.inversion, "Spherical Inversion", icon: "globe",
                       params: [WarpParamSpec(slot: 1, label: "Radius", icon: "globe", range: 0.1...3.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpInversion", gpuDEScaleFn: "warpInversionDEScale",
                       blurb: "Turn space inside-out through a sphere."),
        WarpDescriptor(.kaleidoscope, "Kaleidoscope", icon: "snowflake",
                       params: [WarpParamSpec(slot: 1, label: "Segments", icon: "snowflake", range: 2.0...16.0, defaultValue: 6.0)],
                       gpuApplyFn: "warpKaleido",
                       blurb: "Fold the view into N rotational wedges."),
        WarpDescriptor(.ripple, "Ripple", icon: "waveform.path", amountLabel: "Ripple", usesAxis: true, defaultStrength: 0.6,
                       params: [WarpParamSpec(slot: 1, label: "Frequency", icon: "waveform.path", range: 0.1...8.0, defaultValue: 2.0)],
                       gpuApplyFn: "warpRipple",
                       blurb: "Accordion-displace space along an axis."),
        // ── Radial / nested / self-similar ──────────────────────────────────
        WarpDescriptor(.circle, "Circle", icon: "circle",
                       params: [WarpParamSpec(slot: 1, label: "Inner Radius", icon: "smallcircle.filled.circle", range: 0.05...2.0, defaultValue: 0.5),
                                WarpParamSpec(slot: 2, label: "Outer Radius", icon: "circle.circle", range: 0.1...4.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpCircle", gpuDEScaleFn: "warpCircleDEScale",
                       blurb: "Sphere fold confined to the XZ plane — circular / tube structure."),
        WarpDescriptor(.shells, "Shells", icon: "circle.dotted",
                       params: [WarpParamSpec(slot: 1, label: "Spacing", icon: "circle.dotted", range: 0.1...4.0, defaultValue: 1.0)],
                       gpuApplyFn: "warpShells",
                       blurb: "Repeat the fractal in concentric spherical shells at a fixed spacing."),
        WarpDescriptor(.scaleRepeat, "Scale Repeat", icon: "infinity",
                       params: [WarpParamSpec(slot: 1, label: "Scale Factor", icon: "infinity", range: 1.1...4.0, defaultValue: 2.0)],
                       gpuApplyFn: "warpScaleRepeat", gpuDEScaleFn: "warpScaleRepeatDEScale",
                       blurb: "Repeat self-similarly at growing scales (log-radial / Droste)."),
        // ── Reflection group (Coxeter) ──────────────────────────────────────
        WarpDescriptor(.coxeter, "Coxeter", icon: "hexagon", amountLabel: "Mirror",
                       defaultStrength: 1.0, strengthRange: 0.0...1.0,
                       params: [WarpParamSpec(slot: 1, label: "p", icon: "hexagon", range: 2.0...8.0, defaultValue: 5.0),
                                WarpParamSpec(slot: 2, label: "q", icon: "hexagon", range: 2.0...8.0, defaultValue: 3.0)],
                       gpuApplyFn: "warpCoxeter",   // isometric (reflections) → no DE divisor
                       blurb: "Fold space into a {p,q} kaleidoscopic mirror group (polyhedral / Coxeter symmetry). {5,3}=icosahedral, {4,3}=octahedral; 1/p+1/q<1/2 goes hyperbolic."),
    ]

    private static let byKind: [SpaceWarpKind: WarpDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    static func descriptor(for kind: SpaceWarpKind) -> WarpDescriptor {
        byKind[kind] ?? all[0]
    }
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

    var kind: SpaceWarpKind { SpaceWarpKind(rawValue: type) ?? .twist }

    /// A fresh op seeded with sensible defaults for `kind` (from its descriptor).
    init(kind: SpaceWarpKind) {
        let d = kind.descriptor
        self.id = UUID()
        self.type = kind.rawValue
        self.strength = d.defaultStrength
        self.p1 = d.params.first(where: { $0.slot == 1 })?.defaultValue ?? 0
        self.p2 = d.params.first(where: { $0.slot == 2 })?.defaultValue ?? 0
        self.axis = SIMD3<Float>(0, 1, 0)
        self.isEnabled = true
    }

    init(id: UUID = UUID(), type: Int32, strength: Float, p1: Float, p2: Float,
         axis: SIMD3<Float>, isEnabled: Bool) {
        self.id = id; self.type = type; self.strength = strength
        self.p1 = p1; self.p2 = p2; self.axis = axis; self.isEnabled = isEnabled
    }
}

/// Generates the specialized (unrolled, type-dispatched) Metal source for a stack
/// so `CustomShaderCompiler` can compile a fast variant where the per-op loop +
/// switch are resolved at compile time. Param VALUES still come from the uniforms
/// (`params.spaceWarpOps[k]`), so only STRUCTURE changes (count/order/types)
/// require a recompile — slider tweaks stay live. The CPU↔GPU function names come
/// straight from `WarpCatalog`, so this never drifts from the runtime path.
enum SpaceWarpStackCodegen {
    static func generate(_ ops: [SpaceWarpOpValue]) -> (source: String?, signature: String) {
        let active = Array(ops.filter { $0.isEnabled }.prefix(Int(kMaxSpaceWarpOps)))
        guard !active.isEmpty else { return (nil, "s0") }

        let signature = "s" + active.map { String($0.type) }.joined(separator: ".")

        var applyBody = ""
        var deScaleBody = ""
        var transformBody = ""   // fused: warped point + DE divisor in one sweep (hot march path)
        for (k, op) in active.enumerated() {
            let d = op.kind.descriptor
            applyBody += "    p = \(d.gpuApplyFn)(p, params.spaceWarpOps[\(k)]);\n"
            if let de = d.gpuDEScaleFn {
                deScaleBody += "    scale *= \(de)(q, params.spaceWarpOps[\(k)]);\n"
                transformBody += "    r.deScale *= \(de)(r.point, params.spaceWarpOps[\(k)]);\n"
            }
            deScaleBody += "    q = \(d.gpuApplyFn)(q, params.spaceWarpOps[\(k)]);\n"
            transformBody += "    r.point = \(d.gpuApplyFn)(r.point, params.spaceWarpOps[\(k)]);\n"
        }

        let source = """
        #define THRESHOLD_CODEGEN_SPACEWARP_STACK
        // === Codegen space-warp stack (\(active.count) op\(active.count == 1 ? "" : "s")) ===
        FORCE_INLINE float3 spaceWarpStackApply(float3 p, FractalParams params) {
        \(applyBody)    return p;
        }
        FORCE_INLINE float spaceWarpStackDEScale(float3 p, FractalParams params) {
            float scale = 1.0f;
            float3 q = p;
        \(deScaleBody)    return scale;
        }
        FORCE_INLINE SpaceTransform spaceWarpStackTransform(float3 p, FractalParams params) {
            SpaceTransform r;
            r.point = p;
            r.deScale = 1.0f;
        \(transformBody)    return r;
        }
        // === End codegen space-warp stack ===
        """
        return (source, signature)
    }
}

/// Convert a model op into a GPU-READY op. All frame-uniform math that the Metal
/// warp functions used to redo every march step — axis normalization, the `max()`
/// floor clamps, squared radii, `π/N`, `log(scale)` — is done HERE, once per frame.
/// The GPU functions then just read the precomputed scalars (see `SpaceWarpOp` in
/// ShaderTypes.h). Field meanings become precomputed/type-specific:
///   • axisX/Y/Z = normalized axis (twist/bend/ripple)
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
    case .twist, .bend, .mirror:
        break                                                    // no radius/limit precompute
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
    case .scaleRepeat:
        p1 = logf(max(v.p1, 1.1))                                // log(scale), float-precision (matches GPU log)
    case .coxeter:
        // [p,q] rank-3 reflection group → the 3 mirror normals (through the origin):
        //   n0 = (1, 0, 0)                            [implicit in the shader]
        //   n1 = (−cos π/p, sin π/p, 0)               → p1, p2
        //   n2 = (0, −cos(π/q)/sin(π/p), √(1−a²))      → axisX, axisY
        // Their Gram inner products encode the dihedral orders (n0·n1→p, n1·n2→q,
        // n0·n2 = 0). Real n2.z needs 1/p+1/q ≥ 1/2 (finite/Euclidean); the hyperbolic
        // case clamps to 0 and still folds gracefully (just no convergence).
        let pp = max(v.p1.rounded(), 2)
        let qq = max(v.p2.rounded(), 2)
        let sp = sinf(Float.pi / pp)
        let cp = cosf(Float.pi / pp)
        let cq = cosf(Float.pi / qq)
        let a = -cq / sp
        let b = (1 - a * a > 0) ? sqrtf(1 - a * a) : 0
        return SpaceWarpOp(type: v.type, strength: v.strength,
                           p1: -cp, p2: sp, axisX: a, axisY: b, axisZ: 0, _pad: 0)
    }
    return SpaceWarpOp(type: v.type, strength: v.strength, p1: p1, p2: p2,
                       axisX: n.x, axisY: n.y, axisZ: n.z, _pad: 0)
}

/// Pack the enabled ops (in order) into the GPU `SpaceWarpStack`, precomputing each
/// (`precomputedGPUOp`). Disabled ops are dropped; the list is capped at `kMaxSpaceWarpOps`.
func cSpaceWarpStack(from ops: [SpaceWarpOpValue]) -> SpaceWarpStack {
    var stack = SpaceWarpStack()
    let maxN = Int(kMaxSpaceWarpOps)
    let active = ops.filter { $0.isEnabled }.prefix(maxN)
    withUnsafeMutablePointer(to: &stack.ops) { tuplePtr in
        tuplePtr.withMemoryRebound(to: SpaceWarpOp.self, capacity: maxN) { base in
            for (i, v) in active.enumerated() {
                base[i] = precomputedGPUOp(from: v)
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
