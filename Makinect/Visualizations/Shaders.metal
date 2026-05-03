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

// MARK: - #1 Depth Lava

fragment float4 depth_lava_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    // Depth UV: registered depth is 1920x1082; skip the 1px blank top/bottom rows
    float2 depthUV = float2(in.uv.x, (in.uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;

    // Local 3x3 average to fill speckle holes
    if (depthMM <= 0 || isnan(depthMM)) {
        float sum = 0;
        float cnt = 0;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                float2 off = float2(dx, dy) / float2(1920.0, 1082.0);
                float d = depthTex.sample(s, depthUV + off).r;
                if (d > 0 && !isnan(d)) { sum += d; cnt += 1; }
            }
        }
        depthMM = (cnt > 0) ? sum / cnt : u.farMM;
    }

    float t = saturate((depthMM - u.nearMM) / max(1.0, u.farMM - u.nearMM));

    // Flowing field driven by depth + time + bass
    float bass = u.bands[0] + u.bands[1];
    float2 flowUV = in.uv * 4.0 + float2(0, u.time * 0.3);
    flowUV.x += sin(u.time * 0.5 + in.uv.y * 8.0) * (0.2 + bass * 0.6);
    float n = fbm(flowUV);
    n += fbm(flowUV * 2.5 + u.time * 0.6) * 0.5;

    // Heat map driven by depth + flow
    float heat = saturate((1.0 - t) * 1.2 + n * 0.6 - 0.2);
    heat = pow(heat, 1.4 - u.rms * 1.8);

    // Beat flash
    heat += u.onset * 0.25;

    float3 col = hsv2rgb(float3(0.05 + heat * 0.10 - bass * 0.02, 0.95, heat));

    // Deep voids stay dark
    if (depthMM > u.farMM * 0.98) col *= 0.05;

    return float4(col, 1.0);
}

// MARK: - #4 NPR Halftone (over color, masked by depth)

