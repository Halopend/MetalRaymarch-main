//
//  AudioAnalyzer.swift
//  Threshold
//
//  Captures microphone input and provides audio levels for reactive lighting.
//  Uses FFT for proper frequency band separation (bass, mids, treble).
//
//  Architecture: capture threads (the AVAudioEngine tap and the
//  ScreenCaptureKit delivery queue) feed PCM synchronously into an
//  `AudioAnalysisCore` that owns all DSP state behind a lock. The core
//  accumulates mono samples into fixed 2048-frame analysis windows — so tap
//  delivery size never dictates FFT cadence — and publishes per-window feature
//  targets. `tickEnvelopes(at:)`, driven from `AudioHub.updateFrame()`, applies
//  attack/decay smoothing at display cadence and writes the public levels.
//

import AVFoundation
import Accelerate
import Synchronization
import os

/// Analyzes audio input and provides normalized level values for visual effects
@MainActor
@Observable
class AudioAnalyzer {

    // MARK: - Public Properties

    /// Current audio level (0-1), smoothed for visual appeal.
    /// @ObservationIgnored keeps frame-rate writes from invalidating SwiftUI;
    /// writes (tickEnvelopes) and reads (featureContribution) are MainActor.
    @ObservationIgnored private(set) var level: Float = 0.0

    /// Bass level (low frequencies 20-250Hz) - good for deep pulses
    @ObservationIgnored private(set) var bassLevel: Float = 0.0

    /// Mid level (250Hz-2kHz) - vocals and instruments
    @ObservationIgnored private(set) var midLevel: Float = 0.0

    /// Treble level (high frequencies 2k-8kHz) - good for sparkles
    @ObservationIgnored private(set) var trebleLevel: Float = 0.0

    /// Onset / "Drop" strength (0–1) from spectral flux. Near-zero most of the
    /// time, spikes hard on a transient or a big musical punctuation (the drop).
    @ObservationIgnored private(set) var onsetLevel: Float = 0.0

    /// Whether any audio capture source is active.
    @ObservationIgnored nonisolated(unsafe) private(set) var isCapturing: Bool = false

    /// Whether the microphone capture path is active.
    @ObservationIgnored nonisolated(unsafe) private(set) var isMicrophoneCapturing: Bool = false

    /// Whether an external PCM source (whole-system output minus this process,
    /// captured via ScreenCaptureKit) is active. Read only within AudioAnalyzer.
    @ObservationIgnored nonisolated(unsafe) private var isExternalCapturing: Bool = false

    /// Monotonic time (ProcessInfo systemUptime) of the most recently ingested
    /// PCM buffer, stamped on the capture thread. Capture adapters use this to
    /// keep a stalled route from presenting old features as live; the core also
    /// zeroes feature targets once ingestion goes stale.
    nonisolated var lastSampleTime: TimeInterval { core.latestSampleTime }

    /// Error message if capture fails
    private(set) var errorMessage: String?

    // MARK: - Analysis core

    /// All DSP state lives here, off the MainActor, fed synchronously by
    /// capture threads.
    @ObservationIgnored nonisolated let core = AudioAnalysisCore()

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    @ObservationIgnored private var configurationChangeObserver: (any NSObjectProtocol)?
    #if !os(macOS)
    @ObservationIgnored private var sessionObservers: [any NSObjectProtocol] = []
    #endif

    // Debounced auto-restart after a device/configuration change. A rapid
    // burst of notifications (AirPods connecting renegotiate several times)
    // coalesces into one restart; repeated failures give up and surface an
    // error instead of looping.
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var restartAttempts: [TimeInterval] = []
    private static let restartDebounce: Duration = .milliseconds(500)
    private static let maxRestartAttempts = 3
    private static let restartAttemptWindow: TimeInterval = 10

