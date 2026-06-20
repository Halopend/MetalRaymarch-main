import SwiftUI

// MARK: - Scroll Proxy Environment

struct ScrollProxyKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ScrollViewProxy? = nil
}

extension EnvironmentValues {
    var scrollProxy: ScrollViewProxy? {
        get { self[ScrollProxyKey.self] }
        set { self[ScrollProxyKey.self] = newValue }
    }
}

struct ParameterNodeGroup: Identifiable {
    let id: String
    let triplet: GestureBindableTriplet?
    let nodes: [AnyParameterNodeBase]
}

struct FormulaParamsEditor: View {
    @Bindable var cache: UISettingsCache
    @State private var cachedGroups: [ParameterNodeGroup] = []

    private var descriptor: FormulaDescriptor? {
        FormulaCatalog.shared.descriptor(for: cache.fractalType)
    }

    private var parameterBatch: ParameterNodeBatch {
        ParameterNodeRegistry.shared.formulaBatch(for: cache.fractalType)
    }

    private static func buildNodeGroups(for fractalType: FractalModelType) -> [ParameterNodeGroup] {
        let batch = ParameterNodeRegistry.shared.formulaBatch(for: fractalType)
        let triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: fractalType)
        var groups: [ParameterNodeGroup] = []
        var processedIDs: Set<String> = []
        
