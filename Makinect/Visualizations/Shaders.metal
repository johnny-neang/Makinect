// Shaders.metal — All visualization shaders for Makinect.
//
// Inputs available to most shaders:
//   - registered depth (1920x1082, R32Float, mm)
//   - color (1920x1080, BGRA8)
//   - audio bands[8] + rms + onset
//   - skeleton joint positions
//   - time

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

// MARK: - Common

struct Uniforms {
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

vertex PassthroughVertexOut passthrough_vs(uint vid [[vertex_id]]) {
    // Fullscreen triangle
    float2 positions[3] = {
        float2(-1, -1), float2(3, -1), float2(-1, 3)
    };
    float2 uvs[3] = {
        float2(0, 1), float2(2, 1), float2(0, -1)
    };
    PassthroughVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

// Simple value-noise hash
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float noise2(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

inline float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise2(p);
        p *= 2.02;
        a *= 0.5;
    }
    return v;
}

// HSV → RGB
inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1, 2.0/3.0, 1.0/3.0, 3);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
}

// MARK: - #2 Point Cloud

struct PointCloudUniforms {
    float4x4 viewProj;     // 64
    float4 timing;         // (time, pointSize, rms, onset)
    float4 bandsLow;       // bands[0..3]
    float4 bandsHigh;      // bands[4..7]
    float4 intrinsics;     // (fx, fy, cx, cy)
    float4 dims;           // (depthW, depthH, _, _)
};
// Total 144 bytes, all 16-aligned.

struct PointVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
};

vertex PointVertexOut pointcloud_vs(
    uint vid [[vertex_id]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    texture2d<float, access::sample> colorTex [[texture(1)]],
    constant PointCloudUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);

    float depthW = u.dims.x;
    float depthH = u.dims.y;
    int dw = int(depthW);
    int x = int(vid) % dw;
    int y = int(vid) / dw;

    float2 depthUV = (float2(x, y) + 0.5) / float2(depthW, depthH);
    float z = depthTex.sample(s, depthUV).r;

    PointVertexOut out;
    if (z <= 0 || isnan(z) || z > 6000.0) {
        out.position = float4(0, 0, -10, 1);  // off-screen
        out.pointSize = 0;
        out.color = float3(0);
        return out;
    }

    float time = u.timing.x;
    float pointSize = u.timing.y;
    float rms = u.timing.z;
    float onset = u.timing.w;
    float fx = u.intrinsics.x;
    float fy = u.intrinsics.y;
    float cx = u.intrinsics.z;
    float cy = u.intrinsics.w;

    // Unproject depth-camera intrinsics to camera space (meters, +Z forward)
    float zm = z / 1000.0;
    float xm = (float(x) - cx) * zm / fx;
    float ym = (float(y) - cy) * zm / fy;

    // Audio displacement
    float bass = u.bandsLow.x + u.bandsLow.y;
    float pulse = rms * 0.3 + onset * 0.4;
    float ang = atan2(ym, xm);
    float radial = sin(ang * 6.0 + time * 2.0) * 0.05 * (bass + pulse);
    xm += cos(ang) * radial;
    ym += sin(ang) * radial;

    float4 worldPos = float4(xm, -ym, -zm, 1.0);
    out.position = u.viewProj * worldPos;
    out.pointSize = pointSize * (1.0 + pulse * 1.5);

    float depthN = saturate((zm - 0.5) / 4.0);
    float3 col = hsv2rgb(float3(0.6 - depthN * 0.5 + u.bandsLow.w * 0.1, 0.85, 0.7 + pulse * 0.3));
    out.color = col;
    return out;
}

fragment float4 pointcloud_fs(PointVertexOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
    float d = length(pointCoord - 0.5);
    if (d > 0.5) discard_fragment();
    float a = smoothstep(0.5, 0.2, d);
    return float4(in.color * a, a);
}

// MARK: - #8 AR Body Paint (joint-locked billboards with depth occlusion test)

struct PaintUniforms {
    float aspect;
    float time;
    float rms;
    float onset;
    float bands[8];
    float colorWidth;
    float colorHeight;
    float pad0;
};

struct PaintInstance {
    float2 position;   // normalized 0..1, top-left origin
    float size;        // normalized half-size
    float jointID;
    float intensity;
};

struct PaintVertexOut {
    float4 position [[position]];
    float2 localUV;
    float3 color;
    float intensity;
};

vertex PaintVertexOut paint_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant PaintInstance *instances [[buffer(0)]],
    constant PaintUniforms &u [[buffer(1)]]
) {
    float2 quad[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1, 1),
        float2( 1, -1), float2( 1,  1), float2(-1, 1)
    };
    float2 q = quad[vid];
    PaintInstance inst = instances[iid];

    float beat = 1.0 + u.onset * 1.2 + u.rms * 0.5;
    float2 size = float2(inst.size) * beat;
    size.x /= u.aspect;

    float2 ndc = float2(inst.position.x * 2.0 - 1.0, 1.0 - inst.position.y * 2.0);
    ndc += q * size;

    PaintVertexOut out;
    out.position = float4(ndc, 0, 1);
    out.localUV = q;
    float h = fmod(inst.jointID * 0.12, 1.0);
    out.color = hsv2rgb(float3(h, 0.9, 1.0));
    out.intensity = inst.intensity;
    return out;
}

fragment float4 paint_fs(PaintVertexOut in [[stage_in]], constant PaintUniforms &u [[buffer(1)]]) {
    float r = length(in.localUV);
    float falloff = smoothstep(1.0, 0.2, r);
    float flicker = 0.7 + 0.3 * fract(sin(u.time * 30.0 + in.localUV.x * 13.0) * 43758.5);
    float3 col = in.color * flicker * (1.0 + u.bands[5] * 1.2);
    return float4(col * falloff * in.intensity, falloff * in.intensity * 0.8);
}

// MARK: - Synthetic Frame Source
//
// Compute kernels that fill the same MTLTextures the Kinect bridge would, using
// audio-reactive procedural math. Lets visualizers run with no device attached.
//
// SynthUniforms must stay strictly 16-byte aligned (float4 slots only) so Swift
// and Metal agree on layout — see the lesson from commit 3f5f308.

struct SynthUniforms {
    float4 bands;            // FFT bands 0..3
    float4 bandsHi;          // FFT bands 4..7
    float4 rmsTimeOnsetPad;  // (rms, time, onset, _)
};

// Output: depth in millimeters, clamped to [500, 4500] to match real Kinect range.
// Dispatched twice: once for the 512×424 depthTexture, once for the 1920×1082
// registeredDepthTexture. The kernel reads its grid bounds from the texture itself.
kernel void synth_depth_kernel(
    texture2d<float, access::write> outDepth [[texture(0)]],
    constant SynthUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = float2(gid) / float2(w, h);
    float2 p = uv - 0.5;

    float t = u.rmsTimeOnsetPad.y;
    float rms = u.rmsTimeOnsetPad.x;
    float onset = u.rmsTimeOnsetPad.z;

    // Big rolling ridges driven by the four low FFT bands.
    float ridges = 0.0;
    ridges += sin(p.x * 6.0 + u.bands.x * 5.0 + t * 0.7);
    ridges += sin(p.y * 5.0 + u.bands.y * 5.0 + t * 0.9);
    ridges += sin((p.x + p.y) * 4.0 + u.bands.z * 5.0 + t * 0.5);
    ridges += cos((p.x - p.y) * 4.5 + u.bands.w * 5.0 + t * 0.6);
    ridges *= 0.25;

    // Higher-band shimmer.
    float shimmer = 0.0;
    shimmer += sin(p.x * 18.0 + u.bandsHi.x * 8.0 + t * 1.3) * 0.15;
    shimmer += cos(p.y * 22.0 + u.bandsHi.y * 8.0 + t * 1.5) * 0.12;

    // Radial breathing keyed by RMS so the whole field "pumps" with loudness.
    float r = length(p);
    float breath = sin(r * 12.0 - t * 2.0) * (0.3 + rms * 1.5);

    // Onset pulse: a brief depth bump that fades quickly inside the kernel.
    float pulse = onset * exp(-r * 6.0) * 600.0;

    // Center at 2000mm, swing ±1500mm, then add the onset spike.
    float depthMM = 2000.0 + 1500.0 * (ridges + shimmer + breath * 0.4) + pulse;
    depthMM = clamp(depthMM, 500.0, 4500.0);

    outDepth.write(float4(depthMM, 0, 0, 0), gid);
}

// Output: BGRA color, 1920×1080. Procedural HSV ramp scrolling with time and pulsed by audio.
kernel void synth_color_kernel(
    texture2d<float, access::write> outColor [[texture(0)]],
    constant SynthUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = outColor.get_width();
    uint h = outColor.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = float2(gid) / float2(w, h);
    float t = u.rmsTimeOnsetPad.y;
    float rms = u.rmsTimeOnsetPad.x;
    float onset = u.rmsTimeOnsetPad.z;

    // A few moving blobs whose positions are nudged by FFT bands.
    float2 c0 = float2(0.3 + 0.2 * sin(t * 0.4 + u.bands.x * 3.0),
                       0.4 + 0.2 * cos(t * 0.5 + u.bands.y * 3.0));
    float2 c1 = float2(0.7 + 0.2 * sin(t * 0.3 + u.bands.z * 3.0),
                       0.6 + 0.2 * cos(t * 0.6 + u.bands.w * 3.0));
    float blob = exp(-length(uv - c0) * 6.0) + exp(-length(uv - c1) * 6.0);

    // Hue scrolls and shifts with the bass; saturation comes from mids; value from RMS + treble.
    float hue = fract(uv.x * 0.5 + t * 0.07 + u.bands.x * 0.3 + blob * 0.2);
    float sat = clamp(0.55 + u.bands.y * 0.4 + u.bandsHi.x * 0.2, 0.0, 1.0);
    float val = clamp(0.30 + rms * 0.9 + u.bandsHi.z * 0.4 + onset * 0.3 + blob * 0.4, 0.0, 1.2);

    float3 rgb = hsv2rgb(float3(hue, sat, val));

    // Subtle scanline texture so PostFX/Halftone have something to grind against.
    float scan = 0.92 + 0.08 * sin(uv.y * float(h) * 0.5 + t * 4.0);
    rgb *= scan;

    // Texture is .bgra8Unorm but Metal swizzles transparently: writing float4(r,g,b,a)
    // here lets visualizers sample back .r/.g/.b correctly (matches the convention the
    // Kinect bridge relies on when uploading raw BGRX bytes).
    outColor.write(float4(rgb, 1.0), gid);
}

// MARK: - #12 Volumetric Raymarched Nebula
//
// Cheap 3D fbm marched through a small density field. Depth carves negative space.

inline float hash3(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

inline float noise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash3(i + float3(0,0,0));
    float n100 = hash3(i + float3(1,0,0));
    float n010 = hash3(i + float3(0,1,0));
    float n110 = hash3(i + float3(1,1,0));
    float n001 = hash3(i + float3(0,0,1));
    float n101 = hash3(i + float3(1,0,1));
    float n011 = hash3(i + float3(0,1,1));
    float n111 = hash3(i + float3(1,1,1));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

inline float fbm3(float3 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * noise3(p);
        p *= 2.05;
        a *= 0.5;
    }
    return v;
}

