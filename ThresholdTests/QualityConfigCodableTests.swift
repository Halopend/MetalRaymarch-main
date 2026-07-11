import Foundation
import Testing
@testable import Threshold

@Suite("QualityConfig Codable")
struct QualityConfigCodableTests {
    @Test("base settings survive encode and decode")
    func baseSettingsRoundTrip() throws {
        var config = QualityConfig()
        config.baseMaxRaySteps = 96
        let decoded = try JSONDecoder().decode(QualityConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.baseMaxRaySteps == 96)
    }

    @Test("Glassy Intersect survives Codable and is a valid clamp endpoint")
    func glassyIntersectRoundTripAndClamp() throws {
        var config = QualityConfig()
        config.boundingShapeFogMode = BoundingFogMode.glassyIntersect.rawValue

        var decoded = try JSONDecoder().decode(
            QualityConfig.self,
            from: JSONEncoder().encode(config)
        )
        #expect(decoded.boundingShapeFogMode == BoundingFogMode.glassyIntersect.rawValue)

        decoded.clamp()
        #expect(decoded.boundingShapeFogMode == BoundingFogMode.glassyIntersect.rawValue)

        decoded.boundingShapeFogMode = 99
        decoded.clamp()
        #expect(decoded.boundingShapeFogMode == BoundingFogMode.glassyIntersect.rawValue)
    }
}
