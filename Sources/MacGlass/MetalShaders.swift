// MacGlass - built-in Metal shaders (compiled at runtime).
// SPDX-License-Identifier: GPL-3.0-only

let builtinMetalSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;
};

struct QuadUniforms {
    float4 srcRect;   // u0, v0, u1, v1 in normalized source coordinates
    uint transpose;   // 1: output (s, t) reads source (t, s) - "Vertical" orientation
    uint flipH;
    uint flipV;
    uint pad;
};

// Full-target quad as a 4-vertex triangle strip.
vertex VOut quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
    float2 o = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0); // output coords, top-left origin
    VOut out;
    out.position = float4(o.x * 2.0 - 1.0, 1.0 - o.y * 2.0, 0.0, 1.0);
    float2 c = o;
    if (u.flipH != 0) c.x = 1.0 - c.x;
    if (u.flipV != 0) c.y = 1.0 - c.y;
    if (u.transpose != 0) c = c.yx;
    out.uv = mix(u.srcRect.xy, u.srcRect.zw, c);
    return out;
}

// Plain copy (point or linear sampling, depending on the sampler).
fragment float4 copy_fragment(VOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    return float4(src.sample(smp, in.uv).rgb, 1.0);
}

// Bilinear Filter (port of ShaderGlass-Bilinear's footprint pixel shader):
// when the captured image is scaled down to the shader input (Pixel Size), average the whole
// screen area ("footprint") of each source pixel, centred on it, instead of reading a single point.
// n x n bilinear taps (n = 2..8 depending on the scale) cover the footprint.
fragment float4 footprint_fragment(VOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 texSize = float2(src.get_width(), src.get_height());

    // footprint: captured pixels per shader-input pixel, per texture axis (rotation-safe)
    float2 fp = float2(abs(dfdx(uv.x)) + abs(dfdy(uv.x)), abs(dfdx(uv.y)) + abs(dfdy(uv.y))) * texSize;
    fp = max(fp, 1.0);
    int n = clamp(int(ceil(max(fp.x, fp.y))), 2, 8); // taps per axis
    float2 stp = fp / float(n) / texSize;           // tap spacing in UV

    float4 acc = float4(0.0);
    for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
            acc += src.sample(smp, uv + (float2(float(i), float(j)) + 0.5 - float(n) * 0.5) * stp, level(0.0));
        }
    }
    float4 result = acc / float(n * n);
    return float4(result.rgb, 1.0);
}
"""#
