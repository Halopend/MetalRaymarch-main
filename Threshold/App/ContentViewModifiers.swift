//
//  ContentViewModifiers.swift
//  MetalProject
//
//  Platform-gated SwiftUI helpers shared by ContentView and its extracted
//  component views. Extracted from ContentView.swift during the Phase 3
//  architecture refactor.
//

import SwiftUI

extension View {
    @ViewBuilder
    func thresholdGlassBackground(cornerRadius: CGFloat) -> some View {
#if os(visionOS)
        glassBackgroundEffect(in: .rect(cornerRadius: cornerRadius))
#else
        self
#endif
    }

    @ViewBuilder
    func thresholdTopDockOrnament<Content: View>(
        isVisible: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
#if os(visionOS)
        ornament(
            visibility: isVisible ? .visible : .hidden,
            attachmentAnchor: .scene(.top),
            contentAlignment: .bottom,
            ornament: content
        )
#else
        self
#endif
    }

    @ViewBuilder
    func thresholdHoverEffect() -> some View {
#if os(visionOS)
        hoverEffect()
#else
        self
#endif
    }
}
