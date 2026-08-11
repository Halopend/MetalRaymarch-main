//
//  StrictJSONDuplicateKeyValidator.swift
//  Threshold
//
//  JSONDecoder accepts duplicate object members and silently chooses one value.
//  That is unsafe for externally supplied .threshfx documents: validation could
//  reason about a different apparent value than a human reviewing the file.
//


import Foundation

/// A bounded, non-materializing preflight for duplicate JSON object keys.
///
/// The scanner implements enough of the JSON grammar to identify object-member
/// boundaries without treating strings that happen to contain JSON punctuation
/// as structure. It deliberately does not report ordinary syntax errors;
/// `JSONDecoder` remains the authority for those. A duplicate is reported only
/// after the entire document was structurally and lexically valid JSON.
///
/// Key identity is the decoded Unicode scalar sequence, represented as canonical
/// UTF-8 bytes. Consequently `"name"` and `"\u006Eame"` collide, while two
/// canonically equivalent but scalar-distinct spellings remain distinct as JSON
/// member names. Each object owns its own key set, as required by JSON semantics.
enum StrictJSONDuplicateKeyValidator {

    enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
        case inputTooLarge(actualBytes: Int, maximumBytes: Int)
        case nestingTooDeep(maximumDepth: Int, byteOffset: Int)
        case duplicateKey(String, byteOffset: Int)

        var description: String {
            switch self {
            case .inputTooLarge(let actualBytes, let maximumBytes):
                return "The JSON document is too large (\(actualBytes) bytes; max \(maximumBytes))."
            case .nestingTooDeep(let maximumDepth, let byteOffset):
                return "The JSON document exceeds the maximum nesting depth of \(maximumDepth) near byte \(byteOffset)."
            case .duplicateKey(let key, let byteOffset):
                let prefix = String(key.prefix(80))
                let suffix = key.count > prefix.count ? "…" : ""
                return "The JSON document contains duplicate object key \(String(reflecting: prefix + suffix)) near byte \(byteOffset)."
            }
        }

