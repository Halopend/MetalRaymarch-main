import simd

enum Raymarch {
    struct Settings: Sendable {
        var tMin: Float
        var tMax: Float
        var hitThreshold: Float
        var maxSteps: Int
        var omega: Float

        init(tMin: Float, tMax: Float, hitThreshold: Float, maxSteps: Int, omega: Float) {
            self.tMin = tMin
            self.tMax = tMax
            self.hitThreshold = hitThreshold
            self.maxSteps = maxSteps
            self.omega = omega
        }
    }

    struct TraceResult {
        var hit: Bool
        var t: Float
        var steps: Int
        var mapCalls: Int
    }

    // Minimal “Scene” loop: sphere tracing with optional over-relaxation.
    // We don’t model glow/color; we care about hit distance and cost.
    static func trace(
        origin: SIMD3<Float>,
        dir: SIMD3<Float>,
        map: (SIMD3<Float>) -> Float,
        settings: Settings
    ) -> TraceResult {
        var t = settings.tMin
        var prevH: Float = 1e10
        var calls = 0

        for step in 0..<settings.maxSteps {
            let p = origin + dir * t
            var h = map(p)
            calls += 1

            if !h.isFinite {
                return TraceResult(hit: false, t: t, steps: step + 1, mapCalls: calls)
            }

            if h < settings.hitThreshold {
                return TraceResult(hit: true, t: t, steps: step + 1, mapCalls: calls)
            }

            if t > settings.tMax {
                return TraceResult(hit: false, t: t, steps: step + 1, mapCalls: calls)
            }

            // Over-relaxation (very similar intent to the shader’s omega logic).
            // Clamp factor to avoid big instabilities.
            let denom = max(h + prevH, 1e-6)
            let relax = 1 + (settings.omega - 1) * (h / denom)
            let dt = max(h * 0.2, h * min(max(relax, 1.0), 1.8))

            prevH = h
            t += dt
        }

        return TraceResult(hit: false, t: t, steps: settings.maxSteps, mapCalls: calls)
    }
}
