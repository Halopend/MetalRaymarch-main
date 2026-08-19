//
//  StrictJSONDuplicateKeyValidatorTests.swift
//  ThresholdTests
//


import Foundation
import Testing
@testable import Threshold

@Suite("Strict .threshfx JSON duplicate-key validation")
struct StrictJSONDuplicateKeyValidatorTests {

    @Test("Unique keys remain independent at every object scope")
    func acceptsUniqueKeysAndRepeatedKeysInSeparateObjects() throws {
        let json = #"{"left":{"value":1},"right":{"value":2},"array":[{"value":3},{"value":4}]}"#
        try StrictJSONDuplicateKeyValidator.validate(data: Data(json.utf8))
    }

    @Test("A duplicate is rejected at the root and in nested array objects")
    func rejectsDuplicatesAtAnyObjectDepth() {
        expectDuplicate(#"{"version":1,"version":2}"#, key: "version")
        expectDuplicate(#"{"formula":{"params":[{"index":0,"index":1}]}}"#, key: "index")
    }

    @Test("Escaped and literal spellings of the same decoded key collide")
    func rejectsEscapeEquivalentKeys() {
        expectDuplicate(#"{"name":1,"\u006Eame":2}"#, key: "name")
        expectDuplicate(#"{"a/b":1,"a\/b":2}"#, key: "a/b")
        expectDuplicate(#"{"\n":1,"\u000A":2}"#, key: "\n")
        expectDuplicate(#"{"🚀":1,"\uD83D\uDE80":2}"#, key: "🚀")
    }

    @Test("Canonical-equivalent but scalar-distinct member names stay distinct")
    func preservesJSONScalarIdentity() throws {
        // JSON member equality is scalar/code-unit based, not display-oriented
        // Unicode normalization. These are U+00E9 and U+0065 U+0301.
        let json = #"{"\u00E9":1,"e\u0301":2}"#
        try StrictJSONDuplicateKeyValidator.validate(data: Data(json.utf8))
    }

    @Test("String values cannot masquerade as object structure")
    func ignoresJSONLookingContentInsideValues() throws {
        let json = #"{"source":"{\"id\":1,\"id\":2}","id":3}"#
        try StrictJSONDuplicateKeyValidator.validate(data: Data(json.utf8))
    }

    @Test("Malformed JSON syntax is deferred to JSONDecoder")
    func defersOrdinarySyntaxErrors() throws {
        let malformedDocuments = [
            #"{"id":1,"id":}"#,
            #"{"id":"\q","id":2}"#,
            #"{"id":01,"id":2}"#,
            #"{"id":1,"id":2} trailing"#
        ]

        for json in malformedDocuments {
            try StrictJSONDuplicateKeyValidator.validate(data: Data(json.utf8))
        }
    }

    @Test("A leading UTF-8 BOM does not bypass duplicate detection")
    func scansBOMPrefixedJSON() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Data(#"{"id":1,"id":2}"#.utf8))
        expectDuplicate(data, key: "id")
    }

    @Test("Input bytes and nesting depth are explicitly bounded")
    func enforcesResourceBounds() {
        let oversized = Data(
            repeating: 0x20,
            count: StrictJSONDuplicateKeyValidator.maximumInputByteCount + 1
        )
        do {
            try StrictJSONDuplicateKeyValidator.validate(data: oversized)
            Issue.record("Expected the oversized document to be rejected")
        } catch let error as StrictJSONDuplicateKeyValidator.ValidationError {
            guard case .inputTooLarge(let actual, let maximum) = error else {
                Issue.record("Unexpected validation error: \(error)")
                return
            }
            #expect(actual == oversized.count)
            #expect(maximum == StrictJSONDuplicateKeyValidator.maximumInputByteCount)
        } catch {
            Issue.record("Unexpected validation error type: \(error)")
        }

        let depth = StrictJSONDuplicateKeyValidator.maximumNestingDepth + 1
        let deeplyNested = String(repeating: "[", count: depth)
            + "0"
            + String(repeating: "]", count: depth)
        do {
            try StrictJSONDuplicateKeyValidator.validate(data: Data(deeplyNested.utf8))
            Issue.record("Expected excessive nesting to be rejected")
        } catch let error as StrictJSONDuplicateKeyValidator.ValidationError {
            guard case .nestingTooDeep(let maximum, _) = error else {
                Issue.record("Unexpected validation error: \(error)")
                return
            }
            #expect(maximum == StrictJSONDuplicateKeyValidator.maximumNestingDepth)
        } catch {
            Issue.record("Unexpected validation error type: \(error)")
        }
    }

    private func expectDuplicate(_ json: String, key: String) {
        expectDuplicate(Data(json.utf8), key: key)
    }

    private func expectDuplicate(_ data: Data, key: String) {
        do {
            try StrictJSONDuplicateKeyValidator.validate(data: data)
            Issue.record("Expected duplicate key \(String(reflecting: key)) to be rejected")
        } catch let error as StrictJSONDuplicateKeyValidator.ValidationError {
            guard case .duplicateKey(let actualKey, let byteOffset) = error else {
                Issue.record("Unexpected validation error: \(error)")
                return
            }
            #expect(actualKey == key)
            #expect(byteOffset >= 0)
        } catch {
            Issue.record("Unexpected validation error type: \(error)")
        }
    }
}
