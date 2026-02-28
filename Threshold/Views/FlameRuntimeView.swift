import SwiftUI

struct FlameRuntimeView: View {
    @Environment(AppModel.self) private var appModel
    @StateObject private var realtimeController = FlameRealtimeController()
    @State private var realtime3DEnabled = true
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Flame Runtime", systemImage: "flame.fill")
                    .font(.headline)
                Spacer()
                Toggle("Realtime 3D", isOn: $realtime3DEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Realtime 3D")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    appModel.runtimeViewMode = .raymarch
                } label: {
                    Label("Back To Raymarch", systemImage: "cube")
                }
                .buttonStyle(.bordered)
            }

            if realtime3DEnabled {
                VStack(spacing: 8) {
                    Picker("Quality", selection: $realtimeController.quality) {
                        ForEach(FlameRealtimeController.Quality.allCases) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Toggle("Auto Orbit", isOn: $realtimeController.autoOrbit)
                            .toggleStyle(.switch)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Orbit Speed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $realtimeController.orbitSpeed, in: 0.15...2.2)
                                .frame(maxWidth: 180)
                        }
                        Button("Reset Camera") {
                            realtimeController.resetCamera()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if realtime3DEnabled, let image = realtimeController.frameImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let dx = Float(value.translation.width - lastDragTranslation.width) * 0.0045
                                let dy = Float(value.translation.height - lastDragTranslation.height) * -0.0045
                                lastDragTranslation = value.translation
                                realtimeController.applyOrbitDrag(deltaX: dx, deltaY: dy)
                            }
                            .onEnded { _ in
                                lastDragTranslation = .zero
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                let delta = Float(scale / lastMagnification)
                                lastMagnification = scale
                                realtimeController.applyPinchScale(delta)
                            }
                            .onEnded { _ in
                                lastMagnification = 1.0
                            }
                    )
            } else if let image = appModel.importedFlamePreviewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Flame Loaded")
                        .font(.headline)
                    Text("Open Fractal Browser → Flame family → Import .flam3 to load and render a flame.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let flame = appModel.importedFlame {
                Text("Loaded: \(flame.name) • \(flame.transforms.count) transforms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !appModel.importedFlameStatusText.isEmpty {
                Text(appModel.importedFlameStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if realtime3DEnabled && !realtimeController.statusText.isEmpty {
                Text(realtimeController.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if realtime3DEnabled {
                Text("Drag to orbit • Pinch to adjust depth/perspective")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let err = appModel.importedFlameErrorText {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if realtime3DEnabled {
                realtimeController.start { appModel.importedFlame }
            }
        }
        .onDisappear {
            realtimeController.stop()
        }
        .onChange(of: realtime3DEnabled) { _, enabled in
            if enabled {
                realtimeController.start { appModel.importedFlame }
            } else {
                realtimeController.stop()
            }
        }
        .onChange(of: appModel.importedFlame?.name) { _, _ in
            if realtime3DEnabled {
                realtimeController.restart { appModel.importedFlame }
            }
        }
        .onChange(of: realtimeController.quality) { _, _ in
            if realtime3DEnabled {
                realtimeController.restart { appModel.importedFlame }
            }
        }
    }
}
