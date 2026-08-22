//
//  UsageAnalytics.swift
//  Threshold
//
//  Created on January 31, 2026.
//  Optional anonymous usage analytics.
//  Uses CloudKit public database - no server required.
//
//  SETUP INSTRUCTIONS:
//  1. In Xcode: Target → Signing & Capabilities → + Capability → iCloud
//  2. Check "CloudKit" in the iCloud section
//  3. The container ID will auto-create as "iCloud.{your.bundle.id}"
//  4. In CloudKit Console (https://icloud.developer.apple.com):
//     - Select your container
//     - Go to Schema → Record Types → Create New Type
//     - Name: "UsageSnapshot"
//     - Add fields (all optional):
//       * timestamp (Date/Time)
//       * sessionDuration (Double)
//       * qualityDistribution (String)
//       * colorSchemeDistribution (String)
//       * fractalTypeDistribution (String)
//       * gradientPresetDistribution (String)
//       * lightingPresetDistribution (String)
//       * avgFractalScale (Double)
//       * avgFoldingLimit (Double)
//       * avgSphereRadius (Double)
//       * avgMinDistance (Double)
//       * avgColorMix (Double)
//       * avgGlowIntensity (Double)
//       * avgSafetyBubbleRadius (Double)
//       * avgBloomStrength (Double)
//       * avgFogIntensity (Double)
//       * usedAudioReactive (Int64)
//       * usedHandGestures (Int64)
//       * usedRecording (Int64)
//       * usedSharePlay (Int64)
//       * usedGradientColoring (Int64)
//       * usedAnimation (Int64)
//       * presetsLoaded (Int64)
//       * presetsSaved (Int64)
//       * avgFPS (Double)
//       * deviceModel (String)
//       * osVersion (String)
//       * appVersion (String)
//     - Deploy to Production environment before TestFlight
//
//  VIEW DATA:
//  - CloudKit Console → Data → Public Database → UsageSnapshot
//  - Export to CSV/JSON for analysis
//

import Foundation
import CloudKit
import Security
#if canImport(UIKit)
import UIKit
#endif
import Observation

/// Anonymous usage statistics collected during a session
struct UsageSnapshot: Codable, Sendable {
    let timestamp: Date
    let sessionDuration: TimeInterval
    
    // Quality settings distribution (percentage of time at each level)
    var qualityDistribution: [String: Float]  // e.g., ["iter6": 0.2, "iter9": 0.8]
    
    // Gradient preset usage (percentage of time)
    var gradientPresetUsageDistribution: [String: Float]
    
    // Parameter averages (weighted by time spent)
    var avgFractalScale: Float
    var avgFoldingLimit: Float
    var avgSphereRadius: Float
    var avgMinDistance: Float
    var avgColorMix: Float
    var avgGlowIntensity: Float
    var avgSafetyBubbleRadius: Float
    
    // Feature usage flags
    var usedAudioReactive: Bool
    var usedHandGestures: Bool
    var usedRecording: Bool
    var usedSharePlay: Bool
    var usedGradientColoring: Bool
    var usedAnimation: Bool
    
    // Distributions
    var fractalTypeDistribution: [String: Float]
    var gradientPresetDistribution: [String: Float]
    var lightingPresetDistribution: [String: Float]
    
    // Additional effect averages
    var avgBloomStrength: Float
    var avgFogIntensity: Float
    
    // Preset interactions
    var presetsLoaded: Int
    var presetsSaved: Int
    // Performance context
    var avgFPS: Float
    
    // Device info (anonymous)
    var deviceModel: String  // e.g., "RealityDevice14,1"
    var osVersion: String
    var appVersion: String
}

