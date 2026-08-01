//
//  UsageAnalytics.swift
//  Threshold
//
//  Created on January 31, 2026.
//  Automatic anonymous usage analytics for TestFlight beta.
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
//       * favoritePresets (List of Strings)
//       * avgFPS (Double)
//       * deviceModel (String)
//       * osVersion (String)
//       * appVersion (String)
//
//     - Create another Record Type: "PresetSnapshot"
//     - Add fields:
//       * timestamp (Date/Time)
//       * presetName (String)
//       * presetJSON (String) - full preset as JSON for easy parsing
//       * deviceModel (String)
//       * appVersion (String)
//       --- Individual fields for easy CloudKit querying/filtering ---
//       * colorScheme (String)
//       * fractalScale (Double)
//       * foldingLimit (Double)
//       * sphereRadius (Double)
//       * minDistance (Double)
//       * fractalIterations (Int64)
//       * glowIntensity (Double)
//       * fogIntensity (Double)
//       * colorSchemeVibrance (Double)
//     - Deploy to Production environment before TestFlight
//
//  VIEW DATA:
//  - CloudKit Console → Data → Public Database → UsageSnapshot / PresetSnapshot
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
struct UsageSnapshot: Codable {
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
    var favoritePresetNames: [String]  // Top 3 most loaded
    
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
    static let shared = UsageAnalytics()
    private static let analyticsEnabledKey = "AnalyticsEnabled"
    private static let communityDisplayNameKey = "CommunityDisplayName"
    
    static var persistedAnalyticsEnabled: Bool {
        // Sharing is opt-out: first-launch users get sharing enabled by
        // default. The `object(forKey:) == nil` check is what distinguishes
        // "never set" (first launch) from "explicitly turned off" (an
        // existing user who later set it to false). Returning `true` for
        // the first-launch case is the entire default-flip.
        UserDefaults.standard.object(forKey: analyticsEnabledKey) as? Bool ?? true
    }

    // CloudKit is initialized on first use so analytics-disabled launches
    // don't touch CloudKit during startup or permission-triggered relaunches.
    @ObservationIgnored private var cachedDatabase: CKDatabase?
    
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
    private var presetLoadCounts: [String: Int] = [:]
    
    // Upload interval (upload every 5 minutes of active use)
    private let uploadInterval: TimeInterval = 300
    private var lastUploadTime: Date = Date()
    
    // Persistence key
    private let pendingUploadsKey = "PendingUsageSnapshots"

    private var storedCommunityDisplayName: String
    
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

