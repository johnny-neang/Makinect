// KinectMetalTextures — owns MTLTextures fed from KinectV2Bridge raw buffers.
// One source of truth shared across all GPU visualizers.

import Metal
import MetalKit

final class KinectMetalTextures: @unchecked Sendable {
    static let colorWidth = 1920
    static let colorHeight = 1080
    static let depthWidth = 512
    static let depthHeight = 424
    static let bigDepthWidth = 1920
    static let bigDepthHeight = 1082

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    let colorTexture: MTLTexture          // .bgra8Unorm 1920x1080
    let depthTexture: MTLTexture          // .r32Float 512x424
    let registeredDepthTexture: MTLTexture // .r32Float 1920x1082
    let irTexture: MTLTexture              // .r32Float 512x424

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: w, height: h, mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .shared
            return device.makeTexture(descriptor: desc)
        }

        guard let color = make(.bgra8Unorm, Self.colorWidth, Self.colorHeight),
              let depth = make(.r32Float, Self.depthWidth, Self.depthHeight),
              let regDepth = make(.r32Float, Self.bigDepthWidth, Self.bigDepthHeight),
              let ir = make(.r32Float, Self.depthWidth, Self.depthHeight)
        else { return nil }

        self.colorTexture = color
        self.depthTexture = depth
        self.registeredDepthTexture = regDepth
        self.irTexture = ir
    }

    func uploadColor(_ bgrx: [UInt8]) {
        bgrx.withUnsafeBytes { bytes in
            colorTexture.replace(
                region: MTLRegionMake2D(0, 0, Self.colorWidth, Self.colorHeight),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: Self.colorWidth * 4
            )
        }
    }

    func uploadDepth(_ depth: [Float]) {
        depth.withUnsafeBytes { bytes in
            depthTexture.replace(
                region: MTLRegionMake2D(0, 0, Self.depthWidth, Self.depthHeight),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: Self.depthWidth * MemoryLayout<Float>.size
            )
        }
    }

    func uploadRegisteredDepth(_ depth: [Float]) {
        depth.withUnsafeBytes { bytes in
            registeredDepthTexture.replace(
                region: MTLRegionMake2D(0, 0, Self.bigDepthWidth, Self.bigDepthHeight),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: Self.bigDepthWidth * MemoryLayout<Float>.size
            )
        }
    }

    func uploadIR(_ ir: [Float]) {
        ir.withUnsafeBytes { bytes in
            irTexture.replace(
                region: MTLRegionMake2D(0, 0, Self.depthWidth, Self.depthHeight),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: Self.depthWidth * MemoryLayout<Float>.size
            )
        }
    }
}
