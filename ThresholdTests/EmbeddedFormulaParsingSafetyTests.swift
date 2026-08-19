//
//  EmbeddedFormulaParsingSafetyTests.swift
//  ThresholdTests
//
//  Adversarial coverage for the standalone .threshfx trust boundary.
//


import Foundation
import Testing
@testable import Threshold

@Suite("Safe .threshfx parsing")
struct EmbeddedFormulaParsingSafetyTests {

    private static func spaceWarp(
        schemaVersion: Int = 1,
        id: String = "test.safe-space-warp",
        name: String = "Safe Space Warp",
        metalPrefix: String = ""
    ) -> EmbeddedFormula {
        EmbeddedFormula(
            schemaVersion: schemaVersion,
            kind: .spaceWarp,
            id: id,
            name: name,
            functionStem: "SafeSpaceWarp",
            metalSource: """
            \(metalPrefix)
            FORCE_INLINE float3 customSpaceWarp(
                float3 p, float strength, float param1, float param2, float param3
            ) {
                return p + float3(param1, param2, param3) * strength;
            }
            FORCE_INLINE float customSpaceWarpDEScale(
                float3 p, float strength, float param1, float param2, float param3
            ) {
                (void)p; (void)param1; (void)param2; (void)param3;
                return 1.0f + abs(strength);
            }
            """,
            params: []
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Threshold-ParseSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expectContainerError(
        _ expected: EmbeddedFormulaContainer.ValidationError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected container validation error \(expected)")
        } catch let error as EmbeddedFormulaContainer.ValidationError {
            #expect(error == expected)
            #expect(!error.localizedDescription.isEmpty)
            #expect(error.localizedDescription == error.description)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Container and formula versions fail closed")
    func versionsFailClosed() throws {
        for version in [-1, 0, 2] {
            let directory = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("version-\(version).threshfx")
            let container = EmbeddedFormulaContainer(
                formula: Self.spaceWarp(),
                version: version
            )
            // Bypass the production encoder so an intentionally invalid
            // version reaches the disk decoder.
            try JSONEncoder().encode(container).write(to: url, options: .atomic)
            expectContainerError(.unsupportedVersion(version)) {
                _ = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
            }
        }

        for version in [-1, 0, 2] {
            let formula = Self.spaceWarp(schemaVersion: version)
            do {
                try formula.validate()
                Issue.record("Expected formula schema version \(version) to be rejected")
            } catch let error as EmbeddedFormula.ValidationError {
                #expect(error == .unsupportedSchemaVersion(version))
                #expect(error.localizedDescription == error.description)
            }
        }
    }

    @Test("Reads are bounded before JSON decoding")
    func oversizedFileIsRejected() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversized.threshfx")
        let size = EmbeddedFormulaContainer.maxContainerBytes + 1
        try Data(repeating: 0x20, count: size).write(to: url, options: .atomic)

        expectContainerError(.fileTooLarge(size)) {
            _ = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
        }
    }

    @Test("Only local regular files are accepted")
    func fileTypePolicy() throws {
        expectContainerError(.nonFileURL) {
            _ = try EmbeddedFormulaContainer.decode(
                fromContainerAt: URL(string: "https://example.invalid/effect.threshfx")!
            )
        }

        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        expectContainerError(.notRegularFile) {
            _ = try EmbeddedFormulaContainer.decode(fromContainerAt: directory)
        }

        let target = directory.appendingPathComponent("target.threshfx")
        try EmbeddedFormulaContainer(formula: Self.spaceWarp()).encode()
            .write(to: target, options: .atomic)
        let link = directory.appendingPathComponent("linked.threshfx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        expectContainerError(.symbolicLinkNotAllowed) {
            _ = try EmbeddedFormulaContainer.decode(fromContainerAt: link)
        }
    }

    @Test("Metadata cannot escape generated Metal comments")
    func metadataControlsAreRejectedAndNotSynthesized() throws {
        for formula in [
            Self.spaceWarp(id: "safe\n#define INJECTED 1"),
            Self.spaceWarp(name: "Safe\rcustomSpaceWarp(float3(0), 1, 2, 3, 4)")
        ] {
            do {
                try formula.validate()
                Issue.record("Expected control-bearing metadata to be rejected")
            } catch let error as EmbeddedFormula.ValidationError {
                guard case .metadataContainsControlCharacters = error else {
                    Issue.record("Unexpected validation error: \(error)")
                    continue
                }
            }
        }

        let valid = Self.spaceWarp(
            id: "metadata-marker-id",
            name: "metadata-marker-name"
        )
        let synthesized = try CustomShaderCompiler.synthesizeSource(
            fractal: nil,
            spaceWarp: valid
        )
        #expect(!synthesized.contains("metadata-marker-id"))
        #expect(!synthesized.contains("metadata-marker-name"))
        #expect(synthesized.contains(valid.sourceHash))
    }

    @Test("External source cannot use the preprocessor or module imports")
    func preprocessorSyntaxIsRejected() {
        for prefix in [
            "# include <metal_stdlib>",
            "#\tdefine HOST_POISON 1",
            "/* disguised */ # import <metal_stdlib>",
            "@ import Metal"
        ] {
            let formula = Self.spaceWarp(metalPrefix: prefix)
            do {
                try formula.validate()
                Issue.record("Expected forbidden source syntax to be rejected: \(prefix)")
            } catch let error as EmbeddedFormula.ValidationError {
                guard case .forbiddenToken = error else {
                    Issue.record("Unexpected validation error: \(error)")
                    continue
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Runtime shader identities retain cryptographic collision resistance")
    func fullSourceHashBacksCompilerCacheIdentity() {
        let formula = Self.spaceWarp()
        let key = CustomShaderCompiler.combinedHash(
            fractal: nil,
            spaceWarp: formula
        )
        #expect(formula.sourceHash.count == 64)
        #expect(formula.shortHash.count == 32)
        #expect(key.contains(formula.sourceHash))
    }
}