        var errorDescription: String? { description }
    }

    /// Keep this aligned with the bounded `.threshfx` file reader. The check is
    /// repeated here so direct callers cannot accidentally bypass the envelope.
    static let maximumInputByteCount = EmbeddedFormulaContainer.maxContainerBytes

    /// Recursion is explicitly capped before descending, bounding both stack use
    /// and the number of simultaneously live per-object key sets.
    static let maximumNestingDepth = 128

    static func validate(data: Data) throws {
        guard data.count <= maximumInputByteCount else {
            throw ValidationError.inputTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumInputByteCount
            )
        }

        var scanner = Scanner(bytes: [UInt8](data))
        try scanner.validate()
    }

    private struct Duplicate {
        let key: String
        let byteOffset: Int
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var firstDuplicate: Duplicate?

        mutating func validate() throws {
            // Foundation accepts a leading UTF-8 BOM, so scan through it as well
            // rather than leaving a duplicate-key bypass for BOM-prefixed files.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                index = 3
            }

            skipWhitespace()
            guard try scanValue(containerDepth: 0) else {
                return
            }
            skipWhitespace()

            // Malformed/trailing input belongs to JSONDecoder. Only surface a
            // duplicate once this preflight consumed one complete JSON value.
            guard index == bytes.count, let duplicate = firstDuplicate else {
                return
            }
            throw ValidationError.duplicateKey(
                duplicate.key,
                byteOffset: duplicate.byteOffset
            )
        }

        private mutating func scanValue(containerDepth: Int) throws -> Bool {
            skipWhitespace()
            guard let byte = currentByte else { return false }

            switch byte {
            case Byte.leftBrace:
                let depth = containerDepth + 1
                try checkDepth(depth)
                return try scanObject(depth: depth)
            case Byte.leftBracket:
                let depth = containerDepth + 1
                try checkDepth(depth)
                return try scanArray(depth: depth)
            case Byte.quote:
                return scanJSONString() != nil
            case Byte.t:
                return scanLiteral([Byte.t, Byte.r, Byte.u, Byte.e])
            case Byte.f:
                return scanLiteral([Byte.f, Byte.lowerA, Byte.l, Byte.s, Byte.e])
            case Byte.n:
                return scanLiteral([Byte.n, Byte.u, Byte.l, Byte.l])
            case Byte.minus, Byte.zero ... Byte.nine:
                return scanNumber()
            default:
                return false
            }
        }

        private mutating func scanObject(depth: Int) throws -> Bool {
            index += 1 // {
            skipWhitespace()
            if consume(Byte.rightBrace) { return true }

            var seenKeys = Set<Data>()
            while true {
                skipWhitespace()
                let keyOffset = index
                guard currentByte == Byte.quote,
                      let decodedKey = scanJSONString()
                else { return false }

                let keyIdentity = Data(decodedKey)
                if !seenKeys.insert(keyIdentity).inserted, firstDuplicate == nil {
                    // scanJSONString has already verified that these are valid
                    // UTF-8 bytes, so this conversion cannot repair or conflate.
                    firstDuplicate = Duplicate(
                        key: String(decoding: decodedKey, as: UTF8.self),
                        byteOffset: keyOffset
                    )
                }

                skipWhitespace()
                guard consume(Byte.colon) else { return false }
                guard try scanValue(containerDepth: depth) else { return false }
                skipWhitespace()

                if consume(Byte.rightBrace) { return true }
                guard consume(Byte.comma) else { return false }
            }
        }

        private mutating func scanArray(depth: Int) throws -> Bool {
            index += 1 // [
            skipWhitespace()
            if consume(Byte.rightBracket) { return true }

            while true {
                guard try scanValue(containerDepth: depth) else { return false }
                skipWhitespace()

                if consume(Byte.rightBracket) { return true }
                guard consume(Byte.comma) else { return false }
            }
        }

        /// Consumes and decodes one JSON string to its exact UTF-8 scalar bytes.
        /// Returning `nil` defers malformed string diagnostics to JSONDecoder.
        private mutating func scanJSONString() -> [UInt8]? {
            guard consume(Byte.quote) else { return nil }

            var decoded: [UInt8] = []
            decoded.reserveCapacity(min(bytes.count - index, 256))

            while let byte = currentByte {
                index += 1
                switch byte {
                case Byte.quote:
                    guard String(bytes: decoded, encoding: .utf8) != nil else {
                        return nil
                    }
                    return decoded

                case Byte.backslash:
                    guard let escape = currentByte else { return nil }
                    index += 1
                    switch escape {
                    case Byte.quote, Byte.backslash, Byte.slash:
                        decoded.append(escape)
                    case Byte.b:
                        decoded.append(0x08)
                    case Byte.f:
                        decoded.append(0x0C)
                    case Byte.n:
                        decoded.append(0x0A)
                    case Byte.r:
                        decoded.append(0x0D)
                    case Byte.t:
                        decoded.append(0x09)
                    case Byte.u:
                        guard let firstCodeUnit = scanHexCodeUnit() else { return nil }
                        let scalarValue: UInt32

                        if (0xD800 ... 0xDBFF).contains(firstCodeUnit) {
                            guard consume(Byte.backslash), consume(Byte.u),
                                  let secondCodeUnit = scanHexCodeUnit(),
                                  (0xDC00 ... 0xDFFF).contains(secondCodeUnit)
                            else { return nil }
                            scalarValue = 0x10000
                                + (UInt32(firstCodeUnit - 0xD800) << 10)
                                + UInt32(secondCodeUnit - 0xDC00)
                        } else {
                            guard !(0xDC00 ... 0xDFFF).contains(firstCodeUnit) else {
                                return nil
                            }
                            scalarValue = UInt32(firstCodeUnit)
                        }

                        guard let scalar = UnicodeScalar(scalarValue) else { return nil }
                        decoded.append(contentsOf: String(scalar).utf8)
                    default:
                        return nil
                    }

                case 0x00 ... 0x1F:
                    return nil

                default:
                    decoded.append(byte)
                }
            }
            return nil
        }

        private mutating func scanHexCodeUnit() -> UInt16? {
            guard index <= bytes.count - 4 else { return nil }
            var value: UInt16 = 0
            for _ in 0 ..< 4 {
                guard let nibble = hexNibble(bytes[index]) else { return nil }
                value = (value << 4) | UInt16(nibble)
                index += 1
            }
            return value
        }

        private func hexNibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case Byte.zero ... Byte.nine:
                return byte - Byte.zero
            case Byte.upperA ... Byte.upperF:
                return byte - Byte.upperA + 10
            case Byte.lowerA ... Byte.f:
                return byte - Byte.lowerA + 10
            default:
                return nil
            }
        }

        private mutating func scanLiteral(_ literal: [UInt8]) -> Bool {
            guard index + literal.count <= bytes.count,
                  bytes[index ..< index + literal.count].elementsEqual(literal)
            else { return false }

            index += literal.count
            return isAtValueBoundary
        }

        /// RFC 8259 number grammar. Syntax failures are returned, not thrown, so
        /// JSONDecoder still supplies the user-facing malformed-JSON diagnostic.
        private mutating func scanNumber() -> Bool {
            if consume(Byte.minus), currentByte == nil { return false }

            if consume(Byte.zero) {
                // A leading zero may not be followed by another integer digit.
                if let byte = currentByte, (Byte.zero ... Byte.nine).contains(byte) {
                    return false
                }
            } else {
                guard let byte = currentByte,
                      (Byte.one ... Byte.nine).contains(byte)
                else { return false }
                index += 1
                consumeDigits()
            }

            if consume(Byte.period) {
                guard let byte = currentByte,
                      (Byte.zero ... Byte.nine).contains(byte)
                else { return false }
                consumeDigits()
            }

            if currentByte == Byte.e || currentByte == Byte.upperE {
                index += 1
                if currentByte == Byte.plus || currentByte == Byte.minus {
                    index += 1
                }
                guard let byte = currentByte,
                      (Byte.zero ... Byte.nine).contains(byte)
                else { return false }
                consumeDigits()
            }

            return isAtValueBoundary
        }

        private mutating func consumeDigits() {
            while let byte = currentByte, (Byte.zero ... Byte.nine).contains(byte) {
                index += 1
            }
        }

        private var isAtValueBoundary: Bool {
            guard let byte = currentByte else { return true }
            return isWhitespace(byte)
                || byte == Byte.comma
                || byte == Byte.rightBracket
                || byte == Byte.rightBrace
        }

        private mutating func checkDepth(_ depth: Int) throws {
            guard depth <= StrictJSONDuplicateKeyValidator.maximumNestingDepth else {
                throw ValidationError.nestingTooDeep(
                    maximumDepth: StrictJSONDuplicateKeyValidator.maximumNestingDepth,
                    byteOffset: index
                )
            }
        }

        private var currentByte: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        @discardableResult
        private mutating func consume(_ byte: UInt8) -> Bool {
            guard currentByte == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while let byte = currentByte, isWhitespace(byte) {
                index += 1
            }
        }

        private func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }

    /// ASCII spellings used by the scanner. Named constants keep structural and
    /// literal comparisons readable without repeatedly constructing Characters.
    private enum Byte {
        static let quote: UInt8 = 0x22
        static let plus: UInt8 = 0x2B
        static let comma: UInt8 = 0x2C
        static let minus: UInt8 = 0x2D
        static let period: UInt8 = 0x2E
        static let slash: UInt8 = 0x2F
        static let zero: UInt8 = 0x30
        static let one: UInt8 = 0x31
        static let nine: UInt8 = 0x39
        static let colon: UInt8 = 0x3A
        static let upperA: UInt8 = 0x41
        static let upperE: UInt8 = 0x45
        static let upperF: UInt8 = 0x46
        static let leftBracket: UInt8 = 0x5B
        static let backslash: UInt8 = 0x5C
        static let rightBracket: UInt8 = 0x5D
        static let lowerA: UInt8 = 0x61
        static let b: UInt8 = 0x62
        static let e: UInt8 = 0x65
        static let f: UInt8 = 0x66
        static let l: UInt8 = 0x6C
        static let n: UInt8 = 0x6E
        static let r: UInt8 = 0x72
        static let s: UInt8 = 0x73
        static let t: UInt8 = 0x74
        static let u: UInt8 = 0x75
        static let leftBrace: UInt8 = 0x7B
        static let rightBrace: UInt8 = 0x7D
    }
}
