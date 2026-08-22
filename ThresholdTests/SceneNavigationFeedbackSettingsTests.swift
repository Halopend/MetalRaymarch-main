import Testing
@testable import Threshold

struct SceneNavigationFeedbackSettingsTests {
    @Test("Scene switcher feedback panel defaults to visible")
    func defaultsToVisible() {
        #expect(SceneNavigationFeedbackSettings.defaultValue)
        #expect(!SceneNavigationFeedbackSettings.defaultsKey.isEmpty)
    }
}
