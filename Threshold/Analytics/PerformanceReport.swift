//
//  PerformanceReport.swift
//  Threshold
//
//  A small, versioned report format for the Mac editor and the performance
//  review workflow. The format deliberately contains render facts, not user
//  shader source: it is useful for finding hot paths without turning a report
//  into an accidental code upload.
//

import Foundation
import Compression

enum PerformanceFindingSeverity: String, Codable, CaseIterable, Sendable {
    case critical
    case warning
    case note
}

enum PerformanceFindingArea: String, Codable, CaseIterable, Sendable {
    case gpu
    case raymarch
    case presentation
    case adaptiveQuality
    case metricKit
}

struct PerformanceFinding: Codable, Equatable, Identifiable, Sendable {
    let area: PerformanceFindingArea
    let severity: PerformanceFindingSeverity
    let title: String
    let detail: String

    var id: String { "\(area.rawValue).\(severity.rawValue).\(title)" }
}

struct RenderPerformanceSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let fps: Double
    let gpuFrameMs: Double
    let frameGapP95Ms: Double
    let frameGapP99Ms: Double
    let maximumFrameGapMs: Double
    let hitchCount: Int
    let drawableWidth: Int
    let drawableHeight: Int
    let renderQuality: Float
    let renderPath: String
    let upscalerPath: String
    let avgStepsPerPixel: Double
    let usingSpecializedPipeline: Bool
}

/// MetricKit payloads arrive after the app has been running, often on the next
/// launch. Keeping a bounded set of the original JSON payloads makes the
/// resulting archive parseable by a future server while the counters keep the
/// UI lightweight. The payloads are retained in the compressed archive only.
struct MetricKitReportSnapshot: Codable, Equatable, Sendable {
    let payloadCount: Int
    let diagnosticCount: Int
    let lastReceivedAt: Date?
    let metricPayloadJSON: [Data]
    let diagnosticPayloadJSON: [Data]

    static let empty = MetricKitReportSnapshot(
        payloadCount: 0,
        diagnosticCount: 0,
        lastReceivedAt: nil,
        metricPayloadJSON: [],
        diagnosticPayloadJSON: []
    )
}

struct PerformanceReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let capturedAt: Date
    let appVersion: String
    let buildNumber: String
    let deviceModel: String
    let osVersion: String
    let activeFormulaName: String?
    let activeFormulaHash: String?
    let render: RenderPerformanceSnapshot
    let metricKit: MetricKitReportSnapshot
    let findings: [PerformanceFinding]

    init(
        capturedAt: Date = Date(),
        appVersion: String,
        buildNumber: String,
        deviceModel: String,
        osVersion: String,
        activeFormulaName: String?,
        activeFormulaHash: String?,
        render: RenderPerformanceSnapshot,
        metricKit: MetricKitReportSnapshot
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.capturedAt = capturedAt
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.activeFormulaName = activeFormulaName
        self.activeFormulaHash = activeFormulaHash
        self.render = render
        self.metricKit = metricKit
        self.findings = PerformanceReportAnalyzer.findings(
            for: render,
            metricKit: metricKit
        )
    }

    /// Removes identifiers for a user-created distance estimator before a
    /// report leaves the app. Render measurements remain useful without them.
    func redactedForSharing() -> PerformanceReport {
        PerformanceReport(
            capturedAt: capturedAt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            deviceModel: deviceModel,
            osVersion: osVersion,
            activeFormulaName: nil,
            activeFormulaHash: nil,
            render: render,
            metricKit: metricKit
        )
    }
}

enum PerformanceReportSubmissionResult: Equatable, Sendable {
    case submitted
    case sharingDisabled
    case unavailable
    case failed
}

