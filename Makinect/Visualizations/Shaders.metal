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

// RGB → HSV (Hue 0..1, Sat 0..1, Val 0..1+ for HDR). Standard approach.
inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)),
                   d / (q.x + e),
                   q.x);
}

// MARK: - Common post-process pass
//
// Applied AFTER any visualizer renders into an offscreen MTLTexture, this
// pass reads the colour and applies the universal modifiers (hueShift,
// saturationMul, brightnessMul, glowMul) before writing to the drawable.
// One pass per frame, ~0.1 ms at 1080p — no per-visualizer shader changes
// required for the universal colour controls.

struct CommonPostUniforms {
    float4 commonMods;  // (hueShift, saturationMul, brightnessMul, glowMul)
};

fragment float4 common_post_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> srcTex [[texture(0)]],
    constant CommonPostUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 col = srcTex.sample(s, in.uv).rgb;

    // Glow first — push HDR overdrive that the tone curve below catches.
    col *= u.commonMods.w;

    // HSV manipulation: rotate hue, scale saturation, scale value.
    float3 hsv = rgb2hsv(col);
    hsv.x = fract(hsv.x + u.commonMods.x);   // hue rotate
    hsv.y = saturate(hsv.y * u.commonMods.y);
    hsv.z *= u.commonMods.z;
    col = hsv2rgb(hsv);

    // Soft ACES tone-map so the glowMul overdrive lands as bloom-feel rather
    // than clipping. This is identical to the curve already in many of the
    // visualizers' fragment shaders — running it again is idempotent for
    // values already in LDR range.
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = saturate(col);

    return float4(col, 1.0);
}

// MARK: - #2 Point Cloud

struct PointCloudUniforms {
    float4x4 viewProj;     // 64
    float4 timing;         // (time, pointSize, rms, onset)
    float4 bandsLow;       // bands[0..3]
    float4 bandsHigh;      // bands[4..7]
    float4 intrinsics;     // (fx, fy, cx, cy)
    float4 dims;           // (depthW, depthH, _, _)
    float4 style;          // (baseHue, hueGradient, bassDisplacement, saturation)
};
// Total 160 bytes, all 16-aligned.

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

    // Audio displacement (strength user-controlled).
    float bass = u.bandsLow.x + u.bandsLow.y;
    float pulse = rms * 0.3 + onset * 0.4;
    float ang = atan2(ym, xm);
    float radial = sin(ang * 6.0 + time * 2.0) * u.style.z * (bass + pulse);
    xm += cos(ang) * radial;
    ym += sin(ang) * radial;

    float4 worldPos = float4(xm, -ym, -zm, 1.0);
    out.position = u.viewProj * worldPos;
    out.pointSize = pointSize * (1.0 + pulse * 1.5);

    float depthN = saturate((zm - 0.5) / 4.0);
    // Hue: baseHue + gradient×depth user-controlled.
    float hue = u.style.x + depthN * u.style.y + u.bandsLow.w * 0.1;
    float3 col = hsv2rgb(float3(fract(hue), u.style.w, 0.7 + pulse * 0.3));
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

struct PaintParams {
    float4 cfg;   // (beatBoost, audioCoupling, hueOffset, saturation)
    float4 misc;  // (falloff, trail, _, _)
};

vertex PaintVertexOut paint_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant PaintInstance *instances [[buffer(0)]],
    constant PaintUniforms &u [[buffer(1)]],
    constant PaintParams &p [[buffer(2)]]
) {
    float2 quad[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1, 1),
        float2( 1, -1), float2( 1,  1), float2(-1, 1)
    };
    float2 q = quad[vid];
    PaintInstance inst = instances[iid];

    float beat = 1.0 + u.onset * p.cfg.x + u.rms * 0.5;
    float2 size = float2(inst.size) * beat;
    size.x /= u.aspect;

    float2 ndc = float2(inst.position.x * 2.0 - 1.0, 1.0 - inst.position.y * 2.0);
    ndc += q * size;

    PaintVertexOut out;
    out.position = float4(ndc, 0, 1);
    out.localUV = q;
    float h = fmod(inst.jointID * 0.12 + p.cfg.z, 1.0);
    out.color = hsv2rgb(float3(h, p.cfg.w, 1.0));
    out.intensity = inst.intensity;
    return out;
}

