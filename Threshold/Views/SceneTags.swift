import SwiftUI

/// Cross-platform visibility gate for Vision Pro Mixed-reality scenes.
///
/// Scenes marked `mixedModeScene` (the "Open in Mixed Immersion" opt-in, and
/// every bundled Mixed example) are authored for Mixed immersion: on Vision Pro
/// the fractal composites over the room passthrough. Classification travels
/// inside the file — the bundled loader no longer infers it from a folder name.
/// On flat-display hosts (macOS, iPadOS) there is no passthrough context, so
/// those scenes are hidden from every scene catalog and browse surface unless
/// the user explicitly enables them in Settings → Display. visionOS always
/// includes them — Mixed scenes belong there.
///
/// Mirrors the reserved-tag rules in `SceneTagging`, keyed off the
/// `mixedModeScene` field rather than a tag. The value is read live from
/// `UserDefaults` so catalog computations and navigation projections stay
/// current after the settings toggle flips.
enum MixedRealitySceneCatalogSettings {
    /// `@AppStorage`/UserDefaults key backing the Settings → Display toggle.
    static let defaultsKey = "SceneCatalog.includesMixedRealityScenes"

    /// Whether this host's catalogs include Mixed-reality scenes. Always
    /// `true` on visionOS; every other platform requires the explicit opt-in.
    static var includesScenes: Bool {
        #if os(visionOS)
        true
        #else
        UserDefaults.standard.bool(forKey: defaultsKey)
        #endif
    }
}

/// Shared rules for the small, user-authored labels attached to scenes.
/// Tags are deliberately plain strings so exported files stay portable and
/// older builds can safely ignore them.
enum SceneTagging {
    static let maximumTagCount = 12
    static let maximumTagLength = 28
    /// A reserved, portable tag for scenes designed for a flat display rather
    /// than an immersive view surrounding the viewer. This is now a *legacy wire
    /// encoding* of `PlatformVisibility.flat`: the model strips it on decode and
    /// re-emits it on encode for one release so older builds keep working.
    static let screenOnlyTag = PlatformVisibility.flatLegacyTag
    /// Legacy wire encoding of `PlatformVisibility.mac`.
    static let macOnlyTag = PlatformVisibility.macLegacyTag

    /// True for a tag that only ever encoded platform visibility. The tag UI
    /// hides these now that `platformVisibility` is authoritative.
    static func isReserved(_ tag: String) -> Bool {
        PlatformVisibility.isReservedTag(tag)
    }

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

/// Platform gate editor. Binds `platformVisibility` rather than overloading the
/// user's tag list with a reserved tag.
struct ScreenOnlySceneToggle: View {
    @Binding var visibility: PlatformVisibility?

    var body: some View {
        Toggle("Screen only", isOn: Binding(
            get: {
                switch PlatformVisibility.resolved(visibility) {
                case .flat, .mac: return true
                case .all: return false
                }
            },
            set: { isOn in
                // Off clears both gates; on selects the flat-display gate.
                // Mac-only is an authoring classification set in the file.
                visibility = isOn ? .flat : nil
            }
        ))
        .help("Best viewed on a screen; hide this scene from the Vision Pro library.")
        .accessibilityHint("When enabled, this scene is excluded from Vision Pro because it is intended for a flat display.")
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
        let userTags = SceneTagging.normalized(tags).filter { !SceneTagging.isReserved($0) }
        if !userTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(userTags, id: \.self) { tag in
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
        let userTags = SceneTagging.normalized(tags).filter { !SceneTagging.isReserved($0) }
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

            if userTags.isEmpty {
                Text("Use tags like \"favorites\", \"cavern\", or \"live\" to make your own collections.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(userTags, id: \.self) { tag in
                            SceneTagPill(tag: tag) {
                                tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // Reserved visibility tags are a legacy encoding of the platform
            // field and must never surface as user tags.
            tags = SceneTagging.normalized(tags).filter { !SceneTagging.isReserved($0) }
        }
    }

    private func addTag() {
        guard let tag = SceneTagging.normalized(newTag),
              !SceneTagging.isReserved(tag),
              !SceneTagging.contains(tags, tag: tag),
              tags.count < SceneTagging.maximumTagCount else { return }
        tags = SceneTagging.normalized(tags + [tag])
        newTag = ""
    }
}

/// Marks a scene that carries its own embedded effect definition rather than
/// referencing a reusable library `.threshfx`. See CONTENT_MODEL_PROPOSAL.md
/// §2.7.1 — it makes the source of the effect obvious at a glance.
struct EmbeddedEffectBadge: View {
    var body: some View {
        Image(systemName: "link")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("This scene carries its own embedded effect — not a shared library effect.")
            .accessibilityLabel("Embedded effect")
    }
}