enum PerformanceReportAnalyzer {
    static func findings(
        for render: RenderPerformanceSnapshot,
        metricKit: MetricKitReportSnapshot = .empty
    ) -> [PerformanceFinding] {
        var findings: [PerformanceFinding] = []

        if render.gpuFrameMs >= 16.67 {
            findings.append(PerformanceFinding(
                area: .gpu,
                severity: render.gpuFrameMs >= 25 ? .critical : .warning,
                title: "GPU frame cost is above the 60 Hz budget",
                detail: String(format: "The render path averaged %.1f ms per frame. Start with DE iteration count, secondary marches, and expensive effect tails.", render.gpuFrameMs)
            ))
        }

        if render.avgStepsPerPixel >= 80 {
            findings.append(PerformanceFinding(
                area: .raymarch,
                severity: render.avgStepsPerPixel >= 140 ? .critical : .warning,
                title: "Raymarch work is heavy",
                detail: String(format: "The renderer averaged %.0f converged steps per pixel. Check the distance bound, over-relaxation recovery, and early exits before adding more math to the DE.", render.avgStepsPerPixel)
            ))
        }

        if render.frameGapP95Ms >= 24 || render.hitchCount >= 3 {
            findings.append(PerformanceFinding(
                area: .presentation,
                severity: render.frameGapP99Ms >= 80 ? .critical : .warning,
                title: "Presentation hitches are visible",
                detail: String(format: "The p95 frame gap was %.1f ms with %d recorded hitches. Separate GPU saturation from shader/pipeline compilation and drawable starvation.", render.frameGapP95Ms, render.hitchCount)
            ))
        }

        if render.renderQuality > 0 && render.renderQuality < 0.65 {
            findings.append(PerformanceFinding(
                area: .adaptiveQuality,
                severity: .note,
                title: "Adaptive quality is compensating",
                detail: String(format: "The current render quality is %.0f%%. This is a useful symptom: compare the same scene at a fixed quality before changing the DE.", render.renderQuality * 100)
            ))
        }

        if metricKit.diagnosticCount > 0 {
            findings.append(PerformanceFinding(
                area: .metricKit,
                severity: .note,
                title: "MetricKit has diagnostic payloads",
                detail: "The archive includes OS-delivered diagnostic payloads. Parse their hang, memory, and crash sections alongside this frame sample."
            ))
        }

        return findings
    }

    static func parse(_ data: Data) throws -> PerformanceReport {
        try PerformanceReportArchive.decode(data)
    }
}

enum PerformanceReportArchiveError: LocalizedError {
    case archiveTooShort
    case compressionFailed
    case decompressionFailed
    case invalidUncompressedLength

    var errorDescription: String? {
        switch self {
        case .archiveTooShort: "The performance report archive is incomplete."
        case .compressionFailed: "The performance report could not be compressed."
        case .decompressionFailed: "The performance report could not be decompressed."
        case .invalidUncompressedLength: "The performance report declares an invalid size."
        }
    }
}

enum PerformanceReportArchive {
    private static let header = Data("THRESH-PERF-1\0".utf8)
    private static let lengthByteCount = MemoryLayout<UInt64>.size

    static func encode(_ report: PerformanceReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(report)
        let compressed = try compress(json)

        var archive = header
        var length = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &length) { archive.append(contentsOf: $0) }
        archive.append(compressed)
        return archive
    }

    static func decode(_ data: Data) throws -> PerformanceReport {
        let json: Data
        if data.starts(with: header) {
            let lengthStart = header.count
            let compressedStart = lengthStart + lengthByteCount
            guard data.count > compressedStart else {
                throw PerformanceReportArchiveError.archiveTooShort
            }

            let bytes = data[lengthStart..<compressedStart]
            var uncompressedLength: UInt64 = 0
            for (offset, byte) in bytes.enumerated() {
                uncompressedLength |= UInt64(byte) << UInt64(offset * 8)
            }
            guard uncompressedLength > 0,
                  uncompressedLength <= UInt64(Int.max) else {
                throw PerformanceReportArchiveError.invalidUncompressedLength
            }
            json = try decompress(
                Data(data[compressedStart...]),
                uncompressedLength: Int(uncompressedLength)
            )
        } else {
            // Accept plain JSON as well, which makes server-side ingestion and
            // hand-authored fixtures convenient.
            json = data
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PerformanceReport.self, from: json)
    }

    private static func compress(_ data: Data) throws -> Data {
        let capacities = [
            max(data.count + 64, 256),
            max(data.count * 2 + 64, 512),
            max(data.count * 4 + 64, 1024)
        ]

        for capacity in capacities {
            var destination = Data(count: capacity)
            let written = destination.withUnsafeMutableBytes { destinationBytes in
                data.withUnsafeBytes { sourceBytes in
                    guard let destinationBase = destinationBytes.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        destinationBase,
                        capacity,
                        sourceBase,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 {
                destination.count = written
                return destination
            }
        }
        throw PerformanceReportArchiveError.compressionFailed
    }

    private static func decompress(_ data: Data, uncompressedLength: Int) throws -> Data {
        var destination = Data(count: uncompressedLength)
        let written = destination.withUnsafeMutableBytes { destinationBytes in
            data.withUnsafeBytes { sourceBytes in
                guard let destinationBase = destinationBytes.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    uncompressedLength,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedLength else {
            throw PerformanceReportArchiveError.decompressionFailed
        }
        return destination
    }
}
