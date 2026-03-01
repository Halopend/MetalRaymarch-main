//
//  ErrorReporter.swift
//  Threshold
//
//  Centralized error reporting service.
//  Replaces scattered `print()` error logging with observable state
//  that views can bind to for user-facing error banners.
//

import Foundation

/// Centralized error reporting service for the Threshold application.
/// Views observe `currentError` to display transient error banners.
/// All subsystems call `report(_:)` instead of `print()`.
@MainActor
@Observable
final class ErrorReporter {

    // MARK: - Public State

    /// The most recent error that should be shown to the user.
    /// Set to `nil` when dismissed (manually or by auto-dismiss timer).
    private(set) var currentError: ThresholdError?

    /// Chronological history of reported errors (newest first).
    /// Capped at `maxHistoryCount` entries.
    private(set) var errorHistory: [ErrorEntry] = []

    /// Whether an error banner is currently visible.
    var hasActiveError: Bool { currentError != nil }

    // MARK: - Configuration

    /// Maximum number of errors retained in history.
    let maxHistoryCount: Int = 50

    /// Auto-dismiss durations by severity.
    private let autoDismissSeconds: [ThresholdError.Severity: TimeInterval] = [
        .info: 3.0,
        .warning: 5.0,
        // .critical: no auto-dismiss
    ]

    // MARK: - Internal

    private var dismissTask: Task<Void, Never>?

    // MARK: - Error Entry

    /// A timestamped error record for history.
    struct ErrorEntry: Identifiable {
        let id = UUID()
        let error: ThresholdError
        let timestamp: Date
    }

    // MARK: - Reporting

    /// Report an error. Surfaces it to the UI and logs to history.
    /// Deduplicates identical consecutive errors.
    func report(_ error: ThresholdError) {
        // Deduplicate: don't re-show same error if it's already active
        if let current = currentError, current == error { return }

        // Log to console (replaces scattered print() calls)
        #if DEBUG
        print("⚠️ [ErrorReporter] \(error.severity): \(error.description)")
        #endif

        // Add to history
        let entry = ErrorEntry(error: error, timestamp: Date())
        errorHistory.insert(entry, at: 0)
        if errorHistory.count > maxHistoryCount {
            errorHistory.removeLast(errorHistory.count - maxHistoryCount)
        }

        // Update current error
        currentError = error

        // Schedule auto-dismiss based on severity
        scheduleAutoDismiss(for: error)
    }

    /// Dismiss the current error.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentError = nil
    }

    /// Clear all error history.
    func clearHistory() {
        errorHistory.removeAll()
    }

    // MARK: - Private

    private func scheduleAutoDismiss(for error: ThresholdError) {
        dismissTask?.cancel()

        guard let duration = autoDismissSeconds[error.severity] else {
            // Critical errors don't auto-dismiss
            return
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.currentError = nil
        }
    }
}