fragment float4 nebula_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    // Camera at origin looking down -Z, slowly orbiting on slow Y-axis sway.
    float t = u.time;
    float bass = u.bands[0] + u.bands[1];
    float treb = u.bands[6] + u.bands[7];
    float3 ro = float3(sin(t * 0.05) * 0.3, cos(t * 0.07) * 0.2, -2.5);
    float3 rd = normalize(float3(p, 1.0));

    // Body-as-hole: where there's a body, density is suppressed in the foreground slab.
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool body = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    // March 32 steps from near to far, accumulating density and emission.
    float3 acc = float3(0.0);
    float trans = 1.0;
    const int STEPS = 32;
    float zNear = 0.5;
    float zFar  = 4.5;
    float dz = (zFar - zNear) / float(STEPS);

    float palShift = bass * 0.12 + 0.5 + 0.05 * sin(t * 0.3);

    for (int i = 0; i < STEPS; i++) {
        float z = zNear + (float(i) + 0.5) * dz;
        float3 q = ro + rd * z;
        // Animate the noise field
        q.xy += float2(sin(t * 0.15 + q.z), cos(t * 0.18 - q.z * 0.5)) * 0.3;
        q.z += t * 0.1;

        float density = fbm3(q * (1.0 + bass * 0.4));
        density = pow(saturate(density - 0.45), 2.0) * (1.5 + u.rms * 1.5);

        // Punch a hole behind the body silhouette.
        if (body && z < 2.5) density *= 0.05;

        // Emission color: hue ramps with z, brightened by treble.
        float hue = palShift + z * 0.07 + density * 0.2;
        float3 emit = hsv2rgb(float3(fract(hue), 0.55, 1.0)) * (0.5 + treb * 1.2);

        float a = 1.0 - exp(-density * dz * 6.0);
        acc += trans * emit * a;
        trans *= 1.0 - a;
        if (trans < 0.01) break;
    }

    // Background tint when fully transparent.
    float3 bg = mix(float3(0.02, 0.01, 0.05), float3(0.05, 0.0, 0.10), uv.y);
    acc += bg * trans;

    // Onset bloom flash.
    acc += float3(0.4, 0.3, 0.6) * u.onset * 0.5;

    return float4(acc, 1.0);
}

// MARK: - #17 Optical-Flow Painter
//
// Motion is estimated as a 2D gradient of (currDepth - prevDepth). Paint is
// advected backwards along the flow vector (backwards-Euler advection — the
// Stam stable-fluids trick). New paint splats where motion magnitude is high.

struct OFUniforms {
    float4 ctrl;     // (time, dt, viscosity, motionGate)
    float4 audio;    // (rms, onset, bassLow, treb)
    float4 palette;  // (hueA, hueB, sat, val)
};

inline float depth_in_range(float mm, float2 range) {
    return (mm > range.x && mm < range.y && mm > 0) ? 1.0 : 0.0;
}

kernel void of_copy_depth_kernel(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    // src is registered depth (1920x1082) — skip blank top row.
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    dst.write(float4(src.sample(s, depthUV).r, 0, 0, 0), gid);
}

