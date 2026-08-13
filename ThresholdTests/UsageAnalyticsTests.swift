import Testing
@testable import Threshold

@Suite("UsageAnalytics — CloudKit guard")
struct UsageAnalyticsTests {
    @Test("Authored sharing requires its own explicit consent")
    @MainActor
    func authoredSharingIsSeparateFromAggregateUsage() {
        let analytics = UsageAnalytics.shared
        let oldAggregate = analytics.analyticsEnabled
        let oldDE = analytics.distanceEstimatorSharingEnabled
        let oldScene = analytics.sceneSharingEnabled
        let oldSpecificity = analytics.sharingSpecificity
        defer {
            analytics.analyticsEnabled = oldAggregate
            analytics.distanceEstimatorSharingEnabled = oldDE
            analytics.sceneSharingEnabled = oldScene
            analytics.sharingSpecificity = oldSpecificity
        }

        analytics.analyticsEnabled = true
        analytics.distanceEstimatorSharingEnabled = false
        analytics.sceneSharingEnabled = false
        analytics.sharingSpecificity = .featureWithAttribution
        #expect(!analytics.canShareDistanceEstimator)
        #expect(!analytics.canShareScene)

        analytics.sceneSharingEnabled = true
        #expect(analytics.canShareScene)
        #expect(analytics.canFeatureSharedWork)
    }

    @Test("Sharing specificity explains the three consent levels")
    func sharingSpecificityLevels() {
        #expect(CommunitySharingSpecificity.allCases.count == 3)
        #expect(CommunitySharingSpecificity.aggregateOnly.detail.contains("No work"))
        #expect(CommunitySharingSpecificity.creatorReview.detail.contains("review"))
        #expect(CommunitySharingSpecificity.featureWithAttribution.detail.contains("featured") || CommunitySharingSpecificity.featureWithAttribution.detail.contains("appear"))
    }

    @Test("CloudKit is touched only when entitlement and iCloud identity are both present")
    func cloudKitPrerequisitesRequireEntitlementAndIdentity() {
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: false, ubiquityIdentityToken: nil) == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: false, ubiquityIdentityToken: "token") == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: true, ubiquityIdentityToken: nil) == false)
        #expect(UsageAnalytics.canUseCloudKit(hasEntitlement: true, ubiquityIdentityToken: "token") == true)
    }
}
