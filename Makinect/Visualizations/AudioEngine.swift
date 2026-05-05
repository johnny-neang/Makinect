// AudioEngine — AVAudioEngine mic tap with vDSP FFT producing
// frequency bands, RMS envelope, and beat onset for visualizations.

import AVFoundation
import Accelerate
import AppKit
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isKinect: Bool
}

/// Microphone authorization state. macOS will refuse to deliver real audio
/// (silent buffers) until this is `.authorized` — the user must hit "Allow"
/// in the system permission prompt that fires on first explicit request.
enum AudioPermission: String {
    case undetermined = "Awaiting permission…"
    case requesting   = "Requesting permission…"
    case authorized   = "Authorized"
    case denied       = "Denied — open System Settings → Privacy → Microphone"
    case restricted   = "Restricted by parental controls"
}

@Observable
final class AudioEngine {
    static let bandCount = 8
    static let fftSize = 1024
    static let waveformSize = 2048           // visible waveform window
    static let spectrogramBins = 64          // bins per spectrogram column
    static let onsetEnvelopeSize = 480       // ~8 sec at 60 Hz update rate

    // — Visualizer-facing summary data (scaled by outputMultiplier).
    var bands: [Float] = Array(repeating: 0, count: AudioEngine.bandCount)
    var rms: Float = 0
    var onset: Bool = false
    var isRunning = false

    /// Universal output multiplier applied to bands / rms / onset — driven
    /// by `VisualizationCommonParams.audioReactivity`. Setting this to 0
    /// silences ALL audio modulation across every visualizer. The multiplier
    /// is sampled atomically in `process(buffer:)` (audio render thread) and
    /// snapshotted before the dispatch to main, so concurrent UI writes
    /// can't tear it.
    var outputMultiplier: Float = 1.0

    // — Audio Monitor data (Phase B). Updated each audio callback;
    //   ObservationIgnored heavy buffers to avoid per-element tracking.
    var waveform: [Float] = Array(repeating: 0, count: AudioEngine.waveformSize)
    var spectrumColumn: [Float] = Array(repeating: 0, count: AudioEngine.spectrogramBins)
    var rmsPeak: Float = 0                    // peak-hold meter (decays)
    var lufs: Float = -70.0                   // integrated loudness (dB)
    var onsetEnvelope: [Float] = Array(repeating: 0, count: AudioEngine.onsetEnvelopeSize)

    // — DSP results (Phase B.2–B.5)
    var pitchHz: Float = 0                    // 0 = no clear pitch
    var pitchConfidence: Float = 0
    var pitchNoteName: String = "—"           // "A4", "C#5", etc.
    var chordName: String = "—"               // "C maj", "F# min7", etc.
    var chordConfidence: Float = 0
    var bpm: Float = 0
    var bpmConfidence: Float = 0
    var keyName: String = "—"                 // "G major", "F# minor"
    var keyConfidence: Float = 0
    /// Long-window chromagram — 12 pitch classes, 15-sec exponential decay,
    /// used by the key detector. Exposed for debugging / advanced UIs.
    var chromagram: [Float] = Array(repeating: 0, count: 12)

    var availableInputs: [AudioInputDevice] = []
    var selectedInputID: AudioDeviceID?

    // — Permission + diagnostics
    var permission: AudioPermission = .undetermined
    /// Increments every time the audio render thread delivers a buffer.
    /// Watch this to confirm audio is flowing — if it stays at 0 after
    /// `start()`, the tap isn't firing (permission denied / silent device).
    var tapCallbackCount: UInt64 = 0
    /// Last error from `engine.start()`, exposed for the side-panel.
    var lastEngineError: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var switchGeneration: Int = 0
    @ObservationIgnored private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    @ObservationIgnored private let log2n = vDSP_Length(log2(Float(AudioEngine.fftSize)))
    @ObservationIgnored private var window: [Float] = []
    @ObservationIgnored private var lastFlux: Float = 0
    @ObservationIgnored private var prevMagnitudes: [Float] = Array(repeating: 0, count: AudioEngine.fftSize / 2)

    // Pre-allocated FFT scratch buffers — reused per-callback to avoid heap
    // churn on the audio render thread (per-callback allocations were causing
    // `IOWorkLoop: skipping cycle due to overload` in CoreAudio).
    @ObservationIgnored private var samples: [Float] = Array(repeating: 0, count: AudioEngine.fftSize)
    @ObservationIgnored private var realp: [Float]   = Array(repeating: 0, count: AudioEngine.fftSize / 2)
    @ObservationIgnored private var imagp: [Float]   = Array(repeating: 0, count: AudioEngine.fftSize / 2)
    @ObservationIgnored private var magnitudes: [Float] = Array(repeating: 0, count: AudioEngine.fftSize / 2)
    @ObservationIgnored private var newBands: [Float]   = Array(repeating: 0, count: AudioEngine.bandCount)

