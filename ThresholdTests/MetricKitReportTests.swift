import Foundation
import Testing
@testable import Threshold

@Suite("MetricKit local reports")
struct MetricKitReportTests {
    private let build = MetricKitBuildIdentity(
        bundleIdentifier: "com.puppypower.Threshold.tests",
        applicationVersion: "1.2.3",
        applicationBuildVersion: "456",
        gitSHA: "0123456789ab",
        gitDirty: false
    )

    @Test("Envelope round-trips raw JSON and deterministic identity")
    func envelopeRoundTrip() throws {
        let rawPayload = Data(#"{"cpu":{"seconds":1.25},"futureField":true}"#.utf8)
        let interval = DateInterval(
            start: Date(timeIntervalSinceReferenceDate: 10_000),
            duration: 86_400
        )
        let envelope = MetricKitReportEnvelope(
            kind: .metric,
            receivedAt: Date(timeIntervalSinceReferenceDate: 100_000),
            interval: interval,
            build: build,
            rawPayload: rawPayload
        )

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(MetricKitReportEnvelope.self, from: encoded)
        let independentlyCreated = MetricKitReportEnvelope(
            kind: .metric,
            receivedAt: Date(timeIntervalSinceReferenceDate: 200_000),
            interval: interval,
            build: build,
            rawPayload: rawPayload
        )
        let nextDay = MetricKitReportEnvelope(
            kind: .metric,
            receivedAt: Date(timeIntervalSinceReferenceDate: 200_000),
            interval: DateInterval(start: interval.start.addingTimeInterval(86_400), duration: 86_400),
            build: build,
            rawPayload: rawPayload
        )

        #expect(decoded == envelope)
        #expect(decoded.rawPayload == rawPayload)
        #expect(decoded.hasValidContentHash)
        #expect(independentlyCreated.contentHash == envelope.contentHash)
        #expect(nextDay.contentHash != envelope.contentHash)
    }

    @Test("Writing the same report twice deduplicates to one atomic file")
    func duplicatePersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try MetricKitReportStore(directoryURL: directory)
        let envelope = makeEnvelope(kind: .diagnostic, ordinal: 1, payloadSize: 128)

        let first = try await store.persist(envelope)
        let second = try await store.persist(envelope)
        let urls = try await store.reportURLs(for: .diagnostic)
        let stored = try await store.envelopes(for: .diagnostic)

        if case .stored = first {} else {
            Issue.record("The first persistence result should be stored")
        }
        if case .duplicate = second {} else {
            Issue.record("The second persistence result should be duplicate")
        }
        #expect(urls.count == 1)
        #expect(stored == [envelope])
    }

    @Test("Count and byte retention are enforced independently per kind")
    func retentionPerKind() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let metrics = (0..<3).map { makeEnvelope(kind: .metric, ordinal: $0, payloadSize: 64) }
        let diagnostics = (0..<2).map { makeEnvelope(kind: .diagnostic, ordinal: $0, payloadSize: 512) }
        let diagnosticBytes = try diagnostics.reduce(Int64(0)) {
            $0 + Int64(try JSONEncoder().encode($1).count)
        }
        let policy = MetricKitReportRetentionPolicy(
            metrics: .init(maximumCount: 2, maximumBytes: 1_000_000),
            diagnostics: .init(maximumCount: 10, maximumBytes: diagnosticBytes - 1)
        )
        let store = try MetricKitReportStore(directoryURL: directory, retentionPolicy: policy)

        for envelope in metrics {
            _ = try await store.persist(envelope)
        }
        for envelope in diagnostics {
            _ = try await store.persist(envelope)
        }

        let retainedMetrics = try await store.envelopes(for: .metric)
        let retainedDiagnostics = try await store.envelopes(for: .diagnostic)

        #expect(retainedMetrics.map(\.contentHash) == [metrics[2].contentHash, metrics[1].contentHash])
        #expect(retainedDiagnostics.map(\.contentHash) == [diagnostics[1].contentHash])
    }

    private func makeEnvelope(
        kind: MetricKitReportKind,
        ordinal: Int,
        payloadSize: Int
    ) -> MetricKitReportEnvelope {
        var payload = Data(repeating: UInt8(ordinal & 0xff), count: payloadSize)
        payload.append(contentsOf: Data("-\(ordinal)".utf8))
        let start = Date(timeIntervalSinceReferenceDate: TimeInterval(ordinal * 100))
        return MetricKitReportEnvelope(
            kind: kind,
            receivedAt: start.addingTimeInterval(10),
            interval: DateInterval(start: start, duration: 60),
            build: build,
            rawPayload: payload
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Threshold-MetricKitTests-\(UUID().uuidString)", isDirectory: true)
    }
}
