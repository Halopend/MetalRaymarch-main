import Testing
import simd
@testable import Threshold

@Suite("Gradient color maps")
struct GradientColorMapTests {
    @Test("Initializer sorts stops and clamps stop positions")
    func initializerSortsStopsAndClampsPositions() {
        let gradient = GradientColorMap(
            name: "Test",
            stops: [
                GradientStop(position: 1.5, r: 1, g: 0, b: 0),
                GradientStop(position: -0.5, r: 0, g: 0, b: 1),
                GradientStop(position: 0.5, r: 0, g: 1, b: 0)
            ]
        )

        #expect(gradient.stops.map(\.position) == [0, 0.5, 1])
    }

    @Test("Evaluation interpolates between neighboring stops")
    func evaluationInterpolatesBetweenNeighboringStops() {
        let gradient = GradientColorMap(
            name: "Linear",
            stops: [
                GradientStop(position: 0, color: SIMD3<Float>(0, 0, 0)),
                GradientStop(position: 1, color: SIMD3<Float>(1, 1, 1))
            ],
            smoothing: 0
        )

        #expect(gradient.evaluate(at: 0.25) == SIMD3<Float>(repeating: 0.25))
        #expect(gradient.evaluate(at: 0.75) == SIMD3<Float>(repeating: 0.75))
    }

    @Test("Shader export is capped and position-packed")
    func shaderStopsAreCappedAndPositionPacked() {
        var stops: [GradientStop] = []
        for index in 0..<10 {
            let position = Float(index) / 9
            let color = SIMD3<Float>(Float(index), Float(index + 1), Float(index + 2))
            stops.append(
                GradientStop(
                position: Float(index) / 9,
                    color: color
                )
            )
        }
        let gradient = GradientColorMap(name: "Packed", stops: stops)
        let shaderStops = gradient.toShaderStops()

        #expect(shaderStops.count == 8)
        #expect(shaderStops.colors.count == 8)
        #expect(shaderStops.colors[0].w == 0)
        #expect(shaderStops.colors[7].w == Float(7) / 9)
    }
}
