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

    static let stageHeight: CGFloat = 268
    /// Center gap reserved for the pairing-line chips. Hands fill the rest, so the
    /// channel never collapses regardless of pane width (more robust than a fixed cap).
    static let channelMin: CGFloat = 230
    static let handWidthCap: CGFloat = 440
    static let orbDiameter: CGFloat = 36
    static let orbHit: CGFloat = 54
    static let lineInset: CGFloat = 22   // gap between orb edge and pairing line

    static func handWidth(_ W: CGFloat) -> CGFloat {
        max(120, min((W - channelMin) / 2, handWidthCap, (stageHeight - 20) * handAspect))
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
        VStack(alignment: .leading, spacing: 4) {
            Label("Hand Assignments", systemImage: AppIcons.handPointUpLeftAndText)
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

            gestureAssignmentsSummary
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
            .foregroundStyle(.secondary.opacity(0.28))
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
    //
    // Param-first menu: each control is listed ONCE; you pick which axis it claims.
    //   • Whole-finger bindings (Translate, an XYZ triplet) → "Claim All Axes".
    //   • Scalar params → "Claim Vertical / Horizontal / Depth".
    // The verb flips to "Reclaim" when the target axis (or the whole finger) is
    // already taken, so free vs. occupied reads at a glance. A finger is EITHER one
    // whole-finger binding OR per-axis scalars (within-finger mutual exclusion).

    @ViewBuilder
    private func fingertipOrbMenu(_ hand: GestureHandMode, _ finger: FingerDigit) -> some View {
        let paired = cache.gestureBinding(for: GestureSlot(hand: .both, finger: finger)) != .core(.none)
        let whole = currentWholeBinding(hand, finger)
        let vB = cache.gestureBinding(for: GestureSlot(hand: hand, finger: finger, direction: .vertical))
        let hB = cache.gestureBinding(for: GestureSlot(hand: hand, finger: finger, direction: .horizontal))
        let zB = cache.gestureBinding(for: GestureSlot(hand: hand, finger: finger, direction: .depth))
        let scalarCount = [vB, hB, zB].filter { $0 != .core(.none) }.count
        let lit = whole != nil ? 3 : scalarCount
        let centerIcon = paired ? "arrow.left.arrow.right"
            : (whole?.icon ?? [vB, hB, zB].first { $0 != .core(.none) }?.icon ?? "plus")

        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: hand)
        let threeAxis = bindings.filter { $0.isThreeAxisFinger }
        let scalars = bindings.filter { $0.isScalarParam }

        Menu {
            if !threeAxis.isEmpty {
                Section("Whole finger") {
                    ForEach(threeAxis, id: \.self) { b in
                        Menu {
                            wholeFingerClaimButton(b, hand, finger)
                        } label: {
                            Label(b.contextualDisplayName(for: cache.fractalType), systemImage: b.icon)
                        }
                    }
                }
            }
            Section("Single-axis dials") {
                ForEach(scalars, id: \.self) { p in
                    Menu {
                        axisClaimButton(p, .vertical, hand, finger)
                        axisClaimButton(p, .horizontal, hand, finger)
                        axisClaimButton(p, .depth, hand, finger)
                    } label: {
                        Label(p.contextualDisplayName(for: cache.fractalType), systemImage: p.icon)
                    }
                }
            }
            if lit > 0 {
                Divider()
                Button("Clear Finger", role: .destructive) { clearFinger(hand, finger) }
            }
        } label: {
            FingerOrbLabel(paired: paired, litCount: lit, iconName: centerIcon)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func wholeFingerClaimButton(_ b: GestureActionBinding,
                                        _ hand: GestureHandMode, _ finger: FingerDigit) -> some View {
        let isCurrent = currentWholeBinding(hand, finger) == b
        let hasOther = fingerHasAnyBinding(hand, finger) && !isCurrent
        Button {
            if isCurrent { clearFinger(hand, finger) } else { claimAllAxes(b, hand, finger) }
        } label: {
            if isCurrent { Label("Remove (all axes)", systemImage: AppIcons.checkmark) }
            else { Text(hasOther ? "Reclaim All Axes" : "Claim All Axes") }
        }
    }

    @ViewBuilder
    private func axisClaimButton(_ p: GestureActionBinding, _ axis: GestureDirection,
                                 _ hand: GestureHandMode, _ finger: FingerDigit) -> some View {
        let slot = GestureSlot(hand: hand, finger: finger, direction: axis)
        let occupant = cache.gestureBinding(for: slot)
        let whole = currentWholeBinding(hand, finger)
        let isThisHere = (whole == nil && occupant == p)
        let taken = (whole != nil) || (occupant != .core(.none) && !isThisHere)
        Button {
            if isThisHere { cache.setGestureBinding(.core(.none), for: slot) }
            else { claimScalar(p, axis, hand, finger) }
        } label: {
            if isThisHere { Label("Remove \(axis.displayName)", systemImage: AppIcons.checkmark) }
            else { Text("\(taken ? "Reclaim" : "Claim") \(axis.displayName)") }
        }
    }

    // ── Within-finger binding actions ────────────────────────────────────────

    /// The whole-finger (3-axis) binding occupying this finger, if any. By
    /// convention a 3-axis binding is stored in the finger's vertical slot.
    private func currentWholeBinding(_ hand: GestureHandMode, _ finger: FingerDigit) -> GestureActionBinding? {
        let vB = cache.gestureBinding(for: GestureSlot(hand: hand, finger: finger, direction: .vertical))
        return vB.isThreeAxisFinger ? vB : nil
    }

    private func fingerHasAnyBinding(_ hand: GestureHandMode, _ finger: FingerDigit) -> Bool {
        GestureDirection.allCases.contains {
            cache.gestureBinding(for: GestureSlot(hand: hand, finger: finger, direction: $0)) != .core(.none)
        }
    }

    private func claimAllAxes(_ b: GestureActionBinding, _ hand: GestureHandMode, _ finger: FingerDigit) {
        cache.setGestureBinding(.core(.none), for: GestureSlot(hand: hand, finger: finger, direction: .horizontal))
        cache.setGestureBinding(.core(.none), for: GestureSlot(hand: hand, finger: finger, direction: .depth))
        cache.setGestureBinding(b, for: GestureSlot(hand: hand, finger: finger, direction: .vertical))
    }

    private func claimScalar(_ p: GestureActionBinding, _ axis: GestureDirection,
                             _ hand: GestureHandMode, _ finger: FingerDigit) {
        // Claiming a single axis displaces any whole-finger binding first.
        if currentWholeBinding(hand, finger) != nil {
            cache.setGestureBinding(.core(.none), for: GestureSlot(hand: hand, finger: finger, direction: .vertical))
        }
        cache.setGestureBinding(p, for: GestureSlot(hand: hand, finger: finger, direction: axis))
    }

    private func clearFinger(_ hand: GestureHandMode, _ finger: FingerDigit) {
        for dir in GestureDirection.allCases {
            cache.setGestureBinding(.core(.none), for: GestureSlot(hand: hand, finger: finger, direction: dir))
        }
    }

    // ── Assignments summary (communicates EVERY per-axis binding) ────────────

    @ViewBuilder
    var gestureAssignmentsSummary: some View {
        let hasAny = FingerDigit.allCases.contains { f in
            cache.gestureBinding(for: GestureSlot(hand: .both, finger: f)) != .core(.none)
                || fingerHasAnyBinding(.left, f) || fingerHasAnyBinding(.right, f)
        }
        VStack(alignment: .leading, spacing: 4) {
            if hasAny {
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    summaryRows(for: finger)
                }
            } else {
                Text("No finger gestures assigned yet.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func summaryRows(for finger: FingerDigit) -> some View {
        let both = cache.gestureBinding(for: GestureSlot(hand: .both, finger: finger))
        if both != .core(.none) {
            HStack(spacing: 8) {
                Text("Both · \(finger.displayName)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                summaryChip("⇄", both.icon, both.contextualDisplayName(for: cache.fractalType))
                Spacer(minLength: 0)
            }
        } else {
            ForEach([GestureHandMode.left, GestureHandMode.right], id: \.self) { hand in
                if fingerHasAnyBinding(hand, finger) {
                    summaryFingerRow(hand, finger)
                }
            }
        }
    }

    @ViewBuilder
    private func summaryFingerRow(_ hand: GestureHandMode, _ finger: FingerDigit) -> some View {
        HStack(spacing: 6) {
            Text("\(hand == .left ? "L" : "R") · \(finger.displayName)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            if let whole = currentWholeBinding(hand, finger) {
                summaryChip("XYZ", whole.icon, whole.contextualDisplayName(for: cache.fractalType))
            } else {
                ForEach(GestureDirection.allCases, id: \.self) { dir in
                    let b = cache.gestureBinding(for: GestureSlot(hand: hand, finger: finger, direction: dir))
                    if b != .core(.none) {
                        summaryChip(dir.glyph, b.icon, b.contextualDisplayName(for: cache.fractalType))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func summaryChip(_ axisGlyph: String, _ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Text(axisGlyph).font(.system(size: 9, weight: .bold)).foregroundStyle(GH.blue)
            Image(systemName: icon).font(.system(size: IconSize.micro))
            Text(text).font(.caption2).lineLimit(1)
        }
        .foregroundStyle(GH.label.opacity(0.9))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
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
                        if both == action { Image(systemName: AppIcons.checkmark) }
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

// MARK: - Binding arity helpers

extension GestureActionBinding {
    /// Bindings that consume all three movement axes at once (direction is ignored
    /// by the engine): Translate and the XYZ parameter triplets.
    var isThreeAxisFinger: Bool {
        switch self {
        case .core(.translate), .parameterTriplet: return true
        default: return false
        }
    }
    /// A single 1-D scalar parameter, assignable to one chosen axis.
    var isScalarParam: Bool {
        if case .parameter = self { return true }
        return false
    }
}

extension GestureDirection {
    /// Compact glyph for the assignments summary.
    var glyph: String {
        switch self {
        case .vertical:   return "↕"
        case .horizontal: return "↔"
        case .depth:      return "⤢"
        }
    }
}