kernel void of_advect_kernel(
    texture2d<float, access::sample> paintIn [[texture(0)]],
    texture2d<float, access::write> paintOut [[texture(1)]],
    texture2d<float, access::sample> currDepth [[texture(2)]],
    texture2d<float, access::sample> prevDepth [[texture(3)]],
    constant OFUniforms &u [[buffer(0)]],
    constant float2 &range [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = paintOut.get_width();
    uint H = paintOut.get_height();
    if (gid.x >= W || gid.y >= H) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(W, H);

    // Current/previous depth at this cell (we sample registered depth at the
    // matching uv and account for its 1080→1082 row skip).
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float curr = currDepth.sample(s, depthUV).r;
    float prev = prevDepth.sample(s, uv).r;
    float dt = (curr - prev);

    // Spatial gradient of current depth → 2D flow direction (descend the gradient).
    float dx = currDepth.sample(s, depthUV + float2( 0.003, 0)).r
             - currDepth.sample(s, depthUV - float2( 0.003, 0)).r;
    float dy = currDepth.sample(s, depthUV + float2(0,  0.003)).r
             - currDepth.sample(s, depthUV - float2(0,  0.003)).r;
    float mag = length(float2(dx, dy));
    float2 flow = (mag > 1e-3) ? -float2(dx, dy) / mag : float2(0);
    flow *= clamp(abs(dt) * 0.0012, 0.0, 0.05);

    // Backwards advect.
    float2 prevUV = uv - flow;
    float4 sample_paint = paintIn.sample(s, prevUV);
    float3 col = sample_paint.rgb * u.ctrl.z;  // viscosity decay

    // Splat new color where motion is strong + body is present.
    bool inBody = depth_in_range(curr, range) > 0.5;
    float motionMag = clamp(abs(dt) * 0.001, 0.0, 1.0);
    if (inBody && motionMag > u.ctrl.w) {
        float hue = mix(u.palette.x, u.palette.y, fract(uv.x + uv.y * 0.5 + u.ctrl.x * 0.1));
        float3 hue3 = hsv2rgb(float3(hue, u.palette.z, u.palette.w));
        col += hue3 * motionMag * (0.8 + u.audio.x * 1.0);
    }
    if (u.audio.y > 0.5 && inBody) col += float3(1.0, 0.5, 0.8) * 0.4;

    col = min(col, float3(6.0));
    paintOut.write(float4(col, 1.0), gid);
}

fragment float4 of_draw_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> paint [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 col = paint.sample(s, in.uv).rgb;
    // Soft tone-map.
    col = (col * (2.5 * col + 0.03)) / (col * (2.4 * col + 0.6) + 0.14);
    col = saturate(col);
    float vig = smoothstep(1.4, 0.4, length((in.uv - 0.5) * 1.4));
    col *= vig;
    return float4(col, 1.0);
}

// MARK: - #18 GPU Particle Storm
//
// 256k particles. Each frame, compute kernel integrates a curl-noise + audio-
// modulated velocity field, with body silhouette acting as an attractor
// (particles get sucked into / repelled from cells where depth is in range).

struct PSUniforms {
    float4 ctrl;     // (time, dt, count, _)
    float4 audio;    // (rms, onset, bassLow, treb)
    float4 bandsLow;
    float4 bandsHi;
};

struct PSParticle {
    float4 posLife;  // (x, y, z, life)
    float4 velAge;   // (vx, vy, vz, age)
    float4 color;    // (hue, brightness, _, _)
};

inline float ps_hash(float n) { return fract(sin(n) * 43758.5453); }

inline float3 curl_noise(float3 p) {
    // Cheap 2D curl by finite differences of a 3D fbm channel.
    float e = 0.05;
    float n1 = noise3(p + float3( e, 0, 0));
    float n2 = noise3(p - float3( e, 0, 0));
    float n3 = noise3(p + float3(0,  e, 0));
    float n4 = noise3(p - float3(0,  e, 0));
    return float3(n3 - n4, -(n1 - n2), 0);
}

kernel void ps_init_kernel(
    device PSParticle *p [[buffer(0)]],
    constant PSUniforms &u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    uint count = uint(u.ctrl.z);
    if (gid >= count) return;
    float fi = float(gid);
    float h1 = ps_hash(fi * 0.013) * 2.0 - 1.0;
    float h2 = ps_hash(fi * 0.027) * 2.0 - 1.0;
    float h3 = ps_hash(fi * 0.041);
    p[gid].posLife = float4(h1 * 1.6, h2 * 1.0, 0, h3);
    p[gid].velAge  = float4(0, 0, 0, ps_hash(fi * 0.063) * 200.0);
    p[gid].color   = float4(ps_hash(fi * 0.097), 0.7, 0, 0);
}

kernel void ps_step_kernel(
    device PSParticle *src [[buffer(0)]],
    device PSParticle *dst [[buffer(1)]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant PSUniforms &u [[buffer(2)]],
    constant float2 &range [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint count = uint(u.ctrl.z);
    if (gid >= count) return;

    PSParticle s = src[gid];
    float t = u.ctrl.x;
    float dt = u.ctrl.y;
    float life = s.posLife.w;
    float age = s.velAge.w + 1.0;

    // Curl noise with audio-driven scale.
    float scale = 0.5 + u.audio.z * 1.5;
    float3 acc = curl_noise(float3(s.posLife.xy * scale, t * 0.3)) * (0.7 + u.audio.x * 1.5);

    // Body attractor: sample depth at this NDC; if in range, pull particle inward.
    float2 uv = float2(s.posLife.x * 0.5 + 0.5, 0.5 - s.posLife.y * 0.5);
    if (uv.x > 0 && uv.x < 1 && uv.y > 0 && uv.y < 1) {
        constexpr sampler ss(filter::linear, address::clamp_to_edge);
        float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
        float depthMM = depthTex.sample(ss, depthUV).r;
        bool inBody = depthMM > range.x && depthMM < range.y && depthMM > 0;
        if (inBody) {
            float2 toCenter = (float2(0.0, 0.0) - s.posLife.xy);
            float r = length(toCenter) + 1e-3;
            float pull = (u.audio.y > 0.5) ? -2.0 : 1.2;  // onset pushes outward
            acc.xy += toCenter / r * pull * 0.4;
        }
    }

    // Beat shockwave: outward burst on onset.
    if (u.audio.y > 0.5) {
        float2 outv = normalize(s.posLife.xy + 0.001) * 2.0;
        acc.xy += outv;
    }

    // Integrate.
    float3 vel = s.velAge.xyz * 0.93 + acc * dt;
    float3 pos = s.posLife.xyz + vel * dt;

    // Recycle particles that drifted too far or aged out.
    bool recycle = (length(pos.xy) > 2.5) || (age > 320.0);
    if (recycle) {
        float fi = float(gid) + t * 7.13;
        float a = ps_hash(fi) * 6.2831853;
        float r = ps_hash(fi * 1.7) * 0.5;
        pos = float3(cos(a) * r, sin(a) * r, 0);
        vel = float3(0);
        age = 0;
        s.color.x = ps_hash(fi * 2.3);
    }

    dst[gid].posLife = float4(pos, life);
    dst[gid].velAge  = float4(vel, age);
    dst[gid].color   = float4(s.color.x,
                              0.5 + length(vel) * 1.0 + u.audio.x * 0.6,
                              0, 0);
}

struct PSPointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex PSPointOut ps_point_vs(
    uint vid [[vertex_id]],
    const device PSParticle *src [[buffer(0)]],
    constant PSUniforms &u [[buffer(1)]]
) {
    PSParticle p = src[vid];
    PSPointOut o;
    o.position = float4(p.posLife.xy, 0, 1);
    float speed = length(p.velAge.xy);
    o.pointSize = clamp(2.0 + speed * 8.0 + u.audio.x * 4.0, 1.0, 14.0);
    float hueShift = u.audio.z * 0.2 - u.audio.w * 0.15;
    float3 col = hsv2rgb(float3(fract(p.color.x + hueShift),
                                 0.85,
                                 saturate(p.color.y * 0.6)));
    o.color = float4(col, 1.0);
    return o;
}

fragment float4 ps_point_fs(
    PSPointOut in [[stage_in]],
    float2 ptCoord [[point_coord]]
) {
    float r = length(ptCoord - 0.5) * 2.0;
    float a = exp(-r * r * 4.0);
    return float4(in.color.rgb * a, a * 0.6);
}

// MARK: - #19 Stable Fluids (Navier-Stokes)
//
// Velocity is RG, dye is RGBA, pressure is R. All on a 256² grid. Standard
// semi-Lagrangian advection + Jacobi pressure projection.

struct SFUniforms {
    float4 ctrl;     // (time, dt, dissipation, viscosity)
    float4 audio;    // (rms, onset, bassLow, treb)
    float4 palette;  // (hueA, hueB, sat, val)
};

inline float2 sf_sample_vel(texture2d<float, access::sample> vel, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return vel.sample(s, uv).rg;
}

inline float4 sf_sample_dye(texture2d<float, access::sample> dye, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return dye.sample(s, uv);
}

kernel void sf_inject_kernel(
    texture2d<float, access::read_write> velRW [[texture(0)]],
    texture2d<float, access::read_write> dyeRW [[texture(1)]],
    texture2d<float, access::sample> depthTex [[texture(2)]],
    constant SFUniforms &u [[buffer(0)]],
    constant float2 &range [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = velRW.get_width();
    uint H = velRW.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > range.x && depthMM < range.y && depthMM > 0;

    float2 vel = velRW.read(gid).rg;
    float4 dye = dyeRW.read(gid);

    if (inBody) {
        // Body cells emit upward + outward velocity (so the fluid swirls around them).
        float2 dir = uv - 0.5;
        float r = length(dir) + 0.001;
        float push = 0.4 + u.audio.x * 1.5;
        vel += dir / r * push * 0.05;
        vel.y += 0.04 + u.audio.x * 0.06;

        // Dye injection: hue palette modulated by audio.
        float hue = mix(u.palette.x, u.palette.y, fract(uv.x * 2.0 + u.ctrl.x * 0.1));
        float3 hueRGB = hsv2rgb(float3(hue, u.palette.z, u.palette.w));
        dye.rgb += hueRGB * 0.06;
    }

    // Onset: drop a big colored blob at a moving point.
    if (u.audio.y > 0.5) {
        float t = u.ctrl.x;
        float2 src = float2(0.5 + 0.3 * sin(t * 0.7), 0.5 + 0.3 * cos(t * 0.5));
        float r = length(uv - src);
        float blob = exp(-r * r * 80.0);
        float3 hueRGB = hsv2rgb(float3(fract(u.palette.x + 0.4), 0.95, 1.0));
        dye.rgb += hueRGB * blob * 1.4;
        vel += normalize(uv - src) * blob * 0.5;
    }

    vel *= 0.998;  // subtle damping for stability
    dye.rgb *= u.ctrl.z;  // dissipation

    velRW.write(float4(vel, 0, 0), gid);
    dyeRW.write(dye, gid);
}

kernel void sf_advect_velocity_kernel(
    texture2d<float, access::sample> velIn [[texture(0)]],
    texture2d<float, access::write> velOut [[texture(1)]],
    constant SFUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = velOut.get_width();
    uint H = velOut.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float2 vel = sf_sample_vel(velIn, uv);
    // Backwards trace.
    float2 prev = uv - vel * u.ctrl.y / float2(W, H) * 60.0;
    velOut.write(float4(sf_sample_vel(velIn, prev), 0, 0), gid);
}

kernel void sf_advect_dye_kernel(
    texture2d<float, access::sample> dyeIn [[texture(0)]],
    texture2d<float, access::sample> velIn [[texture(1)]],
    texture2d<float, access::write> dyeOut [[texture(2)]],
    constant SFUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = dyeOut.get_width();
    uint H = dyeOut.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float2 vel = sf_sample_vel(velIn, uv);
    float2 prev = uv - vel * u.ctrl.y / float2(W, H) * 60.0;
    dyeOut.write(sf_sample_dye(dyeIn, prev), gid);
}

kernel void sf_divergence_kernel(
    texture2d<float, access::sample> vel [[texture(0)]],
    texture2d<float, access::write> div [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = div.get_width();
    uint H = div.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 px = 1.0 / float2(W, H);
    float2 uv = (float2(gid) + 0.5) * px;
    float2 vL = sf_sample_vel(vel, uv - float2(px.x, 0));
    float2 vR = sf_sample_vel(vel, uv + float2(px.x, 0));
    float2 vB = sf_sample_vel(vel, uv - float2(0, px.y));
    float2 vT = sf_sample_vel(vel, uv + float2(0, px.y));
    float d = 0.5 * ((vR.x - vL.x) + (vT.y - vB.y));
    div.write(float4(d, 0, 0, 0), gid);
}

kernel void sf_jacobi_kernel(
    texture2d<float, access::sample> presIn [[texture(0)]],
    texture2d<float, access::sample> div [[texture(1)]],
    texture2d<float, access::write> presOut [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = presOut.get_width();
    uint H = presOut.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 px = 1.0 / float2(W, H);
    float2 uv = (float2(gid) + 0.5) * px;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float pL = presIn.sample(s, uv - float2(px.x, 0)).r;
    float pR = presIn.sample(s, uv + float2(px.x, 0)).r;
    float pB = presIn.sample(s, uv - float2(0, px.y)).r;
    float pT = presIn.sample(s, uv + float2(0, px.y)).r;
    float b  = div.sample(s, uv).r;
    float p = (pL + pR + pB + pT - b) * 0.25;
    presOut.write(float4(p, 0, 0, 0), gid);
}

kernel void sf_subgrad_kernel(
    texture2d<float, access::sample> velIn [[texture(0)]],
    texture2d<float, access::sample> pres [[texture(1)]],
    texture2d<float, access::write> velOut [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = velOut.get_width();
    uint H = velOut.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 px = 1.0 / float2(W, H);
    float2 uv = (float2(gid) + 0.5) * px;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float pL = pres.sample(s, uv - float2(px.x, 0)).r;
    float pR = pres.sample(s, uv + float2(px.x, 0)).r;
    float pB = pres.sample(s, uv - float2(0, px.y)).r;
    float pT = pres.sample(s, uv + float2(0, px.y)).r;
    float2 v = sf_sample_vel(velIn, uv);
    v -= float2(pR - pL, pT - pB) * 0.5;
    velOut.write(float4(v, 0, 0), gid);
}

fragment float4 sf_draw_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> dye [[texture(0)]],
    constant SFUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 col = dye.sample(s, in.uv).rgb;
    col = (col * (2.5 * col + 0.03)) / (col * (2.4 * col + 0.6) + 0.14);
    col = saturate(col);
    float vig = smoothstep(1.4, 0.4, length((in.uv - 0.5) * 1.3));
    col *= vig;
    return float4(col, 1.0);
}

// MARK: - #20 Voxel Sculpt
//
// 64×48 instanced cubes. Each cube samples the depth field at its grid cell;
// if depth is in body range, the cube moves to that 3D position and is rendered.
// Otherwise it's NaN-clipped off-screen. The whole scene orbits + audio pulses.

struct VSUniforms {
    float4x4 viewProj;
    float4 bandsLow;
    float4 bandsHi;
    float4 ctrl;            // (time, rms, onset, voxelScale)
    float4 range;           // (nearMM, farMM, gridX, gridY)
    float4 cameraExplode;   // (camY, explodePulse, _, _)
};

struct VSVertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPos;
    float3 baseColor;
    float intensity;
};

vertex VSVertexOut voxel_sculpt_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant VSUniforms &u [[buffer(0)]]
) {
    int gx = int(u.range.z);
    int gy = int(u.range.w);
    int xi = int(iid) % gx;
    int yi = int(iid) / gx;

    // Sample depth at the centre of this grid cell.
    float2 uv = (float2(float(xi) + 0.5, float(yi) + 0.5)) / float2(float(gx), float(gy));
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.range.x && depthMM < u.range.y && depthMM > 0;

    VSVertexOut out;
    if (!inBody) {
        out.position = float4(0, 0, -1000, 1);  // off-screen
        out.worldNormal = float3(0, 1, 0);
        out.worldPos = float3(0);
        out.baseColor = float3(0);
        out.intensity = 0;
        return out;
    }

    // Cube definition — 36 vertices, 6 faces × 2 tris × 3 verts.
    // Pre-baked positions and normals for a unit cube centred at origin.
    float3 cubePos[36] = {
        // +X face
        float3( 0.5, -0.5, -0.5), float3( 0.5,  0.5, -0.5), float3( 0.5, -0.5,  0.5),
        float3( 0.5,  0.5, -0.5), float3( 0.5,  0.5,  0.5), float3( 0.5, -0.5,  0.5),
        // -X face
        float3(-0.5, -0.5,  0.5), float3(-0.5,  0.5,  0.5), float3(-0.5, -0.5, -0.5),
        float3(-0.5,  0.5,  0.5), float3(-0.5,  0.5, -0.5), float3(-0.5, -0.5, -0.5),
        // +Y face
        float3(-0.5,  0.5, -0.5), float3(-0.5,  0.5,  0.5), float3( 0.5,  0.5, -0.5),
        float3(-0.5,  0.5,  0.5), float3( 0.5,  0.5,  0.5), float3( 0.5,  0.5, -0.5),
        // -Y face
        float3(-0.5, -0.5,  0.5), float3(-0.5, -0.5, -0.5), float3( 0.5, -0.5,  0.5),
        float3(-0.5, -0.5, -0.5), float3( 0.5, -0.5, -0.5), float3( 0.5, -0.5,  0.5),
        // +Z face
        float3( 0.5, -0.5,  0.5), float3( 0.5,  0.5,  0.5), float3(-0.5, -0.5,  0.5),
        float3( 0.5,  0.5,  0.5), float3(-0.5,  0.5,  0.5), float3(-0.5, -0.5,  0.5),
        // -Z face
        float3(-0.5, -0.5, -0.5), float3(-0.5,  0.5, -0.5), float3( 0.5, -0.5, -0.5),
        float3(-0.5,  0.5, -0.5), float3( 0.5,  0.5, -0.5), float3( 0.5, -0.5, -0.5)
    };
    float3 cubeNorm[6] = {
        float3( 1, 0, 0), float3(-1, 0, 0),
        float3( 0, 1, 0), float3( 0,-1, 0),
        float3( 0, 0, 1), float3( 0, 0,-1)
    };

    // Per-voxel position in world space.
    // Map grid (xi,yi) in [0,gx)×[0,gy) to world (x,y) in [-aspect, aspect]×[1.6, 0]
    // (so the head is at the top), then z from depth in mm → meters.
    float wx = ((float(xi) + 0.5) / float(gx) - 0.5) * 4.0;
    float wy = (1.0 - (float(yi) + 0.5) / float(gy)) * 2.4 - 0.2;
    float wz = -((depthMM - 1500.0) / 1500.0);  // closer = +z

    // Audio pulse: per-voxel scale modulated by mids.
    float scale = u.ctrl.w * (1.0 + u.ctrl.y * 0.7 + u.bandsHi.x * 0.5);

    // Onset explode: temporarily shove voxels outward from screen centre.
    float3 base = float3(wx, wy, wz);
    float3 outDir = normalize(base + 0.001);
    base += outDir * u.cameraExplode.y * 0.6;

    float3 vp = base + cubePos[vid] * scale;
    out.position = u.viewProj * float4(vp, 1.0);
    out.worldNormal = cubeNorm[vid / 6];
    out.worldPos = vp;

    // Color: hue from height + bass shift, saturation full.
    float hue = fract(0.55 + (wy + 0.2) * 0.15 + u.bandsLow.x * 0.3 + u.ctrl.x * 0.02);
    out.baseColor = hsv2rgb(float3(hue, 0.85, 1.0));
    out.intensity = 1.0;
    return out;
}

fragment float4 voxel_sculpt_fs(
    VSVertexOut in [[stage_in]],
    constant VSUniforms &u [[buffer(0)]]
) {
    if (in.intensity < 0.01) discard_fragment();
    // Cheap directional + ambient lighting so faces read clearly.
    float3 lightDir = normalize(float3(0.4, 0.7, 0.5));
    float n = max(0.0, dot(normalize(in.worldNormal), lightDir));
    float3 col = in.baseColor * (0.35 + 0.75 * n);
    // Rim light on +Y normals so the silhouette glows on top.
    col += in.baseColor * 0.4 * pow(max(0.0, in.worldNormal.y), 4.0) * (0.5 + u.ctrl.y);
    // Onset additive flash.
    col += float3(0.4, 0.5, 0.6) * u.ctrl.z * 0.5;
    return float4(col, 1.0);
}

// MARK: - #26 Iridescent Plumage
//
// Each body pixel grows a procedural "feather" oriented along the local depth
// normal. The shaft is shaded with thin-film interference (wavelength-dependent
// color from viewing angle), barbs branch off in a herringbone pattern, and bass
// combs the whole plumage in a wind direction. Onset cuts a stripe of feathers
// outward as if a gust passed through.

fragment float4 plumage_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    float bass = u.bands[0] + u.bands[1];
    float mid  = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // Background — moody dark gradient
    if (!inBody) {
        float3 bg = mix(float3(0.005, 0.005, 0.012), float3(0.025, 0.012, 0.030), uv.y);
        bg += float3(0.05, 0.03, 0.10) * u.onset * 0.20;
        bg *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
        return float4(bg, 1);
    }

    // — Depth normal (the feather "shaft direction" follows it).
    float dL = depthTex.sample(s, depthUV - float2(0.0025, 0)).r;
    float dR = depthTex.sample(s, depthUV + float2(0.0025, 0)).r;
    float dT = depthTex.sample(s, depthUV - float2(0, 0.0025)).r;
    float dB = depthTex.sample(s, depthUV + float2(0, 0.0025)).r;
    if (dL <= 0 || dL > u.farMM) dL = depthMM;
    if (dR <= 0 || dR > u.farMM) dR = depthMM;
    if (dT <= 0 || dT > u.farMM) dT = depthMM;
    if (dB <= 0 || dB > u.farMM) dB = depthMM;
    float dx = (dR - dL) * 0.0008;
    float dy = (dB - dT) * 0.0008;
    float3 n = normalize(float3(-dx, -dy, 1.0));

    // — Cellular feather grid, biased downward by bass (gravity comb).
    float cellSize = 0.018 - bass * 0.004 + treb * 0.002;
    cellSize = max(cellSize, 0.008);
    float2 windOffset = float2(sin(t * 0.6) * 0.005, bass * 0.020);
    float2 fUV = (uv + windOffset) / cellSize;
    float2 cellI = floor(fUV);
    float2 cellF = fract(fUV) - 0.5;

    float cellHash = hash21(cellI);
    float cellHash2 = hash21(cellI + 13.7);

    // Per-cell base orientation (radians)
    float baseAng = (cellHash - 0.5) * 0.6;
    // Add a global wind direction component
    float windAng = sin(t * 0.4 + cellI.x * 0.07) * 0.3 + bass * 0.4;
    float ang = baseAng + windAng;
    // Treble adds high-frequency ruffle
    ang += sin(t * 8.0 + cellHash2 * 13.0) * treb * 0.15;

    float ca = cos(ang);
    float sa = sin(ang);
    // Rotate cellF into shaft-aligned coords
    float2 sf = float2(ca * cellF.x - sa * cellF.y, sa * cellF.x + ca * cellF.y);

    // — Feather shaft: vertical line down the cell middle with herringbone barbs.
    float shaft = 1.0 - smoothstep(0.02, 0.06, abs(sf.x));
    // Barb pattern: cosine across length, falling off with distance from shaft
    float barbFreq = 18.0 + treb * 8.0;
    float barbPhase = sf.y * barbFreq + cellHash * 6.28;
    float barbSign = (sf.y > 0) ? 1.0 : -1.0;
    float barb = cos(barbPhase) * 0.5 + 0.5;
    float barbDist = abs(sf.x - sin(barbPhase) * 0.18 * barbSign);
    float barbMask = smoothstep(0.10, 0.04, barbDist) * (0.4 + barb * 0.6);
    barbMask *= smoothstep(0.5, 0.0, abs(sf.y)) * 0.9;

    float feather = shaft * 0.7 + barbMask * 0.6;
    feather = saturate(feather);

    // — Onset: cut a horizontal stripe across the feathers (gust pass).
    if (u.onset > 0.001) {
        float gustY = fract(t * 0.5) * 2.0 - 0.5;
        float gustDist = abs(uv.y - gustY);
        feather *= 0.3 + smoothstep(0.0, 0.08, gustDist) * 0.7;
    }

    // — Thin-film color: hue cycles with view-angle dot product on normal.
    float viewDot = saturate(dot(n, float3(0, 0, 1)));
    float hueBase = fract(0.40 + cellHash * 0.20 + cellHash2 * 0.10);
    float hueShift = (1.0 - viewDot) * 0.4 + bass * 0.15 + t * 0.04;
    float hue = fract(hueBase + hueShift);
    float3 baseCol = hsv2rgb(float3(hue, 0.7 + treb * 0.2, 1.0));
    // Iridescent secondary — second hue for highlight color
    float3 highlight = hsv2rgb(float3(fract(hue + 0.55), 0.85, 1.0));

    // — Lighting
    float3 keyDir = normalize(float3(0.4, 0.7, 0.6));
    float key = saturate(dot(n, keyDir)) * 0.7 + 0.30;

    // Compose: dark body base + feather glow + edge highlight
    float3 col = baseCol * 0.15 * key;
    col += baseCol * feather * 1.8 * key;
    col += highlight * pow(feather, 4.0) * 0.8;

    // Audio glow
    col += float3(0.10, 0.05, 0.20) * (bass * 0.6 + u.rms * 0.5);
    col += float3(0.40, 0.20, 0.50) * u.onset * 0.40;

    // Sub-surface scattering hint at deep cells
    col += hsv2rgb(float3(fract(hue + 0.5), 0.5, 1.0)) * 0.10;

    // Vignette
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    (void)mid;

    return float4(col, 1.0);
}

// MARK: - #27 Cathedral of Bones
//
// Procedural anatomical X-ray. The body silhouette is divided vertically into
// head / ribcage / pelvis / limb regions by depth-position; each renders a
// region-specific bone pattern as SDF distance lines. Heart at chest center
// pulses with bass; nerve filaments flicker on treble; full-image strobe flash
// on onset. Wet-plate collodion palette: warm blacks, silver-gray bones, glowing
// visceral red where the heart sits.

fragment float4 cathedral_bones_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    float bass = u.bands[0] + u.bands[1];
    float mid  = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // Wet-plate background: warm-black with silver grain
    float3 bg = mix(float3(0.010, 0.012, 0.020), float3(0.025, 0.020, 0.018), uv.y);
    float grain = (hash21(uv * 4096.0 + t * 30.0) - 0.5) * 0.020;
    bg += grain;
    bg *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));

    if (!inBody) {
        // Subtle scanlines on background to suggest film
        bg *= 0.95 + 0.05 * sin(uv.y * 800.0);
        return float4(bg, 1);
    }

    // — Approximate body bounds via depth field. We don't have skeleton here;
    //   instead use the body silhouette's vertical position to pick anatomical region.
    // We need to find topY and bottomY of the body — march vertically.
    // Cheap approx: measure how far the body extends from the current pixel up/down.
    float upDist = 0.0, dnDist = 0.0;
    for (int i = 1; i <= 12; i++) {
        float ofs = float(i) * 0.018;
        float u2 = depthTex.sample(s, float2(uv.x, ((uv.y - ofs) * 1080.0 + 1.0) / 1082.0)).r;
        if (u2 > u.nearMM && u2 < u.farMM && u2 > 0) upDist = ofs;
        float d2 = depthTex.sample(s, float2(uv.x, ((uv.y + ofs) * 1080.0 + 1.0) / 1082.0)).r;
        if (d2 > u.nearMM && d2 < u.farMM && d2 > 0) dnDist = ofs;
    }
    float bodyTop = uv.y - upDist;
    float bodyBot = uv.y + dnDist;
    float bodyH = max(0.001, bodyBot - bodyTop);
    float regionT = saturate((uv.y - bodyTop) / bodyH);

    float silver = 0.0;
    float3 viscera = float3(0);

    // — Region 0..0.18: skull (dome shape outline)
    if (regionT < 0.20) {
        float skullR = 0.06;
        float2 skullCenter = float2(0.5, bodyTop + skullR);
        float skullDist = abs(length(uv - skullCenter) - skullR);
        silver = max(silver, 1.0 - smoothstep(0.0008, 0.005, skullDist));
        // Eye sockets
        float2 eyeL = skullCenter + float2(-0.018, 0.012);
        float2 eyeR = skullCenter + float2( 0.018, 0.012);
        silver = max(silver, exp(-distance(uv, eyeL) * 200.0) * 0.6);
        silver = max(silver, exp(-distance(uv, eyeR) * 200.0) * 0.6);
    }

    // — Region 0.20..0.55: ribcage + spine
    if (regionT > 0.18 && regionT < 0.62) {
        // Spine: vertical line at body center
        float spineDist = abs(uv.x - 0.5);
        silver = max(silver, 1.0 - smoothstep(0.0030, 0.0090, spineDist));

        // Ribs: 7 pairs curving outward from spine
        for (int i = 0; i < 7; i++) {
            float ribY = mix(bodyTop + 0.18 * bodyH, bodyTop + 0.55 * bodyH, float(i) / 6.0);
            float ribDistY = abs(uv.y - ribY);
            // Curve: rib follows arc
            float ribX = 0.5 + sin((uv.y - ribY) * 4.0) * 0.005;
            float ribCurveDist = abs(uv.x - ribX);
            float ribStrength = (1.0 - smoothstep(0.001, 0.004, ribDistY))
                              * (1.0 - smoothstep(0.05, 0.10, ribCurveDist));
            silver = max(silver, ribStrength);
        }

        // Heart: glowing red blob at chest
        float2 heartC = float2(0.485, bodyTop + 0.32 * bodyH);
        float heartR = 0.025 + bass * 0.015 + sin(t * 4.0 + bass * 8.0) * 0.005;
        float heartDist = distance(uv, heartC) / heartR;
        float heartGlow = exp(-heartDist * heartDist * 4.0);
        viscera += float3(1.6, 0.20, 0.10) * heartGlow * (1.2 + bass * 2.0);

        // Nerve flickers on treble — random thin bright line
        if (treb > 0.05) {
            float nerveSeed = floor(t * 40.0);
            float nerveAng = hash21(float2(nerveSeed, 1.0)) * 6.28;
            float2 nerveStart = float2(0.5, bodyTop + 0.30 * bodyH);
            float nerveLen = 0.2;
            float2 nerveEnd = nerveStart + float2(cos(nerveAng), sin(nerveAng)) * nerveLen;
            float2 toN = uv - nerveStart;
            float2 nDir = nerveEnd - nerveStart;
            float lenSq = dot(nDir, nDir);
            float ts = clamp(dot(toN, nDir) / lenSq, 0.0, 1.0);
            float2 closest = nerveStart + nDir * ts;
            float nerveDist = distance(uv, closest);
            silver = max(silver, exp(-nerveDist * 800.0) * treb * 4.0);
        }
    }

    // — Region 0.62..1.0: pelvis + femurs
    if (regionT > 0.55) {
        // Pelvis arc
        float2 pelvisC = float2(0.5, bodyTop + 0.65 * bodyH);
        float pelvisDist = distance(uv, pelvisC);
        silver = max(silver, (1.0 - smoothstep(0.045, 0.055, pelvisDist))
                            * smoothstep(0.040, 0.046, pelvisDist));
        // Femurs
        float fSlope = (uv.x - 0.5) * 4.0;
        float femurY = bodyTop + 0.70 * bodyH + fSlope * fSlope * 0.3;
        float femurDist = abs(uv.y - femurY);
        float legSep = abs(abs(uv.x - 0.5) - 0.04);
        silver = max(silver, (1.0 - smoothstep(0.002, 0.006, femurDist))
                            * (1.0 - smoothstep(0.005, 0.020, legSep)));
    }

    // Compose: silver bone color + visceral red glow + audio modulation
    float3 boneColor = float3(0.85, 0.83, 0.78);
    float3 col = bg + silver * boneColor * (1.0 + u.rms * 0.4);
    col += viscera;

    // Onset: full-frame strobe flash (radiograph)
    if (u.onset > 0.5) col += float3(0.6, 0.6, 0.55) * 0.35;

    // Subtle ambient red wash inside body
    col += float3(0.08, 0.02, 0.02) * 0.5 * (1.0 + bass * 0.6);

    // Vignette + scanlines
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    col *= 0.92 + 0.08 * sin(uv.y * 1080.0 * 0.5);
    (void)mid;

    return float4(saturate(col), 1.0);
}

