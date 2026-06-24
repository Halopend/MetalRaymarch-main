//
//  ContentView+GestureHands.swift
//  Threshold
//
//  "Constellation Hands" — the reworked hero for the Gestures pane.
//  Two large mirrored hands (the `HandSilhouette` vector asset) reach toward a
//  central channel. Each index/middle/ring fingertip is a tappable orb that maps
//  one hand's finger (vertical / horizontal / depth axes). A pairing line bridges
//  each matching fingertip pair — tapping it assigns the BOTH-hands gesture for
//  that finger (GestureSlot(hand:.both)). Per-finger mutual exclusion is enforced
//  by `cache.setGestureBinding` (RenderSettings.setBinding); the UI just reflects it.
//
//  Layout constants live in `GH` for easy tuning against a screenshot.
//

import SwiftUI

// MARK: - Palette + layout

private enum GH {
    static let blue        = Color(red: 0x5B/255, green: 0x9C/255, blue: 0xFF/255)
    static let assignedBg  = Color(red: 0x10/255, green: 0x24/255, blue: 0x3F/255)
    static let pairedBg     = Color(red: 0x16/255, green: 0x20/255, blue: 0x2F/255)
    static let label        = Color(red: 0xE6/255, green: 0xEE/255, blue: 0xFB/255)

    /// HandSilhouette.svg viewBox is 1000 × 729 (fingers point right).
    static let handAspect: CGFloat = 1000.0 / 729.0

    /// Fingertip anchors as UnitPoints within the un-mirrored hand image.
    /// (Derived from the SVG path's right-edge tip clusters: index ~0.25,
    /// middle reaches the edge ~0.44, ring ~0.69.)
    static let anchors: [FingerDigit: CGPoint] = [
        .index:  CGPoint(x: 0.93,  y: 0.25),
        .middle: CGPoint(x: 0.965, y: 0.44),
        .ring:   CGPoint(x: 0.93,  y: 0.69),
    ]

    static let stageHeight: CGFloat = 250
    static let handWidthFactor: CGFloat = 0.42
    static let handWidthCap: CGFloat = 320
    static let orbDiameter: CGFloat = 30
    static let orbHit: CGFloat = 48
    static let lineInset: CGFloat = 20   // gap between orb edge and pairing line

    static func handWidth(_ W: CGFloat) -> CGFloat {
        min(W * handWidthFactor, handWidthCap, (stageHeight - 24) * handAspect)
    }
    static func handCenterX(_ hand: GestureHandMode, _ W: CGFloat) -> CGFloat {
        let hw = handWidth(W)
        return hand == .left ? hw / 2 : W - hw / 2
    }
    static func orbCenter(_ hand: GestureHandMode, _ finger: FingerDigit, _ W: CGFloat) -> CGPoint {
        let hw = handWidth(W)
        let hh = hw / handAspect
        let top = stageHeight / 2 - hh / 2
        let a = anchors[finger] ?? CGPoint(x: 0.9, y: 0.5)
        let x = hand == .left ? a.x * hw : (W - hw) + (1 - a.x) * hw
        return CGPoint(x: x, y: top + a.y * hh)
    }
}

// MARK: - Hero panel

extension ContentView {

    var gestureHandConstellationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Hand Assignments", systemImage: "hand.point.up.left.and.text")
                .font(.subheadline.weight(.semibold))