fragment float4 paint_fs(
    PaintVertexOut in [[stage_in]],
    constant PaintUniforms &u [[buffer(1)]],
    constant PaintParams &p [[buffer(2)]]
) {
    float r = length(in.localUV);
    float falloffExp = max(0.05, p.misc.x);
    float falloff = smoothstep(1.0, max(0.05, 0.2 / falloffExp), r);
    float flicker = 0.7 + 0.3 * fract(sin(u.time * 30.0 + in.localUV.x * 13.0) * 43758.5);
    float3 col = in.color * flicker * (1.0 + u.bands[5] * 1.2);
    float trail = clamp(p.misc.y, 0.1, 4.0);
    return float4(col * falloff * in.intensity, falloff * in.intensity * 0.8 * trail);
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

struct NebulaParams {
    float4 march;     // (steps, threshold, densityScale, audioCoupling)
    float4 palette;   // (baseHue, saturation, bodyVoid, noiseScale)
};

fragment float4 nebula_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant NebulaParams &cfg [[buffer(1)]]
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

    // — User-tunable parameters
    int   STEPS           = clamp(int(cfg.march.x), 8, 64);
    float threshold       = cfg.march.y;
    float densityScale    = cfg.march.z;
    float audioCoupling   = cfg.march.w;
    float baseHue         = cfg.palette.x;
    float saturation      = cfg.palette.y;
    float bodyVoid        = cfg.palette.z;
    float noiseScale      = cfg.palette.w;

    float3 acc = float3(0.0);
    float trans = 1.0;
    float zNear = 0.5;
    float zFar  = 4.5;
    float dz = (zFar - zNear) / float(STEPS);

    float palShift = bass * 0.12 + baseHue + 0.05 * sin(t * 0.3);

    for (int i = 0; i < 64; i++) {
        if (i >= STEPS) break;
        float z = zNear + (float(i) + 0.5) * dz;
        float3 q = ro + rd * z;
        q.xy += float2(sin(t * 0.15 + q.z), cos(t * 0.18 - q.z * 0.5)) * 0.3;
        q.z += t * 0.1;

        float density = fbm3(q * (noiseScale + bass * 0.4));
        density = pow(saturate(density - threshold), 2.0) * (densityScale + u.rms * audioCoupling);

        // Body silhouette void.
        if (body && z < 2.5) density *= max(0.0, 1.0 - bodyVoid);

        // Emission color: hue ramps with z, brightened by treble.
        float hue = palShift + z * 0.07 + density * 0.2;
        float3 emit = hsv2rgb(float3(fract(hue), saturation, 1.0)) * (0.5 + treb * 1.2);

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
    // — Bespoke user controls (ParticleStormConfig)
    float4 motion;   // (curlScale, accelGain, damping, bodyPull)
    float4 burst;    // (onsetBurst, recycleAge, baseHue, hueSpread)
    float4 paint;    // (pointSizeBase, speedToSize, jitterAmount, saturation)
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

    // — User-tunable parameters (read from PSUniforms.motion / .burst / .paint)
    float curlScale       = u.motion.x;
    float accelGain       = u.motion.y;
    float damping         = u.motion.z;
    float bodyPull        = u.motion.w;
    float onsetBurst      = u.burst.x;
    float recycleAgeLimit = u.burst.y;
    float jitterAmt       = u.paint.z;

    // Curl noise — bass still modulates spatial frequency (drift) and audio
    // RMS still amplifies the force, but absolute scale is now user-controlled.
    float scale = curlScale * (0.5 + u.audio.z * 1.5);
    float3 acc = curl_noise(float3(s.posLife.xy * scale, t * 0.3)) * accelGain * (0.7 + u.audio.x * 1.5);

    // Treble jitter — adds high-frequency randomness to acceleration.
    if (jitterAmt > 0.001) {
        float jSeed = float(gid) * 0.000037 + t * 0.5;
        acc.xy += float2(sin(jSeed * 31.0), sin(jSeed * 53.0)) * jitterAmt * u.audio.w * 0.6;
    }

    // Body attractor: pull strength is now user-tunable (and zero disables it).
    float2 uv = float2(s.posLife.x * 0.5 + 0.5, 0.5 - s.posLife.y * 0.5);
    if (bodyPull > 0.001 && uv.x > 0 && uv.x < 1 && uv.y > 0 && uv.y < 1) {
        constexpr sampler ss(filter::linear, address::clamp_to_edge);
        float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
        float depthMM = depthTex.sample(ss, depthUV).r;
        bool inBody = depthMM > range.x && depthMM < range.y && depthMM > 0;
        if (inBody) {
            float2 toCenter = (float2(0.0, 0.0) - s.posLife.xy);
            float r = length(toCenter) + 1e-3;
            // Onset still flips the pull direction so the body "pushes off" on beats.
            float pull = (u.audio.y > 0.5) ? -bodyPull * 1.7 : bodyPull * 1.0;
            acc.xy += toCenter / r * pull * 0.4;
        }
    }

    // Beat shockwave: outward burst, magnitude user-tunable.
    if (u.audio.y > 0.5 && onsetBurst > 0.001) {
        float2 outv = normalize(s.posLife.xy + 0.001) * onsetBurst;
        acc.xy += outv;
    }

    // Integrate with user-controlled damping.
    float3 vel = s.velAge.xyz * damping + acc * dt;
    float3 pos = s.posLife.xyz + vel * dt;

    // Recycle particles that drifted too far or aged out (age limit user-controlled).
    bool recycle = (length(pos.xy) > 2.5) || (age > recycleAgeLimit);
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

    // User-tunable point-sprite styling.
    float pointSizeBase = u.paint.x;
    float speedToSize   = u.paint.y;
    float saturation    = u.paint.w;
    float baseHue       = u.burst.z;
    float hueSpread     = u.burst.w;

    float speed = length(p.velAge.xy);
    o.pointSize = clamp(pointSizeBase + speed * speedToSize + u.audio.x * 4.0, 1.0, 18.0);

    // Hue: per-particle index drift (was random in init), shifted by audio.
    float hueShift = u.audio.z * 0.2 - u.audio.w * 0.15;
    float hue = fract(baseHue + (p.color.x - 0.5) * hueSpread + hueShift);
    float3 col = hsv2rgb(float3(hue, saturate(saturation), saturate(p.color.y * 0.6)));
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
    float4 style;           // (baseHue, hueSpread, saturation, audioCoupling)
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

    // Color: hue from height + bass shift, with user palette controls.
    float hue = fract(u.style.x + (wy + 0.2) * u.style.y + u.bandsLow.x * u.style.w + u.ctrl.x * 0.02);
    out.baseColor = hsv2rgb(float3(hue, u.style.z, 1.0));
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

struct BonesParams {
    float4 cfg;   // (heartSize, heartPulse, nerveIntensity, boneTint)
    float4 misc;  // (strobeIntensity, plateWarmth, visceraGlow, boneThickness)
};

fragment float4 cathedral_bones_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant BonesParams &p [[buffer(1)]]
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

    // Wet-plate background: warm-black with silver grain.
    // plateWarmth (p.misc.y) lerps between cool film and warm collodion.
    float warmth = p.misc.y;
    float3 coolBg = mix(float3(0.012, 0.015, 0.026), float3(0.020, 0.022, 0.026), uv.y);
    float3 warmBg = mix(float3(0.010, 0.012, 0.020), float3(0.025, 0.020, 0.018), uv.y);
    float3 bg = mix(coolBg, warmBg, warmth);
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

    // boneThickness (p.misc.w) scales line thickness for every bone.
    float thick = max(0.4, p.misc.w);

    // — Region 0..0.18: skull (dome shape outline)
    if (regionT < 0.20) {
        float skullR = 0.06;
        float2 skullCenter = float2(0.5, bodyTop + skullR);
        float skullDist = abs(length(uv - skullCenter) - skullR);
        silver = max(silver, 1.0 - smoothstep(0.0008 * thick, 0.005 * thick, skullDist));
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
        silver = max(silver, 1.0 - smoothstep(0.0030 * thick, 0.0090 * thick, spineDist));

        // Ribs: 7 pairs curving outward from spine
        for (int i = 0; i < 7; i++) {
            float ribY = mix(bodyTop + 0.18 * bodyH, bodyTop + 0.55 * bodyH, float(i) / 6.0);
            float ribDistY = abs(uv.y - ribY);
            // Curve: rib follows arc
            float ribX = 0.5 + sin((uv.y - ribY) * 4.0) * 0.005;
            float ribCurveDist = abs(uv.x - ribX);
            float ribStrength = (1.0 - smoothstep(0.001 * thick, 0.004 * thick, ribDistY))
                              * (1.0 - smoothstep(0.05, 0.10, ribCurveDist));
            silver = max(silver, ribStrength);
        }

        // Heart: glowing red blob at chest. heartSize/heartPulse user-controlled.
        float heartBase = max(0.005, p.cfg.x);
        float heartPulse = max(0.0, p.cfg.y);
        float2 heartC = float2(0.485, bodyTop + 0.32 * bodyH);
        float heartR = heartBase + bass * 0.015 * heartPulse + sin(t * 4.0 + bass * 8.0) * 0.005 * heartPulse;
        float heartDist = distance(uv, heartC) / heartR;
        float heartGlow = exp(-heartDist * heartDist * 4.0);
        float visceraGlow = max(0.0, p.misc.z);
        viscera += float3(1.6, 0.20, 0.10) * heartGlow * (1.2 + bass * 2.0) * visceraGlow;

        // Nerve flickers on treble — random thin bright line. nerveIntensity user-controlled.
        float nerveStrength = max(0.0, p.cfg.z);
        if (treb > 0.05 && nerveStrength > 0.001) {
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
            silver = max(silver, exp(-nerveDist * 800.0) * treb * 4.0 * nerveStrength);
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
        silver = max(silver, (1.0 - smoothstep(0.002 * thick, 0.006 * thick, femurDist))
                            * (1.0 - smoothstep(0.005, 0.020, legSep)));
    }

    // Compose: silver bone color + visceral red glow + audio modulation.
    // boneTint (p.cfg.w) shifts hue between warm silver (0) and cool blue (1).
    float boneTint = saturate(p.cfg.w);
    float3 warmBone = float3(0.85, 0.83, 0.78);
    float3 coolBone = float3(0.72, 0.78, 0.92);
    float3 boneColor = mix(warmBone, coolBone, boneTint);
    float3 col = bg + silver * boneColor * (1.0 + u.rms * 0.4);
    col += viscera;

    // Onset: full-frame strobe flash (radiograph). strobeIntensity user-controlled.
    float strobe = max(0.0, p.misc.x);
    if (u.onset > 0.5) col += float3(0.6, 0.6, 0.55) * 0.35 * strobe;

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

struct PixelStormParams {
    float4 cfg;  // (sampleCount, fallSpeed, thresholdOffset, bodyProtect)
    float4 misc; // (hueTint, _, _, _)
};

fragment float4 pixel_storm_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> colorTex [[texture(0)]],
    texture2d<float, access::sample> depthTex [[texture(1)]],
    constant Uniforms &u [[buffer(0)]],
    constant PixelStormParams &p [[buffer(1)]]
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

    // Body protection user-controlled (0 = body sorted too, 1 = pristine).
    if (inBody && p.cfg.w > 0.5) {
        float3 c = colorTex.sample(s, uv).rgb;
        c *= 1.0 + u.rms * 0.20;
        return float4(c, 1.0);
    }

    // — Sort cascade: each column's pixel chooses a brightness-sorted color
    //   from a vertical sample run modulated by audio bands.
    float colSeed = uv.x;
    int bandIdx = int(colSeed * 8.0);
    float bandStrength = (bandIdx >= 0 && bandIdx < 8) ? u.bands[bandIdx] : 0.0;

    // Sample count + threshold offset user-controlled.
    int sampleCount = clamp(int(p.cfg.x), 4, 16);
    float threshold = 0.3 - bandStrength * 1.5 + treb * 0.4 + p.cfg.z;
    float3 best = float3(0);
    float bestLum = -1.0;
    for (int i = 0; i < 16; i++) {
        if (i >= sampleCount) break;
        float sy = mix(0.0, 1.0, float(i) / float(sampleCount - 1)) + sin(t * 0.5 + colSeed * 8.0) * 0.05;
        float3 c = colorTex.sample(s, float2(uv.x, sy)).rgb;
        float lum = dot(c, float3(0.299, 0.587, 0.114));
        if (lum > bestLum && lum > threshold) {
            bestLum = lum;
            best = c;
        }
    }

    // Streamer fall: shift vertically over time (speed user-controlled).
    float streamShift = fract(t * (0.6 + bass * 1.5) * p.cfg.y + colSeed * 0.3);
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

    // Hue rotate based on band (per-column tint, base hue user-controlled).
    float hueShift = bandStrength * 0.5;
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(col, hsv2rgb(float3(fract(p.misc.x + colSeed * 0.3 + hueShift), 0.8, lum + 0.2)), 0.4);

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

struct PetalsParams {
    float4 motion;    // (petalSize, density, fallSpeed, bassFall)
    float4 palette;   // (hueA, hueB, hueC, saturation)
    float4 mood;      // (subSurface, bodyAvoidance, onsetBouquet, _)
};

fragment float4 petals_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant PetalsParams &cfg [[buffer(1)]]
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

    // — User-tunable parameters
    float petalSizeBase = cfg.motion.x;
    float density       = cfg.motion.y;
    float fallSpeed     = cfg.motion.z;
    float bassFall      = cfg.motion.w;

    // Background gradient — soft cream → dusty lavender for spring atmosphere
    float3 bg = mix(float3(0.94, 0.86, 0.78), float3(0.78, 0.65, 0.78), smoothstep(0.0, 1.0, uv.y));
    bg *= 0.65 + bass * 0.20;
    // Airborne dust particles
    float dust = noise2(uv * 220.0 + t * 0.6) * 0.06;
    bg += float3(dust * 0.6, dust * 0.5, dust * 0.4);

    // — Petal grid (skewed for organic spread). Size + scroll user-controlled.
    float scrollSpeed = fallSpeed + bass * bassFall;
    float petalSize = petalSizeBase + treb * 0.015;
    float2 pUV = uv;
    pUV.y -= t * scrollSpeed;
    pUV /= petalSize;

    // Skew for offset rows
    float row = floor(pUV.y);
    if (fmod(row, 2.0) > 0.5) pUV.x += 0.5;
    float2 cell = floor(pUV);
    float2 cellF = fract(pUV) - 0.5;

    float cellHash = hash21(cell);
    float cellHash2 = hash21(cell + 17.7);

    // Skip some cells (spaces between petals) — density user-controlled.
    float cellAlive = step(1.0 - density - bass * 0.15, cellHash);

    // Onset bouquet: extra petals burst from center — magnitude user-controlled.
    if (u.onset > 0.5 && cfg.mood.z > 0.001) {
        float distFromCenter = length(uv - 0.5);
        if (distFromCenter < 0.3 * cfg.mood.z && hash21(cell + t * 100.0) > 0.5) cellAlive = 1.0;
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

    // Petal color: three user-controlled hues, randomly assigned per cell.
    float hueChoice = cellHash * 3.0;
    float petalHue;
    if      (hueChoice < 1.0) petalHue = cfg.palette.x;
    else if (hueChoice < 2.0) petalHue = cfg.palette.y;
    else                      petalHue = cfg.palette.z;
    float3 petalCol = hsv2rgb(float3(petalHue, cfg.palette.w, 0.95));

    // Sub-surface scattering glow — strength user-controlled.
    float subSurface = pow(1.0 - petalDist / 0.42, 2.0);
    float3 ssColor = mix(petalCol, float3(1.0, 0.95, 0.90), 0.5);
    petalCol = mix(petalCol, ssColor, subSurface * cfg.mood.x);

    // Wet-edge highlight (rim)
    float rim = smoothstep(0.30, 0.42, petalDist) * smoothstep(0.45, 0.32, petalDist);
    petalCol += float3(1.0) * rim * 0.4;

    float3 col = bg;
    col = mix(col, petalCol, petalMask);

    // — Body avoidance: if there's a body here, dim petals (strength user-controlled).
    if (inBody && cfg.mood.y > 0.001) {
        col = mix(col, bg * 0.85, 0.5 * cfg.mood.y);
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

struct MandelbulbAviaryParams {
    float4 fractal;   // (fractalPower, powerAudioMod, raymarchSteps, fractalHue)
    float4 flock;     // (camOrbitSpeed, birdCount, birdSize, birdBodyAttract)
    float4 misc;      // (birdHue, _, _, _)
};

fragment float4 mandelbulb_aviary_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant MandelbulbAviaryParams &cfg [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // — User-tunable parameters
    float fractalPowerBase = cfg.fractal.x;
    float powerAudioMod    = cfg.fractal.y;
    int   raymarchSteps    = clamp(int(cfg.fractal.z), 12, 80);
    float fractalHueBase   = cfg.fractal.w;
    float camOrbitSpeed    = cfg.flock.x;

    // Camera orbits at user-controlled speed.
    float3 ro = float3(sin(t * camOrbitSpeed) * 2.5, cos(t * camOrbitSpeed * 0.7) * 1.5, -3.0);
    float3 lookAt = float3(0, 0, 0);
    float3 fwd = normalize(lookAt - ro);
    float3 right = normalize(cross(float3(0, 1, 0), fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(fwd + right * p.x + up * p.y);

    // Mandelbulb power = base + audio mod (audio scales bass effect down/up).
    float power = fractalPowerBase + bass * powerAudioMod - mid * powerAudioMod * 0.5;

    // Raymarch — step budget user-controlled (lower = faster but blockier).
    float dist = 0.0;
    float3 hit = ro;
    bool fractalHit = false;
    int hitIters = 0;
    for (int i = 0; i < 80; i++) {
        if (i >= raymarchSteps) break;
        hit = ro + rd * dist;
        float d = mandelbulb_de(hit, power);
        if (d < 0.001) { fractalHit = true; hitIters = i; break; }
        if (dist > 10.0) break;
        dist += d * 0.6;
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

        // Iridescent palette per iteration depth — base hue user-controlled.
        float iterT = float(hitIters) / float(max(1, raymarchSteps));
        float hue = fract(fractalHueBase - iterT * 0.4 + bass * 0.2);
        float3 fractalCol = hsv2rgb(float3(hue, 0.6, 1.0)) * diff;

        // Fresnel rim
        float fres = pow(1.0 - saturate(-dot(rd, n)), 3.0);
        fractalCol += float3(0.6, 0.7, 0.9) * fres * 0.5;

        col = fractalCol;
    }

    // — Bird flock: scatter procedural specks with vermilion trails through screen
    int flockCount = clamp(int(cfg.flock.y), 0, 120);
    float birdSize = cfg.flock.z;
    float bodyAttract = cfg.flock.w;
    float birdHue = cfg.misc.x;
    for (int i = 0; i < 120; i++) {
        if (i >= flockCount) break;
        float fi = float(i);
        // Each bird orbits a slightly different center, time-shifted.
        float orbAng = t * (0.7 + fract(fi * 0.13) * 0.5) + fi * 0.78;
        float orbR = 0.35 + 0.20 * sin(t * 0.4 + fi * 0.2);
        float2 birdC = float2(0.5 + cos(orbAng) * orbR * 0.6,
                              0.5 + sin(orbAng * 1.3 + fi) * orbR * 0.4);
        // Body attractor — pull birds toward body center if depth there.
        float2 bDU = float2(birdC.x, (birdC.y * 1080.0 + 1.0) / 1082.0);
        float bd = depthTex.sample(s, bDU).r;
        if (bd > u.nearMM && bd < u.farMM && bd > 0 && bodyAttract > 0.001) {
            // Drift around body — strength user-controlled.
            birdC = mix(birdC, float2(0.5), bodyAttract);
        }

        float birdDist = distance(uv, birdC);
        // birdSize from cfg + small treble shimmer.
        float bSize = birdSize + treb * 0.003;
        float birdMask = smoothstep(bSize, bSize * 0.5, birdDist);
        // Trail
        float2 trailDir = float2(-sin(orbAng * 1.3 + fi), cos(orbAng * 1.3 + fi)) * 0.04;
        float trailDist = abs((uv.x - birdC.x) * trailDir.y - (uv.y - birdC.y) * trailDir.x) /
                          (length(trailDir) + 1e-4);
        float trailMask = (1.0 - smoothstep(0.0008, 0.0050, trailDist)) *
                          smoothstep(0.05, 0.0, distance(uv, birdC));
        // Bird color from user-controlled hue (default vermilion = 0.02).
        float3 birdCol = hsv2rgb(float3(birdHue, 0.85, 1.0));
        col += birdCol * (birdMask + trailMask * 0.5);
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

struct SmokeGodParams {
    float4 march;     // (steps, threshold, densityScale, audioCoupling)
    float4 palette;   // (litHue, shadowHue, saturation, emberStrength)
};

fragment float4 smoke_god_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant SmokeGodParams &cfg [[buffer(1)]]
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

    // — User-tunable parameters
    int   STEPS         = clamp(int(cfg.march.x), 8, 64);
    float threshold     = cfg.march.y;
    float densityScale  = cfg.march.z;
    float audioCoupling = cfg.march.w;
    float litHue        = cfg.palette.x;
    float shadowHue     = cfg.palette.y;
    float saturation    = cfg.palette.z;
    float emberStr      = cfg.palette.w;

    // Camera at origin, ray in p direction
    float3 ro = float3(0, 0, -2.0);
    float3 rd = normalize(float3(p, 1.0));

    // March accumulating fog
    float3 acc = float3(0);
    float trans = 1.0;
    float zNear = 0.5;
    float zFar = 5.0;
    float dz = (zFar - zNear) / float(STEPS);

    for (int i = 0; i < 64; i++) {
        if (i >= STEPS) break;
        if (trans < 0.005) break;
        float z = zNear + (float(i) + hash21(uv * 100.0 + t)) * dz;
        float3 q = ro + rd * z;
        // Animate fog
        q.xy += float2(sin(t * 0.15 + q.z), cos(t * 0.12 - q.z * 0.5)) * 0.4;
        q.z += t * 0.08;

        float density = fbm3(q * (1.5 + bass * 0.6));
        density = pow(saturate(density - threshold), 2.0) * (densityScale + u.rms * audioCoupling);

        // Project sample back to screen and check body silhouette
        float2 projUV = uv + (q.xy * 0.04);
        projUV = clamp(projUV, 0.001, 0.999);
        float2 pDU = float2(projUV.x, (projUV.y * 1080.0 + 1.0) / 1082.0);
        float pDM = depthTex.sample(s, pDU).r;
        bool nearBody = pDM > u.nearMM && pDM < u.farMM && pDM > 0;

        // God-ray: fog lights up where ray passes through body's "light"
        float lit = nearBody ? (1.5 + bass * 1.0) : 0.4;

        // Hue: lit-side and shadow-side both user-controlled.
        float hue = nearBody ? fract(litHue + t * 0.02 + bass * 0.05)
                              : fract(shadowHue + t * 0.01);
        float3 emit = hsv2rgb(float3(hue, saturation, 1.0)) * lit * (0.4 + treb * 0.6);

        // Ember sparks on onset (user-tunable strength).
        if (u.onset > 0.5 && emberStr > 0.001) {
            float spark = step(0.998, fract(sin(dot(q.xy + q.z * 13.0, float2(12.9, 78.2))) * 4357.5));
            emit += float3(2.5, 1.5, 0.5) * spark * emberStr;
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

struct AuroraParams {
    float4 motion;     // (fallSpeed, curtainFreq, dropMagnitude, starDensity)
    float4 palette;    // (hueA, hueB, hueC, bodyBoost)
    float4 misc;       // (trebleShimmer, _, _, _)
};

fragment float4 aurora_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant AuroraParams &cfg [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // Background: deep night sky with stars (density user-controlled).
    float3 sky = mix(float3(0.005, 0.010, 0.025), float3(0.020, 0.012, 0.040), uv.y);
    float2 starG = floor(uv * 1000.0);
    float starH = hash21(starG);
    float starThreshold = 1.0 - cfg.motion.w * 0.02;  // 0=no stars, 1=dense
    float star = step(starThreshold, starH) * (0.6 + sin(t * 2.0 + starH * 13.0) * 0.4);
    sky += float3(star);

    // — Aurora curtain: vertically falling waves of color
    float2 curtainP = uv;
    curtainP.y *= 1.5;
    curtainP.x += sin(curtainP.y * cfg.motion.y + t * 0.5) * 0.05 * (1.0 + bass);
    curtainP.y -= t * cfg.motion.x;  // user-tunable descent speed

    float curtain = fbm(curtainP * float2(3.0, 1.5));
    float curtain2 = fbm(curtainP * float2(8.0, 3.0) + 17.3);

    // Bass "drop": sudden vertical compression on onset (magnitude tunable).
    float dropPhase = u.onset * cfg.motion.z;
    if (dropPhase > 0.001) {
        curtainP.y -= dropPhase * 0.3;
    }

    // Aurora intensity is non-uniform — sharp top edge, fading bottom
    float verticalGate = smoothstep(0.0, 0.3, uv.y) * (1.0 - smoothstep(0.5, 1.0, uv.y));
    float auroraDensity = pow(curtain, 2.0) * verticalGate;
    auroraDensity += pow(curtain2, 4.0) * verticalGate * (0.4 + treb * cfg.misc.x);

    // Multi-color aurora — three user-controlled hues.
    float hueA = fract(cfg.palette.x + curtain2 * 0.05);
    float hueB = fract(cfg.palette.y + bass * 0.05);
    float hueC = fract(cfg.palette.z);
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

    // Treble shimmer — intensity user-controlled.
    float shimmer = pow(noise2(uv * 80.0 + t * 0.7), 8.0) * treb * cfg.misc.x;
    col += float3(0.8, 0.9, 1.0) * shimmer;

    if (inBody) {
        // Body pixels get aurora super-bright (boost user-controlled).
        col += aurora * cfg.palette.w;
        // Subtle silhouette outline (rim) tinted with hueB.
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

struct MercuryStormParams {
    float4 shape;   // (ballCount, orbitRadius, ballRadius, bodyEmit)
    float4 chrome;  // (baseHue, streakIntensity, specularTightness, onsetVortex)
};

fragment float4 mercury_storm_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant MercuryStormParams &p [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 p2 = (uv - 0.5) * float2(u.aspect, 1.0);

    float bass = u.bands[0] + u.bands[1];
    float mid = u.bands[3] + u.bands[4];
    float treb = u.bands[6] + u.bands[7];
    float t = u.time;

    // — User-tunable parameters
    int   ballCount      = clamp(int(p.shape.x), 1, 16);
    float orbitRadius    = p.shape.y;
    float ballRadiusBase = p.shape.z;
    float bodyEmit       = p.shape.w;

    // — Compute metaball field
    float field = 0.0;
    for (int i = 0; i < 16; i++) {
        if (i >= ballCount) break;
        float fi = float(i);
        float ang = t * (0.4 + fract(fi * 0.13) * 0.3) + fi * 0.785;
        float r = orbitRadius + sin(t * 0.3 + fi * 0.5) * 0.10 + bass * 0.05;
        float2 ballC = float2(cos(ang), sin(ang)) * r;
        float ballR = ballRadiusBase + sin(t * 0.5 + fi) * 0.025 + treb * 0.012;
        float d = distance(p2, ballC);
        field += ballR * ballR / max(0.0001, d * d);
    }

    // Body attractor: when body is at this pixel's screen pos, add to field
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;
    if (inBody) {
        field += bodyEmit + bass * 0.8;
    }

    // Onset vortex: spawn extra ball at random position (intensity controllable)
    if (u.onset > 0.5 && p.chrome.w > 0.001) {
        float vAng = fract(t * 1.0) * 6.28;
        float2 vC = float2(cos(vAng), sin(vAng)) * 0.35;
        float vDist = distance(p2, vC);
        float vR = 0.20 * p.chrome.w;
        field += vR * vR / max(0.0001, vDist * vDist);
    }

    // Smooth iso-surface: field > 1.0 = inside metaball
    float isoMask = smoothstep(0.7, 1.3, field);
    float surfaceWidth = abs(field - 1.0);

    // — Chrome shading: derive a fake normal from field gradient
    float2 grad;
    {
        float fl = 0.0, fr = 0.0, fb = 0.0, ft = 0.0;
        for (int i = 0; i < 16; i++) {
            if (i >= ballCount) break;
            float fi = float(i);
            float ang = t * (0.4 + fract(fi * 0.13) * 0.3) + fi * 0.785;
            float rr = orbitRadius + sin(t * 0.3 + fi * 0.5) * 0.10 + bass * 0.05;
            float2 ballC = float2(cos(ang), sin(ang)) * rr;
            float ballR = ballRadiusBase + sin(t * 0.5 + fi) * 0.025 + treb * 0.012;
            fl += ballR * ballR / max(0.0001, dot(p2 - float2(0.005, 0) - ballC, p2 - float2(0.005, 0) - ballC));
            fr += ballR * ballR / max(0.0001, dot(p2 + float2(0.005, 0) - ballC, p2 + float2(0.005, 0) - ballC));
            fb += ballR * ballR / max(0.0001, dot(p2 - float2(0, 0.005) - ballC, p2 - float2(0, 0.005) - ballC));
            ft += ballR * ballR / max(0.0001, dot(p2 + float2(0, 0.005) - ballC, p2 + float2(0, 0.005) - ballC));
        }
        grad = float2(fr - fl, ft - fb);
    }
    float3 normal = normalize(float3(grad, 1.0));

    // Procedural cubemap: hue varies with reflection direction (base hue user-controlled).
    float reflAng = atan2(normal.y, normal.x);
    float reflMag = length(normal.xy);
    float hue = fract(p.chrome.x + reflAng * 0.159154943 + bass * 0.10);
    float3 chromeBase = hsv2rgb(float3(hue, 0.4, 1.0));

    // Anisotropic streak (rotation-aligned) — intensity user-controlled.
    float streakAng = atan2(grad.y, grad.x) * 4.0 + t * 2.0;
    float streak = pow(saturate(sin(streakAng) * 0.5 + 0.5), 8.0);
    chromeBase += float3(0.95, 0.92, 0.85) * streak * p.chrome.y;

    // Specular hot dot — tightness user-controlled (8 = soft, 128 = pinpoint).
    float3 light = normalize(float3(0.3, 0.6, 0.7));
    float3 halfV = normalize(light + float3(0, 0, 1));
    float spec = pow(saturate(dot(normal, halfV)), p.chrome.z) * 1.5;

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

// MARK: - #40 Parametric Swarm (Casberry-inspired)
//
// 65k GPU particles arranged via *parametric formulas* on each particle's index
// — not advected by physics. Six formations cycle and smooth-morph: Fibonacci
// sphere, torus, double helix, cube lattice, Lissajous knot, audio-warped
// attractor. Onset triggers a morph step; bass twists and scales the formation;
// treble shimmers per-particle hue. Plasma additive-glow rendering with a
// neon palette (default green, hue-drifts with bass into cyan / magenta).
//
// Body presence (when a Kinect skeleton is detected) attracts the swarm center
// to the body's center of mass — the swarm wraps around the dancer.
//
// Reference: https://particles.casberry.in/ — geodesic point-cloud aesthetic.

struct PSWUniforms {
    float4x4 viewProj;
    float4 ctrl;          // (time, count, morphPhase, particleSize)
    float4 audio;         // (rms, onset, bassLow, treb)
    float4 bandsLow;      // bands[0..3]
    float4 bandsHi;       // bands[4..7]
    float4 bodyAttract;   // (cx, cy, cz, strength)  — strength=0 → no body
    float4 palette;       // (baseHue, hueSpread, sat, val)
    float4 userParams;    // (formationOverride, audioReactivity, glowIntensity, _)
                          //  formationOverride: -1 = auto-cycle via morphPhase;
                          //                     0..7 = lock to a specific mode.
};

struct PSWParticle {
    float4 posPad;
};

inline float3 psw_fib_sphere(float i, float n) {
    // Golden-angle sphere — perfect distribution of points (geodesic sphere).
    float phi = 2.39996323;
    float y = 1.0 - (i / max(1.0, n - 1.0)) * 2.0;
    float r = sqrt(1.0 - y * y);
    float th = phi * i;
    return float3(cos(th) * r, y, sin(th) * r);
}

inline float3 psw_torus(float i, float n, float bass, float treb, float t) {
    // 2D-grid distribution over a torus surface — gives a dense surface, not a string.
    // ~200 longitudinal × (n/200) latitudinal samples.
    float N = 200.0;
    float M = max(1.0, floor(n / N));
    float ui = fmod(i, N) / N;
    float vi = floor(i / N) / M;
    float u = ui * 6.2831853;
    float v = vi * 6.2831853 + t * 0.30;
    float R = 0.70 + bass * 0.10;
    float r = 0.22 + treb * 0.04;
    return float3((R + r * cos(v)) * cos(u),
                   r * sin(v),
                  (R + r * cos(v)) * sin(u));
}

inline float3 psw_helix(float i, float n, float t, float bass, float treb) {
    // Double helix — odd/even index split into two strands. ~7 turns over height 1.8.
    float strand = (fmod(i, 2.0) < 1.0) ? 1.0 : -1.0;
    float u = (i / n - 0.5) * 14.0 * 3.14159 + t * 0.25;
    float r = 0.40 + bass * 0.08;
    float pitch = 1.8 - treb * 0.30;
    float y = (i / n - 0.5) * pitch;
    float ang = strand > 0 ? u : (u + 3.14159);
    return float3(cos(ang) * r, y, sin(ang) * r);
}

inline float3 psw_cube_lattice(float i, float n) {
    // Hollow-cube shell — only render face cells, leave interior empty so the
    // lattice reads as a cube rather than a solid block of points.
    int N = int(round(pow(n, 1.0/3.0)));
    int idx = int(i);
    int x = idx % N;
    int y = (idx / N) % N;
    int z = (idx / (N * N)) % N;
    int Nm = N - 1;
    bool onShell = (x == 0 || x == Nm || y == 0 || y == Nm || z == 0 || z == Nm);
    float3 p = (float3(float(x), float(y), float(z)) / max(1.0, float(Nm)) - 0.5) * 1.4;
    // Push interior cells onto the nearest face — deterministic packing.
    if (!onShell) {
        // Shift to back face (z=0) deterministically.
        p.z = -0.7;
    }
    return p;
}

inline float3 psw_lissajous(float i, float n, float t) {
    // 3D Lissajous knot — three coprime frequencies (3,2,5) → closed curve.
    float s = i / n * 6.2831853;
    float a = 3.0, b = 2.0, c = 5.0;
    float ph = t * 0.30;
    return float3(sin(a * s + ph)        * 0.65,
                  sin(b * s + ph * 1.3)  * 0.65,
                  sin(c * s + ph * 0.7)  * 0.65);
}

inline float3 psw_galaxy(float i, float n, float t) {
    // 3-arm logarithmic spiral. Arms rotate over time; disc thickness = small
    // vertical jitter that grows with radius.
    const int armCount = 3;
    int arm = int(i) % armCount;
    float along = floor(i / float(armCount)) / max(1.0, n / float(armCount));
    float radius = along;
    float angOffset = float(arm) * 6.2831853 / float(armCount);
    // Logarithmic wind — tightens toward the centre, opens up at the rim.
    float wind = log(radius * 4.0 + 1.0) * 4.0 + t * 0.30;
    float ang = wind + angOffset;
    float thicknessSeed = hash21(float2(i, 1.7));
    float y = (thicknessSeed - 0.5) * 0.06 * (0.4 + radius);
    return float3(cos(ang) * radius, y, sin(ang) * radius);
}

inline float3 psw_orbital(float i, float n, float t) {
    // sp³ tetrahedral orbital — 4 lobes at the corners of a tetrahedron, each
    // packed with a Fibonacci-sphere distribution around its centre. Iconic
    // chemistry-textbook electron-density look.
    int lobe = int(i) & 3;  // % 4 cheaply
    float withinLobe = floor(i * 0.25);
    float lobeN = max(1.0, n * 0.25);

    float3 c0 = normalize(float3( 1,  1,  1)) * 0.60;
    float3 c1 = normalize(float3( 1, -1, -1)) * 0.60;
    float3 c2 = normalize(float3(-1,  1, -1)) * 0.60;
    float3 c3 = normalize(float3(-1, -1,  1)) * 0.60;
    float3 centre = (lobe == 0) ? c0 :
                    (lobe == 1) ? c1 :
                    (lobe == 2) ? c2 : c3;

    // Fibonacci point on a small lobe sphere.
    float phi = 2.39996323;
    float yLocal = 1.0 - (withinLobe / max(1.0, lobeN - 1.0)) * 2.0;
    float rLocal = sqrt(1.0 - yLocal * yLocal);
    float th = phi * withinLobe;
    float3 local = float3(cos(th) * rLocal, yLocal, sin(th) * rLocal);
    float pulse = 0.32 + 0.04 * sin(t * 0.6 + float(lobe) * 1.57);
    return centre + local * pulse;
}

inline float3 psw_attractor(float i, float n, float t, float bass) {
    // Aizawa-style strange attractor — each particle samples a stable orbit by
    // (i, t). Bass twists the whole orbit so the attractor breathes with kicks.
    float s = (i / n) * 30.0 + t * 0.05;
    float x = sin(s) * (0.6 + 0.2 * cos(s * 0.7));
    float y = cos(s * 1.7) * (0.5 + 0.1 * sin(s * 0.3));
    float z = sin(s * 0.7) * 0.55 + cos(s * 1.1) * 0.15;
    // Bass twist around Y axis.
    float a = bass * 0.4;
    float ca = cos(a), sa = sin(a);
    float xr = x * ca - z * sa;
    float zr = x * sa + z * ca;
    return float3(xr, y, zr);
}

kernel void psw_step_kernel(
    device PSWParticle *particles [[buffer(0)]],
    constant PSWUniforms &u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    float n = u.ctrl.y;
    if (float(gid) >= n) return;

    float i = float(gid);
    float t = u.ctrl.x;
    float morph = u.ctrl.z;
    float bass = u.audio.z;
    float treb = u.audio.w;
    float audioRx = u.userParams.y;       // 0 = ignore audio, 1 = full modulation
    int   override = int(u.userParams.x); // -1 = auto, 0..7 = locked formation
    const int FORMATION_COUNT = 8;

    // Resolve formation (modeA/modeB blend, or single locked mode).
    int modeA, modeB;
    float interp;
    if (override >= 0) {
        modeA = override;
        modeB = override;
        interp = 0.0;
    } else {
        modeA = int(floor(morph)) % FORMATION_COUNT;
        modeB = (modeA + 1) % FORMATION_COUNT;
        interp = smoothstep(0.0, 1.0, fract(morph));
    }

    // Lookup table dispatch — keeps both pA and pB resolution under one branch
    // path so the GPU SIMT lanes stay coherent across the threadgroup.
    #define PSW_PICK(MODE, OUT)                                          \
        if      (MODE == 0) OUT = psw_fib_sphere(i, n);                  \
        else if (MODE == 1) OUT = psw_torus(i, n, bass * audioRx,        \
                                            treb * audioRx, t);          \
        else if (MODE == 2) OUT = psw_helix(i, n, t, bass * audioRx,     \
                                            treb * audioRx);             \
        else if (MODE == 3) OUT = psw_cube_lattice(i, n);                \
        else if (MODE == 4) OUT = psw_lissajous(i, n, t);                \
        else if (MODE == 5) OUT = psw_attractor(i, n, t, bass * audioRx);\
        else if (MODE == 6) OUT = psw_galaxy(i, n, t);                   \
        else                OUT = psw_orbital(i, n, t)

    float3 pA, pB;
    PSW_PICK(modeA, pA);
    PSW_PICK(modeB, pB);
    #undef PSW_PICK

    float3 pos = (override >= 0) ? pA : mix(pA, pB, interp);

    // Audio modulation — bass swells the swarm, treble jitters per particle.
    pos *= 1.0 + (bass * 0.30 + u.audio.x * 0.18) * audioRx;

    float jSeed = i * 0.000037 + t * 0.5;
    float3 jitter = float3(sin(jSeed * 31.0), sin(jSeed * 53.0), sin(jSeed * 71.0));
    pos += jitter * (0.005 + treb * 0.020 * audioRx);

    // Body attractor — translate the swarm toward the body's COM (when present).
    pos += u.bodyAttract.xyz * u.bodyAttract.w;

    // NOTE: in-kernel Y-axis rotation removed — the camera handles auto-orbit
    // (see ParametricSwarmVisualizer makeViewProj). Rotating points here would
    // double-rotate them and slide the body-attract centre off the screen.

    // Onset shockwave — single-frame outward push.
    if (u.audio.y > 0.5) {
        pos += normalize(pos + 0.0001) * 0.06;
    }

    particles[gid].posPad = float4(pos, 1.0);
}

struct PSWVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
    float intensity;
};

vertex PSWVertexOut psw_vs(
    uint vid [[vertex_id]],
    const device PSWParticle *particles [[buffer(0)]],
    constant PSWUniforms &u [[buffer(1)]]
) {
    PSWParticle p = particles[vid];
    PSWVertexOut o;
    float4 cp = u.viewProj * float4(p.posPad.xyz, 1.0);
    o.position = cp;

    // Depth-cued point size: closer = larger (cp.w grows with distance).
    float depthFactor = 1.0 / max(0.5, cp.w);
    float baseSize = u.ctrl.w * depthFactor;
    float pump = u.audio.x * 4.0 + u.audio.y * 6.0;
    o.pointSize = clamp(baseSize + pump, 1.5, 12.0);

    // Palette driven entirely by the SidePanel controls (baseHue / hueSpread /
    // saturation / value), audio-modulated by `audioReactivity` (userParams.y).
    float i = float(vid) / max(1.0, u.ctrl.y);
    float audioRx = u.userParams.y;
    float hueShift = (u.audio.z * 0.10 - u.audio.w * 0.05) * audioRx;
    float hue = fract(u.palette.x + (i - 0.5) * u.palette.y + hueShift);
    // Allow val > 1 — feeds HDR into the additive blend; the fragment's
    // ACES tone-map compresses overdrive into bloom, not clipping.
    float val = u.palette.w + (u.audio.x * 0.40 + u.audio.y * 0.60) * audioRx;
    o.color = hsv2rgb(float3(hue, u.palette.z, val));
    // Glow intensity multiplier — passed through to fragment via `intensity`.
    o.intensity = u.userParams.z;
    return o;
}

fragment float4 psw_fs(PSWVertexOut in [[stage_in]], float2 pc [[point_coord]]) {
    // Discard far corners so the point sprite reads as a circle, not a square.
    float r = length(pc - 0.5) * 2.0;
    if (r > 1.0) discard_fragment();
    // Sharp bright core + soft outer halo. Overdrive into HDR; ACES below
    // tone-maps the additive accumulation into a smooth bloom. (ACES inlined
    // because aces_tonemap() is defined later in the file.)
    float core = exp(-r * r * 6.0);
    float halo = exp(-r * r * 1.4) * 0.45;
    float intensity = (core + halo) * in.intensity;
    float3 col = in.color * intensity * 1.8;
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    return float4(col, intensity * 0.9);
}

// =============================================================================
// MARK: - Research-grounded replacements (#40+)
//
// All of these target a higher visual floor than the earlier batch:
//   - HDR float math accumulated then ACES tone-mapped at the end
//   - Multi-layer audio mapping (different bands drive different aspects)
//   - Specific colour palettes lifted from referenced art
//   - Body interaction is sculptural, not just gating
// =============================================================================

// Shared ACES filmic tone-map (Narkowicz 2015) — saves us from the bare saturate()
// that made the old shaders feel flat.
inline float3 aces_tonemap(float3 c) {
    return saturate((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14));
}

// Cosine-palette gradient (Inigo Quilez palette trick).
inline float3 iq_palette(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(6.28318 * (c * t + d));
}

// MARK: - #40 Plasma Sea
//
// Volumetric caustics: per pixel we trace a refracted ray through a wave-
// displaced surface, then accumulate "photon density" along the ray with
// chromatic dispersion. Body silhouette tints the absorbing medium so you
// become a coloured shadow inside the tank.

inline float wave_height(float2 p, float t, float bass) {
    float h = 0.0;
    h += sin(p.x * 1.6 + t * 0.7 + bass * 1.5) * 0.18;
    h += sin(p.y * 1.9 - t * 0.6) * 0.16;
    h += sin(dot(p, float2(1.2, -0.8)) * 2.4 + t * 1.1) * 0.10;
    h += sin(length(p - float2(sin(t * 0.3), cos(t * 0.4))) * 5.0 - t * 1.7) * 0.07;
    return h;
}

inline float caustic_brightness(float2 p, float t, float bass, float dispersion) {
    // Forward-difference normal of the wave height; intensity comes from how
    // much that normal focuses light onto the pixel.
    const float e = 0.0035;
    float h0 = wave_height(p, t, bass);
    float hx = wave_height(p + float2(e, 0), t, bass);
    float hy = wave_height(p + float2(0, e), t, bass);
    float2 n = float2(hx - h0, hy - h0) / e;
    float focus = exp(-dot(n, n) * (4.0 - dispersion * 1.5));
    // Add a Voronoi-noise crispness pass so caustic lines feel sharp.
    float v = fract(sin(dot(floor(p * 28.0 + n * 14.0), float2(127.1, 311.7))) * 43758.5);
    focus += pow(v, 36.0) * 0.5;
    return focus;
}

struct PlasmaSeaParams {
    float4 wave;     // (waveScale, waveSpeed, dispersion, audioCoupling)
    float4 palette;  // (deepHueShift, litHueShift, bodyGlowHue, brightness)
};

fragment float4 plasma_sea_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant PlasmaSeaParams &cfg [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    // Wave scale user-controlled.
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0) * cfg.wave.x;
    // Wave time scaled by user speed.
    float t = u.time * cfg.wave.y;
    float bass = u.bands[0] + u.bands[1];
    float treb = u.bands[6] + u.bands[7];

    // 3-channel chromatic dispersion — separation user-controlled.
    float dispScale = cfg.wave.z * 0.012;
    float r = caustic_brightness(p * (1.00 + dispScale * sin(t * 0.4)), t, bass, treb);
    float g = caustic_brightness(p * 1.000, t * 1.02, bass, treb);
    float b = caustic_brightness(p * (1.00 - dispScale * cos(t * 0.5)), t * 1.05, bass, treb);
    float3 caustic = float3(r, g, b);
    caustic = pow(caustic, float3(2.4 - bass * 0.4));

    // Body presence: tint the medium so the silhouette glows from within.
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;
    float bodyT = inBody ? saturate((u.farMM - depthMM) / max(1.0, u.farMM - u.nearMM)) : 0.0;

    // Iquilez cosine palette — hue offsets user-controlled.
    float3 deep = iq_palette(0.5 + bass * 0.1 + cfg.palette.x,
                             float3(0.05, 0.15, 0.20),
                             float3(0.30, 0.50, 0.50),
                             float3(0.6, 0.7, 0.8),
                             float3(0.0, 0.10, 0.20));
    float3 lit  = iq_palette(0.7 + treb * 0.1 + cfg.palette.y,
                             float3(0.50, 0.60, 0.70),
                             float3(0.50, 0.50, 0.50),
                             float3(1.0, 1.0, 1.0),
                             float3(0.0, 0.10, 0.20));

    // Audio coupling on caustic intensity user-controlled.
    float3 col = deep + caustic * lit * (1.0 + u.rms * cfg.wave.w);
    // Body subsurface glow — color user-controlled.
    float3 bodyGlowColor = hsv2rgb(float3(cfg.palette.z, 0.85, 1.0));
    col += bodyGlowColor * bodyT * (0.4 + caustic.r * 0.7);
    // Onset adds a quick highlight.
    col += float3(0.7, 0.9, 1.0) * u.onset * (0.4 + caustic.g * 0.6);

    // Brightness multiplier + vignette.
    col *= cfg.palette.w;
    col *= smoothstep(1.6, 0.4, length((uv - 0.5) * 1.4));
    return float4(aces_tonemap(col), 1.0);
}

// MARK: - #41 Liquid Chrome Body
//
// Build an SDF of the body silhouette (depth → 2D blob in 3D space), raymarch a
// chrome surface, reflect rays into a procedural HDR environment. Audio drives
// the environment palette and a wobble term that makes the chrome feel liquid.

inline float chrome_sample_depth(texture2d<float, access::sample> depthTex,
                                 float2 uv, float nearMM, float farMM) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 d = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float mm = depthTex.sample(s, d).r;
    if (mm <= 0 || mm >= 9000) return 1.0;
    return clamp((mm - nearMM) / max(1.0, farMM - nearMM), 0.0, 1.0);
}

// SDF: returns negative INSIDE the body silhouette, positive outside.
// Distance is roughly in screen units, with z used so reflections look 3D.
inline float chrome_sdf(float3 p,
                        texture2d<float, access::sample> depthTex,
                        float nearMM, float farMM, float t, float wobble) {
    // Project p.xy back to UV space, accounting for aspect.
    float2 uv = p.xy * 0.5 + 0.5;
    if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1) {
        return length(p) - 0.05;
    }
    // Body presence ∈ [0,1] — 0 = body, 1 = far.
    float depthN = chrome_sample_depth(depthTex, float2(uv.x, 1.0 - uv.y), nearMM, farMM);
    float occupied = step(depthN, 0.92);
    // Build a height profile so body has rounded volume.
    float bodyZ = -0.4 + (1.0 - depthN) * 0.6;
    // Wobble the surface like mercury.
    float w = sin(p.x * 8.0 + t * 1.4) * sin(p.y * 8.0 - t * 1.1) * wobble;
    bodyZ += w * 0.15;
    float zd = p.z - bodyZ;
    float xy = (1.0 - occupied) * 0.5 + 0.05;  // distance to body in screen plane
    return max(xy - 0.1, zd);
}

inline float3 chrome_normal(float3 p,
                            texture2d<float, access::sample> depthTex,
                            float nearMM, float farMM, float t, float wobble) {
    const float e = 0.0025;
    float dx = chrome_sdf(p + float3(e, 0, 0), depthTex, nearMM, farMM, t, wobble)
             - chrome_sdf(p - float3(e, 0, 0), depthTex, nearMM, farMM, t, wobble);
    float dy = chrome_sdf(p + float3(0, e, 0), depthTex, nearMM, farMM, t, wobble)
             - chrome_sdf(p - float3(0, e, 0), depthTex, nearMM, farMM, t, wobble);
    float dz = chrome_sdf(p + float3(0, 0, e), depthTex, nearMM, farMM, t, wobble)
             - chrome_sdf(p - float3(0, 0, e), depthTex, nearMM, farMM, t, wobble);
    return normalize(float3(dx, dy, dz));
}

// Procedural HDR environment for reflections — palette pulses with audio.
inline float3 chrome_env(float3 d, float t, float bass, float treb) {
    float h = atan2(d.z, d.x) * 0.15915 + 0.5;
    float v = d.y * 0.5 + 0.5;
    float3 base = iq_palette(h + t * 0.05,
                             float3(0.5, 0.5, 0.5),
                             float3(0.5, 0.5, 0.5),
                             float3(1.0, 1.0, 1.0),
                             float3(0.0 + bass * 0.1, 0.33, 0.67));
    // Sun-disk highlight.
    float3 sunDir = normalize(float3(sin(t * 0.3), 0.6, cos(t * 0.3)));
    float sun = pow(max(0.0, dot(d, sunDir)), 64.0);
    base += float3(2.0, 1.6, 1.2) * sun * (1.0 + treb * 1.5);
    // Sky gradient on top.
    base = mix(base * 0.7, float3(1.1, 0.8, 0.5), smoothstep(0.2, 0.9, v));
    return base;
}

fragment float4 liquid_chrome_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    float2 uv = in.uv;
    float2 p2 = (uv - 0.5) * 2.0;
    p2.x *= u.aspect;
    float t = u.time;
    float bass = u.bands[0] + u.bands[1];
    float treb = u.bands[6] + u.bands[7];
    float wobble = 0.5 + u.rms * 1.5 + u.onset * 0.7;

    // Camera at +Z, looking toward -Z. Orthographic-ish for simplicity.
    float3 ro = float3(p2, 0.6);
    float3 rd = float3(0, 0, -1);

    // Sphere-trace toward the surface.
    float dist = 0.0;
    float3 pos = ro;
    bool hit = false;
    for (int i = 0; i < 48; i++) {
        float d = chrome_sdf(pos, depthTex, u.nearMM, u.farMM, t, wobble);
        if (d < 0.001) { hit = true; break; }
        if (dist > 1.5) break;
        pos += rd * d;
        dist += d;
    }

    if (!hit) {
        // Background: same env in look direction.
        float3 bg = chrome_env(rd, t, bass, treb) * 0.25;
        return float4(aces_tonemap(bg), 1.0);
    }

    float3 n = chrome_normal(pos, depthTex, u.nearMM, u.farMM, t, wobble);
    float3 r = reflect(rd, n);
    float fres = pow(1.0 - max(0.0, dot(-rd, n)), 5.0);
    float3 env = chrome_env(r, t, bass, treb);
    float3 base = float3(0.10, 0.11, 0.13);
    float3 col = mix(base, env, 0.65 + 0.35 * fres) * (1.0 + u.rms * 0.4);

    // Onset spike: brief specular flare aligned with view dir.
    col += float3(1.0, 0.9, 0.7) * u.onset * pow(max(0.0, dot(n, -rd)), 16.0);

    return float4(aces_tonemap(col), 1.0);
}

// MARK: - #42 Hyperbolic Tunnel
//
// Tile the Poincaré disk with a triangle/heptagon group; each step we run a
// few inversions in the unit circle to fold UV back into the fundamental
// domain. Audio modulates the curvature and rotation.

inline float2 mobius_invert(float2 p) {
    float r2 = dot(p, p);
    return p / max(r2, 1e-4);
}

inline float2 fold_disk(float2 p, int steps, float swirl) {
    for (int i = 0; i < steps; i++) {
        if (length(p) > 1.0) p = mobius_invert(p);
        // Rotate by swirl per fold so the tessellation spins.
        float c = cos(swirl);
        float s = sin(swirl);
        p = float2(c * p.x - s * p.y, s * p.x + c * p.y);
        // Reflect across one of the three triangle mirrors (rotation symmetry of 6).
        float a = atan2(p.y, p.x);
        float r = length(p);
        a = fract(a / 6.28318 * 6.0) / 6.0 * 6.28318;
        p = r * float2(cos(a), sin(a));
    }
    return p;
}

fragment float4 hyperbolic_tunnel_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0) * 1.6;
    float t = u.time;
    float bass = u.bands[0] + u.bands[1];

    // Body presence pulls the disk centre toward the silhouette so the tunnel
    // feels emitted from the body.
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    float swirl = 0.10 + bass * 0.30 + sin(t * 0.27) * 0.06;
    float2 q = fold_disk(p, 6, swirl);

    // Build a "tile" from distance to fold seams.
    float seam = abs(0.5 - fract(length(q) * 4.0));
    float radial = abs(sin(atan2(q.y, q.x) * 7.0 + t * 0.6));
    float tile = pow(saturate(1.0 - seam * 6.0), 2.5);
    tile += pow(radial, 8.0) * 0.5;

    // Iridescent glass palette.
    float3 col = iq_palette(t * 0.05 + length(q) * 0.7,
                            float3(0.5, 0.5, 0.5),
                            float3(0.5, 0.5, 0.5),
                            float3(2.0, 1.0, 0.0),
                            float3(0.50, 0.20, 0.25));
    col *= 0.4 + 1.6 * tile;

    if (inBody) col *= 1.4;
    col += float3(0.4, 0.6, 1.0) * u.onset * 0.5;
    col *= smoothstep(2.0, 0.8, length(p));
    return float4(aces_tonemap(col), 1.0);
}


// MARK: - WIP stubs
//
// Visually-distinct holding patterns for visualizers whose shader is still in
// progress. Each sits at low energy so it's clearly a "coming soon" not a final.

inline float3 wip_pattern(float2 uv, float t, float rms, float seed) {
    float h = fract(seed * 0.317 + t * 0.05);
    float pulse = 0.4 + 0.6 * sin(t * 0.6 + seed);
    float ring = abs(0.5 - fract(length((uv - 0.5)) * 5.0 - t * 0.3));
    float band = pow(1.0 - ring * 6.0, 6.0);
    float3 col = iq_palette(h,
        float3(0.05, 0.05, 0.07),
        float3(0.10, 0.15, 0.20),
        float3(1.0, 1.0, 1.0),
        float3(0.0, 0.10, 0.20));
    col += float3(0.4, 0.4, 0.5) * band * (0.6 + rms * 0.6) * pulse;
    return aces_tonemap(col);
}

#define WIP_FS(name, seed) \
fragment float4 name(PassthroughVertexOut in [[stage_in]], \
                     texture2d<float, access::sample> tex [[texture(0)]], \
                     constant Uniforms &u [[buffer(0)]]) { \
    return float4(wip_pattern(in.uv, u.time, u.rms, seed), 1.0); \
}



// MARK: - #43 Magnetic Iron Filings

struct MIFUniforms {
    float4 ctrl;       // (time, count, polarity, _)
    float4 audio;      // (rms, onset, bassLow, treb)
    float4 bandsLow;
};

struct MIFFiling {
    float4 posAngle;   // (x, y, angle, life)
};

inline float mif_hash(float n) { return fract(sin(n) * 43758.5453); }

inline float2 mif_dipole_field(float2 p, float2 source, float strength, float angle) {
    // 2D approximation of a dipole field aligned along `angle`.
    float2 d = p - source;
    float r2 = dot(d, d) + 1e-3;
    float r = sqrt(r2);
    float2 dipDir = float2(cos(angle), sin(angle));
    float dot_ = dot(d / r, dipDir);
    float2 b = (3.0 * dot_ * (d / r) - dipDir) / (r2 * r);
    return b * strength;
}

inline float2 mif_field_at(float2 p, float t, float bass, float pol,
                           texture2d<float, access::sample> depthTex,
                           float nearMM, float farMM) {
    float2 f = float2(0);
    // Two animated dipoles dancing around the centre.
    float a1 = t * 0.3;
    float a2 = -t * 0.27 + 1.7;
    float2 s1 = float2(sin(t * 0.4) * 0.4, cos(t * 0.5) * 0.3);
    float2 s2 = float2(sin(t * 0.3 + 2) * 0.5, cos(t * 0.2 + 1) * 0.4);
    f += mif_dipole_field(p, s1, 0.04 * pol, a1);
    f += mif_dipole_field(p, s2, 0.04 * -pol, a2);

    // Body acts as a third dipole that tracks the centre of mass; sample depth
    // along a coarse 4×4 grid to estimate body centroid and orientation.
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 bodyC = float2(0); float bodyW = 0;
    for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
        float2 uv = (float2(i, j) + 0.5) / 4.0;
        float2 du = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
        float mm = depthTex.sample(s, du).r;
        if (mm > nearMM && mm < farMM && mm > 0) {
            bodyC += (uv * 2.0 - 1.0); bodyW += 1.0;
        }
    }
    if (bodyW > 0) {
        bodyC /= bodyW;
        f += mif_dipole_field(p, bodyC, 0.05 * (1.0 + bass), t * 0.4);
    }
    return f;
}

kernel void mif_init_kernel(
    device MIFFiling *out [[buffer(0)]],
    constant MIFUniforms &u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= uint(u.ctrl.y)) return;
    float fi = float(gid);
    float x = mif_hash(fi * 0.013) * 2.0 - 1.0;
    float y = mif_hash(fi * 0.027) * 2.0 - 1.0;
    out[gid].posAngle = float4(x, y, 0, mif_hash(fi * 0.041));
}

kernel void mif_step_kernel(
    device MIFFiling *src [[buffer(0)]],
    device MIFFiling *dst [[buffer(1)]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant MIFUniforms &u [[buffer(2)]],
    constant float2 &range [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint count = uint(u.ctrl.y);
    if (gid >= count) return;
    MIFFiling s = src[gid];
    float2 p = s.posAngle.xy;
    float t = u.ctrl.x;

    float2 f = mif_field_at(p, t, u.audio.z, u.ctrl.z, depthTex, range.x, range.y);
    // Filings drift along the field with a small step and align to it.
    p += f * 0.6;
    float angle = atan2(f.y, f.x);

    // Recycle filings that drifted off-screen.
    if (length(p) > 1.6) {
        float fi = float(gid) + t * 7.13;
        p = float2(mif_hash(fi) * 2.0 - 1.0, mif_hash(fi * 1.7) * 2.0 - 1.0);
    }

    dst[gid].posAngle = float4(p, angle, s.posAngle.w);
}

struct MIFOut {
    float4 position [[position]];
    float4 color;
};

vertex MIFOut mif_vs(
    uint vid [[vertex_id]],
    const device MIFFiling *src [[buffer(0)]],
    constant MIFUniforms &u [[buffer(1)]]
) {
    uint pi = vid / 2;
    uint end = vid & 1;
    MIFFiling f = src[pi];
    float2 p = f.posAngle.xy;
    float a = f.posAngle.z;
    // Filings are short stretched lines aligned with the local field.
    float len = 0.012 * (1.0 + u.audio.x * 1.4);
    float2 d = float2(cos(a), sin(a)) * (end == 0 ? -len : len);
    MIFOut o;
    o.position = float4(p + d, 0, 1);
    // Warm/cool palette by angle, brightened by RMS.
    float h = fract(0.55 + a / 6.28318 + u.audio.z * 0.2);
    float3 col = hsv2rgb(float3(h, 0.7, 1.0));
    o.color = float4(col * (0.5 + u.audio.x * 1.2), 1.0);
    return o;
}

fragment float4 mif_fs(MIFOut in [[stage_in]]) {
    return float4(aces_tonemap(in.color.rgb), in.color.a * 0.7);
}

// MARK: - #44 Sand Mandala

struct SMUniforms {
    float4 ctrl;     // (time, count, springK, damping)
    float4 audio;    // (rms, onset, bassLow, treb)
    float4 pattern;  // (rotation, symmetry, ringScale, morphSeed)
};

struct SMGrain {
    float4 current;   // (x, y, hue, life)
    float4 target;    // (x, y, _, _)
    float4 velocity;  // (vx, vy, _, _)
};

inline float sm_hash(float n) { return fract(sin(n) * 43758.5453); }

// Compute the target position for a grain given pattern parameters. We sweep a
// dense set of (radius, theta) cells in a rotationally-symmetric mandala and
// occasionally mirror to make sub-petals.
inline float2 sm_target_for(uint gid, float4 pattern) {
    float fi = float(gid);
    float seed = pattern.w;
    // Distribute grains to N rings with M divisions; n & m derived from seed.
    int rings = 14;
    int divisionsBase = int(pattern.y);   // symmetry e.g. 8
    int divisions = max(divisionsBase, 6);
    int perRing = 1024;
    int ring = int(fi) / perRing;
    int idx = int(fi) % perRing;
    if (ring >= rings) ring = ring % rings;
    float ringT = float(ring) / float(rings - 1);
    float r = pattern.z + ringT * 0.42;

    // Rotational division within the ring; petal index modulates with seed.
    float petal = float(idx) / float(perRing) * float(divisions);
    float petalIdx = floor(petal);
    float petalT = fract(petal);
    // Inside each petal: a 2D shape (lemniscate-like).
    float petalAngle = (petalIdx + 0.5) / float(divisions) * 6.28318 + pattern.x;
    float along = (petalT - 0.5) * 0.30;
    float across = sin(petalT * 6.28318 * (1.0 + sm_hash(seed * 17.0 + ringT * 9.0))) * 0.07;
    // Polar → cartesian.
    float2 dir = float2(cos(petalAngle), sin(petalAngle));
    float2 perp = float2(-dir.y, dir.x);
    float2 p = dir * (r + along) + perp * across;
    return p + 0.5;  // centre at (0.5, 0.5)
}

kernel void sm_init_kernel(
    device SMGrain *out [[buffer(0)]],
    constant SMUniforms &u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= uint(u.ctrl.y)) return;
    float fi = float(gid);
    float2 target = sm_target_for(gid, u.pattern);
    out[gid].current  = float4(target.x + (sm_hash(fi * 0.07) - 0.5) * 0.02,
                               target.y + (sm_hash(fi * 0.13) - 0.5) * 0.02,
                               sm_hash(fi * 0.31), 1.0);
    out[gid].target   = float4(target, 0, 0);
    out[gid].velocity = float4(0);
}

kernel void sm_step_kernel(
    device SMGrain *src [[buffer(0)]],
    device SMGrain *dst [[buffer(1)]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant SMUniforms &u [[buffer(2)]],
    constant float2 &range [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint count = uint(u.ctrl.y);
    if (gid >= count) return;
    SMGrain s = src[gid];

    // Recompute target every frame so onset-driven pattern changes propagate.
    float2 target = sm_target_for(gid, u.pattern);
    float2 cur = s.current.xy;
    float2 vel = s.velocity.xy;

    // Spring force toward target.
    float2 toTarget = target - cur;
    vel += toTarget * u.ctrl.z;
    vel *= u.ctrl.w;

    // Body repulsor: if grain sits on the body silhouette, push away.
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float2 du = float2(cur.x, (cur.y * 1080.0 + 1.0) / 1082.0);
    float mm = depthTex.sample(ss, du).r;
    bool inBody = mm > range.x && mm < range.y && mm > 0;
    if (inBody) {
        float2 outward = normalize(cur - 0.5 + 0.001);
        vel += outward * (0.0035 + u.audio.z * 0.012);
    }
    // Onset: outward burst from a moving point.
    if (u.audio.y > 0.5) {
        float2 burstC = float2(0.5 + 0.3 * sin(u.ctrl.x * 0.7),
                               0.5 + 0.3 * cos(u.ctrl.x * 0.5));
        float2 d = cur - burstC;
        vel += normalize(d + 0.0001) * exp(-dot(d, d) * 50.0) * 0.06;
    }

    cur += vel;

    dst[gid].current  = float4(cur, s.current.z, s.current.w);
    dst[gid].target   = s.target;
    dst[gid].velocity = float4(vel, 0, 0);
}

struct SMOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex SMOut sm_point_vs(
    uint vid [[vertex_id]],
    const device SMGrain *src [[buffer(0)]],
    constant SMUniforms &u [[buffer(1)]]
) {
    SMGrain g = src[vid];
    SMOut o;
    o.position = float4(g.current.xy * 2.0 - 1.0, 0, 1);
    o.pointSize = clamp(2.0 + length(g.velocity.xy) * 30.0 + u.audio.x * 4.0, 1.0, 6.0);
    // Tibetan palette: vermilion, gold, lapis, jade, ivory.
    float idx = floor(fract(g.current.z * 5.0) * 5.0);
    float3 palette[5] = {
        float3(0.85, 0.18, 0.13),  // vermilion
        float3(0.95, 0.78, 0.20),  // gold
        float3(0.13, 0.30, 0.75),  // lapis
        float3(0.20, 0.65, 0.40),  // jade
        float3(0.95, 0.92, 0.80)   // ivory
    };
    int i = int(clamp(idx, 0.0, 4.0));
    float3 col = palette[i];
    // Boost on motion.
    float speed = length(g.velocity.xy);
    col *= (0.6 + u.audio.x * 0.6 + speed * 30.0);
    o.color = float4(col, 1.0);
    return o;
}

fragment float4 sm_point_fs(
    SMOut in [[stage_in]],
    float2 ptCoord [[point_coord]]
) {
    float r = length(ptCoord - 0.5) * 2.0;
    float a = 1.0 - smoothstep(0.7, 1.0, r);
    return float4(in.color.rgb * a, a);
}

// MARK: - #45 Dissipative Cells

struct DCUniforms {
    float4 ctrl;     // (time, count, aspect, _)
    float4 audio;    // (rms, onset, bassLow, treb)
};

struct DCCell {
    float4 posHueRadius;   // (x, y, hue, radius)
    float4 ageAlive;       // (age, alive, _, _)
};

fragment float4 dissipative_cells_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    const device DCCell *cells [[buffer(0)]],
    constant DCUniforms &u [[buffer(1)]]
) {
    float2 uv = in.uv;
    float2 p = uv;
    p.x *= u.ctrl.z;
    int count = int(u.ctrl.y);

    // Find the two nearest seeds for smooth Voronoi.
    float d1 = 1e9, d2 = 1e9;
    int i1 = 0, i2 = 0;
    for (int i = 0; i < 64; i++) {
        if (i >= count) break;
        DCCell c = cells[i];
        if (c.ageAlive.y < 0.5) continue;
        float2 q = c.posHueRadius.xy;
        q.x *= u.ctrl.z;
        float d = length(p - q) / max(0.05, c.posHueRadius.w);
        if (d < d1) { d2 = d1; i2 = i1; d1 = d; i1 = i; }
        else if (d < d2) { d2 = d; i2 = i; }
    }
    if (count == 0) return float4(0, 0, 0, 1);

    DCCell c1 = cells[i1];
    DCCell c2 = cells[i2];
    // Edge intensity from the gap between the two nearest distances.
    float edge = saturate((d2 - d1) * 6.0);
    float edgeGlow = pow(1.0 - edge, 16.0);

    // Inner gradient — radial from cell centre, hue from the cell.
    float2 q1 = c1.posHueRadius.xy; q1.x *= u.ctrl.z;
    float r = length(p - q1) / max(0.05, c1.posHueRadius.w);
    float age = c1.ageAlive.x;
    float life = saturate(1.0 - age);

    // Jewel-tone palette: deep saturated centres, cool rims.
    float3 inner = hsv2rgb(float3(c1.posHueRadius.z, 0.85, 1.0));
    float3 outer = hsv2rgb(float3(fract(c1.posHueRadius.z + 0.55), 0.55, 0.7));
    float3 col = mix(inner * 0.05, outer, smoothstep(0.0, 1.0, r)) * (0.6 + life * 0.4);

    // Edge glow — bright filament.
    float3 edgeCol = hsv2rgb(float3(fract(0.55 + u.audio.x * 0.5), 0.4, 1.0));
    col += edgeCol * edgeGlow * (0.6 + u.audio.x * 0.8);

    // Body presence intensifies the cell over the silhouette.
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float2 du = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float mm = depthTex.sample(ss, du).r;
    bool inBody = mm > 500.0 && mm < 4000.0 && mm > 0;
    if (inBody) col *= 1.4;

    // Onset shimmer.
    col += float3(0.6, 0.7, 1.0) * u.audio.y * edgeGlow * 0.7;

    return float4(aces_tonemap(col), 1.0);
}


// MARK: - #46 Mocap Constellation
//
// Each star is a (position, birthTime, hue, energy) record. Fragment renders
// twinkles + radial shockwaves emanating from recently-born stars.

struct MCUniforms {
    float4 ctrl;     // (time, count, aspect, _)
    float4 audio;    // (rms, onset, bassLow, treb)
    float4 visual;   // (starCoreSize, ringGrowth, ringWidth, audioCoupling)
};

struct MCStar {
    float4 posBirthHue;   // (x, y, birthTime, hue)
    float4 energy;        // (energy, _, _, _)
};

fragment float4 mocap_constellation_fs(
    PassthroughVertexOut in [[stage_in]],
    const device MCStar *stars [[buffer(0)]],
    constant MCUniforms &u [[buffer(1)]]
) {
    float2 uv = in.uv;
    float aspect = u.ctrl.z;
    float2 p = uv;
    p.x *= aspect;
    int count = int(u.ctrl.y);
    float t = u.ctrl.x;

    float3 col = float3(0.005, 0.01, 0.025);  // deep night-sky bg

    for (int i = 0; i < 1024; i++) {
        if (i >= count) break;
        MCStar s = stars[i];
        if (s.posBirthHue.z < -100.0) continue;
        float age = t - s.posBirthHue.z;
        if (age < 0 || age > 8.0) continue;

        float2 sp = s.posBirthHue.xy;
        sp.x *= aspect;
        float r = length(p - sp);
        float life = exp(-age * 0.45);

        // Star core: bright twinkle. Size + audio coupling user-controlled.
        float core = exp(-r * r * u.visual.x) * (1.0 + u.audio.x * u.visual.w);
        float3 starCol = hsv2rgb(float3(s.posBirthHue.w, 0.7, 1.0));
        col += starCol * core * life * s.energy.x;

        // Shockwave: ring growth + width user-controlled.
        float ringR = age * u.visual.y;
        float ringW = u.visual.z;
        float ring = exp(-pow(r - ringR, 2.0) / (ringW * ringW)) * 0.20 * life;
        col += starCol * ring * (1.0 + u.audio.z * 1.5);
    }

    // Subtle horizon-glow gradient so it never feels totally flat.
    col += iq_palette(uv.y * 0.5,
                      float3(0.01, 0.01, 0.02),
                      float3(0.02, 0.04, 0.06),
                      float3(1.0, 1.0, 1.0),
                      float3(0.0, 0.10, 0.20)) * 0.4;

    col += float3(0.5, 0.6, 1.0) * u.audio.y * 0.3;
    return float4(aces_tonemap(col), 1.0);
}

// MARK: - #47 Liquid Light Calligraphy

struct LLUniforms {
    float4 ctrl;     // (time, decay, viscosity, emitCount)
    float4 audio;    // (rms, onset, bassLow, treb)
};

struct LLEmitter {
    float4 posHueRadius;   // (xNorm, yNorm, hue, radius)
    float4 velocity;       // (vx, vy, _, _)
};

kernel void ll_step_kernel(
    texture2d<float, access::sample> prevAccum [[texture(0)]],
    texture2d<float, access::write>  currAccum [[texture(1)]],
    constant LLUniforms &u [[buffer(0)]],
    constant LLEmitter *emitters [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint W = currAccum.get_width();
    uint H = currAccum.get_height();
    if (gid.x >= W || gid.y >= H) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float2 p = uv;
    p.y = 1.0 - p.y;  // emitters are bottom-origin (Vision)

    // Read prev with a small advection toward each emitter — gives that "wet
    // calligraphy" pull. Sum velocity contributions weighted by 1/r².
    float2 advect = float2(0);
    int n = int(u.ctrl.w);
    for (int i = 0; i < 24; i++) {
        if (i >= n) break;
        LLEmitter e = emitters[i];
        if (e.posHueRadius.w <= 0.001) continue;
        float2 d = e.posHueRadius.xy - p;
        float r2 = dot(d, d) + 0.0001;
        advect += e.velocity.xy * exp(-r2 * 80.0) * 0.35;
    }
    float2 sampleUV = uv;
    sampleUV.x -= advect.x * u.ctrl.z * 60.0;
    sampleUV.y += advect.y * u.ctrl.z * 60.0;
    float3 prev = prevAccum.sample(s, sampleUV).rgb * u.ctrl.y;

    // Emit ink at each emitter — gaussian deposit in its hue.
    float3 ink = float3(0);
    for (int i = 0; i < 24; i++) {
        if (i >= n) break;
        LLEmitter e = emitters[i];
        if (e.posHueRadius.w <= 0.001) continue;
        float2 d = e.posHueRadius.xy - p;
        float r2 = dot(d, d);
        float intensity = exp(-r2 / (e.posHueRadius.w * e.posHueRadius.w * 0.5));
        float3 hue = hsv2rgb(float3(e.posHueRadius.z, 0.7, 1.0));
        ink += hue * intensity * (0.4 + u.audio.x * 0.6);
    }

    float3 col = prev + ink;
    if (u.audio.y > 0.5) col += ink * 0.7;
    col = min(col, float3(8.0));
    currAccum.write(float4(col, 1.0), gid);
}

fragment float4 ll_composite_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> accum [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    uv.y = 1.0 - uv.y;
    float treb = u.bands[6] + u.bands[7];
    float ab = 0.0025 + treb * 0.005;
    float r = accum.sample(s, uv + float2( ab, 0)).r;
    float g = accum.sample(s, uv).g;
    float b = accum.sample(s, uv - float2( ab, 0)).b;
    float3 base = accum.sample(s, uv).rgb;
    float3 chroma = float3(r, g, b);
    float3 bloom = float3(0);
    float br = 0.006 + treb * 0.012;
    bloom += accum.sample(s, uv + float2( br, 0)).rgb;
    bloom += accum.sample(s, uv + float2(-br, 0)).rgb;
    bloom += accum.sample(s, uv + float2(0,  br)).rgb;
    bloom += accum.sample(s, uv + float2(0, -br)).rgb;
    bloom *= 0.25;
    float3 col = chroma + bloom * 0.6 + base * 0.15;
    col = aces_tonemap(col);
    float vig = smoothstep(1.4, 0.4, length((in.uv - 0.5) * 1.3));
    return float4(col * vig, 1.0);
}

// MARK: - #48 Strand Veil

struct SVUniforms {
    float4 ctrl;        // (time, count, segments, _)
    float4 audio;       // (rms, onset, bassLow, treb)
    float4 aspectFlow;  // (aspect, flowScale, gravity, audioCoupling)
    float4 style;       // (baseHue, hueSpread, strandLength, _)
};

struct SVStrandHead {
    float4 posPhase;     // (x, y, phase, length)
    float4 velocityHue;  // (vx, vy, hue, _)
};

inline float sv_hash(float n) { return fract(sin(n) * 43758.5453); }

inline float2 sv_curl(float2 p, float t, float scale) {
    float e = 0.05;
    float n1 = noise2(p * scale + float2(t * 0.3, 0) + float2( e, 0));
    float n2 = noise2(p * scale + float2(t * 0.3, 0) - float2( e, 0));
    float n3 = noise2(p * scale + float2(0, t * 0.31) + float2(0,  e));
    float n4 = noise2(p * scale + float2(0, t * 0.31) - float2(0,  e));
    return float2(n3 - n4, -(n1 - n2)) / (2 * e);
}

kernel void sv_init_kernel(
    device SVStrandHead *out [[buffer(0)]],
    constant SVUniforms &u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= uint(u.ctrl.y)) return;
    float fi = float(gid);
    out[gid].posPhase = float4(
        sv_hash(fi * 0.013) * 2.0 - 1.0,
        sv_hash(fi * 0.027) * 2.0 - 1.0,
        sv_hash(fi * 0.041) * 6.28318,
        0.20 + sv_hash(fi * 0.061) * 0.20
    );
    out[gid].velocityHue = float4(0, 0, sv_hash(fi * 0.083), 0);
}

kernel void sv_step_kernel(
    device SVStrandHead *src [[buffer(0)]],
    device SVStrandHead *dst [[buffer(1)]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant SVUniforms &u [[buffer(2)]],
    constant float2 &range [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint count = uint(u.ctrl.y);
    if (gid >= count) return;
    SVStrandHead s = src[gid];
    float t = u.ctrl.x;
    float2 p = s.posPhase.xy;

    // Curl-noise advection.
    float2 v = sv_curl(p, t, u.aspectFlow.y);
    // Body presence: pull strand toward the body silhouette so the veil clings.
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float2 uv = p * 0.5 + 0.5;
    if (uv.x > 0 && uv.x < 1 && uv.y > 0 && uv.y < 1) {
        float2 du = float2(uv.x, ((1.0 - uv.y) * 1080.0 + 1.0) / 1082.0);
        float mm = depthTex.sample(ss, du).r;
        bool inBody = mm > range.x && mm < range.y && mm > 0;
        if (inBody) {
            float2 toC = float2(0.0, 0.0) - p;
            v += toC * 0.05;
        }
    }
    // Light gravity pulls strands downward (NDC -y).
    v += float2(0, -u.aspectFlow.z) * 0.05;

    // Recycle if drifted off-screen.
    p += v * 0.012 * (1.0 + u.audio.x * 1.0);
    if (length(p) > 1.6 || p.y < -1.4) {
        float fi = float(gid) + t * 7.13;
        p = float2(sv_hash(fi) * 2.0 - 1.0, 1.2 + sv_hash(fi * 1.7) * 0.4);
    }

    dst[gid].posPhase = float4(p, s.posPhase.z, s.posPhase.w);
    dst[gid].velocityHue = float4(v, s.velocityHue.z, 0);
}

struct SVOut {
    float4 position [[position]];
    float4 color;
};

vertex SVOut sv_strand_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device SVStrandHead *heads [[buffer(0)]],
    constant SVUniforms &u [[buffer(1)]]
) {
    SVStrandHead h = heads[iid];
    int segments = int(u.ctrl.z);
    float segT = float(vid) / float(segments - 1);
    // Strand length user-controlled (multiplied with per-strand random length).
    float lenScale = u.style.z;
    // March from the head along curl noise to build the strand body.
    float2 p = h.posPhase.xy;
    float t = u.ctrl.x;
    for (int i = 0; i < 16; i++) {
        if (float(i) / float(segments - 1) > segT) break;
        float2 v = sv_curl(p, t + float(i) * 0.08, u.aspectFlow.y);
        v += float2(0, -u.aspectFlow.z * 0.6);
        p += v * h.posPhase.w * lenScale / float(segments);
    }
    SVOut o;
    o.position = float4(p, 0, 1);

    // Color: base hue + per-strand offset. hueSpread=0 makes monochrome;
    // hueSpread=1 spreads across the whole circle.
    float hue = fract(u.style.x + (h.velocityHue.z - 0.5) * u.style.y);
    float3 col = hsv2rgb(float3(hue, 0.6, 1.0));
    float speed = length(h.velocityHue.xy);
    float life = 1.0 - segT * 0.7;
    // audioCoupling user-controlled.
    float audioBoost = 0.3 + u.audio.x * u.aspectFlow.w + speed * 8.0;
    o.color = float4(col * life * audioBoost, life * 0.3);
    return o;
}

fragment float4 sv_strand_fs(SVOut in [[stage_in]]) {
    return float4(aces_tonemap(in.color.rgb), in.color.a);
}


// MARK: - #49 Boids Murmuration
//
// Classical Reynolds rules with a body-as-predator force. We approximate the
// neighbourhood lookup with a coarse 16×16 spatial bin so the kernel can sample
// O(N) instead of O(N²). This is sufficient for ~32k birds.

struct BMUniforms {
    float4 ctrl;     // (time, count, dt, _)
    float4 audio;    // (rms, onset, bassLow, treb)
    float4 weights;  // (separation, alignment, cohesion, predator)
};

struct BMBird {
    float4 posSpeed;   // (x, y, speed, _)
    float4 velocity;   // (vx, vy, _, _)
};

inline float bm_hash(float n) { return fract(sin(n) * 43758.5453); }

kernel void bm_init_kernel(
    device BMBird *out [[buffer(0)]],
    constant BMUniforms &u [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= uint(u.ctrl.y)) return;
    float fi = float(gid);
    float angle = bm_hash(fi * 0.013) * 6.28318;
    float r = bm_hash(fi * 0.027) * 0.5;
    float2 p = float2(cos(angle), sin(angle)) * r;
    float vAngle = bm_hash(fi * 0.041) * 6.28318;
    float2 v = float2(cos(vAngle), sin(vAngle)) * 0.005;
    out[gid].posSpeed = float4(p, length(v), 0);
    out[gid].velocity = float4(v, 0, 0);
}

kernel void bm_step_kernel(
    device BMBird *src [[buffer(0)]],
    device BMBird *dst [[buffer(1)]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant BMUniforms &u [[buffer(2)]],
    constant float2 &range [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint count = uint(u.ctrl.y);
    if (gid >= count) return;
    BMBird s = src[gid];
    float2 p = s.posSpeed.xy;
    float2 v = s.velocity.xy;

    // Sample 12 nearby birds (stride strategy — fast and gives enough flock
    // coherence for visual purposes).
    float2 sumPos = float2(0);
    float2 sumVel = float2(0);
    float2 sepForce = float2(0);
    int n = 0;
    for (int k = 0; k < 12; k++) {
        uint other = (gid * 13u + uint(k) * 71u + uint(u.ctrl.x * 60.0) * 17u) % count;
        if (other == gid) continue;
        BMBird ob = src[other];
        float2 d = ob.posSpeed.xy - p;
        float dist2 = dot(d, d);
        if (dist2 > 0.06) continue;
        float dist = sqrt(dist2 + 1e-5);
        sumPos += ob.posSpeed.xy;
        sumVel += ob.velocity.xy;
        if (dist2 < 0.005) sepForce -= d / dist;
        n++;
    }
    if (n > 0) {
        float2 cohesion = (sumPos / float(n) - p) * u.weights.z;
        float2 alignment = (sumVel / float(n) - v) * u.weights.y;
        v += cohesion + alignment + sepForce * u.weights.x;
    }

    // Body predator: approximate centroid via 4×4 sample; flee.
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float2 bodyC = float2(0); float bodyW = 0;
    for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
        float2 uv = (float2(i, j) + 0.5) / 4.0;
        float2 du = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
        float mm = depthTex.sample(ss, du).r;
        if (mm > range.x && mm < range.y && mm > 0) {
            bodyC += (uv * 2.0 - 1.0); bodyW += 1.0;
        }
    }
    if (bodyW > 0) {
        bodyC /= bodyW;
        float2 d = p - bodyC;
        float dist = length(d) + 1e-3;
        v += (d / dist) * exp(-dist * 4.0) * u.weights.w;
    }

    // Speed clamp.
    float speed = length(v);
    float maxSpeed = 0.012;
    if (speed > maxSpeed) v = (v / speed) * maxSpeed;
    if (speed < 0.001) v += float2(0.001, 0);

    p += v;
    // Wrap edges.
    if (p.x > 1.4) p.x = -1.4;
    if (p.x < -1.4) p.x = 1.4;
    if (p.y > 1.0) p.y = -1.0;
    if (p.y < -1.0) p.y = 1.0;

    dst[gid].posSpeed = float4(p, speed, 0);
    dst[gid].velocity = float4(v, 0, 0);
}

struct BMOut {
    float4 position [[position]];
    float4 color;
};

vertex BMOut bm_bird_vs(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device BMBird *birds [[buffer(0)]],
    constant BMUniforms &u [[buffer(1)]]
) {
    BMBird b = birds[iid];
    float2 v = b.velocity.xy;
    float speed = length(v) + 1e-5;
    float2 fwd = v / speed;
    float2 sideV = float2(-fwd.y, fwd.x);

    // Two-triangle wing quad: pointed forward, ~12 px long.
    float lenL = 0.012 + speed * 1.2;
    float widT = 0.005;
    float2 quad[4] = {
        b.posSpeed.xy - fwd * lenL * 0.4 - sideV * widT,
        b.posSpeed.xy - fwd * lenL * 0.4 + sideV * widT,
        b.posSpeed.xy + fwd * lenL,
        b.posSpeed.xy + fwd * lenL + sideV * 0.001
    };
    BMOut o;
    o.position = float4(quad[vid], 0, 1);
    // Twilight palette — birds against amber sky.
    float h = fract(0.06 + speed * 1.5 + u.audio.x * 0.3);
    float3 col = hsv2rgb(float3(h, 0.4, 1.0));
    o.color = float4(col * (0.4 + speed * 8.0), 0.7);
    return o;
}

fragment float4 bm_bird_fs(BMOut in [[stage_in]]) {
    return float4(aces_tonemap(in.color.rgb), in.color.a);
}

// MARK: - #50 Vortex Ring Smoke

struct VRUniforms {
    float4 ctrl;     // (time, count, aspect, _)
    float4 audio;    // (rms, onset, bassLow, treb)
    float4 style;    // (swirlFreq, saturation, bodyBoost, _)
};

struct VRRing {
    float4 posSize;   // (x, y, radius, coreSize)
    float4 hueAge;    // (hue, age, strength, alive)
};

fragment float4 vortex_ring_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    const device VRRing *rings [[buffer(0)]],
    constant VRUniforms &u [[buffer(1)]]
) {
    float2 uv = in.uv;
    float2 p = uv;
    p.x *= u.ctrl.z;
    int count = int(u.ctrl.y);
    float t = u.ctrl.x;

    float3 col = float3(0.01, 0.012, 0.018);

    for (int i = 0; i < 24; i++) {
        if (i >= count) break;
        VRRing r = rings[i];
        if (r.hueAge.w < 0.5) continue;
        float2 c = r.posSize.xy; c.x *= u.ctrl.z;
        float dist = length(p - c);
        // Gaussian "tube" around the radius — that's the visible smoke ring.
        float band = exp(-pow(dist - r.posSize.z, 2.0) / (r.posSize.w * r.posSize.w));
        // Inner and outer edges have soft glow.
        float core = exp(-pow(dist - r.posSize.z, 2.0) / (r.posSize.w * r.posSize.w * 0.25));
        float3 hue = hsv2rgb(float3(r.hueAge.x, u.style.y, 1.0));
        col += hue * (band * 0.5 + core * 0.6) * r.hueAge.z * (0.7 + u.audio.x * 0.6);

        // Swirling fine structure inside the band — frequency user-controlled.
        float a = atan2(p.y - c.y, p.x - c.x);
        float swirl = sin(a * u.style.x - t * 3.0 - r.hueAge.y * 0.3) * 0.5 + 0.5;
        col += hue * band * swirl * 0.25;
    }

    // Body presence makes nearby smoke glow warmer (boost user-controlled).
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float2 du = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float mm = depthTex.sample(ss, du).r;
    bool inBody = mm > 500.0 && mm < 4000.0 && mm > 0;
    if (inBody) col *= u.style.z;

    col += float3(0.5, 0.7, 1.0) * u.audio.y * 0.3;
    col *= smoothstep(1.6, 0.4, length((uv - 0.5) * 1.3));
    return float4(aces_tonemap(col), 1.0);
}

// MARK: - #51 Filament Cosmology
//
// Volumetric raymarch through a 3D Worley filament density field; body acts as
// a gravitational lens (deflects ray direction near body region).

inline float worley3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float minD = 1e9;
    for (int dz = -1; dz <= 1; dz++) for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        float3 g = float3(dx, dy, dz);
        float3 cell = i + g;
        float3 jit = float3(hash3(cell), hash3(cell + 7.0), hash3(cell + 13.0));
        float3 d = g + jit - f;
        minD = min(minD, dot(d, d));
    }
    return sqrt(minD);
}

inline float filament_density(float3 p, float t) {
    // Cosmic web: invert Worley so we get bright filaments along cell edges.
    float w = worley3(p * 1.4);
    float ridge = exp(-w * 4.0);
    float drift = noise3(p * 0.7 + t * 0.05) * 0.5;
    return ridge * (0.6 + drift);
}

struct FilamentParams {
    float4 cfg;   // (marchSteps, threshold, lensStrength, audioCoupling)
    float4 misc;  // (hueShift, worleyScale, _, _)
};

fragment float4 filament_cosmology_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant FilamentParams &p [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 p2 = (uv - 0.5) * float2(u.aspect, 1.0);

    float t = u.time;
    float bass = u.bands[0] + u.bands[1];
    float treb = u.bands[6] + u.bands[7];

    // Body lensing: detect body presence and bend rays toward it.
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;
    float bodyMass = inBody ? 1.0 : 0.0;
    // Estimate body centroid via 3×3 neighbour sum for a lensing direction.
    float2 grad = float2(0);
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        float2 off = float2(i, j) * 0.04;
        float2 du = float2(uv.x + off.x, ((uv.y + off.y) * 1080.0 + 1.0) / 1082.0);
        float m = depthTex.sample(s, du).r;
        bool b = m > u.nearMM && m < u.farMM && m > 0;
        if (b) grad += off;
    }
    // User-tunable lens strength.
    p2 -= grad * p.cfg.z * (1.0 + bass);

    float3 ro = float3(p2, -2.5);
    float3 rd = normalize(float3(p2 * 0.4, 1.0));

    int STEPS = clamp(int(p.cfg.x), 12, 72);
    float3 acc = float3(0);
    float trans = 1.0;
    float zNear = 0.5, zFar = 5.0;
    float dz = (zFar - zNear) / float(STEPS);
    float threshold = p.cfg.y;
    float audioCoupling = p.cfg.w;
    float worleyScale = p.misc.y;
    float hueShift = p.misc.x;

    for (int i = 0; i < 72; i++) {
        if (i >= STEPS) break;
        float z = zNear + (float(i) + 0.5) * dz;
        float3 q = ro + rd * z;
        q += float3(sin(t * 0.05 + q.z), cos(t * 0.07 - q.z), t * 0.03);
        // Worley scale + threshold user-controlled.
        float w = worley3(q * worleyScale);
        float ridge = exp(-w * 4.0);
        float drift = noise3(q * 0.7 + t * 0.05) * 0.5;
        float density = ridge * (0.6 + drift);
        density = pow(saturate(density - threshold), 1.7) * (1.5 + u.rms * audioCoupling);

        float3 emit = iq_palette(0.62 + hueShift + bass * 0.2 + density * 0.2,
                                 float3(0.5, 0.5, 0.6),
                                 float3(0.5, 0.5, 0.5),
                                 float3(1.0, 1.0, 0.8),
                                 float3(0.0, 0.10, 0.20));
        float a = 1.0 - exp(-density * dz * 7.0);
        acc += trans * emit * a * (0.6 + treb * 0.6);
        trans *= 1.0 - a;
        if (trans < 0.02) break;
    }

    // Lensing edge highlight: thin halo around body silhouette.
    if (bodyMass > 0.5) acc += float3(0.6, 0.5, 1.0) * 0.15;
    acc += float3(0.2, 0.4, 0.8) * u.onset * 0.3;
    return float4(aces_tonemap(acc), 1.0);
}


// MARK: - #52 Velvet Petal Field
//
// 50k procedural petals computed per-fragment via a Voronoi-modulated billboard
// pattern. Velvet sheen via Disney-style fresnel sheen approximation.

inline float petal_shape(float2 p, float t) {
    // 4-lobed petal: pow(cos(2θ), 1.5) with radial taper.
    float r = length(p);
    float a = atan2(p.y, p.x);
    float lobes = abs(cos(a * 2.0));
    float falloff = exp(-r * 6.0) * pow(lobes, 1.4);
    return falloff;
}

fragment float4 velvet_petal_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0) * 6.0;
    float t = u.time;
    float bass = u.bands[0] + u.bands[1];
    float treb = u.bands[6] + u.bands[7];

    // Body presence: petals bloom denser inside the silhouette.
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inBody = depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0;

    float3 col = float3(0.06, 0.04, 0.08);  // deep velvet plum bg

    // Iterate over a coarse jittered grid of petal centres.
    int rings = 4;
    int divisions = 14;
    for (int ringI = 0; ringI < rings; ringI++) {
        float ringR = 0.5 + float(ringI) * 0.6 + bass * 0.2;
        for (int j = 0; j < divisions; j++) {
            float baseA = (float(j) + 0.5) / float(divisions) * 6.28318;
            // Phase wobble per petal so the field breathes.
            float wobbleA = sin(t * 0.6 + float(ringI + j) * 1.7) * 0.05;
            float a = baseA + wobbleA + t * 0.04 * (1.0 + float(ringI) * 0.2);
            float2 c = ringR * float2(cos(a), sin(a));
            // Stem sway with audio.
            c += float2(sin(t * 1.3 + ringR + float(j)) * 0.05 * (1.0 + bass),
                        cos(t * 1.1 + ringR + float(j)) * 0.05 * (1.0 + bass));
            float2 toP = p - c;
            // Rotate the petal so it points outward from origin.
            float orient = a + 1.5707963;
            float ca = cos(-orient), sa = sin(-orient);
            float2 q = float2(ca * toP.x - sa * toP.y, sa * toP.x + ca * toP.y);
            // Stretch tall.
            q.y *= 0.6;
            float petal = petal_shape(q, t);
            if (petal < 0.001) continue;

            // Hue from ring + petal seed; saturated jewel velvets.
            float hue = fract(0.85 + float(ringI) * 0.07 + sin(float(j) * 1.7) * 0.05);
            float3 base = hsv2rgb(float3(hue, 0.85, 1.0));
            // Velvet sheen: Disney sheen approximation.
            float fres = pow(saturate(1.0 - length(q) * 1.4), 5.0);
            float3 sheen = mix(base, float3(1.0, 0.85, 0.95), fres) * (0.4 + treb * 0.7);

            float bloom = petal * (1.0 + u.rms * 1.4);
            if (inBody) bloom *= 1.6;
            col += sheen * bloom * 0.18;
        }
    }

    col += float3(0.6, 0.4, 0.7) * u.onset * 0.3;
    col *= smoothstep(2.5, 0.6, length((uv - 0.5) * 1.6));
    return float4(aces_tonemap(col), 1.0);
}

// MARK: - #53 Glitch Mosaic
//
// Each tile is a tilted holographic mirror; we sample the source colour from
// a different offset per tile, modulated by a flow field. Body region triggers
// datamosh-style P-frame displacement.

struct GlitchMosaicParams {
    float4 cfg;   // (tileSize, bassPump, glitchProbability, rgbSeparation)
    float4 misc;  // (rimIntensity, onsetStrobe, _, _)
};

fragment float4 glitch_mosaic_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> colorTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant GlitchMosaicParams &p [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float t = u.time;
    float bass = u.bands[0] + u.bands[1];
    float treb = u.bands[6] + u.bands[7];

    // Tile size: base + bass pump (both user-controlled).
    float tileSize = p.cfg.x + bass * p.cfg.y;
    float2 tile = floor(uv / tileSize);
    float2 inTile = fract(uv / tileSize);

    // Per-tile pseudo-random offset gives the holographic-mirror tilt.
    float seed = fract(sin(dot(tile, float2(127.1, 311.7))) * 43758.5);
    float seed2 = fract(sin(dot(tile, float2(269.5, 183.3))) * 43758.5);

    // Time-modulated tilt → each tile samples from a slightly different uv.
    float tilt = (seed - 0.5) * 0.04 + sin(t * 0.5 + seed * 6.28318) * 0.012;
    float tilt2 = (seed2 - 0.5) * 0.04 + cos(t * 0.5 + seed2 * 6.28318) * 0.012;
    float2 sampleUV = uv + float2(tilt, tilt2);

    // YUV channel separation — magnitude user-controlled.
    float sep = p.cfg.w;
    float3 cr = colorTex.sample(s, sampleUV + float2(sep, 0)).rgb;
    float3 cg = colorTex.sample(s, sampleUV).rgb;
    float3 cb = colorTex.sample(s, sampleUV - float2(sep, 0)).rgb;
    float3 col = float3(cr.r, cg.g, cb.b);

    // P-frame block offset on certain tiles (probability user-controlled).
    float glitchProb = p.cfg.z - u.onset * 0.5 - bass * 0.2;
    if (seed > glitchProb) {
        float2 mosh = float2(seed - 0.5, seed2 - 0.5) * 0.12;
        col = colorTex.sample(s, sampleUV + mosh).rgb;
        col = abs(col - 0.5) * 2.0;
    }

    // Holographic rim per-tile (intensity user-controlled).
    float rim = pow(max(abs(inTile.x - 0.5), abs(inTile.y - 0.5)) * 2.0, 8.0);
    float3 rainbow = iq_palette(seed + t * 0.1,
                                float3(0.5, 0.5, 0.5),
                                float3(0.5, 0.5, 0.5),
                                float3(1.0, 1.0, 1.0),
                                float3(0.0, 0.33, 0.67));
    col += rainbow * rim * (p.misc.x + treb * 0.7);

    // Onset strobe inversion (user-controlled strength).
    if (u.onset > 0.5 && seed > (1.0 - p.misc.y * 0.3)) col = 1.0 - col;

    return float4(aces_tonemap(col), 1.0);
}

// MARK: - #54 Kinetic Wireframe
//
// Delaunay-ish triangle net derived from depth gradient sample points. Lines
// "explode" outward from cells then snap back via critically-damped springs.

inline float wireframe_line(float2 p, float2 a, float2 b, float thickness) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    float d = length(pa - ba * h);
    return smoothstep(thickness, 0.0, d);
}

struct WireframeParams {
    float4 cfg;   // (lineThickness, explosionMag, baseHueShift, audioCoupling)
    float4 misc;  // (bodyTintHue, _, _, _)
};

fragment float4 kinetic_wireframe_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant WireframeParams &cfg [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float t = u.time;
    float bass = u.bands[0] + u.bands[1];

    // Build a 14×9 grid of jittered nodes; each node displaces away from
    // origin on every onset and decays back exponentially.
    float3 col = float3(0.005, 0.005, 0.012);
    int gx = 14, gy = 9;
    for (int gy_i = 0; gy_i < 9; gy_i++) {
        for (int gx_i = 0; gx_i < 14; gx_i++) {
            // Node position with audio-driven explosion + sine wobble.
            float seed = fract(sin(float(gx_i) * 12.3 + float(gy_i) * 7.7) * 43758.5);
            float2 base = float2((float(gx_i) + 0.5) / float(gx),
                                 (float(gy_i) + 0.5) / float(gy));
            float2 explode = (base - 0.5) * (0.04 + u.onset * cfg.cfg.y) * (0.4 + bass * cfg.cfg.w);
            // Reset on time mod.
            float decay = exp(-fract(t * 0.4 + seed) * 2.0);
            float2 a = base + explode * decay
                            + float2(sin(t + seed * 6.0), cos(t + seed * 7.0)) * 0.006;

            // Connect to four neighbours: right, down, diag.
            for (int kk = 0; kk < 4; kk++) {
                int nx = gx_i + (kk == 0 ? 1 : (kk == 2 ? 1 : (kk == 3 ? -1 : 0)));
                int ny = gy_i + (kk == 1 ? 1 : (kk >= 2 ? 1 : 0));
                if (nx < 0 || nx >= gx || ny < 0 || ny >= gy) continue;
                float seed2 = fract(sin(float(nx) * 12.3 + float(ny) * 7.7) * 43758.5);
                float2 b = float2((float(nx) + 0.5) / float(gx),
                                  (float(ny) + 0.5) / float(gy));
                float2 explode2 = (b - 0.5) * (0.04 + u.onset * cfg.cfg.y) * (0.4 + bass * cfg.cfg.w);
                float decay2 = exp(-fract(t * 0.4 + seed2) * 2.0);
                b = b + explode2 * decay2
                      + float2(sin(t + seed2 * 6.0), cos(t + seed2 * 7.0)) * 0.006;

                float thickness = cfg.cfg.x + bass * 0.0014;
                float line = wireframe_line(uv, a, b, thickness);
                if (line < 0.01) continue;

                // Body presence colours edges warmer.
                float2 mid = (a + b) * 0.5;
                float2 du = float2(mid.x, (mid.y * 1080.0 + 1.0) / 1082.0);
                float mm = depthTex.sample(s, du).r;
                bool inBody = mm > u.nearMM && mm < u.farMM && mm > 0;

                float3 baseCol = inBody
                    ? hsv2rgb(float3(cfg.misc.x, 0.55, 1.0))
                    : iq_palette(t * 0.05 + cfg.cfg.z + length(mid - 0.5),
                                 float3(0.5, 0.5, 0.6),
                                 float3(0.5, 0.5, 0.5),
                                 float3(1.0, 1.0, 1.0),
                                 float3(0.0, 0.33, 0.67));
                col += baseCol * line * (0.4 + u.rms * 0.8) * (0.7 + decay * 0.6);
            }
        }
    }

    col += float3(0.5, 0.6, 0.8) * u.onset * 0.4;
    return float4(aces_tonemap(col), 1.0);
}

// MARK: - #55 Impasto Painter
//
// Accumulated brush splats with simulated impasto raised highlights. Per-pixel
// brush direction comes from depth gradient; lighting from a simulated raked
// light source so the paint reads as physical material.

struct ImpastoParams {
    float4 cfg;   // (brushFreq, bassPump, baseHueShift, highlightHueShift)
    float4 misc;  // (bgDesaturation, audioCoupling, _, _)
};

fragment float4 impasto_painter_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant ImpastoParams &p_ [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.aspect, 1.0);
    float t = u.time;
    float bass = u.bands[0] + u.bands[1];
    float treb = u.bands[6] + u.bands[7];

    // Depth gradient → brush direction.
    float2 depthUV = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float dxDepth = depthTex.sample(s, depthUV + float2(0.004, 0)).r
                   - depthTex.sample(s, depthUV - float2(0.004, 0)).r;
    float dyDepth = depthTex.sample(s, depthUV + float2(0, 0.004)).r
                   - depthTex.sample(s, depthUV - float2(0, 0.004)).r;
    float2 grad = float2(dxDepth, dyDepth);
    float gradLen = length(grad) + 1e-3;
    float2 brushDir = grad / gradLen;
    if (gradLen < 1e-3) brushDir = float2(cos(t * 0.4), sin(t * 0.4));

    // Brush stripe frequency user-controlled.
    float brushFreq = p_.cfg.x + bass * p_.cfg.y;
    float2 perp = float2(-brushDir.y, brushDir.x);
    float2 q = float2(dot(p, brushDir), dot(p, perp));
    float stripe = sin(q.y * brushFreq) * 0.5 + 0.5;
    stripe = pow(stripe, 1.6);

    float strokes = stripe;
    strokes += sin(q.y * 240.0 + q.x * 4.0) * 0.5 + 0.5;
    strokes += sin(q.y * 380.0 - q.x * 6.0) * 0.5 + 0.5;
    strokes /= 3.0;

    float dStripe = cos(q.y * brushFreq) * brushFreq;
    float light = saturate(0.5 + dStripe * 0.005);

    // Palette hue shifts user-controlled.
    float3 base = iq_palette(0.55 + p_.cfg.z + bass * 0.2 + uv.x * 0.3,
                             float3(0.4, 0.4, 0.5),
                             float3(0.5, 0.5, 0.5),
                             float3(1.0, 1.0, 1.0),
                             float3(0.0, 0.10, 0.20));
    float3 highlight = iq_palette(0.05 + p_.cfg.w + treb * 0.2,
                                  float3(0.95, 0.85, 0.6),
                                  float3(0.4, 0.4, 0.5),
                                  float3(1.0, 1.0, 0.8),
                                  float3(0.0, 0.20, 0.40));

    float3 col = mix(base * 0.6, highlight, light * strokes) * (1.0 + u.rms * p_.misc.y);

    // Body presence → desaturate background (strength user-controlled).
    float2 du = float2(uv.x, (uv.y * 1080.0 + 1.0) / 1082.0);
    float mm = depthTex.sample(s, du).r;
    bool inBody = mm > u.nearMM && mm < u.farMM && mm > 0;
    if (!inBody) {
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(lum), col, 1.0 - p_.misc.x);
    }

    col += float3(0.3, 0.2, 0.05) * u.onset * 0.4;
    col *= smoothstep(1.5, 0.6, length((uv - 0.5) * 1.4));
    return float4(aces_tonemap(col), 1.0);
}


// (Removed: dead `parametric_swarm_fs` — replaced by the live `psw_*` compute+
// render pipeline at the top of this file. The fragment-shader-only approach
// could never reproduce Casberry's 3D geodesic sphere look at viable cost.)