/// Owns every potentially blocking CloudKit operation away from MainActor.
/// CloudKit's first account/container lookup can synchronously initialize iCloud
/// services, so doing it here prevents a first background upload from stalling UI.
private actor UsageCloudKitUploader {
    private var cachedDatabase: CKDatabase?

    private func database() -> CKDatabase? {
        if let cachedDatabase { return cachedDatabase }
        guard UsageAnalytics.canUseCloudKit(
            hasEntitlement: UsageAnalytics.hasCloudKitEntitlement,
            ubiquityIdentityToken: FileManager.default.ubiquityIdentityToken
        ) else { return nil }

        let database = CKContainer.default().publicCloudDatabase
        cachedDatabase = database
        return database
    }

    func upload(_ snapshot: UsageSnapshot) async -> Bool {
        let record = CKRecord(recordType: "UsageSnapshot")
        record["timestamp"] = snapshot.timestamp as NSDate
        record["sessionDuration"] = snapshot.sessionDuration as NSNumber
        if let value = jsonString(snapshot.qualityDistribution) { record["qualityDistribution"] = value }
        record["avgFractalScale"] = snapshot.avgFractalScale as NSNumber
        record["avgFoldingLimit"] = snapshot.avgFoldingLimit as NSNumber
        record["avgSphereRadius"] = snapshot.avgSphereRadius as NSNumber
        record["avgMinDistance"] = snapshot.avgMinDistance as NSNumber
        record["avgColorMix"] = snapshot.avgColorMix as NSNumber
        record["avgGlowIntensity"] = snapshot.avgGlowIntensity as NSNumber
        record["avgSafetyBubbleRadius"] = snapshot.avgSafetyBubbleRadius as NSNumber
        record["avgBloomStrength"] = snapshot.avgBloomStrength as NSNumber
        record["avgFogIntensity"] = snapshot.avgFogIntensity as NSNumber
        record["usedAudioReactive"] = snapshot.usedAudioReactive ? 1 : 0
        record["usedHandGestures"] = snapshot.usedHandGestures ? 1 : 0
        record["usedRecording"] = snapshot.usedRecording ? 1 : 0
        record["usedSharePlay"] = snapshot.usedSharePlay ? 1 : 0
        record["usedGradientColoring"] = snapshot.usedGradientColoring ? 1 : 0
        record["usedAnimation"] = snapshot.usedAnimation ? 1 : 0
        if let value = jsonString(snapshot.fractalTypeDistribution) { record["fractalTypeDistribution"] = value }
        if let value = jsonString(snapshot.gradientPresetDistribution) { record["gradientPresetDistribution"] = value }
        if let value = jsonString(snapshot.lightingPresetDistribution) { record["lightingPresetDistribution"] = value }
        record["presetsLoaded"] = snapshot.presetsLoaded as NSNumber
        record["presetsSaved"] = snapshot.presetsSaved as NSNumber
        record["avgFPS"] = snapshot.avgFPS as NSNumber
        record["deviceModel"] = snapshot.deviceModel
        record["osVersion"] = snapshot.osVersion
        record["appVersion"] = snapshot.appVersion

        guard let database = database() else { return true }
        do {
            _ = try await database.save(record)
            return true
        } catch {
            return false
        }
    }

    func submit(_ report: PerformanceReport) async -> PerformanceReportSubmissionResult {
        guard let database = database() else { return .unavailable }
        let sharedReport = report.redactedForSharing()
        guard let archive = try? PerformanceReportArchive.encode(sharedReport) else { return .failed }

        let record = CKRecord(recordType: "PerformanceReport")
        record["timestamp"] = sharedReport.capturedAt as NSDate
        record["schemaVersion"] = sharedReport.schemaVersion as NSNumber
        record["appVersion"] = sharedReport.appVersion
        record["buildNumber"] = sharedReport.buildNumber
        record["deviceModel"] = sharedReport.deviceModel
        record["osVersion"] = sharedReport.osVersion
        record["fps"] = sharedReport.render.fps as NSNumber
        record["gpuFrameMs"] = sharedReport.render.gpuFrameMs as NSNumber
        record["avgStepsPerPixel"] = sharedReport.render.avgStepsPerPixel as NSNumber
        record["metricKitPayloadCount"] = sharedReport.metricKit.payloadCount as NSNumber
        record["metricKitDiagnosticCount"] = sharedReport.metricKit.diagnosticCount as NSNumber
        record["findingAreas"] = sharedReport.findings.map { $0.area.rawValue }.joined(separator: ",")
        record["reportArchiveBase64"] = archive.base64EncodedString()

        do {
            _ = try await database.save(record)
            return .submitted
        } catch {
            return .failed
        }
    }

    private func jsonString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Tracks usage patterns and uploads anonymously to CloudKit
@MainActor
@Observable
final class UsageAnalytics {
    static let shared = UsageAnalytics()
    private static let analyticsEnabledKey = "AnalyticsEnabled"
    
    static var persistedAnalyticsEnabled: Bool {
        // Sharing is opt-in. A missing preference is treated as disabled;
        // setup and Settings persist the user's explicit choice.
        UserDefaults.standard.object(forKey: analyticsEnabledKey) as? Bool ?? false
    }

    // CloudKit is initialized on first use, on its own actor, so an
    // analytics-disabled launch never touches it and first use cannot block UI.
    @ObservationIgnored private let cloudKitUploader = UsageCloudKitUploader()
    
    // Local tracking state
    private var lastSampleTime: Date = Date()
    private var totalSessionTime: TimeInterval = 0
    
    // Weighted accumulators (value * time)
    private var qualityTimeAccum: [String: TimeInterval] = [:]
    private var gradientPresetUsageAccum: [String: TimeInterval] = [:]
    private var fractalScaleAccum: Float = 0
    private var foldingLimitAccum: Float = 0
    private var sphereRadiusAccum: Float = 0
    private var minDistanceAccum: Float = 0
    private var colorMixAccum: Float = 0
    private var glowIntensityAccum: Float = 0
    private var safetyBubbleRadiusAccum: Float = 0
    private var fpsAccum: Float = 0

    // Feature flags
    private var usedAudioReactive = false
    private var usedHandGestures = false
    private var usedRecording = false
    private var usedSharePlay = false
    private var usedGradientColoring = false
    private var usedAnimation = false
    
    // Distribution accumulators
    private var fractalTypeTimeAccum: [String: TimeInterval] = [:]
    private var gradientPresetTimeAccum: [String: TimeInterval] = [:]
    private var lightingPresetTimeAccum: [String: TimeInterval] = [:]
    
    // Additional effect accumulators
    private var bloomStrengthAccum: Float = 0
    private var fogIntensityAccum: Float = 0
    
    // Preset tracking
    private var presetsLoaded = 0
    private var presetsSaved = 0
    
    // Upload interval (upload every 5 minutes of active use)
    private let uploadInterval: TimeInterval = 300
    private var lastUploadTime: Date = Date()
    
    // Persistence key
    private let pendingUploadsKey = "PendingUsageSnapshots"

    var analyticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(analyticsEnabled, forKey: Self.analyticsEnabledKey)
            if analyticsEnabled {
                Task {
                    await uploadPendingSnapshots()
                }
            }
        }
    }

    private init() {
        // Default to disabled; setup and Settings can explicitly enable it.
        self.analyticsEnabled = Self.persistedAnalyticsEnabled
        // Display names are no longer part of sharing. Remove a value saved by
        // an older release instead of retaining an unused user identifier.
        UserDefaults.standard.removeObject(forKey: "CommunityDisplayName")
        
        // Try to upload any pending snapshots from previous sessions when opted in.
        if analyticsEnabled {
            Task {
                await uploadPendingSnapshots()
            }
        }
    }

    private func distributionPercentages(_ source: [String: TimeInterval], duration: TimeInterval) -> [String: Float] {
        let safeDuration = max(duration, 1.0)
        return source.mapValues { Float($0 / safeDuration) }
    }

    /// Custom descriptors use the author's formula name in the UI. Analytics
    /// collapses every one of them into a generic bucket.
    static func fractalCategory(for type: FractalModelType) -> String {
        type == .custom ? "Custom Formula" : type.displayName
    }

    private func currentDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private func currentOSVersion() -> String {
        #if canImport(UIKit)
        UIDevice.current.systemVersion
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    /// Whether THIS binary was signed with the iCloud-container entitlement, read once
    /// from the running process's own entitlements via the Security framework. Unlike
    /// `CKContainer.default()` (which aborts with an uncaught ObjC exception when the
    /// entitlement is absent), this probe is non-throwing, so it's safe on unsigned builds.
    nonisolated fileprivate static let hasCloudKitEntitlement: Bool = {
        #if os(macOS)
        // The unsigned-build CloudKit freeze this guards against only happens on the
        // macOS local-build workflow (CODE_SIGNING_ALLOWED=NO). SecTask entitlement
        // introspection is exposed there; use it as the non-throwing probe.
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        if let identifiers = value as? [Any] { return !identifiers.isEmpty }
        return true
        #else
        // SecTask entitlement introspection is not exposed by the iOS/visionOS Swift
        // SDKs. Those targets ship as provisioned device builds; the token check below
        // remains the non-throwing account-availability gate.
        return true
        #endif
    }()

    nonisolated static func canUseCloudKit(hasEntitlement: Bool, ubiquityIdentityToken: Any?) -> Bool {
        hasEntitlement && ubiquityIdentityToken != nil
    }

    private func buildSnapshot() -> UsageSnapshot {
        let duration = totalSessionTime
        let durationF = Float(max(duration, 1.0))

        let qualityDist = distributionPercentages(qualityTimeAccum, duration: duration)
        let gradientPresetUsageDist = distributionPercentages(gradientPresetUsageAccum, duration: duration)
        let fractalTypeDist = distributionPercentages(fractalTypeTimeAccum, duration: duration)
        let gradientPresetDist = distributionPercentages(gradientPresetTimeAccum, duration: duration)
        let lightingPresetDist = distributionPercentages(lightingPresetTimeAccum, duration: duration)

        return UsageSnapshot(
            timestamp: Date(),
            sessionDuration: duration,
            qualityDistribution: qualityDist,
            gradientPresetUsageDistribution: gradientPresetUsageDist,
            avgFractalScale: fractalScaleAccum / durationF,
            avgFoldingLimit: foldingLimitAccum / durationF,
            avgSphereRadius: sphereRadiusAccum / durationF,
            avgMinDistance: minDistanceAccum / durationF,
            avgColorMix: colorMixAccum / durationF,
            avgGlowIntensity: glowIntensityAccum / durationF,
            avgSafetyBubbleRadius: safetyBubbleRadiusAccum / durationF,
            usedAudioReactive: usedAudioReactive,
            usedHandGestures: usedHandGestures,
            usedRecording: usedRecording,
            usedSharePlay: usedSharePlay,
            usedGradientColoring: usedGradientColoring,
            usedAnimation: usedAnimation,
            fractalTypeDistribution: fractalTypeDist,
            gradientPresetDistribution: gradientPresetDist,
            lightingPresetDistribution: lightingPresetDist,
            avgBloomStrength: bloomStrengthAccum / durationF,
            avgFogIntensity: fogIntensityAccum / durationF,
            presetsLoaded: presetsLoaded,
            presetsSaved: presetsSaved,
            avgFPS: fpsAccum / durationF,
            deviceModel: currentDeviceModel(),
            osVersion: currentOSVersion(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
    }
    
    // MARK: - Sampling (call from render loop ~1Hz)
    
    /// Sample current settings. Call approximately once per second from render loop.
    func sample(settings: RenderSettings, fps: Double, currentQuality: String) {
        guard analyticsEnabled else { return }
        
        let now = Date()
        let deltaTime = now.timeIntervalSince(lastSampleTime)
        lastSampleTime = now
        
        // Clamp delta to [0, 2]: the upper bound absorbs backgrounding gaps; the
        // lower bound rejects a NEGATIVE delta from a backward wall-clock jump
        // (NTP correction, manual clock change, DST edge), which would otherwise
        // add negative time to every weighted accumulator and corrupt the stats.
        let dt = max(min(deltaTime, 2.0), 0)
        totalSessionTime += dt
        
        // Accumulate quality time
        qualityTimeAccum[currentQuality, default: 0] += dt
        
        // ── Snapshot domains (4 lock acquisitions vs ~15) ──
        let geo = settings.geometryConfig
        let col = settings.colorConfig
        let lit = settings.lightingConfig
        let sb  = settings.safetyBubbleConfig

        // Accumulate gradient preset time
        let presetName = col.gradientState.gradientPreset?.rawValue ?? "custom"
        gradientPresetUsageAccum[presetName, default: 0] += dt
        
        // Accumulate parameter values (for averaging)
        let dtf = Float(dt)
        fractalScaleAccum += geo.fractalScale * dtf
        foldingLimitAccum += geo.foldingLimit * dtf
        sphereRadiusAccum += geo.sphereRadius * dtf
        minDistanceAccum += geo.minDistance * dtf
        colorMixAccum += col.colorMix * dtf
        glowIntensityAccum += lit.glowEffect.intensity * dtf
        safetyBubbleRadiusAccum += sb.radius * dtf
        bloomStrengthAccum += lit.bloomEffect.strength * dtf
        fogIntensityAccum += lit.fogEffect.intensity * dtf
        fpsAccum += Float(fps) * dtf

        // Accumulate fractal type distribution
        fractalTypeTimeAccum[Self.fractalCategory(for: geo.fractalType), default: 0] += dt
        
        // Accumulate gradient preset distribution
        usedGradientColoring = true
        let gradName = col.gradientState.gradientPreset?.rawValue ?? "Custom"
        gradientPresetTimeAccum[gradName, default: 0] += dt
        
        // Accumulate lighting preset distribution
        lightingPresetTimeAccum[lit.lightingPreset.displayName, default: 0] += dt
        
        // Track feature usage
        if settings.displayConfig.lightingMode == .audioReactive {
            usedAudioReactive = true
        }
        // Check if we should upload
        if now.timeIntervalSince(lastUploadTime) >= uploadInterval {
            Task {
                await uploadSnapshot()
            }
            lastUploadTime = now
        }
    }
    
    /// Mark that hand gestures were used
    func trackHandGestureUsed() {
        guard analyticsEnabled else { return }
        usedHandGestures = true
    }
    
    
    /// Mark that SharePlay was used
    func trackSharePlayUsed() {
        guard analyticsEnabled else { return }
        usedSharePlay = true
    }
    
    /// Mark that animation playback was used
    func trackAnimationUsed() {
        guard analyticsEnabled else { return }
        usedAnimation = true
    }

    /// Mark that live session recording was used
    func trackRecordingUsed() {
        guard analyticsEnabled else { return }
        usedRecording = true
    }
    
    /// Track preset load
    func trackPresetLoaded(name _: String) {
        guard analyticsEnabled else { return }
        presetsLoaded += 1
    }
    
    /// Track that a preset was saved (local aggregate count only).
    ///
    /// Only the aggregate count is retained. Preset names, contents, custom
    /// distance estimators, and positions are never recorded or uploaded.
    func trackPresetSaved(preset _: FractalPreset) {
        guard analyticsEnabled else { return }
        presetsSaved += 1
    }
    
    // MARK: - CloudKit Upload
    
    /// Upload current snapshot to CloudKit
    func uploadSnapshot() async {
        guard analyticsEnabled else { return }
        guard totalSessionTime > 10 else { return }  // Don't upload very short sessions
        
        // Build a snapshot from the current accumulated data.
        let snapshot = buildSnapshot()

        await uploadToCloudKit(snapshot)
    }

    /// Submit a structured, compressed performance report. This is separate
    /// from the background usage snapshot: it only runs after the user presses
    /// “Submit report”, and it is gated by the anonymous analytics
    /// preference. Reports contain no formula source, formula identifier, user
    /// preset name, or scene position.
    func submitPerformanceReport(_ report: PerformanceReport) async -> PerformanceReportSubmissionResult {
        guard analyticsEnabled else { return .sharingDisabled }
        return await cloudKitUploader.submit(report)
    }

    private func uploadToCloudKit(_ snapshot: UsageSnapshot) async {
        guard analyticsEnabled else { return }
        if !(await cloudKitUploader.upload(snapshot)) {
            // Save for retry later
            savePendingSnapshot(snapshot)
        }
    }
    
    // MARK: - Offline Persistence
    
    private func savePendingSnapshot(_ snapshot: UsageSnapshot) {
        var pending = loadPendingSnapshots()
        pending.append(snapshot)
        
        // Keep only last 10 pending
        if pending.count > 10 {
            pending = Array(pending.suffix(10))
        }
        
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: pendingUploadsKey)
        }
    }
    
    private func loadPendingSnapshots() -> [UsageSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: pendingUploadsKey),
              let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }
    
    private func uploadPendingSnapshots() async {
        guard analyticsEnabled else { return }
        let pending = loadPendingSnapshots()
        guard !pending.isEmpty else { return }
        
        // Clear pending - uploadToCloudKit will re-save failures
        UserDefaults.standard.removeObject(forKey: pendingUploadsKey)
        
        for snapshot in pending {
            await uploadToCloudKit(snapshot)
        }
    }
    
    // MARK: - Session Lifecycle
    
    /// Call when app goes to background or terminates
    func endSession() async {
        guard analyticsEnabled else { return }
        await uploadSnapshot()
    }
    
}
