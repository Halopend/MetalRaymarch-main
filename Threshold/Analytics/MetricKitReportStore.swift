//
//  MetricKitReportStore.swift
//  Threshold
//
//  Serialized, bounded persistence for raw MetricKit reports. Reports stay on
//  device; this store deliberately contains no upload or network behavior.
//

import Foundation
import os

struct MetricKitReportRetentionPolicy: Equatable, Sendable {
    struct Limit: Equatable, Sendable {
        let maximumCount: Int
        let maximumBytes: Int64

        init(maximumCount: Int, maximumBytes: Int64) {
            precondition(maximumCount > 0, "MetricKit retention must keep at least one report")
            precondition(maximumBytes > 0, "MetricKit retention byte limit must be positive")
            self.maximumCount = maximumCount
            self.maximumBytes = maximumBytes
        }
    }

    let metrics: Limit
    let diagnostics: Limit

    static let `default` = MetricKitReportRetentionPolicy(
        metrics: Limit(maximumCount: 30, maximumBytes: 24 * 1_024 * 1_024),
        diagnostics: Limit(maximumCount: 50, maximumBytes: 64 * 1_024 * 1_024)
    )

    func limit(for kind: MetricKitReportKind) -> Limit {
        switch kind {
        case .metric: metrics
        case .diagnostic: diagnostics
        }
    }
}

enum MetricKitReportPersistenceResult: Equatable, Sendable {
    case stored(URL)
    case duplicate(URL)
}

enum MetricKitReportStoreError: Error, Equatable {
    case invalidContentHash
}

actor MetricKitReportStore {
    private struct StoredFile {
        let url: URL
        let byteCount: Int64
        let receivedAt: Date
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.puppypower.Threshold",
        category: "MetricKitStore"
    )

    nonisolated let directoryURL: URL
    private let retentionPolicy: MetricKitReportRetentionPolicy

    init(
        directoryURL: URL,
        retentionPolicy: MetricKitReportRetentionPolicy = .default
    ) throws {
        self.directoryURL = directoryURL
        self.retentionPolicy = retentionPolicy

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        Self.excludeFromBackup(directoryURL)
        Self.applyFileProtection(directoryURL)
    }

    static func makeDefault(
        retentionPolicy: MetricKitReportRetentionPolicy = .default
    ) throws -> MetricKitReportStore {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("Threshold", isDirectory: true)
            .appendingPathComponent("MetricKitReports", isDirectory: true)
        return try MetricKitReportStore(
            directoryURL: directory,
            retentionPolicy: retentionPolicy
        )
    }

    @discardableResult
    func persist(_ envelope: MetricKitReportEnvelope) throws -> MetricKitReportPersistenceResult {
        guard envelope.hasValidContentHash else {
            Self.logger.error("Refusing to persist a MetricKit report with an invalid content hash")
            throw MetricKitReportStoreError.invalidContentHash
        }

        let destination = reportURL(for: envelope)
        if FileManager.default.fileExists(atPath: destination.path),
           let existingData = try? Data(contentsOf: destination),
           let existing = try? Self.decoder().decode(MetricKitReportEnvelope.self, from: existingData),
           existing.hasValidContentHash,
           existing.kind == envelope.kind,
           existing.contentHash == envelope.contentHash,
           existing.rawPayload == envelope.rawPayload {
            enforceRetention(for: envelope.kind)
            return .duplicate(destination)
        }

        do {
            let encoded = try Self.encoder().encode(envelope)
            try encoded.write(to: destination, options: .atomic)
            Self.applyFileProtection(destination)
            enforceRetention(for: envelope.kind)
            return .stored(destination)
        } catch {
            Self.logger.error(
                "Failed to persist \(envelope.kind.rawValue, privacy: .public) MetricKit report: \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    func reportURLs(for kind: MetricKitReportKind) throws -> [URL] {
        try storedFiles(for: kind)
            .sorted(by: Self.newestFirst)
            .map(\.url)
    }

    func envelopes(for kind: MetricKitReportKind) throws -> [MetricKitReportEnvelope] {
        try reportURLs(for: kind).map { url in
            let data = try Data(contentsOf: url)
            return try Self.decoder().decode(MetricKitReportEnvelope.self, from: data)
        }
    }

    private func reportURL(for envelope: MetricKitReportEnvelope) -> URL {
        directoryURL.appendingPathComponent(
            "\(envelope.kind.rawValue)-\(envelope.contentHash).json",
            isDirectory: false
        )
    }

    private func enforceRetention(for kind: MetricKitReportKind) {
        do {
            var files = try storedFiles(for: kind).sorted(by: Self.oldestFirst)
            var totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
            let limit = retentionPolicy.limit(for: kind)

            // Always retain the newest report, even if a single unusually large
            // payload is itself larger than the byte budget.
            while files.count > 1,
                  files.count > limit.maximumCount || totalBytes > limit.maximumBytes {
                let oldest = files.removeFirst()
                do {
                    try FileManager.default.removeItem(at: oldest.url)
                    totalBytes -= oldest.byteCount
                } catch {
                    Self.logger.error(
                        "Failed to prune MetricKit report \(oldest.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
                    )
                    break
                }
            }
        } catch {
            Self.logger.error(
                "Failed to enforce MetricKit retention: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func storedFiles(for kind: MetricKitReportKind) throws -> [StoredFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let prefix = "\(kind.rawValue)-"
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix(prefix) else { return nil }

            do {
                let values = try url.resourceValues(forKeys: keys)
                let byteCount = Int64(values.fileSize ?? 0)
                let fallbackDate = values.contentModificationDate ?? .distantPast
                let receivedAt: Date
                if let data = try? Data(contentsOf: url),
                   let envelope = try? Self.decoder().decode(MetricKitReportEnvelope.self, from: data) {
                    receivedAt = envelope.receivedAt
                } else {
                    receivedAt = fallbackDate
                    Self.logger.warning(
                        "MetricKit report could not be decoded during retention: \(url.lastPathComponent, privacy: .public)"
                    )
                }
                return StoredFile(url: url, byteCount: byteCount, receivedAt: receivedAt)
            } catch {
                Self.logger.error(
                    "Failed to inspect MetricKit report \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
        }
    }

    private static func oldestFirst(_ lhs: StoredFile, _ rhs: StoredFile) -> Bool {
        if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt < rhs.receivedAt }
        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
    }

    private static func newestFirst(_ lhs: StoredFile, _ rhs: StoredFile) -> Bool {
        oldestFirst(rhs, lhs)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            logger.error(
                "Failed to exclude MetricKit report directory from backup: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func applyFileProtection(_ url: URL) {
        #if os(iOS) || os(visionOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            logger.error(
                "Failed to protect MetricKit report storage: \(error.localizedDescription, privacy: .private)"
            )
        }
        #endif
    }
}