    var communityDisplayName: String {
        get { storedCommunityDisplayName }
        set {
            let normalized = Self.normalizedCommunityDisplayName(newValue)
            guard storedCommunityDisplayName != normalized else { return }
            storedCommunityDisplayName = normalized

            if normalized.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.communityDisplayNameKey)
            } else {
                UserDefaults.standard.set(normalized, forKey: Self.communityDisplayNameKey)
            }
        }
    }
    
    private init() {
        // Default to enabled — user can opt out via Settings > Sharing or
        // by toggling it on the welcome screen. `persistedAnalyticsEnabled`
        // returns `true` for users who have never set the key (first
        // launch); users who explicitly turned it off in a previous build
        // will see it stay off.
        self.analyticsEnabled = Self.persistedAnalyticsEnabled
        self.storedCommunityDisplayName = Self.normalizedCommunityDisplayName(
            UserDefaults.standard.string(forKey: Self.communityDisplayNameKey) ?? ""
        )
        
        // Try to upload any pending snapshots from previous sessions when opted in.
        if analyticsEnabled {
            Task {
                await uploadPendingSnapshots()
            }
        }
    }

    private static func normalizedCommunityDisplayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func distributionPercentages(_ source: [String: TimeInterval], duration: TimeInterval) -> [String: Float] {
        let safeDuration = max(duration, 1.0)
        return source.mapValues { Float($0 / safeDuration) }
    }

    private func topFavoritePresets(limit: Int = 3) -> [String] {
        presetLoadCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
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
            favoritePresetNames: topFavoritePresets(),
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
        fractalTypeTimeAccum[geo.fractalType.displayName, default: 0] += dt
        
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
    func trackPresetLoaded(name: String) {
        guard analyticsEnabled else { return }
        presetsLoaded += 1
        presetLoadCounts[name, default: 0] += 1
    }
    
    /// Track that a preset was saved (local aggregate count only).
    ///
    /// Historically this ALSO uploaded the preset's name + full JSON to the PUBLIC
    /// CloudKit database on every save — user-authored content, world-readable,
    /// opt-out. That upload is DISABLED pending a real accounts-based community /
    /// sharing feature: publishing user content to a public DB needs actual identity
    /// and explicit per-preset consent, not a silent opt-out telemetry push.
    /// `uploadPresetSnapshot` is retained (unused) so it can be re-wired behind that
    /// feature once accounts exist.
    func trackPresetSaved(preset: FractalPreset) {
        guard analyticsEnabled else { return }
        presetsSaved += 1
    }
    
    // MARK: - Preset Snapshot Upload
    
    /// Upload a saved preset to CloudKit for analysis
    private func uploadPresetSnapshot(_ preset: FractalPreset) async {
        guard analyticsEnabled else { return }
        let record = CKRecord(recordType: "PresetSnapshot")
        
        // Metadata
        record["timestamp"] = Date() as NSDate
        record["presetName"] = preset.name
        
        // Encode full preset as JSON for complete data access
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let jsonData = try? encoder.encode(preset),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            record["presetJSON"] = jsonString
        }
        
        // Device info
        record["deviceModel"] = currentDeviceModel()
        record["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        
        // === Key fields for easy CloudKit querying/filtering ===
        // These let you filter/sort in CloudKit Console without parsing JSON
        
        // Color & style
        record["gradientPreset"] = preset.gradientState?.gradientPreset?.rawValue ?? "custom"
        record["colorSchemeVibrance"] = (preset.colorSchemeVibrance ?? 0.0) as NSNumber
        record["colorSchemeSaturation"] = preset.colorSchemeSaturation as NSNumber
        record["colorSchemeContrast"] = preset.colorSchemeContrast as NSNumber
        
        // Fractal geometry
        record["fractalScale"] = preset.fractalScale as NSNumber
        record["foldingLimit"] = preset.foldingLimit as NSNumber
        record["sphereRadius"] = preset.sphereRadius as NSNumber
        record["minDistance"] = preset.minDistance as NSNumber
        record["fractalIterations"] = preset.fractalIterations as NSNumber
        
        // Effects
        record["glowIntensity"] = (preset.glowEffect?.intensity ?? 0.0) as NSNumber
        record["fogIntensity"] = (preset.fogEffect?.intensity ?? 0.5) as NSNumber
        record["bloomStrength"] = (preset.bloomEffect?.strength ?? 0.0) as NSNumber
        
        // Lighting
        record["lightingMode"] = preset.lightingMode?.displayName ?? "Animated"
        record["hueCycleSpeed"] = (preset.hueRotationEffect?.speed ?? 0.0) as NSNumber
        record["pulseSpeed"] = (preset.pulseEffect?.speed ?? 0.0) as NSNumber
        
        // Position (useful to see if people explore far from origin)
        record["positionX"] = preset.position.x as NSNumber
        record["positionY"] = preset.position.y as NSNumber
        record["positionZ"] = preset.position.z as NSNumber
        
        guard let database = database() else { return }  // CloudKit unavailable — skip
        do {
            _ = try await database.save(record)
        } catch {
            // Could save for retry, but presets are less critical than session data
        }
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
    /// “Submit report”, and it is gated by the existing Community Sharing
    /// preference. The archive contains no formula source.
    func submitPerformanceReport(_ report: PerformanceReport) async -> PerformanceReportSubmissionResult {
        guard analyticsEnabled else { return .sharingDisabled }
        guard let database = database() else { return .unavailable }
        guard let archive = try? PerformanceReportArchive.encode(report) else { return .failed }

        let record = CKRecord(recordType: "PerformanceReport")
        record["timestamp"] = report.capturedAt as NSDate
        record["schemaVersion"] = report.schemaVersion as NSNumber
        record["appVersion"] = report.appVersion
        record["buildNumber"] = report.buildNumber
        record["deviceModel"] = report.deviceModel
        record["osVersion"] = report.osVersion
        record["formulaHash"] = report.activeFormulaHash ?? "built-in"
        record["fps"] = report.render.fps as NSNumber
        record["gpuFrameMs"] = report.render.gpuFrameMs as NSNumber
        record["avgStepsPerPixel"] = report.render.avgStepsPerPixel as NSNumber
        record["metricKitPayloadCount"] = report.metricKit.payloadCount as NSNumber
        record["metricKitDiagnosticCount"] = report.metricKit.diagnosticCount as NSNumber
        record["findingAreas"] = report.findings.map { $0.area.rawValue }.joined(separator: ",")
        // CloudKit stores the compressed archive as a string so the record is
        // self-contained and can be copied into the parser without a file
        // attachment. The bounded MetricKit retention keeps this well below a
        // normal public-record limit.
        record["reportArchiveBase64"] = archive.base64EncodedString()

        do {
            _ = try await database.save(record)
            return .submitted
        } catch {
            return .failed
        }
    }

    private func uploadToCloudKit(_ snapshot: UsageSnapshot) async {
        guard analyticsEnabled else { return }
        let record = CKRecord(recordType: "UsageSnapshot")
        
        // Session info
        record["timestamp"] = snapshot.timestamp as NSDate
        record["sessionDuration"] = snapshot.sessionDuration as NSNumber
        
        // Encode distributions as JSON strings (CloudKit doesn't support nested dicts)
        if let qualityString = jsonString(from: snapshot.qualityDistribution) {
            record["qualityDistribution"] = qualityString
        }
        
        // NOTE: gradientPresetUsageDistribution is intentionally NOT uploaded — it
        // duplicates gradientPresetDistribution (same dt-per-preset accumulation,
        // differing only by a "custom"/"Custom" default) and previously collided on
        // the same "gradientPresetDistribution" record key, silently overwriting it.
        // The authoritative upload is below (snapshot.gradientPresetDistribution).
        // TECH_DEBT #5 — see dedupe #7 to collapse the two accumulators.

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
        if !snapshot.favoritePresetNames.isEmpty {
            record["favoritePresets"] = snapshot.favoritePresetNames
        }
        
        // Performance
        record["avgFPS"] = snapshot.avgFPS as NSNumber
        
        // Device (anonymous)
        record["deviceModel"] = snapshot.deviceModel
        record["osVersion"] = snapshot.osVersion
        record["appVersion"] = snapshot.appVersion
        
        guard let database = database() else { return }  // CloudKit unavailable — skip
        do {
            _ = try await database.save(record)
        } catch {
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
