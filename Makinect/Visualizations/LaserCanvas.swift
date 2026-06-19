// LaserCanvas — the resolution-independent "SceneGraph" for the geometric
// light-show look (Phase 1 of the light-show engine; see
// docs/lightshow/06-roadmap.md and docs/lightshow/07-visual-and-tech-catalog.md).
//
// A LaserCanvas is a list of high-level vector primitives (beams, fans,
// starbursts, tunnels, polygons) expressed in normalized device coordinates
// (x, y ∈ [-1, 1]). It is deliberately decoupled from pixels and from any
// output device: the live audio-reactive choreographer builds one each frame,
// the renderer tessellates it into additive beam quads, and — in later phases —
// the AI choreographer and any future hardware output target write/read against
// this same model. This is the reusable seam.

import Foundation
import simd

/// One GPU vertex of a tessellated beam. Layout MUST match `LaserVtx` in
/// Shaders.metal (`laser_beam_vs`): `float2 pos; float2 uv; float4 color;`.
struct LaserVertex {
    var pos: SIMD2<Float>      // clip space, [-1, 1]
    var uv: SIMD2<Float>       // x = across-beam (-1..1, 0 = core), y = along length (0..1)
    var color: SIMD4<Float>    // rgb + intensity in .w
}

/// HSV colour (h, s, v ∈ 0..1). Converted to RGB on the CPU before upload.
struct LaserColorHSV {
    var h: Float
    var s: Float
    var v: Float

    /// Standard HSV→RGB (hue wraps). Visually matches `hsv2rgb` in Shaders.metal.
    func rgb() -> SIMD3<Float> {
        let hh = (h - floorf(h)) * 6.0          // wrap hue into [0, 6)
        let f = hh - floorf(hh)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch Int(floorf(hh)) % 6 {
        case 0:  return SIMD3<Float>(v, t, p)
        case 1:  return SIMD3<Float>(q, v, p)
        case 2:  return SIMD3<Float>(p, v, t)
        case 3:  return SIMD3<Float>(p, q, v)
        case 4:  return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
        }
    }
}

/// A high-level laser primitive. Each carries colour, intensity, and a
/// `groupID` so a choreographer can address bundles of beams as a unit.
struct LaserPrimitive {
    enum Shape {
        /// A single line segment p0 → p1.
        case beam(p0: SIMD2<Float>, p1: SIMD2<Float>)
        /// `count` beams radiating from `apex`, centred on `angle`, spanning
        /// `spread` radians, each `length` long.
        case fan(apex: SIMD2<Float>, angle: Float, spread: Float, count: Int, length: Float)
        /// `count` symmetric spokes from `center` out to `radius`.
        case starburst(center: SIMD2<Float>, count: Int, radius: Float, rotation: Float)
        /// `rings` concentric N-gons (`sides`) receding toward `center`.
        case tunnel(center: SIMD2<Float>, rings: Int, innerRadius: Float, spacing: Float, sides: Int, rotation: Float)
        /// A single closed N-gon outline.
        case polygon(center: SIMD2<Float>, sides: Int, radius: Float, rotation: Float)
    }

    var shape: Shape
    var width: Float            // half-width in clip-Y units (thin = more "laser")
    var color: LaserColorHSV
    var intensity: Float        // 0 = dark; ~1 = bright; >1 = blown-out white core
    var groupID: Int = 0
}

/// The scene graph for one frame. Build on the CPU, then call `vertices(aspect:)`.
struct LaserCanvas {
    var primitives: [LaserPrimitive] = []

    mutating func add(_ p: LaserPrimitive) { primitives.append(p) }

    /// Tessellate every primitive into beam quads (2 triangles = 6 verts each).
    /// `aspect` = drawableWidth / drawableHeight, used so beam thickness stays
    /// visually uniform regardless of viewport shape.
    func vertices(aspect: Float) -> [LaserVertex] {
        var out: [LaserVertex] = []
        out.reserveCapacity(primitives.count * 24)
        for p in primitives {
            append(p.shape, width: p.width, rgb: p.color.rgb(), intensity: p.intensity, aspect: aspect, into: &out)
        }
        return out
    }