// MARK: - #28 Pixel Storm (3D pixel-sort cascade)
//
// Streamers of color cascade vertically from each non-body pixel, with sort
// thresholds modulated per-band. The body silhouette stays pristine — sort
// happens only behind. Onset triggers a hard re-sort wave that rolls across.

fragment float4 pixel_storm_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> colorTex [[texture(0)]],
    texture2d<float, access::sample> depthTex [[texture(1)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    float bass = u.bands[0] + u.bands[1];
    float mid  = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    if (inBody) {
        // Body stays pristine + slight chromatic bloom
        float3 c = colorTex.sample(s, uv).rgb;
        // Subtle vignette so body floats
        c *= 1.0 + u.rms * 0.20;
        return float4(c, 1.0);
    }

    // — Sort cascade: each column's pixel chooses a brightness-sorted color
    //   from a vertical sample run modulated by audio bands.
    float colSeed = uv.x;
    int bandIdx = int(colSeed * 8.0);
    float bandStrength = (bandIdx >= 0 && bandIdx < 8) ? u.bands[bandIdx] : 0.0;

    // Vertical "streamer" sample — read 8 vertical positions, pick one based on threshold.
    float threshold = 0.3 - bandStrength * 1.5 + treb * 0.4;
    float3 best = float3(0);
    float bestLum = -1.0;
    for (int i = 0; i < 8; i++) {
        float sy = mix(0.0, 1.0, float(i) / 7.0) + sin(t * 0.5 + colSeed * 8.0) * 0.05;
        float3 c = colorTex.sample(s, float2(uv.x, sy)).rgb;
        float lum = dot(c, float3(0.299, 0.587, 0.114));
        if (lum > bestLum && lum > threshold) {
            bestLum = lum;
            best = c;
        }
    }

    // Streamer fall: shift vertically over time, modulated by bass
    float streamShift = fract(t * (0.6 + bass * 1.5) + colSeed * 0.3);
    float streamY = uv.y - streamShift;
    streamY = fract(streamY + 1.0);

    // Choose between sampled and sorted based on Y position
    float3 col;
    if (bestLum > 0) {
        // Sorted streamer (vivid)
        float verticalGate = smoothstep(0.0, 0.1, streamY) * smoothstep(1.0, 0.7, streamY);
        col = mix(colorTex.sample(s, uv).rgb * 0.4, best * 1.6, verticalGate);
    } else {
        col = colorTex.sample(s, uv).rgb * 0.6;
    }

    // — Onset wave: a horizontal stripe of pure-bright sort that rolls down
    if (u.onset > 0.001) {
        float waveY = fract(t * 1.5);
        float waveDist = abs(uv.y - waveY);
        float waveMask = exp(-waveDist * 60.0);
        col = mix(col, float3(1.0), waveMask * u.onset * 0.6);
    }

    // Hue rotate based on band (per-column tint)
    float hueShift = bandStrength * 0.5;
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(col, hsv2rgb(float3(fract(0.6 + colSeed * 0.3 + hueShift), 0.8, lum + 0.2)), 0.4);

    // Scanlines
    col *= 0.90 + 0.10 * sin(uv.y * 1080.0 * 0.7);

    // Vignette
    col *= smoothstep(1.4, 0.4, length((uv - 0.5) * 1.4));
    (void)mid;

    return float4(saturate(col), 1.0);
}

// MARK: - #29 Body of Petals
//
// Procedural floating petal field. Each pixel determines if it falls inside a
// petal blob via skewed coordinates; petals avoid body silhouette via SDF
// repulsion and are tinted with sub-surface scattering glow. Bass releases waves
// of new petals; onset detonates a bouquet from screen center.

fragment float4 petals_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    float bass = u.bands[0] + u.bands[1];
    float mid  = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // Background gradient — soft cream → dusty lavender for spring atmosphere
    float3 bg = mix(float3(0.94, 0.86, 0.78), float3(0.78, 0.65, 0.78), smoothstep(0.0, 1.0, uv.y));
    bg *= 0.65 + bass * 0.20;
    // Airborne dust particles
    float dust = noise2(uv * 220.0 + t * 0.6) * 0.06;
    bg += float3(dust * 0.6, dust * 0.5, dust * 0.4);

    // — Petal grid (skewed for organic spread)
    float scrollSpeed = 0.05 + bass * 0.10;
    float petalSize = 0.040 + treb * 0.015;
    float2 pUV = uv;
    pUV.y -= t * scrollSpeed;  // gravity-fall
    pUV /= petalSize;

    // Skew for offset rows
    float row = floor(pUV.y);
    if (fmod(row, 2.0) > 0.5) pUV.x += 0.5;
    float2 cell = floor(pUV);
    float2 cellF = fract(pUV) - 0.5;

    float cellHash = hash21(cell);
    float cellHash2 = hash21(cell + 17.7);

    // Skip some cells (spaces between petals)
    float cellAlive = step(0.30 - bass * 0.15, cellHash);

    // Onset bouquet: extra petals burst from center
    if (u.onset > 0.5) {
        float distFromCenter = length(uv - 0.5);
        if (distFromCenter < 0.3 && hash21(cell + t * 100.0) > 0.5) cellAlive = 1.0;
    }

    // Petal shape: rotated ellipse (slow rotation per cell)
    float ang = cellHash * 6.28 + t * (0.5 + cellHash2 * 0.8);
    float ca = cos(ang);
    float sa = sin(ang);
    float2 petalLocal = float2(ca * cellF.x + sa * cellF.y, -sa * cellF.x + ca * cellF.y);
    petalLocal.x /= 0.55;  // ellipse axis ratio
    float petalDist = length(petalLocal);

    // Tear-drop deformation
    petalDist += abs(petalLocal.y) * 0.15;

    float petalMask = smoothstep(0.42, 0.32, petalDist) * cellAlive;

    // Petal color: pinks, creams, deep crimson — varied per cell
    float hueChoice = cellHash * 3.0;
    float3 petalCol;
    if (hueChoice < 1.0) petalCol = float3(0.97, 0.85, 0.86);  // soft pink
    else if (hueChoice < 2.0) petalCol = float3(0.78, 0.30, 0.40);  // crimson
    else petalCol = float3(0.96, 0.92, 0.78);  // cream

    // Sub-surface scattering glow — bright center, dim edge
    float subSurface = pow(1.0 - petalDist / 0.42, 2.0);
    float3 ssColor = mix(petalCol, float3(1.0, 0.95, 0.90), 0.5);
    petalCol = mix(petalCol, ssColor, subSurface * 0.6);

    // Wet-edge highlight (rim)
    float rim = smoothstep(0.30, 0.42, petalDist) * smoothstep(0.45, 0.32, petalDist);
    petalCol += float3(1.0) * rim * 0.4;

    float3 col = bg;
    col = mix(col, petalCol, petalMask);

    // — Body avoidance: if there's a body here, dim petals
    if (inBody) {
        col = mix(col, bg * 0.85, 0.5);
    }

    // Audio glow
    col += float3(0.10, 0.04, 0.06) * (bass * 0.4 + u.rms * 0.4);
    col += float3(0.20, 0.08, 0.12) * u.onset * 0.30;

    // Vignette
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    (void)mid;

    return float4(col, 1.0);
}