        for node in batch.allNodes {
            if processedIDs.contains(node.id) { continue }
            
            if let triplet = triplets.first(where: { 
                $0.xNodeID == node.id || $0.yNodeID == node.id || $0.zNodeID == node.id 
            }) {
                let tripletNodes = batch.allNodes.filter { 
                    $0.id == triplet.xNodeID || $0.id == triplet.yNodeID || $0.id == triplet.zNodeID 
                }
                groups.append(ParameterNodeGroup(id: triplet.groupName, triplet: triplet, nodes: tripletNodes))
                for tNode in tripletNodes {
                    processedIDs.insert(tNode.id)
                }
            } else {
                groups.append(ParameterNodeGroup(id: node.id, triplet: nil, nodes: [node]))
                processedIDs.insert(node.id)
            }
        }
        return groups
    }

    var body: some View {
        if let desc = descriptor, !parameterBatch.allNodes.isEmpty {
            VStack(spacing: 8) {
                HStack {
                    Label("\(desc.name) Parameters", systemImage: cache.fractalType.icon)
                        .font(.headline)
                    Spacer()
                    Button {
                        cache.resetFormulaParams()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reset to defaults")
                }

                Text(desc.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(cachedGroups) { group in
                    if let triplet = group.triplet {
                        VStack(spacing: 6) {
                            TripletRow(cache: cache, triplet: triplet)

                            DisclosureGroup("Parameters") {
                                VStack(spacing: 6) {
                                ForEach(group.nodes) { node in
                                    ParameterNodeRow(cache: cache, node: node)
                                        .id(node.id)
                                    if node.id == "formula.1.0.Power" {
                                        PowerQuickPicker(cache: cache, node: node)
                                    }
                                }
                            }
                            .padding(.top, 2)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    } else {
                        VStack(spacing: 6) {
                            ForEach(group.nodes) { node in
                                ParameterNodeRow(cache: cache, node: node)
                                    .id(node.id)

                                if node.id == "formula.1.0.Power" {
                                    PowerQuickPicker(cache: cache, node: node)
                                }
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
            .onAppear { cachedGroups = Self.buildNodeGroups(for: cache.fractalType) }
            .onChange(of: cache.fractalType) { _, newType in cachedGroups = Self.buildNodeGroups(for: newType) }
        }
    }
}

private struct ParameterNodeRow: View {
    private var operationFrameIndex: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    @Bindable var cache: UISettingsCache
    let node: AnyParameterNodeBase

    /// When true, shows the sensitivity slider instead of the parameter slider.
    @Environment(\.scrollProxy) private var scrollProxy
    @State private var isFlipped: Bool = false
    /// Local copy of this parameter's gesture sensitivity for the slider binding.
    @State private var sensitivityValue: Float = GestureSensitivityStore.defaultSensitivity

    /// Small dead-zone around the midpoint so neutral 1.0x is easy to land on.
    private let sensitivityNeutralSnapThreshold: Float = 0.02

    /// Slider position in [0,1] where 0.5 is neutral (1.0x).
    /// Left half maps to reduced sensitivity, right half maps to increased sensitivity.
    private var sensitivitySliderPosition: Binding<Float> {
        Binding(
            get: {
                let minValue = GestureSensitivityStore.range.lowerBound
                let maxValue = GestureSensitivityStore.range.upperBound
                let clamped = min(max(sensitivityValue, minValue), maxValue)

                // Log-space mapping gives symmetric precision below/above 1.0x.
                // 0.0 -> 0.1x, 0.5 -> 1.0x, 1.0 -> 10.0x.
                let exponent = log10f(clamped)
                return min(max((exponent + 1.0) * 0.5, 0.0), 1.0)
            },
            set: { position in
                let defaultValue = GestureSensitivityStore.defaultSensitivity
                let clampedPosition = min(max(position, 0.0), 1.0)

                if abs(clampedPosition - 0.5) <= sensitivityNeutralSnapThreshold {
                    sensitivityValue = defaultValue
                } else {
                    let exponent = (clampedPosition * 2.0) - 1.0
                    sensitivityValue = powf(10.0, exponent)
                }
            }
        )
    }

    private var supportsGestureShortcuts: Bool {
#if os(visionOS)
        true
#else
        false
#endif
    }

    var body: some View {
        if let boolNode = node as? BoolParameterNode {
            HStack(spacing: 8) {
                Image(systemName: boolNode.icon).font(.caption).frame(width: 16)
                Text(boolNode.name)
                    .font(.subheadline)
                    .frame(width: 135, alignment: .leading)
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding<Bool>(
                    get: { boolNode.readValue(cache) },
                    set: { value in
                        cache.dispatchParameterOperation(
                            ParameterOperation(
                                targetID: boolNode.id,
                                source: .slider,
                                value: .absolute(value ? 1.0 : 0.0),
                                frameIndex: operationFrameIndex
                            )
                        )
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .frame(height: 32)
        }

        if let floatNode = node as? FloatParameterNode {
            ZStack {
                // ── FRONT: Normal parameter slider ──
                if !isFlipped {
                    frontFace(floatNode: floatNode)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }

                // ── BACK: Gesture sensitivity slider ──
                if isFlipped {
                    backFace(floatNode: floatNode)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isFlipped)
            .onAppear {
                sensitivityValue = GestureSensitivityStore.shared.sensitivity(for: floatNode.id)
            }
            .onChange(of: isFlipped) { _, flipped in
                if flipped {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy?.scrollTo(node.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Front Face (Parameter Slider)

    @ViewBuilder
    private func frontFace(floatNode: FloatParameterNode) -> some View {
        VStack(spacing: 2) {
            frontFaceControls(floatNode: floatNode)

            // Live drift diagnostic: where the music offset puts the final
            // value inside the gesture/slider min...max range.
            if let target = musicReactiveTarget, hasMusicMapping(target) {
                MusicDriftIndicatorBar(node: floatNode)
                    .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func frontFaceControls(floatNode: FloatParameterNode) -> some View {
        HStack(spacing: 4) {
            EffectSliderRow(
                icon: floatNode.icon,
                label: floatNode.name,
                value: Binding<Float>(
                    get: { floatNode.readValue(cache) },
                    set: { value in
                        cache.dispatchParameterOperation(
                            ParameterOperation(
                                targetID: floatNode.id,
                                source: .slider,
                                value: .absolute(value),
                                frameIndex: operationFrameIndex
                            )
                        )
                    }
                ),
                range: floatNode.range,
                enabled: .constant(true),
                onChanged: {},
                showToggle: false,
                musicTargetID: floatNode.id
            )

            if floatNode.isGestureMappable {
                if supportsGestureShortcuts, let formulaBinding = floatGestureBinding {
                    Menu {
                        // Filter hand modes: triplets only work on single-hand
                        let isTriplet: Bool = { if case .parameterTriplet = formulaBinding { return true }; return false }()
                        let validModes: [GestureHandMode] = isTriplet ? [.left, .right] : GestureHandMode.allCases
                        ForEach(validModes, id: \.self) { mode in
                            Menu(mode.displayName) {
                                ForEach(FingerDigit.allCases, id: \.self) { finger in
                                    let slot = GestureSlot(hand: mode, finger: finger)
                                    let isCurrentSlot = currentGestureSlot == slot
                                    Button {
                                        cache.setGestureBinding(formulaBinding, for: slot)
                                    } label: {
                                        HStack {
                                            Label(finger.displayName, systemImage: finger.icon)
                                            if isCurrentSlot {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if currentGestureSlot != nil {
                            Divider()
                            Button("Clear Gesture") { clearGestureMapping() }
                        }
                    } label: {
                        Image(systemName: currentGestureSlot != nil ? (currentGestureSlot!.hand.icon) : "hand.point.up.left.fill")
                            .font(.caption)
                            .foregroundStyle(currentGestureSlot != nil ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .frame(width: 20)
                    }
                    .help(currentGestureSlot.map { "\($0.hand.displayName) \($0.finger.displayName)" } ?? "Assign hand gesture")
                }

                // Assign to music reactive
                if let musicTarget = musicReactiveTarget {
                    Button {
                        toggleMusicMapping(musicTarget)
                    } label: {
                        Image(systemName: hasMusicMapping(musicTarget) ? "waveform.circle.fill" : "waveform.circle")
                            .font(.caption)
                            .foregroundStyle(hasMusicMapping(musicTarget) ? AnyShapeStyle(.pink) : AnyShapeStyle(.tertiary))
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(hasMusicMapping(musicTarget) ? "Remove music reactivity" : "Assign to music")
                }

                // Flip to sensitivity
                if supportsGestureShortcuts {
                    Button {
                        isFlipped = true
                    } label: {
                        Image(systemName: sensitivityIsCustom ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.50percent")
                            .font(.caption)
                            .foregroundStyle(sensitivityIsCustom ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary.opacity(0.6)))
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(sensitivityIsCustom ? "Sensitivity: \(String(format: "%.1fx", sensitivityValue))" : "Adjust gesture sensitivity")
                }
            }
        }
    }

    // MARK: - Back Face (Gesture Sensitivity + Music Shortcuts)

    @ViewBuilder
    private func backFace(floatNode: FloatParameterNode) -> some View {
        VStack(spacing: 4) {
            // ── Row 1: Gesture sensitivity ──
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 16)

                Text("Sensitivity")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 66, alignment: .leading)
                    .lineLimit(1)

                  Slider(value: sensitivitySliderPosition,
                      in: 0...1)
                    .tint(.orange)
                    .onChange(of: sensitivityValue) { _, newVal in
                        GestureSensitivityStore.shared.setSensitivity(newVal, for: floatNode.id)
                    }

                Text(String(format: "%.1fx", sensitivityValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32)

                Button {
                    sensitivityValue = GestureSensitivityStore.defaultSensitivity
                    GestureSensitivityStore.shared.resetSensitivity(for: floatNode.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)

                Button {
                    isFlipped = false
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
            }

            // ── Row 2+: Music shortcuts (when enabled and param has a music target) ──
            if cache.display.showMusicShortcuts, let target = musicReactiveTarget {
                let mappingIndex = musicMappingIndex(for: target)

                Divider()

                // Source picker
                HStack(spacing: 4) {
                    Image(systemName: "waveform.circle")
                        .font(.caption)
                        .foregroundStyle(.pink)
                        .frame(width: 16)

                    if let idx = mappingIndex, idx < cache.audioReactive.musicReactiveMappings.count {
                        Picker("", selection: Binding(
                            get: { idx < cache.audioReactive.musicReactiveMappings.count ? cache.audioReactive.musicReactiveMappings[idx].source : .composite },
                            set: { src in updateMusicMapping(target) { $0.source = src } }
                        )) {
                            ForEach(MusicReactiveSource.allCases, id: \.self) { s in
                                Text(s.displayName).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                    } else {
                        Text("Not mapped")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Add") { toggleMusicMapping(target) }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(.pink)
                    }
                }

                if mappingIndex != nil {
                    // Response curve
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .frame(width: 16)
                        Picker("", selection: Binding(
                            get: {
                                guard let idx = musicMappingIndex(for: target),
                                      idx < cache.audioReactive.musicReactiveMappings.count else { return ResponseCurve.sinusoidal }
                                return cache.audioReactive.musicReactiveMappings[idx].responseCurve
                            },
                            set: { curve in updateMusicMapping(target) { $0.responseCurve = curve } }
                        )) {
                            ForEach(ResponseCurve.allCases, id: \.self) { c in
                                Image(systemName: c.icon).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                    }

                    // Intensity
                    HStack(spacing: 4) {
                        Text("Intensity")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .frame(width: 52, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { musicMappingValue(for: target, \.amount) ?? 1.0 },
                                set: { v in updateMusicMapping(target) { $0.amount = v; $0.sanitizeInPlace() } }
                            ),
                            in: 0...3
                        )
                        .tint(.pink)
                        Text(String(format: "%.1f", musicMappingValue(for: target, \.amount) ?? 1.0))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                    }

                    // Smooth
                    HStack(spacing: 4) {
                        Text("Smooth")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .frame(width: 52, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { musicMappingValue(for: target, \.smoothingWindow) ?? 0.0 },
                                set: { v in updateMusicMapping(target) { $0.smoothingWindow = v; $0.sanitizeInPlace() } }
                            ),
                            in: 0...2
                        )
                        .tint(.pink)
                        Text(String(format: "%.1f", musicMappingValue(for: target, \.smoothingWindow) ?? 0.0))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.06))
        )
    }

    // MARK: - Music Mapping Inline Helpers

    private func musicMappingIndex(for target: MusicReactiveTarget) -> Int? {
        cache.audioReactive.musicReactiveMappings.firstIndex(where: { $0.target == target })
    }

    private func musicMappingValue(for target: MusicReactiveTarget, _ keyPath: KeyPath<MusicReactiveMapping, Float>) -> Float? {
        guard let idx = musicMappingIndex(for: target) else { return nil }
        return cache.audioReactive.musicReactiveMappings[idx][keyPath: keyPath]
    }

    private func updateMusicMapping(_ target: MusicReactiveTarget, _ mutate: (inout MusicReactiveMapping) -> Void) {
        var mappings = cache.audioReactive.musicReactiveMappings
        if let idx = mappings.firstIndex(where: { $0.target == target }) {
            mutate(&mappings[idx])
            cache.audioReactive.musicReactiveMappings = mappings
            cache.push(\.musicReactiveMappings, value: mappings)
        }
    }

    // MARK: - Helpers

    private var sensitivityIsCustom: Bool {
        abs(GestureSensitivityStore.shared.sensitivity(for: node.id)
            - GestureSensitivityStore.defaultSensitivity) > 0.01
    }

    private var floatGestureBinding: GestureActionBinding? {
        guard let floatNode = node as? FloatParameterNode else { return nil }
        let pieces = floatNode.id.split(separator: ".")
        guard pieces.count >= 3, let index = Int(pieces[2]) else { return nil }
        return .parameter(GestureBindableParameter(
            fractalType: cache.fractalType,
            parameterNodeID: floatNode.id,
            formulaIndex: index,
            display: GestureDisplayMetadata(title: floatNode.name, subtitle: floatNode.group?.title, icon: floatNode.icon)
        ))
    }

    private var currentGestureSlot: GestureSlot? {
        guard let binding = floatGestureBinding else { return nil }
        return cache.gestureSlot(for: binding)
    }

    private func clearGestureMapping() {
        guard let slot = currentGestureSlot else { return }
        cache.setGestureBinding(.core(.none), for: slot)
    }

    // MARK: - Music Reactive Helpers

    private var musicReactiveTarget: MusicReactiveTarget? {
        guard let floatNode = node as? FloatParameterNode else { return nil }
        let pieces = floatNode.id.split(separator: ".")
        guard pieces.count >= 3, let formulaIndex = Int(pieces[2]) else { return nil }
        let floatParams = MusicReactiveTarget.floatFormulaParams(for: cache.fractalType)
        guard let slotIndex = floatParams.firstIndex(where: { $0.index == formulaIndex }) else { return nil }
        guard slotIndex < MusicReactiveTarget.allFormulaParamCases.count else { return nil }
        return MusicReactiveTarget.allFormulaParamCases[slotIndex]
    }

    private func hasMusicMapping(_ target: MusicReactiveTarget) -> Bool {
        cache.audioReactive.musicReactiveMappings.contains { $0.target == target && $0.isEnabled }
    }

    private func toggleMusicMapping(_ target: MusicReactiveTarget) {
        var mappings = cache.audioReactive.musicReactiveMappings
        if let idx = mappings.firstIndex(where: { $0.target == target }) {
            mappings.remove(at: idx)
        } else {
            mappings.append(target.defaultMapping(for: cache.fractalType, enabled: true))
        }
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }
}

// MARK: - Power Quick Picker (Mandelbulb)

/// Segmented control for quickly selecting common Mandelbulb integer power values.
private struct PowerQuickPicker: View {
    @Bindable var cache: UISettingsCache
    let node: AnyParameterNodeBase

    private static let presets: [(label: String, value: Float)] = [
        ("2", 2), ("3", 3), ("4", 4), ("5", 5),
        ("6", 6), ("8", 8), ("10", 10), ("12", 12), ("16", 16)
    ]

    private var currentPower: Float {
        (node as? FloatParameterNode)?.readValue(cache) ?? 8
    }

    /// Selected index matching one of the presets, or nil if the slider is at a custom value.
    private var selectedIndex: Int? {
        Self.presets.firstIndex { abs($0.value - currentPower) < 0.25 }
    }

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 16) // align with slider icon column

            ForEach(Array(Self.presets.enumerated()), id: \.offset) { idx, preset in
                Button {
                    applyPower(preset.value)
                } label: {
                    Text(preset.label)
                        .font(.caption2.weight(selectedIndex == idx ? .bold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selectedIndex == idx ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        )
                        .foregroundStyle(selectedIndex == idx ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
        .frame(height: 26)
    }

    private func applyPower(_ value: Float) {
        guard let floatNode = node as? FloatParameterNode else { return }
        // Write directly to cache so the slider binding refreshes immediately
        floatNode.writeValue(cache, value)
        // Also dispatch through the parameter operation system for render settings
        let frameIndex = UInt64(Date().timeIntervalSince1970 * 1000)
        cache.dispatchParameterOperation(
            ParameterOperation(
                targetID: floatNode.id,
                source: .slider,
                value: .absolute(value),
                frameIndex: frameIndex
            )
        )
    }
}

// MARK: - Multi-Axis Gesture Assignment

private struct TripletRow: View {
    @Bindable var cache: UISettingsCache
    let triplet: GestureBindableTriplet

    private var binding: GestureActionBinding { .parameterTriplet(triplet) }

    private var currentSlot: GestureSlot? {
        cache.gestureSlot(for: binding)
    }

    private var hasTripletMusicMapping: Bool {
        let floatParams = MusicReactiveTarget.floatFormulaParams(for: cache.fractalType)
        let indices = [triplet.xFormulaIndex, triplet.yFormulaIndex, triplet.zFormulaIndex]
        for formulaIndex in indices {
            guard let slotIndex = floatParams.firstIndex(where: { $0.index == formulaIndex }) else { continue }
            let target: MusicReactiveTarget?
            switch slotIndex {
            case 0: target = .formulaParam0
            case 1: target = .formulaParam1
            case 2: target = .formulaParam2
            case 3: target = .formulaParam3
            default: target = nil
            }
            if let t = target, cache.audioReactive.musicReactiveMappings.contains(where: { $0.target == t && $0.isEnabled }) {
                return true
            }
        }
        return false
    }

    private var tripletGain: Float {
        cache.audioReactive.tripletMusicGains[triplet.groupName] ?? 1.0
    }

    private func setTripletGain(_ value: Float) {
        cache.audioReactive.tripletMusicGains[triplet.groupName] = value
        cache.push(\.tripletMusicGains, value: cache.audioReactive.tripletMusicGains)
    }

    private var supportsGestureShortcuts: Bool {
#if os(visionOS)
        true
#else
        false
#endif
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "move.3d")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .frame(width: 16)

                Text(triplet.display.title)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                if supportsGestureShortcuts {
                    Menu {
                        ForEach([GestureHandMode.left, .right], id: \.self) { hand in
                            Menu(hand.displayName) {
                                ForEach(FingerDigit.allCases, id: \.self) { finger in
                                    let slot = GestureSlot(hand: hand, finger: finger)
                                    let isCurrent = currentSlot == slot
                                    Button {
                                        cache.setGestureBinding(binding, for: slot)
                                    } label: {
                                        HStack {
                                            Label(finger.displayName, systemImage: finger.icon)
                                            if isCurrent { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            }
                        }
                        if currentSlot != nil {
                            Divider()
                            Button("Clear") {
                                if let slot = currentSlot {
                                    cache.setGestureBinding(.core(.none), for: slot)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let slot = currentSlot {
                                Image(systemName: slot.hand.icon)
                                Text("\(slot.hand.displayName) \(slot.finger.displayName)")
                            } else {
                                Text("Not Assigned")
                            }
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(currentSlot != nil ? .green : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(currentSlot != nil ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08))
                        )
                    }
                }
            }

            if hasTripletMusicMapping {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                        .frame(width: 16)
                    Text("Gain")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                        .frame(width: 32, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { tripletGain },
                            set: { setTripletGain($0) }
                        ),
                        in: 0...2
                    )
                    .tint(.pink)
                    Text(String(format: "%.2f", tripletGain))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                }
                .padding(.leading, 16)
            }
        }
    }
}
