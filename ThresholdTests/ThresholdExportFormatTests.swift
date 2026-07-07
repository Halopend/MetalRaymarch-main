//
//  ThresholdExportFormatTests.swift
//  ThresholdTests
//
//  Pins ThresholdExportFormat — the single file-type registry that all
//  .threshscene/.threshmp/.threshanim/.threshanimv/.threshfx handling routes
//  through (extension lookup, preset/animation format choice, category routing
//  for imports, and import-sheet presentation metadata). Drift here would
//  silently mis-route a file type on import/export, so lock the contract down.
//

import Testing
import Foundation
import SwiftUI
@testable import Threshold

@Suite("ThresholdExportFormat — the single file-type registry")
struct ThresholdExportFormatTests {

    @Test("Every format's extension is unique and round-trips through init?(fileExtension:)")
    func extensionsUniqueAndRoundTrip() {
        var seen = Set<String>()
        for format in ThresholdExportFormat.allCases {
            #expect(seen.insert(format.ext).inserted, "duplicate extension: \(format.ext)")
            #expect(ThresholdExportFormat(fileExtension: format.ext) == format)
        }
    }

    @Test("init?(fileExtension:) tolerates a leading dot and any case, rejects unknown")
    func fileExtensionParsing() {
        #expect(ThresholdExportFormat(fileExtension: "threshscene") == .scenePreset)
        #expect(ThresholdExportFormat(fileExtension: ".threshmp") == .musicPreset)
        #expect(ThresholdExportFormat(fileExtension: "THRESHFX") == .customFormula)
        #expect(ThresholdExportFormat(fileExtension: ".ThreshAnim") == .animationScene)
        #expect(ThresholdExportFormat(fileExtension: "threshanimv") == .musicVideoScene)
        #expect(ThresholdExportFormat(fileExtension: "png") == nil)
        #expect(ThresholdExportFormat(fileExtension: "") == nil)
    }

    @Test("preset(hasMusic:) / animation(hasSong:) pick the right format")
    func presetAndAnimationChoice() {
        #expect(ThresholdExportFormat.preset(hasMusic: true) == .musicPreset)
        #expect(ThresholdExportFormat.preset(hasMusic: false) == .scenePreset)
        #expect(ThresholdExportFormat.animation(hasSong: true) == .musicVideoScene)
        #expect(ThresholdExportFormat.animation(hasSong: false) == .animationScene)
    }

    @Test("category routes each format to the import arm it belongs to")
    func categoryRouting() {
        #expect(ThresholdExportFormat.scenePreset.category == .preset)
        #expect(ThresholdExportFormat.musicPreset.category == .preset)
        #expect(ThresholdExportFormat.animationScene.category == .animation)
        #expect(ThresholdExportFormat.musicVideoScene.category == .animation)
        #expect(ThresholdExportFormat.customFormula.category == .formula)
    }

    @Test("extensions(in:) groups by category in declaration order")
    func extensionsByCategory() {
        #expect(ThresholdExportFormat.extensions(in: .preset) == ["threshscene", "threshmp"])
        #expect(ThresholdExportFormat.extensions(in: .animation) == ["threshanim", "threshanimv"])
        #expect(ThresholdExportFormat.extensions(in: .formula) == ["threshfx"])
    }

    @Test("Every format exposes non-empty presentation metadata")
    func presentationMetadata() {
        for format in ThresholdExportFormat.allCases {
            #expect(!format.displayName.isEmpty)
            #expect(!format.iconName.isEmpty)
            #expect(!format.summary.isEmpty)
            _ = format.accentColor  // reachable + typechecks (SwiftUI Color)
        }
    }
}
