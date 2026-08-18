//
//  PerformanceReportTests.swift
//  ThresholdTests
//

import Foundation
import Testing
@testable import Threshold

@Suite("Performance reports")
struct PerformanceReportTests {
    private let render = RenderPerformanceSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_000),
        fps: 36,
        gpuFrameMs: 28,
        frameGapP95Ms: 32,
        frameGapP99Ms: 92,
        maximumFrameGapMs: 120,
        hitchCount: 4,
        drawableWidth: 1920,
        drawableHeight: 1080,
        renderQuality: 0.5,
        renderPath: "fragment",
        upscalerPath: "native",
        avgStepsPerPixel: 160,
        usingSpecializedPipeline: true
    )

    private func makeReport() -> PerformanceReport {
        PerformanceReport(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "1.0",
            buildNumber: "42",
            deviceModel: "fixture-mac",
            osVersion: "fixture-os",
            activeFormulaName: "Fixture",
            activeFormulaHash: "abc123",
            render: render,
            metricKit: MetricKitReportSnapshot(
                payloadCount: 2,
                diagnosticCount: 1,
                lastReceivedAt: Date(timeIntervalSince1970: 1_001),
                metricPayloadJSON: [Data("{\"cpu\":1}".utf8)],
                diagnosticPayloadJSON: [Data("{\"hang\":1}".utf8)]
            )
        )
    }

    @Test("Compressed archives round-trip structured reports")
    func archiveRoundTrip() throws {
        let report = makeReport()
        let archive = try PerformanceReportArchive.encode(report)
        let rawSize = try JSONEncoder().encode(report).count

        #expect(archive.starts(with: Data("THRESH-PERF-1\0".utf8)))
        #expect(archive.count < rawSize + 100)
        #expect(try PerformanceReportAnalyzer.parse(archive) == report)
    }

    @Test("The parser also accepts plain JSON submissions")
    func plainJSONRoundTrip() throws {
        let report = makeReport()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(report)

        #expect(try PerformanceReportAnalyzer.parse(json) == report)
    }

    @Test("Shared reports remove user-created distance-estimator identity")
    func sharingRedactsCustomFormulaIdentity() {
        let shared = makeReport().redactedForSharing()

        #expect(shared.activeFormulaName == nil)
        #expect(shared.activeFormulaHash == nil)
        #expect(shared.render == render)
    }

    @Test("Analysis identifies GPU, DE, presentation, quality, and MetricKit focus areas")
    func findingsIdentifyFocusAreas() {
        let report = makeReport()
        let areas = Set(report.findings.map { $0.area })

        #expect(areas.contains(.gpu))
        #expect(areas.contains(.raymarch))
        #expect(areas.contains(.presentation))
        #expect(areas.contains(.adaptiveQuality))
        #expect(areas.contains(.metricKit))
    }
}
