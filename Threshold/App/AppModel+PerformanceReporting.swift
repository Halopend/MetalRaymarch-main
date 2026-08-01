//
//  AppModel+PerformanceReporting.swift
//  Threshold
//

import Foundation

@MainActor
extension AppModel {
    func makePerformanceReport(capturedAt: Date = Date()) -> PerformanceReport {
        let metrics = renderMetrics
        let activeFormula = activeEmbeddedFormula
        let render = RenderPerformanceSnapshot(
            capturedAt: capturedAt,
            fps: metrics.fps,
            gpuFrameMs: metrics.gpuFrameMs,
            frameGapP95Ms: metrics.frameGapP95Ms,
            frameGapP99Ms: metrics.frameGapP99Ms,
            maximumFrameGapMs: metrics.maximumFrameGapMs,
            hitchCount: metrics.hitchCount,
            drawableWidth: metrics.drawableWidth,
            drawableHeight: metrics.drawableHeight,
            renderQuality: metrics.renderQuality,
            renderPath: metrics.renderPath,
            upscalerPath: metrics.upscalerPath,
            avgStepsPerPixel: metrics.avgStepsPerPixel,
            usingSpecializedPipeline: isUsingSpecializedPipeline
        )

        return PerformanceReport(
            capturedAt: capturedAt,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            deviceModel: Self.currentDeviceModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            activeFormulaName: activeFormula?.name,
            activeFormulaHash: activeFormula?.shortHash,
            render: render,
            metricKit: metricKitPerformanceReporter.snapshot()
        )
    }

    private static func currentDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

