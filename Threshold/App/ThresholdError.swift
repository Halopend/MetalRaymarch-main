//
//  ThresholdError.swift
//  Threshold
//
//  Unified error domain for the entire application.
//  Subsystem-specific errors are nested enums to keep a flat import.
//

import Foundation

/// Top-level error type for the Threshold application.
/// Each case wraps a subsystem-specific error for easy pattern-matching.
enum ThresholdError: Error, Equatable, CustomStringConvertible {
    case rendering(RenderingError)
    case pipeline(PipelineError)
    case music(MusicError)
    case preset(PresetError)
    case collaboration(CollaborationError)
    case animation(AnimationError)

    // MARK: - Rendering

    enum RenderingError: Error, Equatable, CustomStringConvertible {
        case metalLibraryUnavailable
        case commandQueueCreationFailed
        case uniformBufferCreationFailed
        case depthStencilCreationFailed
        case meshBuildFailed(String)
        case frameEncodingFailed(String)

        var description: String {
            switch self {
            case .metalLibraryUnavailable:       return "Metal shader library unavailable"
            case .commandQueueCreationFailed:     return "Failed to create Metal command queue"
            case .uniformBufferCreationFailed:    return "Failed to create uniform buffer"
            case .depthStencilCreationFailed:     return "Failed to create depth stencil state"
            case .meshBuildFailed(let msg):       return "Mesh build failed: \(msg)"
            case .frameEncodingFailed(let msg):   return "Frame encoding failed: \(msg)"
            }
        }
    }

    // MARK: - Pipeline

    enum PipelineError: Error, Equatable, CustomStringConvertible {
        case compilationFailed(key: String, detail: String)
        case computeCompilationFailed(key: String, detail: String)
        case cacheEviction(count: Int)

        var description: String {
            switch self {
            case .compilationFailed(let key, let detail):
                return "Pipeline compilation failed [\(key)]: \(detail)"
            case .computeCompilationFailed(let key, let detail):
                return "Compute pipeline failed [\(key)]: \(detail)"
            case .cacheEviction(let count):
                return "Evicted \(count) stale pipeline(s) from cache"
            }
        }
    }

    // MARK: - Music

    enum MusicError: Error, Equatable, CustomStringConvertible {
        case authFailed(service: String, reason: String)
        case tokenRefreshFailed(service: String)
        case playbackFailed(service: String, reason: String)
        case libraryLoadFailed(service: String, reason: String)
        case microphoneAccessDenied
        case audioEngineStartFailed(String)
        case noServiceConnected

        var description: String {
            switch self {
            case .authFailed(let svc, let reason):
                return "\(svc) auth failed: \(reason)"
            case .tokenRefreshFailed(let svc):
                return "\(svc) token refresh failed — please re-authenticate"
            case .playbackFailed(let svc, let reason):
                return "\(svc) playback failed: \(reason)"
            case .libraryLoadFailed(let svc, let reason):
                return "\(svc) library load failed: \(reason)"
            case .microphoneAccessDenied:
                return "Microphone access denied. Enable in Settings."
            case .audioEngineStartFailed(let detail):
                return "Audio engine start failed: \(detail)"
            case .noServiceConnected:
                return "No music service connected"
            }
        }
    }

    // MARK: - Preset

    enum PresetError: Error, Equatable, CustomStringConvertible {
        case saveFailed(String)
        case loadFailed(String)
        case importFailed(String)
        case exportFailed(String)
        case backupFailed(String)
        case corruptedData(String)

        var description: String {
            switch self {
            case .saveFailed(let msg):      return "Preset save failed: \(msg)"
            case .loadFailed(let msg):      return "Preset load failed: \(msg)"
            case .importFailed(let msg):    return "Preset import failed: \(msg)"
            case .exportFailed(let msg):    return "Preset export failed: \(msg)"
            case .backupFailed(let msg):    return "Backup failed: \(msg)"
            case .corruptedData(let msg):   return "Corrupted preset data: \(msg)"
            }
        }
    }

    // MARK: - Collaboration

    enum CollaborationError: Error, Equatable, CustomStringConvertible {
        case sessionStartFailed(String)
        case syncFailed(String)
        case disconnected(String)

        var description: String {
            switch self {
            case .sessionStartFailed(let msg): return "SharePlay session failed: \(msg)"
            case .syncFailed(let msg):         return "Sync failed: \(msg)"
            case .disconnected(let msg):       return "Disconnected: \(msg)"
            }
        }
    }

    // MARK: - Animation

    enum AnimationError: Error, Equatable, CustomStringConvertible {
        case saveFailed(String)
        case loadFailed(String)
        case importFailed(String)
        case exportFailed(String)

        var description: String {
            switch self {
            case .saveFailed(let msg):   return "Animation save failed: \(msg)"
            case .loadFailed(let msg):   return "Animation load failed: \(msg)"
            case .importFailed(let msg): return "Animation import failed: \(msg)"
            case .exportFailed(let msg): return "Animation export failed: \(msg)"
            }
        }
    }

    // MARK: - Severity

    /// How urgently the error should be surfaced to the user.
    enum Severity {
        case info       // Transient, auto-dismiss in 3s
        case warning    // Auto-dismiss in 5s
        case critical   // Persists until dismissed
    }

    var severity: Severity {
        switch self {
        case .rendering:                              return .critical
        case .pipeline(.compilationFailed):           return .warning
        case .pipeline(.computeCompilationFailed):    return .warning
        case .pipeline(.cacheEviction):               return .info
        case .music(.authFailed):                     return .warning
        case .music(.tokenRefreshFailed):             return .warning
        case .music(.microphoneAccessDenied):         return .warning
        case .music(.audioEngineStartFailed):         return .warning
        case .music(.playbackFailed):                 return .info
        case .music(.libraryLoadFailed):              return .info
        case .music(.noServiceConnected):             return .info
        case .preset(.corruptedData):                 return .critical
        case .preset:                                 return .warning
        case .collaboration:                          return .warning
        case .animation:                              return .warning
        }
    }

    /// User-facing message (shorter than `description` for UI display).
    var userMessage: String {
        switch self {
        case .rendering(let e):      return e.description
        case .pipeline(let e):       return e.description
        case .music(let e):          return e.description
        case .preset(let e):         return e.description
        case .collaboration(let e):  return e.description
        case .animation(let e):      return e.description
        }
    }

    var description: String { userMessage }
}