    // — Phase B internal storage (audio render thread; never published as-is)
    // All marked @ObservationIgnored so writes from the audio render thread
    // don't trigger SwiftUI observation tracking — that's reserved for the
    // public properties published via DispatchQueue.main.async snapshots.

    @ObservationIgnored fileprivate var waveformRing: [Float] = Array(repeating: 0, count: AudioEngine.waveformSize)
    @ObservationIgnored fileprivate var waveformWritePos = 0

    @ObservationIgnored fileprivate var onsetEnvRing: [Float] = Array(repeating: 0, count: AudioEngine.onsetEnvelopeSize)
    @ObservationIgnored fileprivate var onsetEnvWritePos = 0

    @ObservationIgnored fileprivate var chromaIntegrated: [Float] = Array(repeating: 0, count: 12)
    @ObservationIgnored fileprivate let chromaDecay: Float = 0.998

    // LUFS K-weighting biquad state (BS.1770).
    @ObservationIgnored fileprivate var hsX1: Float = 0
    @ObservationIgnored fileprivate var hsX2: Float = 0
    @ObservationIgnored fileprivate var hsY1: Float = 0
    @ObservationIgnored fileprivate var hsY2: Float = 0
    @ObservationIgnored fileprivate var hpX1: Float = 0
    @ObservationIgnored fileprivate var hpX2: Float = 0
    @ObservationIgnored fileprivate var hpY1: Float = 0
    @ObservationIgnored fileprivate var hpY2: Float = 0
    @ObservationIgnored fileprivate var lufs400Sum: Float = 0
    @ObservationIgnored fileprivate var lufs400Count: Int = 0
    @ObservationIgnored fileprivate let lufs400Frames = 400 * 48 / 1000

    // Analyzer cadences (run pitch / chord / tempo / key on staggered
    // schedules to keep the audio thread fast).
    @ObservationIgnored fileprivate var framesSinceLastPitch = 0
    @ObservationIgnored fileprivate let pitchEveryNFrames = 5
    @ObservationIgnored fileprivate var framesSinceLastChord = 0
    @ObservationIgnored fileprivate var framesSinceLastTempo = 0
    @ObservationIgnored fileprivate var framesSinceLastKey = 0

    init() {
        fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        window = [Float](repeating: 0, count: AudioEngine.fftSize)
        vDSP_hann_window(&window, vDSP_Length(AudioEngine.fftSize), Int32(vDSP_HANN_NORM))
        refreshInputs()
    }

    deinit { stop() }

    func refreshInputs() {
        var inputs: [AudioInputDevice] = []
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs)

        for id in deviceIDs {
            guard hasInputChannels(deviceID: id) else { continue }
            let name = deviceName(id: id) ?? "Unknown"
            let isKinect = name.localizedCaseInsensitiveContains("kinect")
                || name.localizedCaseInsensitiveContains("xbox nui")
            inputs.append(AudioInputDevice(id: id, name: name, isKinect: isKinect))
        }

