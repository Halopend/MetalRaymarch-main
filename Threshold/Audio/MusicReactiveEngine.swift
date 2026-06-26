import Foundation

/// Per-frame audio band levels feeding the music-reactive engine.
///
/// Each platform computes these from whatever audio sources are available to it
/// (visionOS blends microphone + Apple Music; macOS uses the analyzer feed), then
/// hands them to the shared `MusicReactiveEngine` so the response-curve / LFO /
/// dispatch math lives in exactly one place.
struct BandLevels {
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var beat: Float = 0
    var overall: Float = 0
}

/// Shared, platform-neutral engine that turns aggregated audio band levels into
/// additive `ParameterOperation`s for the layer stack.
///
/// Both the visionOS `Renderer` (an `actor`) and the macOS `ThresholdMacRenderView`
/// (a `@MainActor` class) own a private instance. The engine carries no shared
/// global state — each owner has its own — so it is safe to use from either
/// isolation domain. All mutable per-frame state (oscillator phases, decay/drift
/// trackers, damped source levels, the triplet-gain cache, and the reusable
/// operation buffer) lives here instead of being duplicated in each renderer.
final class MusicReactiveEngine {

    /// Per-mapping data that is expensive or redundant to resolve every frame.
    ///
    /// This is rebuilt only when the active fractal type or the user-facing
    /// mapping array changes, leaving the hot path to do only frame-dependent
    /// math (source sampling, curve integration, LFO, and dispatch).
    private struct ResolvedMapping {
        let target: MusicReactiveTarget
        let source: MusicReactiveSource
        let responseCurve: ResponseCurve
        let targetID: String
        let allowedSpan: Float
        let absAmount: Float
        let sign: Float
        let formulaParamSlot: Int?
        let smoothingTime: Float
        let hybridCombo: Float
        let lfo: LFOSettings
    }

    // MARK: - Per-target oscillator / envelope state

    private var phaseByTarget: [MusicReactiveTarget: Float] = [:]
    private var decayByTarget: [MusicReactiveTarget: Float] = [:]
    private var driftByTarget: [MusicReactiveTarget: Float] = [:]
    private var lfoPhaseByTarget: [MusicReactiveTarget: Float] = [:]

    // MARK: - Damped source levels (exponential follower per band)

    private var dampedBass: Float = 0
    private var dampedMid: Float = 0
    private var dampedTreble: Float = 0
    private var dampedBeat: Float = 0
    private var dampedOverall: Float = 0
    private var dampedComposite: Float = 0

    // MARK: - Cached slot-gain lookup for music-reactive triplet gains

    /// Rebuilt only when the active fractal type or triplet-gain dictionary
    /// changes — the per-frame hot path must not recompute this from scratch.
    private var cachedFractalType: FractalModelType?
    private var cachedTripletGains: [String: Float] = [:]
    private var cachedSlotGainLookup: [Int: Float] = [:]

    // MARK: - Reusable per-frame buffers

    /// Rebuilt per-frame via `removeAll(keepingCapacity: true)` so the backing
    /// storage survives and we avoid reallocating every frame while active.
    private var operationsBuffer: [ParameterOperation] = []
    private var frameIndex: UInt64 = 0

    // MARK: - Resolved mapping cache

    /// Snapshot of the last user-facing mapping set used to resolve the hot-path
    /// mapping metadata below.
    private var cachedResolvedFractalType: FractalModelType?
    private var cachedResolvedMappingsSnapshot: [MusicReactiveMapping] = []
    private var activeResolvedMappings: [ResolvedMapping] = []

    /// Tracks whether the music layer has been activated so it can be cleared
    /// when music reactivity is turned off.
    private(set) var layerActive: Bool = false

    /// Last observed scene-load generation. Drift/decay/phase state accumulated
    /// against the previous preset must not carry into a freshly loaded one —
    /// stale drift offsets immediately shove the new preset off its values.
    private var lastSceneLoadGeneration: UInt64?

    // MARK: - Public API

