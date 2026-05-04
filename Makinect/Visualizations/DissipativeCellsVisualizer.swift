// DissipativeCellsVisualizer — Voronoi cells that grow, contract, and split
// based on body presence. Each cell is a jewel-toned gradient. Bass triggers
// cell mitosis; treble adds shimmer along the cell edges.
//
// Inspiration: Onformative *Dissipative Figures*, iquilezles Voronoi articles.
//
// CPU keeps a fixed-capacity pool of seeds (radius, position, velocity, age,
// hue). Each frame we tick: drift seeds with audio-modulated noise force, kill
// seeds older than max-age, spawn new seeds on onset. Fragment shader receives
// up to 64 nearest seeds and computes smooth-Voronoi distances.

import Metal
import MetalKit
import simd

@MainActor
final class DissipativeCellsVisualizer: Visualizer {
    private static let maxCells = 64
    private static let maxAge: Float = 600  // frames

    private struct Cell {
        var x: Float
        var y: Float
        var vx: Float
        var vy: Float
        var hue: Float
        var radius: Float
        var age: Float
        var alive: Bool
    }

    private struct CellGPU {
        var posHueRadius: SIMD4<Float>  // (x, y, hue, radius)
        var ageAlive:     SIMD4<Float>  // (age, alive, _, _)
    }

    private struct DCUniforms {
        var ctrl: SIMD4<Float>     // (time, count, aspect, _)
        var audio: SIMD4<Float>    // (rms, onset, bassLow, treb)
    }

    private let pipeline: MTLRenderPipelineState
    private let cellBuffer: MTLBuffer
    private var cells: [Cell] = []
    private var rng: UInt32 = 0x9E37_79B9
    private var lastOnset: Float = 0

    required init?(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "passthrough_vs")
        desc.fragmentFunction = library.makeFunction(name: "dissipative_cells_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pso

        let bytes = MemoryLayout<CellGPU>.stride * Self.maxCells
        guard let buf = device.makeBuffer(length: bytes, options: [.storageModeShared]) else { return nil }
        self.cellBuffer = buf

        // Seed initial population: 24 cells in a rough lattice with tinted hues.
        for i in 0..<24 {
            let theta = Float(i) * (2 * .pi / 24)
            let r: Float = 0.18 + Float(i % 3) * 0.13
            cells.append(Cell(
                x: 0.5 + cos(theta) * r,
                y: 0.5 + sin(theta) * r,
                vx: 0, vy: 0,
                hue: fmod(0.55 + Float(i) * 0.04, 1.0),
                radius: 0.18 + Float.random(in: 0..<0.06),
                age: 0,
                alive: true
            ))
        }
    }

    func draw(in view: MTKView, encoder: MTLRenderCommandEncoder, inputs: VisualizerInputs) {
        let bands = inputs.audio.bands
        let bassLow = bands.indices.contains(0) ? bands[0] : 0
        let treb = (bands.indices.contains(6) ? bands[6] : 0) + (bands.indices.contains(7) ? bands[7] : 0)

        // Tick CPU simulation.
        for i in cells.indices where cells[i].alive {
            // Audio-modulated noise drift.
            let theta = atan2(cells[i].y - 0.5, cells[i].x - 0.5)
            cells[i].vx += cos(theta + .pi / 2) * 0.0008 * (1.0 + bassLow)
            cells[i].vy += sin(theta + .pi / 2) * 0.0008 * (1.0 + bassLow)
            cells[i].vx *= 0.95
            cells[i].vy *= 0.95
            cells[i].x += cells[i].vx
            cells[i].y += cells[i].vy
            // Soft boundary repulsion.
            if cells[i].x < 0.05 { cells[i].vx += 0.002 }
            if cells[i].x > 0.95 { cells[i].vx -= 0.002 }
            if cells[i].y < 0.05 { cells[i].vy += 0.002 }
            if cells[i].y > 0.95 { cells[i].vy -= 0.002 }
            // Age + radius pulse.
            cells[i].age += 1
            cells[i].radius += sin(inputs.timeSeconds * 1.7 + Float(i)) * 0.0008
            if cells[i].age > Self.maxAge { cells[i].alive = false }
        }

        // Mitosis on onset: split a random alive cell into two children.
        if inputs.audio.onset && lastOnset < 0.5 {
            let aliveIdx = cells.indices.filter { cells[$0].alive }
            if let parent = aliveIdx.randomElement(), cells.count < Self.maxCells {
                let p = cells[parent]
                let theta = Float.random(in: 0..<(2 * .pi))
                let off: Float = 0.05
                cells[parent].x += cos(theta) * off
                cells[parent].y += sin(theta) * off
                let child = Cell(
                    x: p.x - cos(theta) * off, y: p.y - sin(theta) * off,
                    vx: 0, vy: 0,
                    hue: fmod(p.hue + 0.07, 1.0),
                    radius: p.radius * 0.85,
                    age: 0, alive: true
                )
                if let dead = cells.firstIndex(where: { !$0.alive }) {
                    cells[dead] = child
                } else {
                    cells.append(child)
                }
            }
        }
        lastOnset = inputs.audio.onset ? 1 : 0

        // Replenish dead slots with periodic re-seeding so the field never empties.
        let aliveCount = cells.lazy.filter { $0.alive }.count
        if aliveCount < 12, cells.count < Self.maxCells {
            cells.append(Cell(
                x: Float.random(in: 0.1...0.9),
                y: Float.random(in: 0.1...0.9),
                vx: 0, vy: 0,
                hue: Float.random(in: 0..<1),
                radius: 0.16,
                age: 0, alive: true
            ))
        }

        // Upload the cell buffer.
        let ptr = cellBuffer.contents().bindMemory(to: CellGPU.self, capacity: Self.maxCells)
        var uploaded = 0
        for (i, c) in cells.prefix(Self.maxCells).enumerated() {
            if c.alive {
                ptr[i] = CellGPU(
                    posHueRadius: SIMD4<Float>(c.x, c.y, c.hue, c.radius),
                    ageAlive: SIMD4<Float>(c.age / Self.maxAge, 1, 0, 0)
                )
                uploaded += 1
            } else {
                ptr[i] = CellGPU(
                    posHueRadius: SIMD4<Float>(0, 0, 0, 0),
                    ageAlive: SIMD4<Float>(0, 0, 0, 0)
                )
            }
        }

        var u = DCUniforms(
            ctrl: SIMD4<Float>(inputs.timeSeconds, Float(uploaded),
                               Float(view.drawableSize.width / max(1, view.drawableSize.height)), 0),
            audio: SIMD4<Float>(inputs.audio.rms, inputs.audio.onset ? 1 : 0, bassLow, treb)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputs.textures.registeredDepthTexture, index: 0)
        encoder.setFragmentBuffer(cellBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<DCUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
