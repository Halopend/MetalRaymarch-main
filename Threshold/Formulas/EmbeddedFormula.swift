//
//  EmbeddedFormula.swift
//  Threshold
//
//  Portable distance-estimator payload that can ship inside .threshfx, .threshanim,
//  or .threshscene files. Carries Metal source for both DE variants
//  (DE_<stem> + DE_<stem>_Dist) plus catalog-style parameter metadata.
//
//  The renderer compiles the embedded source at runtime into a separate MTLLibrary
//  and treats the formula as FractalModelType.custom for dispatch & cache keying.
//

import CryptoKit
import Foundation

// MARK: - Container (for standalone .threshfx files)

/// File-level wrapper for a `.threshfx` document. Versioned so the schema can evolve.
struct EmbeddedFormulaContainer: Codable, Equatable {
    /// Schema version of the container format (current = 1).
    let version: Int
    /// The formula payload.
    var formula: EmbeddedFormula

    static let currentVersion: Int = 1

    init(formula: EmbeddedFormula, version: Int = EmbeddedFormulaContainer.currentVersion) {
        self.version = version
        self.formula = formula
    }
}

// MARK: - Effect kind

/// What kind of GPU effect an embedded payload carries. The format is otherwise
/// identical (`.threshfx`); only the required Metal functions + the compiler's
/// injection point differ. Stored as an OPTIONAL on `EmbeddedFormula` so old files
/// (no key) decode to nil → treated as `.fractal` (full backward compatibility).
enum EffectKind: String, Codable, Equatable, Sendable {
    /// A fractal distance estimator: defines `DE_<stem>` + `DE_<stem>_Dist`,
    /// injected at the dispatch markers; rides `FractalModelType.custom`.
    case fractal
    /// A space-domain warp: defines `customSpaceWarp` + `customSpaceWarpDEScale`,
    /// injected at `// __CUSTOM_SPACE_WARP__`; applies to any fractal.
    case spaceWarp
}

// MARK: - Embedded formula payload

/// A self-contained fractal distance estimator: Metal source + parameter metadata.
///
/// The same payload is embedded inside `.threshfx`, `.threshanim`, and `.threshscene`
/// files under the shared `embeddedFormula` JSON key. When loaded, the renderer:
///   1. Validates the source (length, regex, forbidden tokens).
///   2. Registers an ephemeral entry in `FormulaCatalog` keyed to `FractalModelType.custom`.
///   3. Synthesizes a Metal source that wraps the embedded DE in the standard render
///      kernels and compiles a separate MTLLibrary keyed by `sourceHash`.
struct EmbeddedFormula: Codable, Equatable {

    /// Two embedded formulas are considered equal when their `id` and
    /// `sourceHash` (SHA-256 of stem + Metal source) match. We avoid synthesized
    /// Equatable because `FormulaParamDescriptor` does not (yet) conform.
    static func == (lhs: EmbeddedFormula, rhs: EmbeddedFormula) -> Bool {
        lhs.id == rhs.id && lhs.sourceHash == rhs.sourceHash
    }

    // MARK: Schema

    /// Schema version. Lets future fields land without breaking older readers.
    var schemaVersion: Int

    /// Effect kind. Optional so old files (no key) decode to nil; use `effectKind`
    /// to read the resolved value (nil → `.fractal`).
    var kind: EffectKind?

    /// Resolved effect kind (defaults to `.fractal` for legacy payloads).
    var effectKind: EffectKind { kind ?? .fractal }

    /// Stable identifier (e.g. `"user.boxFold01"`). Must be unique within a session.
    var id: String

    /// Author-facing display name (e.g. `"Box Fold 01"`). Used in pickers.
    var name: String

    /// Optional grouping name shown alongside built-in categories. Defaults to "Custom".
    var category: String?

    /// Optional author / mathematician / artist credit.
    var author: String?

    /// Optional long-form description shown in info popovers.
    var formulaDescription: String?

    /// Bare function-name stem. The Metal source MUST define both
    /// `DE_<functionStem>` (orbit-tracking variant) and `DE_<functionStem>_Dist`
    /// (lean distance-only variant).
    /// Validated against `[A-Za-z_][A-Za-z0-9_]*`.
    var functionStem: String

