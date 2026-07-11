//
//  UsageAnalytics.swift
//  Threshold
//
//  Created on January 31, 2026.
//  Opt-in anonymous usage analytics for TestFlight beta.
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
import OSLog
import Security
#if canImport(UIKit)
import UIKit
#endif
import Observation

/// Anonymous usage statistics collected during a session
struct UsageSnapshot: Codable {
    /// Stable upload identity. Optional only so queues written by older builds
    /// decode successfully; legacy entries receive and persist an ID before any
    /// network request is attempted.
    var uploadID: UUID?
    let timestamp: Date
    let sessionDuration: TimeInterval
    
    // Quality settings distribution (percentage of time at each level)
    var qualityDistribution: [String: Float]  // e.g., ["iter6": 0.2, "iter9": 0.8]
    
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

/// Tracks usage patterns and uploads anonymously to CloudKit
@MainActor
@Observable
final class UsageAnalytics {
    static let shared = UsageAnalytics(defaults: .standard)
    nonisolated static let analyticsEnabledKey = "AnalyticsEnabled"
    nonisolated static let pendingUploadsKey = "PendingUsageSnapshots"
    nonisolated static let maxPendingUploads = 10
    private static let communityDisplayNameKey = "CommunityDisplayName"
    private static let logger = Logger(subsystem: "com.puppypower.Threshold", category: "UsageAnalytics")
    
    nonisolated static var persistedAnalyticsEnabled: Bool {
        persistedAnalyticsEnabled(in: .standard)
    }

