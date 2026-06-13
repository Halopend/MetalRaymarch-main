import SwiftUI

/// Live diagnostic bar showing how a music-reactive offset (drift/pulse/etc.)
/// composes with the parameter's base value inside its min...max range:
///
///   |────────●━━━━━◆────────|
///   min     base   final    max
///
/// - White tick `●`  = base value (preset/slider/gesture layers).
/// - Pink band `━━`  = current music-layer offset from the base.
/// - Dot `◆`         = final clamped value the renderer actually uses.
///
/// When base + offset lands outside the range the final dot pins at the bound
/// and the bar edge glows red — the state where the finger control or a
/// freshly loaded preset appears to "stop working" because further base
/// movement is swallowed by the clamp.
/// Convenience wrapper for core/effect sliders: resolves the parameter node
/// for a `MusicReactiveTarget` and shows the drift bar only while that target
/// has an enabled music mapping. Renders nothing otherwise.
struct MusicDriftIndicatorRow: View {
    var cache: UISettingsCache
    let target: MusicReactiveTarget

    private var hasEnabledMapping: Bool {
        cache.audioReactive.musicReactiveMappings.contains { $0.target == target && $0.isEnabled }
    }

    private var resolvedNode: FloatParameterNode? {
        guard let id = target.parameterTargetID(for: cache.fractalType) else { return nil }
        let registry = ParameterNodeRegistry.shared
        return registry.coreNodes[id] ?? registry.effectNodes[id]
    }

    var body: some View {
        if hasEnabledMapping, let node = resolvedNode {
            MusicDriftIndicatorBar(node: node)
                .padding(.horizontal, 20)
        }
    }
}

struct MusicDriftIndicatorBar: View {
    let node: FloatParameterNode

    private static let refreshInterval: TimeInterval = 1.0 / 15.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
            let info = node.inspectLayers()
            bar(for: info)
        }
        .frame(height: 14)
        .help("Music drift: white tick = base value, pink band = audio offset, dot = final value. Red edge = pinned at range limit.")
    }

    @ViewBuilder
    private func bar(for info: ParameterLayerInspection) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = max(info.range.upperBound - info.range.lowerBound, .leastNonzeroMagnitude)
            let position: (Float) -> CGFloat = { value in
                let t = (min(max(value, info.range.lowerBound), info.range.upperBound) - info.range.lowerBound) / span
                return CGFloat(t) * width
            }

            let baseX = position(info.baseValue)
            let finalX = position(info.finalValue)
            let trackY = geo.size.height / 2

            ZStack(alignment: .leading) {
                // Range track
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 3)
                    .position(x: width / 2, y: trackY)
                    .frame(width: width)

                // Music offset band (base → final)
                if abs(finalX - baseX) > 0.5 {
                    Capsule()
                        .fill(Color.pink.opacity(0.55))
                        .frame(width: abs(finalX - baseX), height: 3)
                        .position(x: (baseX + finalX) / 2, y: trackY)
                }

                // Base value tick
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: 10)
                    .position(x: baseX, y: trackY)

                // Final resolved value
                Circle()
                    .fill(info.isPinned ? Color.red : Color.pink)
                    .frame(width: 7, height: 7)
                    .position(x: finalX, y: trackY)

                // Saturation warning at the pinned bound
                if info.isPinned {
                    Capsule()
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 3, height: 12)
                        .position(x: info.isPinnedHigh ? width - 1.5 : 1.5, y: trackY)
                }
            }
        }
    }
}
