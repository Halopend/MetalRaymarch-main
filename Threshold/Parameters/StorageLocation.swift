//
//  StorageLocation.swift
//  Threshold
//
//  Single source of truth for WHERE the user's presets, scenes, and animations
//  live. The user picks a storage mode — local (sandboxed) or iCloud Drive — and
//  every store folder resolves off the active root. The chosen folder IS the
//  source of truth: the managers load from it, watch it live, and mirror
//  add/remove. A separate local Backups folder is an always-on safety net,
//  independent of the mode.
//
//      <root>/
//        ├── Scenes/            (.threshscene)
//        ├── Music Presets/     (.threshmp)
//        └── Animations/        (.threshanim / .threshanimv)
//
//  Local root  : App sandbox  Documents/Threshold/
//  iCloud root : the ubiquity container's Documents/ (browseable in Files.app)
//
//  Backups     : App sandbox  Documents/Backups/   (never synced, auto-managed)
//

import Foundation
import Observation

enum StorageMode: String, Codable, CaseIterable, Sendable {
    case local
    case iCloud

    var displayName: String {
        switch self {
        case .local:  return "On This Device"
        case .iCloud: return "iCloud Drive"
        }
    }

    var iconName: String {
        switch self {
        case .local:  return "internaldrive"
        case .iCloud: return "icloud"
        }
    }
}

@Observable
@MainActor
final class StorageLocation {

    /// Shared instance — managers and UI all resolve the active root through this.
    static let shared = StorageLocation()

    // MARK: - Subfolder names (mirror the app's internal Examples layout)

    nonisolated static let scenesSubdir       = "Scenes"
    nonisolated static let musicPresetsSubdir = "Music Presets"
    nonisolated static let animationsSubdir   = "Animations"
    nonisolated static let settingsSubdir     = "Settings"

    static let allStoreSubdirs = [scenesSubdir, musicPresetsSubdir, animationsSubdir, settingsSubdir]

    // MARK: - Notifications

    /// Posted after the active mode changes (object = the new StorageMode.rawValue).
    nonisolated static let modeChangedNotification = Notification.Name("StorageLocation.modeChanged")
    /// Posted when the active root first becomes usable (object = the root URL).
    /// For iCloud this fires after async container discovery completes.
    nonisolated static let rootResolvedNotification = Notification.Name("StorageLocation.rootResolved")

    // MARK: - State

    private nonisolated static let modeKey = "Storage.mode"
    private nonisolated static let hasChosenKey = "Storage.hasChosenMode"

    private(set) var mode: StorageMode
    /// Whether the user has made an explicit first-run storage choice yet.
    /// Drives the one-time choice prompt at launch.
    private(set) var hasChosenMode: Bool = UserDefaults.standard.bool(forKey: hasChosenKey)
    /// Resolved iCloud store root (nil until the container is discovered / when unavailable).
    private(set) var iCloudRoot: URL?
    private(set) var isICloudAvailable = false

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey)
        self.mode = raw.flatMap(StorageMode.init(rawValue:)) ?? .local
        ensureLayout(at: localRoot)
        ensureBackupsRoot()
        if mode == .iCloud { resolveICloud() }
    }

    // MARK: - Roots

    /// Local (sandboxed) store root: Documents/Threshold/.
    var localRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Threshold", isDirectory: true)
    }

    #if DEBUG || THRESHOLD_TESTING
    /// Test-only override for the active store root. When set, `activeRoot` returns
    /// it regardless of mode so tests can exercise the real folder-mirroring against
    /// a temp directory instead of the app sandbox. Never compiled into Release.
    var testRootOverride: URL?
    #endif

    /// The active store root for the current mode. `nil` when iCloud is chosen but
    /// its container has not resolved yet — callers should fall back or wait for
    /// `rootResolvedNotification`.
    var activeRoot: URL? {
        #if DEBUG || THRESHOLD_TESTING
        if let testRootOverride { return testRootOverride }
        #endif
        switch mode {
        case .local:  return localRoot
        case .iCloud: return iCloudRoot
        }
    }

    /// Always-local Backups root (never synced). A safety net independent of mode.
    var backupsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: - Subfolder accessors (relative to a given root)

    nonisolated static func scenesDir(_ root: URL) -> URL { root.appendingPathComponent(scenesSubdir, isDirectory: true) }
    nonisolated static func musicPresetsDir(_ root: URL) -> URL { root.appendingPathComponent(musicPresetsSubdir, isDirectory: true) }
    nonisolated static func animationsDir(_ root: URL) -> URL { root.appendingPathComponent(animationsSubdir, isDirectory: true) }
    nonisolated static func settingsDir(_ root: URL) -> URL { root.appendingPathComponent(settingsSubdir, isDirectory: true) }

    // MARK: - Mode selection

    /// Switch the active storage mode and persist it. Resolves the iCloud
    /// container if needed and notifies observers so the managers can re-point.
    /// Migration/merge between stores is handled by the caller (AppModel) so the
    /// data move can take a pre-switch Backups snapshot first.
    /// Record that the user made an explicit storage choice (even if they kept the
    /// default), so the first-run prompt doesn't reappear.
    func markModeChosen() {
        guard !hasChosenMode else { return }
        hasChosenMode = true
        UserDefaults.standard.set(true, forKey: Self.hasChosenKey)
    }

    func setMode(_ newMode: StorageMode) {
        markModeChosen()
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        if newMode == .iCloud {
            resolveICloud()
        } else {
            ensureLayout(at: localRoot)
        }
        NotificationCenter.default.post(name: Self.modeChangedNotification, object: newMode.rawValue)
        if let root = activeRoot {
            NotificationCenter.default.post(name: Self.rootResolvedNotification, object: root)
        }
    }

    // MARK: - Layout

    /// Create the store subfolders under `root` if missing (idempotent).
    func ensureLayout(at root: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for sub in Self.allStoreSubdirs {
            try? fm.createDirectory(at: root.appendingPathComponent(sub, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
    }

    private func ensureBackupsRoot() {
        try? FileManager.default.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
    }

    // MARK: - iCloud resolution

    /// Discovers the ubiquity container off the main actor and caches the root.
    /// Safe to call repeatedly. Posts `rootResolvedNotification` on first success.
    func resolveICloud() {
        Task {
            let root = await Self.discoverICloudRoot()
            if let root {
                let firstResolve = self.iCloudRoot == nil
                self.iCloudRoot = root
                self.isICloudAvailable = true
                self.ensureLayout(at: root)
                if firstResolve, self.mode == .iCloud {
                    NotificationCenter.default.post(name: Self.rootResolvedNotification, object: root)
                }
            } else {
                self.iCloudRoot = nil
                self.isICloudAvailable = false
            }
        }
    }

    private nonisolated static func discoverICloudRoot() async -> URL? {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        // NSUbiquitousContainerIsDocumentScopePublic surfaces Documents/ in
        // Files.app; the container is named via NSUbiquitousContainerName, so
        // Documents/ IS the Threshold root (no extra path component).
        let docs = containerURL.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }
}