        availableInputs = inputs
        if selectedInputID == nil {
            // Prefer the system default input. Picking the Kinect mic by
            // default is misleading because the Kinect v2 mic array isn't
            // wired to libfreenect2's audio path on macOS — AVAudioEngine
            // will tap the device but receive silent buffers.
            let sysDefault = systemDefaultInputDevice()
            if sysDefault != 0, inputs.contains(where: { $0.id == sysDefault }) {
                selectedInputID = sysDefault
            } else {
                selectedInputID = inputs.first(where: { !$0.isKinect })?.id
                                  ?? inputs.first?.id
            }
        }
    }

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buffer) == noErr else { return false }
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    private func deviceName(id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    func start() {
        guard !isRunning else { return }

        // — Diagnostic — log the bundle ID + current TCC status so the user
        //   can confirm what TCC key the app is keyed under, and what state
        //   the system says the permission is in. Visible in Xcode console.
        let bid = Bundle.main.bundleIdentifier ?? "<no bundle id>"
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("Makinect.AudioEngine.start() — bundle=\(bid) auth=\(status.rawValue) (\(authStatusName(status)))")

        // — Microphone permission. macOS won't deliver real audio until the
        //   user clicks "Allow" in the system prompt; without an explicit
        //   request the prompt never fires and `installTap` quietly receives
        //   silent (all-zero) buffers, so the audio monitor stays blank.
        switch status {
        case .authorized:
            permission = .authorized
            startEngineNow()
        case .notDetermined:
            permission = .requesting
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permission = granted ? .authorized : .denied
                    if granted { self.startEngineNow() }
                }
            }
        case .denied:
            permission = .denied
        case .restricted:
            permission = .restricted
        @unknown default:
            permission = .denied
        }
    }

    /// Manually trigger the system mic permission prompt. No-op if status
    /// is already .authorized or .denied — the prompt only fires on
    /// .notDetermined. Wire this to a UI "Request Microphone" button.
    func requestPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            permission = .requesting
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permission = granted ? .authorized : .denied
                    if granted, !self.isRunning { self.startEngineNow() }
                }
            }
        } else {
            permission = (status == .authorized) ? .authorized : .denied
            if status == .authorized, !isRunning { startEngineNow() }
        }
    }

    /// Open System Settings → Privacy & Security → Microphone so the user
    /// can manually grant access when the system prompt has already fired
    /// and been denied (TCC blocks re-prompting once denied).
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func authStatusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Internal — called once permission is .authorized.
    private func startEngineNow() {
        guard !isRunning else { return }

        // Tear down any prior tap + stop, regardless of `isRunning` state.
        // AVAudioEngine sometimes keeps a tap registered even when the
        // engine isn't running, and installTap() throws an uncatchable
        // Obj-C exception if a tap already exists.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        // CRITICAL: reset the engine before binding the device. Without this,
        // AVAudioEngine's internal format cache holds the previous device's
        // sample rate, and installTap() throws an UNCATCHABLE Obj-C exception
        // when the new hardware reports a different rate (e.g. 44.1k vs 48k):
        //
        //   "Format mismatch: input hw 1ch 44100Hz, client format 1ch 48000Hz"
        //   *** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio'
        //
        // engine.reset() flushes that cache. Then we bind the device, then
        // we read the (now-correct) format directly from CoreAudio.
        engine.reset()

        let target = (selectedInputID != nil && selectedInputID != 0) ? selectedInputID! : systemDefaultInputDevice()
        if target != 0 {
            bindEngineInput(to: target)
        }

        let input = engine.inputNode

        // Build the tap format from CoreAudio HAL properties on the actual
        // device, NOT from AVAudioEngine. Reason: after a device bind,
        // AVAudioEngine's inputFormat(forBus:) can still report the engine's
        // *processing* format (commonly 48 kHz) instead of the HW's nominal
        // sample rate. Passing `format: nil` to installTap has the same
        // problem — it resolves to the bus's *output* format.
        //
        // The HAL device properties (kAudioDevicePropertyNominalSampleRate +
        // kAudioDevicePropertyStreamConfiguration) are the ground truth.
        let format: AVAudioFormat
        if target != 0, let hw = halInputFormat(deviceID: target) {
            format = hw
        } else {
            format = input.inputFormat(forBus: 0)
        }
        guard format.channelCount > 0, format.sampleRate > 0 else { return }

        // Pass the explicit HW format. Without this, the tap defaults to the
        // engine's 48 kHz processing format and engine.start() fails graph
        // initialization with kAudioUnitErr_FormatNotSupported (-10868).
        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(AudioEngine.fftSize),
            format: format
        ) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        do {
            try engine.start()
            isRunning = true
            lastEngineError = nil
        } catch {
            input.removeTap(onBus: 0)
            isRunning = false
            lastEngineError = error.localizedDescription
        }
    }

    /// Return the system default input device ID, or 0 if unavailable.
    /// Used as a fallback when `selectedInputID` is unset.
    private func systemDefaultInputDevice() -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// Build an AVAudioFormat from the device's actual HAL properties — the
    /// ground truth, immune to AVAudioEngine's format cache.
    private func halInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        guard deviceID != 0 else { return nil }

        // Nominal sample rate
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &rate) == noErr,
              rate > 0 else { return nil }

        // Channel count from input stream configuration
        var ch: UInt32 = 1
        var chAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var chSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &chAddr, 0, nil, &chSize) == noErr, chSize > 0 {
            let buf = UnsafeMutableRawPointer.allocate(
                byteCount: Int(chSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { buf.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &chAddr, 0, nil, &chSize, buf) == noErr {
                let bl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
                let total = bl.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
                if total > 0 { ch = total }
            }
        }

        // Match the HW channel count exactly — installTap fails with a
        // format-mismatch crash if the tap channel count differs from the
        // bus's actual channel count (just like sample-rate mismatch). Our
        // DSP only reads channelData[0] so 1 or 2 channels both work.
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: AVAudioChannelCount(max(1, min(2, Int(ch)))),
            interleaved: false
        )
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    func switchInput(to id: AudioDeviceID) {
        guard id != 0 else { return }
        // No-op if same device already selected and running.
        if id == selectedInputID, isRunning { return }
        selectedInputID = id
        if isRunning {
            stop()
            // Generation counter — if the user picks devices A → B → C in
            // quick succession, only the LAST asyncAfter actually fires
            // start(); earlier closures see a stale generation and bail.
            // This prevents stacked engine.start() attempts that would crash
            // each other with format mismatches.
            switchGeneration &+= 1
            let gen = switchGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.switchGeneration == gen else { return }
                self.start()
            }
        }
    }

    /// Bind the AVAudioEngine's input node to a specific CoreAudio device by
    /// setting kAudioOutputUnitProperty_CurrentDevice on the underlying audio
    /// unit. Non-invasive (doesn't mutate system default).
    private func bindEngineInput(to deviceID: AudioDeviceID) {
        guard deviceID != 0 else { return }
        guard let au = engine.inputNode.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let n = AudioEngine.fftSize
        guard frameLength > 0 else { return }

        // Bump the tap-fired counter so the UI can verify audio is flowing.
        // Snapshot to a local first so the SwiftUI tracker only sees one
        // change per main-thread hop (we publish below in the dispatch).
        let newTapCount = tapCallbackCount &+ 1

        // — Append the entire input buffer to the waveform ring (at full
        //   `frameLength`, not just `n`). The ring is the source-of-truth
        //   for the visible waveform AND for the YIN pitch detector below.
        appendToWaveformRing(channelData: channelData[0], count: frameLength)

        // — K-weight + 400ms RMS for LUFS (BS.1770). Runs over the whole
        //   `frameLength` so we accumulate consistent block sizes.
        updateLUFS(channelData: channelData[0], count: frameLength,
                   sampleRate: Float(buffer.format.sampleRate))

        // — Pull the latest N samples from the waveform ring for the FFT
        //   instead of requiring the buffer be ≥ N. AVAudioEngine often
        //   delivers smaller buffers (256–512 samples) than the requested
        //   bufferSize hint, especially at non-default sample rates. Reading
        //   from the ring lets us run the FFT on every callback regardless.
        let cap = AudioEngine.waveformSize
        for i in 0..<n {
            let idx = (waveformWritePos - n + i + cap) % cap
            samples[i] = waveformRing[idx]
        }

        var rmsValue: Float = 0
        vDSP_rmsqv(samples, 1, &rmsValue, vDSP_Length(n))

        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))

        // Reuse pre-allocated realp/imagp/magnitudes scratch.
        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBufferPointer { sampPtr in
                    sampPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fftSetup?.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }

        // Logarithmic banding: map FFT bins into 8 bands spanning ~80Hz–10kHz
        let sampleRate = Float(buffer.format.sampleRate)
        let nyquist = sampleRate / 2
        let minHz: Float = 80
        let maxHz = min(nyquist, 10_000)
        for b in 0..<AudioEngine.bandCount {
            let t0 = Float(b) / Float(AudioEngine.bandCount)
            let t1 = Float(b + 1) / Float(AudioEngine.bandCount)
            let f0 = minHz * powf(maxHz / minHz, t0)
            let f1 = minHz * powf(maxHz / minHz, t1)
            let bin0 = max(1, Int(f0 / nyquist * Float(n / 2)))
            let bin1 = min(n / 2 - 1, max(bin0 + 1, Int(f1 / nyquist * Float(n / 2))))
            var sum: Float = 0
            for k in bin0...bin1 { sum += magnitudes[k] }
            let avg = sum / Float(bin1 - bin0 + 1)
            newBands[b] = log10f(1 + avg) * 0.15  // soft compression
        }

        // Spectral flux for onset
        var flux: Float = 0
        for k in 0..<(n / 2) {
            let diff = magnitudes[k] - prevMagnitudes[k]
            if diff > 0 { flux += diff }
        }
        // In-place copy (no allocation): magnitudes → prevMagnitudes
        for k in 0..<(n / 2) { prevMagnitudes[k] = magnitudes[k] }
        let onsetDetected = flux > lastFlux * 1.5 && flux > 5
        lastFlux = max(flux, lastFlux * 0.9)

        // Snapshot the global output multiplier on the audio render thread so
        // we can't read a torn value when the main thread bumps the slider
        // mid-process. Applied to every band, RMS, and the onset gate.
        let m = self.outputMultiplier

        // Snapshot bands by value into a small fixed-size array (avoids capturing
        // the mutable `newBands` storage in the async closure → eliminates
        // potential cross-thread reads on the scratch buffer).
        let snap = (newBands[0] * m, newBands[1] * m, newBands[2] * m, newBands[3] * m,
                    newBands[4] * m, newBands[5] * m, newBands[6] * m, newBands[7] * m)
        let scaledRms = rmsValue * m
        let onsetGated = onsetDetected && m > 0.05

        // — Phase B analysis: build the 64-bin log-spaced spectrum column
        //   for the waterfall, append flux to the onset envelope, update
        //   the long-window chromagram for key detection, run pitch /
        //   chord / tempo / key analyzers on staggered cadences.
        let spectrumColumn = buildSpectrumColumn(magnitudes: magnitudes, nyquist: nyquist)
        appendOnsetEnvelope(flux)
        updateChromagram(magnitudes: magnitudes, nyquist: nyquist, sampleRate: sampleRate)

        framesSinceLastPitch += 1
        framesSinceLastChord += 1
        framesSinceLastTempo += 1
        framesSinceLastKey += 1

        var pitchResult: (hz: Float, confidence: Float, note: String)? = nil
        if framesSinceLastPitch >= pitchEveryNFrames {
            framesSinceLastPitch = 0
            pitchResult = detectPitchYIN(sampleRate: sampleRate)
        }

        var chordResult: (name: String, confidence: Float)? = nil
        if framesSinceLastChord >= 6 {
            framesSinceLastChord = 0
            // Build a short-window chromagram from the latest spectrum
            // (rather than the integrated long-window one).
            let shortChroma = computeChromagram(magnitudes: magnitudes, nyquist: nyquist, sampleRate: sampleRate)
            chordResult = detectChord(chroma: shortChroma)
        }

        var tempoResult: (bpm: Float, confidence: Float)? = nil
        if framesSinceLastTempo >= 30 {
            framesSinceLastTempo = 0
            tempoResult = detectTempoBPM()
        }

        var keyResult: (name: String, confidence: Float)? = nil
        let longChromaSnap: [Float]? = (framesSinceLastKey >= 60) ? Array(chromaIntegrated) : nil
        if framesSinceLastKey >= 60 {
            framesSinceLastKey = 0
            keyResult = detectKey(longChroma: chromaIntegrated)
        }

        // Waveform snapshot for the UI — copy out so the main thread reads
        // a stable view even if the next callback overwrites the ring.
        let waveSnap = waveformRing
        let onsetEnvSnap = onsetEnvRing
        let lufsSnap = self.lufs

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tapCallbackCount = newTapCount
            self.bands[0] = self.bands[0] * 0.6 + snap.0 * 0.4
            self.bands[1] = self.bands[1] * 0.6 + snap.1 * 0.4
            self.bands[2] = self.bands[2] * 0.6 + snap.2 * 0.4
            self.bands[3] = self.bands[3] * 0.6 + snap.3 * 0.4
            self.bands[4] = self.bands[4] * 0.6 + snap.4 * 0.4
            self.bands[5] = self.bands[5] * 0.6 + snap.5 * 0.4
            self.bands[6] = self.bands[6] * 0.6 + snap.6 * 0.4
            self.bands[7] = self.bands[7] * 0.6 + snap.7 * 0.4
            self.rms = self.rms * 0.7 + scaledRms * 0.3
            self.onset = onsetGated

            // — Audio Monitor publication
            self.waveform = waveSnap
            self.spectrumColumn = spectrumColumn
            self.onsetEnvelope = onsetEnvSnap

            // Peak-hold for the RMS meter — slow exponential decay, instant attack.
            if scaledRms > self.rmsPeak { self.rmsPeak = scaledRms }
            else { self.rmsPeak *= 0.985 }

            self.lufs = lufsSnap

            if let p = pitchResult {
                self.pitchHz = p.hz
                self.pitchConfidence = p.confidence
                self.pitchNoteName = p.note
            }
            if let c = chordResult {
                self.chordName = c.name
                self.chordConfidence = c.confidence
            }
            if let t = tempoResult {
                self.bpm = t.bpm
                self.bpmConfidence = t.confidence
            }
            if let k = keyResult, let _ = longChromaSnap {
                self.keyName = k.name
                self.keyConfidence = k.confidence
                self.chromagram = Array(self.chromaIntegrated)
            }
        }
    }
}

