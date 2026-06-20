//
//  PresetViews.swift
//  MetalProject
//
//  Created on January 11, 2026.
//

import SwiftUI

// MARK: - Sharing helper
#if os(iOS) || os(visionOS)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
struct ShareSheet: NSViewControllerRepresentable {
    let activityItems: [Any]
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        let picker = NSSharingServicePicker(items: activityItems)
        picker.delegate = context.coordinator
        // Delay presentation to next run loop iteration so the view is laid out.
        // Already on MainActor via NSViewControllerRepresentable.
        Task { @MainActor in
            picker.show(relativeTo: .zero, of: controller.view, preferredEdge: .minY)
        }
        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}

    final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }

        @MainActor func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            dismiss()
        }
    }
}
#endif