    /// Compute additive music-reactive parameter offsets from the given band
    /// levels and dispatch them through the parameter pipeline.
    ///
    /// - Parameters:
    ///   - bandLevels: Aggregated per-band audio levels (already sensitivity-scaled
    ///     and clamped to 0...1 by the caller).
    ///   - settings: Live render settings (mappings, amounts, damping, fractal type).
    ///   - deltaTime: Frame delta in seconds.
    ///   - pipeline: Shared parameter pipeline used to dispatch the audio layer.
    func process(bandLevels: BandLevels,
                 settings: RenderSettings,
                 deltaTime dt: Float,
                 pipeline: ParameterPipeline) {
        layerActive = true

        let sceneGeneration = settings.sceneLoadGeneration
        if let last = lastSceneLoadGeneration, last != sceneGeneration {
            clearCurveState()
        }
        lastSceneLoadGeneration = sceneGeneration

        let damping = max(0.0, min(3.0, settings.fractalAudioDamping))

        // Global damping has two effects, so the slider feels like a single
        // "calm the response" control instead of only softening the envelope:
        //   1. It smooths the incoming band levels (amplitude envelope) below.
        //   2. `motionScale` slows the response-curve dynamics (oscillation /
        //      decay / drift rates). Without this, oscillating curves keep
        //      wobbling at full speed and damping appears to "do nothing".
        // At damping 0 → full speed (1.0); damping 1 → ~15% speed (very calm).
        // The slider extends to 3 for triple-strength damping: beyond 1 the
        // motion scale keeps easing down (continuous from 0.15) to a 0.05 floor
        // at 3, so it never goes negative or inverts the oscillation direction.
        let motionScale: Float = damping <= 1.0
            ? (1.0 - 0.85 * damping)
            : max(0.05, 0.15 - 0.05 * (damping - 1.0))

        let bass = applyDamping(current: dampedBass, target: bandLevels.bass, damping: damping, deltaTime: dt)
        dampedBass = bass
        let mid = applyDamping(current: dampedMid, target: bandLevels.mid, damping: damping, deltaTime: dt)
        dampedMid = mid
        let treble = applyDamping(current: dampedTreble, target: bandLevels.treble, damping: damping, deltaTime: dt)
        dampedTreble = treble
        let overall = applyDamping(current: dampedOverall, target: bandLevels.overall, damping: damping, deltaTime: dt)
        dampedOverall = overall

        let globalAmount = settings.fractalAudioAmount * settings.animationActivityFactor
        let beatPunch = settings.fractalBeatPunch

        // Drop (the punctuation source) is a TRANSIENT: bypass the amplitude
        // follower so global damping can't smear the snap. The "Drop" slider
        // (beatPunch) scales its intensity; default 0.3 ≈ unity gain.
        let beat = min(1.0, bandLevels.beat * (0.5 + 1.5 * beatPunch))

        // Energy = smooth band-weighted intensity. Deliberately does NOT mix in
        // the transient Drop, so Energy-driven Wave/Follow targets stay smooth.
        let bandDrive = bass * 0.55 + mid * 0.30 + treble * 0.15
        let driveTarget = min(1.0, bandDrive * 0.9)
        let drive = applyDamping(current: dampedComposite, target: driveTarget, damping: damping, deltaTime: dt)
        dampedComposite = drive

        // Reuse the buffer's backing storage across frames.
        operationsBuffer.removeAll(keepingCapacity: true)

        let activeFractalType = settings.fractalType
        let mappings = settings.musicReactiveMappings
        refreshResolvedMappingsIfNeeded(for: activeFractalType, mappings: mappings)

        // Drain manual re-center requests AFTER the mapping refresh (so the
        // targetID→target map is current) and BEFORE the offset loop (so this
        // frame already reflects the reset). Re-zeros drift/decay/phase for any
        // target the user just moved manually, so variation restarts from zero
        // around the fresh value instead of carrying a stale offset.
        let recenterRequests = settings.drainMusicRecenterRequests()
        if !recenterRequests.isEmpty {
            for mapping in activeResolvedMappings where recenterRequests.contains(mapping.targetID) {
                resetState(for: mapping.target)
            }
        }

        let slotGainLookup = slotGainLookup(for: activeFractalType,
                                            tripletGains: settings.tripletMusicGains)

        for mapping in activeResolvedMappings {
            // ── 1. Select audio source level (0-1) ──
            let sourceValue: Float
            switch mapping.source {
            case .composite: sourceValue = drive
            case .bass: sourceValue = bass
            case .mid: sourceValue = mid
            case .treble: sourceValue = treble
            case .beat: sourceValue = beat
            case .overall: sourceValue = overall
            }

            // ── 2. Scale audio intensity ──
            // ── 3. Compute max deviation (fraction of allowed range) ──
            let maxDeviation = mapping.allowedSpan * 0.15 * mapping.absAmount * globalAmount

            // ── 4. Apply response curve to produce a bipolar offset ──
            // Audio energy modulates the AMPLITUDE of an oscillation centered at zero,
            // so the parameter oscillates around the user's manual/animation base value.
            let delta: Float
            switch mapping.responseCurve {
            case .sinusoidal:
                // Continuous phase-locked oscillation; audio modulates amplitude.
                // When audio is silent → offset = 0 (no drift from base).
                // When audio is loud  → offset oscillates ±maxDeviation.
                // `motionScale` lets global damping slow the oscillation rate.
                let phaseSpeed: Float = (2.0 + sourceValue * 4.0) * motionScale  // faster when louder
                var phase = phaseByTarget[mapping.target] ?? 0
                phase += phaseSpeed * dt
                phase = phase - floor(phase)
                phaseByTarget[mapping.target] = phase
                delta = sin(phase * 2.0 * .pi) * sourceValue * maxDeviation * mapping.sign

            case .pulse:
                // Fast attack on beat onset, exponential decay.
                // Produces a sharp spike that fades, ideal for bloom/glow.
                // `motionScale` slows the decay under damping so pulses hold
                // longer and the overall response feels calmer/smoother.
                let attack = sourceValue * sourceValue  // quadratic for sharper onset
                var decay = decayByTarget[mapping.target] ?? 0
                decay = max(attack, decay * exp(-6.0 * motionScale * dt))  // ~170ms decay at damping 0
                decayByTarget[mapping.target] = decay
                delta = decay * maxDeviation * mapping.sign

            case .drift:
                // Heavily smoothed, slow-moving offset.
                // Audio energy gently pushes the parameter; the large smoothing
                // window makes it lag behind the beat for a "color drift" feel.
                // Higher damping lengthens the convergence time (calmer drift).
                let target = sourceValue * maxDeviation * mapping.sign
                var drifted = driftByTarget[mapping.target] ?? 0
                let driftRate: Float = 2.0 / max(0.15, motionScale)  // seconds to converge
                drifted += (target - drifted) * min(1.0, dt / driftRate)
                driftByTarget[mapping.target] = drifted
                delta = drifted

            case .hybrid:
                // True hybrid: large slow drift + smaller fast vibration.
                // hybridCombo controls how pronounced/energetic the fast vibration is.
                let combo = mapping.hybridCombo

                // Slow large-scale movement (drift backbone).
                // Higher damping lengthens convergence and slows the vibration.
                let target = sourceValue * maxDeviation * mapping.sign
                var drifted = driftByTarget[mapping.target] ?? 0
                let driftRate: Float = 2.4 / max(0.15, motionScale)
                drifted += (target - drifted) * min(1.0, dt / driftRate)
                driftByTarget[mapping.target] = drifted

                // Fast micro-vibration (wave overlay), still music-driven.
                let vibrationSpeed: Float = (6.0 + sourceValue * 8.0 + combo * 4.0) * motionScale
                var phase = phaseByTarget[mapping.target] ?? 0
                phase += vibrationSpeed * dt
                phase = phase - floor(phase)
                phaseByTarget[mapping.target] = phase

                let vibrationAmplitude = maxDeviation * sourceValue * (0.08 + 0.35 * combo)
                let vibration = sin(phase * 2.0 * .pi) * vibrationAmplitude * mapping.sign

                let combined = drifted + vibration
                let limit = maxDeviation * 1.2
                delta = max(-limit, min(limit, combined))
            }

            // ── 5. Optional LFO overlay ──
            var lfoOffset: Float = 0
            if mapping.lfo.enabled {
                var phase = lfoPhaseByTarget[mapping.target] ?? 0
                phase += mapping.lfo.frequency * dt
                phase = phase - floor(phase)
                lfoPhaseByTarget[mapping.target] = phase
                lfoOffset = mapping.lfo.shape.evaluate(phase: phase) * mapping.lfo.amplitude * maxDeviation
            }

            let rawTargetValue = delta + lfoOffset

            // ── 6. Dispatch to parameter system (LayerStack handles smoothing) ──
            // Apply triplet gain for formula param targets
            let finalOffset: Float
            if let slot = mapping.formulaParamSlot, let gain = slotGainLookup[slot] {
                finalOffset = rawTargetValue * gain
            } else {
                finalOffset = rawTargetValue
            }

            operationsBuffer.append(
                ParameterOperation(
                    targetID: mapping.targetID,
                    source: .audio,
                    // The music layer is itself additive, so it must receive the
                    // raw offset to apply on top of the current base value.
                    value: .absolute(finalOffset),
                    frameIndex: frameIndex,
                    smoothing: ParameterOperationSmoothing(
                        smoothingTime: mapping.smoothingTime
                    )
                )
            )
        }

        if !operationsBuffer.isEmpty {
            pipeline.dispatchAudio(operationsBuffer, settings: settings)
            frameIndex &+= 1
        }
    }