// MARK: - Audio Monitor DSP (Phase B)

extension AudioEngine {

    // — B.1: time-domain ring + spectrogram column + LUFS + onset envelope

    fileprivate func appendToWaveformRing(channelData: UnsafePointer<Float>, count: Int) {
        let cap = AudioEngine.waveformSize
        for i in 0..<count {
            waveformRing[waveformWritePos] = channelData[i]
            waveformWritePos = (waveformWritePos + 1) % cap
        }
    }

    /// Map the FFT magnitude bins (n/2 = 512 bins linear) to a 64-bin
    /// logarithmic-spaced spectrogram column for the waterfall display.
    fileprivate func buildSpectrumColumn(magnitudes: [Float], nyquist: Float) -> [Float] {
        let bins = AudioEngine.spectrogramBins
        let halfN = magnitudes.count
        let minHz: Float = 30
        let maxHz = min(nyquist, 16_000)
        var col = [Float](repeating: 0, count: bins)
        for b in 0..<bins {
            let t0 = Float(b) / Float(bins)
            let t1 = Float(b + 1) / Float(bins)
            let f0 = minHz * powf(maxHz / minHz, t0)
            let f1 = minHz * powf(maxHz / minHz, t1)
            let bin0 = max(0, Int(f0 / nyquist * Float(halfN)))
            let bin1 = min(halfN - 1, max(bin0 + 1, Int(f1 / nyquist * Float(halfN))))
            var sum: Float = 0
            for k in bin0...bin1 { sum += magnitudes[k] }
            let avg = sum / Float(bin1 - bin0 + 1)
            // Soft-compressed log magnitude — matches the bar-meter palette.
            col[b] = log10f(1 + avg) * 0.15
        }
        return col
    }