    /// Metal source body for the distance estimator (the contents of a `.h` file).
    /// Must define both DE variants and may rely on declarations from
    /// `FractalFormulaCommon.h` (which is prepended automatically at compile time).
    var metalSource: String

    /// Catalog-style parameter metadata (reuses `FormulaParamDescriptor`).
    /// Indexes must be in 0...15 and unique.
    var params: [FormulaParamDescriptor]

    /// Optional default iteration count for new keyframes/presets.
    var defaultIterations: Int?

    /// Optional default color-iteration count.
    var defaultColorIterations: Int?

    /// Effect tags to surface in UI (raw `EffectTag.rawValue` strings).
    /// When omitted a baseline set is used. Stored raw so unknown tags from a future
    /// app version don't break decoding.
    var supportedEffectTagsRaw: [String]?

    // MARK: Derived

    /// SHA-256 of `functionStem | metalSource`. Used as the pipeline-cache key prefix
    /// and as the on-disk metallib filename.
    var sourceHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(functionStem.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(metalSource.utf8))
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// First 12 hex chars of `sourceHash` — used in cache keys for readability.
    var shortHash: String {
        let h = sourceHash
        return String(h.prefix(12))
    }

    /// Built-in construction primitives are shipped as embedded formulas so a
    /// scene remains self-contained, but unlike imported `.threshfx` files they
    /// are trusted app content and do not require the experimental-import flag.
    /// Trust is granted by source hash, never by id alone: the payload must be
    /// byte-identical to the formula this build generates or to a revision an
    /// earlier build shipped (`historicalBundledSourceHashes`). The historical
    /// set is what keeps saved scenes and the auto-saved last session restoring
    /// as primitives across payload edits — without it, editing a primitive's
    /// Metal source demotes every previously saved scene embedding it to the
    /// gated `.custom` path ("Custom scenes are experimental"). Accepting a
    /// historical payload is safe: recognition always routes rendering to the
    /// precompiled `.constructionPrimitive` type, so the embedded source of a
    /// trusted primitive is never runtime-compiled.
    var bundledConstructionPrimitiveKind: FractalPrimitiveKind? {
        let prefix = "com.puppypower.threshold.primitive."
        guard id.hasPrefix(prefix),
              let kind = FractalPrimitiveKind(rawValue: String(id.dropFirst(prefix.count))),
              self == kind.formula
                || FractalPrimitiveKind.historicalBundledSourceHashes[kind]?
                    .contains(sourceHash) == true
        else { return nil }
        return kind
    }

    var isBundledConstructionPrimitive: Bool {
        bundledConstructionPrimitiveKind != nil
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case id
        case name
        case category
        case author
        case formulaDescription = "description"
        case functionStem
        case metalSource
        case params
        case defaultIterations
        case defaultColorIterations
        case supportedEffectTagsRaw = "supportedEffectTags"
    }

    init(
        schemaVersion: Int = 1,
        kind: EffectKind? = nil,
        id: String,
        name: String,
        category: String? = nil,
        author: String? = nil,
        formulaDescription: String? = nil,
        functionStem: String,
        metalSource: String,
        params: [FormulaParamDescriptor],
        defaultIterations: Int? = nil,
        defaultColorIterations: Int? = nil,
        supportedEffectTagsRaw: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.id = id
        self.name = name
        self.category = category
        self.author = author
        self.formulaDescription = formulaDescription
        self.functionStem = functionStem
        self.metalSource = metalSource
        self.params = params
        self.defaultIterations = defaultIterations
        self.defaultColorIterations = defaultColorIterations
        self.supportedEffectTagsRaw = supportedEffectTagsRaw
    }
}

// MARK: - Bundled construction primitives

/// Analytic SDFs selected and sized in the dedicated Primitives workspace, then
/// optionally used as seed geometry for the Transformations editor.
/// They deliberately use the same EmbeddedFormula contract as imported `.threshfx`
/// content, so saving a scene embeds the selected primitive and its attribution.
/// Current builds render these through the precompiled construction-primitive
/// type; the source payload keeps the scene portable to builds that only know
/// the runtime custom-formula contract.
enum FractalPrimitiveKind: String, CaseIterable, Identifiable {
    case sphere
    case box
    case torus
    case octahedron
    case capsule
    case cylinder
    case cone
    case hexagonalPrism
    case pyramid
    case tetrahedron
    case icosahedron
    case dodecahedron
    case mandelboxSeed