    // Envelope smoothing state (MainActor only; applied in tickEnvelopes).
    @ObservationIgnored private var lastTickTime: TimeInterval = 0
    // Time constants (seconds): fast attack so hits land, slower decay so the
    // fall reads smooth at display rate.
    private let attackTau: Float = 0.03
    private let bandDecayTau: Float = 0.15
    private let overallDecayTau: Float = 0.25
    private let onsetDecaySpeed: Float = 6.0   // linear fall per second — reads as a discrete hit

    // MARK: - Public Methods

    /// Start capturing audio from the default input device without forcing
    /// callers that predate `AudioHub` to become asynchronous.
    func startCapture() {
        Task { @MainActor in
            _ = await startCaptureIfNeeded()
        }
    }

    /// Starts capture and reports whether a live microphone tap was installed.
    /// `AudioHub` uses this rather than guessing from a delayed permission task,
    /// which lets it make a source transition atomically with the feature mixer.
    @discardableResult
    func startCaptureIfNeeded() async -> Bool {
        guard !isMicrophoneCapturing else { return true }
        errorMessage = nil

        guard await checkMicrophonePermission() else {
            #if os(macOS)
            errorMessage = "Microphone access denied. Enable Threshold in System Settings -> Privacy & Security -> Microphone. If you recently changed the bundle identifier, macOS treats it as a new app and you must re-enable access."
            #else
            errorMessage = "Microphone access denied. Enable in Settings."
            #endif
            return false
        }

        setupAudioCapture()
        return isMicrophoneCapturing
    }

    /// Stop capturing audio
    func stopCapture() {
        restartTask?.cancel()
        restartTask = nil
        teardownEngine()
        #if !os(macOS)
        removeSessionObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        if !isExternalCapturing {
            core.deactivate()
        }
        isMicrophoneCapturing = false
        refreshCaptureState(resetLevelsWhenIdle: true)
    }

    // MARK: - External PCM Ingestion
    //
    // Allows alternate capture backends (ScreenCaptureKit on macOS) to feed
    // PCM into the same analysis core used by the microphone path.

    /// Mark the analyzer as actively receiving samples from an external source.
    /// The core re-locks its band indices to the source's sample rate (and
    /// adapts again per-buffer if the delivered rate ever differs).
    func beginExternalCapture(sampleRate externalSampleRate: Double) {
        core.activate(sampleRate: Float(externalSampleRate))
        isExternalCapturing = true
        refreshCaptureState()
        errorMessage = nil
    }

    /// Stop external ingestion and decay levels back to zero.
    func endExternalCapture() {
        isExternalCapturing = false
        if !isMicrophoneCapturing {
            core.deactivate()
        }
        refreshCaptureState(resetLevelsWhenIdle: true)
    }

    /// Feed an externally-captured PCM buffer into the analysis core. Safe to
    /// call from any thread; the buffer is consumed synchronously.
    nonisolated func ingestExternalBuffer(_ buffer: AVAudioPCMBuffer) {
        core.ingest(buffer)
    }

    // MARK: - Envelope tick

    /// Apply attack/decay smoothing toward the core's latest feature targets.
    /// Called from `AudioHub.updateFrame()` — once per rendered frame, and from
    /// the hub's low-rate fallback timer when rendering is paused. Onset is
    /// consumed on read (max-accumulated in the core), so a transient that
    /// lands between ticks is never dropped.
    func tickEnvelopes(at now: TimeInterval) {
        let deltaTime = lastTickTime > 0 ? Float(now - lastTickTime) : Float(1.0 / 60.0)
        lastTickTime = now
        let dt = max(0.001, min(0.1, deltaTime))

        let targets = core.consumeTargets(now: now) ?? AudioAnalysisCore.Targets()

        let attackFactor = 1.0 - exp(-dt / attackTau)
        let overallDecayFactor = 1.0 - exp(-dt / overallDecayTau)
        let bandDecayFactor = 1.0 - exp(-dt / bandDecayTau)

        smooth(&level, target: targets.overall, attack: attackFactor, decay: overallDecayFactor)
        smooth(&bassLevel, target: targets.bass, attack: attackFactor, decay: bandDecayFactor)
        smooth(&midLevel, target: targets.mid, attack: attackFactor, decay: bandDecayFactor)
        smooth(&trebleLevel, target: targets.treble, attack: attackFactor, decay: bandDecayFactor)

        // Onset/"Drop": instant attack (snap to the spike), fast linear decay so
        // it reads as a discrete hit rather than a sustained level.
        if targets.onset > onsetLevel {
            onsetLevel = targets.onset
        } else {
            onsetLevel = max(0, onsetLevel - onsetDecaySpeed * dt)
        }
    }