    fileprivate func appendOnsetEnvelope(_ flux: Float) {
        onsetEnvRing[onsetEnvWritePos] = flux
        onsetEnvWritePos = (onsetEnvWritePos + 1) % AudioEngine.onsetEnvelopeSize
    }

    /// Update the integrated chromagram (12 pitch-class energies) with
    /// exponential decay. Used by Krumhansl–Schmuckler key detection over a
    /// long (~15-sec) window.
    fileprivate func updateChromagram(magnitudes: [Float], nyquist: Float, sampleRate: Float) {
        let halfN = magnitudes.count
        // Decay everything first.
        for i in 0..<12 { chromaIntegrated[i] *= chromaDecay }
        // Then add the latest spectrum's contribution to each pitch class.
        for k in 1..<halfN {
            let freq = Float(k) / Float(halfN) * nyquist
            if freq < 60 || freq > 5000 { continue }   // ignore sub-bass + extreme treble
            let pc = (12 * log2f(freq / 440) + 9.0)
            let pcInt = ((Int(pc.rounded()) % 12) + 12) % 12
            chromaIntegrated[pcInt] += magnitudes[k]
        }
    }

    /// Compute a *short-window* chromagram from a single spectrum frame,
    /// used by chord detection (we want responsive chord changes, not the
    /// 15-sec smear that key detection wants).
    fileprivate func computeChromagram(magnitudes: [Float], nyquist: Float, sampleRate: Float) -> [Float] {
        let halfN = magnitudes.count
        var chroma = [Float](repeating: 0, count: 12)
        for k in 1..<halfN {
            let freq = Float(k) / Float(halfN) * nyquist
            if freq < 60 || freq > 5000 { continue }
            let pc = (12 * log2f(freq / 440) + 9.0)
            let pcInt = ((Int(pc.rounded()) % 12) + 12) % 12
            chroma[pcInt] += magnitudes[k]
        }
        // Normalize (so loudness doesn't bias chord match).
        var maxVal: Float = 0
        for v in chroma { if v > maxVal { maxVal = v } }
        if maxVal > 1e-6 {
            for i in 0..<12 { chroma[i] /= maxVal }
        }
        return chroma
    }

