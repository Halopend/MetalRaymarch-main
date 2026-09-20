//
//  ThresholdExportFormatTests.swift
//  ThresholdTests
//
//  Pins ThresholdExportFormat — the single file-type registry that all
//  `.thresh` / `.threshanim` / `.threshfx` handling routes through (extension
//  lookup, category routing for imports, and import-sheet presentation
//  metadata). The legacy `.threshscene` / `.threshmp` / `.threshanimv`
//  extensions are read-only aliases that must keep resolving to the same
//  formats. Drift here would silently mis-route a file type on import/export,
//  so lock the contract down.
//

import Testing
import Foundation
import SwiftUI
@testable import Threshold

@Suite("ThresholdExportFormat — the single file-type registry")
struct ThresholdExportFormatTests {

    @Test("Every canonical format's extension is unique and round-trips through init?(fileExtension:)")
    func extensionsUniqueAndRoundTrip() {
        var seen = Set<String>()
        for format in ThresholdExportFormat.allCases {
            #expect(seen.insert(format.ext).inserted, "duplicate extension: \(format.ext)")
            #expect(ThresholdExportFormat(fileExtension: format.ext) == format)
        }
    }

    @Test("Canonical extensions are the three consolidated file types")
    func canonicalExtensions() {
        #expect(ThresholdExportFormat.scenePreset.ext == "thresh")
        #expect(ThresholdExportFormat.animationScene.ext == "threshanim")
        #expect(ThresholdExportFormat.customFormula.ext == "threshfx")
        #expect(ThresholdExportFormat.allCases.count == 3)
    }

    @Test("Legacy extensions still resolve to their consolidated format")
    func legacyExtensionsResolve() {
        #expect(ThresholdExportFormat(fileExtension: "threshscene") == .scenePreset)
        #expect(ThresholdExportFormat(fileExtension: ".threshmp") == .scenePreset)
        #expect(ThresholdExportFormat(fileExtension: "thresh") == .scenePreset)
        #expect(ThresholdExportFormat(fileExtension: "THRESHFX") == .customFormula)
        #expect(ThresholdExportFormat(fileExtension: ".ThreshAnim") == .animationScene)
        #expect(ThresholdExportFormat(fileExtension: "threshanimv") == .animationScene)
        #expect(ThresholdExportFormat(fileExtension: "png") == nil)
        #expect(ThresholdExportFormat(fileExtension: "") == nil)
    }

    @Test("category routes each format to the import arm it belongs to")
    func categoryRouting() {
        #expect(ThresholdExportFormat.scenePreset.category == .preset)
        #expect(ThresholdExportFormat.animationScene.category == .animation)
        #expect(ThresholdExportFormat.customFormula.category == .formula)
    }

    @Test("extensions(in:) returns canonical + legacy for scans and prune")
    func extensionsByCategory() {
        #expect(ThresholdExportFormat.extensions(in: .preset) == ["thresh", "threshscene", "threshmp"])
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
