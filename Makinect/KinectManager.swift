// KinectManager — Manages Kinect v1 and v2 connections, streaming, and frame conversion
//
// Kinect v1 support uses libfreenect:
//   Copyright (c) 2010-2015 individual OpenKinect contributors
//   Licensed under Apache 2.0 / GPL v2
//   https://github.com/OpenKinect/libfreenect
//
// Kinect v2 support uses libfreenect2 via KinectV2Bridge (see KinectV2Bridge.mm)

import Foundation
import AppKit

enum CameraMode: String, CaseIterable {
    case rgb = "RGB Camera"
    case depth = "Depth Sensor"
    case ir = "IR Sensor"
    case skeleton = "Skeleton"
    case segmented = "Segmented"
}

/// Where the visualization textures get their pixels from.
/// `.kinect` uses a connected device; `.synthetic` runs procedural, audio-reactive
/// compute kernels so visualizers work standalone without a sensor.
enum InputSource: String, CaseIterable, Identifiable {
    case kinect = "Kinect"
    case synthetic = "Synthetic"
    var id: String { rawValue }
}

/// Describes a detected Kinect device
struct DetectedKinect: Identifiable {
    let id = UUID()
    let version: MKKinectVersion
    let name: String
    let productId: Int
}

// MARK: - V2 Frame Constants

private let kV2ColorWidth = 1920
private let kV2ColorHeight = 1080
private let kV2ColorBufferSize = 1920 * 1080 * 4  // BGRX
private let kV2DepthWidth = 512
private let kV2DepthHeight = 424
private let kV2DepthPixelCount = 512 * 424
private let kV2BigDepthWidth = 1920
private let kV2BigDepthHeight = 1082  // libfreenect2 adds 1 blank row top and bottom
private let kV2BigDepthPixelCount = 1920 * 1082

// MARK: - V1 Frame Constants

private let kV1Width = 640
private let kV1Height = 480
private let kV1RGBBufferSize = 640 * 480 * 3
private let kV1DepthPixelCount = 640 * 480

// MARK: - V1 Global Buffers (for C callback interop)

private var gV1RGBBuffer = [UInt8](repeating: 0, count: kV1RGBBufferSize)
private var gV1DepthBuffer = [UInt16](repeating: 0, count: kV1DepthPixelCount)
private var gV1HasNewRGB = false
private var gV1HasNewDepth = false
private let gV1Lock = NSLock()

private func v1VideoCallback(_ dev: OpaquePointer?, _ data: UnsafeMutableRawPointer?, _ timestamp: UInt32) {
    guard let data else { return }
    gV1Lock.lock()
    gV1RGBBuffer.withUnsafeMutableBufferPointer { buf in memcpy(buf.baseAddress!, data, kV1RGBBufferSize) }
    gV1HasNewRGB = true
    gV1Lock.unlock()
}

private func v1DepthCallback(_ dev: OpaquePointer?, _ data: UnsafeMutableRawPointer?, _ timestamp: UInt32) {
    guard let data else { return }
    gV1Lock.lock()
    gV1DepthBuffer.withUnsafeMutableBufferPointer { buf in memcpy(buf.baseAddress!, data, kV1DepthPixelCount * 2) }
    gV1HasNewDepth = true
    gV1Lock.unlock()
}

// MARK: - KinectManager

@Observable
final class KinectManager {
    var currentFrame: NSImage?
    var isConnected = false
    var cameraMode: CameraMode = .rgb
    var statusMessage = "Scanning for Kinect..."
    var detectedDevices: [DetectedKinect] = []
    var activeVersion: MKKinectVersion = .none
    var serialNumber: String?
    var firmwareVersion: String?

    // Pose detection
    let poseDetector = PoseDetector()
    var showSkeleton = false

    // Audio (FFT bands / RMS / onset for visualizations)
    let audio = AudioEngine()

    // Universal modifiers applied across every visualizer (hue / sat / val
    // / glow at output stage; speed and audio-reactivity scale inputs).
    let common = VisualizationCommonParams()

    // Per-visualizer user controls, exposed in SidePanel and read by the
    // visualizer each frame via VisualizerInputs.
    let parametricSwarm = ParametricSwarmConfig()
    let particleStorm = ParticleStormConfig()
    let mercuryStorm = MercuryStormConfig()
    let mandelbulbAviary = MandelbulbAviaryConfig()
    let bodyOfPetals = BodyOfPetalsConfig()