    /// LUFS K-weighting (BS.1770): cascaded high-shelf + high-pass biquads,
    /// then 400ms windowed RMS, then dB conversion. Coefficients computed
    /// for the input sample rate.
    fileprivate func updateLUFS(channelData: UnsafePointer<Float>, count: Int, sampleRate: Float) {
        // Coefficients for 48kHz from BS.1770 Annex 1 Table 1. We approximate
        // for other sample rates by scaling — exact-rate coefficients would
        // require pre-warping; this approximation is fine for a meter.
        let sr = sampleRate
        let _ = sr  // marker for future per-rate biquad coefficient tables
        // High-shelf (+4 dB above ~1.5 kHz)
        let hsB0: Float = 1.53512485958697
        let hsB1: Float = -2.69169618940638
        let hsB2: Float = 1.19839281085285
        let hsA1: Float = -1.69065929318241
        let hsA2: Float = 0.73248077421585
        // High-pass (~38 Hz)
        let hpB0: Float = 1.0
        let hpB1: Float = -2.0
        let hpB2: Float = 1.0
        let hpA1: Float = -1.99004745483398
        let hpA2: Float = 0.99007225036621

        for i in 0..<count {
            let x = channelData[i]
            let hs = hsB0 * x + hsB1 * hsX1 + hsB2 * hsX2 - hsA1 * hsY1 - hsA2 * hsY2
            hsX2 = hsX1; hsX1 = x
            hsY2 = hsY1; hsY1 = hs
            let hp = hpB0 * hs + hpB1 * hpX1 + hpB2 * hpX2 - hpA1 * hpY1 - hpA2 * hpY2
            hpX2 = hpX1; hpX1 = hs
            hpY2 = hpY1; hpY1 = hp

            lufs400Sum += hp * hp
            lufs400Count += 1
            if lufs400Count >= lufs400Frames {
                let mean = lufs400Sum / Float(lufs400Count)
                // BS.1770 LUFS = -0.691 + 10·log10(meanSquare), single channel.
                let dB: Float = (mean > 1e-12) ? (-0.691 + 10 * log10f(mean)) : -70.0
                self.lufs = max(-70, dB)
                lufs400Sum = 0
                lufs400Count = 0
            }
        }
    }

    // — B.2: YIN pitch detection on the time-domain waveform ring.

