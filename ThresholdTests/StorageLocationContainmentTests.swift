//
//  StorageLocationContainmentTests.swift
//  ThresholdTests
//
//  Guards open-in-place routing for files already owned by the active store.
//

import Foundation
import Testing
@testable import Threshold

@Suite("Storage location containment")
struct StorageLocationContainmentTests {

    @Test("Files below the store root are managed")
    func descendantsAreManaged() {
        let root = URL(fileURLWithPath: "/tmp/ThresholdStore", isDirectory: true)

        #expect(StorageLocation.contains(
            root.appendingPathComponent("scene.threshscene"),
            in: root
        ))
        #expect(StorageLocation.contains(
            StorageLocation.scenesDir(root).appendingPathComponent("scene.threshscene"),
            in: root
        ))
    }

    @Test("The root itself and similarly prefixed siblings are not managed files")
    func boundariesDoNotUseStringPrefixes() {
        let root = URL(fileURLWithPath: "/tmp/ThresholdStore", isDirectory: true)

        #expect(!StorageLocation.contains(root, in: root))
        #expect(!StorageLocation.contains(
            URL(fileURLWithPath: "/tmp/ThresholdStore Copy/scene.threshscene"),
            in: root
        ))
        #expect(!StorageLocation.contains(
            URL(fileURLWithPath: "/tmp/scene.threshscene"),
            in: root
        ))
    }

    @Test("A symlink inside the store cannot classify an outside file as managed")
    func symlinkEscapeIsExternal() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageContainment-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Store", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("scene.threshscene")
        let link = root.appendingPathComponent("Linked Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(!StorageLocation.contains(
            link.appendingPathComponent("scene.threshscene"),
            in: root
        ))
    }
}
