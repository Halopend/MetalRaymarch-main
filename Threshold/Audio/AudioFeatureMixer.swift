//
//  AudioFeatureMixer.swift
//  Threshold
//
//  Pure, deterministic aggregation of normalized audio features. Keeping this
//  independent of AVFoundation makes the feature policy testable without audio
//  hardware or privacy permissions.
//

import Foundation

enum AudioFeatureMixer {
    /// Builds one GPU-safe snapshot from fresh, selected feature sources.
    ///
    /// - Important: Inputs with a non-finite feature value are dropped instead
    ///   of being coerced to silence and included in the denominator. This
    ///   prevents a poisoned capture callback from reducing healthy sources.
    static func mix(contributions: [AudioSourceContribution],
                    selectedSourceIDs: Set<AudioSourceID>,
                    policy: AudioMixPolicy,
                    now: TimeInterval,
                    maximumAge: TimeInterval = 0.35) -> AudioFeatureSnapshot {
        guard !selectedSourceIDs.isEmpty else { return .empty(at: now) }

        let fresh = contributions
            .filter { selectedSourceIDs.contains($0.sourceID) }
            .filter { now >= $0.timestamp && now - $0.timestamp <= maximumAge }
            .filter { $0.features.isFinite && $0.weight.isFinite && $0.weight > 0 }
            .map { contribution in
                AudioSourceContribution(
                    sourceID: contribution.sourceID,
                    features: contribution.features.sanitized(),
                    provenance: contribution.provenance,
                    timestamp: contribution.timestamp,
                    weight: min(1, max(0, contribution.weight))
                )
            }
            .sorted { lhs, rhs in lhs.sourceID.rawValue < rhs.sourceID.rawValue }

        guard !fresh.isEmpty else { return .empty(at: now) }

        switch policy {
        case .exclusive:
            let selected = [fresh[0]]
            return AudioFeatureSnapshot(
                timestamp: now,
                contributions: selected,
                mixed: selected[0].features,
                provenance: selected[0].provenance,
                isActive: true
            )

        case .weighted:
            var weightTotal: Float = 0
            var bass: Float = 0
            var mid: Float = 0
            var treble: Float = 0
            var overall: Float = 0
            var onset: Float = 0

            for contribution in fresh {
                let weight = contribution.weight * contribution.features.confidence
                guard weight > 0 else { continue }
                weightTotal += weight
                bass += contribution.features.bass * weight
                mid += contribution.features.mid * weight
                treble += contribution.features.treble * weight
                overall += contribution.features.overall * weight
                onset = max(onset, contribution.features.onset)
            }

            guard weightTotal > 0 else { return .empty(at: now) }

            let provenance = combinedProvenance(fresh.map(\.provenance))
            return AudioFeatureSnapshot(
                timestamp: now,
                contributions: fresh,
                mixed: AudioFeatures(
                    bass: bass / weightTotal,
                    mid: mid / weightTotal,
                    treble: treble / weightTotal,
                    onset: onset,
                    overall: overall / weightTotal,
                    confidence: min(1, weightTotal / Float(fresh.count))
                ).sanitized(),
                provenance: provenance,
                isActive: true
            )
        }
    }

    private static func combinedProvenance(_ provenance: [AudioFeatureProvenance]) -> AudioFeatureProvenance {
        guard let first = provenance.first else { return .unknown }
        return provenance.dropFirst().allSatisfy { $0 == first } ? first : .mixed
    }
}
