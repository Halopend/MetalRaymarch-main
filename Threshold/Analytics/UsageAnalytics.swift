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
//       * dynamicQualityEnabled (Int64)
//       * avgRenderQuality (Double)
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
import UIKit

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
    var dynamicQualityEnabled: Bool
    var avgRenderQuality: Float
    
    // Device info (anonymous)
    var deviceModel: String  // e.g., "RealityDevice14,1"
    var osVersion: String
    var appVersion: String
}

/// Tracks usage patterns and uploads anonymously to CloudKit
@MainActor
class UsageAnalytics: ObservableObject {
    static let shared = UsageAnalytics()
    
    // CloudKit container - uses your app's default container
    private let container = CKContainer.default()
    private var database: CKDatabase { container.publicCloudDatabase }
    
    // Local tracking state
    private var sessionStartTime: Date = Date()
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
    private var renderQualityAccum: Float = 0
    private var sampleCount: Int = 0
    
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
    
    @Published var analyticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(analyticsEnabled, forKey: "AnalyticsEnabled")
        }
    }
    
    private init() {
        // Default to enabled for TestFlight, user can opt out
        self.analyticsEnabled = UserDefaults.standard.object(forKey: "AnalyticsEnabled") as? Bool ?? true
        
        // Try to upload any pending snapshots from previous sessions
        Task {
            await uploadPendingSnapshots()
        }
    }

    private func distributionPercentages(_ source: [String: TimeInterval], duration: TimeInterval) -> [String: Float] {
        let safeDuration = max(duration, 1.0)
        var distribution: [String: Float] = [:]
        distribution.reserveCapacity(source.count)
        for (key, time) in source {
            distribution[key] = Float(time / safeDuration)
        }
        return distribution
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

    private func jsonString<T: Encodable>(from value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func buildSnapshot(dynamicQualityEnabled: Bool) -> UsageSnapshot {
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
            dynamicQualityEnabled: dynamicQualityEnabled,
            avgRenderQuality: renderQualityAccum / durationF,
            deviceModel: currentDeviceModel(),
            osVersion: UIDevice.current.systemVersion,
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
        
        // Clamp delta to avoid huge jumps if app was backgrounded
        let dt = min(deltaTime, 2.0)
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
        renderQualityAccum += settings.currentRenderQuality * dtf
        sampleCount += 1
        
        // Accumulate fractal type distribution
        fractalTypeTimeAccum[geo.fractalType.displayName, default: 0] += dt
        
        // Accumulate gradient preset distribution
        if col.gradientState.useGradientColoring {
            usedGradientColoring = true
            let gradName = col.gradientState.gradientPreset?.rawValue ?? "Custom"
            gradientPresetTimeAccum[gradName, default: 0] += dt
        }
        
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
        usedHandGestures = true
    }
    
    /// Mark that recording was used
    func trackRecordingUsed() {
        usedRecording = true
    }
    
    /// Mark that SharePlay was used
    func trackSharePlayUsed() {
        usedSharePlay = true
    }
    
    /// Mark that animation playback was used
    func trackAnimationUsed() {
        usedAnimation = true
    }
    
    /// Track preset load
    func trackPresetLoaded(name: String) {
        presetsLoaded += 1
        presetLoadCounts[name, default: 0] += 1
    }
    
    /// Track preset save
    func trackPresetSaved() {
        presetsSaved += 1
    }
    
    /// Track preset save with full preset data for analysis
    /// This uploads the complete preset to CloudKit so you can see what users are creating
    func trackPresetSaved(preset: FractalPreset) {
        presetsSaved += 1
        
        guard analyticsEnabled else { return }
        
        Task {
            await uploadPresetSnapshot(preset)
        }
    }
    
    // MARK: - Preset Snapshot Upload
    
    /// Upload a saved preset to CloudKit for analysis
    private func uploadPresetSnapshot(_ preset: FractalPreset) async {
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
        var systemInfo = utsname()
        uname(&systemInfo)
        let deviceModel = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        record["deviceModel"] = deviceModel
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
        
        do {
            let _ = try await database.save(record)
            print("📊 Preset snapshot uploaded: \"\(preset.name)\"")
        } catch {
            print("📊 Preset snapshot upload failed: \(error.localizedDescription)")
            // Could save for retry, but presets are less critical than session data
        }
    }
    
    // MARK: - Snapshot Creation
    
    private func createSnapshot(settings: RenderSettings) -> UsageSnapshot {
        buildSnapshot(dynamicQualityEnabled: settings.dynamicRenderQualityEnabled)
    }
    
    // MARK: - CloudKit Upload
    
    /// Upload current snapshot to CloudKit
    func uploadSnapshot() async {
        guard analyticsEnabled else { return }
        guard totalSessionTime > 10 else { return }  // Don't upload very short sessions
        
        // Get current settings from app model (need to pass in or use shared reference)
        // For now, create a minimal snapshot
        let snapshot = createMinimalSnapshot()
        
        await uploadToCloudKit(snapshot)
    }
    
    /// Create snapshot with current accumulated data
    private func createMinimalSnapshot() -> UsageSnapshot {
        buildSnapshot(dynamicQualityEnabled: true)
    }
    
    private func uploadToCloudKit(_ snapshot: UsageSnapshot) async {
        let record = CKRecord(recordType: "UsageSnapshot")
        
        // Session info
        record["timestamp"] = snapshot.timestamp as NSDate
        record["sessionDuration"] = snapshot.sessionDuration as NSNumber
        
        // Encode distributions as JSON strings (CloudKit doesn't support nested dicts)
        if let qualityString = jsonString(from: snapshot.qualityDistribution) {
            record["qualityDistribution"] = qualityString
        }
        
        if let presetString = jsonString(from: snapshot.gradientPresetUsageDistribution) {
            record["gradientPresetDistribution"] = presetString
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
        if !snapshot.favoritePresetNames.isEmpty {
            record["favoritePresets"] = snapshot.favoritePresetNames
        }
        
        // Performance
        record["avgFPS"] = snapshot.avgFPS as NSNumber
        record["dynamicQualityEnabled"] = snapshot.dynamicQualityEnabled ? 1 : 0
        record["avgRenderQuality"] = snapshot.avgRenderQuality as NSNumber
        
        // Device (anonymous)
        record["deviceModel"] = snapshot.deviceModel
        record["osVersion"] = snapshot.osVersion
        record["appVersion"] = snapshot.appVersion
        
        do {
            let _ = try await database.save(record)
            print("📊 Analytics uploaded successfully")
        } catch {
            print("📊 Analytics upload failed: \(error.localizedDescription)")
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
    
    /// Reset accumulators for new session
    func startNewSession() {
        sessionStartTime = Date()
        lastSampleTime = Date()
        totalSessionTime = 0
        qualityTimeAccum = [:]
        gradientPresetUsageAccum = [:]
        fractalTypeTimeAccum = [:]
        gradientPresetTimeAccum = [:]
        lightingPresetTimeAccum = [:]
        fractalScaleAccum = 0
        foldingLimitAccum = 0
        sphereRadiusAccum = 0
        minDistanceAccum = 0
        colorMixAccum = 0
        glowIntensityAccum = 0
        safetyBubbleRadiusAccum = 0
        bloomStrengthAccum = 0
        fogIntensityAccum = 0
        fpsAccum = 0
        renderQualityAccum = 0
        sampleCount = 0
        usedAudioReactive = false
        usedHandGestures = false
        usedRecording = false
        usedSharePlay = false
        usedGradientColoring = false
        usedAnimation = false
        presetsLoaded = 0
        presetsSaved = 0
        presetLoadCounts = [:]
        lastUploadTime = Date()
    }
}