fragment float4 halftone_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> colorTex [[texture(0)]],
    texture2d<float, access::sample> depthTex [[texture(1)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 depthUV = float2(in.uv.x, (in.uv.y * 1080.0 + 1.0) / 1082.0);
    float depthMM = depthTex.sample(s, depthUV).r;
    bool inRange = (depthMM > u.nearMM && depthMM < u.farMM && depthMM > 0 && !isnan(depthMM));

    float4 c = colorTex.sample(s, in.uv);
    float lum = dot(c.rgb, float3(0.299, 0.587, 0.114));

    // Halftone dot pattern, dot size pumped by RMS + bass
    float dotSpacing = 16.0 - u.rms * 8.0 - u.bands[0] * 6.0;
    dotSpacing = max(4.0, dotSpacing);
    float2 grid = in.uv * float2(1920, 1080) / dotSpacing;
    float2 gridFract = fract(grid) - 0.5;
    float dotR = (1.0 - lum) * 0.55 + u.rms * 0.15;
    float d = length(gridFract);
    float dot = smoothstep(dotR, dotR - 0.04, d);

    float3 outCol;
    if (inRange) {
        // Body cut-out: black halftone on cyan/magenta
        float hue = 0.55 + sin(u.time * 0.3) * 0.05 + u.bands[3] * 0.1;
        float3 fg = hsv2rgb(float3(hue, 0.7, 1.0));
        outCol = mix(fg, float3(0.05), dot);
    } else {
        // Background: silver halftone
        outCol = mix(float3(0.85), float3(0.10), dot);
    }

    // Beat flash inverts briefly
    if (u.onset > 0.5) outCol = 1.0 - outCol;

    return float4(outCol, 1.0);
}

// MARK: - #9 Audio PostFX (chromatic aberration + scanlines + bloom approximation)

fragment float4 postfx_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> colorTex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 center = float2(0.5);
    float2 dir = uv - center;

    float bass = u.bands[0] + u.bands[1] * 0.7;
    float treb = u.bands[6] + u.bands[7];
    float aberr = 0.005 + bass * 0.015 + u.onset * 0.02;

    float r = colorTex.sample(s, uv + dir * aberr).r;
    float g = colorTex.sample(s, uv).g;
    float b = colorTex.sample(s, uv - dir * aberr).b;
    float3 col = float3(r, g, b);

    // Cheap "bloom": 4-tap blur sample at high luminance
    float3 bloom = float3(0);
    float bloomR = 0.004 + treb * 0.012;
    bloom += colorTex.sample(s, uv + float2( bloomR, 0)).rgb;
    bloom += colorTex.sample(s, uv + float2(-bloomR, 0)).rgb;
    bloom += colorTex.sample(s, uv + float2(0,  bloomR)).rgb;
    bloom += colorTex.sample(s, uv + float2(0, -bloomR)).rgb;
    bloom *= 0.25;
    float bloomMask = smoothstep(0.6, 1.0, dot(bloom, float3(0.299, 0.587, 0.114)));
    col += bloom * bloomMask * (0.4 + treb * 0.8);

    // Scanlines pulsing on RMS
    float scan = sin(uv.y * 1080.0 * 1.5 + u.time * 4.0) * 0.5 + 0.5;
    col *= mix(1.0, 0.7 + scan * 0.5, 0.3 + u.rms * 0.4);

    // Vignette
    float vig = smoothstep(1.2, 0.4, length(dir) * 1.4);
    col *= vig;

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

// MARK: - #3 Skeleton Ribbons

struct RibbonVertexIn {
    float2 position;
    float age;
    float jointID;
};

struct RibbonUniforms {
    float aspect;
    float time;
    float rms;
    float onset;
    float bands[8];
};

struct RibbonVertexOut {
    float4 position [[position]];
    float3 color;
    float alpha;
};

vertex RibbonVertexOut ribbon_vs(
    uint vid [[vertex_id]],
    constant RibbonVertexIn *verts [[buffer(0)]],
    constant RibbonUniforms &u [[buffer(1)]]
) {
    RibbonVertexIn v = verts[vid];
    RibbonVertexOut out;
    // verts are in normalized [0,1] image coords; convert to clip space (Y flipped)
    float2 ndc = float2(v.position.x * 2.0 - 1.0, 1.0 - v.position.y * 2.0);
    out.position = float4(ndc, 0, 1);
    float h = fmod(v.jointID * 0.137 + u.time * 0.05, 1.0);
    float3 col = hsv2rgb(float3(h, 0.85, 1.0));
    float fade = saturate(1.0 - v.age);
    float beat = 1.0 + u.onset * 1.5 + u.rms * 0.6;
    out.color = col * beat;
    out.alpha = fade * (0.6 + u.bands[2] * 0.6);
    return out;
}

fragment float4 ribbon_fs(RibbonVertexOut in [[stage_in]]) {
    return float4(in.color * in.alpha, in.alpha);
}

// Pass-through color sampler used to draw RGB underneath ribbons
fragment float4 color_passthrough_fs(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float, access::sample> colorTex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return colorTex.sample(s, in.uv);
}

// MARK: - #6 Height Field Mesh

struct HeightFieldUniforms {
    float4x4 viewProj;     // 64
    float4 timing;         // (time, rms, onset, _)
    float4 bandsLow;       // bands[0..3]
    float4 bandsHigh;      // bands[4..7]
    float4 dims;           // (depthW, depthH, nearMM, farMM)
};
// Total 128 bytes, all 16-aligned.

struct HeightFieldVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 color;
    float2 uv;
};

vertex HeightFieldVertexOut heightfield_vs(
    uint vid [[vertex_id]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    constant HeightFieldUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float depthW = u.dims.x;
    float depthH = u.dims.y;
    float nearMM = u.dims.z;
    float farMM = u.dims.w;
    float time = u.timing.x;

    int dw = int(depthW);
    int x = int(vid) % dw;
    int y = int(vid) / dw;
    float2 uv = float2(float(x) / (depthW - 1.0), float(y) / (depthH - 1.0));
    float z = depthTex.sample(s, uv).r;
    if (z <= 0 || isnan(z) || z > farMM * 1.2) z = farMM;

    float zN = saturate((z - nearMM) / max(1.0, farMM - nearMM));
    float ripple = sin(uv.x * 30.0 + time * 2.0) * u.bandsLow.y * 0.1
                 + cos(uv.y * 25.0 - time * 1.5) * u.bandsLow.w * 0.08;

    float3 pos = float3(uv.x * 2.0 - 1.0, (1.0 - zN) * 0.6 + ripple, -(uv.y * 2.0 - 1.0));

    HeightFieldVertexOut out;
    out.position = u.viewProj * float4(pos, 1);
    out.worldPos = pos;
    out.color = hsv2rgb(float3(0.55 - zN * 0.4 + u.bandsHigh.y * 0.15, 0.7, 0.6 + (1.0 - zN) * 0.4));
    out.uv = uv;
    return out;
}

fragment float4 heightfield_fs(HeightFieldVertexOut in [[stage_in]]) {
    float3 light = normalize(float3(0.5, 1.0, 0.6));
    float3 dx = dfdx(in.worldPos);
    float3 dy = dfdy(in.worldPos);
    float3 n = normalize(cross(dx, dy));
    float diff = saturate(dot(n, light)) * 0.7 + 0.3;
    return float4(in.color * diff, 1.0);
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
