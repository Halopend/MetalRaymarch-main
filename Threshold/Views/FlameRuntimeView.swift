import SwiftUI

struct FlameRuntimeView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Flame Runtime", systemImage: "flame.fill")
                    .font(.headline)
                Spacer()
                Button {
                    appModel.runtimeViewMode = .raymarch
                } label: {
                    Label("Back To Raymarch", systemImage: "cube")
                }
                .buttonStyle(.bordered)
            }

            if let image = appModel.importedFlamePreviewImage {
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
            if let err = appModel.importedFlameErrorText {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