            GeometryReader { geo in
                let W = geo.size.width
                ZStack {
                    constellationHand(.left, W)
                    constellationHand(.right, W)

                    Text("LEFT")
                        .font(.caption2.weight(.semibold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                        .position(x: GH.handCenterX(.left, W), y: 10)
                    Text("RIGHT")
                        .font(.caption2.weight(.semibold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                        .position(x: GH.handCenterX(.right, W), y: 10)

                    ForEach(FingerDigit.allCases, id: \.self) { finger in
                        constellationPairLine(finger, W)
                    }
                    ForEach(FingerDigit.allCases, id: \.self) { finger in
                        fingertipOrbMenu(.left, finger)
                            .position(GH.orbCenter(.left, finger, W))
                        fingertipOrbMenu(.right, finger)
                            .position(GH.orbCenter(.right, finger, W))
                        pairChipMenu(finger)
                            .position(x: W / 2, y: GH.orbCenter(.left, finger, W).y)
                    }
                }
            }
            .frame(height: GH.stageHeight)

            Text("Tap a fingertip to map one hand  ·  tap the line between matching fingers for a both-hands gesture.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // ── Hand silhouette ──────────────────────────────────────────────────────

    @ViewBuilder
    private func constellationHand(_ hand: GestureHandMode, _ W: CGFloat) -> some View {
        let hw = GH.handWidth(W)
        let hh = hw / GH.handAspect
        Image("HandSilhouette")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: hw, height: hh)
            .foregroundStyle(.secondary.opacity(0.20))
            .scaleEffect(x: hand == .left ? 1 : -1, y: 1)
            .position(x: GH.handCenterX(hand, W), y: GH.stageHeight / 2)
            .allowsHitTesting(false)
    }

    // ── Pairing line (both-hands binding) ────────────────────────────────────

    @ViewBuilder
    private func constellationPairLine(_ finger: FingerDigit, _ W: CGFloat) -> some View {
        let both = cache.gestureBinding(for: GestureSlot(hand: .both, finger: finger))
        let active = both != .core(.none)
        let lc = GH.orbCenter(.left, finger, W)
        let rc = GH.orbCenter(.right, finger, W)
        let x1 = lc.x + GH.lineInset
        let x2 = rc.x - GH.lineInset
        if x2 > x1 + 4 {
            PairLineShape(x1: x1, x2: x2, y: lc.y)
                .stroke(active ? GH.blue.opacity(0.9) : Color.secondary.opacity(0.30),
                        style: StrokeStyle(lineWidth: active ? 4 : 1.6,
                                           lineCap: .round,
                                           dash: active ? [] : [2, 6]))
                .allowsHitTesting(false)
        }
    }

    // ── Single-hand fingertip orb (Menu) ─────────────────────────────────────

    @ViewBuilder
    private func fingertipOrbMenu(_ hand: GestureHandMode, _ finger: FingerDigit) -> some View {
        let paired = cache.gestureBinding(for: GestureSlot(hand: .both, finger: finger)) != .core(.none)
        let vSlot = GestureSlot(hand: hand, finger: finger, direction: .vertical)
        let hSlot = GestureSlot(hand: hand, finger: finger, direction: .horizontal)
        let zSlot = GestureSlot(hand: hand, finger: finger, direction: .depth)
        let vB = cache.gestureBinding(for: vSlot)
        let hB = cache.gestureBinding(for: hSlot)
        let zB = cache.gestureBinding(for: zSlot)
        let lit = [vB, hB, zB].filter { $0 != .core(.none) }.count
        let dominant = [vB, hB, zB].first { $0 != .core(.none) }
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: hand)

        Menu {
            gestureAxisMenuSection("Vertical", vSlot, vB, bindings)
            gestureAxisMenuSection("Horizontal", hSlot, hB, bindings)
            gestureAxisMenuSection("Depth", zSlot, zB, bindings)
            if lit > 0 {
                Divider()
                Button("Clear Finger", role: .destructive) {
                    cache.setGestureBinding(.core(.none), for: vSlot)
                    cache.setGestureBinding(.core(.none), for: hSlot)
                    cache.setGestureBinding(.core(.none), for: zSlot)
                }
            }
        } label: {
            FingerOrbLabel(paired: paired, litCount: lit,
                           iconName: paired ? "arrow.left.arrow.right" : (dominant?.icon ?? "plus"))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func gestureAxisMenuSection(_ title: String, _ slot: GestureSlot,
                                        _ current: GestureActionBinding,
                                        _ bindings: [GestureActionBinding]) -> some View {
        Section(title) {
            ForEach(bindings, id: \.self) { action in
                Button {
                    cache.setGestureBinding(action, for: slot)
                } label: {
                    HStack {
                        Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon)
                        if current == action { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }

    // ── Both-hands pairing chip (Menu) ───────────────────────────────────────

    @ViewBuilder
    private func pairChipMenu(_ finger: FingerDigit) -> some View {
        let slot = GestureSlot(hand: .both, finger: finger)
        let both = cache.gestureBinding(for: slot)
        let paired = both != .core(.none)
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: .both)

        Menu {
            ForEach(bindings, id: \.self) { action in
                Button {
                    cache.setGestureBinding(action, for: slot)
                } label: {
                    HStack {
                        Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon)
                        if both == action { Image(systemName: "checkmark") }
                    }
                }
            }
            if paired {
                Divider()
                Button("Clear Pair", role: .destructive) {
                    cache.setGestureBinding(.core(.none), for: slot)
                }
            }
        } label: {
            PairChipLabel(paired: paired,
                          title: paired ? both.contextualDisplayName(for: cache.fractalType) : "pair",
                          iconName: paired ? both.icon : "plus")
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Visual leaves

private struct FingerOrbLabel: View {
    let paired: Bool
    let litCount: Int
    let iconName: String

    private var strokeColor: Color {
        paired ? GH.blue.opacity(0.45) : (litCount > 0 ? GH.blue : Color.secondary.opacity(0.4))
    }
    private var fillColor: Color {
        paired ? GH.pairedBg : (litCount > 0 ? GH.assignedBg : Color.secondary.opacity(0.06))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .overlay(
                    Circle().strokeBorder(strokeColor,
                        style: StrokeStyle(lineWidth: paired ? 1.4 : (litCount > 0 ? 1.6 : 1),
                                           dash: paired ? [2, 3] : []))
                )
                .frame(width: GH.orbDiameter, height: GH.orbDiameter)

            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(paired ? GH.blue.opacity(0.7)
                                        : (litCount > 0 ? GH.label : Color.secondary))

            if !paired && litCount > 0 {
                Text("\(litCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(GH.blue)
                    .frame(width: 15, height: 15)
                    .background(
                        Circle().fill(GH.assignedBg)
                            .overlay(Circle().strokeBorder(GH.blue.opacity(0.5), lineWidth: 1))
                    )
                    .offset(x: GH.orbDiameter / 2 - 3, y: GH.orbDiameter / 2 - 3)
            }
        }
        .frame(width: GH.orbHit, height: GH.orbHit)
        .contentShape(Circle())
    }
}

private struct PairChipLabel: View {
    let paired: Bool
    let title: String
    let iconName: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName).font(.system(size: 10, weight: .semibold))
            Text(title).font(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .foregroundStyle(paired ? GH.label : Color.secondary)
        .background(
            Capsule()
                .fill(paired ? GH.assignedBg : Color.secondary.opacity(0.05))
                .overlay(
                    Capsule().strokeBorder(paired ? GH.blue.opacity(0.45) : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: paired ? [] : [2, 3]))
                )
        )
        .fixedSize()
    }
}

private struct PairLineShape: Shape {
    let x1: CGFloat
    let x2: CGFloat
    let y: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x1, y: y))
        p.addLine(to: CGPoint(x: x2, y: y))
        return p
    }
}
