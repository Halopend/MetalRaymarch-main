//
//  AutoExpandingPopover.swift
//  Threshold
//
//  A generalized popover-body container that sizes itself to its content.
//
//  Drop any content inside and the container grows as that content grows — for
//  example when a DisclosureGroup expands — so newly revealed rows become fully
//  visible instead of being trapped inside a small fixed scroll area. Once the
//  content would exceed `maxHeight` it caps and scrolls, so it can never grow
//  taller than the screen.
//
//  Usage:
//      .popover(isPresented: $isShowing) {
//          AutoExpandingPopover {
//              VStack { ... }          // collapsed = short popover, expanded = tall popover
//          }
//      }
//

import SwiftUI

/// Preference used to bubble the content's natural (unclamped) height up to the
/// container so it can decide whether to grow or cap-and-scroll.
private struct AutoExpandHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A popover body that auto-sizes to its content.
///
/// - While the content fits within `maxHeight`, it is rendered at its natural
///   height (no scroll) so the popover expands and contracts with the content.
/// - When the content would exceed `maxHeight`, the container caps at `maxHeight`
///   and scrolls.
///
/// Width is fixed to `idealWidth` so rows lay out predictably; height is the
/// dimension that tracks the content.
struct AutoExpandingPopover<Content: View>: View {
    var idealWidth: CGFloat = 300
    var maxHeight: CGFloat = 460
    var contentPadding: CGFloat = 14
    /// When true, the popover always presents at `maxHeight` instead of growing with
    /// its content. This trades the compact auto-expand look for a *stable* presented
    /// size — which matters when the popover is anchored to drop *down* from a control:
    /// a mid-interaction resize (e.g. expanding a category) can push the popover's
    /// bottom past the screen edge, and AppKit responds by flipping the whole popover
    /// to point *up*. Reserving the full height up front means the popover never
    /// resizes after presentation, so AppKit picks the drop-down placement once and
    /// keeps it.
    var reservesMaxHeight: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var measuredHeight: CGFloat = 0

    private var isOverflowing: Bool { measuredHeight > maxHeight }

    var body: some View {
        Group {
            if reservesMaxHeight {
                ScrollView(.vertical, showsIndicators: true) {
                    measuredContent
                }
                .frame(height: maxHeight)
            } else if isOverflowing {
                ScrollView(.vertical, showsIndicators: true) {
                    measuredContent
                }
                .frame(height: maxHeight)
            } else {
                measuredContent
            }
        }
        .frame(width: idealWidth)
        .onPreferenceChange(AutoExpandHeightKey.self) { newHeight in
            // Ignore sub-pixel jitter so we don't thrash the layout/animation.
            if abs(newHeight - measuredHeight) > 0.5 {
                measuredHeight = newHeight
            }
        }
        // Animate only the grow/cap transition, keyed on a discrete value so the
        // measurement feedback can't drive a continuous resize loop.
        .animation(.easeInOut(duration: 0.18), value: isOverflowing)
        .animation(.easeInOut(duration: 0.18), value: measuredHeight)
    }

    /// The content, padded and measured. Rendered identically in both the scrolling
    /// and non-scrolling branches so the natural-height measurement stays stable
    /// (a ScrollView lays its content out at natural size, so the reported height is
    /// the unclamped content height in either branch).
    private var measuredContent: some View {
        content()
            .padding(contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AutoExpandHeightKey.self, value: proxy.size.height)
                }
            )
    }
}

#if DEBUG
private struct AutoExpandingPopoverPreview: View {
    @State private var showing = false
    @State private var expandA = false
    @State private var expandB = false

    var body: some View {
        Button("Show menu") { showing = true }
            .popover(isPresented: $showing) {
                AutoExpandingPopover(idealWidth: 280, maxHeight: 360) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add Control").font(.headline)
                        DisclosureGroup("Geometry", isExpanded: $expandA) {
                            ForEach(0..<3) { Text("Item \($0)") }
                        }
                        DisclosureGroup("Effects", isExpanded: $expandB) {
                            ForEach(0..<12) { Text("Effect \($0)") }
                        }
                    }
                }
            }
            .frame(width: 320, height: 200)
    }
}

#Preview("Auto-expanding popover") {
    AutoExpandingPopoverPreview()
}
#endif