// MARK: - #30 Mandelbulb Aviary
//
// Cheap raymarched Mandelbulb with body silhouette acting as an attractor for a
// procedural flock — the flock itself is procedural specks (no real boids
// physics, but renders the right energy). Fractal walls expose iridescent inner
// geometry where bands modulate the power exponent.

inline float mandelbulb_de(float3 p, float power) {
    float3 z = p;
    float dr = 1.0;
    float r = 0.0;
    for (int i = 0; i < 6; i++) {
        r = length(z);
        if (r > 2.0) break;
        // Convert to polar
        float theta = acos(z.z / r);
        float phi = atan2(z.y, z.x);
        dr = pow(r, power - 1.0) * power * dr + 1.0;
        // Scale and rotate
        float zr = pow(r, power);
        theta = theta * power;
        phi = phi * power;
        z = zr * float3(sin(theta) * cos(phi),
                        sin(phi) * sin(theta),
                        cos(theta));
        z += p;
    }
    return 0.5 * log(r) * r / dr;
}

fragment float4 mandelbulb_aviary_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // Camera orbits slowly
    float3 ro = float3(sin(t * 0.10) * 2.5, cos(t * 0.07) * 1.5, -3.0);
    float3 lookAt = float3(0, 0, 0);
    float3 fwd = normalize(lookAt - ro);
    float3 right = normalize(cross(float3(0, 1, 0), fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(fwd + right * p.x + up * p.y);

    // Mandelbulb power modulated by audio
    float power = 8.0 + bass * 2.0 - mid * 1.0;

    // Raymarch
    float dist = 0.0;
    float3 hit = ro;
    bool fractalHit = false;
    int hitIters = 0;
    for (int i = 0; i < 60; i++) {
        hit = ro + rd * dist;
        float d = mandelbulb_de(hit, power);
        if (d < 0.001) { fractalHit = true; hitIters = i; break; }
        if (dist > 10.0) break;
        dist += d * 0.6;  // safety factor
    }

    // Background: arctic blue sky with faint stars
    float2 starG = floor(uv * 800.0);
    float starH = hash21(starG);
    float star = step(0.997, starH) * (0.5 + sin(t * 2.0 + starH * 13.0) * 0.5);
    float3 sky = mix(float3(0.02, 0.05, 0.10), float3(0.10, 0.18, 0.30), uv.y);
    sky += float3(star);
    sky += float3(0.05, 0.10, 0.15) * fbm(uv * 5.0 + t * 0.05) * 0.4;

    float3 col = sky;

    if (fractalHit) {
        // Surface normal via gradient
        float e = 0.001;
        float3 n = normalize(float3(
            mandelbulb_de(hit + float3(e, 0, 0), power) - mandelbulb_de(hit - float3(e, 0, 0), power),
            mandelbulb_de(hit + float3(0, e, 0), power) - mandelbulb_de(hit - float3(0, e, 0), power),
            mandelbulb_de(hit + float3(0, 0, e), power) - mandelbulb_de(hit - float3(0, 0, e), power)
        ));
        // Lighting
        float3 lDir = normalize(float3(0.5, 0.8, 0.6));
        float diff = saturate(dot(n, lDir)) * 0.7 + 0.30;

        // Iridescent palette per iteration depth — inside fractal layers vary in hue
        float iterT = float(hitIters) / 60.0;
        float hue = fract(0.55 - iterT * 0.4 + bass * 0.2);
        float3 fractalCol = hsv2rgb(float3(hue, 0.6, 1.0)) * diff;

        // Fresnel rim
        float fres = pow(1.0 - saturate(-dot(rd, n)), 3.0);
        fractalCol += float3(0.6, 0.7, 0.9) * fres * 0.5;

        col = fractalCol;
    }

    // — Bird flock: scatter procedural specks with vermilion trails through screen
    int flockCount = 80;
    for (int i = 0; i < 80; i++) {
        if (i >= flockCount) break;
        float fi = float(i);
        // Each bird orbits a slightly different center, time-shifted.
        float orbAng = t * (0.7 + fract(fi * 0.13) * 0.5) + fi * 0.78;
        float orbR = 0.35 + 0.20 * sin(t * 0.4 + fi * 0.2);
        float2 birdC = float2(0.5 + cos(orbAng) * orbR * 0.6,
                              0.5 + sin(orbAng * 1.3 + fi) * orbR * 0.4);
        // Body attractor — pull birds toward body center if depth there
        float2 bDU = float2(birdC.x, (birdC.y * 1080.0 + 1.0) / 1082.0);
        float bd = depthTex.sample(s, bDU).r;
        if (bd > u.nearMM && bd < u.farMM && bd > 0) {
            // Drift around body
            birdC = mix(birdC, float2(0.5), 0.2);
        }

        float birdDist = distance(uv, birdC);
        float birdSize = 0.005 + treb * 0.003;
        float birdMask = smoothstep(birdSize, birdSize * 0.5, birdDist);
        // Trail
        float2 trailDir = float2(-sin(orbAng * 1.3 + fi), cos(orbAng * 1.3 + fi)) * 0.04;
        float trailDist = abs((uv.x - birdC.x) * trailDir.y - (uv.y - birdC.y) * trailDir.x) /
                          (length(trailDir) + 1e-4);
        float trailMask = (1.0 - smoothstep(0.0008, 0.0050, trailDist)) *
                          smoothstep(0.05, 0.0, distance(uv, birdC));
        col += float3(0.95, 0.30, 0.20) * (birdMask + trailMask * 0.5);
    }

    // Onset: brief flash
    col += float3(0.4, 0.6, 0.8) * u.onset * 0.30;

    // ACES tone curve
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));

    return float4(col, 1.0);
}

// MARK: - #31 Smoke God
//
// Body-as-light-source raymarched volumetric fog. Per-pixel ray marches into
// space, accumulates fog density (FBM) modulated by bass, and where the ray
// passes near body silhouette, the fog "lights up" — body emits shafts of
// crepuscular rays. Onset triggers ember sparks throughout the volume.

