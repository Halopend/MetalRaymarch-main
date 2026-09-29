//
//  EffectPickerCatalogTests.swift
//  ThresholdTests
//
//  Pins the effects-picker provenance contract: reusable rows come from the
//  `.threshfx` library only, grouped by effect kind, and a scene-embedded
//  payload is never advertised as reusable (see CONTENT_MODEL_PROPOSAL.md §2.7).
//

import Foundation
import Testing
@testable import Threshold

@Suite("Effect picker — library vs embedded provenance")
struct EffectPickerCatalogTests {

    // MARK: Fixtures

    private func formula(_ name: String, kind: EffectKind = .fractal, stem: String) -> EmbeddedFormula {
        EmbeddedFormula(
            kind: kind,
            id: "test.\(stem.lowercased())",
            name: name,
            functionStem: stem,
            metalSource: "// \(stem)",
            params: []
        )
    }

    private func libraryEntry(_ name: String, kind: EffectKind = .fractal, stem: String) -> FormulaLibraryEntry {
        FormulaLibraryEntry(
            url: URL(fileURLWithPath: "/tmp/effects/\(stem).threshfx"),
            formula: formula(name, kind: kind, stem: stem)
        )
    }

    // MARK: Reusable rows come from the library

    @Test("Library entries become reusable rows tagged as library")
    func libraryEntriesBecomeReusableRows() {
        let rows = EffectPickerCatalog.libraryEntries([
            libraryEntry("Beta", stem: "Beta"),
            libraryEntry("Alpha", stem: "Alpha"),
        ])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.isLibrary })
        #expect(rows.allSatisfy { $0.provenanceLabel == "Library" })
        #expect(rows.allSatisfy { $0.provenanceIcon == EffectKind.fractal.icon })
    }

    @Test("A space warp wears its own icon, not the DE glyph")
    func spaceWarpIcon() {
        let rows = EffectPickerCatalog.libraryEntries([
            libraryEntry("Twist", kind: .spaceWarp, stem: "Twist")
        ])
        #expect(rows.first?.provenanceIcon == EffectKind.spaceWarp.icon)
        #expect(EffectKind.spaceWarp.icon != EffectKind.fractal.icon)
    }

    // MARK: Grouping

    @Test("Sections group by effect kind with a stable order and name sort")
    func sectionsGroupByKind() {
        let rows = EffectPickerCatalog.libraryEntries([
            libraryEntry("Zeta Warp", kind: .spaceWarp, stem: "Zeta"),
            libraryEntry("Beta DE", kind: .fractal, stem: "Beta"),
            libraryEntry("Alpha DE", kind: .fractal, stem: "Alpha"),
        ])
        let sections = EffectPickerCatalog.sections(rows)

        #expect(sections.map(\.kind) == [.fractal, .spaceWarp])
        #expect(sections.first?.title == "Distance Estimators")
        #expect(sections.first?.entries.map(\.formula.name) == ["Alpha DE", "Beta DE"])
        #expect(sections.last?.entries.map(\.formula.name) == ["Zeta Warp"])
        #expect(sections.last?.title == "Space Warps")
    }

    @Test("Sections omit kinds with no entries, and an empty catalog is empty")
    func sectionsOmitEmptyKinds() {
        let sections = EffectPickerCatalog.sections(
            EffectPickerCatalog.libraryEntries([libraryEntry("Only DE", stem: "Only")])
        )
        #expect(sections.map(\.kind) == [.fractal])
        #expect(EffectPickerCatalog.sections([]).isEmpty)
    }

    // MARK: Provenance

    @Test("An active hash absent from the library is embedded-only")
    func embeddedOnlyDetection() {
        let libraryHashes: Set<String> = ["abc123"]
        #expect(EffectPickerCatalog.isEmbeddedOnly(hash: "deadbeef", libraryHashes: libraryHashes))
        #expect(!EffectPickerCatalog.isEmbeddedOnly(hash: "abc123", libraryHashes: libraryHashes))
        #expect(
            !EffectPickerCatalog.isEmbeddedOnly(hash: nil, libraryHashes: libraryHashes),
            "no active custom effect is not 'embedded'"
        )
    }

    @Test("The reusable catalog never fabricates rows without library files")
    func reusableCatalogIsLibraryOnly() {
        #expect(EffectPickerCatalog.libraryEntries([]).isEmpty)
    }

    // MARK: Kind metadata (the extension point)

    @Test("Every effect kind exposes library presentation metadata")
    func effectKindMetadata() {
        for kind in EffectKind.libraryOrder {
            #expect(!kind.librarySectionTitle.isEmpty)
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.icon.isEmpty)
        }
        #expect(
            Set(EffectKind.libraryOrder).count == EffectKind.libraryOrder.count,
            "the library display order must not repeat a kind"
        )
    }
}