    /// Clears the active music layer (if any) and resets all per-target and
    /// damping state. Call when music reactivity is disabled or sources go away.
    func reset(settings: RenderSettings, pipeline: ParameterPipeline) {
        if layerActive {
            pipeline.clearMusicLayers(settings: settings)
        }
        // Drop any music offsets the playback composer is still layering on the animation
        // (with the engine off, nothing refreshes them back toward zero each frame).
        settings.clearAudioPlaybackOffsets()
        layerActive = false
        clearCurveState()
        resetDamping()
        // Discard any pending re-center requests so they don't linger across an
        // audio-off/on cycle (the curve state was just cleared anyway).
        _ = settings.drainMusicRecenterRequests()
    }

    // MARK: - Internals

    @inline(__always)
    private func applyDamping(current: Float, target: Float, damping: Float, deltaTime: Float) -> Float {
        let clampedDamping = max(0.0, min(3.0, damping))
        guard clampedDamping > 0.001 else { return target }
        let responseTime = 0.02 + clampedDamping * 0.5
        let blend = 1.0 - exp(-deltaTime / responseTime)
        return current + (target - current) * blend
    }

    private func resetDamping() {
        dampedBass = 0
        dampedMid = 0
        dampedTreble = 0
        dampedBeat = 0
        dampedOverall = 0
        dampedComposite = 0
    }

