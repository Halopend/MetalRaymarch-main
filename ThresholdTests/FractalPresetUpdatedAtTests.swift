//
//  FractalPresetUpdatedAtTests.swift
//  ThresholdTests
//
//  Pins the `updatedAt` field added for iCloud newest-wins merge: it must
//  round-trip independently of `createdAt`, and presets saved BEFORE the field
//  existed must decode with `updatedAt == createdAt` (backward-compatible), never
//  a spurious value. A regression here would silently break conflict resolution.
//

import Testing
import Foundation
@testable import Threshold

@Suite("FractalPreset.updatedAt round-trips + back-fills")
struct FractalPresetUpdatedAtTests {

    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    @Test("A fresh preset's updatedAt equals its createdAt")
    func freshEqualsCreated() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let p = FractalPreset(name: "Fresh", createdAt: created)
        #expect(p.updatedAt == created)
    }

    @Test("updatedAt survives encode -> decode, distinct from createdAt")
    func roundTrips() throws {
        var p = FractalPreset(name: "RT", createdAt: Date(timeIntervalSince1970: 1_000_000))
        p.updatedAt = Date(timeIntervalSince1970: 2_000_000)   // deliberately != createdAt
        let data = try encoder().encode(p)
        let back = try decoder().decode(FractalPreset.self, from: data)
        #expect(back.createdAt == p.createdAt)
        #expect(back.updatedAt == p.updatedAt)
        #expect(back.updatedAt != back.createdAt)
    }

    @Test("A preset saved before updatedAt existed decodes with updatedAt == createdAt")
    func backfillsFromLegacyJSON() throws {
        var p = FractalPreset(name: "Legacy", createdAt: Date(timeIntervalSince1970: 1_500_000))
        p.updatedAt = Date(timeIntervalSince1970: 2_000_000)
        // Strip the key to simulate a file written before the field existed.
        let data = try encoder().encode(p)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "updatedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let back = try decoder().decode(FractalPreset.self, from: legacyData)
        #expect(back.updatedAt == back.createdAt)   // backfilled from createdAt…
        #expect(back.updatedAt == p.createdAt)       // …not the stripped 2_000_000 value
    }
}
