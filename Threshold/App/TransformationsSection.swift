//
//  TransformationsSection.swift
//  Threshold
//
//  Composable domain transforms ("Transformations") applied to ANY fractal before
//  the distance-estimator runs. A single selector (`RenderSettings.spaceWarpType`)
//  picks one operator from a catalog ported from Mandelbulber's transf_* vocabulary
//  (twist, bend, folds, spherical inversion, kaleidoscope, ripple). The master
//  amount is `spaceWarpStrength` (0 = off → the whole feature is dead-code
//  eliminated on the GPU). Each operator reads the generic warp params
//  (`spaceWarpParam1/2/3`) with its own meaning — see the GPU `applySpaceWarp`
//  switch in Shaders.metal. Twist & Bend additionally use the axis/origin from
//  `TwistShapingSection`.
//

import SwiftUI
import simd

/// The built-in domain-warp catalog. Raw values MUST match the GPU
/// `applySpaceWarp` / `applySpaceWarpDEScale` switch in Shaders.metal.
enum SpaceWarpKind: Int32, CaseIterable, Identifiable {
    case twist = 0
    case bend = 1
    case mirror = 2
    case boxFold = 3
    case sphereFold = 4
    case inversion = 5
    case kaleidoscope = 6
    case ripple = 7

    var id: Int32 { rawValue }

    var displayName: String {
        switch self {
        case .twist:        return "Twist"
        case .bend:         return "Bend"
        case .mirror:       return "Mirror Fold"
        case .boxFold:      return "Box Fold"
        case .sphereFold:   return "Sphere Fold"
        case .inversion:    return "Spherical Inversion"
        case .kaleidoscope: return "Kaleidoscope"
        case .ripple:       return "Ripple"
        }
    }

    var icon: String {
        switch self {
        case .twist:        return "tornado"
        case .bend:         return "wind"
        case .mirror:       return "square.on.square"
        case .boxFold:      return "cube"
        case .sphereFold:   return "circle.circle"
        case .inversion:    return "globe"
        case .kaleidoscope: return "snowflake"
        case .ripple:       return "waveform.path"
        }
    }

    /// Label for the master strength slider (verb fits the operator).
    var amountLabel: String {
        switch self {
        case .twist:        return "Twist"
        case .bend:         return "Bend"
        case .ripple:       return "Ripple"
        default:            return "Amount"
        }
    }

    /// One-line hint shown under the picker.
    var blurb: String {
        switch self {
        case .twist:        return "Rotate space progressively along an axis. Aim it with Twist Shaping below."
        case .bend:         return "Bow space around an axis. Aim it with Twist Shaping below."
        case .mirror:       return "Reflect space into mirror-symmetric copies."
        case .boxFold:      return "Fold coordinates back inside a box — the iconic Mandelbox fold, applied once."
        case .sphereFold:   return "Inflate the inner region radially (Mandelbox sphere fold)."
        case .inversion:    return "Turn space inside-out through a sphere."
        case .kaleidoscope: return "Fold the view into N rotational wedges."
        case .ripple:       return "Accordion-displace space along an axis."
        }
    }

    /// A default master strength when the user first activates this transform.
    var defaultStrength: Float {
        switch self {
        case .twist, .bend, .ripple: return 0.6
        default:                     return 1.0   // folds blend 0…1
        }
    }

    /// Per-operator scalar sliders bound to spaceWarpParam1/2/3.
    var params: [ParamSpec] {
        switch self {
        case .twist, .bend, .mirror:
            return []
        case .boxFold:
            return [ParamSpec(index: 1, label: "Fold Limit", icon: "cube", range: 0.1...3.0, defaultValue: 1.0)]
        case .sphereFold:
            return [
                ParamSpec(index: 1, label: "Min Radius", icon: "smallcircle.filled.circle", range: 0.05...2.0, defaultValue: 0.5),
                ParamSpec(index: 2, label: "Max Radius", icon: "circle.circle", range: 0.1...4.0, defaultValue: 1.0),
            ]
        case .inversion:
            return [ParamSpec(index: 1, label: "Radius", icon: "globe", range: 0.1...3.0, defaultValue: 1.0)]
        case .kaleidoscope:
            return [ParamSpec(index: 1, label: "Segments", icon: "snowflake", range: 2.0...16.0, defaultValue: 6.0)]
        case .ripple:
            return [ParamSpec(index: 1, label: "Frequency", icon: "waveform.path", range: 0.1...8.0, defaultValue: 2.0)]
        }
    }

    struct ParamSpec: Identifiable {
        let index: Int             // 1, 2, or 3 → spaceWarpParam{N}
        let label: String
        let icon: String
        let range: ClosedRange<Float>
        let defaultValue: Float
        var id: Int { index }
    }
}

struct TransformationsSection: View {
    let renderSettings: RenderSettings

    // RenderSettings is not Observable; bump this to force the rows to re-read
    // after an external / programmatic mutation (e.g. seeding defaults on switch).
    @State private var refresh: Int = 0

    private var kind: SpaceWarpKind {
        SpaceWarpKind(rawValue: renderSettings.spaceWarpType) ?? .twist
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Transformations", systemImage: "circle.hexagongrid")
                .font(.headline)

            Text("Reshape space before the fractal is drawn. Works with any fractal; stack with Twist Shaping, Sphere Projection, and Spherical Inversion.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Transform", selection: kindBinding) {
                ForEach(SpaceWarpKind.allCases) { k in
                    Label(k.displayName, systemImage: k.icon).tag(k)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text(kind.blurb)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Master amount.
            EffectSliderRow(
                icon: kind.icon, label: kind.amountLabel,
                value: Binding(
                    get: { renderSettings.spaceWarpStrength },
                    set: { renderSettings.spaceWarpStrength = $0 }),
                range: ControlCatalog.spaceWarpStrength.range,
                enabled: .constant(true),
                onChanged: {},
                showToggle: false)

            // Per-operator scalars.
            ForEach(kind.params) { spec in
                EffectSliderRow(
                    icon: spec.icon, label: spec.label,
                    value: Binding(
                        get: { paramValue(spec.index) },
                        set: { setParam(spec.index, $0) }),
                    range: spec.range,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)
            }
        }
        .id(refresh)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.mint.opacity(0.07)))
    }

    private var kindBinding: Binding<SpaceWarpKind> {
        Binding(
            get: { kind },
            set: { newKind in
                renderSettings.spaceWarpType = newKind.rawValue
                // Seed sensible defaults for the new operator so the generic params
                // don't carry a stale meaning from the previous transform, and make
                // the effect immediately visible if it was off.
                for spec in newKind.params { setParam(spec.index, spec.defaultValue) }
                if renderSettings.spaceWarpStrength <= 0 {
                    renderSettings.spaceWarpStrength = newKind.defaultStrength
                }
                refresh &+= 1
            })
    }

    private func paramValue(_ index: Int) -> Float {
        switch index {
        case 1:  return renderSettings.spaceWarpParam1
        case 2:  return renderSettings.spaceWarpParam2
        default: return renderSettings.spaceWarpParam3
        }
    }

    private func setParam(_ index: Int, _ value: Float) {
        switch index {
        case 1:  renderSettings.spaceWarpParam1 = value
        case 2:  renderSettings.spaceWarpParam2 = value
        default: renderSettings.spaceWarpParam3 = value
        }
    }
}
