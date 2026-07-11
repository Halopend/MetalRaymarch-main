import CloudKit
import Foundation
import Testing
@testable import Threshold

@Suite("UsageAnalytics")
struct UsageAnalyticsTests {
    @Test("CloudKit is touched only when entitlement and iCloud identity are both present")
    func cloudKitPrerequisitesRequireEntitlementAndIdentity() {
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: false, ubiquityIdentityToken: nil) == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: false, ubiquityIdentityToken: "token") == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: true, ubiquityIdentityToken: nil) == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: true, ubiquityIdentityToken: "token") == true)
    }

    @Test("Analytics defaults off until the user explicitly opts in")
    func analyticsDefaultsOffWhenUnset() throws {
        let suiteName = "UsageAnalyticsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        #expect(UsageAnalytics.persistedAnalyticsEnabled(in: defaults) == false)

        defaults.set(true, forKey: UsageAnalytics.analyticsEnabledKey)
        #expect(UsageAnalytics.persistedAnalyticsEnabled(in: defaults) == true)

        defaults.set(false, forKey: UsageAnalytics.analyticsEnabledKey)
        #expect(UsageAnalytics.persistedAnalyticsEnabled(in: defaults) == false)
    }

    @MainActor
    @Test("Opting out purges the in-memory window and durable outbox")
    func optingOutPurgesCollectedAnalytics() throws {
        let suiteName = "UsageAnalyticsTests.Purge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: UsageAnalytics.analyticsEnabledKey)

        let analytics = UsageAnalytics(defaults: defaults, automaticallyUploadPending: false)
        analytics.trackPresetLoaded(name: "Never Persist This Name")
        analytics.trackHandGestureUsed()
        defaults.set(Data([0x01, 0x02]), forKey: UsageAnalytics.pendingUploadsKey)

        #expect(!analytics.isCurrentWindowEmpty)
        #expect(defaults.data(forKey: UsageAnalytics.pendingUploadsKey) != nil)

        analytics.analyticsEnabled = false

        #expect(analytics.isCurrentWindowEmpty)
        #expect(defaults.data(forKey: UsageAnalytics.pendingUploadsKey) == nil)
        #expect(UsageAnalytics.persistedAnalyticsEnabled(in: defaults) == false)
    }

    @Test("Outbox record names are deterministic and namespaced")
    func recordNameIsStableAndNamespaced() throws {
        let uploadID = try #require(UUID(uuidString: "BFD2AB7C-EA63-43C5-8F45-708A52B2B002"))
        let expected = "usage-bfd2ab7c-ea63-43c5-8f45-708a52b2b002"

        #expect(UsageAnalytics.recordName(for: uploadID) == expected)
        #expect(UsageAnalytics.recordName(for: uploadID) == expected)
    }

    @Test("Only a matching deterministic-record conflict counts as delivered")
    func matchingRecordConflictIsDelivered() {
        let expected = CKRecord.ID(recordName: "usage-expected")
        let other = CKRecord.ID(recordName: "usage-other")

        #expect(UsageAnalytics.isDeliveredRecordConflict(
            code: .serverRecordChanged,
            serverRecordID: expected,
            expectedRecordID: expected
        ))
        #expect(!UsageAnalytics.isDeliveredRecordConflict(
            code: .serverRecordChanged,
            serverRecordID: other,
            expectedRecordID: expected
        ))
        #expect(!UsageAnalytics.isDeliveredRecordConflict(
            code: .networkUnavailable,
            serverRecordID: expected,
            expectedRecordID: expected
        ))
    }

    @Test("Outbox bounds retain the newest windows")
    func outboxBoundRetainsNewestWindows() {
        let values = Array(0..<13)
        #expect(UsageAnalytics.boundedSuffix(values, limit: 10) == Array(3..<13))
        #expect(UsageAnalytics.boundedSuffix(values, limit: 0).isEmpty)
    }

    @Test("Fractal telemetry uses stable identifiers and masks custom names")
    func fractalTelemetryKeyIsStable() {
        #expect(UsageAnalytics.fractalAnalyticsKey(for: .mandelbulb) == "mandelbulb")
        #expect(UsageAnalytics.fractalAnalyticsKey(for: .custom) == "custom")
    }
}
