//
//  ExampleSceneDecodeTests.swift
//  ThresholdTests
//
//  End-to-end guard for the EXTERNAL scene-loading pipeline: every shipped
//  example file (.threshscene / .threshmp / .threshanim / .threshfx) must
//  decode through the SAME decoders the app uses when a user opens one of these
//  files from Finder / Files / drag-drop (AppModel.openExternalFile ->
//  PresetManager.decodePreset / AnimationManager.decodeScene /
//  EmbeddedFormulaContainer.decode).
//
//  Why this exists: the production decoders use `.iso8601` date strategy and the
//  example files store dates as ISO8601 strings; `createdAt` is a *required*
//  field on FractalPreset. A decoder-strategy drift, a renamed/removed required
//  key, or a malformed example file would silently break "open scene from
//  Finder" with no compile-time signal. This test reproduces the exact decode
//  the app performs, over the real shipped assets, headlessly.
//

import Testing
import Foundation
@testable import Threshold

@Suite("External scene loading — every example file decodes through the production path")
struct ExampleSceneDecodeTests {

    /// Repo `Threshold/Examples` directory, located relative to this test's
    /// source file so the test is independent of bundle-resource packaging.
    private static var examplesDir: URL {
        // .../ThresholdTests/ExampleSceneDecodeTests.swift -> repo root -> Threshold/Examples
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Threshold/Examples")
    }

    private static func files(withExtension ext: String, in subdir: String) -> [URL] {
        let dir = examplesDir.appendingPathComponent(subdir)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Mirrors PresetManager.presetDecoder / AnimationManager.sceneDecoder.
    private static func iso8601Decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test("Examples directory is present and non-empty")
    func examplesDirectoryExists() {
        let scenes = Self.files(withExtension: "threshscene", in: "Scenes")
        let music = Self.files(withExtension: "threshmp", in: "Scenes")
        let anims = Self.files(withExtension: "threshanim", in: "Animations")
        let fx = Self.files(withExtension: "threshfx", in: "Scenes")
        #expect(!scenes.isEmpty, "no .threshscene example files found at \(Self.examplesDir.path)")
        #expect(!music.isEmpty, "no .threshmp example files found")
        #expect(!anims.isEmpty, "no .threshanim example files found")
        #expect(!fx.isEmpty, "no .threshfx example files found")
    }

    @Test("Every .threshscene decodes as a FractalPreset (the .onOpenURL preset path)")
    func threshscenesDecode() throws {
        let decoder = Self.iso8601Decoder()
        let files = Self.files(withExtension: "threshscene", in: "Scenes")
        for url in files {
            let data = try Data(contentsOf: url)
            #expect(throws: Never.self, "FAILED to decode \(url.lastPathComponent)") {
                _ = try decoder.decode(FractalPreset.self, from: data)
            }
        }
    }

    @Test("Every .threshmp decodes as a FractalPreset (music-preset path)")
    func threshmpsDecode() throws {
        let decoder = Self.iso8601Decoder()
        let files = Self.files(withExtension: "threshmp", in: "Scenes")
        for url in files {
            let data = try Data(contentsOf: url)
            #expect(throws: Never.self, "FAILED to decode \(url.lastPathComponent)") {
                _ = try decoder.decode(FractalPreset.self, from: data)
            }
        }
    }

    @Test("Every .threshanim decodes as an AnimationScene (animation import path)")
    func threshanimsDecode() throws {
        let decoder = Self.iso8601Decoder()
        let files = Self.files(withExtension: "threshanim", in: "Animations")
        for url in files {
            let data = try Data(contentsOf: url)
            #expect(throws: Never.self, "FAILED to decode \(url.lastPathComponent)") {
                _ = try decoder.decode(AnimationScene.self, from: data)
            }
        }
    }

    @Test("Every .threshfx decodes + validates as an EmbeddedFormulaContainer (custom-formula path)")
    func threshfxDecode() throws {
        let files = Self.files(withExtension: "threshfx", in: "Scenes")
        for url in files {
            #expect(throws: Never.self, "FAILED to decode/validate \(url.lastPathComponent)") {
                _ = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
            }
        }
    }
}
