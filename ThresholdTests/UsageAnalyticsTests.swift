import Testing
@testable import Threshold

@Suite("UsageAnalytics — CloudKit guard")
struct UsageAnalyticsTests {
    @Test("CloudKit is touched only when entitlement and iCloud identity are both present")
    func cloudKitPrerequisitesRequireEntitlementAndIdentity() {
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: false, ubiquityIdentityToken: nil) == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: false, ubiquityIdentityToken: "token") == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: true, ubiquityIdentityToken: nil) == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: true, ubiquityIdentityToken: "token") == true)
    }
}
