//
//  TransformationEquationUnlock.swift
//  Threshold
//
//  A deliberately non-executing bridge from taught equations to the built-in
//  transform catalog. Submitted text is lexed and compared with authored Metal
//  token patterns; it is never compiled, evaluated, or sent to the renderer.
//

import Foundation

/// Stable curriculum identity. This deliberately does not reuse `SpaceWarpKind`'s
/// renderer-facing integer discriminator: lesson packs can add namespaced entries
/// without reserving GPU enum values or invalidating earned progress.
struct TransformationLessonID: RawRepresentable, Hashable, Codable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func < (lhs: TransformationLessonID, rhs: TransformationLessonID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func core(_ kind: SpaceWarpKind) -> TransformationLessonID {
        let slug: String
        switch kind {
        case .twist: slug = "twist"
        case .bend: slug = "bend"
        case .mirror: slug = "mirror"
        case .boxFold: slug = "box-fold"
        case .sphereFold: slug = "sphere-fold"
        case .inversion: slug = "inversion"
        case .kaleidoscope: slug = "kaleidoscope"
        case .ripple: slug = "ripple"
        case .circle: slug = "circle"
        case .shells: slug = "shells"
        case .scaleRepeat: slug = "scale-repeat"
        case .coxeter: slug = "coxeter"
        case .planeFold: slug = "plane-fold"
        case .mengerFold: slug = "menger-fold"
        case .tiling: slug = "tiling"
        case .scale: slug = "scale"
        case .offsetFold: slug = "offset-fold"
        case .mandelboxStep: slug = "mandelbox-step"
        case .icosahedralCut: slug = "icosahedral-cut"
        case .compressionShells: slug = "compression-shells"
        case .voronoi3D: slug = "voronoi-3d"
        }
        return TransformationLessonID(rawValue: "core.\(slug)")
    }

    var isSafeForLocalStorage: Bool {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128,
              rawValue.contains(".") else { return false }
        return rawValue.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 95
        }
    }
}

struct TransformationEquationLesson: Identifiable, Equatable {
    let id: TransformationLessonID
    let kind: SpaceWarpKind
    let mathematicalNotation: String
    let spokenMathematicalNotation: String
    let metalNotation: String
    let hint: String
    let acceptedAliases: [String]

}

/// One small piece of Metal vocabulary relevant to the equation being assembled.
/// These are teaching notes only; submitted source still goes through the strict,
/// non-executing token matcher below.
struct TransformationMetalVocabularyEntry: Identifiable, Equatable {
    let notation: String
    let meaning: String

    var id: String { notation }
}

enum TransformationEquationCatalog {
    /// Bounds the work done by the local lexer while leaving room for the longer
    /// reflection-group lessons. The submitted text is never executed.
    static let maximumInputLength = 4_096