    // Active GPU visualization (nil = use CPU CameraMode pipeline)
    var visualization: VisualizationKind? {
        didSet {
            if visualization != nil { audio.start() } else { audio.stop() }
        }
    }

    /// Where visualization textures are sourced from. Defaults to `.kinect` to preserve
    /// existing behavior. When set to `.synthetic`, any active Kinect connection is
    /// released and `MetalKinectView` fills the textures via compute kernels instead.
    var source: InputSource = .kinect {
        didSet {
            guard oldValue != source else { return }
            if source == .synthetic {
                if isConnected { disconnect() }
                statusMessage = "Synthetic source — no device required"
            } else {
                scanForDevices()
            }
        }
    }

    // Segmentation parameters
    var segmentationNearMM: Float = 500
    var segmentationFarMM: Float = 2000

    // FPS tracking
    var currentFPS: Double = 0.0
    private var frameCount = 0
    private var fpsTimestamp = Date()

    // Latest CGImage for Vision framework (avoids NSImage roundtrip)
    var latestColorCGImage: CGImage?

    // V2 bridge
    private var v2Bridge: KinectV2Bridge?

    // V1 state
    private var v1Ctx: OpaquePointer?
    private var v1Dev: OpaquePointer?
    private var v1Processing = false

    // Shared
    private var displayTimer: Timer?

    // V2 frame buffers (read on main thread)
    private var v2ColorBuffer = [UInt8](repeating: 0, count: kV2ColorBufferSize)
    private var v2DepthBuffer = [Float](repeating: 0, count: kV2DepthPixelCount)
    private var v2IRBuffer = [Float](repeating: 0, count: kV2DepthPixelCount)
    private var v2RegisteredDepthBuffer = [Float](repeating: 0, count: kV2BigDepthPixelCount)

    // GPU texture sink (set by MetalKinectView when a visualization mode is active)
    private weak var visualizationTextures: KinectMetalTextures?

    func attachVisualizationTextures(_ textures: KinectMetalTextures) {
        self.visualizationTextures = textures
    }

    private var needsPoseForVisualization: Bool {
        switch visualization {
        case .bodyPaint, .cathedralOfBones: return true
        default: return false
        }
    }

    init() {
        scanForDevices()
    }

    deinit {
        disconnect()
    }

    // MARK: - Device Scanning

    func scanForDevices() {
        detectedDevices = []
        statusMessage = "Scanning USB bus..."

        let detected = KinectV2Bridge.detectConnectedKinects()
        var devices: [DetectedKinect] = []

        for dk in detected {
            guard let dk = dk as? MKDetectedKinect else { continue }
            devices.append(DetectedKinect(
                version: dk.version,
                name: dk.name,
                productId: Int(dk.usbProductId)
            ))
        }

        detectedDevices = devices

        if devices.isEmpty {
            statusMessage = "No Kinect detected"
        } else {
            let versions = Set(devices.map { $0.version })
            var parts: [String] = []
            if versions.contains(.kinectV1) { parts.append("v1") }
            if versions.contains(.kinectV2) { parts.append("v2") }
            statusMessage = "Found Kinect \(parts.joined(separator: " & ")) — Press Connect"
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        guard source == .kinect else { return }
        guard !isConnected else { return }

        let hasV2 = detectedDevices.contains { $0.version == .kinectV2 }
        let hasV1 = detectedDevices.contains { $0.version == .kinectV1 }

        if hasV2 {
            connectV2()
        } else if hasV1 {
            connectV1()
        } else {
            scanForDevices()
            if detectedDevices.isEmpty {
                statusMessage = "No Kinect detected — plug one in and retry"
            }
        }
    }

    func disconnect() {
        displayTimer?.invalidate()
        displayTimer = nil

        switch activeVersion {
        case .kinectV2: disconnectV2()
        case .kinectV1: disconnectV1()
        default: break
        }

        isConnected = false
        activeVersion = .none
        currentFrame = nil
        latestColorCGImage = nil
        serialNumber = nil
        firmwareVersion = nil
        currentFPS = 0
        poseDetector.skeletons = []
        statusMessage = "Disconnected"
    }

    // MARK: - V2 Connection

    private func connectV2() {
        statusMessage = "Connecting to Kinect v2..."
        let bridge = KinectV2Bridge()

        let count = bridge.enumerateDevices()
        guard count > 0 else {
            statusMessage = "Kinect v2 detected on USB but libfreenect2 can't open it"
            return
        }

        guard bridge.openDevice(0) else {
            statusMessage = "Failed to open Kinect v2 device"
            return
        }

        guard bridge.startStreaming() else {
            statusMessage = "Failed to start Kinect v2 streams"
            bridge.closeDevice()
            return
        }

        v2Bridge = bridge
        activeVersion = .kinectV2
        isConnected = true
        serialNumber = bridge.serialNumber
        firmwareVersion = bridge.firmwareVersion
        statusMessage = "Kinect v2 connected (S/N: \(bridge.serialNumber ?? "unknown"))"

        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateV2Frame()
        }
    }