    var id: String { rawValue }

    /// Selector values are persisted in FormulaParams, so existing values must
    /// never be renumbered when the library grows.
    var selector: Int {
        switch self {
        case .sphere: return 0
        case .box: return 1
        case .torus: return 2
        case .octahedron: return 3
        case .mandelboxSeed: return 4
        case .capsule: return 5
        case .cylinder: return 6
        case .cone: return 7
        case .hexagonalPrism: return 8
        case .pyramid: return 9
        case .tetrahedron: return 10
        case .icosahedron: return 11
        case .dodecahedron: return 12
        }
    }

    init?(selector: Int) {
        guard let match = Self.allCases.first(where: { $0.selector == selector }) else {
            return nil
        }
        self = match
    }

    /// Selector slot 0 reaches the UI as a raw, unclamped Float — preset decode
    /// applies `formulaParamValues` verbatim — and Swift's `Int(Float)` traps on
    /// NaN or magnitudes beyond `Int`'s range. This is the Swift-side twin of
    /// the shader's `clamp(int(round(fp.params[0])), 0, 12)` guard, except it
    /// rejects instead of clamping so a corrupt selector reads as "no primitive
    /// selected" rather than snapping to an arbitrary shape.
    init?(rawSelector: Float) {
        let rounded = rawSelector.rounded()
        guard rounded.isFinite,
              rounded >= 0,
              rounded <= Float(Self.allCases.count - 1) else { return nil }
        self.init(selector: Int(rounded))
    }

    /// Source hashes of payload revisions that EARLIER builds embedded in saved
    /// scenes and the auto-saved last session. `bundledConstructionPrimitiveKind`
    /// accepts these alongside the current payload so old files keep restoring
    /// as trusted primitives after `formula`'s Metal source evolves.
    /// RULE: when changing an existing primitive's helper (or the shared
    /// `metalSource` template), append the outgoing `sourceHash` for every
    /// affected kind — the pinned-hash test in EmbeddedFormulaCompileTests
    /// fails until this ledger is updated.
    static let historicalBundledSourceHashes: [FractalPrimitiveKind: Set<String>] = [
        // Box before the roundness clamp gained its `size` upper bound
        // (`max(fp.params[1], 0.0f)` → `min(max(fp.params[1], 0.0f), size)`).
        .box: ["ed1daccfbc870c8fa6915210fae8614eabd012624e2059651bc0350022105b8e"]
    ]

    static var analyticCases: [Self] {
        allCases.filter { $0 != .mandelboxSeed }
    }

    var name: String {
        switch self {
        case .sphere: return "Sphere"
        case .box: return "Box"
        case .torus: return "Torus"
        case .octahedron: return "Octahedron"
        case .capsule: return "Capsule"
        case .cylinder: return "Cylinder"
        case .cone: return "Cone"
        case .hexagonalPrism: return "Hex Prism"
        case .pyramid: return "Pyramid"
        case .tetrahedron: return "Tetrahedron"
        case .icosahedron: return "Icosahedron"
        case .dodecahedron: return "Dodecahedron"
        case .mandelboxSeed: return "Mandelbox Seed"
        }
    }

    var icon: String {
        switch self {
        case .sphere, .mandelboxSeed: return "circle.fill"
        case .box: return "cube.fill"
        case .torus: return "circle.dashed"
        case .octahedron: return "diamond.fill"
        case .capsule: return "capsule.fill"
        case .cylinder: return "cylinder.fill"
        case .cone: return "triangle.fill"
        case .hexagonalPrism: return "hexagon.fill"
        case .pyramid: return "triangle.fill"
        case .tetrahedron: return "triangle.fill"
        case .icosahedron: return "hexagon.fill"
        case .dodecahedron: return "pentagon.fill"
        }
    }

