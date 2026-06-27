//
//  TwistShapingSection.swift
//  Threshold
//
//  Orientation + origin controls for the built-in "Twist" space warp.
//  The twist axis (orientation) is `RenderSettings.spaceWarpAxis`; the origin
//  point is carried by the generic warp params (`spaceWarpOrigin`). A reset
//  restores the default vertical axis through the world center. These shape
//  whatever the Twist slider applies — at strength 0 they have no visible effect.
//

import SwiftUI
import simd

struct TwistShapingSection: View {
    let renderSettings: RenderSettings

    // RenderSettings is not Observable, so the slider rows read through closures.
    // Bumping this token forces a re-read after an external mutation (Reset).
    @State private var refresh: Int = 0

    private static let axisRange: ClosedRange<Float> = -1.0...1.0
    private static let originRange: ClosedRange<Float> = -4.0...4.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Twist Shaping", systemImage: "tornado")
                    .font(.headline)
                Spacer()
                Button {
                    renderSettings.spaceWarpAxis = SIMD3<Float>(0, 1, 0)
                    renderSettings.spaceWarpOrigin = .zero
                    refresh &+= 1
                } label: {
                    Label("Reset", systemImage: AppIcons.arrowCounterclockwise)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Text("Aim the twist axis and move its pivot. The default twists about the vertical axis through the center.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Axis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            axisRow("Axis X", "arrow.left.and.right", \SIMD3<Float>.x)
            axisRow("Axis Y", "arrow.up.and.down", \SIMD3<Float>.y)
            axisRow("Axis Z", "arrow.up.left.and.arrow.down.right", \SIMD3<Float>.z)

            Text("Origin")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            originRow("Origin X", "arrow.left.and.right", \SIMD3<Float>.x)
            originRow("Origin Y", "arrow.up.and.down", \SIMD3<Float>.y)
            originRow("Origin Z", "arrow.up.left.and.arrow.down.right", \SIMD3<Float>.z)
        }
        .id(refresh)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
    }

    private func axisRow(_ label: String, _ icon: String, _ comp: WritableKeyPath<SIMD3<Float>, Float>) -> some View {
        EffectSliderRow(
            icon: icon, label: label,
            value: Binding(
                get: { renderSettings.spaceWarpAxis[keyPath: comp] },
                set: { var a = renderSettings.spaceWarpAxis; a[keyPath: comp] = $0; renderSettings.spaceWarpAxis = a }
            ),
            range: Self.axisRange,
            enabled: .constant(true),
            onChanged: {},
            showToggle: false)
    }

    private func originRow(_ label: String, _ icon: String, _ comp: WritableKeyPath<SIMD3<Float>, Float>) -> some View {
        EffectSliderRow(
            icon: icon, label: label,
            value: Binding(
                get: { renderSettings.spaceWarpOrigin[keyPath: comp] },
                set: { var o = renderSettings.spaceWarpOrigin; o[keyPath: comp] = $0; renderSettings.spaceWarpOrigin = o }
            ),
            range: Self.originRange,
            enabled: .constant(true),
            onChanged: {},
            showToggle: false)
    }
}