fragment float4 smoke_god_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // Sample current pixel's depth — the body is the light source
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    // Camera at origin, ray in p direction
    float3 ro = float3(0, 0, -2.0);
    float3 rd = normalize(float3(p, 1.0));

    // March accumulating fog
    float3 acc = float3(0);
    float trans = 1.0;
    const int STEPS = 32;
    float zNear = 0.5;
    float zFar = 5.0;
    float dz = (zFar - zNear) / float(STEPS);

    // For god-rays: sample depth along the projected ray to detect "lit" regions
    for (int i = 0; i < STEPS; i++) {
        if (trans < 0.005) break;
        float z = zNear + (float(i) + hash21(uv * 100.0 + t)) * dz;
        float3 q = ro + rd * z;
        // Animate fog
        q.xy += float2(sin(t * 0.15 + q.z), cos(t * 0.12 - q.z * 0.5)) * 0.4;
        q.z += t * 0.08;

        float density = fbm3(q * (1.5 + bass * 0.6));
        density = pow(saturate(density - 0.40), 2.0) * (0.8 + u.rms * 1.2);

        // Project sample back to screen and check body silhouette
        // Approximate: sample depth at the ray's projected (x,y)
        float2 projUV = uv + (q.xy * 0.04);  // small offset based on world pos
        projUV = clamp(projUV, 0.001, 0.999);
        float2 pDU = float2(projUV.x, (projUV.y * 1080.0 + 1.0) / 1082.0);
        float pDM = depthTex.sample(s, pDU).r;
        bool nearBody = pDM > u.nearMM && pDM < u.farMM && pDM > 0;

        // God-ray: fog lights up where ray passes through body's "light"
        float lit = nearBody ? (1.5 + bass * 1.0) : 0.4;

        // Hue: warm gold near body, cool blue in shadows
        float hue = nearBody ? fract(0.10 + t * 0.02 + bass * 0.05) : fract(0.58 + t * 0.01);
        float3 emit = hsv2rgb(float3(hue, 0.5, 1.0)) * lit * (0.4 + treb * 0.6);

        // Ember sparks on onset
        if (u.onset > 0.5) {
            float spark = step(0.998, fract(sin(dot(q.xy + q.z * 13.0, float2(12.9, 78.2))) * 4357.5));
            emit += float3(2.5, 1.5, 0.5) * spark;
        }

        float a = 1.0 - exp(-density * dz * 5.0);
        acc += trans * emit * a;
        trans *= 1.0 - a;
    }

    // Background — deep teal with hint of amber sun
    float3 bg = mix(float3(0.005, 0.012, 0.025), float3(0.030, 0.020, 0.015), uv.y);
    bg += float3(0.05, 0.04, 0.02) * smoothstep(0.4, 0.0, length(uv - float2(0.5, 0.3)));
    acc += bg * trans;

    // Body pixels get an additional warm glow halo
    if (inBody) {
        float zN = saturate((depthMM - u.nearMM) / max(1.0, u.farMM - u.nearMM));
        acc += float3(0.6, 0.4, 0.2) * (1.0 - zN) * (0.4 + u.rms * 0.6);
    }

    // ACES tone curve
    acc = (acc * (2.51 * acc + 0.03)) / (acc * (2.43 * acc + 0.59) + 0.14);
    acc = saturate(acc);

    // Vignette + subtle grain
    acc *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    acc += (hash21(uv * 4096.0 + t * 30.0) - 0.5) * 0.02;
    (void)mid;

    return float4(acc, 1.0);
}

// MARK: - #32 Stained Cathedral
//
// Procedural rosette window with body silhouette as the cut-out tracery. Twelve
// radial sections (like a clock), each colored by a hue rotated through the
// chromatic spectrum, modulated per band. Volumetric god-ray simulation: rays
// emanate from the rosette center and scatter through dust-mote air. Body acts
// as occluder, casting shafts.

fragment float4 stained_cathedral_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    float r = length(p);
    float ang = atan2(p.y, p.x);
    if (ang < 0) ang += 6.2831853;

    // — Rosette window: 12-fold radial symmetry with concentric rings
    int sectorIdx = int(ang * 12.0 / 6.2831853);
    sectorIdx = clamp(sectorIdx, 0, 11);
    float sectorAng = fmod(ang * 12.0 / 6.2831853, 1.0);
    float ringIdx = floor(r * 8.0);
    float ringFract = fract(r * 8.0);

    // Lead tracery: dark lines between sectors and rings
    float sectorLead = smoothstep(0.05, 0.12, abs(sectorAng - 0.5));
    float ringLead = smoothstep(0.08, 0.20, abs(ringFract - 0.5));
    float traceryMask = sectorLead * ringLead;

    // Glass color: each sector gets a hue mapped to its index (rainbow rosette)
    float sectorHue = fract(float(sectorIdx) / 12.0 + bass * 0.10 + t * 0.02);
    float ringHueShift = ringFract * 0.15;
    float3 glassColor = hsv2rgb(float3(fract(sectorHue + ringHueShift), 0.85, 1.0));

    // Audio: each sector responds to one band (cycling through 8)
    int bandIdx = sectorIdx % 8;
    float bandStrength = u.bands[bandIdx];
    glassColor *= 0.5 + bandStrength * 2.0;

    // Inner rosette fades to bright cathedral light at center
    float innerGlow = exp(-r * 4.0) * (0.5 + u.rms * 0.5);
    float3 innerLight = float3(1.0, 0.95, 0.85) * innerGlow * 1.5;

    // — God-rays: sample depth along radial direction; if body is between center
    //   and this pixel, dim the light here.
    float2 toCenter = -p;
    float2 lightDir = normalize(toCenter);
    float occluded = 0.0;
    int rayMarchSteps = 8;
    for (int i = 1; i <= 8; i++) {
        if (i > rayMarchSteps) break;
        float marchT = float(i) / float(rayMarchSteps);
        float2 sampleP = uv + lightDir * 0.4 * marchT * 0.5;
        float2 sDU = float2(sampleP.x, (sampleP.y * 1080.0 + 1.0) / 1082.0);
        float sDM = depthTex.sample(s, sDU).r;
        if (sDM > u.nearMM && sDM < u.farMM && sDM > 0) occluded += 1.0;
    }
    occluded /= float(rayMarchSteps);

    // — Atmospheric dust motes (animated noise)
    float dust = noise2(uv * 100.0 + t * 0.5) * (1.0 - occluded * 0.7);

    // — Body pixel: glow brightly with the spectrum from this position's sector
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    // Compose: glass + lead + inner glow, modulated by occlusion
    float3 col = glassColor * traceryMask * (1.0 - occluded * 0.5);
    col = mix(float3(0.02, 0.018, 0.030), col, traceryMask);  // lead is dark
    col += innerLight;
    col += float3(0.95, 0.92, 0.78) * dust * 0.20;

    if (inBody) {
        // Body pool of light underfoot — saintly halo
        col = glassColor * (0.6 + bass * 0.6 + u.rms * 0.8);
        col += float3(1.0, 0.95, 0.80) * 0.40;
    }

    // Onset: organ pulse — bright flash + glass rotation
    if (u.onset > 0.5) {
        col += float3(0.6, 0.55, 0.45) * 0.40;
    }

    // ACES tone curve
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);
    col *= smoothstep(1.6, 0.3, r * 1.4);
    (void)mid; (void)treb;

    return float4(col, 1.0);
}

// MARK: - #33 Volumetric Aurora
//
// Aurora borealis curtain hugging body contour. Curl-noise advected
// inhomogeneous medium with greens, magentas, deep teals. Bass beats trigger
// vertical "drops" — sudden descents that ripple outward; treble shimmers the
// high-frequency sparkle layer.

fragment float4 aurora_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // Background: deep night sky with stars
    float3 sky = mix(float3(0.005, 0.010, 0.025), float3(0.020, 0.012, 0.040), uv.y);
    float2 starG = floor(uv * 1000.0);
    float starH = hash21(starG);
    float star = step(0.9985, starH) * (0.6 + sin(t * 2.0 + starH * 13.0) * 0.4);
    sky += float3(star);

    // — Aurora curtain: vertically falling waves of color
    float2 curtainP = uv;
    curtainP.y *= 1.5;
    curtainP.x += sin(curtainP.y * 8.0 + t * 0.5) * 0.05 * (1.0 + bass);
    curtainP.y -= t * 0.08;  // slow descent

    float curtain = fbm(curtainP * float2(3.0, 1.5));
    float curtain2 = fbm(curtainP * float2(8.0, 3.0) + 17.3);

    // Bass "drop": sudden vertical compression
    float dropPhase = u.onset * 1.0;
    if (dropPhase > 0.001) {
        curtainP.y -= dropPhase * 0.3;
    }

    // Aurora intensity is non-uniform — sharp top edge, fading bottom
    float verticalGate = smoothstep(0.0, 0.3, uv.y) * (1.0 - smoothstep(0.5, 1.0, uv.y));
    float auroraDensity = pow(curtain, 2.0) * verticalGate;
    auroraDensity += pow(curtain2, 4.0) * verticalGate * (0.4 + treb * 0.8);

    // Multi-color aurora: green base, magenta accents, teal mid
    float hueA = fract(0.32 + curtain2 * 0.05);   // green-ish
    float hueB = fract(0.85 + bass * 0.05);       // magenta
    float hueC = fract(0.50);                      // teal
    float3 aurora = mix(
        hsv2rgb(float3(hueA, 0.65, 1.0)),
        hsv2rgb(float3(hueB, 0.85, 1.0)),
        smoothstep(0.4, 0.8, curtain2)
    );
    aurora = mix(aurora, hsv2rgb(float3(hueC, 0.70, 1.0)), smoothstep(0.6, 0.9, fbm(curtainP * 2.0 + 31.7)));

    // — Sample depth — body acts as soft attractor, brightening aurora near it
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    // Compose
    float3 col = sky;
    col += aurora * auroraDensity * 1.6;

    // Treble shimmer — high-frequency sparkle layer
    float shimmer = pow(noise2(uv * 80.0 + t * 0.7), 8.0) * treb * 0.8;
    col += float3(0.8, 0.9, 1.0) * shimmer;

    if (inBody) {
        // Body pixels get aurora super-bright
        col += aurora * 2.5;
        // Subtle silhouette outline (rim)
        col += hsv2rgb(float3(hueB, 0.7, 1.0)) * 0.3;
    }

    // Onset additive flash
    col += float3(0.3, 0.6, 0.5) * u.onset * 0.40;

    // ACES tone curve
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);
    col *= smoothstep(1.6, 0.3, length((uv - 0.5) * 1.4));
    (void)mid;

    return float4(col, 1.0);
}

// MARK: - #34 Glass Ocean
//
// Depth surface treated as a translucent glass sheet with refraction; underneath
// a procedural reef with audio-reactive corals and drifting jellies. Refraction
// shifts color sample positions based on local depth gradient. The body becomes
// a god-eye lens distorting the underwater world.