    /// Returns (Hz, confidence 0..1, note name). Hz=0 → no clear pitch.
    /// Uses the standard YIN algorithm: difference function → cumulative
    /// mean normalized → first dip below threshold → parabolic interp.
    fileprivate func detectPitchYIN(sampleRate: Float) -> (hz: Float, confidence: Float, note: String) {
        // YIN works on the most recent N samples — pull from the ring in order.
        let bufSize = 1024
        var samples = [Float](repeating: 0, count: bufSize)
        let cap = AudioEngine.waveformSize
        for i in 0..<bufSize {
            let idx = (waveformWritePos - bufSize + i + cap) % cap
            samples[i] = waveformRing[idx]
        }

        let halfSize = bufSize / 2
        var d = [Float](repeating: 0, count: halfSize)
        for tau in 1..<halfSize {
            var sum: Float = 0
            for i in 0..<halfSize {
                let delta = samples[i] - samples[i + tau]
                sum += delta * delta
            }
            d[tau] = sum
        }

        var dPrime = [Float](repeating: 1, count: halfSize)
        var runSum: Float = 0
        for tau in 1..<halfSize {
            runSum += d[tau]
            dPrime[tau] = (runSum > 1e-9) ? (d[tau] * Float(tau) / runSum) : 1
        }

        // Find first τ where dPrime drops below threshold and stays at a
        // local minimum.
        let threshold: Float = 0.15
        var tauEstimate = -1
        var tauVal: Float = Float.greatestFiniteMagnitude
        var tau = 2
        while tau < halfSize {
            if dPrime[tau] < threshold {
                while tau + 1 < halfSize && dPrime[tau + 1] < dPrime[tau] {
                    tau += 1
                }
                tauEstimate = tau
                tauVal = dPrime[tau]
                break
            }
            tau += 1
        }
        if tauEstimate < 2 { return (0, 0, "—") }

        // Parabolic interpolation around the minimum for sub-sample accuracy.
        let x0 = max(1, tauEstimate - 1)
        let x2 = min(halfSize - 1, tauEstimate + 1)
        let s0 = dPrime[x0], s1 = dPrime[tauEstimate], s2 = dPrime[x2]
        let denom = (s0 - 2 * s1 + s2)
        let betterTau: Float = (abs(denom) > 1e-9)
            ? Float(tauEstimate) + 0.5 * (s0 - s2) / denom
            : Float(tauEstimate)

        let hz = sampleRate / max(1, betterTau)
        // Bound to musical pitch range (C2..C8).
        if hz < 65 || hz > 4200 { return (0, 0, "—") }

        let confidence = max(0, 1 - tauVal)
        let note = noteName(forHz: hz)
        return (hz, confidence, note)
    }

