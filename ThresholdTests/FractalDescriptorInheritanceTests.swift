import Foundation
import simd
import Testing
@testable import Threshold

@Suite("Fractal descriptor inheritance")
struct FractalDescriptorInheritanceTests {
    private let familyTypes: [FractalModelType] = [
        .mandelbulb,
        .mandelbulbJulia,
        .boxFoldMandelbulb,
    ]

    @Test("registry identity is derived from the model type")
    func registryIdentity() {
        for type in FractalModelType.allCases {
            let descriptor = type.descriptor
            #expect(descriptor.type == type)
            #expect(descriptor.rawValue == type.rawValue)
        }
    }

    @Test("Mandelbulb family inherits one quality policy")
    func familyQualityPolicy() {
        let expected: [(QualityPreset, Int, Int)] = [
            (.low, 4, 68),
            (.medium, 6, 88),
            (.high, 8, 97),
            (.ultra, 10, 102),
        ]

        for type in familyTypes {
            #expect(type.descriptor is MandelbulbFamilyDescriptor)
            for (preset, iterations, raySteps) in expected {
                guard let values = type.descriptor.qualityValues(for: preset) else {
                    Issue.record("Missing \(preset) quality policy for \(type)")
                    continue
                }
                #expect(values.fractalIterations == iterations)
                #expect(values.raySteps == raySteps)
            }
        }
    }

    @Test("Mandelbulb family inherits capabilities and gesture bindings")
    func familyCapabilities() {
        let expectedSlots = [
            GestureSlot(hand: .left, finger: .middle),
            GestureSlot(hand: .left, finger: .index),
        ]

        for type in familyTypes {
            let descriptor = type.descriptor
            #expect(descriptor.supportedEffectTags.contains(.polarRotation))
            #expect(descriptor.grabScaleClamp == (0.0005...2000.0))
            #expect(descriptor.defaultScalarBindings.map { $0.slot } == expectedSlots)
            #expect(
                descriptor.defaultScalarBindings.map { $0.paramName }
                    == ["PolarRotation", "Power"]
            )
            #expect(descriptor.defaultViewState.detailScale == 0.25)
            #expect(descriptor.defaultViewState.safetyBubbleEnabled == false)
        }

        #expect(!FractalModelType.mandelbulb.supports(.juliaDrift))
        #expect(FractalModelType.mandelbulbJulia.supports(.juliaDrift))
        #expect(!FractalModelType.boxFoldMandelbulb.supports(.juliaDrift))
        #expect(
            FractalModelType.mandelbulb.descriptor.defaultViewState.position
                == SIMD3<Float>(0.1, 0.1, -0.9)
        )
        #expect(
            FractalModelType.mandelbulbJulia.descriptor.defaultViewState.position
                == SIMD3<Float>(0.1, 0.1, -1.45)
        )
    }

    @Test("Mandelbulb family applies polar rotation only to its shared slot")
    func familyPolarRotation() {
        for type in familyTypes {
            var params = FractalTypeDescriptor.baseFormulaParams()
            for index in 0..<16 {
                FormulaCatalog.setParam(&params, index: index, value: Float(index + 1))
            }
            let before = (0..<16).map {
                FormulaCatalog.getParam(params, index: $0)
            }

            type.descriptor.applyPolarRotation(into: &params, accum: 0.375)

            for index in 0..<16 {
                let actual = FormulaCatalog.getParam(params, index: index)
                let expected = before[index] + (index == 4 ? 0.375 : 0)
                #expect(abs(actual - expected) < 0.000_001)
            }
        }
    }
}
