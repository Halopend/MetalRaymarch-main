import SwiftUI

/// Shared rules for the small, user-authored labels attached to scenes.
/// Tags are deliberately plain strings so exported files stay portable and
/// older builds can safely ignore them.
enum SceneTagging {
    static let maximumTagCount = 12
    static let maximumTagLength = 28

    static func normalized(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            guard let cleaned = normalized(tag),
                  !result.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else {
                continue
            }
            result.append(cleaned)
            if result.count == maximumTagCount { break }
        }
        return result
    }

    static func normalized(_ tag: String) -> String? {
        let cleaned = tag
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= maximumTagLength else { return nil }
        return cleaned
    }

    static func contains(_ tags: [String], tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

struct SceneTagPill: View {
    let tag: String
    var isSelected = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    label
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(tag)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            if onRemove != nil {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.14),
                lineWidth: 1
            )
        )
    }
}

struct SceneTagRow: View {
    let tags: [String]

    var body: some View {
        if !SceneTagging.normalized(tags).isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(SceneTagging.normalized(tags), id: \.self) { tag in
                        SceneTagPill(tag: tag)
                    }
                }
            }
        }
    }
}

struct SceneTagEditor: View {
    @Binding var tags: [String]
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add a tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)

                Button(action: addTag) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(SceneTagging.normalized(newTag) == nil)
                .accessibilityLabel("Add tag")
            }

            if SceneTagging.normalized(tags).isEmpty {
                Text("Use tags like \"favorites\", \"cavern\", or \"live\" to make your own collections.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(SceneTagging.normalized(tags), id: \.self) { tag in
                            SceneTagPill(tag: tag) {
                                tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            tags = SceneTagging.normalized(tags)
        }
    }

    private func addTag() {
        guard let tag = SceneTagging.normalized(newTag),
              !SceneTagging.contains(tags, tag: tag),
              tags.count < SceneTagging.maximumTagCount else { return }
        tags = SceneTagging.normalized(tags + [tag])
        newTag = ""
    }
}