    private func smooth(_ current: inout Float, target: Float, attack: Float, decay: Float) {
        guard target.isFinite else { return }
        if !current.isFinite { current = 0 }
        current += (target - current) * (target > current ? attack : decay)
    }

    // MARK: - Private Methods

    private func checkMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    #if !os(macOS)
    /// The default session category does not permit recording, so without this
    /// the input node reports a dead 0 Hz format on iPadOS/visionOS.
    /// `.playAndRecord` + `.mixWithOthers` keeps the user's music playing —
    /// a visualizer must never silence what it is visualizing.
    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            errorMessage = "Could not activate the audio session: \(error.localizedDescription)"
            return false
        }
    }

    private func installSessionObservers() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let rawType,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                if type == .ended {
                    self.scheduleEngineRestart()
                }
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEngineRestart() }
        })
    }

    private func removeSessionObservers() {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
    }
    #endif

    private func setupAudioCapture() {
        #if !os(macOS)
        guard activateAudioSession() else { return }
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            errorMessage = "No audio input available"
            return
        }

        core.activate(sampleRate: Float(format.sampleRate))

        // The requested tap size is a hint only — the engine may deliver more
        // or fewer frames. The core's internal accumulator makes analysis
        // independent of whatever size actually arrives.
        let core = self.core
        input.installTap(onBus: 0,
                         bufferSize: AVAudioFrameCount(AudioAnalysisCore.windowSize),
                         format: format) { buffer, _ in
            core.ingest(buffer)
        }

        do {
            try engine.start()
            self.audioEngine = engine
            self.inputNode = input
            self.isMicrophoneCapturing = true
            self.installConfigurationChangeObserver(for: engine)
            #if !os(macOS)
            self.installSessionObservers()
            #endif
            self.refreshCaptureState()
            self.errorMessage = nil
        } catch {
            self.teardownEngine()
            self.core.deactivate()
            self.isMicrophoneCapturing = false
            self.refreshCaptureState(resetLevelsWhenIdle: true)
            self.errorMessage = "Failed to start audio: \(error.localizedDescription)"
        }
    }

    private func teardownEngine() {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
        configurationChangeObserver = nil
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        inputNode = nil
    }

    // MARK: - Device-change recovery

    /// AVAudioEngine stops itself when the input hardware changes (default
    /// device switch, AirPods connect, unplugged interface, wake). Without
    /// this observer the tap silently dies while the UI still claims the mic
    /// is live.
    private func installConfigurationChangeObserver(for engine: AVAudioEngine) {
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEngineRestart() }
        }
    }

    private func scheduleEngineRestart() {
        guard isMicrophoneCapturing, restartTask == nil else { return }
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.restartDebounce)
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            self.restartCaptureAfterConfigurationChange()
        }
    }

    private func restartCaptureAfterConfigurationChange() {
        guard isMicrophoneCapturing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        restartAttempts.removeAll { now - $0 > Self.restartAttemptWindow }

        teardownEngine()
        isMicrophoneCapturing = false

        guard restartAttempts.count < Self.maxRestartAttempts else {
            core.deactivate()
            refreshCaptureState(resetLevelsWhenIdle: true)
            errorMessage = "Audio input stopped after repeated device changes. Press Start to try again."
            return
        }
        restartAttempts.append(now)

        // Re-reads the (possibly new) device format and re-locks band indices.
        setupAudioCapture()
        refreshCaptureState(resetLevelsWhenIdle: true)
    }

    private func refreshCaptureState(resetLevelsWhenIdle: Bool = false) {
        isCapturing = isMicrophoneCapturing || isExternalCapturing
        if resetLevelsWhenIdle, !isCapturing {
            resetLevels()
        }
    }

    private func resetLevels() {
        level = 0
        bassLevel = 0
        midLevel = 0
        trebleLevel = 0
        onsetLevel = 0
        lastTickTime = 0
    }
}