    private func disconnectV2() {
        v2Bridge?.stopStreaming()
        v2Bridge?.closeDevice()
        v2Bridge = nil
    }

    private func updateV2Frame() {
        guard let bridge = v2Bridge else { return }

        // FPS tracking
        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsTimestamp)
        if elapsed >= 1.0 {
            currentFPS = Double(frameCount) / elapsed
            frameCount = 0
            fpsTimestamp = Date()
        }

        // Always fetch color frame (needed for skeleton/segmentation overlays)
        let gotColor = v2ColorBuffer.withUnsafeMutableBufferPointer { buf -> Bool in
            bridge.copyColorFrame(buf.baseAddress!)
        }

        // GPU visualization path: pull all streams and upload to MTLTextures.
        // CPU CGImage path is skipped to keep the main thread free.
        if visualization != nil, let textures = visualizationTextures {
            if gotColor { textures.uploadColor(v2ColorBuffer) }

            let gotDepth = v2DepthBuffer.withUnsafeMutableBufferPointer { buf -> Bool in
                bridge.copyDepthFrame(buf.baseAddress!)
            }
            if gotDepth { textures.uploadDepth(v2DepthBuffer) }

            let gotRegDepth = v2RegisteredDepthBuffer.withUnsafeMutableBufferPointer { buf -> Bool in
                bridge.copyRegisteredDepthFrame(buf.baseAddress!)
            }
            if gotRegDepth { textures.uploadRegisteredDepth(v2RegisteredDepthBuffer) }

            // Pose detection still runs (skeleton visualizers depend on it).
            if gotColor {
                latestColorCGImage = Self.createV2ColorCGImage(from: v2ColorBuffer)
                if needsPoseForVisualization, let cg = latestColorCGImage {
                    poseDetector.detectPose(in: cg)
                }
            }
            return
        }

        if gotColor {
            latestColorCGImage = Self.createV2ColorCGImage(from: v2ColorBuffer)
        }

        switch cameraMode {
        case .rgb:
            if gotColor, let cg = latestColorCGImage {
                currentFrame = NSImage(cgImage: cg, size: NSSize(width: kV2ColorWidth, height: kV2ColorHeight))
            }

        case .depth:
            let gotDepth = v2DepthBuffer.withUnsafeMutableBufferPointer { buf -> Bool in
                bridge.copyDepthFrame(buf.baseAddress!)
            }
            if gotDepth {
                currentFrame = Self.createV2DepthImage(from: v2DepthBuffer)
            }

        case .ir:
            let gotIR = v2IRBuffer.withUnsafeMutableBufferPointer { buf -> Bool in
                bridge.copyIRFrame(buf.baseAddress!)
            }
            if gotIR {
                currentFrame = Self.createV2IRImage(from: v2IRBuffer)
            }

        case .skeleton:
            if gotColor, let cg = latestColorCGImage {
                currentFrame = NSImage(cgImage: cg, size: NSSize(width: kV2ColorWidth, height: kV2ColorHeight))
            }

        case .segmented:
            let gotRegDepth = v2RegisteredDepthBuffer.withUnsafeMutableBufferPointer { buf -> Bool in
                bridge.copyRegisteredDepthFrame(buf.baseAddress!)
            }
            if gotColor || gotRegDepth {
                currentFrame = Self.createSegmentedImage(
                    colorBGRX: v2ColorBuffer,
                    registeredDepth: v2RegisteredDepthBuffer,
                    nearMM: segmentationNearMM,
                    farMM: segmentationFarMM
                )
            }
        }