fragment float4 glass_ocean_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    // Depth gradient → glass surface normal, used as refraction vector
    float dL = depthTex.sample(s, depthUV - float2(0.002, 0)).r;
    float dR = depthTex.sample(s, depthUV + float2(0.002, 0)).r;
    float dT = depthTex.sample(s, depthUV - float2(0, 0.002)).r;
    float dB = depthTex.sample(s, depthUV + float2(0, 0.002)).r;
    if (dL <= 0 || dL > u.farMM) dL = depthMM;
    if (dR <= 0 || dR > u.farMM) dR = depthMM;
    if (dT <= 0 || dT > u.farMM) dT = depthMM;
    if (dB <= 0 || dB > u.farMM) dB = depthMM;
    float dx = (dR - dL) * 0.0008;
    float dy = (dB - dT) * 0.0008;
    float refractionAmount = inBody ? (0.05 + bass * 0.04) : 0.0;
    float2 refractedUV = uv - float2(dx, dy) * refractionAmount;

    // — Reef background (procedural sub-scene)
    // Background: deep ocean blue gradient with caustics
    float2 reefUV = refractedUV;
    reefUV.y -= t * 0.02;  // slow scroll
    float caustics = 0.0;
    {
        float2 cP = reefUV * 8.0;
        caustics = sin(cP.x + sin(cP.y * 1.3 + t * 0.4)) * 0.5 + 0.5;
        caustics *= sin(cP.y + cos(cP.x * 1.7 - t * 0.5)) * 0.5 + 0.5;
        caustics = pow(caustics, 6.0);
    }

    float3 deepBlue = float3(0.005, 0.06, 0.16);
    float3 medBlue = float3(0.02, 0.20, 0.35);
    float3 cyan = float3(0.15, 0.55, 0.65);
    float3 reef = mix(deepBlue, medBlue, smoothstep(0.0, 1.0, refractedUV.y));
    reef += float3(0.8, 0.9, 1.0) * caustics * (0.4 + treb * 0.5);

    // Coral structures: vertical procedural shapes
    float coralPhase = sin(refractedUV.x * 30.0 + t * 0.3) * 0.5 + 0.5;
    float coralMask = smoothstep(0.7, 0.9, refractedUV.y) * smoothstep(0.0, 0.2, coralPhase);
    float coralHue = fract(0.95 + bass * 0.15);
    float3 coralCol = hsv2rgb(float3(coralHue, 0.7, 1.0)) * coralMask * 1.5;
    reef += coralCol;

    // Drifting jellies (slow procedural blobs)
    int jellyCount = 8;
    for (int i = 0; i < 8; i++) {
        if (i >= jellyCount) break;
        float fi = float(i);
        float2 jellyC = float2(
            0.5 + 0.4 * sin(t * 0.3 + fi * 1.7),
            0.5 + 0.3 * cos(t * 0.2 + fi * 2.3)
        );
        float jDist = distance(refractedUV, jellyC);
        float jSize = 0.04 + sin(t * 0.8 + fi) * 0.015;
        float jMask = exp(-jDist * jDist / (jSize * jSize));
        float jHue = fract(0.85 + fi * 0.13);
        float3 jCol = hsv2rgb(float3(jHue, 0.5, 1.0));
        reef += jCol * jMask * 0.8 * (0.6 + u.rms * 0.6);
    }

    float3 col = reef;

    // — Body pixels: glass distortion adds a colored fresnel-rim and chromatic split
    if (inBody) {
        // Chromatic aberration on refracted samples
        float aberr = 0.005 + bass * 0.005;
        float r = depthTex.sample(s, depthUV + float2(aberr, 0)).r;
        // Reuse reef as background image at refracted position
        col = reef * (0.7 + u.rms * 0.4);
        // Add rim
        float rimAmount = 1.0 - saturate(abs(dx) + abs(dy)) * 100.0;
        rimAmount = pow(saturate(1.0 - rimAmount), 4.0);
        col += float3(0.7, 0.85, 1.0) * rimAmount * 0.6;
        (void)r;
    }

    // Onset: lightning ripple
    if (u.onset > 0.5) col += float3(0.4, 0.55, 0.65) * 0.30;

    // ACES tone
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    (void)mid;

    return float4(col, 1.0);
}

// MARK: - #35 Mercury Storm
//
// Liquid chrome metaballs orbiting/attracted to the body silhouette. Each pixel
// computes a metaball field from N moving spheres + body attractor, then shades
// the resulting iso-surface with chrome reflection (procedural cubemap-ish look).
// Bass increases viscosity (globs cohere); treble adds shimmer; onset spawns
// vortex bursts. Inspiration: T-1000, Ferrofluid sculptures by Sachiko Kodama.

fragment float4 mercury_storm_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // — Compute metaball field
    float field = 0.0;
    int ballCount = 8;
    for (int i = 0; i < 8; i++) {
        if (i >= ballCount) break;
        float fi = float(i);
        float ang = t * (0.4 + fract(fi * 0.13) * 0.3) + fi * 0.785;
        float r = 0.25 + sin(t * 0.3 + fi * 0.5) * 0.10 + bass * 0.05;
        float2 ballC = float2(cos(ang), sin(ang)) * r;
        float ballR = 0.10 + sin(t * 0.5 + fi) * 0.025 + treb * 0.012;
        float d = distance(p, ballC);
        field += ballR * ballR / max(0.0001, d * d);
    }

    // Body attractor: when body is at this pixel's screen pos, add to field
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;
    if (inBody) {
        field += 1.5 + bass * 0.8;
    }

    // Onset vortex: spawn extra ball at random position
    if (u.onset > 0.5) {
        float vAng = fract(t * 1.0) * 6.28;
        float2 vC = float2(cos(vAng), sin(vAng)) * 0.35;
        float vDist = distance(p, vC);
        float vR = 0.20;
        field += vR * vR / max(0.0001, vDist * vDist);
    }

    // Smooth iso-surface: field > 1.0 = inside metaball
    float isoMask = smoothstep(0.7, 1.3, field);
    float surfaceWidth = abs(field - 1.0);

    // — Chrome shading: derive a fake normal from field gradient
    float2 grad;
    {
        float fl = 0.0, fr = 0.0, fb = 0.0, ft = 0.0;
        for (int i = 0; i < 8; i++) {
            if (i >= ballCount) break;
            float fi = float(i);
            float ang = t * (0.4 + fract(fi * 0.13) * 0.3) + fi * 0.785;
            float rr = 0.25 + sin(t * 0.3 + fi * 0.5) * 0.10 + bass * 0.05;
            float2 ballC = float2(cos(ang), sin(ang)) * rr;
            float ballR = 0.10 + sin(t * 0.5 + fi) * 0.025 + treb * 0.012;
            fl += ballR * ballR / max(0.0001, dot(p - float2(0.005, 0) - ballC, p - float2(0.005, 0) - ballC));
            fr += ballR * ballR / max(0.0001, dot(p + float2(0.005, 0) - ballC, p + float2(0.005, 0) - ballC));
            fb += ballR * ballR / max(0.0001, dot(p - float2(0, 0.005) - ballC, p - float2(0, 0.005) - ballC));
            ft += ballR * ballR / max(0.0001, dot(p + float2(0, 0.005) - ballC, p + float2(0, 0.005) - ballC));
        }
        grad = float2(fr - fl, ft - fb);
    }
    float3 normal = normalize(float3(grad, 1.0));

    // Procedural cubemap: hue varies with reflection direction
    float reflAng = atan2(normal.y, normal.x);
    float reflMag = length(normal.xy);
    float hue = fract(0.55 + reflAng * 0.159154943 + bass * 0.10);
    float3 chromeBase = hsv2rgb(float3(hue, 0.4, 1.0));

    // Anisotropic streak (rotation-aligned)
    float streakAng = atan2(grad.y, grad.x) * 4.0 + t * 2.0;
    float streak = pow(saturate(sin(streakAng) * 0.5 + 0.5), 8.0);
    chromeBase += float3(0.95, 0.92, 0.85) * streak * 0.4;

    // Specular hot dot
    float3 light = normalize(float3(0.3, 0.6, 0.7));
    float3 halfV = normalize(light + float3(0, 0, 1));
    float spec = pow(saturate(dot(normal, halfV)), 64.0) * 1.5;

    // — Background
    float3 bg = mix(float3(0.005, 0.008, 0.020), float3(0.025, 0.012, 0.035), uv.y);
    bg += float3(0.05, 0.03, 0.10) * fbm(uv * 5.0 + t * 0.05) * 0.3;

    float3 col = mix(bg, chromeBase, isoMask);
    col += float3(1.0, 0.95, 0.85) * spec * isoMask;

    // Edge brightness (rim) where field is just below 1.0
    float rim = smoothstep(0.05, 0.0, surfaceWidth) * 0.6;
    col += chromeBase * rim;

    // Onset additive flash
    col += float3(0.4, 0.5, 0.7) * u.onset * 0.30;

    // ACES tone curve
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);

    // Vignette + dirt
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    (void)mid;
    (void)reflMag;

    return float4(col, 1.0);
}

// MARK: - #36 Origami Body
//
// Tessellates body silhouette into triangular paper polygons that fold open and
// closed with audio. Soft inkwash gradients, paper-grain texture, calligraphy
// ink-bleed on fold edges. Onset triggers a refold transition. Inspiration:
// Akira Yoshizawa's wet-folding technique, Es Devlin's *Forest of Us*, kirigami.

fragment float4 origami_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // — Background: rice paper texture
    float paperGrain = noise2(uv * 600.0) * 0.05;
    float paperFiber = noise2(uv * float2(80.0, 40.0)) * 0.08;
    float3 bg = float3(0.92, 0.88, 0.82) - paperGrain - paperFiber;
    bg *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));

    if (!inBody) {
        // Background paper with sumi-e brushstroke shadow
        float brushStroke = noise2(uv * 5.0 + t * 0.03);
        bg -= float3(0.10, 0.08, 0.05) * pow(brushStroke, 6.0) * 0.3;
        bg += float3(0.05, 0.02, 0.0) * u.onset * 0.20;
        return float4(bg, 1);
    }

    // — Triangular tessellation: divide UV into triangles via skewed grid
    float gridSize = 0.045 + treb * 0.015;
    float2 tileUV = uv / gridSize;

    // Skew for triangular pattern
    float2 cellI = floor(tileUV);
    float2 cellF = fract(tileUV);
    bool oddRow = fmod(cellI.y, 2.0) > 0.5;
    if (oddRow) cellF.x = fract(cellF.x + 0.5);
    bool upperTri = cellF.y > cellF.x;

    float triHash = hash21(cellI + (upperTri ? 17.3 : 31.7));
    float triHash2 = hash21(cellI + (upperTri ? 47.1 : 73.9));

    // Each triangle has a "fold angle" — animates open/closed
    float foldPhase = t * (0.6 + triHash * 0.5) + triHash * 6.28;
    float foldAng = sin(foldPhase) * 0.5 + 0.5;
    // Onset: refold burst
    if (u.onset > 0.5) foldAng = triHash;

    // — Depth-based shading
    float dL = depthTex.sample(s, depthUV - float2(0.002, 0)).r;
    float dR = depthTex.sample(s, depthUV + float2(0.002, 0)).r;
    float dT = depthTex.sample(s, depthUV - float2(0, 0.002)).r;
    float dB = depthTex.sample(s, depthUV + float2(0, 0.002)).r;
    if (dL <= 0 || dL > u.farMM) dL = depthMM;
    if (dR <= 0 || dR > u.farMM) dR = depthMM;
    if (dT <= 0 || dT > u.farMM) dT = depthMM;
    if (dB <= 0 || dB > u.farMM) dB = depthMM;

    float dx = (dR - dL) * 0.0006;
    float dy = (dB - dT) * 0.0006;
    float3 normal = normalize(float3(-dx, -dy, 1.0));

    float3 keyDir = normalize(float3(0.4, 0.6, 0.8));
    float key = saturate(dot(normal, keyDir)) * 0.7 + 0.30;

    // Per-triangle fold shading: brighter on "open" angles
    float foldShade = 0.5 + foldAng * 0.5;

    // — Inkwash gradient color: chooses one of three palettes per triangle
    float palette = triHash2 * 3.0;
    float3 inkwash;
    if (palette < 1.0) {
        // Sumi black + warm amber
        inkwash = mix(float3(0.10, 0.08, 0.05), float3(0.85, 0.55, 0.20),
                       smoothstep(0.0, 0.7, foldAng));
    } else if (palette < 2.0) {
        // Indigo blue + soft cream
        inkwash = mix(float3(0.05, 0.10, 0.30), float3(0.92, 0.88, 0.78),
                       smoothstep(0.0, 0.6, foldAng));
    } else {
        // Vermillion + gold
        inkwash = mix(float3(0.55, 0.10, 0.05), float3(0.95, 0.85, 0.45),
                       smoothstep(0.0, 0.6, foldAng));
    }

    // Crease line: dark line along triangle edges
    float edgeDist = min(min(cellF.x, cellF.y), 1.0 - max(cellF.x, cellF.y));
    float creaseMask = smoothstep(0.0, 0.04, edgeDist);

    // Calligraphy ink-bleed on crease (subtle dark feather)
    float inkBleed = pow(1.0 - creaseMask, 2.0) * 0.30;
    inkwash *= 1.0 - inkBleed;

    float3 col = inkwash * key * foldShade;
    col = mix(col * 0.4, col, creaseMask);  // edges darker

    // Audio modulation
    col += float3(0.10, 0.05, 0.05) * (bass * 0.4 + u.rms * 0.3);
    col += float3(0.30, 0.20, 0.15) * u.onset * 0.30;

    // Lens-blur bokeh feel: subtle blur halo on bright fold corners
    float bokeh = smoothstep(0.0, 0.05, edgeDist) * pow(foldAng, 4.0);
    col += float3(0.95, 0.85, 0.55) * bokeh * 0.3;

    // Vignette
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    (void)mid;

    return float4(col, 1.0);
}

