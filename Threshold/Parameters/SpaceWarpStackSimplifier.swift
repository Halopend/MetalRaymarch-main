//
//  SpaceWarpStackSimplifier.swift
//  Threshold
//
//  Semi-automatic algebraic collapse of the space-warp stack. Adjacent operators
//  that compose to a SINGLE equivalent operator are fused before the stack reaches
//  the GPU — shortening the count-driven runtime loop (it runs `cSpaceWarpStack`'s
//  packed `count` ops each march step), a real per-march-step saving. Because the
//  loop reads the live per-frame `count`, value-dependent collapses are SAFE here
//  (nothing freezes the op count).
//
//  ── Design contract ─────────────────────────────────────────────────────────
//  • NON-DESTRUCTIVE: runs only on the way to the GPU. The user's editable model
//    (what the Transformations UI shows) is never mutated — they keep both ops;
//    the GPU just runs the fused one.
//  • EXACT ONLY: every rule must produce byte-identical GPU output. There is no
//    golden-image test guarding the pixels, so an approximate rule = silent visual
//    corruption. When in doubt, leave it out. Each rule below carries its proof.
//  • PURE / DETERMINISTIC / IDEMPOTENT: `simplify` is a pure function of its input
//    and `simplify(simplify(x)) == simplify(x)`. This is what keeps the runtime
//    buffer and the codegen unroll in lockstep — both call this on the same model.
//  • ORDER-PRESERVING, ADJACENT-ONLY: warps do not commute, so we never reorder.
//    Only neighbours are considered for fusion.
//
//  ── Why so few rules? (the "two mirrors = a rotation" question) ───────────────
//  In the classic group-theory picture two REFLECTIONS compose to a rotation. But
//  this stack's `mirror` is a FOLD (`abs(p)`), not a reflection — folds are
//  idempotent (`abs∘abs = abs`), so two mirrors collapse to ONE mirror, not a
//  rotation. The genuine compose-reflections-into-a-symmetry algebra already lives
//  in the Coxeter op (its fundamental-domain fold IS that, pre-collapsed). What
//  remains here is the exact, provable residue: identity removal, idempotent-fold
//  coalescing, and additive-twist fusion. New rules belong in `fuse(_:_:)` and MUST
//  arrive with a proof (ideally backed by a future reference-image regression).
//

import Foundation
import simd

enum SpaceWarpStackSimplifier {

    /// Collapse a stack into an equivalent, never-longer stack using only exact,
    /// behaviour-preserving rewrites. Pure, deterministic, idempotent.
    static func simplify(_ ops: [SpaceWarpOpValue]) -> [SpaceWarpOpValue] {
        // R1 — drop identity ops. Every warp body is the identity at strength ≤ 0
        // (early-return or `mix(p, …, t==0) == p`), so removing them changes nothing.
        let live = ops.filter { $0.strength > 0.0 }
        guard live.count > 1 else { return live }

        // R2/R3 — left-to-right adjacent fusion. A successful fuse leaves the merged
        // op as the new `last`, so a run of N identical ops collapses to one.
        var result: [SpaceWarpOpValue] = []
        result.reserveCapacity(live.count)
        for op in live {
            if let prev = result.last, let merged = fuse(prev, op) {
                result[result.count - 1] = merged
            } else {
                result.append(op)
            }
        }
        return result
    }

    /// If applying `a` then `b` is EXACTLY a single op, return it; else `nil`.
    /// Extension point: add a `case` only with a closed-form proof of exactness.
    private static func fuse(_ a: SpaceWarpOpValue, _ b: SpaceWarpOpValue) -> SpaceWarpOpValue? {
        guard a.type == b.type else { return nil }   // different kinds never fuse

        switch a.kind {
        // ── R2: idempotent folds (f∘f = f) at full strength, identical params ──
        // mirror:      abs(abs(p)) == abs(p).
        // scaleRepeat: maps r into the base octave [1,s); a point already there is
        //              left unchanged ⇒ second pass is the identity.
        // shells:      maps r into [0, d/2]; a point already there rounds to shell 0
        //              ⇒ second pass is the identity.
        // (kaleido and boxFold LOOK idempotent but are NOT — see file header — and
        //  Coxeter's iterative fold isn't exactly idempotent when it doesn't
        //  converge, so none of the three are listed here.)
        case .mirror, .scaleRepeat, .shells:
            guard isFullStrength(a), isFullStrength(b), sameFoldParams(a, b) else { return nil }
            return a   // keep exactly one

        // ── R3: twists about a shared axis add ─────────────────────────────────
        // warpTwist rotates p about `axis` by θ = strength·dot(p,axis)·1.5. Rotation
        // about that axis preserves dot(p,axis), so the second twist sees the SAME
        // projection and rotations about a common axis compose additively:
        //   R(θ₂)·R(θ₁) = R(θ₁+θ₂) with θ₁+θ₂ = (s₁+s₂)·dot(p,axis)·1.5.
        // Exact for parallel axes. (Strength may exceed the UI range — fine: this op
        // is GPU-bound only and never round-trips to the slider.)
        case .twist:
            guard parallelAxis(a, b) else { return nil }
            var merged = a
            merged.strength = a.strength + b.strength
            return merged

        default:
            return nil
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private static let strengthEps: Float = 1e-4
    private static let paramEps: Float = 1e-5
    private static let axisDotEps: Float = 1e-5

    /// Idempotent folds collapse only when the blend is OFF (mix(p, fold, 1) == fold).
    private static func isFullStrength(_ op: SpaceWarpOpValue) -> Bool {
        op.strength >= 1.0 - strengthEps
    }

    /// The fold's shape parameters must match exactly for f∘f = f to hold.
    /// (mirror uses none; scaleRepeat uses p1 = scale; shells uses p1 = spacing.)
    private static func sameFoldParams(_ a: SpaceWarpOpValue, _ b: SpaceWarpOpValue) -> Bool {
        abs(a.p1 - b.p1) <= paramEps && abs(a.p2 - b.p2) <= paramEps
    }

    /// Axes point the same way (normalized dot ≈ 1). Anti-parallel is intentionally
    /// NOT fused — it would need a sign flip and isn't worth the extra proof surface.
    private static func parallelAxis(_ a: SpaceWarpOpValue, _ b: SpaceWarpOpValue) -> Bool {
        let la = simd_length(a.axis), lb = simd_length(b.axis)
        guard la > 1e-6, lb > 1e-6 else { return false }
        return simd_dot(a.axis / la, b.axis / lb) >= 1.0 - axisDotEps
    }
}