    var summary: String {
        switch self {
        case .sphere: return "A smooth radial solid with one radius."
        case .box: return "A cube that can soften continuously into a rounded box."
        case .torus: return "A ring with independent major and tube radii."
        case .octahedron: return "A sharp eight-faced Platonic solid."
        case .capsule: return "A line segment swept by a sphere."
        case .cylinder: return "A flat-capped round column."
        case .cone: return "A centered, flat-based pointed solid."
        case .hexagonalPrism: return "A six-sided column with a controllable height."
        case .pyramid: return "A centered square-based pyramid with a sharp apex."
        case .tetrahedron: return "A four-faced Platonic seed matched to the Bounding system."
        case .icosahedron: return "A twenty-faced Platonic seed matched to the Bounding system."
        case .dodecahedron: return "A twelve-faced Platonic seed matched to the Bounding system."
        case .mandelboxSeed: return "The terminal sphere used by the Mandelbox construction recipe."
        }
    }

    struct Dimension: Identifiable {
        let index: Int
        let name: String
        let icon: String
        let range: ClosedRange<Float>

        var id: Int { index }
    }

    /// Shape-specific labels for the statically compiled parameter slots.
    var dimensions: [Dimension] {
        switch self {
        case .sphere:
            return [Dimension(index: 1, name: "Radius", icon: "circle", range: 0.05...30)]
        case .box:
            return [
                Dimension(index: 1, name: "Half Size", icon: "arrow.left.and.right", range: 0.05...30),
                Dimension(index: 2, name: "Roundness", icon: "square", range: 0...2)
            ]
        case .torus:
            return [
                Dimension(index: 1, name: "Major Radius", icon: "circle.dashed", range: 0.05...6),
                Dimension(index: 2, name: "Tube Radius", icon: "circle", range: 0.02...2)
            ]
        case .octahedron:
            return [Dimension(index: 1, name: "Radius", icon: "diamond", range: 0.05...30)]
        case .capsule:
            return [
                Dimension(index: 1, name: "Half Length", icon: "arrow.up.and.down", range: 0.05...6),
                Dimension(index: 2, name: "Radius", icon: "circle", range: 0.02...2)
            ]
        case .cylinder:
            return [
                Dimension(index: 1, name: "Half Height", icon: "arrow.up.and.down", range: 0.05...6),
                Dimension(index: 2, name: "Radius", icon: "circle", range: 0.02...2)
            ]
        case .cone:
            return [
                Dimension(index: 1, name: "Half Height", icon: "arrow.up.and.down", range: 0.05...6),
                Dimension(index: 2, name: "Base Radius", icon: "arrow.left.and.right", range: 0.02...2)
            ]
        case .hexagonalPrism:
            return [
                Dimension(index: 1, name: "Half Height", icon: "arrow.up.and.down", range: 0.05...6),
                Dimension(index: 2, name: "Radius", icon: "hexagon", range: 0.02...2)
            ]
        case .pyramid:
            return [
                Dimension(index: 1, name: "Height", icon: "arrow.up.and.down", range: 0.05...6),
                Dimension(index: 2, name: "Base Half Width", icon: "arrow.left.and.right", range: 0.02...2)
            ]
        case .tetrahedron, .icosahedron, .dodecahedron:
            return [Dimension(index: 1, name: "Radius", icon: icon, range: 0.05...30)]
        case .mandelboxSeed:
            return [Dimension(index: 1, name: "Terminal Radius", icon: "circle", range: 0.05...6)]
        }
    }

    /// Parameters consumed by the statically compiled construction-primitive
    /// shader. Keeping this separate from the portable embedded formula lets
    /// iPad render trusted primitives without runtime-compiling all Shaders.metal.
    var bundledFormulaParams: FormulaParams {
        var fp = FractalTypeDescriptor.baseFormulaParams()
        switch self {
        case .sphere:
            fp.params.0 = 0; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .box:
            fp.params.0 = 1; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .torus:
            fp.params.0 = 2; fp.params.1 = 1.0; fp.params.2 = 0.25
        case .octahedron:
            fp.params.0 = 3; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .capsule:
            fp.params.0 = 5; fp.params.1 = 1.0; fp.params.2 = 0.35
        case .cylinder:
            fp.params.0 = 6; fp.params.1 = 1.0; fp.params.2 = 0.75
        case .cone:
            fp.params.0 = 7; fp.params.1 = 1.0; fp.params.2 = 0.85
        case .hexagonalPrism:
            fp.params.0 = 8; fp.params.1 = 1.0; fp.params.2 = 0.85
        case .pyramid:
            fp.params.0 = 9; fp.params.1 = 1.6; fp.params.2 = 0.9
        case .tetrahedron:
            fp.params.0 = 10; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .icosahedron:
            fp.params.0 = 11; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .dodecahedron:
            fp.params.0 = 12; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .mandelboxSeed:
            fp.params.0 = 4; fp.params.1 = 2.5; fp.params.2 = 0.0
        }
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }

