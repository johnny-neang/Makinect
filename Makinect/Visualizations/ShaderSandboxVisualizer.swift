// ShaderSandboxVisualizer — Candidate #10: live-coded Metal shader.
//
// Watches ~/Library/Application Support/Makinect/shaders/user.metal and recompiles
// on save. The shader function must be named `user_fs` and accept the standard
// PassthroughVertexOut and Uniforms layout used elsewhere in this app.
// On compile error, the last known-good pipeline is retained.

import Metal
import MetalKit
import Foundation

@MainActor
final class ShaderSandboxVisualizer: Visualizer {
    private let device: MTLDevice
    private let colorPixelFormat: MTLPixelFormat
    private let baseLibrary: MTLLibrary
    private var pipeline: MTLRenderPipelineState  // last good
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private(set) var lastError: String?
    private(set) var sourceURL: URL

    private static let template = """
    // Edit and save this file — shader recompiles live.
    // Available textures:
    //   [[texture(0)]] colorTex  — 1920x1080 BGRA
    //   [[texture(1)]] depthTex  — 1920x1082 R32Float (registered)
    // Uniforms (buffer 0): time, rms, onset, aspect, bands[8], nearMM, farMM

    #include <metal_stdlib>
    using namespace metal;

    struct UserUniforms {
        float time;
        float rms;
        float onset;
        float aspect;
        float bands[8];
        float nearMM;
        float farMM;
        float pad0;
    };

    struct PassthroughVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    fragment float4 user_fs(
        PassthroughVertexOut in [[stage_in]],
        texture2d<float, access::sample> colorTex [[texture(0)]],
        texture2d<float, access::sample> depthTex [[texture(1)]],
        constant UserUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = colorTex.sample(s, in.uv);
        float pulse = 0.5 + 0.5 * sin(u.time * 2.0 + in.uv.x * 8.0);
        c.rgb = mix(c.rgb, float3(pulse, u.rms * 4, u.bands[0] * 6), 0.4);
        return c;
    }
    """

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        self.device = device
        self.colorPixelFormat = colorPixelFormat
        self.baseLibrary = library

        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = supportDir.appendingPathComponent("Makinect/shaders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("user.metal")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Self.template.write(to: url, atomically: true, encoding: .utf8)
        }
        self.sourceURL = url

        // Build initial pipeline from a bundled fallback (postfx) so we always have something
        let fallback = MTLRenderPipelineDescriptor()
        fallback.vertexFunction = library.makeFunction(name: "passthrough_vs")
        fallback.fragmentFunction = library.makeFunction(name: "postfx_fs")
        fallback.colorAttachments[0].pixelFormat = colorPixelFormat
        fallback.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: fallback) else { return nil }
        self.pipeline = pso

        compileFromDisk()
        startWatching()
    }

    deinit {
        fileSource?.cancel()
        if watchedFD >= 0 { close(watchedFD) }
    }

    private func startWatching() {
        let fd = open(sourceURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .extend, .rename], queue: .main
        )
        src.setEventHandler { [weak self] in
            // Re-open on rename/delete (atomic save)
            self?.restartWatching()
            self?.compileFromDisk()
        }
        src.resume()
        fileSource = src
    }

    private func restartWatching() {
        fileSource?.cancel()
        if watchedFD >= 0 { close(watchedFD); watchedFD = -1 }
        startWatching()
    }

    private func compileFromDisk() {
        guard let src = try? String(contentsOf: sourceURL, encoding: .utf8) else { return }
        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            guard let frag = lib.makeFunction(name: "user_fs") else {
                lastError = "Function `user_fs` not found"
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = baseLibrary.makeFunction(name: "passthrough_vs")
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        var u = DepthLavaUniforms()
        u.time = inputs.timeSeconds
        u.rms = inputs.audio.rms
        u.onset = inputs.audio.onset ? 1 : 0
        u.aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        u.nearMM = inputs.segmentationNearMM
        u.farMM = inputs.segmentationFarMM
        let b = inputs.audio.bands
        if b.count >= 8 {
            u.bands = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7])
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.colorTexture, index: 0)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DepthLavaUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
