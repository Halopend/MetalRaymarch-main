import SwiftUI

struct AnimationPlayerWindowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Animation Player")
                .font(.headline)
            Text("Legacy animation editor/player UI was removed during cleanup.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 420, minHeight: 140)
    }
}

struct AnimationEditorWindowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Animation Editor")
                .font(.headline)
            Text("Scene authoring UI has been intentionally stripped as part of legacy cleanup.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 220)
    }
}