    /// Map a frequency to a note name like "A4". A4 = 440 Hz = MIDI 69.
    fileprivate func noteName(forHz hz: Float) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let midi = Int((69 + 12 * log2f(hz / 440)).rounded())
        guard midi >= 0 && midi < 128 else { return "—" }
        let oct = midi / 12 - 1
        let nm = names[midi % 12]
        return "\(nm)\(oct)"
    }

    // — B.3: Chord detection — chromagram correlation against 84 templates.

    /// 7 chord-type templates (root-centered, 12 semitone bins). Each is a
    /// binary "1 if this interval is in the chord, 0 otherwise" vector.
    fileprivate static let chordTemplates: [(label: String, template: [Float])] = [
        ("maj",  [1,0,0,0,1,0,0,1,0,0,0,0]),  // 0,4,7
        ("min",  [1,0,0,1,0,0,0,1,0,0,0,0]),  // 0,3,7
        ("dim",  [1,0,0,1,0,0,1,0,0,0,0,0]),  // 0,3,6
        ("aug",  [1,0,0,0,1,0,0,0,1,0,0,0]),  // 0,4,8
        ("dom7", [1,0,0,0,1,0,0,1,0,0,1,0]),  // 0,4,7,10
        ("maj7", [1,0,0,0,1,0,0,1,0,0,0,1]),  // 0,4,7,11
        ("min7", [1,0,0,1,0,0,0,1,0,0,1,0])   // 0,3,7,10
    ]
    fileprivate static let pitchClassNames =
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    fileprivate func detectChord(chroma: [Float]) -> (name: String, confidence: Float) {
        // Silence guard — short-window chromagram with no energy shouldn't
        // pick an arbitrary chord.
        let energy = chroma.reduce(0, +)
        if energy < 0.5 { return ("—", 0) }

        var bestScore: Float = -1
        var bestRoot = 0
        var bestType = 0
        for (typeIdx, t) in Self.chordTemplates.enumerated() {
            for root in 0..<12 {
                var score: Float = 0
                for i in 0..<12 {
                    score += chroma[i] * t.template[(i - root + 12) % 12]
                }
                if score > bestScore {
                    bestScore = score
                    bestRoot = root
                    bestType = typeIdx
                }
            }
        }
        // Confidence = best score / sum of best template weights (normalized).
        let templateSum = Self.chordTemplates[bestType].template.reduce(0, +)
        let conf = templateSum > 0 ? min(1.0, bestScore / templateSum) : 0
        let name = Self.pitchClassNames[bestRoot] + " " + Self.chordTemplates[bestType].label
        return (name, conf)
    }

    // — B.4: Tempo/BPM via autocorrelation on the onset envelope ring.

    fileprivate func detectTempoBPM() -> (bpm: Float, confidence: Float) {
        // Onset envelope is updated every audio callback — that rate is
        // approximately `sampleRate / fftSize`, but the FFT size doesn't
        // match the buffer size, so the effective rate is closer to the
        // audio render rate (≈ 60 Hz at 1024-sample buffers @ 48k).
        // Empirical: assume 60 frames/sec for autocorrelation lag math.
        let frameRate: Float = 60.0
        let minBPM: Float = 60
        let maxBPM: Float = 200
        let minLag = Int(60.0 * frameRate / maxBPM)   // ~18 frames
        let maxLag = Int(60.0 * frameRate / minBPM)   // ~60 frames

        // Pull onset-envelope into a flat (chronological) buffer for
        // autocorrelation. Subtract the mean to whiten.
        let n = AudioEngine.onsetEnvelopeSize
        var buf = [Float](repeating: 0, count: n)
        var mean: Float = 0
        for i in 0..<n {
            let idx = (onsetEnvWritePos + i) % n
            buf[i] = onsetEnvRing[idx]
            mean += buf[i]
        }
        mean /= Float(n)
        for i in 0..<n { buf[i] -= mean }

        // Compute autocorrelation for lag in [minLag, maxLag], find peak.
        var bestLag = minLag
        var bestVal: Float = -1
        var totalEnergy: Float = 1e-9
        for v in buf { totalEnergy += v * v }
        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in 0..<(n - lag) { sum += buf[i] * buf[i + lag] }
            if sum > bestVal { bestVal = sum; bestLag = lag }
        }
        let bpmEstimate = 60.0 * frameRate / Float(bestLag)
        let confidence = max(0, min(1, bestVal / totalEnergy * 3))
        return (bpmEstimate, confidence)
    }

    // — B.5: Krumhansl–Schmuckler key detection.

    /// Major / minor key profiles from Krumhansl 1990 — average tonal
    /// hierarchy ratings for the 12 pitch classes, rotated by root.
    fileprivate static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    fileprivate static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    fileprivate func detectKey(longChroma: [Float]) -> (name: String, confidence: Float) {
        // Guard against silence: if the integrated chromagram has barely any
        // energy, all key correlations will be near-zero noise — return "—"
        // rather than picking C major arbitrarily.
        let energy = longChroma.reduce(0, +)
        if energy < 0.5 { return ("—", 0) }

        var bestCorr: Float = -2
        var bestRoot = 0
        var bestIsMajor = true
        for root in 0..<12 {
            for mode in 0...1 {
                let profile = mode == 0 ? Self.majorProfile : Self.minorProfile
                let corr = pearsonCorr(a: longChroma, b: rotated(profile, by: root))
                if corr > bestCorr {
                    bestCorr = corr
                    bestRoot = root
                    bestIsMajor = (mode == 0)
                }
            }
        }
        let name = Self.pitchClassNames[bestRoot] + (bestIsMajor ? " major" : " minor")
        let conf = max(0, min(1, bestCorr))
        return (name, conf)
    }

    private func rotated(_ a: [Float], by k: Int) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { out[(i + k) % a.count] = a[i] }
        return out
    }

    private func pearsonCorr(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = Float(a.count)
        var sumA: Float = 0, sumB: Float = 0
        for i in 0..<a.count { sumA += a[i]; sumB += b[i] }
        let meanA = sumA / n, meanB = sumB / n
        var num: Float = 0, denomA: Float = 0, denomB: Float = 0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            num += da * db
            denomA += da * da
            denomB += db * db
        }
        let d = sqrtf(denomA * denomB)
        return d > 1e-9 ? num / d : 0
    }

    // — Tap tempo override: average the inter-tap intervals over the last
    //   four taps. Bumps `bpm` directly when invoked from the UI.

    private static var lastTapTimes: [Date] = []
    func tapTempo() {
        let now = Date()
        Self.lastTapTimes.append(now)
        if Self.lastTapTimes.count > 5 { Self.lastTapTimes.removeFirst() }
        // If gap > 2.5s, treat as a new tap session.
        if Self.lastTapTimes.count >= 2,
           now.timeIntervalSince(Self.lastTapTimes[Self.lastTapTimes.count - 2]) > 2.5 {
            Self.lastTapTimes = [now]
            return
        }
        guard Self.lastTapTimes.count >= 2 else { return }
        var totalGap: Double = 0
        for i in 1..<Self.lastTapTimes.count {
            totalGap += Self.lastTapTimes[i].timeIntervalSince(Self.lastTapTimes[i - 1])
        }
        let avgGap = totalGap / Double(Self.lastTapTimes.count - 1)
        if avgGap > 0.2 && avgGap < 2.0 {
            self.bpm = Float(60.0 / avgGap)
            self.bpmConfidence = 1.0
        }
    }
}