    /// Rebuild the per-mapping hot-path metadata only when the fractal type or
    /// the user-facing mapping array changes.
    private func refreshResolvedMappingsIfNeeded(for activeFractalType: FractalModelType,
                                                 mappings: [MusicReactiveMapping]) {
        guard cachedResolvedFractalType != activeFractalType ||
                cachedResolvedMappingsSnapshot != mappings else {
            return
        }

        if cachedResolvedFractalType != activeFractalType {
            clearCurveState()
        } else {
            resetStateForChangedMappings(previous: cachedResolvedMappingsSnapshot,
                                         next: mappings)
        }

        cachedResolvedFractalType = activeFractalType
        cachedResolvedMappingsSnapshot = mappings
        activeResolvedMappings.removeAll(keepingCapacity: true)
        activeResolvedMappings.reserveCapacity(mappings.count)

        for mapping in mappings where mapping.isEnabled {
            guard let targetID = mapping.target.parameterTargetID(for: activeFractalType) else { continue }
            let allowed = mapping.target.allowedRange(for: activeFractalType)
            activeResolvedMappings.append(
                ResolvedMapping(
                    target: mapping.target,
                    source: mapping.source,
                    responseCurve: mapping.responseCurve,
                    targetID: targetID,
                    allowedSpan: allowed.upperBound - allowed.lowerBound,
                    absAmount: abs(mapping.amount),
                    sign: mapping.amount >= 0 ? 1.0 : -1.0,
                    formulaParamSlot: mapping.target.formulaParamSlot,
                    smoothingTime: max(0.02, mapping.smoothingWindow),
                    hybridCombo: max(0.0, min(1.0, mapping.hybridCombo)),
                    lfo: mapping.lfo
                )
            )
        }
    }

