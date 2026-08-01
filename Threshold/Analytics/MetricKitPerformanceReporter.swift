//
//  MetricKitPerformanceReporter.swift
//  Threshold
//
//  MetricKit is intentionally an invisible collection seam: Apple delivers
//  aggregate performance/diagnostic payloads to the app when available. We
//  retain only a small bounded set locally and attach it to a report when the
//  user explicitly chooses to share one.
//

import Foundation
import Observation

#if os(macOS)
import MetricKit

@MainActor
@Observable
final class MetricKitPerformanceReporter: NSObject, MXMetricManagerSubscriber {
    private(set) var payloadCount = 0
    private(set) var diagnosticCount = 0
    private(set) var lastReceivedAt: Date?

    @ObservationIgnored private var metricPayloadJSON: [Data] = []
    @ObservationIgnored private var diagnosticPayloadJSON: [Data] = []
    private let retentionLimit = 5

    override init() {
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let payloadJSON = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor [weak self] in
            self?.ingestMetrics(payloadJSON)
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let payloadJSON = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor [weak self] in
            self?.ingestDiagnostics(payloadJSON)
        }
    }

    func snapshot() -> MetricKitReportSnapshot {
        MetricKitReportSnapshot(
            payloadCount: payloadCount,
            diagnosticCount: diagnosticCount,
            lastReceivedAt: lastReceivedAt,
            metricPayloadJSON: metricPayloadJSON,
            diagnosticPayloadJSON: diagnosticPayloadJSON
        )
    }

    private func ingestMetrics(_ payloads: [Data]) {
        guard !payloads.isEmpty else { return }
        payloadCount += payloads.count
        lastReceivedAt = Date()
        metricPayloadJSON.append(contentsOf: payloads)
        metricPayloadJSON = Array(metricPayloadJSON.suffix(retentionLimit))
    }

    private func ingestDiagnostics(_ payloads: [Data]) {
        guard !payloads.isEmpty else { return }
        diagnosticCount += payloads.count
        lastReceivedAt = Date()
        diagnosticPayloadJSON.append(contentsOf: payloads)
        diagnosticPayloadJSON = Array(diagnosticPayloadJSON.suffix(retentionLimit))
    }
}
#else

@MainActor
@Observable
final class MetricKitPerformanceReporter {
    var payloadCount = 0
    var diagnosticCount = 0
    var lastReceivedAt: Date?

    func snapshot() -> MetricKitReportSnapshot { .empty }
}
#endif

