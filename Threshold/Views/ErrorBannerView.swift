//
//  ErrorBannerView.swift
//  Threshold
//
//  Transient error banner overlay.
//  Observes ErrorReporter.currentError and displays a dismissible banner.
//  Critical errors persist until dismissed; others auto-dismiss.
//

import SwiftUI

struct ErrorBannerView: View {
    var errorReporter: ErrorReporter

    var body: some View {
        if let error = errorReporter.currentError {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: error.severity))
                    .foregroundStyle(iconColor(for: error.severity))

                Text(error.userMessage)
                    .font(.callout)
                    .lineLimit(2)

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        errorReporter.dismiss()
                    }
                } label: {
                    Image(systemName: AppIcons.xmarkCircleFill)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderColor(for: error.severity).opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Helpers

    private func iconName(for severity: ThresholdError.Severity) -> String {
        switch severity {
        case .info:     return "info.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func iconColor(for severity: ThresholdError.Severity) -> Color {
        switch severity {
        case .info:     return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private func borderColor(for severity: ThresholdError.Severity) -> Color {
        switch severity {
        case .info:     return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}