    /// Reset curve state for targets that were removed, newly added, or had
    /// their mapping definition changed. This preserves continuity only for
    /// targets whose mapping remains exactly the same.
    private func resetStateForChangedMappings(previous: [MusicReactiveMapping],
                                             next: [MusicReactiveMapping]) {
        let previousByTarget = Dictionary(uniqueKeysWithValues: previous.filter(\.isEnabled).map { ($0.target, $0) })
        let nextByTarget = Dictionary(uniqueKeysWithValues: next.filter(\.isEnabled).map { ($0.target, $0) })
        let activeTargets = Set(nextByTarget.keys)

        for (target, previousMapping) in previousByTarget {
            guard let nextMapping = nextByTarget[target] else {
                resetState(for: target)
                continue
            }
            if previousMapping != nextMapping {
                resetState(for: target)
            }
        }

        for target in activeTargets where previousByTarget[target] == nil {
            resetState(for: target)
        }

        pruneState(keeping: activeTargets)
    }

    private func resetState(for target: MusicReactiveTarget) {
        phaseByTarget.removeValue(forKey: target)
        decayByTarget.removeValue(forKey: target)
        driftByTarget.removeValue(forKey: target)
        lfoPhaseByTarget.removeValue(forKey: target)
    }

    private func clearCurveState() {
        phaseByTarget.removeAll()
        decayByTarget.removeAll()
        driftByTarget.removeAll()
        lfoPhaseByTarget.removeAll()
    }

    private func pruneState(keeping activeTargets: Set<MusicReactiveTarget>) {
        phaseByTarget = phaseByTarget.filter { activeTargets.contains($0.key) }
        decayByTarget = decayByTarget.filter { activeTargets.contains($0.key) }
        driftByTarget = driftByTarget.filter { activeTargets.contains($0.key) }
        lfoPhaseByTarget = lfoPhaseByTarget.filter { activeTargets.contains($0.key) }
    }

    /// Returns the cached `formulaParamSlot → gain` lookup, rebuilding it only
    /// when the active fractal type or triplet-gain dictionary actually changes.
    private func slotGainLookup(for activeFractalType: FractalModelType,
                                tripletGains: [String: Float]) -> [Int: Float] {
        if cachedFractalType != activeFractalType || cachedTripletGains != tripletGains {
            cachedFractalType = activeFractalType
            cachedTripletGains = tripletGains
            cachedSlotGainLookup.removeAll(keepingCapacity: true)

            if !tripletGains.isEmpty {
                let triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: activeFractalType)
                let floatParams = MusicReactiveTarget.floatFormulaParams(for: activeFractalType)
                for triplet in triplets {
                    guard let gain = tripletGains[triplet.groupName], gain != 1.0 else { continue }
                    for formulaIndex in [triplet.xFormulaIndex, triplet.yFormulaIndex, triplet.zFormulaIndex] {
                        if let slot = floatParams.firstIndex(where: { $0.index == formulaIndex }) {
                            cachedSlotGainLookup[slot] = gain
                        }
                    }
                }
            }
        }
        return cachedSlotGainLookup
    }
}
