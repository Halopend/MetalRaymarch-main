//
//  MetricKitReporter.swift
//  Threshold
//
//  App-lifetime MetricKit collection. OS 27 uses MetricKit's Sendable async
//  report streams; deployed OS versions fall back to MXMetricManager. Reports
//  are persisted locally and are never uploaded by this component.
//

#if canImport(MetricKit)
import Foundation
import MetricKit
import os

final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitReporter()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.puppypower.Threshold",
        category: "MetricKitReporter"
    )

    private let lifecycleLock = NSLock()
    private let store: MetricKitReportStore?
    private var isStarted = false
    private var isUsingLegacyManager = false
    private var modernManager: AnyObject?
    private var modernTasks: [Task<Void, Never>] = []

    private override init() {
        do {
            self.store = try MetricKitReportStore.makeDefault()
        } catch {
            self.store = nil
            Self.logger.error(
                "MetricKit local store is unavailable: \(error.localizedDescription, privacy: .private)"
            )
        }
        super.init()
    }

    /// Starts report delivery once for the process lifetime. Calling this more
    /// than once is harmless, including when several SwiftUI scenes appear.
    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isStarted else { return }
        guard let store else {
            Self.logger.error("MetricKit reporter was not started because its local store is unavailable")
            return
        }

        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            startModernLocked(store: store)
            isStarted = true
            Self.logger.info("Started MetricKit async report streams")
            return
        }
        #endif

        let manager = MXMetricManager.shared
        manager.add(self)
        isUsingLegacyManager = true
        isStarted = true

        // A callback can overlap these snapshots; deterministic content hashes
        // make processing both paths safe and prevent duplicate files.
        #if !os(visionOS)
        didReceive(manager.pastPayloads)
        #endif
        didReceive(manager.pastDiagnosticPayloads)
        Self.logger.info("Started legacy MetricKit subscription")
    }

    /// Primarily useful for deterministic teardown in tests and tooling. Normal
    /// app lifecycle transitions should not stop the reporter: MetricKit can only
    /// deliver while a subscriber/listener remains available.
    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isStarted else { return }

        if isUsingLegacyManager {
            MXMetricManager.shared.remove(self)
            isUsingLegacyManager = false
        }

        modernTasks.forEach { $0.cancel() }
        modernTasks.removeAll()
        modernManager = nil
        isStarted = false
        Self.logger.info("Stopped MetricKit report delivery")
    }

    deinit {
        stop()
    }

    // MARK: - Legacy MXMetricManagerSubscriber

    /// MetricKit invokes this on a background queue. Convert every Objective-C
    /// payload to Sendable Foundation values before crossing into a Task/actor.
    func didReceive(_ payloads: [MXMetricPayload]) {
        #if !os(visionOS)
        let receivedAt = Date()
        let build = MetricKitBuildIdentity.current()
        let envelopes = payloads.map { payload in
            MetricKitReportEnvelope(
                kind: .metric,
                receivedAt: receivedAt,
                interval: DateInterval(start: payload.timeStampBegin, end: payload.timeStampEnd),
                build: build,
                rawPayload: payload.jsonRepresentation()
            )
        }
        persist(envelopes)
        #endif
    }

    /// As above, materialize JSON immediately so non-Sendable MX payload objects
    /// never escape the callback queue.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let receivedAt = Date()
        let build = MetricKitBuildIdentity.current()
        let envelopes = payloads.map { payload in
            MetricKitReportEnvelope(
                kind: .diagnostic,
                receivedAt: receivedAt,
                interval: DateInterval(start: payload.timeStampBegin, end: payload.timeStampEnd),
                build: build,
                rawPayload: payload.jsonRepresentation()
            )
        }
        persist(envelopes)
    }

    private func persist(_ envelopes: [MetricKitReportEnvelope]) {
        guard !envelopes.isEmpty, let store else { return }

        Task.detached(priority: .utility) {
            for envelope in envelopes {
                do {
                    _ = try await store.persist(envelope)
                } catch {
                    Self.logger.error(
                        "Failed to store \(envelope.kind.rawValue, privacy: .public) MetricKit report: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }
    }

    // MARK: - OS 27 async MetricManager

    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func startModernLocked(store: MetricKitReportStore) {
        let manager = MetricManager()
        modernManager = manager

        let diagnosticTask = Task.detached(priority: .utility) {
            for await report in manager.diagnosticReports {
                guard !Task.isCancelled else { return }
                do {
                    let rawPayload = try Self.makeModernEncoder().encode(report)
                    let envelope = MetricKitReportEnvelope(
                        kind: .diagnostic,
                        interval: report.timeRange,
                        rawPayload: rawPayload
                    )
                    _ = try await store.persist(envelope)
                } catch {
                    Self.logger.error(
                        "Failed to encode or store modern MetricKit diagnostic: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }
        modernTasks.append(diagnosticTask)

        // MetricKit intentionally supplies diagnostics, but not daily
        // performance metric reports, for visionOS apps.
        #if !os(visionOS)
        let metricTask = Task.detached(priority: .utility) {
            for await report in manager.metricReports {
                guard !Task.isCancelled else { return }
                do {
                    let rawPayload = try Self.makeModernEncoder().encode(report)
                    let envelope = MetricKitReportEnvelope(
                        kind: .metric,
                        interval: report.timeRange,
                        rawPayload: rawPayload
                    )
                    _ = try await store.persist(envelope)
                } catch {
                    Self.logger.error(
                        "Failed to encode or store modern MetricKit metrics: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }
        modernTasks.append(metricTask)
        #endif
    }

    private static func makeModernEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    #endif
}
#endif
