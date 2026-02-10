//
//  GradientEditorView.swift
//  MetalRaymarch
//
//  SwiftUI gradient editor for the new gradient coloring system.
//  Provides preset selection, custom stop editing, mapping mode picker,
//  and real-time gradient preview.
//

import SwiftUI

// MARK: - Gradient Editor Section (embeds in Color & Effects DisclosureGroup)

struct GradientEditorSection: View {
    @Binding var cache: UISettingsCache
    
    @State private var showingStopEditor = false
    @State private var editingStopIndex: Int? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toggle between legacy and gradient mode
            Toggle("Gradient Coloring", isOn: $cache.useGradientColoring)
                .onChange(of: cache.useGradientColoring) { _, newValue in
                    cache.pushGradientEnabled(newValue)
                }
            
            if cache.useGradientColoring {
                // Gradient preview bar
                GradientPreviewBar(gradient: cache.gradientColorMap)
                    .frame(height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                // Preset picker
                Text("Presets").font(.subheadline).foregroundColor(.secondary)
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 6) {
                    ForEach(GradientPreset.allCases, id: \.rawValue) { preset in
                        Button {
                            cache.applyGradientPreset(preset)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: preset.icon)
                                    .font(.caption)
                                Text(preset.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(cache.gradientPreset == preset ? .blue : .secondary)
                    }
                }
                
                Divider()
                
                // Mapping mode
                HStack {
                    Text("Mapping")
                    Spacer()
                    Picker("Mapping", selection: $cache.colorMappingMode) {
                        ForEach(ColorMappingMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 140)
                    .onChange(of: cache.colorMappingMode) { _, newValue in
                        cache.push(\.colorMappingMode, value: newValue)
                    }
                }
                
                // Repeat
                HStack {
                    Text("Repeat: \(cache.gradientRepeat, specifier: "%.1f")x")
                    Spacer()
                }
                Slider(value: $cache.gradientRepeat, in: 0.1...5.0, onEditingChanged: { editing in
                    if !editing { cache.push(\.gradientRepeat, value: cache.gradientRepeat) }
                })
                
                // Offset
                HStack {
                    Text("Offset: \(cache.gradientOffset, specifier: "%.2f")")
                    Spacer()
                }
                Slider(value: $cache.gradientOffset, in: 0...1, onEditingChanged: { editing in
                    if !editing { cache.push(\.gradientOffset, value: cache.gradientOffset) }
                })
                
                // Smoothing
                HStack {
                    Text("Smoothing: \(cache.gradientSmoothing, specifier: "%.2f")")
                    Spacer()
                }
                Slider(value: $cache.gradientSmoothing, in: 0...1, onEditingChanged: { editing in
                    if !editing { cache.push(\.gradientSmoothing, value: cache.gradientSmoothing) }
                })
                
                Divider()
                
                // Color stops editor
                HStack {
                    Text("Color Stops").font(.subheadline)
                    Spacer()
                    Button {
                        addStop()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                    }
                    .disabled(cache.gradientColorMap.stops.count >= 8)
                }
                
                ForEach(Array(cache.gradientColorMap.stops.enumerated()), id: \.element.id) { index, stop in
                    GradientStopRow(
                        stop: stop,
                        index: index,
                        onUpdate: { updatedStop in
                            updateStop(at: index, with: updatedStop)
                        },
                        onDelete: {
                            deleteStop(at: index)
                        },
                        canDelete: cache.gradientColorMap.stops.count > 2
                    )
                }
            }
        }
    }
    
    private func addStop() {
        var map = cache.gradientColorMap
        // Add at midpoint of existing range
        let newPos: Float = 0.5
        let newStop = GradientStop(position: newPos, r: 1.0, g: 1.0, b: 1.0)
        map.stops.append(newStop)
        map.sortStops()
        cache.gradientColorMap = map
        cache.pushGradientMap(map)
    }
    
    private func updateStop(at index: Int, with stop: GradientStop) {
        var map = cache.gradientColorMap
        guard index < map.stops.count else { return }
        map.stops[index] = stop
        map.sortStops()
        cache.gradientColorMap = map
        cache.pushGradientMap(map)
    }
    
    private func deleteStop(at index: Int) {
        var map = cache.gradientColorMap
        guard map.stops.count > 2, index < map.stops.count else { return }
        map.stops.remove(at: index)
        cache.gradientColorMap = map
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
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Gradient Preview Bar

struct GradientPreviewBar: View {
    let gradient: GradientColorMap
    
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let width = Int(size.width)
                guard width > 0 else { return }
                
                for x in 0..<width {
                    let t = Float(x) / Float(width - 1)
                    let color = gradient.evaluate(at: t)
                    
                    let rect = CGRect(x: CGFloat(x), y: 0, width: 1, height: size.height)
                    context.fill(
                        Path(rect),
                        with: .color(Color(
                            red: Double(color.x),
                            green: Double(color.y),
                            blue: Double(color.z)
                        ))
                    )
                }
            }
        }
    }
}
