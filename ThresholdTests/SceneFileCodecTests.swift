import Foundation
import Testing
@testable import Threshold

struct SceneFileCodecTests {
    private struct Document: Codable, Equatable {
        var name: String
        var values: [Double]
        var createdAt: Date
    }

    @Test func compressedAndLegacyJSONDecodeIdentically() throws {
        let scene = Document(name: "Tweaked scene 🌌", values: Array(repeating: 2.75, count: 4000), createdAt: Date(timeIntervalSince1970: 1234567890))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = try encoder.encode(scene)
        let compressed = try SceneFileCodec.encode(scene, encoder: encoder)
        #expect(SceneFileCodec.isCompressed(compressed))
        #expect(compressed.count < json.count / 2)
        #expect(try SceneFileCodec.jsonData(from: compressed) == json)
        #expect(try SceneFileCodec.decode(Document.self, from: compressed, decoder: decoder) == scene)
        #expect(try SceneFileCodec.decode(Document.self, from: json, decoder: decoder) == scene)
    }

    @Test func smallDocumentsRemainJSON() throws {
        let json = Data("{\"name\":\"A\"}".utf8)
        #expect(try SceneFileCodec.compressJSON(json) == json)
        #expect(!SceneFileCodec.isCompressed(json))
        #expect(try SceneFileCodec.jsonData(from: json) == json)
    }

    @Test func damagedAndTruncatedFilesAreRejected() throws {
        let json = Data(String(repeating: "scene parameters ", count: 10000).utf8)
        let encoded = try SceneFileCodec.compressJSON(json)
        #expect(SceneFileCodec.isCompressed(encoded))
        for length in [8, 47, encoded.count / 2, encoded.count - 1] {
            #expect(throws: (any Error).self) {
                try SceneFileCodec.jsonData(from: Data(encoded.prefix(length)))
            }
        }
        var badDigest = encoded
        badDigest[16] ^= 0xff
        #expect(throws: SceneFileCodec.FileError.self) { try SceneFileCodec.jsonData(from: badDigest) }
        var badPayload = encoded
        badPayload[48] ^= 0xff
        #expect(throws: SceneFileCodec.FileError.self) { try SceneFileCodec.jsonData(from: badPayload) }
    }

    @Test func unsupportedVersionsAndOversizedHeadersAreRejected() throws {
        var encoded = try SceneFileCodec.compressJSON(Data(String(repeating: "x", count: 10000).utf8))
        encoded[7] = Character("2").asciiValue!
        #expect(throws: SceneFileCodec.FileError.self) { try SceneFileCodec.jsonData(from: encoded) }
        encoded[7] = Character("1").asciiValue!
        for index in 8..<16 { encoded[index] = 0xff }
        #expect(throws: SceneFileCodec.FileError.self) { try SceneFileCodec.jsonData(from: encoded) }
    }
    @MainActor
    @Test func sceneExportsPreserveSettingsAndAnimationKeyframes() throws {
        let settings = RenderSettings()
        settings.fractalScale = 3.25
        var preset = FractalPreset.fromSettings(settings, name: "Codec preset \(UUID())")
        preset.tags = ["Compression", "Test"]
        preset.thumbnailData = Data(repeating: 42, count: 4096)
        let presetURL = try #require(PresetManager.exportPresetFile(preset))
        defer { try? FileManager.default.removeItem(at: presetURL) }
        let presetData = try Data(contentsOf: presetURL)
        #expect(SceneFileCodec.isCompressed(presetData))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedPreset = try SceneFileCodec.decode(FractalPreset.self, from: presetData, decoder: decoder)
        #expect(decodedPreset.id == preset.id)
        #expect(decodedPreset.fractalScale == preset.fractalScale)
        #expect(decodedPreset.tags == preset.tags)
        #expect(decodedPreset.thumbnailData == preset.thumbnailData)

        let keyframe = AnimationKeyframe(from: settings)
        var scene = AnimationScene(name: "Codec animation \(UUID())", initialKeyframe: keyframe)
        scene.keyframes.append(keyframe)
        let sceneURL = try #require(AnimationManager.exportSceneFile(scene))
        defer { try? FileManager.default.removeItem(at: sceneURL) }
        let sceneData = try Data(contentsOf: sceneURL)
        #expect(SceneFileCodec.isCompressed(sceneData))
        let decodedScene = try SceneFileCodec.decode(AnimationScene.self, from: sceneData, decoder: decoder)
        #expect(decodedScene.id == scene.id)
        #expect(decodedScene.keyframes == scene.keyframes)
    }

}