// MARK: - Analysis core

/// Owns every piece of DSP state — FFT scratch, the sample accumulator, band
/// indices, silence gate, spectral-flux onset — behind one lock. Capture
/// threads call `ingest` synchronously (no per-buffer copies, Tasks, or actor
/// hops); the MainActor consumes smoothing targets once per display tick.
///
/// Analysis runs on fixed `windowSize`-frame windows regardless of how many
/// frames each capture callback delivers, so band and onset behavior is
/// identical for a 640-frame Bluetooth tap, a 4800-frame iPad tap, and
/// ScreenCaptureKit's ~960-frame cadence.
final class AudioAnalysisCore: @unchecked Sendable {

    /// FFT window length in frames. Also the hop: windows do not overlap, so
    /// the spectral-flux EMA time constant stays as tuned.
    static let windowSize = 2048

    struct Targets {
        var overall: Float = 0
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
        var onset: Float = 0
    }

    /// `os_unfair_lock` (not `NSLock`): the capture thread holds this during
    /// window analysis while the MainActor contends for targets. Unfair locks
    /// donate priority to the holder, so neither side can be starved by a
    /// preempted owner the way an NSLock waiter can.
    private let lock = OSAllocatedUnfairLock()

    /// Monotonic uptime of the most recent ingested buffer. Atomic rather than
    /// lock-guarded so `latestSampleTime` (read per source per frame on the
    /// MainActor) never touches the DSP lock.
    private let sampleTime = Atomic<TimeInterval>(0)

    // Everything below is guarded by `lock`.
    private var active = false
    private var sampleRate: Float = 48_000
    private var fftSetup: vDSP_DFT_Setup?
    private var windowBuffer: [Float]
    private var windowedSamples: [Float]
    private var imagInput: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudeBuffer: [Float]
    private var prevMagnitudeBuffer: [Float]

    /// Mono samples awaiting a full analysis window.
    private var pending: [Float] = []
    /// Reused scratch for the selected channel of the incoming buffer.
    private var monoScratch: [Float] = []

    // Band boundary bins (inclusive on both ends; bands abut with no gaps).
    private var bassStartBin = 0
    private var bassEndBin = 0
    private var midEndBin = 0
    private var trebleEndBin = 0

    // Spectral-flux onset state
    private var fluxBaseline: Float = 0
    private var fluxFrameCount: Int = 0
    private var needsFluxReseed = true

    // Silence gate with hysteresis: enter after `gateEnterCount` consecutive
    // quiet buffers (~-75 dBFS), exit immediately above ~-65 dBFS. The dead
    // band prevents room-tone flicker at a single threshold.
    private let gateEnterRMS: Float = 0.00018
    private let gateExitRMS: Float = 0.00056
    private let gateEnterCount = 3
    private var gated = false
    private var quietBufferCount = 0

    // Perceptual mapping: normalized position of the level in dBFS between
    // floor and ceiling, with a mild gamma. Replaces linear RMS × fixed gain,
    // which crushed everything above ~-20 dBFS into the top of the range.
    private let levelFloorDB: Float = -60
    private let levelCeilingDB: Float = -8
    private let levelGamma: Float = 0.8

    private var targets = Targets()

    /// Targets older than this are treated as silence by `consumeTargets` —
    /// a stalled capture route decays visuals instead of freezing them.
    private let targetStaleAge: TimeInterval = 0.25

