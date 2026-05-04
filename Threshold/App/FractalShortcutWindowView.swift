import SwiftUI

struct FractalShortcutWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("ContentView.skipOuterNavigationSync") private var skipOuterNavigationSync = false
    @AppStorage("ContentView.selectedTab") private var selectedTab: SidebarTab = .fractal
    @AppStorage("ContentView.fractalSubTab") private var fractalSubTab: FractalSubTab = .shape
    @AppStorage("MusicTabContent.innerTab") private var musicInnerTabRaw: String = "Music"

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ShortcutBarItem.allCases, id: \.self) { item in
                Button {
                    appModel.ensureWindowContentVisible()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        performContentOnlyNavigation {
                            switch item {
                            case .browse:
                                selectedTab = .fractal
                                fractalSubTab = .browse
                            case .shape:
                                selectedTab = .fractal
                                fractalSubTab = .shape
                            case .space:
                                selectedTab = .fractal
                                fractalSubTab = .space
                            case .render:
                                selectedTab = .fractal
                                fractalSubTab = .render
                            case .music:
                                selectedTab = .music
                                musicInnerTabRaw = "Music"
                            case .visualizations:
                                selectedTab = .music
                                musicInnerTabRaw = "Visualizations"
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .semibold))
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(foregroundFill(for: item))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(foregroundStroke(for: item), lineWidth: 1)
                    )
                    .foregroundStyle(foregroundStyle(for: item))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title) shortcut")
                .accessibilityAddTraits(isSelected(item) ? .isSelected : [])
            }
        }
        .padding(12)
        .background(windowSurfaceFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(windowSurfaceStroke, lineWidth: 1)
        )
        .glassBackgroundEffect(in: .rect(cornerRadius: 20))
        .frame(minWidth: 520, maxWidth: 640)
    }

    private func performContentOnlyNavigation(_ updates: () -> Void) {
        skipOuterNavigationSync = true
        updates()
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            skipOuterNavigationSync = false
        }
    }

    private var windowSurfaceFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.76) : Color.white.opacity(0.7)
    }

    private var windowSurfaceStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private func foregroundFill(for item: ShortcutBarItem) -> Color {
        if isSelected(item) {
            return Color.blue.opacity(colorScheme == .dark ? 0.28 : 0.18)
        }
        return Color.secondary.opacity(0.08)
    }

    private func foregroundStroke(for item: ShortcutBarItem) -> Color {
        if isSelected(item) {
            return Color.blue.opacity(0.35)
        }
        return Color.secondary.opacity(0.14)
    }

    private func foregroundStyle(for item: ShortcutBarItem) -> Color {
        isSelected(item) ? .primary : .secondary
    }

    private func isSelected(_ item: ShortcutBarItem) -> Bool {
        switch item {
        case .browse:
            return selectedTab == .fractal && fractalSubTab == .browse
        case .shape:
            return selectedTab == .fractal && fractalSubTab == .shape
        case .space:
            return selectedTab == .fractal && fractalSubTab == .space
        case .render:
            return selectedTab == .fractal && fractalSubTab == .render
        case .music:
            return selectedTab == .music && musicInnerTabRaw == "Music"
        case .visualizations:
            return selectedTab == .music && musicInnerTabRaw == "Visualizations"
        }
    }
}

private enum ShortcutBarItem: CaseIterable {
    case browse
    case shape
    case space
    case render
    case music
    case visualizations

    var title: String {
        switch self {
        case .browse:
            return "Browse"
        case .shape:
            return "Shape"
        case .space:
            return "Space"
        case .render:
            return "Render"
        case .music:
            return "Music"
        case .visualizations:
            return "Visualizations"
        }
    }

    var icon: String {
        switch self {
        case .browse:
            return "square.grid.2x2"
        case .shape:
            return "triangle"
        case .space:
            return "move.3d"
        case .render:
            return "camera.aperture"
        case .music:
            return "music.note"
        case .visualizations:
            return "waveform.path.ecg"
        }
    }
}