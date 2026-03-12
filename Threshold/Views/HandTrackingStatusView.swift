//
//  HandTrackingStatusView.swift
//  Threshold
//
//  Isolates observation of high-frequency hand tracking state (gestureStatus,
//  leftHandTracked, rightHandTracked) into a small sub-tree so that per-frame
//  updates from the render loop don't invalidate larger parent views.
//

import SwiftUI

struct HandTrackingStatusView: View {
    @Environment(AppModel.self) private var appModel

    private var statusColor: Color {
        let status = appModel.gestureStatus
        if status.hasPrefix("Active:") { return .green }
        if status.hasPrefix("Ready") { return .cyan }
        if status.contains("Suppressed") { return .yellow }
        if status.contains("disabled") || status.contains("not authorized") || status.contains("not running") || status.contains("stopped") || status.contains("failed") {
            return .red
        }
        if status.contains("No hands") { return .orange }
        return .gray
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(appModel.gestureStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if appModel.leftHandTracked || appModel.rightHandTracked {
                HStack(spacing: 4) {
                    if appModel.leftHandTracked {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if appModel.rightHandTracked {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }
}