    /// Reads consent without creating the shared analytics object. An absent
    /// key is deliberately OFF: collection starts only after an explicit opt-in.
    nonisolated static func persistedAnalyticsEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: analyticsEnabledKey) as? Bool ?? false
    }

    /// Stable CloudKit record name used for every retry of an outbox item.
    nonisolated static func recordName(for uploadID: UUID) -> String {
        "usage-\(uploadID.uuidString.lowercased())"
    }

    /// Stable, bounded-cardinality key. A custom formula's descriptor carries
    /// its user-authored display name, which must never become telemetry.
    nonisolated static func fractalAnalyticsKey(for type: FractalModelType) -> String {
        guard type != .custom else { return "custom" }
        return type.descriptor.codableString
    }

    /// Retains the newest values when bounding a durable queue.
    nonisolated static func boundedSuffix<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        return values.count > limit ? Array(values.suffix(limit)) : values
    }

    /// A retry of a successfully-created deterministic record reports a
    /// conflict. It is delivered only when the server record is the exact ID
    /// we attempted, never for an unrelated conflict.
    nonisolated static func isDeliveredRecordConflict(
        code: CKError.Code,
        serverRecordID: CKRecord.ID?,
        expectedRecordID: CKRecord.ID
    ) -> Bool {
        code == .serverRecordChanged && serverRecordID == expectedRecordID
    }

    // CloudKit is initialized on first use so analytics-disabled launches
    // don't touch CloudKit during startup or permission-triggered relaunches.
    @ObservationIgnored private var cachedDatabase: CKDatabase?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let automaticallyUploadPending: Bool
    
    // Local tracking state
    private var lastSampleTime: Date = Date()
    private var totalSessionTime: TimeInterval = 0
    
    // Weighted accumulators (value * time)
    private var qualityTimeAccum: [String: TimeInterval] = [:]
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
    
    private var isDrainingOutbox = false

    private var storedCommunityDisplayName: String
    
    var analyticsEnabled: Bool {
        didSet {
            guard oldValue != analyticsEnabled else { return }
            defaults.set(analyticsEnabled, forKey: Self.analyticsEnabledKey)
            if analyticsEnabled {
                lastSampleTime = Date()
                lastUploadTime = Date()
                if automaticallyUploadPending {
                    Task {
                        await uploadPendingSnapshots()
                    }
                }
            } else {
                purgeCollectedAnalytics()
            }
        }
    }

    var communityDisplayName: String {
        get { storedCommunityDisplayName }
        set {
            let normalized = Self.normalizedCommunityDisplayName(newValue)
            guard storedCommunityDisplayName != normalized else { return }
            storedCommunityDisplayName = normalized

            if normalized.isEmpty {
                defaults.removeObject(forKey: Self.communityDisplayNameKey)
            } else {
                defaults.set(normalized, forKey: Self.communityDisplayNameKey)
            }
        }
    }
    
    init(defaults: UserDefaults, automaticallyUploadPending: Bool = true) {
        // Existing explicit choices are preserved; an unset key is OFF.
        self.defaults = defaults
        self.automaticallyUploadPending = automaticallyUploadPending
        self.analyticsEnabled = Self.persistedAnalyticsEnabled(in: defaults)
        self.storedCommunityDisplayName = Self.normalizedCommunityDisplayName(
            defaults.string(forKey: Self.communityDisplayNameKey) ?? ""
        )
        
        // Try to upload any pending snapshots from previous sessions when opted in.
        if analyticsEnabled {
            if automaticallyUploadPending {
                Task {
                    await uploadPendingSnapshots()
                }
            }
        } else {
            // Also clears legacy queued payloads on upgrade when consent is
            // absent or had already been withdrawn.
            defaults.removeObject(forKey: Self.pendingUploadsKey)
        }
    }

    private static func normalizedCommunityDisplayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func distributionPercentages(_ source: [String: TimeInterval], duration: TimeInterval) -> [String: Float] {
        let safeDuration = max(duration, 1.0)
        return source.mapValues { Float($0 / safeDuration) }
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

    private func jsonString<T: Encodable>(from value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The CloudKit public database, or `nil` when CloudKit isn't usable.
    ///
    /// `CKContainer.default()` throws an *uncaught Objective-C exception* (→ abort)
    /// when the iCloud entitlement is absent — which happens for local builds
    /// signed without the team's provisioning (empty team ID). Swift `do/catch`
    /// can't catch that, so we must avoid the call. `ubiquityIdentityToken` is a
    /// non-throwing probe that is non-nil only when the iCloud entitlement is
    /// present AND a user is signed in — both prerequisites for a usable default
    /// container here (this target's entitlements set the ubiquity + CloudKit
    /// containers together). When it's nil we degrade analytics to a silent no-op.
    private func database() -> CKDatabase? {
        if let cachedDatabase {
            return cachedDatabase
        }

        // Two independent prerequisites, BOTH required before touching CloudKit:
        //  1. This binary actually carries the iCloud-container entitlement. Local builds
        //     signed without provisioning (CODE_SIGNING_ALLOWED=NO) have NO entitlements,
        //     yet if the developer is signed into iCloud the token probe below still passes
        //     — so `CKContainer.default()` throws an UNCAUGHT ObjC exception (Swift can't
        //     catch it) and the app freezes in the crash-reporter modal. That freeze reads
        //     as "the whole app hangs / is completely laggy". Reading our own signed
        //     entitlements is the only reliable, non-throwing way to detect this.
        //  2. A user is signed into iCloud (token non-nil).
        guard Self.canUseCloudKit(hasEntitlement: Self.hasCloudKitEntitlement,
                                  ubiquityIdentityToken: FileManager.default.ubiquityIdentityToken) else {
            return nil
        }

        let database = CKContainer.default().publicCloudDatabase
        cachedDatabase = database
        return database
    }

    /// Whether THIS binary was signed with the iCloud-container entitlement, read once
    /// from the running process's own entitlements via the Security framework. Unlike
    /// `CKContainer.default()` (which aborts with an uncaught ObjC exception when the
    /// entitlement is absent), this probe is non-throwing, so it's safe on unsigned builds.
    private static let hasCloudKitEntitlement: Bool = {
        #if targetEnvironment(simulator)
        // Simulator builds are commonly unsigned. Even when the host Mac has
        // an iCloud identity token, touching CKContainer.default() without the
        // app entitlement can raise an Objective-C exception that Swift cannot
        // catch. Analytics is intentionally a no-op in simulators.
        return false
        #elseif os(macOS)
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

    private func buildSnapshot(uploadID: UUID) -> UsageSnapshot {
        let duration = totalSessionTime
        let durationF = Float(max(duration, 1.0))

        let qualityDist = distributionPercentages(qualityTimeAccum, duration: duration)
        let fractalTypeDist = distributionPercentages(fractalTypeTimeAccum, duration: duration)
        let gradientPresetDist = distributionPercentages(gradientPresetTimeAccum, duration: duration)
        let lightingPresetDist = distributionPercentages(lightingPresetTimeAccum, duration: duration)

        return UsageSnapshot(
            uploadID: uploadID,
            timestamp: Date(),
            sessionDuration: duration,
            qualityDistribution: qualityDist,
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
        fractalTypeTimeAccum[Self.fractalAnalyticsKey(for: geo.fractalType), default: 0] += dt
        
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
    
    /// Track that a preset was saved (aggregate count only). The preset object is
    /// intentionally ignored: names and authored content never enter telemetry.
    func trackPresetSaved(preset _: FractalPreset) {
        guard analyticsEnabled else { return }
        presetsSaved += 1
    }
    
    // MARK: - CloudKit Upload
    
    /// Consumes the current aggregate window into the durable outbox, then tries
    /// to deliver it. Persisting succeeds before accumulators are reset or any
    /// network request starts, so a crash/background suspension cannot lose it.
    func uploadSnapshot() async {
        guard analyticsEnabled else { return }
        guard totalSessionTime > 10 else { return }  // Don't upload very short sessions

        let snapshot = buildSnapshot(uploadID: UUID())
        guard enqueuePendingSnapshot(snapshot) else { return }
        resetAccumulatedWindow()
        await uploadPendingSnapshots()
    }

    private func uploadToCloudKit(_ snapshot: UsageSnapshot, database: CKDatabase) async -> Bool {
        guard analyticsEnabled, let uploadID = snapshot.uploadID else { return false }
        let recordID = CKRecord.ID(recordName: Self.recordName(for: uploadID))
        let record = CKRecord(recordType: "UsageSnapshot", recordID: recordID)
        
        // Session info
        record["timestamp"] = snapshot.timestamp as NSDate
        record["sessionDuration"] = snapshot.sessionDuration as NSNumber
        
        // Encode distributions as JSON strings (CloudKit doesn't support nested dicts)
        if let qualityString = jsonString(from: snapshot.qualityDistribution) {
            record["qualityDistribution"] = qualityString
        }
        
        // Parameter averages
        record["avgFractalScale"] = snapshot.avgFractalScale as NSNumber
        record["avgFoldingLimit"] = snapshot.avgFoldingLimit as NSNumber
        record["avgSphereRadius"] = snapshot.avgSphereRadius as NSNumber
        record["avgMinDistance"] = snapshot.avgMinDistance as NSNumber
        record["avgColorMix"] = snapshot.avgColorMix as NSNumber
        record["avgGlowIntensity"] = snapshot.avgGlowIntensity as NSNumber
        record["avgSafetyBubbleRadius"] = snapshot.avgSafetyBubbleRadius as NSNumber
        record["avgBloomStrength"] = snapshot.avgBloomStrength as NSNumber
        record["avgFogIntensity"] = snapshot.avgFogIntensity as NSNumber
        
        // Feature flags
        record["usedAudioReactive"] = snapshot.usedAudioReactive ? 1 : 0
        record["usedHandGestures"] = snapshot.usedHandGestures ? 1 : 0
        record["usedRecording"] = snapshot.usedRecording ? 1 : 0
        record["usedSharePlay"] = snapshot.usedSharePlay ? 1 : 0
        record["usedGradientColoring"] = snapshot.usedGradientColoring ? 1 : 0
        record["usedAnimation"] = snapshot.usedAnimation ? 1 : 0
        
        // Distributions (encoded as JSON strings)
        if let fractalTypeString = jsonString(from: snapshot.fractalTypeDistribution) {
            record["fractalTypeDistribution"] = fractalTypeString
        }
        if let gradientString = jsonString(from: snapshot.gradientPresetDistribution) {
            record["gradientPresetDistribution"] = gradientString
        }
        if let lightingString = jsonString(from: snapshot.lightingPresetDistribution) {
            record["lightingPresetDistribution"] = lightingString
        }
        
        // Presets
        record["presetsLoaded"] = snapshot.presetsLoaded as NSNumber
        record["presetsSaved"] = snapshot.presetsSaved as NSNumber
        
        // Performance
        record["avgFPS"] = snapshot.avgFPS as NSNumber
        
        // Device (anonymous)
        record["deviceModel"] = snapshot.deviceModel
        record["osVersion"] = snapshot.osVersion
        record["appVersion"] = snapshot.appVersion
        
        do {
            _ = try await database.save(record)
            return true
        } catch let cloudError as CKError {
            if Self.isDeliveredRecordConflict(
                code: cloudError.code,
                serverRecordID: cloudError.serverRecord?.recordID,
                expectedRecordID: recordID
            ) {
                // A prior attempt reached CloudKit but its acknowledgement did
                // not reach us. The deterministic record already exists.
                return true
            }
            Self.logger.error(
                "CloudKit analytics upload failed (code: \(cloudError.code.rawValue, privacy: .public)); outbox retained"
            )
            return false
        } catch {
            Self.logger.error("CloudKit analytics upload failed; outbox retained")
            return false
        }
    }
    
    // MARK: - Offline Persistence
    
    @discardableResult
    private func enqueuePendingSnapshot(_ snapshot: UsageSnapshot) -> Bool {
        var pending = loadPendingSnapshots()
        assignMissingUploadIDs(in: &pending)
        pending.append(snapshot)
        let bounded = Self.boundedSuffix(pending, limit: Self.maxPendingUploads)
        if bounded.count < pending.count {
            Self.logger.notice("Analytics outbox reached its retention limit; oldest window dropped")
        }
        return persistPendingSnapshots(bounded)
    }
    
    private func loadPendingSnapshots() -> [UsageSnapshot] {
        guard let data = defaults.data(forKey: Self.pendingUploadsKey) else { return [] }
        do {
            return try JSONDecoder().decode([UsageSnapshot].self, from: data)
        } catch {
            // The bytes are unusable and may have come from an incompatible beta
            // schema. Do not log their contents.
            Self.logger.error("Analytics outbox could not be decoded and was discarded")
            defaults.removeObject(forKey: Self.pendingUploadsKey)
            return []
        }
    }

    @discardableResult
    private func persistPendingSnapshots(_ snapshots: [UsageSnapshot]) -> Bool {
        if snapshots.isEmpty {
            defaults.removeObject(forKey: Self.pendingUploadsKey)
            return true
        }
        do {
            let data = try JSONEncoder().encode(snapshots)
            defaults.set(data, forKey: Self.pendingUploadsKey)
            return true
        } catch {
            Self.logger.error("Analytics outbox could not be encoded; collection window retained")
            return false
        }
    }

    private func assignMissingUploadIDs(in snapshots: inout [UsageSnapshot]) {
        for index in snapshots.indices where snapshots[index].uploadID == nil {
            snapshots[index].uploadID = UUID()
        }
    }

    /// Migrates legacy queue entries (which had no ID and could contain fields
    /// no longer present in `UsageSnapshot`) and persists the sanitized form
    /// before delivery. Returning nil means persistence failed, so networking
    /// must not begin.
    private func outboxReadyForDelivery() -> [UsageSnapshot]? {
        var pending = loadPendingSnapshots()
        let originalCount = pending.count
        let hadMissingIDs = pending.contains { $0.uploadID == nil }
        assignMissingUploadIDs(in: &pending)
        pending = Self.boundedSuffix(pending, limit: Self.maxPendingUploads)

        if hadMissingIDs || pending.count != originalCount {
            guard persistPendingSnapshots(pending) else { return nil }
        }
        return pending
    }

    @discardableResult
    private func removePendingSnapshot(uploadID: UUID) -> Bool {
        var pending = loadPendingSnapshots()
        pending.removeAll { $0.uploadID == uploadID }
        return persistPendingSnapshots(pending)
    }
    
    private func uploadPendingSnapshots() async {
        guard analyticsEnabled, !isDrainingOutbox else { return }
        isDrainingOutbox = true
        defer { isDrainingOutbox = false }

        // Normalize and persist legacy entries even when CloudKit is currently
        // unavailable. This strips retired raw-name fields from the encoded queue.
        guard let initialPending = outboxReadyForDelivery(), !initialPending.isEmpty else { return }
        guard let database = database() else {
            Self.logger.debug("CloudKit unavailable; analytics outbox retained")
            return
        }

        while analyticsEnabled {
            guard let pending = outboxReadyForDelivery(), let snapshot = pending.first,
                  let uploadID = snapshot.uploadID else {
                return
            }

            guard await uploadToCloudKit(snapshot, database: database) else { return }
            guard analyticsEnabled else { return }
            // If this write fails, leave the item in place. Its deterministic
            // record name makes the next attempt safe even after server success.
            guard removePendingSnapshot(uploadID: uploadID) else { return }
        }
    }

    // MARK: - Window Reset / Consent Revocation

    /// Internal invariant used by consent handling and regression tests.
    var isCurrentWindowEmpty: Bool {
        totalSessionTime == 0 &&
        qualityTimeAccum.isEmpty &&
        fractalScaleAccum == 0 &&
        foldingLimitAccum == 0 &&
        sphereRadiusAccum == 0 &&
        minDistanceAccum == 0 &&
        colorMixAccum == 0 &&
        glowIntensityAccum == 0 &&
        safetyBubbleRadiusAccum == 0 &&
        fpsAccum == 0 &&
        !usedAudioReactive &&
        !usedHandGestures &&
        !usedRecording &&
        !usedSharePlay &&
        !usedGradientColoring &&
        !usedAnimation &&
        fractalTypeTimeAccum.isEmpty &&
        gradientPresetTimeAccum.isEmpty &&
        lightingPresetTimeAccum.isEmpty &&
        bloomStrengthAccum == 0 &&
        fogIntensityAccum == 0 &&
        presetsLoaded == 0 &&
        presetsSaved == 0
    }

    private func resetAccumulatedWindow(now: Date = Date()) {
        lastSampleTime = now
        lastUploadTime = now
        totalSessionTime = 0

        qualityTimeAccum.removeAll(keepingCapacity: true)
        fractalScaleAccum = 0
        foldingLimitAccum = 0
        sphereRadiusAccum = 0
        minDistanceAccum = 0
        colorMixAccum = 0
        glowIntensityAccum = 0
        safetyBubbleRadiusAccum = 0
        fpsAccum = 0

        usedAudioReactive = false
        usedHandGestures = false
        usedRecording = false
        usedSharePlay = false
        usedGradientColoring = false
        usedAnimation = false

        fractalTypeTimeAccum.removeAll(keepingCapacity: true)
        gradientPresetTimeAccum.removeAll(keepingCapacity: true)
        lightingPresetTimeAccum.removeAll(keepingCapacity: true)
        bloomStrengthAccum = 0
        fogIntensityAccum = 0

        presetsLoaded = 0
        presetsSaved = 0
    }

    private func purgeCollectedAnalytics() {
        resetAccumulatedWindow()
        defaults.removeObject(forKey: Self.pendingUploadsKey)
        cachedDatabase = nil
    }
    
    // MARK: - Session Lifecycle
    
    /// Call when app goes to background or terminates
    func endSession() async {
        guard analyticsEnabled else { return }
        guard totalSessionTime > 10 else {
            // A short foreground period is intentionally discarded, not merged
            // into a later session or uploaded twice by inactive/background hooks.
            resetAccumulatedWindow()
            return
        }
        await uploadSnapshot()
    }
    
}
