import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// Native image encoding kept out of reusable SwiftUI controls.
enum PlatformImageEncodingAdapter {
    @MainActor
    static func pngData<Content: View>(for content: Content, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        #if os(macOS)
        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return renderer.uiImage?.pngData()
        #endif
    }
}

/// Platform accessibility announcement seam used by shared views.
enum PlatformAccessibilityAdapter {
    @MainActor
    static func announce(_ message: String, urgent: Bool = false) {
        #if os(macOS)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: (urgent
                    ? NSAccessibilityPriorityLevel.high
                    : NSAccessibilityPriorityLevel.medium).rawValue,
            ]
        )
        #else
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

/// Finder behavior is native; shared views fall back to their SwiftUI share sheet.
enum PlatformFilePresentationAdapter {
    @MainActor
    static func revealIfSupported(_ url: URL) -> Bool {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
        #else
        return false
        #endif
    }
}

private struct SystemColorPanelOwnershipModifier: ViewModifier {
    let begin: () -> Void
    let end: () -> Void
    #if os(macOS)
    @State private var isHolding = false
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard note.object is NSColorPanel, !isHolding else { return }
                isHolding = true
                begin()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                guard note.object is NSColorPanel, isHolding else { return }
                isHolding = false
                end()
            }
            .onDisappear {
                guard isHolding else { return }
                isHolding = false
                end()
            }
        #else
        content
        #endif
    }
}

extension View {
    /// Keeps a transient control surface alive while AppKit's shared color panel
    /// owns keyboard/pointer focus. It is intentionally a no-op elsewhere.
    func retainsMenuDuringSystemColorPanel(
        begin: @escaping () -> Void,
        end: @escaping () -> Void
    ) -> some View {
        modifier(SystemColorPanelOwnershipModifier(begin: begin, end: end))
    }
}