    var formula: EmbeddedFormula {
        let stem: String
        let description: String
        let params: [FormulaParamDescriptor]
        let helper: String

        switch self {
        case .sphere:
            stem = "PrimitiveSphere"
            description = "Analytic sphere seed for building forms with the transformation stack."
            params = [Self.param(0, "Radius", 1.0, 0.05, 30.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                return length(p) - max(fp.params[0], 0.001f);
            }
            """
        case .box:
            stem = "PrimitiveBox"
            description = "Analytic rounded-box seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Half Size", 1.0, 0.05, 30.0, 0.05),
                Self.param(1, "Roundness", 0.0, 0.0, 2.0, 0.01)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float size = max(fp.params[0], 0.001f);
                float roundness = min(max(fp.params[1], 0.0f), size);
                float3 q = abs(p) - float3(size - roundness);
                return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f) - roundness;
            }
            """
        case .torus:
            stem = "PrimitiveTorus"
            description = "Analytic torus seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Major Radius", 1.0, 0.05, 6.0, 0.05),
                Self.param(1, "Tube Radius", 0.25, 0.02, 2.0, 0.02)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float2 q = float2(length(p.xz) - max(fp.params[0], 0.001f), p.y);
                return length(q) - max(fp.params[1], 0.001f);
            }
            """
        case .octahedron:
            stem = "PrimitiveOctahedron"
            description = "Analytic octahedron seed for building forms with the transformation stack."
            params = [Self.param(0, "Radius", 1.0, 0.05, 30.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                return (abs(p.x) + abs(p.y) + abs(p.z) - max(fp.params[0], 0.001f)) * 0.57735026919f;
            }
            """
        case .capsule:
            stem = "PrimitiveCapsule"
            description = "Analytic vertical capsule seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Half Length", 1.0, 0.05, 6.0, 0.05),
                Self.param(1, "Radius", 0.35, 0.02, 2.0, 0.02)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float halfLength = max(fp.params[0], 0.001f);
                p.y -= clamp(p.y, -halfLength, halfLength);
                return length(p) - max(fp.params[1], 0.001f);
            }
            """
        case .cylinder:
            stem = "PrimitiveCylinder"
            description = "Analytic capped-cylinder seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Half Height", 1.0, 0.05, 6.0, 0.05),
                Self.param(1, "Radius", 0.75, 0.02, 2.0, 0.02)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float2 d = abs(float2(length(p.xz), p.y))
                         - float2(max(fp.params[1], 0.001f), max(fp.params[0], 0.001f));
                return min(max(d.x, d.y), 0.0f) + length(max(d, 0.0f));
            }
            """
        case .cone:
            stem = "PrimitiveCone"
            description = "Analytic centered capped-cone seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Half Height", 1.0, 0.05, 6.0, 0.05),
                Self.param(1, "Base Radius", 0.85, 0.02, 2.0, 0.02)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float h = max(fp.params[0], 0.001f);
                float r = max(fp.params[1], 0.001f);
                float2 q = float2(length(p.xz), p.y);
                float2 k1 = float2(0.0f, h);
                float2 k2 = float2(-r, 2.0f * h);
                float2 ca = float2(q.x - min(q.x, q.y < 0.0f ? r : 0.0f), abs(q.y) - h);
                float2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0f, 1.0f);
                float signValue = (cb.x < 0.0f && ca.y < 0.0f) ? -1.0f : 1.0f;
                return signValue * sqrt(min(dot(ca, ca), dot(cb, cb)));
            }
            """
        case .hexagonalPrism:
            stem = "PrimitiveHexagonalPrism"
            description = "Analytic hexagonal-prism seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Half Height", 1.0, 0.05, 6.0, 0.05),
                Self.param(1, "Radius", 0.85, 0.02, 2.0, 0.02)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float3 q = abs(p);
                float side = max(q.x * 0.86602540378f + q.z * 0.5f, q.z)
                           - max(fp.params[1], 0.001f);
                return max(q.y - max(fp.params[0], 0.001f), side);
            }
            """
        case .pyramid:
            stem = "PrimitivePyramid"
            description = "Analytic centered square-pyramid seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Height", 1.6, 0.05, 6.0, 0.05),
                Self.param(1, "Base Half Width", 0.9, 0.02, 2.0, 0.02)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float baseScale = 2.0f * max(fp.params[1], 0.001f);
                float h = max(fp.params[0], 0.001f) / baseScale;
                float3 x = p / baseScale;
                x.y += 0.5f * h;
                x.xz = abs(x.xz);
                if (x.z > x.x) { float swapValue = x.x; x.x = x.z; x.z = swapValue; }
                x.xz -= float2(0.5f);
                float m2 = h * h + 0.25f;
                float3 q = float3(x.z, h * x.y - 0.5f * x.x, h * x.x + 0.5f * x.y);
                float s = max(-q.x, 0.0f);
                float t = clamp((q.y - 0.5f * x.z) / (m2 + 0.25f), 0.0f, 1.0f);
                float a = m2 * (q.x + s) * (q.x + s) + q.y * q.y;
                float b = m2 * (q.x + 0.5f * t) * (q.x + 0.5f * t)
                        + (q.y - m2 * t) * (q.y - m2 * t);
                float d2 = min(q.y, -q.x * m2 - q.y * 0.5f) > 0.0f ? 0.0f : min(a, b);
                float d = sqrt((d2 + q.z * q.z) / m2) * sign(max(q.z, -x.y));
                return d * baseScale;
            }
            """
        case .tetrahedron:
            stem = "PrimitiveTetrahedron"
            description = "Analytic tetrahedral seed using the same radius convention as the Bounding system."
            params = [Self.param(0, "Radius", 1.0, 0.05, 30.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float radius = max(fp.params[0], 0.001f);
                float invSqrt3 = 0.5773502691896258f;
                float faceOffset = radius * invSqrt3;
                float d1 = dot(p, float3( invSqrt3,  invSqrt3,  invSqrt3));
                float d2 = dot(p, float3( invSqrt3, -invSqrt3, -invSqrt3));
                float d3 = dot(p, float3(-invSqrt3,  invSqrt3, -invSqrt3));
                float d4 = dot(p, float3(-invSqrt3, -invSqrt3,  invSqrt3));
                return max(max(d1, d2), max(d3, d4)) - faceOffset;
            }
            """
        case .icosahedron:
            stem = "PrimitiveIcosahedron"
            description = "Analytic icosahedral seed using the same radius convention as the Bounding system."
            params = [Self.param(0, "Radius", 1.0, 0.05, 30.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float radius = max(fp.params[0], 0.001f);
                float phi = 1.618033988749895f;
                float3 q = abs(p);
                float d1 = dot(q, float3(1.0f, 1.0f, 1.0f) * 0.5773502691896258f);
                float d2 = dot(q, float3(0.0f, 1.0f, phi) * 0.5257311121191336f);
                float d3 = dot(q, float3(1.0f, phi, 0.0f) * 0.5257311121191336f);
                float d4 = dot(q, float3(phi, 0.0f, 1.0f) * 0.5257311121191336f);
                return max(max(d1, d2), max(d3, d4)) - radius * 0.85065080835204f;
            }
            """
        case .dodecahedron:
            stem = "PrimitiveDodecahedron"
            description = "Analytic dodecahedral seed using the same radius convention as the Bounding system."
            params = [Self.param(0, "Radius", 1.0, 0.05, 30.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float radius = max(fp.params[0], 0.001f);
                float phi = 1.618033988749895f;
                float3 q = abs(p);
                float d1 = dot(q, float3(phi, 1.0f, 0.0f) * 0.5257311121191336f);
                float d2 = dot(q, float3(1.0f, 0.0f, phi) * 0.5257311121191336f);
                float d3 = dot(q, float3(0.0f, phi, 1.0f) * 0.5257311121191336f);
                return max(d1, max(d2, d3)) - radius * 0.85065080835204f;
            }
            """
        case .mandelboxSeed:
            stem = "MandelboxConstructionSeed"
            description = "The terminal sphere used by the classic Mandelbox distance estimator. Repeat Mandelbox Step transformations to build the recurrence."
            params = [Self.param(0, "Terminal Radius", 2.5, 0.05, 6.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                return length(p) - max(fp.params[0], 0.001f);
            }
            """
        }

        return EmbeddedFormula(
            kind: .fractal,
            id: "com.puppypower.threshold.primitive.\(rawValue)",
            name: name,
            category: "Primitives",
            author: "Threshold",
            formulaDescription: description,
            functionStem: stem,
            metalSource: Self.metalSource(stem: stem, helper: helper),
            params: params,
            defaultIterations: 1,
            defaultColorIterations: 1,
            supportedEffectTagsRaw: []
        )
    }

    private static func param(_ index: Int, _ name: String, _ value: Float,
                              _ min: Float, _ max: Float, _ step: Float) -> FormulaParamDescriptor {
        FormulaParamDescriptor(index: index, name: name, default: value,
                               min: min, max: max, step: step)
    }

    private static func metalSource(stem: String, helper: String) -> String {
        """
        // Threshold bundled construction primitive. This source is embedded in
        // saved scenes so the primitive remains portable as a custom fractal type.
        \(helper)

        FORCE_INLINE float DE_\(stem)(float3 pos, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                      thread OrbitData& orbit) {
            (void)iterations; (void)colorIterations;
            float3 p = hasRot1Precomputed(fp) ? (rot * pos) : pos;
            float d = primitiveDistance(p, fp);
            orbit.trap = dot(p, p);
            orbit.trapIteration = 0;
            orbit.trapPosition = p;
            orbit.finalP = p;
            orbit.iterationsUsed = 1;
            return d;
        }

        FORCE_INLINE float DE_\(stem)_Dist(float3 pos, FormulaParams fp,
                                           float3x3 rot, int iterations) {
            (void)iterations;
            float3 p = hasRot1Precomputed(fp) ? (rot * pos) : pos;
            return primitiveDistance(p, fp);
        }
        """
    }
}

// MARK: - Validation

extension EmbeddedFormula {

    /// Reasons an embedded formula payload may be rejected before compilation.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedSchemaVersion(Int)
        case emptyId
        case invalidFunctionStem(String)
        case emptyMetalSource
        case metalSourceTooLong(Int)
        case forbiddenToken(String)
        case missingFunctionDefinition(String)
        case duplicateParamIndex(Int)
        case paramIndexOutOfRange(Int)

        var description: String {
            switch self {
            case .unsupportedSchemaVersion(let v):
                return "Embedded formula schema version \(v) is not supported by this build."
            case .emptyId:
                return "Embedded formula is missing an id."
            case .invalidFunctionStem(let stem):
                return "Embedded formula function stem '\(stem)' is invalid (must match [A-Za-z_][A-Za-z0-9_]*)."
            case .emptyMetalSource:
                return "Embedded formula has empty Metal source."
            case .metalSourceTooLong(let n):
                return "Embedded formula Metal source is too long (\(n) bytes; max \(EmbeddedFormula.maxSourceBytes))."
            case .forbiddenToken(let tok):
                return "Embedded formula contains forbidden token '\(tok)'."
            case .missingFunctionDefinition(let name):
                return "Embedded formula source does not appear to define '\(name)'."
            case .duplicateParamIndex(let i):
                return "Embedded formula has duplicate parameter index \(i)."
            case .paramIndexOutOfRange(let i):
                return "Embedded formula parameter index \(i) is out of range (must be 0...15)."
            }
        }
    }

    /// Maximum permitted size of `metalSource` in bytes (UTF-8). Keeps scene files
    /// reasonable and bounds compile time.
    static let maxSourceBytes: Int = 64 * 1024

    /// Tokens that must not appear anywhere in `metalSource`. These would let the
    /// embedded payload pull in arbitrary headers or files at compile time, which
    /// defeats the validation we do up-front.
    static let forbiddenTokens: [String] = [
        "#import",
        "#include",
        "@import"
    ]

    /// Validates the payload. Throws on first failure.
    func validate() throws {
        guard schemaVersion <= EmbeddedFormulaContainer.currentVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError.emptyId
        }
        try Self.validateFunctionStem(functionStem)

        let trimmed = metalSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError.emptyMetalSource
        }
        let byteCount = metalSource.utf8.count
        guard byteCount <= Self.maxSourceBytes else {
            throw ValidationError.metalSourceTooLong(byteCount)
        }
        for token in Self.forbiddenTokens where metalSource.contains(token) {
            throw ValidationError.forbiddenToken(token)
        }

        // Cheap text check — confirm the kind's required functions appear by name.
        let requiredFunctions: [String]
        switch effectKind {
        case .fractal:
            requiredFunctions = ["DE_\(functionStem)", "DE_\(functionStem)_Dist"]
        case .spaceWarp:
            // Bare names: the compiler's `#define THRESHOLD_CUSTOM_SPACE_WARP`
            // skips the built-in defaults, so there is no symbol collision.
            requiredFunctions = ["customSpaceWarp", "customSpaceWarpDEScale"]
        }
        for fn in requiredFunctions where !Self.containsFunctionDefinition(in: metalSource, named: fn) {
            throw ValidationError.missingFunctionDefinition(fn)
        }

        // Parameter index bounds + uniqueness.
        var seen = Set<Int>()
        for p in params {
            guard p.index >= 0 && p.index < 16 else {
                throw ValidationError.paramIndexOutOfRange(p.index)
            }
            if !seen.insert(p.index).inserted {
                throw ValidationError.duplicateParamIndex(p.index)
            }
        }
    }

    private static func validateFunctionStem(_ stem: String) throws {
        guard !stem.isEmpty else {
            throw ValidationError.invalidFunctionStem(stem)
        }
        let firstScalar = stem.unicodeScalars.first!
        let isFirstValid = firstScalar.isASCII &&
            (CharacterSet.letters.contains(firstScalar) || firstScalar == "_")
        guard isFirstValid else {
            throw ValidationError.invalidFunctionStem(stem)
        }
        for scalar in stem.unicodeScalars.dropFirst() {
            let ok = scalar.isASCII &&
                (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            guard ok else {
                throw ValidationError.invalidFunctionStem(stem)
            }
        }
    }

    private static func containsFunctionDefinition(in source: String, named name: String) -> Bool {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?m)^\\s*(?:[A-Za-z_][A-Za-z0-9_]*\\s+)+" + escapedName + "\\s*\\("
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source.contains(name)
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.firstMatch(in: source, options: [], range: range) != nil
    }
}

// MARK: - File I/O helpers

extension EmbeddedFormulaContainer {

    /// Decodes a `.threshfx` container from disk, validating the formula payload.
    static func decode(fromContainerAt url: URL) throws -> EmbeddedFormulaContainer {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Defensive: matches PresetManager.decodePreset / AnimationManager so a
        // future Date field on the formula wouldn't silently break .threshfx
        // imports. Harmless today (the container has no Date fields).
        decoder.dateDecodingStrategy = .iso8601
        let container = try decoder.decode(EmbeddedFormulaContainer.self, from: data)
        try container.formula.validate()
        return container
    }

    /// Encodes this container to JSON data with stable, sorted keys for diff-friendly output.
    func encode() throws -> Data {
        try formula.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Writes this container to a shareable `.threshfx` file in the temp
    /// directory. Call off the main actor (see `exportOffMain`) — validate +
    /// encode + write blocks for the file's size.
    func exportToFile() -> URL? {
        let fileName = "\(PresetManager.sanitizedExportFileNameStem(formula.name)).\(ThresholdExportFormat.customFormula.ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try encode().write(to: url)
            return url
        } catch {
            print("Failed to export formula: \(error)")
            return nil
        }
    }
}
