// AudioEngine — AVAudioEngine mic tap with vDSP FFT producing
// frequency bands, RMS envelope, and beat onset for visualizations.

import AVFoundation
import Accelerate
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isKinect: Bool
}

@Observable
final class AudioEngine {
    static let bandCount = 8
    static let fftSize = 1024

    var bands: [Float] = Array(repeating: 0, count: AudioEngine.bandCount)
    var rms: Float = 0
    var onset: Bool = false
    var isRunning = false

    var availableInputs: [AudioInputDevice] = []
    var selectedInputID: AudioDeviceID?

    private let engine = AVAudioEngine()
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private let log2n = vDSP_Length(log2(Float(AudioEngine.fftSize)))
    private var window: [Float] = []
    private var lastFlux: Float = 0
    private var prevMagnitudes: [Float] = Array(repeating: 0, count: AudioEngine.fftSize / 2)

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
            selectedInputID = inputs.first(where: \.isKinect)?.id ?? inputs.first?.id
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
        if let target = selectedInputID {
            setSystemDefaultInput(target)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(AudioEngine.fftSize), format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    func switchInput(to id: AudioDeviceID) {
        selectedInputID = id
        if isRunning {
            stop()
            start()
        }
    }

    private func setSystemDefaultInput(_ id: AudioDeviceID) {
        var deviceID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let n = AudioEngine.fftSize
        guard frameLength >= n else { return }

        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = channelData[0][i] }

        var rmsValue: Float = 0
        vDSP_rmsqv(samples, 1, &rmsValue, vDSP_Length(n))

        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)

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
        var newBands = [Float](repeating: 0, count: AudioEngine.bandCount)
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
        prevMagnitudes = magnitudes
        let onsetDetected = flux > lastFlux * 1.5 && flux > 5
        lastFlux = max(flux, lastFlux * 0.9)

        let smoothBands = newBands
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<AudioEngine.bandCount {
                self.bands[i] = self.bands[i] * 0.6 + smoothBands[i] * 0.4
            }
            self.rms = self.rms * 0.7 + rmsValue * 0.3
            self.onset = onsetDetected
        }
    }
}