// MARK: - #37 Spectral Ocean
//
// Concentric rings of audio spectrogram amplitude scrolling outward from body
// center. Each ring is one historical moment; recent moments form the highest
// crests at the center. Music carves its own coastline. Implemented as a polar
// decomposition with audio bands sampled at angle-determined indices.

fragment float4 spectral_ocean_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    float r = length(p);
    float ang = atan2(p.y, p.x);
    if (ang < 0) ang += 6.2831853;

    // — Ring index: each ring is one "frame" of audio history
    // Ring scrolls outward: ring 0 is the center (now), ring N is N seconds ago
    float ringSpeed = 0.20 + bass * 0.10;
    float ringIdx = r * 30.0 - t * ringSpeed * 30.0;
    float ringFract = fract(ringIdx);

    // Audio band sampled by angle (0..2π → bands 0..7)
    int bandIdx = int(ang * 8.0 / 6.2831853) % 8;
    float bandStrength = u.bands[bandIdx];

    // Each ring's amplitude is determined by the band at that angle (sustained)
    float ringAmp = bandStrength * (1.0 - r * 0.5);  // fade with distance
    ringAmp = pow(ringAmp, 0.7);

    // Ring color from ring depth + audio
    float3 ringHueA = float3(0.05, 0.30, 0.65);  // deep teal
    float3 ringHueB = float3(0.95, 0.50, 0.30);  // warm coral
    float3 ringColor = mix(ringHueA, ringHueB, smoothstep(0.0, 1.0, ringAmp));
    ringColor += hsv2rgb(float3(fract(0.55 + ang * 0.159154943 + t * 0.05), 0.5, 1.0)) * 0.2;

    // Ring crest: brightness peaks at ring boundaries
    float crest = 1.0 - abs(ringFract - 0.5) * 2.0;
    crest = pow(crest, 1.5);
    crest *= ringAmp * (1.0 + u.rms * 0.6);

    // — Concentric vertical "displacement" — pseudo-3D crest height visualization
    // Y-axis perspective tilt
    float perspective = 1.0 - p.y * 0.3;
    float displacement = crest * perspective * 0.3;

    // — Body silhouette: rendered as deep void with golden silhouette outline
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    // Compose: ocean background + crest brightness
    float3 oceanBg = mix(float3(0.005, 0.020, 0.040), float3(0.020, 0.060, 0.090), uv.y);
    float3 col = oceanBg;
    col += ringColor * crest * 1.6;
    col += float3(0.6, 0.8, 1.0) * pow(crest, 4.0) * 1.2;

    // Concentric haze from rms
    col += float3(0.05, 0.10, 0.15) * exp(-r * 1.5) * (0.4 + u.rms * 0.6);

    if (inBody) {
        col = mix(col, float3(0.95, 0.78, 0.26) * 0.6, 0.3);
    }

    // Onset wave crash
    if (u.onset > 0.5) {
        col += float3(0.4, 0.5, 0.6) * 0.40;
    }

    // ACES + vignette
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);
    col *= smoothstep(1.6, 0.3, r * 1.4);
    (void)mid;
    (void)treb;
    (void)displacement;

    return float4(col, 1.0);
}

// MARK: - #38 Forest of Light
//
// Vertical light-pillar field. Each screen column has a "pillar" whose height
// is the depth at that x; color is mapped to the FFT band at that x. Volumetric
// god-ray scatter through the colonnade; body silhouette repels pillars to
// create a person-shaped negative space. Inspiration: UVA's *Our Time*, Bruce
// Munro's installations.

fragment float4 forest_of_light_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // — Pillar grid: each column has a pillar at its center
    float pillarSpacing = 0.025 - bass * 0.008;
    pillarSpacing = max(pillarSpacing, 0.012);
    float pillarHash = hash21(float2(floor(uv.x / pillarSpacing), 0));

    // Pillar X-center at this UV
    float pillarCenterX = (floor(uv.x / pillarSpacing) + 0.5) * pillarSpacing;
    pillarCenterX += sin(t * 0.6 + pillarHash * 13.0) * pillarSpacing * 0.10;  // wind sway

    // Distance to pillar axis (horizontal)
    float pillarDist = abs(uv.x - pillarCenterX) / (pillarSpacing * 0.5);

    // — Sample depth at pillar's X to determine height
    float2 pillarSampleUV = float2(pillarCenterX, 0.5);
    float2 pillarDepthUV = float2(pillarSampleUV.x, (pillarSampleUV.y * 1080.0 + 1.0) / 1082.0);
    float pillarDepthMM = depthTex.sample(s, pillarDepthUV).r;
    bool pillarInBody = pillarDepthMM > u.nearMM && pillarDepthMM < u.farMM && pillarDepthMM > 0;
    float pillarHeight = pillarInBody
        ? saturate(1.0 - (pillarDepthMM - u.nearMM) / max(1.0, u.farMM - u.nearMM))
        : 0.4 + sin(t * 0.4 + pillarHash * 4.0) * 0.10;

    // Body repulsion: if THIS uv is in body, pillar height drops
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;
    if (inBody) pillarHeight = 0.0;  // create negative space

    // Pillar visibility — Y is from bottom (1) to top (0)
    float pillarBottom = 1.0 - pillarHeight;
    float pillarVis = step(pillarBottom, uv.y) * (1.0 - pillarDist);
    pillarVis = saturate(pillarVis);

    // Pillar color: from FFT band at this column
    int bandIdx = int(uv.x * 8.0) % 8;
    float bandStrength = u.bands[bandIdx];
    float hue = fract(0.55 + uv.x * 0.5 + bandStrength * 0.4 + t * 0.02);
    float3 pillarColor = hsv2rgb(float3(hue, 0.65 + bandStrength * 0.20, 1.0));

    // Pillar core glow (vertical streak)
    float core = 1.0 - smoothstep(0.0, 0.3, pillarDist);
    core = pow(core, 3.0);

    // — Volumetric scatter: brightness fades with vertical position above pillar
    float scatterAmt = pow(saturate(1.0 - uv.y), 1.5);

    // Background
    float3 bg = mix(float3(0.005, 0.008, 0.020), float3(0.020, 0.012, 0.030), uv.y);

    float3 col = bg;
    col += pillarColor * pillarVis * (0.6 + bandStrength * 1.5);
    col += pillarColor * core * (1.5 + u.rms * 1.0);

    // Scatter haze
    col += pillarColor * pillarVis * scatterAmt * 0.30;

    // Onset: full row brightens
    if (u.onset > 0.5) col += pillarColor * 0.30;

    // ACES tone
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);

    // Subtle scanlines and vignette
    col *= 0.92 + 0.08 * sin(uv.y * 1080.0 * 0.5);
    col *= smoothstep(1.5, 0.4, length((uv - 0.5) * 1.4));
    (void)mid; (void)treb;

    return float4(col, 1.0);
}

// MARK: - #39 Memory Palace (capstone)
//
// 3×3 mosaic showing nine different aesthetic modes simultaneously, each driven
// by the same depth+audio inputs but routed to a different EQ slice. Each pane
// uses a distinct shader subset — different palette, different effect blend.
// Onset triggers pane rotation (mosaic re-shuffles).

fragment float4 memory_palace_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    texture2d<float, access::sample> colorTex [[texture(1)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // — Pane index: 3×3 mosaic
    int paneX = int(uv.x * 3.0);
    int paneY = int(uv.y * 3.0);
    int paneIdx = paneY * 3 + paneX;
    paneIdx = clamp(paneIdx, 0, 8);

    // Pane local UV (0..1 within each pane)
    float2 paneUV = fract(uv * 3.0);

    // Pane assignment shuffles on onset
    float onsetTime = floor(t * 0.5);
    int shuffle = int(onsetTime) % 9;
    int actualPane = (paneIdx + shuffle) % 9;

    // Sample depth at pane center for inBody check
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    // Each pane has its own EQ slice (one of 8 bands)
    int bandIdx = actualPane % 8;
    float band = u.bands[bandIdx];

    // Each pane gets a distinct base color palette
    float hueShift = float(actualPane) / 9.0;
    float3 paneCol = hsv2rgb(float3(fract(hueShift + bass * 0.10 + t * 0.02), 0.7, 1.0));

    float3 col = float3(0);

    // Pane 0: black hole-ish (radial darkness)
    if (actualPane == 0) {
        float r = length(paneUV - 0.5) * 2.0;
        col = paneCol * (1.0 - r) * (0.5 + band * 1.5);
        if (inBody) col *= 0.3;
    }
    // Pane 1: noise-driven plasma
    else if (actualPane == 1) {
        float n = fbm(paneUV * 5.0 + t * 0.3);
        col = paneCol * pow(n, 1.5) * (0.5 + band * 1.5);
    }
    // Pane 2: scanlines + chromatic
    else if (actualPane == 2) {
        col = colorTex.sample(s, uv).rgb * 1.2;
        col *= 0.85 + 0.15 * sin(uv.y * 1080.0);
        col = mix(col, paneCol, 0.4);
    }
    // Pane 3: caustics
    else if (actualPane == 3) {
        float c1 = sin(paneUV.x * 12.0 + t * 0.7);
        float c2 = sin(paneUV.y * 10.0 - t * 0.5);
        col = paneCol * pow(saturate(c1 + c2), 4.0) * (0.5 + band * 1.5);
    }
    // Pane 4: kaleidoscope
    else if (actualPane == 4) {
        float ang = atan2(paneUV.y - 0.5, paneUV.x - 0.5) * 6.0;
        ang = fract(ang / 6.2831853);
        float r = length(paneUV - 0.5);
        col = hsv2rgb(float3(fract(ang + t * 0.1), 0.8, smoothstep(0.5, 0.2, r))) * (0.5 + band);
    }
    // Pane 5: depth lava
    else if (actualPane == 5) {
        if (inBody) {
            float n = fbm(paneUV * 4.0 + t * 0.4);
            col = paneCol * (0.5 + n) * (0.7 + band * 1.0);
        } else {
            col = paneCol * 0.05;
        }
    }
    // Pane 6: stars
    else if (actualPane == 6) {
        float starH = hash21(floor(paneUV * 200.0));
        col = paneCol * step(0.99, starH) * 1.5;
        col += float3(0.05, 0.05, 0.10);
    }
    // Pane 7: feedback echo
    else if (actualPane == 7) {
        float r1 = distance(paneUV, float2(0.5));
        col = paneCol * pow(1.0 - r1, 2.0) * (0.5 + band);
        col += sin(r1 * 30.0 - t * 2.0) * 0.2;
    }
    // Pane 8: rainbow rings
    else {
        float ang = atan2(paneUV.y - 0.5, paneUV.x - 0.5);
        col = hsv2rgb(float3(fract(ang * 0.159154943 + t * 0.1), 0.85, 1.0)) * (0.5 + band * 1.5);
    }

    // — Pane gutters (dim borders)
    float2 panePixel = paneUV;
    float gutter = min(min(panePixel.x, 1.0 - panePixel.x), min(panePixel.y, 1.0 - panePixel.y));
    col *= smoothstep(0.0, 0.02, gutter);

    // — Soft cross-pane bleed (subtle)
    col *= 0.85 + 0.15 * smoothstep(0.04, 0.08, gutter);

    // Onset additive flash globally
    col += float3(0.3, 0.3, 0.5) * u.onset * 0.30;

    // ACES tone
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);

    col *= smoothstep(1.6, 0.3, length((uv - 0.5) * 1.4));
    (void)mid; (void)treb;

    return float4(col, 1.0);
}
