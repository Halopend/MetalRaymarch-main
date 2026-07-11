//
//  MetricKitReportEnvelope.swift
//  Threshold
//
//  Stable, versioned on-disk representation for MetricKit reports. The raw
//  framework JSON is retained verbatim so newer payload fields survive even
//  when this version of Threshold does not know how to interpret them.
//

import CryptoKit
import Foundation

enum MetricKitReportKind: String, Codable, CaseIterable, Sendable {
    case metric
    case diagnostic
}

struct MetricKitBuildIdentity: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let applicationVersion: String
    let applicationBuildVersion: String
    let gitSHA: String
    let gitDirty: Bool

    static func current() -> MetricKitBuildIdentity {
        MetricKitBuildIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            applicationVersion: BuildStamp.marketingVersion,
            applicationBuildVersion: BuildStamp.buildNumber,
            gitSHA: BuildStamp.gitSHA,
            gitDirty: BuildStamp.gitDirty
        )
    }
}

struct MetricKitReportEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let kind: MetricKitReportKind
    let receivedAt: Date
    let interval: DateInterval
    let build: MetricKitBuildIdentity
    let rawPayload: Data
    let contentHash: String

    init(
        kind: MetricKitReportKind,
        receivedAt: Date = Date(),
        interval: DateInterval,
        build: MetricKitBuildIdentity = .current(),
        rawPayload: Data
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.receivedAt = receivedAt
        self.interval = interval
        self.build = build
        self.rawPayload = rawPayload
        self.contentHash = Self.makeContentHash(
            kind: kind,
            interval: interval,
            rawPayload: rawPayload
        )
    }

    var hasValidContentHash: Bool {
        contentHash == Self.makeContentHash(
            kind: kind,
            interval: interval,
            rawPayload: rawPayload
        )
    }

    static func makeContentHash(
        kind: MetricKitReportKind,
        interval: DateInterval,
        rawPayload: Data
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: stableDateBytes(interval.start))
        hasher.update(data: stableDateBytes(interval.end))
        hasher.update(data: rawPayload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stableDateBytes(_ date: Date) -> Data {
        var bits = date.timeIntervalSinceReferenceDate.bitPattern.bigEndian
        return Data(bytes: &bits, count: MemoryLayout<UInt64>.size)
    }
}
