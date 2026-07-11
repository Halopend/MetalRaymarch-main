//
//  PerfLog.swift
//  Threshold
//
//  Per-build performance log (Vision Pro focus). A deterministic scene sweep
//  (see PerfSweepRunner) measures the renderer on-device and appends one record
//  per run to Documents/PerfLog/perf-log.jsonl (+ a human-readable perf-log.md).
//  Pull those off-device via the Files app / iCloud Drive and append them to the
//  repo's tracked Threshold/PERF_LOG.jsonl + PERF_LOG.md to track perf across
//  builds. GPU/CPU numbers are only meaningful on a real device, never the
//  Simulator.
//

import Foundation

// MARK: - Build identity

/// Runtime build identity for stamping perf records. `gitSHA`/`gitDirty` come
/// from the bundled GitStamp.plist resource written by the "Stamp Git SHA" build
/// phase, with Info.plist as a compatibility fallback.
enum BuildStamp {
    static var gitSHA: String {
        (stampValue("GitSHA") ?? Bundle.main.object(forInfoDictionaryKey: "GitSHA") as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "unknown"
    }
    static var gitDirty: Bool {
        (stampValue("GitDirty") ?? Bundle.main.object(forInfoDictionaryKey: "GitDirty") as? String) == "YES"
    }
    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.isEmpty ? "unknown" : machine
    }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func stampValue(_ key: String) -> String? {
        guard let url = Bundle.main.url(forResource: "GitStamp", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: String] else {
            return nil
        }
        return dict[key]
    }
}

// MARK: - Record schema

/// One swept scene's measured stats.
///
/// **Headline metric: `iterationsAvg`** — the average number of raymarch steps a
/// ray took to converge. Unlike GPU ms (which drifts with thermals / device /
/// OS), this is a deterministic, hardware-independent measure of how much work
/// the distance-field march does, so it's the right signal for tracking the
/// raymarcher's cost across builds. GPU ms / FPS are kept as secondary context.
struct PerfSceneRecord: Codable, Sendable {
    var name: String
    var fractalType: Int
    var frames: Int
    var holdSeconds: Double

    /// Average march iterations to converge — the primary cross-build metric.
    var iterationsAvg: Double

    var gpuMsAvg: Double
    var gpuMsMin: Double
    var gpuMsMax: Double
    var gpuMsP95: Double

    var fpsAvg: Double
    var fpsMin: Double
    var cpuEncodeMsAvg: Double

    var renderPath: String
    var drawableWidth: Int
    var drawableHeight: Int
    var tileSize: Int
    var iters: Int
    var raySteps: Int
    var views: Int
}

/// The raymarch acceleration techniques active during a run, recorded as its own
/// section so iteration averages are interpretable: a drop in `iterationsAvg`
/// across builds only means something against the same technique config.
struct PerfRaymarchConfig: Codable, Sendable {
    var baseFractalIterations: Int
    var baseMaxRaySteps: Int
    var tileSize: Int
    var coneMarchStrength: Double
    var distanceLODStrength: Double
    var shadowsEnabled: Bool
    var foveationStrength: Double
    var coherentPacketEnabled: Bool
    var boundingSphereSkipEnabled: Bool

    /// One-line human summary for the markdown log.
    var summary: String {
        func pct(_ v: Double) -> String { v < 0.005 ? "off" : "\(Int((v * 100).rounded()))%" }
        return "tile=\(tileSize) iters=\(baseFractalIterations) steps=\(baseMaxRaySteps) "
            + "cone=\(pct(coneMarchStrength)) lod=\(pct(distanceLODStrength)) "
            + "shadows=\(shadowsEnabled ? "on" : "off") fov=\(pct(foveationStrength)) "
            + "coherent=\(coherentPacketEnabled ? "on" : "off") "
            + "boundSphere=\(boundingSphereSkipEnabled ? "on" : "off")"
    }
}

/// One benchmark run = one build's perf snapshot across the swept scenes.
struct PerfRunRecord: Codable, Sendable {
    var schemaVersion: Int = 1
    var capturedAt: String          // ISO-8601 UTC
    var gitSHA: String
    var gitDirty: Bool
    var marketingVersion: String
    var buildNumber: String
    var deviceModel: String
    var osVersion: String
    var raymarch: PerfRaymarchConfig
    var scenes: [PerfSceneRecord]

    /// A compact human-readable block for PERF_LOG.md.
    var markdownSummary: String {
        let dirtyTag = gitDirty ? "+dirty" : ""
        var lines = [
            "## \(capturedAt) · build \(buildNumber) · \(gitSHA)\(dirtyTag) · \(deviceModel) \(osVersion)",
            "",
            "_raymarch: \(raymarch.summary)_",
            "",
            "| scene | iters avg | gpu avg | gpu p95 | fps avg | fps min | path |",
            "|---|---|---|---|---|---|---|",
        ]
        for s in scenes {
            lines.append(String(
                format: "| %@ | %.1f | %.1f | %.1f | %.0f | %.0f | %@ |",
                s.name, s.iterationsAvg, s.gpuMsAvg, s.gpuMsP95, s.fpsAvg, s.fpsMin, s.renderPath))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

extension PerfRaymarchConfig {
    init(from q: QualityConfig) {
        self.init(
            baseFractalIterations: q.baseFractalIterations,
            baseMaxRaySteps: q.baseMaxRaySteps,
            tileSize: q.tileSize,
            coneMarchStrength: Double(q.coneMarchStrength),
            distanceLODStrength: Double(q.distanceLODStrength),
            shadowsEnabled: q.shadowsEnabled,
            foveationStrength: Double(q.foveationStrength),
            coherentPacketEnabled: q.coherentPacketEnabled,
            boundingSphereSkipEnabled: q.boundingSphereSkipEnabled)
    }
}

// MARK: - File sink

enum PerfLog {
    /// Appends a run to Documents/PerfLog/{perf-log.jsonl, perf-log.md}.
    /// Returns the JSONL file path (for surfacing in the UI), or nil on failure.
    @discardableResult
    static func write(_ run: PerfRunRecord) -> String? {
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = docs.appendingPathComponent("PerfLog", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let jsonlURL = dir.appendingPathComponent("perf-log.jsonl")
        let mdURL = dir.appendingPathComponent("perf-log.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(run),
              let jsonLine = String(data: data, encoding: .utf8) else { return nil }

        append(jsonLine + "\n", to: jsonlURL)
        append(run.markdownSummary + "\n", to: mdURL)
        return jsonlURL.path
    }

    /// Append text to a file, creating it (with a header for the .md) if absent.
    private static func append(_ text: String, to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let header = url.pathExtension == "md"
                ? "# Threshold — Vision Pro Performance Log\n\nOne block per benchmark run. GPU ms is the headline metric (lower = faster).\n\n"
                : ""
            try? (header).data(using: .utf8)?.write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = text.data(using: .utf8) { handle.write(data) }
    }
}