    private func append(_ shape: LaserPrimitive.Shape, width: Float, rgb: SIMD3<Float>,
                        intensity: Float, aspect: Float, into out: inout [LaserVertex]) {
        switch shape {
        case let .beam(p0, p1):
            appendBeam(p0, p1, width, rgb, intensity, aspect, &out)

        case let .fan(apex, angle, spread, count, length):
            let n = max(1, count)
            for i in 0..<n {
                let t = n == 1 ? 0.5 : Float(i) / Float(n - 1)
                let a = angle + (t - 0.5) * spread
                let tip = SIMD2<Float>(apex.x + cosf(a) * length, apex.y + sinf(a) * length)
                appendBeam(apex, tip, width, rgb, intensity, aspect, &out)
            }

        case let .starburst(center, count, radius, rotation):
            let n = max(1, count)
            for i in 0..<n {
                let a = rotation + Float(i) / Float(n) * (2 * Float.pi)
                let tip = SIMD2<Float>(center.x + cosf(a) * radius, center.y + sinf(a) * radius)
                appendBeam(center, tip, width, rgb, intensity, aspect, &out)
            }

        case let .tunnel(center, rings, innerRadius, spacing, sides, rotation):
            let r = max(1, rings)
            for k in 0..<r {
                let radius = innerRadius + Float(k) * spacing
                // Dimmer toward the inside for a sense of depth.
                let fade = 0.4 + 0.6 * (Float(k) / Float(max(1, r - 1)))
                appendPolygon(center, sides, radius, rotation + Float(k) * 0.15, width, rgb, intensity * fade, aspect, &out)
            }

        case let .polygon(center, sides, radius, rotation):
            appendPolygon(center, sides, radius, rotation, width, rgb, intensity, aspect, &out)
        }
    }

    private func appendPolygon(_ center: SIMD2<Float>, _ sides: Int, _ radius: Float, _ rotation: Float,
                               _ width: Float, _ rgb: SIMD3<Float>, _ intensity: Float,
                               _ aspect: Float, _ out: inout [LaserVertex]) {
        let n = max(3, sides)
        var prev = SIMD2<Float>(center.x + cosf(rotation) * radius, center.y + sinf(rotation) * radius)
        for i in 1...n {
            let a = rotation + Float(i) / Float(n) * (2 * Float.pi)
            let cur = SIMD2<Float>(center.x + cosf(a) * radius, center.y + sinf(a) * radius)
            appendBeam(prev, cur, width, rgb, intensity, aspect, &out)
            prev = cur
        }
    }

    /// Tessellate one line segment into a textured quad. The `uv.x` axis runs
    /// -1…+1 across the beam (0 = core) so the fragment shader can draw a
    /// razor core + soft halo; `uv.y` runs 0…1 along the length.
    private func appendBeam(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ halfWidth: Float,
                            _ rgb: SIMD3<Float>, _ intensity: Float, _ aspect: Float,
                            _ out: inout [LaserVertex]) {
        // Work in aspect-corrected (screen) space so thickness is uniform, then
        // convert the perpendicular offset back to clip space.
        var d = SIMD2<Float>((p1.x - p0.x) * aspect, p1.y - p0.y)
        let len = max(1e-5, sqrtf(d.x * d.x + d.y * d.y))
        d /= len
        let nrm = SIMD2<Float>(-d.y / aspect, d.x) * halfWidth
        let c = SIMD4<Float>(rgb.x, rgb.y, rgb.z, intensity)

        let a0 = SIMD2<Float>(p0.x + nrm.x, p0.y + nrm.y)
        let b0 = SIMD2<Float>(p0.x - nrm.x, p0.y - nrm.y)
        let a1 = SIMD2<Float>(p1.x + nrm.x, p1.y + nrm.y)
        let b1 = SIMD2<Float>(p1.x - nrm.x, p1.y - nrm.y)

        func v(_ pos: SIMD2<Float>, _ ux: Float, _ vy: Float) -> LaserVertex {
            LaserVertex(pos: pos, uv: SIMD2<Float>(ux, vy), color: c)
        }
        out.append(v(a0, -1, 0)); out.append(v(b0, 1, 0)); out.append(v(a1, -1, 1))
        out.append(v(b0,  1, 0)); out.append(v(b1, 1, 1)); out.append(v(a1, -1, 1))
    }
}
