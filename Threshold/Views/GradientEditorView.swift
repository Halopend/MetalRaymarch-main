//
//  GradientEditorView.swift
//  Threshold
//
//  SwiftUI gradient editor for the new gradient coloring system.
//  Provides preset selection, custom stop editing, mapping mode picker,
//  and real-time gradient preview.
//

import SwiftUI

// MARK: - Gradient Stops Popover

/// Popover shown when the gradient bar is tapped, allowing editing of individual color stops.
struct GradientStopsPopover: View {
    @Binding var cache: UISettingsCache
    
    @State private var gradientName: String = ""
    @State private var showSavedConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Header ──
            HStack {
                Text("Gradient Editor")
                    .font(.headline)
                Spacer()
                Button {
                    saveGradient()
                } label: {
                    Label("Save", systemImage: AppIcons.squareAndArrowDown)
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(gradientName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            
            // ── Name field ──
            HStack(spacing: 8) {
                Image(systemName: AppIcons.characterCursorIbeam)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Gradient name", text: $gradientName)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
            }
            
            // ── Gradient live preview ──
            GradientPreviewBar(gradient: cache.color.gradientState.gradient)
                .frame(height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            
            Divider()
            
            // ── Color Stops header ──
            HStack {
                Text("Color Stops")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(cache.color.gradientState.gradient.stops.count)/8")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // ── Stop rows ──
            ForEach(Array(cache.color.gradientState.gradient.stops.enumerated()), id: \.element.id) { index, stop in
                GradientStopRow(
                    stop: stop,
                    index: index,
                    onUpdate: { updatedStop in
                        updateStop(at: index, with: updatedStop)
                    },
                    onDelete: {
                        deleteStop(at: index)
                    },
                    canDelete: cache.color.gradientState.gradient.stops.count > 2
                )
            }
            
            // ── Add Color button ──
            Button {
                addStop()
            } label: {
                HStack {
                    Image(systemName: AppIcons.plusCircleFill)
                    Text("Add Color Stop")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(cache.color.gradientState.gradient.stops.count >= 8)
            
            // ── Saved confirmation ──
            if showSavedConfirmation {
                HStack(spacing: 6) {
                    Image(systemName: AppIcons.checkmarkCircleFill)
                        .foregroundStyle(.green)
                    Text("Saved!")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }
        }
        .padding(16)
        .frame(minWidth: 320, idealWidth: 370)
        .onAppear {
            gradientName = cache.color.gradientState.gradient.name
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showSavedConfirmation)
    }
    
    private func saveGradient() {
        let trimmed = gradientName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        // Update the live gradient name first
        var map = cache.color.gradientState.gradient
        map = GradientColorMap(name: trimmed, stops: map.stops,
                                mappingMode: map.mappingMode, repeatCount: map.repeatCount,
                                offset: map.offset, smoothing: map.smoothing)
        cache.color.gradientState.gradient = map
        cache.pushGradientMap(map)
        
        // Save to custom list
        cache.gradientLibrary.savedCustomGradients.append(map)
        cache.gradientLibrary.persist()
        
        showSavedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { showSavedConfirmation = false }
        }
    }
    
    private func addStop() {
        var map = cache.color.gradientState.gradient
        // Place new stop at the midpoint of the largest gap
        let newPos = findLargestGap(in: map.stops)
        let color = map.evaluate(at: newPos)  // Sample existing gradient for a sensible default
        let newStop = GradientStop(position: newPos, color: color)
        map.stops.append(newStop)
        map.sortStops()
        cache.color.gradientState.gradient = map
        cache.pushGradientMap(map)
    }
    
    /// Find the midpoint of the largest gap between stops
    private func findLargestGap(in stops: [GradientStop]) -> Float {
        guard stops.count >= 2 else { return 0.5 }
        let sorted = stops.sorted { $0.position < $1.position }
        var bestGap: Float = 0
        var bestMid: Float = 0.5
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1].position - sorted[i].position
            if gap > bestGap {
                bestGap = gap
                bestMid = (sorted[i].position + sorted[i + 1].position) / 2.0
            }
        }
        // Also check edges (0 to first, last to 1)
        if sorted[0].position > bestGap {
            bestGap = sorted[0].position
            bestMid = sorted[0].position / 2.0
        }
        if (1.0 - sorted[sorted.count - 1].position) > bestGap {
            bestMid = (sorted[sorted.count - 1].position + 1.0) / 2.0
        }
        return bestMid
    }
    
    private func updateStop(at index: Int, with stop: GradientStop) {
        var map = cache.color.gradientState.gradient
        guard index < map.stops.count else { return }
        map.stops[index] = stop
        map.sortStops()
        cache.color.gradientState.gradient = map
        cache.pushGradientMap(map)
    }
    
    private func deleteStop(at index: Int) {
        var map = cache.color.gradientState.gradient
        guard map.stops.count > 2, index < map.stops.count else { return }
        map.stops.remove(at: index)
        cache.color.gradientState.gradient = map
        cache.pushGradientMap(map)
    }
}

// MARK: - Gradient Stop Row

struct GradientStopRow: View {
    let stop: GradientStop
    let index: Int
    let onUpdate: (GradientStop) -> Void
    let onDelete: () -> Void
    let canDelete: Bool
    
    @State private var localPosition: Float
    @State private var localColor: Color
    
    init(stop: GradientStop, index: Int, onUpdate: @escaping (GradientStop) -> Void,
         onDelete: @escaping () -> Void, canDelete: Bool) {
        self.stop = stop
        self.index = index
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.canDelete = canDelete
        self._localPosition = State(initialValue: stop.position)
        self._localColor = State(initialValue: Color(
            red: Double(stop.color.x),
            green: Double(stop.color.y),
            blue: Double(stop.color.z)
        ))
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Color swatch
            ColorPicker("", selection: $localColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .onChange(of: localColor) { _, newColor in
                    if let components = newColor.cgColor?.components, components.count >= 3 {
                        var updated = stop
                        updated.color = SIMD3<Float>(Float(components[0]), Float(components[1]), Float(components[2]))
                        onUpdate(updated)
                    }
                }
            
            // Position slider
            Text("\(localPosition, specifier: "%.2f")")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 35)
            
            Slider(value: $localPosition, in: 0...1, onEditingChanged: { editing in
                if !editing {
                    var updated = stop
                    updated.position = localPosition
                    onUpdate(updated)
                }
            })
            
            // Delete button
            if canDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: AppIcons.xmarkCircleFill)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove color stop \(index + 1)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Color stop \(index + 1)")
        .accessibilityValue("Position \(String(format: "%.0f", localPosition * 100)) percent")
    }
}

// MARK: - Gradient Preview Bar

struct GradientPreviewBar: View {
    let gradient: GradientColorMap
    @State private var renderedImage: CGImage?
    private static let renderWidth = 256

    var body: some View {
        GeometryReader { geo in
            if let image = renderedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear { renderedImage = Self.renderGradient(gradient) }
        .onChange(of: gradient) { _, newGradient in renderedImage = Self.renderGradient(newGradient) }
        .accessibilityLabel("Gradient preview: \(gradient.name)")
        .accessibilityAddTraits(.isImage)
    }

    private static func renderGradient(_ gradient: GradientColorMap) -> CGImage? {
        let w = renderWidth
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: 1,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let buffer = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for x in 0..<w {
            let t = Float(x) / Float(w - 1)
            let c = gradient.evaluate(at: t)
            buffer[x * 4 + 0] = UInt8(clamping: Int(c.x * 255))
            buffer[x * 4 + 1] = UInt8(clamping: Int(c.y * 255))
            buffer[x * 4 + 2] = UInt8(clamping: Int(c.z * 255))
            buffer[x * 4 + 3] = 255
        }
        return ctx.makeImage()
    }
}
