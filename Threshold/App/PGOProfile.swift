//
//  PGOProfile.swift
//  Threshold
//
//  Profile-Guided Optimization (PGO) support for Xcode's "Generate
//  Optimization Profile" runs.
//
//  Xcode builds a temporary *instrumented* binary whose LLVM execution
//  counters are, by default, only written to a `.profraw` file at clean
//  process exit (an `atexit` handler calls `__llvm_profile_write_file`).
//  A visionOS immersive app is almost never exited cleanly — the system
//  tears it down with SIGKILL when you leave via the Digital Crown, take the
//  headset off, lose tracking, or hit Stop in Xcode — and SIGKILL does not
//  run `atexit`. The result is the "No profile data files were written"
//  merge failure: the counters are never flushed.
//
//  This helper flushes the counters explicitly at safe points so a SIGKILL
//  can't lose them. The flush symbol exists only in an instrumented build;
//  we resolve it at runtime via dlsym, so normal Run/Release builds link and
//  behave exactly as before (every entry point here becomes a no-op).
//

import Darwin
import Foundation

enum PGOProfile {
    private typealias WriteFileFn = @convention(c) () -> Int32

    /// `int __llvm_profile_write_file(void)`, resolved once at runtime.
    /// Non-nil ONLY in an instrumented PGO build; nil otherwise.
    private static let writeFile: WriteFileFn? = {
        // RTLD_DEFAULT == (void *)-2 on Darwin: search every loaded image,
        // including the statically linked profiling runtime.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "__llvm_profile_write_file") else { return nil }
        return unsafeBitCast(sym, to: WriteFileFn.self)
    }()

    /// True when running the instrumented binary produced by "Generate
    /// Optimization Profile".
    static var isInstrumented: Bool { writeFile != nil }

    /// Write current profile counters to the on-device `.profraw` now. Safe,
    /// cheap no-op when not instrumented. Repeated calls are fine — counters
    /// are cumulative, so a later flush is a superset of an earlier one.
    static func flush() {
        guard let writeFile else { return }
        let rc = writeFile()
        print("✓ PGO: flushed profile counters (rc=\(rc))")
    }

    /// Lazily initialized exactly once (Swift guarantees thread-safe one-time
    /// `static let` init): a background loop that flushes periodically so an
    /// abrupt SIGKILL loses at most a few seconds of coverage.
    private static let periodicFlusher: Void = {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                flush()
            }
        }
        return ()
    }()

    /// Start periodic flushing — only if this is an instrumented build.
    /// Idempotent: the loop starts at most once no matter how often called.
    static func startPeriodicFlushIfInstrumented() {
        guard isInstrumented else { return }
        print("✓ PGO: instrumented build detected — periodic profile flushing enabled")
        _ = periodicFlusher
    }
}