    init() {
        let n = Self.windowSize
        let half = n / 2
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)
        windowBuffer = [Float](repeating: 0, count: n)
        windowedSamples = [Float](repeating: 0, count: n)
        imagInput = [Float](repeating: 0, count: n)
        realBuffer = [Float](repeating: 0, count: n)
        imagBuffer = [Float](repeating: 0, count: n)
        magnitudeBuffer = [Float](repeating: 0, count: half)
        prevMagnitudeBuffer = [Float](repeating: 0, count: half)
        vDSP_hann_window(&windowBuffer, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        computeBandIndices()
        // Pre-size the capture-thread buffers so steady-state ingestion never
        // allocates while holding the lock.
        pending.reserveCapacity(Self.windowSize * 8)
        monoScratch = [Float](repeating: 0, count: 4096)
    }

    deinit {
        if let fftSetup {
            vDSP_DFT_DestroySetup(fftSetup)
        }
    }

    // MARK: Lifecycle

    func activate(sampleRate rate: Float) {
        lock.lock()
        defer { lock.unlock() }
        if rate > 0, abs(rate - sampleRate) > 1 {
            sampleRate = rate
            computeBandIndices()
        }
        resetAnalysisState()
        active = true
        sampleTime.store(0, ordering: .relaxed)
    }

    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        resetAnalysisState()
        sampleTime.store(0, ordering: .relaxed)
    }

    var latestSampleTime: TimeInterval {
        sampleTime.load(ordering: .relaxed)
    }

    /// Latest smoothing targets, or nil when the core is inactive. Onset is
    /// consumed (reset to zero) on read; continuous levels persist between
    /// windows. Targets stale by more than `targetStaleAge` read as silence.
    func consumeTargets(now: TimeInterval) -> Targets? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        let latest = sampleTime.load(ordering: .relaxed)
        guard latest > 0, now - latest <= targetStaleAge else {
            targets.onset = 0
            return Targets()
        }
        let current = targets
        targets.onset = 0
        return current
    }

    // MARK: Ingestion

    /// Consume a PCM buffer synchronously on the calling (capture) thread.
    /// Float32 only — both AVAudioEngine input taps and ScreenCaptureKit
    /// deliver Float32 PCM.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0,
              channelCount > 0,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else { return }

        lock.lock()
        defer { lock.unlock() }
        guard active, fftSetup != nil else { return }

        // Follow the delivered rate, not the configured one — a device swap
        // mid-capture or an SCK stream that ignores the requested rate would
        // otherwise shift every band boundary.
        let deliveredRate = Float(buffer.format.sampleRate)
        if deliveredRate > 0, abs(deliveredRate - sampleRate) > 1 {
            sampleRate = deliveredRate
            computeBandIndices()
            resetAnalysisState()
        }

        sampleTime.store(ProcessInfo.processInfo.systemUptime, ordering: .relaxed)

        // Analyze the strongest channel. Some interfaces and virtual devices
        // put their live signal on a channel other than channel zero, and for
        // hard-panned stereo content the hot side carries the information.
        let isInterleaved = buffer.format.isInterleaved
        let sampleStride = isInterleaved ? vDSP_Stride(channelCount) : vDSP_Stride(1)
        var selected = channelData[0]
        var rms: Float = 0
        for channel in 0..<channelCount {
            let channelSamples = isInterleaved
                ? channelData[0].advanced(by: channel)
                : channelData[channel]
            var channelRMS: Float = 0
            vDSP_rmsqv(channelSamples, sampleStride, &channelRMS, vDSP_Length(frameLength))
            if channel == 0 || channelRMS > rms {
                rms = channelRMS
                selected = channelSamples
            }
        }

        // Non-finite RMS means the buffer contains NaN/Inf samples (possible
        // after wake-from-sleep with a bad capture buffer). Read as silence.
        guard rms.isFinite else {
            targets = Targets()
            pending.removeAll(keepingCapacity: true)
            return
        }

        // Silence gate with hysteresis so paused music and quiet rooms decay
        // to zero without flickering at a single threshold.
        if rms < gateEnterRMS {
            quietBufferCount += 1
        } else {
            quietBufferCount = 0
        }
        if !gated, quietBufferCount >= gateEnterCount {
            gated = true
            pending.removeAll(keepingCapacity: true)
            // Re-seed the flux comparison when sound returns, so resuming
            // audio against a minutes-old spectrum doesn't fire a phantom drop.
            needsFluxReseed = true
        }
        if gated {
            if rms >= gateExitRMS {
                gated = false
                quietBufferCount = 0
            } else {
                targets = Targets()
                return
            }
        }

        targets.overall = perceptualLevel(rms)

        // De-interleave the selected channel and accumulate toward full
        // analysis windows. A single delivery larger than the accumulator
        // bound (~0.3 s of audio) is a discontinuity, not a backlog — keep
        // only the freshest samples and re-seed the flux comparison so the
        // splice can't read as a drop.
        var copyStart = 0
        if frameLength > Self.windowSize * 8 {
            copyStart = frameLength - Self.windowSize * 2
            pending.removeAll(keepingCapacity: true)
            needsFluxReseed = true
        }
        let copyCount = frameLength - copyStart
        if monoScratch.count < copyCount {
            monoScratch = [Float](repeating: 0, count: copyCount)
        }
        let strideInt = Int(sampleStride)
        monoScratch.withUnsafeMutableBufferPointer { dst in
            for i in 0..<copyCount {
                dst[i] = selected[(copyStart + i) * strideInt]
            }
        }
        pending.append(contentsOf: monoScratch[0..<copyCount])

        // Drain full windows through a read offset — one compaction memmove
        // per ingest instead of one per window. Band targets max-merge across
        // the windows of a single delivery, so a loud window can't be
        // discarded by a quieter one arriving in the same buffer. Every
        // window is still analyzed: spectral-flux onset depends on
        // consecutive-window comparison.
        var offset = 0
        var mergedBands: (bass: Float, mid: Float, treble: Float)?
        while pending.count - offset >= Self.windowSize {
            if let bands = analyzeWindow(at: offset) {
                mergedBands = mergedBands.map {
                    (max($0.bass, bands.bass), max($0.mid, bands.mid), max($0.treble, bands.treble))
                } ?? bands
            }
            offset += Self.windowSize
        }
        if offset > 0 {
            pending.removeFirst(offset)
        }
        if let mergedBands {
            targets.bass = mergedBands.bass
            targets.mid = mergedBands.mid
            targets.treble = mergedBands.treble
        }
    }

    // MARK: Window analysis (lock held)

    /// Analyze one window starting at `offset` into `pending` and return its
    /// band levels (nil if the DFT setup is unavailable). Onset max-accumulates
    /// directly into `targets`; band levels are returned so the caller can
    /// merge across the windows of one delivery.
    private func analyzeWindow(at offset: Int) -> (bass: Float, mid: Float, treble: Float)? {
        guard let fftSetup else { return nil }
        let n = Self.windowSize
        let half = n / 2

        pending.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress! + offset, 1, windowBuffer, 1, &windowedSamples, 1, vDSP_Length(n))
        }
        vDSP_vclr(&imagInput, 1, vDSP_Length(n))
        vDSP_DFT_Execute(fftSetup, &windowedSamples, &imagInput, &realBuffer, &imagBuffer)

        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvabs(&splitComplex, 1, &magnitudeBuffer, 1, vDSP_Length(half))
            }
        }
        var scale: Float = 2.0 / Float(n)
        vDSP_vsmul(magnitudeBuffer, 1, &scale, &magnitudeBuffer, 1, vDSP_Length(half))

        // Integrate spectral energy across each band (inclusive bin ranges).
        // An average would dilute a tone by every empty FFT bin in its band.
        let bass = perceptualLevel(bandAmplitude(from: bassStartBin, through: bassEndBin))
        let mid = perceptualLevel(bandAmplitude(from: bassEndBin + 1, through: midEndBin))
        let treble = perceptualLevel(bandAmplitude(from: midEndBin + 1, through: trebleEndBin))

        updateOnset(half: half)
        return (bass, mid, treble)
    }

    private func bandAmplitude(from start: Int, through end: Int) -> Float {
        guard end >= start, start >= 0, end < magnitudeBuffer.count else { return 0 }
        var energy: Float = 0
        magnitudeBuffer.withUnsafeBufferPointer { ptr in
            vDSP_svesq(ptr.baseAddress! + start, 1, &energy, vDSP_Length(end - start + 1))
        }
        let amplitude = sqrt(max(0, energy))
        return amplitude.isFinite ? amplitude : 0
    }

    /// Spectral-flux onset detection (the "Drop" signal): the sum of positive
    /// per-bin magnitude increases vs the previous window. A transient raises
    /// many bins at once → large flux; sustained sound has near-zero flux. An
    /// EMA baseline acts as an adaptive threshold so only above-average jumps
    /// register, making the detector level-independent.
    private func updateOnset(half: Int) {
        if needsFluxReseed {
            // First window after (re)start or gate exit: seed the comparison
            // spectrum and warm-up counter without emitting an onset.
            copyMagnitudesToPrevious(half: half)
            fluxBaseline = 0
            fluxFrameCount = 0
            needsFluxReseed = false
            return
        }

        var flux: Float = 0
        let fluxEnd = max(2, min(half, trebleEndBin))  // ignore very-high noise bins
        for i in 1..<fluxEnd {
            let d = magnitudeBuffer[i] - prevMagnitudeBuffer[i]
            if d > 0 { flux += d }
        }
        fluxFrameCount += 1
        if fluxFrameCount == 1 {
            fluxBaseline = flux                               // seed at the right magnitude
        } else {
            fluxBaseline = fluxBaseline * 0.96 + flux * 0.04  // slow EMA: a spike barely moves its own threshold
        }
        if fluxFrameCount > 8 {  // warm-up so startup doesn't false-trigger
            let excess = max(0, flux - fluxBaseline * 1.5)
            let onset = min(1.0, excess / max(fluxBaseline, 1e-3) * 0.6)
            // Max-accumulated until the display tick consumes it, so a hit
            // between ticks is never dropped.
            targets.onset = max(targets.onset, onset)
        }
        copyMagnitudesToPrevious(half: half)
    }

    private func copyMagnitudesToPrevious(half: Int) {
        prevMagnitudeBuffer.withUnsafeMutableBufferPointer { dst in
            magnitudeBuffer.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: half)
            }
        }
    }

    // MARK: Helpers (lock held)

    private func computeBandIndices() {
        let half = Self.windowSize / 2
        let binWidth = sampleRate / Float(Self.windowSize)
        bassStartBin = max(1, Int(20.0 / binWidth))
        bassEndBin = min(half - 1, Int(250.0 / binWidth))
        midEndBin = min(half - 1, Int(2000.0 / binWidth))
        trebleEndBin = min(half - 1, Int(8000.0 / binWidth))
    }

    private func resetAnalysisState() {
        pending.removeAll(keepingCapacity: true)
        targets = Targets()
        fluxBaseline = 0
        fluxFrameCount = 0
        needsFluxReseed = true
        gated = false
        quietBufferCount = 0
    }

    private func perceptualLevel(_ amplitude: Float) -> Float {
        guard amplitude > 0, amplitude.isFinite else { return 0 }
        let db = 20 * log10(amplitude)
        let normalized = min(1, max(0, (db - levelFloorDB) / (levelCeilingDB - levelFloorDB)))
        return pow(normalized, levelGamma)
    }
}