    static let lessons: [TransformationEquationLesson] = [
        lesson(
            .twist,
            math: "Tₛ(p) = Rₐ̂(1.5s⟨p,â⟩)p",
            spokenMath: "Point p is rotated around the axis by an angle equal to one point five times s times the dot product of p and the axis.",
            metal: """
            if (op.strength > 0.0f) {
                float3 axis = float3(op.axisX, op.axisY, op.axisZ);
                float angle = op.strength * dot(p, axis) * 1.5f;
                float c;
                float s = sincos(angle, c);
                p = p * c + cross(axis, p) * s + axis * dot(axis, p) * (1.0f - c);
            }
            """,
            hint: "`op.axisX/Y/Z` is the CPU-normalized rotation axis; `op.strength` controls radians per unit along it. `sincos` applies Rodrigues' rotation and leaves the result in `p`."
        ),
        lesson(
            .bend,
            math: "a = ⟨p,â⟩,  p⊥ = p − aâ\nBₛ(p) = p⊥ + a cos(θ)â + a sin(θ)p̂⊥,  θ = 1.5s‖p⊥‖",
            spokenMath: "Output is the perpendicular part of p, plus the axis multiplied by scalar a and cosine of theta, plus the normalized perpendicular direction multiplied by scalar a and sine of theta. Theta equals one point five times s times the length of the perpendicular part.",
            metal: """
            if (op.strength > 0.0f) {
                float3 axis = float3(op.axisX, op.axisY, op.axisZ);
                float along = dot(p, axis);
                float3 perp = p - along * axis;
                float angle = op.strength * length(perp) * 1.5f;
                float c;
                float s = sincos(angle, c);
                float3 perpDir = (length(perp) > 1e-6f) ? normalize(perp) : float3(0.0f);
                p = perp + axis * (along * c) + perpDir * (along * s);
            }
            """,
            hint: "`op.axisX/Y/Z` is the normalized curvature axis and `op.strength` controls curvature. Split `p` into parallel and perpendicular parts before rotating the parallel distance."
        ),
        lesson(
            .mirror,
            math: "Mₛ(p) = (1 − s)p + s|p|",
            spokenMath: "Output equals one minus s, times p, plus s times the component-wise absolute value of p.",
            metal: "p = mix(p, abs(p), clamp(op.strength, 0.0f, 1.0f));",
            hint: "`op.strength` blends from the original point to `abs(p)`, which reflects negative coordinates into the positive octant."
        ),
        lesson(
            .boxFold,
            math: "Fₗ,ₛ(p) = (1 − s)p + s(2 clamp(p,−L,L) − p)\nHₗ(p) = L − |mod(p + L,4L) − 2L|",
            spokenMath: "Output equals two times p clamped between negative L and L, minus p. The optional repeating form reflects every four L.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float L = op.p1;
            float3 folded;
            if (op.p2 > 0.5f) {
                float period = 4.0f * L;
                float3 u = p + L;
                float3 m = u - period * floor(u / period);
                folded = L - fabs(m - 2.0f * L);
            } else {
                folded = clamp(p, -L, L) * 2.0f - p;
            }
            p = mix(p, folded, t);
            """,
            hint: "`op.p1` is the positive fold limit L, `op.p2` selects the repeating variant, and `op.strength` blends the fold. All three coordinates are mapped before assigning `p`."
        ),
        lesson(
            .sphereFold,
            math: "k(r²) = maxR²/minR²  if r² < minR²;  maxR²/r²  if r² < maxR²;  1 otherwise\nSₛ(p) = (1 − s)p + s·k(‖p‖²)p",
            spokenMath: "Inside the minimum radius, multiply p by maximum radius squared over minimum radius squared. Inside the maximum radius, multiply p by maximum radius squared over the squared length of p. Outside, leave p unchanged.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float r2 = dot(p, p);
            float minR2 = op.p1;
            float maxR2 = op.p2;
            float factor = 1.0f;
            if (r2 < minR2) {
                factor = maxR2 / minR2;
            } else if (r2 < maxR2) {
                factor = maxR2 / max(r2, 1e-6f);
            }
            p = mix(p, p * factor, t);
            """,
            hint: "`op.p1` and `op.p2` already contain min-radius² and max-radius²; `op.strength` blends the radial scale. The renderer separately maintains the distance correction."
        ),
        lesson(
            .inversion,
            math: "Iᵣ(p) = p · clamp(R²/‖p‖², 0.05, 20)",
            spokenMath: "Multiply p by radius squared divided by the squared length of p, clamped between zero point zero five and twenty.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float r2 = max(dot(p, p), 1e-6f);
            float factor = clamp(op.p1 / r2, 0.05f, 20.0f);
            p = mix(p, p * factor, t);
            """,
            hint: "`op.p1` is the CPU-precomputed radius squared and `op.strength` blends the map. The radius floor prevents a singular division at the origin."
        ),
        lesson(
            .kaleidoscope,
            math: "α = π/N,  φ′ = mod(|φ| + α,2α) − α",
            spokenMath: "Map angle phi to the absolute value of phi plus alpha, modulo two alpha, then subtract alpha. Alpha equals pi divided by the segment count.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float seg = op.p1;
            float ang = atan2(p.z, p.x);
            float len = length(p.xz);
            float a = fmod(fabs(ang) + seg, 2.0f * seg) - seg;
            float ca;
            float sa = sincos(a, ca);
            p = mix(p, float3(ca * len, p.y, sa * len), t);
            """,
            hint: "`op.p1` already contains π divided by the segment count; `op.strength` blends the XZ wedge fold while preserving `p.y`."
        ),
        lesson(
            .ripple,
            math: "Rₛ(p) = p + â·s sin(f⟨p,â⟩)",
            spokenMath: "Output equals p plus the axis multiplied by s and the sine of f times the dot product of p and the axis.",
            metal: """
            if (op.strength > 0.0f) {
                float3 axis = float3(op.axisX, op.axisY, op.axisZ);
                float freq = op.p1;
                p = p + axis * (op.strength * sin(dot(p, axis) * freq));
            }
            """,
            hint: "`op.axisX/Y/Z` is the normalized displacement direction, `op.p1` is frequency, and `op.strength` is amplitude."
        ),
        lesson(
            .circle,
            math: "q = (pₓ,p_z),  q′ = k(‖q‖²)q\nCₛ(p) = (1 − s)p + s(q′ₓ,p_y,q′ᵧ)",
            spokenMath: "Apply the radial scale using the squared length of p's x-z components, while leaving the y component unchanged.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float2 xz = float2(p.x, p.z);
            float r2 = dot(xz, xz);
            float minR2 = op.p1;
            float maxR2 = op.p2;
            float factor = 1.0f;
            if (r2 < minR2) {
                factor = maxR2 / minR2;
            } else if (r2 < maxR2) {
                factor = maxR2 / max(r2, 1e-6f);
            }
            p = mix(p, float3(xz.x * factor, p.y, xz.y * factor), t);
            """,
            hint: "`op.p1` and `op.p2` are inner-radius² and outer-radius²; `op.strength` blends the XZ-only radial fold, producing tubes without changing y."
        ),
        lesson(
            .shells,
            math: "r′ = |r − d·round(r/d)|,  r = ‖p‖\nSₛ(p) = (1 − s)p + s(r′/r)p",
            spokenMath: "New radius equals the absolute value of radius minus spacing times the rounded value of radius over spacing. Then multiply p by new radius over radius.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float d = op.p1;
            float r = length(p);
            if (r >= 1e-5f) {
                float rNew = fabs(r - d * round(r / d));
                p = mix(p, p * (rNew / r), t);
            }
            """,
            hint: "`op.p1` is the CPU-clamped shell spacing and `op.strength` blends the radial sawtooth. The guard keeps the origin unchanged."
        ),
        lesson(
            .compressionShells,
            math: "c/R ∈ {1−1/√2, φ⁻², φ⁻¹, 1}\nbᵢ(r) = 1−smoothstep(1/2,1,|r−cᵢ|/(wcᵢ))\nr′ = r + (s/3)Σ(−1)ⁱwcᵢbᵢ(r)",
            spokenMath: "Place four finite shell regions at proportional radii: one minus one over square root two, two inverse golden scales, and the outer radius. Alternate their radial offsets between positive and negative.",
            metal: """
            if (op.strength > 0.0f) {
                float r = length(p);
                if (r >= 1e-5f) {
                    float4 scales = float4(0.29289321881f, 0.38196601125f, 0.61803398875f, 1.0f);
                    float4 signs = float4(1.0f, -1.0f, 1.0f, -1.0f);
                    float4 centers = op.p1 * scales;
                    float4 halfWidths = op.p2 * centers;
                    float4 x = abs(float4(r) - centers) / halfWidths;
                    float4 regions = float4(1.0f) - smoothstep(float4(0.5f), float4(1.0f), x);
                    float displacement = op.strength * dot(signs, halfWidths * regions) / 3.0f;
                    float rNew = max(r + displacement, 1e-5f);
                    p = p * (rNew / r);
                }
            }
            """,
            hint: "`op.p1` is the outer radius and `op.p2` is each region's relative half-width. The four compact regions alternate signs and leave all intervening space unchanged."
        ),
        lesson(
            .scaleRepeat,
            math: "Oₛ(p) = p·exp(−⌊logₛ‖p‖⌋·log s)",
            spokenMath: "Multiply p by e raised to the power of: negative floor of the base-s logarithm of the length of p, multiplied by the natural logarithm of s. That entire product is in the exponent.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float logS = op.p1;
            float r = length(p);
            if (r >= 1e-5f) {
                float octave = floor(log(r) / logS);
                float scale = exp(-octave * logS);
                p = mix(p, p * scale, t);
            }
            """,
            hint: "`op.p1` already contains log(max(scale factor, 1.1)); `op.strength` blends the point back into its base radial octave."
        ),
        lesson(
            .coxeter,
            math: "rₙ(x) = x − 2 min(0,⟨x,n⟩)n\nCₚ,ᵩ(x) = (rₙ₂ ∘ rₙ₁ ∘ rₙ₀)ᵏ(x),  k ≤ 16",
            spokenMath: "Repeatedly reflect the point whenever it lies behind any of three mirror planes determined by the two orders p and q.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            if (t > 0.0f) {
                const float3 n0 = float3(1.0f, 0.0f, 0.0f);
                float3 n1 = float3(op.p1, op.p2, 0.0f);
                float3 n2 = float3(0.0f, op.axisX, op.axisY);
                float3 q = p;
                for (int i = 0; i < 16; ++i) {
                    bool folded = false;
                    float d0 = dot(q, n0);
                    if (d0 < 0.0f) {
                        q -= 2.0f * d0 * n0;
                        folded = true;
                    }
                    float d1 = dot(q, n1);
                    if (d1 < 0.0f) {
                        q -= 2.0f * d1 * n1;
                        folded = true;
                    }
                    float d2 = dot(q, n2);
                    if (d2 < 0.0f) {
                        q -= 2.0f * d2 * n2;
                        folded = true;
                    }
                    if (!folded) {
                        break;
                    }
                }
                p = mix(p, q, t);
            }
            """,
            hint: "The CPU converts the chosen {p,q} orders into packed mirror normals: `op.p1/p2` form n1 and `op.axisX/Y` form n2. `op.strength` blends the converged chamber fold."
        ),
        lesson(
            .planeFold,
            math: "Fₙ,ᵈ,ₛ(p) = p − 2s·min(0,⟨p,n⟩ − d)n",
            spokenMath: "If the dot product of p and normal n is less than distance d, subtract two times that signed difference, times n, times s.",
            metal: """
            float intensity = clamp(op.strength, 0.0f, 1.0f);
            if (intensity > 0.0f) {
                float3 n = float3(op.axisX, op.axisY, op.axisZ);
                float d = op.p1;
                float len = dot(p, n);
                if (len < d) {
                    p -= n * (2.0f * (len - d) * intensity);
                }
            }
            """,
            hint: "`op.axisX/Y/Z` is the CPU-normalized plane normal, `op.p1` is signed distance, and `op.strength` is reflection intensity."
        ),
        lesson(
            .mengerFold,
            math: "Mₛ(p) = (1 − s)p + s·sort↓(|p|)",
            spokenMath: "Replace p with its component-wise absolute value, then sort the three coordinates from greatest to least.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float3 a = abs(p);
            if (a.x < a.y) {
                a.xy = a.yx;
            }
            if (a.x < a.z) {
                a.xz = a.zx;
            }
            if (a.y < a.z) {
                a.yz = a.zy;
            }
            p = mix(p, a, t);
            """,
            hint: "`op.strength` blends an octant fold followed by three coordinate swaps; no helper function is hidden behind the notation."
        ),
        lesson(
            .tiling,
            math: "Tₗ(p) = p − L·round(p/L)",
            spokenMath: "Output equals p minus cell size times the component-wise rounded value of p divided by cell size.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float size = op.p1;
            float3 q = p - size * round(p / size);
            p = mix(p, q, t);
            """,
            hint: "`op.p1` is the CPU-clamped cell size and `op.strength` blends the wrapped lattice point."
        ),
        lesson(
            .scale,
            math: "Sₛ(p) = sp",
            spokenMath: "Output equals s multiplied by p.",
            metal: "p = p * op.strength;",
            hint: "Here `op.strength` is the signed uniform factor itself, not a 0…1 blend. The renderer applies its distance correction separately.",
            aliases: ["p *= op.strength;"]
        ),
        lesson(
            .offsetFold,
            math: "Fₛ,c(p) = (1 − s)p + s|p + c|",
            spokenMath: "Output equals one minus s, times p, plus s times the component-wise absolute value of the complete sum p plus offset c.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            float3 c = float3(op.axisX, op.axisY, op.axisZ);
            p = mix(p, abs(p + c), t);
            """,
            hint: "`op.axisX/Y/Z` is a raw offset vector (not normalized); `op.strength` slides between the original point and the off-centre absolute-value fold."
        ),
        lesson(
            .mandelboxStep,
            math: "zₙ₊₁ = scale · radialFold(boundaryFold(zₙ)) + p₀",
            spokenMath: "Next z equals scale times the result of a radial fold applied after a boundary fold of the current z, plus the original point p zero.",
            metal: """
            float3 folded = fma(clamp(p, -op.p1, op.p1), float3(2.0f), -p);
            float r2 = dot(folded, folded);
            float sphereScale = 1.0f;
            if (r2 < op.p2) {
                sphereScale = 1.0f / max(op.p2, 1e-6f);
            } else if (r2 < 1.0f) {
                sphereScale = 1.0f / max(r2, 1e-6f);
            }
            p = fma(folded, sphereScale * op.strength, p0);
            """,
            hint: "`op.p1` is fold limit, `op.p2` is min-radius², `op.strength` is signed recurrence scale, and `p0` is the original stack input added every iteration."
        ),
        lesson(
            .icosahedralCut,
            math: "rₙ(x) = x − 2 min(0,⟨x,n⟩)n\nI₅,₃(x) = (rₙ₂ ∘ rₙ₁ ∘ rₙ₀)ᵏ(x),  k ≤ 20",
            spokenMath: "Repeatedly reflect the point into the fundamental chamber defined by the fixed orders five and three.",
            metal: """
            float t = clamp(op.strength, 0.0f, 1.0f);
            if (t > 0.0f) {
                const float3 n0 = float3(1.0f, 0.0f, 0.0f);
                const float3 n1 = float3(-0.809016994f, 0.587785252f, 0.0f);
                const float3 n2 = float3(0.0f, -0.850650808f, 0.525731112f);
                float3 q = p;
                for (int i = 0; i < 16; ++i) {
                    bool folded = false;
                    float d0 = dot(q, n0);
                    if (d0 < 0.0f) {
                        q -= 2.0f * d0 * n0;
                        folded = true;
                    }
                    float d1 = dot(q, n1);
                    if (d1 < 0.0f) {
                        q -= 2.0f * d1 * n1;
                        folded = true;
                    }
                    float d2 = dot(q, n2);
                    if (d2 < 0.0f) {
                        q -= 2.0f * d2 * n2;
                        folded = true;
                    }
                    if (!folded) {
                        break;
                    }
                }
                p = mix(p, q, t);
            }
            """,
            hint: "The three constants are fixed {5,3} unit mirror normals from golden-ratio geometry; only `op.strength` is read to blend the converged chamber point."
        ),
        lesson(
            .voronoi3D,
            math: "q = ρp + o,  g = F₂(q) − F₁(q)\nV(p) = p + (s/ρ) smoothstep(0,1,g)(site₁(q) − fract(q))",
            spokenMath: "Find the nearest and second-nearest jittered sites around scaled point q, then pull p toward the nearest site by their distance gap, fading the pull to zero at shared cell boundaries.",
            metal: """
            if (op.strength > 0.0f) {
                float density = op.p1;
                float jitter = op.p2;
                float3 offset = float3(op.axisX, op.axisY, op.axisZ);
                float3 q = p * density + offset;
                float3 cell = floor(q);
                float3 local = fract(q);
                float nearest = 1.0e10f;
                float secondNearest = 1.0e10f;
                float3 nearestDelta = float3(0.0f);
                for (int z = -2; z <= 2; ++z) {
                    for (int y = -2; y <= 2; ++y) {
                        for (int x = -2; x <= 2; ++x) {
                            float3 neighbour = float3(x, y, z);
                            float3 hash = fract((cell + neighbour) * float3(0.1031f, 0.1030f, 0.0973f));
                            hash += dot(hash, hash.yxz + 33.33f);
                            hash = fract((hash.xxy + hash.yxx) * hash.zyx);
                            float3 site = neighbour + mix(float3(0.5f), hash, jitter);
                            float3 delta = site - local;
                            float distanceSquared = dot(delta, delta);
                            if (distanceSquared < nearest) {
                                secondNearest = nearest;
                                nearest = distanceSquared;
                                nearestDelta = delta;
                            } else if (distanceSquared < secondNearest) {
                                secondNearest = distanceSquared;
                            }
                        }
                    }
                }
                float gap = max(sqrt(secondNearest) - sqrt(nearest), 0.0f);
                float interior = smoothstep(0.0f, 1.0f, gap);
                p = p + nearestDelta * (op.strength * interior / density);
            }
            """,
            hint: "`op.p1` is cell density, `op.p2` jitters each deterministic site, and `op.axisX/Y/Z` slides the lattice. The five-cell envelope makes F1/F2 exact; production Metal prunes its outer cells before building the boundary-safe mask."
        ),
    ]

    /// Builds a compact toolbox from the actual Metal used by a lesson, so the
    /// learner sees useful notation before typing without receiving the answer.
    static func metalVocabulary(for lesson: TransformationEquationLesson) -> [TransformationMetalVocabularyEntry] {
        let source = lesson.metalNotation
        var mathEntries: [TransformationMetalVocabularyEntry] = [
            .init(notation: "p = expression;",
                  meaning: "Assign the transformed float3 point back to p."),
        ]
        var fieldEntries: [TransformationMetalVocabularyEntry] = []

        func addMath(_ notation: String, _ meaning: String, when condition: Bool) {
            guard condition, !mathEntries.contains(where: { $0.notation == notation }) else { return }
            mathEntries.append(.init(notation: notation, meaning: meaning))
        }

        func addField(_ notation: String, _ meaning: String, when condition: Bool) {
            guard condition, !fieldEntries.contains(where: { $0.notation == notation }) else { return }
            fieldEntries.append(.init(notation: notation, meaning: meaning))
        }

        // Distinctive math comes first so a complex lesson's defining operation is
        // never pushed out of the compact card by generic parameter vocabulary.
        addMath("p0", "The original point before this transformation stack pass.",
            when: source.contains("p0"))
        addMath("fma(a, b, c)", "Compute a × b + c in one GPU operation.",
            when: source.contains("fma("))
        addMath("dot(a, b)", "Measure alignment; dot(p, p) is squared radius.",
            when: source.contains("dot("))
        addMath("mix(a, b, t)", "Blend from a to b by t; t = 0 keeps a and t = 1 reaches b.",
            when: source.contains("mix("))
        addMath("clamp(x, lo, hi)", "Keep x inside a safe numeric interval.",
            when: source.contains("clamp("))
        addMath("max(x, floor)", "Give a denominator a safe lower bound near zero.",
            when: source.contains("max("))
        addMath("abs(x) / fabs(x)", "Take each component's absolute value; unlike length(v), this keeps a vector.",
            when: source.contains("abs(") || source.contains("fabs("))
        addMath("length(v) / normalize(v)", "Read a vector's radius or keep only its direction.",
            when: source.contains("length(") || source.contains("normalize("))
        addMath("cross(a, b)", "Build the vector perpendicular to a and b.",
            when: source.contains("cross("))
        addMath("atan2(y, x)", "Recover a signed polar angle from two coordinates.",
            when: source.contains("atan2("))
        addMath("sin / cos / sincos", "Periodic angle tools; sincos(a, c) returns sine and writes cosine into c.",
            when: source.contains("sin(") || source.contains("cos(") || source.contains("sincos("))
        addMath("log / exp", "Move between multiplicative scale and linear exponent space.",
            when: source.contains("log(") || source.contains("exp("))
        addMath("fmod(x, period)", "Wrap a scalar into a repeating interval.",
            when: source.contains("fmod("))
        addMath("floor / round", "Choose a repeated cell or radial octave.",
            when: source.contains("floor(") || source.contains("round("))
        addMath("float2/3 · .xy/.xz", "Construct vectors and select just the coordinates a map needs.",
            when: source.contains("float2(") || source.contains("float3(") || source.contains(".xy") || source.contains(".xz"))
        addMath("if / for", "Apply a rule conditionally or repeat a bounded fold.",
            when: source.contains("if (") || source.contains("for ("))
        addMath("scalar * float3", "A scalar multiplies every component of a vector.",
            when: source.contains(" * ") || source.contains(" *= "))

        if lesson.kind == .coxeter {
            addField("op.p1/p2 · op.axisX/Y",
                     "Packed components of two reflection-system mirror normals, not an editable direction.",
                     when: true)
        } else {
            addField("op.strength", "The primary control supplied by the transformation UI.",
                when: source.contains("op.strength"))
            addField("op.p1 / op.p2", "Extra scalar parameters already packed for the GPU.",
                when: source.contains("op.p1") || source.contains("op.p2"))
            addField("op.axisX/Y/Z", "Three packed components used as a direction or offset.",
                when: source.contains("op.axisX") || source.contains("op.axisY") || source.contains("op.axisZ"))
        }

        // Keep the card useful on small screens. The per-lesson hint supplies the
        // next layer of detail, and the full authored Metal remains an explicit reveal.
        return Array((mathEntries + fieldEntries).prefix(8))
    }

    /// Returns a built-in kind only when the entire tokenized input matches one
    /// complete authored mapping. Mathematical prompts are deliberately excluded.
    static func match(_ input: String) -> SpaceWarpKind? {
        guard let submitted = MetalPattern(input, byteLimit: maximumInputLength) else { return nil }
        for entry in authoredPatterns where entry.pattern.accepts(submitted) {
            return entry.kind
        }
        return nil
    }

    /// Evaluates an attempt against the selected lesson without compiling or
    /// executing it. Exact authored structure is still required, but consistent
    /// local-variable renaming is accepted and near misses receive non-spoiler
    /// feedback instead of a single password-style failure.
    static func assess(_ input: String,
                       for lesson: TransformationEquationLesson) -> TransformationEquationAttempt {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard input.utf8.count <= maximumInputLength else { return .tooLong }
        guard let submitted = MetalPattern(input, byteLimit: maximumInputLength) else {
            return input.unicodeScalars.allSatisfy(\.isASCII)
                ? .invalidSyntax
                : .nonASCIIPunctuation
        }

        let targetPatterns = authoredPatterns.filter { $0.lessonID == lesson.id }
        if targetPatterns.contains(where: { $0.pattern.accepts(submitted) }) {
            return .matched
        }
        if let other = authoredPatterns.first(where: {
            $0.lessonID != lesson.id && $0.pattern.accepts(submitted)
        }) {
            return .differentLesson(other.lessonID)
        }

        if targetPatterns.contains(where: { $0.pattern.atoms == submitted.atoms }) {
            return .statementBoundary
        }
        if targetPatterns.contains(where: {
            $0.pattern.atoms.map { $0.lowercased() }
                == submitted.atoms.map { $0.lowercased() }
        }) {
            return .caseMismatch
        }
        guard submitted.hasBalancedDelimiters else { return .unbalancedDelimiters }
        if targetPatterns.contains(where: { $0.pattern.hasPrefix(submitted) }) {
            return .incomplete
        }
        let bestPrefix = targetPatterns.map {
            $0.pattern.commonPrefixLength(with: submitted)
        }.max() ?? 0
        if bestPrefix >= 3 { return .openingMatches }
        if !submitted.atoms.contains("p") { return .missingPoint }
        return .structureMismatch
    }

    private static func lesson(
        _ kind: SpaceWarpKind,
        math: String,
        spokenMath: String,
        metal: String,
        hint: String,
        aliases: [String] = []
    ) -> TransformationEquationLesson {
        TransformationEquationLesson(
            id: .core(kind),
            kind: kind,
            mathematicalNotation: math,
            spokenMathematicalNotation: spokenMath,
            metalNotation: metal,
            hint: hint,
            acceptedAliases: aliases
        )
    }

    private struct AuthoredPattern {
        let pattern: MetalPattern
        let kind: SpaceWarpKind
        let lessonID: TransformationLessonID
    }

    private static let authoredPatterns: [AuthoredPattern] = {
        var result: [AuthoredPattern] = []
        for lesson in lessons {
            for source in [lesson.metalNotation] + lesson.acceptedAliases {
                guard let pattern = MetalPattern(source, byteLimit: maximumInputLength) else {
                    assertionFailure("Invalid authored Metal mapping for \(lesson.kind)")
                    continue
                }
                if result.contains(where: { $0.pattern == pattern && $0.kind != lesson.kind }) {
                    assertionFailure("Duplicate transformation equation mapping for \(lesson.kind)")
                    continue
                }
                result.append(AuthoredPattern(
                    pattern: pattern,
                    kind: lesson.kind,
                    lessonID: lesson.id
                ))
            }
        }
        return result
    }()
}

enum TransformationEquationAttempt: Equatable {
    case matched
    case differentLesson(TransformationLessonID)
    case empty
    case tooLong
    case nonASCIIPunctuation
    case invalidSyntax
    case caseMismatch
    case statementBoundary
    case unbalancedDelimiters
    case incomplete
    case openingMatches
    case missingPoint
    case structureMismatch

    var guidance: String {
        switch self {
        case .matched:
            return "This equation maps the selected transformation."
        case .differentLesson:
            return "That code forms a different map. Return to it when its lesson is available; this lesson unlocks from its own equation."
        case .empty:
            return "Enter the Metal point-map for the selected equation."
        case .tooLong:
            return "This attempt is longer than the lesson mapper accepts. Keep only the point transformation."
        case .nonASCIIPunctuation:
            return "Metal uses ASCII operators and punctuation. Replace mathematical symbols or smart punctuation with their code equivalents."
        case .invalidSyntax:
            return "The mapper could not read these Metal tokens. Check comments, numeric suffixes, operators, and punctuation."
        case .caseMismatch:
            return "The structure is right, but Metal identifiers are case-sensitive. Check the capitalization of each name."
        case .statementBoundary:
            return "The operations line up, but a statement boundary is misplaced. Check the semicolons."
        case .unbalancedDelimiters:
            return "A parenthesis, bracket, or brace is unmatched. Close the nested expression before mapping it."
        case .incomplete:
            return "Good start—the opening matches this map. Continue until the transformed value is left in `p`."
        case .openingMatches:
            return "The opening matches. Compare the next operator, `op` field, or delimiter with the selected clue."
        case .missingPoint:
            return "Use the mutable point `p` in the map and leave the transformed result in `p`."
        case .structureMismatch:
            return "These are readable Metal tokens, but the operations do not match the selected map yet. Compare one operation at a time with the clue."
        }
    }
}

/// User-level presentation choice. It never enters scene data and never changes
/// equation progress by itself.
enum TransformationExperienceMode: String, CaseIterable, Identifiable {
    case education
    case justUse

    static let defaultsKey = "Transformations.experienceMode.v1"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .education: return "Learn"
        case .justUse: return "Edit"
        }
    }

    static func decode(_ storedValue: String) -> TransformationExperienceMode {
        TransformationExperienceMode(rawValue: storedValue) ?? .justUse
    }
}

struct TransformationEducationLevel: Identifiable, Equatable {
    let id: Int
    let numeral: String
    let title: String
    let subtitle: String
    let kinds: [SpaceWarpKind]
    /// Mappings required in this level before the next level opens. The final
    /// level has no successor and therefore no threshold.
    let requiredToAdvance: Int?

    var lessons: [TransformationEquationLesson] {
        kinds.map { kind in
            guard let lesson = TransformationEquationCatalog.lessons.first(where: {
                $0.kind == kind
            }) else {
                preconditionFailure("Education level \(id) references missing lesson \(kind)")
            }
            return lesson
        }
    }
}

/// Authored curriculum order. Availability is derived entirely from successfully
/// mapped lesson IDs, so there is no separately persisted "current level" to drift.
enum TransformationEducationPath {
    static let levels: [TransformationEducationLevel] = [
        .init(
            id: 1,
            numeral: "I",
            title: "Foundations",
            subtitle: "Scale, reflect, and repeat coordinates.",
            kinds: [.scale, .mirror, .tiling],
            requiredToAdvance: 2
        ),
        .init(
            id: 2,
            numeral: "II",
            title: "Folds & Directions",
            subtitle: "Displace points and fold them across boundaries.",
            kinds: [.ripple, .boxFold, .planeFold, .offsetFold],
            requiredToAdvance: 3
        ),
        .init(
            id: 3,
            numeral: "III",
            title: "Curved & Repeating Space",
            subtitle: "Work with radii, angles, shells, and logarithmic repetition.",
            kinds: [.sphereFold, .inversion, .shells, .compressionShells,
                    .kaleidoscope, .circle, .scaleRepeat],
            requiredToAdvance: 4
        ),
        .init(
            id: 4,
            numeral: "IV",
            title: "Composition & Motion",
            subtitle: "Combine coordinate ordering with axis-driven motion.",
            kinds: [.mengerFold, .twist, .bend, .voronoi3D],
            requiredToAdvance: 2
        ),
        .init(
            id: 5,
            numeral: "V",
            title: "Systems & Recurrence",
            subtitle: "Assemble reflection systems and a full recurrence step.",
            kinds: [.coxeter, .icosahedralCut, .mandelboxStep],
            requiredToAdvance: nil
        ),
    ]

    static func mappedCount(in level: TransformationEducationLevel,
                            mappedIDs: Set<TransformationLessonID>) -> Int {
        level.lessons.reduce(into: 0) { count, lesson in
            if mappedIDs.contains(lesson.id) { count += 1 }
        }
    }

    static func isComplete(_ level: TransformationEducationLevel,
                           mappedIDs: Set<TransformationLessonID>) -> Bool {
        mappedCount(in: level, mappedIDs: mappedIDs) == level.kinds.count
    }

    static func isUnlocked(_ level: TransformationEducationLevel,
                           mappedIDs: Set<TransformationLessonID>) -> Bool {
        guard let index = levels.firstIndex(where: { $0.id == level.id }) else { return false }
        guard index > 0 else { return true }

        let previous = levels[index - 1]
        guard isUnlocked(previous, mappedIDs: mappedIDs),
              let threshold = previous.requiredToAdvance else { return false }
        return mappedCount(in: previous, mappedIDs: mappedIDs) >= threshold
    }

    static func unlockedLevelIDs(mappedIDs: Set<TransformationLessonID>) -> Set<Int> {
        Set(levels.filter { isUnlocked($0, mappedIDs: mappedIDs) }.map(\.id))
    }

    static func deepestUnlockedLevel(
        mappedIDs: Set<TransformationLessonID>
    ) -> TransformationEducationLevel {
        levels.last { isUnlocked($0, mappedIDs: mappedIDs) } ?? levels[0]
    }

    static func level(containing kind: SpaceWarpKind) -> TransformationEducationLevel? {
        levels.first { $0.kinds.contains(kind) }
    }

    /// The workbench follows the deepest open level. Once that level is exhausted,
    /// it returns to an unfinished earlier lesson rather than claiming completion.
    static func preferredLesson(
        mappedIDs: Set<TransformationLessonID>
    ) -> TransformationEquationLesson? {
        let current = deepestUnlockedLevel(mappedIDs: mappedIDs)
        if let next = current.lessons.first(where: { !mappedIDs.contains($0.id) }) {
            return next
        }
        return guideLessons(mappedIDs: mappedIDs).first {
            !mappedIDs.contains($0.id)
        } ?? current.lessons.first
    }

    /// The deepest currently open level is the actionable blocker for any later
    /// locked level; pointing at an inaccessible immediate predecessor is misleading.
    static func blockingLevel(for level: TransformationEducationLevel,
                              mappedIDs: Set<TransformationLessonID>) -> TransformationEducationLevel? {
        guard !isUnlocked(level, mappedIDs: mappedIDs) else { return nil }
        return deepestUnlockedLevel(mappedIDs: mappedIDs)
    }

    static func mappingsRemainingToAdvance(from level: TransformationEducationLevel,
                                           mappedIDs: Set<TransformationLessonID>) -> Int {
        guard let threshold = level.requiredToAdvance else { return 0 }
        return max(0, threshold - mappedCount(in: level, mappedIDs: mappedIDs))
    }

    static func newlyUnlockedLevels(before: Set<TransformationLessonID>,
                                    after: Set<TransformationLessonID>) -> [TransformationEducationLevel] {
        let previousIDs = unlockedLevelIDs(mappedIDs: before)
        return levels.filter {
            !previousIDs.contains($0.id) && isUnlocked($0, mappedIDs: after)
        }
    }

    static func unmappedLessonCount(mappedIDs: Set<TransformationLessonID>) -> Int {
        TransformationEquationCatalog.lessons.reduce(into: 0) { count, lesson in
            if !mappedIDs.contains(lesson.id) { count += 1 }
        }
    }

    /// Unlocked levels expose every lesson. A successfully mapped out-of-order
    /// lesson remains visible in its native locked level without opening that level.
    static func guideLessons(
        mappedIDs: Set<TransformationLessonID>
    ) -> [TransformationEquationLesson] {
        levels.flatMap { level in
            if isUnlocked(level, mappedIDs: mappedIDs) { return level.lessons }
            return level.lessons.filter { mappedIDs.contains($0.id) }
        }
    }
}

/// One access policy keeps direct-use availability separate from earned Education
/// progress. These functions are read-only: browsing or adding can never map a lesson.
enum TransformationAccessPolicy {
    /// Raw-ID entry point for imported stack data. Unknown future IDs fail closed
    /// instead of inheriting `SpaceWarpOpValue.kind`'s legacy Twist fallback.
    static func canInteract(withRawKindID rawKindID: Int32,
                            mode: TransformationExperienceMode,
                            mappedIDs: Set<Int32>) -> Bool {
        guard SpaceWarpKind(rawValue: rawKindID) != nil else { return false }
        return mode == .justUse || mappedIDs.contains(rawKindID)
    }

    static func canAdd(_ kind: SpaceWarpKind,
                       mode: TransformationExperienceMode,
                       mappedIDs: Set<Int32>) -> Bool {
        canInteract(
            withRawKindID: kind.rawValue,
            mode: mode,
            mappedIDs: mappedIDs
        )
    }

    static func addMenuLessons(mode: TransformationExperienceMode,
                               mappedIDs: Set<Int32>) -> [TransformationEquationLesson] {
        TransformationEquationCatalog.lessons.filter {
            canAdd($0.kind, mode: mode, mappedIDs: mappedIDs)
        }
    }

    static func canInspectSource(for kind: SpaceWarpKind,
                                 mode: TransformationExperienceMode,
                                 mappedIDs: Set<Int32>) -> Bool {
        canInteract(
            withRawKindID: kind.rawValue,
            mode: mode,
            mappedIDs: mappedIDs
        )
    }

    /// Pack recipes are all-or-nothing in Education: every constituent operator
    /// must already have been mapped. Returning the missing kinds lets a future
    /// pack browser guide the learner without revealing recipe internals early.
    static func missingKinds(for recipe: WarpRecipe,
                             mode: TransformationExperienceMode,
                             mappedIDs: Set<Int32>) -> [SpaceWarpKind] {
        recipe.requiredKinds.filter {
            !canAdd($0, mode: mode, mappedIDs: mappedIDs)
        }
    }

    static func canApply(_ recipe: WarpRecipe,
                         mode: TransformationExperienceMode,
                         mappedIDs: Set<Int32>) -> Bool {
        recipe.instantiate {
            canAdd($0, mode: mode, mappedIDs: mappedIDs)
        } != nil
    }

    /// The construction boundary itself is checked; callers never need to invoke
    /// a recipe builder first and remember to authorize its declared metadata.
    static func instantiate(_ recipe: WarpRecipe,
                            mode: TransformationExperienceMode,
                            mappedIDs: Set<Int32>) -> [SpaceWarpOpValue]? {
        recipe.instantiate {
            canAdd($0, mode: mode, mappedIDs: mappedIDs)
        }
    }

    static func eligibleKinds<S: Sequence>(from candidates: S,
                                            mode: TransformationExperienceMode,
                                            mappedIDs: Set<Int32>) -> Set<SpaceWarpKind>
    where S.Element == SpaceWarpKind {
        Set(candidates.filter { canAdd($0, mode: mode, mappedIDs: mappedIDs) })
    }

    /// Reward/existence checks must use the persisted raw discriminator. The model's
    /// legacy `kind` convenience falls unknown future IDs back to Twist for rendering;
    /// treating that fallback as identity would suppress a real Twist unlock.
    static func hasExactInstance(of kind: SpaceWarpKind,
                                 in stack: [SpaceWarpOpValue]) -> Bool {
        stack.contains { $0.type == kind.rawValue }
    }
}

enum TransformationAssistanceStage: Int, Comparable {
    case theory
    case vocabulary
    case hint
    case fullAnswer

    static func < (lhs: TransformationAssistanceStage,
                   rhs: TransformationAssistanceStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum TransformationAssistanceEvent {
    case showVocabulary
    case requestHint
    case revealAnswer
}

/// Session-local help progresses monotonically. An unmapped lesson cannot reveal
/// its answer before its hint, while a completed lesson may be reviewed directly.
enum TransformationAssistancePolicy {
    static func advance(from stage: TransformationAssistanceStage,
                        event: TransformationAssistanceEvent,
                        isMapped: Bool,
        isFocused: Bool) -> TransformationAssistanceStage {
        switch event {
        case .showVocabulary:
            guard isFocused else { return stage }
            return max(stage, .vocabulary)
        case .requestHint:
            guard isFocused, stage >= .vocabulary else { return stage }
            return max(stage, .hint)
        case .revealAnswer:
            guard isMapped || (isFocused && stage >= .hint) else { return stage }
            return .fullAnswer
        }
    }

    static func canRevealAnswer(from stage: TransformationAssistanceStage,
                                isMapped: Bool,
                                isFocused: Bool) -> Bool {
        isMapped || (isFocused && stage >= .hint)
    }
}

/// A very small, strict lexer for the subset of Metal used by lesson mappings.
/// It preserves identifier case and token boundaries. Numeric `f`/`F` suffixes
/// and an optional final semicolon are the only spelling grace.
private struct MetalPattern: Equatable {
    let atoms: [String]
    let semicolonBoundaries: Set<Int>

    private static let declarationTypes: Set<String> = [
        "bool", "int", "uint", "float", "float2", "float3", "float4",
        "float2x2", "float3x3", "float4x4",
    ]
    private static let reservedIdentifiers: Set<String> = Set([
        "p", "p0", "op", "true", "false", "if", "else", "for", "while",
        "return", "break", "continue",
    ]).union(declarationTypes)

    init?(_ source: String, byteLimit: Int) {
        guard !source.isEmpty, source.utf8.count <= byteLimit,
              let lexed = MetalLexer.lex(source)
        else { return nil }
        atoms = lexed.atoms
        semicolonBoundaries = lexed.semicolonBoundaries
    }

    func accepts(_ submitted: MetalPattern) -> Bool {
        let optionalFinalBoundary = semicolonBoundaries.contains(atoms.count)
            ? Set([atoms.count])
            : []
        let requiredBoundaries = semicolonBoundaries.subtracting(optionalFinalBoundary)
        return atomsMatch(submitted.atoms)
            && requiredBoundaries.isSubset(of: submitted.semicolonBoundaries)
            && submitted.semicolonBoundaries.isSubset(of: semicolonBoundaries)
    }

    var hasBalancedDelimiters: Bool {
        var stack: [String] = []
        let closingToOpening = [")": "(", "]": "[", "}": "{"]
        for atom in atoms {
            if atom == "(" || atom == "[" || atom == "{" {
                stack.append(atom)
            } else if let expected = closingToOpening[atom] {
                guard stack.popLast() == expected else { return false }
            }
        }
        return stack.isEmpty
    }

    func hasPrefix(_ submitted: MetalPattern) -> Bool {
        guard submitted.atoms.count < atoms.count else { return false }
        return Array(atoms.prefix(submitted.atoms.count)) == submitted.atoms
    }

    func commonPrefixLength(with submitted: MetalPattern) -> Int {
        var count = 0
        for (authored, candidate) in zip(atoms, submitted.atoms) {
            guard authored == candidate else { break }
            count += 1
        }
        return count
    }

    /// Accepts consistent renaming of authored local temporaries while keeping
    /// `p`, `p0`, `op`, field names, functions, types, and operators exact.
    private func atomsMatch(_ submittedAtoms: [String]) -> Bool {
        guard atoms.count == submittedAtoms.count else { return false }
        let locals = localIdentifiers
        var bindings: [String: String] = [:]
        var claimedSubmittedNames: Set<String> = []

        for (authored, submitted) in zip(atoms, submittedAtoms) {
            if locals.contains(authored) {
                if let bound = bindings[authored] {
                    guard bound == submitted else { return false }
                } else {
                    guard MetalLexer.isIdentifier(submitted),
                          !Self.reservedIdentifiers.contains(submitted),
                          claimedSubmittedNames.insert(submitted).inserted else { return false }
                    bindings[authored] = submitted
                }
            } else if authored != submitted {
                return false
            }
        }
        return true
    }

    private var localIdentifiers: Set<String> {
        var result: Set<String> = []
        guard atoms.count > 1 else { return result }
        for index in 0..<(atoms.count - 1) where Self.declarationTypes.contains(atoms[index]) {
            let candidate = atoms[index + 1]
            guard MetalLexer.isIdentifier(candidate),
                  !Self.reservedIdentifiers.contains(candidate),
                  (index + 2 >= atoms.count || atoms[index + 2] != "(") else { continue }
            result.insert(candidate)
        }
        return result
    }
}

private enum MetalLexer {
    struct Result {
        let atoms: [String]
        let semicolonBoundaries: Set<Int>
    }

    private static let doubleOperators: Set<String> = [
        "++", "--", "+=", "-=", "*=", "/=", "<=", ">=", "==", "!=", "&&", "||",
    ]
    private static let singleSymbols: Set<UInt8> = Set("+-*/%=<>&|!?:.,(){}[]".utf8)

    static func isIdentifier(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard let first = bytes.first, isIdentifierStart(first) else { return false }
        return bytes.dropFirst().allSatisfy(isIdentifierContinuation)
    }

    static func lex(_ source: String) -> Result? {
        let bytes = Array(source.utf8)
        var atoms: [String] = []
        var semicolonBoundaries: Set<Int> = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            guard byte < 0x80 else { return nil }

            if isWhitespace(byte) {
                index += 1
                continue
            }

            if byte == ascii("/") && index + 1 < bytes.count {
                if bytes[index + 1] == ascii("/") {
                    index += 2
                    while index < bytes.count && bytes[index] != ascii("\n") { index += 1 }
                    continue
                }
                if bytes[index + 1] == ascii("*") {
                    index += 2
                    var closed = false
                    while index + 1 < bytes.count {
                        if bytes[index] == ascii("*") && bytes[index + 1] == ascii("/") {
                            index += 2
                            closed = true
                            break
                        }
                        index += 1
                    }
                    guard closed else { return nil }
                    continue
                }
            }

            if isIdentifierStart(byte) {
                let start = index
                index += 1
                while index < bytes.count && isIdentifierContinuation(bytes[index]) { index += 1 }
                atoms.append(String(decoding: bytes[start..<index], as: UTF8.self))
                continue
            }

            if isDigit(byte) || (byte == ascii(".") && index + 1 < bytes.count && isDigit(bytes[index + 1])) {
                guard let number = scanNumber(bytes, from: &index) else { return nil }
                atoms.append(number)
                continue
            }

            if byte == ascii(";") {
                guard semicolonBoundaries.insert(atoms.count).inserted else { return nil }
                index += 1
                continue
            }

            if index + 1 < bytes.count {
                let pair = String(decoding: bytes[index...(index + 1)], as: UTF8.self)
                if doubleOperators.contains(pair) {
                    atoms.append(pair)
                    index += 2
                    continue
                }
            }

            if singleSymbols.contains(byte) {
                atoms.append(String(UnicodeScalar(byte)))
                index += 1
                continue
            }

            return nil
        }

        guard !atoms.isEmpty else { return nil }
        return Result(atoms: atoms, semicolonBoundaries: semicolonBoundaries)
    }

    private static func scanNumber(_ bytes: [UInt8], from index: inout Int) -> String? {
        let start = index
        var hasWholeDigits = false
        while index < bytes.count && isDigit(bytes[index]) {
            hasWholeDigits = true
            index += 1
        }

        var hasFractionDigits = false
        if index < bytes.count && bytes[index] == ascii(".") {
            index += 1
            while index < bytes.count && isDigit(bytes[index]) {
                hasFractionDigits = true
                index += 1
            }
        }
        guard hasWholeDigits || hasFractionDigits else { return nil }

        if index < bytes.count && (bytes[index] == ascii("e") || bytes[index] == ascii("E")) {
            index += 1
            if index < bytes.count && (bytes[index] == ascii("+") || bytes[index] == ascii("-")) {
                index += 1
            }
            let exponentStart = index
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
            guard index > exponentStart else { return nil }
        }

        let numericEnd = index
        if index < bytes.count && (bytes[index] == ascii("f") || bytes[index] == ascii("F")) {
            index += 1
        }

        if index < bytes.count && isIdentifierContinuation(bytes[index]) { return nil }
        return String(decoding: bytes[start..<numericEnd], as: UTF8.self)
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    private static func isUppercase(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }
    private static func isLowercase(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }
    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        isUppercase(byte) || isLowercase(byte) || byte == ascii("_")
    }
    private static func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || isDigit(byte)
    }
}

enum TransformationUnlockProgress {
    /// User-level progress stays out of scene/preset formats. V2 stores stable,
    /// namespaced curriculum IDs; V1 remains readable so existing learners keep
    /// everything they previously mapped.
    static let defaultsKey = "Transformations.unlockedEquationLessonIDs.v2"
    static let legacyDefaultsKey = "Transformations.unlockedEquationRawIDs.v1"

    /// UI callers see only lessons understood by this build. Unknown semantic IDs
    /// remain in the V2 payload whenever another lesson is unlocked, allowing a
    /// build without an optional transformation pack to preserve that pack's data.
    static func decode(_ encoded: String,
                       legacyEncoded: String = "") -> Set<TransformationLessonID> {
        let knownIDs = Set(TransformationEquationCatalog.lessons.map(\.id))
        return storedLessonIDs(encoded)
            .union(migratedLegacyIDs(legacyEncoded))
            .intersection(knownIDs)
    }

    /// Runtime access is still expressed in renderer IDs at the final boundary.
    /// Keeping this projection explicit prevents the curriculum store from taking
    /// an accidental dependency on GPU enum values again.
    static func runtimeKindIDs(
        from lessonIDs: Set<TransformationLessonID>
    ) -> Set<Int32> {
        Set(TransformationEquationCatalog.lessons.compactMap { lesson in
            lessonIDs.contains(lesson.id) ? lesson.kind.rawValue : nil
        })
    }

    /// Deterministic JSON avoids delimiter restrictions on future pack namespaces.
    /// Invalid IDs are discarded, while valid IDs unknown to this build survive.
    static func encode(_ lessonIDs: Set<TransformationLessonID>) -> String {
        let rawValues = lessonIDs
            .filter(\.isSafeForLocalStorage)
            .map(\.rawValue)
            .sorted()
        guard let data = try? JSONEncoder().encode(rawValues),
              let encoded = String(data: data, encoding: .utf8) else { return "[]" }
        return encoded
    }

    /// Returns a canonical V2 snapshot that merges any already-present pack IDs
    /// with known lessons imported from the legacy raw-ID store.
    static func migratedEncoding(_ encoded: String, legacyEncoded: String) -> String {
        encode(storedLessonIDs(encoded).union(migratedLegacyIDs(legacyEncoded)))
    }

    static func unlock(_ kind: SpaceWarpKind,
                       in encoded: String,
                       legacyEncoded: String = "") -> String {
        unlock(kind, merging: [encoded], legacyEncodedValues: [legacyEncoded])
    }

    /// Merges cached and freshly persisted snapshots before adding a mapping. This
    /// prevents two scene windows from overwriting one another's recently earned ID.
    static func unlock(_ kind: SpaceWarpKind,
                       merging encodedValues: [String],
                       legacyEncodedValues: [String] = []) -> String {
        var lessonIDs = encodedValues.reduce(into: Set<TransformationLessonID>()) {
            result, encoded in
            result.formUnion(storedLessonIDs(encoded))
        }
        for legacyEncoded in legacyEncodedValues {
            lessonIDs.formUnion(migratedLegacyIDs(legacyEncoded))
        }
        lessonIDs.insert(.core(kind))
        return encode(lessonIDs)
    }

    static func contains(_ kind: SpaceWarpKind,
                         in encoded: String,
                         legacyEncoded: String = "") -> Bool {
        decode(encoded, legacyEncoded: legacyEncoded).contains(.core(kind))
    }

    private static func storedLessonIDs(_ encoded: String) -> Set<TransformationLessonID> {
        guard let data = encoded.data(using: .utf8),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(rawValues.compactMap { rawValue in
            let lessonID = TransformationLessonID(rawValue: rawValue)
            return lessonID.isSafeForLocalStorage ? lessonID : nil
        })
    }

    private static func migratedLegacyIDs(_ encoded: String) -> Set<TransformationLessonID> {
        Set(encoded.split(separator: ",").compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawID = Int32(trimmed), rawID >= 0,
                  let kind = SpaceWarpKind(rawValue: rawID) else { return nil }
            return .core(kind)
        })
    }

}

/// Scene-local drafts follow lessons rather than the currently visible text field.
/// Switching clues cannot submit a retained answer under the wrong prompt, and
/// unknown pack drafts survive while that pack is not installed.
enum TransformationEquationDraftStore {
    private static let maximumStoredDraftLength =
        TransformationEquationCatalog.maximumInputLength * 2

    static func draft(for lessonID: TransformationLessonID,
                      in encoded: String) -> String {
        storedDrafts(encoded)[lessonID] ?? ""
    }

    static func update(_ draft: String,
                       for lessonID: TransformationLessonID,
                       in encoded: String) -> String {
        var drafts = storedDrafts(encoded)
        if draft.isEmpty {
            drafts.removeValue(forKey: lessonID)
        } else if lessonID.isSafeForLocalStorage {
            drafts[lessonID] = String(draft.prefix(maximumStoredDraftLength))
        }
        return encode(drafts)
    }

    static func decode(_ encoded: String) -> [TransformationLessonID: String] {
        storedDrafts(encoded)
    }

    /// V1 used `-1` for its original default lesson (Mirror) and otherwise stored
    /// `SpaceWarpKind.rawValue`. Unknown future raw IDs remain unresolved instead
    /// of being filed under the wrong lesson.
    static func legacyLessonID(focusedRawID: Int) -> TransformationLessonID? {
        if focusedRawID < 0 { return .core(.mirror) }
        guard let rawID = Int32(exactly: focusedRawID),
              let kind = SpaceWarpKind(rawValue: rawID) else { return nil }
        return .core(kind)
    }

    private static func storedDrafts(
        _ encoded: String
    ) -> [TransformationLessonID: String] {
        guard let data = encoded.data(using: .utf8),
              let rawDrafts = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return rawDrafts.reduce(into: [:]) { result, entry in
            let lessonID = TransformationLessonID(rawValue: entry.key)
            guard lessonID.isSafeForLocalStorage,
                  entry.value.count <= maximumStoredDraftLength else { return }
            result[lessonID] = entry.value
        }
    }

    private static func encode(_ drafts: [TransformationLessonID: String]) -> String {
        let rawDrafts = Dictionary(uniqueKeysWithValues: drafts.map {
            ($0.key.rawValue, $0.value)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rawDrafts),
              let encoded = String(data: data, encoding: .utf8) else { return "{}" }
        return encoded
    }
}

/// A durable record of text the learner explicitly checked. Drafts remain
/// scene-local, while these results follow app-level learning progress so a
/// completed answer is still available after the workbench clears it.
struct TransformationEquationCheckRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let lessonID: TransformationLessonID
    let submittedText: String
    let wasAccepted: Bool
    let feedback: String
    let checkedAt: Date
}

enum TransformationEquationCheckHistoryStore {
    static let defaultsKey = "Transformations.educationCheckHistory.v1"
    static let maximumChecksPerLesson = 10
    static let maximumStoredChecks = 60

    static func checks(for lessonID: TransformationLessonID,
                       in encoded: String) -> [TransformationEquationCheckRecord] {
        decode(encoded).filter { $0.lessonID == lessonID }
    }

    static func record(_ submittedText: String,
                       assessment: TransformationEquationAttempt,
                       for lessonID: TransformationLessonID,
                       merging encodedValues: [String],
                       id: UUID = UUID(),
                       checkedAt: Date = Date()) -> String {
        guard lessonID.isSafeForLocalStorage else {
            return encode(mergedChecks(encodedValues))
        }
        let boundedText = boundedUTF8(
            submittedText,
            maximumBytes: TransformationEquationCatalog.maximumInputLength
        )
        guard !boundedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encode(mergedChecks(encodedValues))
        }

        var checks = mergedChecks(encodedValues)
        checks.removeAll { $0.id == id }
        checks.append(TransformationEquationCheckRecord(
            id: id,
            lessonID: lessonID,
            submittedText: boundedText,
            wasAccepted: assessment == .matched,
            feedback: assessment.guidance,
            checkedAt: checkedAt
        ))
        return encode(pruned(checks))
    }

    static func decode(_ encoded: String) -> [TransformationEquationCheckRecord] {
        guard let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                [TransformationEquationCheckRecord].self,
                from: data
              ) else {
            return []
        }
        return pruned(decoded.filter { check in
            check.lessonID.isSafeForLocalStorage
                && !check.submittedText.isEmpty
                && check.submittedText.utf8.count
                    <= TransformationEquationCatalog.maximumInputLength
                && check.feedback.utf8.count <= 1_024
                && check.checkedAt.timeIntervalSinceReferenceDate.isFinite
        })
    }

    private static func mergedChecks(
        _ encodedValues: [String]
    ) -> [TransformationEquationCheckRecord] {
        var checksByID: [UUID: TransformationEquationCheckRecord] = [:]
        for encoded in encodedValues {
            for check in decode(encoded) {
                checksByID[check.id] = check
            }
        }
        return Array(checksByID.values)
    }

    private static func pruned(
        _ checks: [TransformationEquationCheckRecord]
    ) -> [TransformationEquationCheckRecord] {
        let newestFirst = checks.sorted {
            if $0.checkedAt != $1.checkedAt {
                return $0.checkedAt > $1.checkedAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }
        var countByLesson: [TransformationLessonID: Int] = [:]
        var kept: [TransformationEquationCheckRecord] = []
        for check in newestFirst {
            let lessonCount = countByLesson[check.lessonID, default: 0]
            guard lessonCount < maximumChecksPerLesson,
                  kept.count < maximumStoredChecks else { continue }
            kept.append(check)
            countByLesson[check.lessonID] = lessonCount + 1
        }
        return kept
    }

    private static func encode(
        _ checks: [TransformationEquationCheckRecord]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(pruned(checks)),
              let encoded = String(data: data, encoding: .utf8) else { return "[]" }
        return encoded
    }

    private static func boundedUTF8(_ value: String,
                                    maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var byteCount = 0
        var endIndex = value.startIndex
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumBytes else { break }
            byteCount += characterByteCount
            endIndex = value.index(after: endIndex)
        }
        return String(value[..<endIndex])
    }
}