        // Run pose detection when skeleton mode is active or overlay is on
        if (cameraMode == .skeleton || (cameraMode == .rgb && showSkeleton)),
           let cg = latestColorCGImage {
            poseDetector.detectPose(in: cg)
        }
    }

    // MARK: - V1 Connection

    private func connectV1() {
        statusMessage = "Connecting to Kinect v1..."

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.runV1Loop()
        }

        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateV1Frame()
        }
    }

    private func disconnectV1() {
        v1Processing = false
    }

    private func runV1Loop() {
        var ctxPtr: OpaquePointer?
        guard freenect_init(&ctxPtr, nil) >= 0 else {
            DispatchQueue.main.async { [weak self] in self?.statusMessage = "Failed to init libfreenect" }
            return
        }

        freenect_set_log_level(ctxPtr, FREENECT_LOG_WARNING)

        guard freenect_num_devices(ctxPtr) > 0 else {
            DispatchQueue.main.async { [weak self] in self?.statusMessage = "No Kinect v1 found by libfreenect" }
            freenect_shutdown(ctxPtr)
            return
        }

        var devPtr: OpaquePointer?
        guard freenect_open_device(ctxPtr, &devPtr, 0) >= 0 else {
            DispatchQueue.main.async { [weak self] in self?.statusMessage = "Failed to open Kinect v1" }
            freenect_shutdown(ctxPtr)
            return
        }

        freenect_set_video_mode(devPtr, freenect_find_video_mode(FREENECT_RESOLUTION_MEDIUM, FREENECT_VIDEO_RGB))
        freenect_set_depth_mode(devPtr, freenect_find_depth_mode(FREENECT_RESOLUTION_MEDIUM, FREENECT_DEPTH_11BIT))
        freenect_set_video_callback(devPtr, v1VideoCallback)
        freenect_set_depth_callback(devPtr, v1DepthCallback)
        freenect_start_video(devPtr)
        freenect_start_depth(devPtr)
        freenect_set_led(devPtr, LED_GREEN)

        DispatchQueue.main.async { [weak self] in
            self?.v1Ctx = ctxPtr
            self?.v1Dev = devPtr
            self?.isConnected = true
            self?.activeVersion = .kinectV1
            self?.statusMessage = "Kinect v1 connected"
        }

        v1Processing = true
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        while v1Processing {
            if freenect_process_events_timeout(ctxPtr, &timeout) < 0 { break }
        }

        freenect_set_led(devPtr, LED_OFF)
        freenect_stop_depth(devPtr)
        freenect_stop_video(devPtr)
        freenect_close_device(devPtr)
        freenect_shutdown(ctxPtr)

        DispatchQueue.main.async { [weak self] in
            self?.v1Ctx = nil
            self?.v1Dev = nil
        }
    }

    private func updateV1Frame() {
        // FPS tracking
        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsTimestamp)
        if elapsed >= 1.0 {
            currentFPS = Double(frameCount) / elapsed
            frameCount = 0
            fpsTimestamp = Date()
        }

        gV1Lock.lock()
        if cameraMode == .rgb && gV1HasNewRGB {
            let copy = gV1RGBBuffer
            gV1HasNewRGB = false
            gV1Lock.unlock()
            currentFrame = Self.createV1RGBImage(from: copy)
        } else if cameraMode == .depth && gV1HasNewDepth {
            let copy = gV1DepthBuffer
            gV1HasNewDepth = false
            gV1Lock.unlock()
            currentFrame = Self.createV1DepthImage(from: copy)
        } else {
            gV1Lock.unlock()
        }
    }

    // MARK: - V2 Image Conversion (CGImage-based)

    /// Convert BGRX (1920x1080) to CGImage
    private static func createV2ColorCGImage(from bgrxBuffer: [UInt8]) -> CGImage? {
        var rgb = [UInt8](repeating: 0, count: kV2ColorWidth * kV2ColorHeight * 3)
        for i in 0..<(kV2ColorWidth * kV2ColorHeight) {
            rgb[i * 3]     = bgrxBuffer[i * 4 + 2] // R
            rgb[i * 3 + 1] = bgrxBuffer[i * 4 + 1] // G
            rgb[i * 3 + 2] = bgrxBuffer[i * 4]     // B
        }

        let data = Data(rgb)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: kV2ColorWidth, height: kV2ColorHeight,
            bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: kV2ColorWidth * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Convert float depth (mm, 512x424) to rainbow-colored NSImage
    private static func createV2DepthImage(from depthBuffer: [Float]) -> NSImage? {
        var rgb = [UInt8](repeating: 0, count: kV2DepthWidth * kV2DepthHeight * 3)

        for i in 0..<kV2DepthPixelCount {
            let mm = depthBuffer[i]
            let (r, g, b) = depthMMToColor(mm)
            rgb[i * 3]     = r
            rgb[i * 3 + 1] = g
            rgb[i * 3 + 2] = b
        }

        let data = Data(rgb)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: kV2DepthWidth, height: kV2DepthHeight,
            bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: kV2DepthWidth * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: kV2DepthWidth, height: kV2DepthHeight))
    }

    /// Convert float IR (512x424) to grayscale NSImage with sqrt scaling
    private static func createV2IRImage(from irBuffer: [Float]) -> NSImage? {
        var rgb = [UInt8](repeating: 0, count: kV2DepthWidth * kV2DepthHeight * 3)
        let sqrtMax = sqrtf(65535.0)

        for i in 0..<kV2DepthPixelCount {
            let raw = irBuffer[i]
            let normalized = min(max(sqrtf(raw) / sqrtMax, 0), 1)
            let val = UInt8(normalized * 255)
            rgb[i * 3]     = val
            rgb[i * 3 + 1] = val
            rgb[i * 3 + 2] = val
        }

        let data = Data(rgb)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: kV2DepthWidth, height: kV2DepthHeight,
            bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: kV2DepthWidth * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: kV2DepthWidth, height: kV2DepthHeight))
    }

    /// Combine color + registered depth to produce background-removed image
    private static func createSegmentedImage(
        colorBGRX: [UInt8],
        registeredDepth: [Float],
        nearMM: Float,
        farMM: Float
    ) -> NSImage? {
        let width = kV2ColorWidth
        let height = kV2ColorHeight
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let colorIdx = y * width + x
                // registeredDepth is 1920x1082 — skip row 0 (blank top row)
                let depthIdx = (y + 1) * kV2BigDepthWidth + x

                let depthMM = registeredDepth[depthIdx]
                let inRange = depthMM > nearMM && depthMM < farMM && depthMM > 0 && !depthMM.isNaN

                let outIdx = colorIdx * 4
                if inRange {
                    rgba[outIdx]     = colorBGRX[colorIdx * 4 + 2] // R
                    rgba[outIdx + 1] = colorBGRX[colorIdx * 4 + 1] // G
                    rgba[outIdx + 2] = colorBGRX[colorIdx * 4]     // B
                    rgba[outIdx + 3] = 255
                }
                // else: stays 0,0,0,0 (transparent/black)
            }
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Map depth in millimeters to rainbow color. Range: 500mm–4500mm.
    private static func depthMMToColor(_ mm: Float) -> (UInt8, UInt8, UInt8) {
        if mm <= 0 || mm.isNaN || mm.isInfinite { return (0, 0, 0) }

        let minDepth: Float = 500
        let maxDepth: Float = 4500
        let clamped = min(max(mm, minDepth), maxDepth)
        let t = (clamped - minDepth) / (maxDepth - minDepth)

        let hue = t * 240.0
        let sector = hue / 60.0
        let idx = Int(sector)
        let f = sector - Float(idx)

        var r: Float = 0, g: Float = 0, b: Float = 0
        switch idx {
        case 0: r = 1; g = f;     b = 0
        case 1: r = 1 - f; g = 1; b = 0
        case 2: r = 0; g = 1;     b = f
        case 3: r = 0; g = 1 - f; b = 1
        default: r = 0; g = 0;    b = 1
        }

        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    // MARK: - V1 Image Conversion

    private static func createV1RGBImage(from buffer: [UInt8]) -> NSImage? {
        let data = Data(buffer)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: kV1Width, height: kV1Height,
            bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: kV1Width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: kV1Width, height: kV1Height))
    }

    private static func createV1DepthImage(from buffer: [UInt16]) -> NSImage? {
        var rgb = [UInt8](repeating: 0, count: kV1Width * kV1Height * 3)
        for i in 0..<kV1DepthPixelCount {
            let d = buffer[i]
            if d == 0 || d >= 2047 { continue }
            let t = Float(d - 1) / 2045.0
            let hue = t * 240.0
            let sector = hue / 60.0
            let idx = Int(sector)
            let f = sector - Float(idx)
            var r: Float = 0, g: Float = 0, b: Float = 0
            switch idx {
            case 0: r = 1; g = f;     b = 0
            case 1: r = 1 - f; g = 1; b = 0
            case 2: r = 0; g = 1;     b = f
            case 3: r = 0; g = 1 - f; b = 1
            default: r = 0; g = 0;    b = 1
            }
            rgb[i * 3]     = UInt8(r * 255)
            rgb[i * 3 + 1] = UInt8(g * 255)
            rgb[i * 3 + 2] = UInt8(b * 255)
        }
        return createV1RGBImage(from: rgb)
    }
}
