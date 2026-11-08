#include <metal_stdlib>
using namespace metal;

// The viewfinder while focus peaking is on: each camera frame is drawn with its own peaking outlines, so they
// can't lag behind the picture. See PeakingRenderer.swift for the steps and why.

// 1. Shrink the luma plane by a whole factor, averaging each block. Output is luma in 0…255.
kernel void peakingDownscale(texture2d<float, access::read> luma [[texture(0)]],
                             texture2d<float, access::write> small [[texture(1)]],
                             constant uint &factor [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= small.get_width() || gid.y >= small.get_height()) return;
    float sum = 0;
    for (uint dy = 0; dy < factor; dy++) {
        for (uint dx = 0; dx < factor; dx++) {
            sum += luma.read(gid * factor + uint2(dx, dy)).r;
        }
    }
    small.write(float4(sum * 255.0 / float(factor * factor)), gid);
}

constant float binomial[3] = { 1, 2, 1 };

// 2a. 3×3 binomial blur, edges repeating their outermost pixel, so single-pixel noise doesn't count as detail.
kernel void peakingBlur(texture2d<float, access::read> small [[texture(0)]],
                        texture2d<float, access::write> blurred [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(small.get_width(), small.get_height());
    int2 p = int2(gid);
    if (p.x >= size.x || p.y >= size.y) return;
    float sum = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 q = clamp(p + int2(dx, dy), int2(0), size - 1);
            sum += binomial[dx + 1] * binomial[dy + 1] * small.read(uint2(q)).r;
        }
    }
    blurred.write(float4(sum / 16.0), gid);
}

// 2b. High-pass with a Laplacian: the response to fine detail. The border stays 0.
kernel void peakingResponse(texture2d<float, access::read> blurred [[texture(0)]],
                            texture2d<float, access::write> response [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(blurred.get_width(), blurred.get_height());
    int2 p = int2(gid);
    if (p.x >= size.x || p.y >= size.y) return;
    float value = 0;
    if (p.x >= 1 && p.y >= 1 && p.x < size.x - 1 && p.y < size.y - 1) {
        value = abs(4 * blurred.read(gid).r
                    - blurred.read(uint2(p + int2(1, 0))).r - blurred.read(uint2(p - int2(1, 0))).r
                    - blurred.read(uint2(p + int2(0, 1))).r - blurred.read(uint2(p - int2(0, 1))).r);
    }
    response.write(float4(value), gid);
}

// 3. Average the response over 3×3. Along an edge this evens out the pixel-to-pixel wobble that otherwise breaks
//    outlines into dots; an isolated noise spike is diluted instead. The outer ring stays 0. Each 16×16
//    threadgroup (a tile) also sums its values, their squares and its brightness into `partials`: the frame's
//    mean and deviation, and each tile's sharpness and brightness for sweep peaking.
kernel void peakingEdges(texture2d<float, access::read> response [[texture(0)]],
                         texture2d<float, access::write> edges [[texture(1)]],
                         texture2d<float, access::read> small [[texture(2)]],
                         device float4 *partials [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 lid [[thread_position_in_threadgroup]],
                         uint2 group [[threadgroup_position_in_grid]],
                         uint2 groups [[threadgroups_per_grid]]) {
    int2 size = int2(response.get_width(), response.get_height());
    int2 p = int2(gid);
    float value = 0, brightness = 0;
    if (p.x < size.x && p.y < size.y) {
        brightness = small.read(gid).r;
        if (p.x >= 1 && p.y >= 1 && p.x < size.x - 1 && p.y < size.y - 1) {
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) value += response.read(uint2(p + int2(dx, dy))).r;
            }
            value /= 9;
        }
        edges.write(float4(value), gid);
    }

    threadgroup float4 shared[256];
    uint i = lid.y * 16 + lid.x;
    shared[i] = float4(value, value * value, brightness, 0);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (i < stride) shared[i] += shared[i + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (i == 0) partials[group.y * groups.x + group.x] = shared[0];
}

struct MaskParams {
    float cutoff;       // the frame's threshold
    uint tilesAcross;
    uint sweep;         // 1: use each tile's verdict from `tiles` (see SweepTracker)
};

// 4. Mark what clears the cutoff and has at least two marked neighbours: edges are lines, stray noise is dots.
//    In sweep mode a tile's verdict overrides the frame's cutoff: its own cutoff at its sharpest, none past it.
kernel void peakingMask(texture2d<float, access::read> edges [[texture(0)]],
                        texture2d<float, access::write> mask [[texture(1)]],
                        constant MaskParams &params [[buffer(0)]],
                        device const float *tiles [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(edges.get_width(), edges.get_height());
    int2 p = int2(gid);
    if (p.x >= size.x || p.y >= size.y) return;
    float cutoff = params.cutoff;
    if (params.sweep != 0) {
        float verdict = tiles[(gid.y / 16) * params.tilesAcross + gid.x / 16];
        if (verdict < 0) cutoff = INFINITY;
        else if (verdict > 0) cutoff = verdict;
    }
    float marked = 0;
    if (p.x >= 1 && p.y >= 1 && p.x < size.x - 1 && p.y < size.y - 1 && edges.read(gid).r > cutoff) {
        int neighbours = 0;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if ((dx != 0 || dy != 0) && edges.read(uint2(p + int2(dx, dy))).r > cutoff) neighbours++;
            }
        }
        if (neighbours >= 2) marked = 1;
    }
    mask.write(float4(marked), gid);
}

// 4b. Shrink the mask to about screen resolution, keeping any mark in each block, so lines drawn from it are as
//     bold on screen as they're meant to be however large the frame.
kernel void peakingPool(texture2d<float, access::read> mask [[texture(0)]],
                        texture2d<float, access::write> pooled [[texture(1)]],
                        constant uint &factor [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= pooled.get_width() || gid.y >= pooled.get_height()) return;
    uint2 limit = uint2(mask.get_width(), mask.get_height()) - 1;
    float marked = 0;
    for (uint dy = 0; dy < factor; dy++) {
        for (uint dx = 0; dx < factor; dx++) {
            marked = max(marked, mask.read(min(gid * factor + uint2(dx, dy), limit)).r);
        }
    }
    pooled.write(float4(marked), gid);
}

// 5. Draw the frame upright and fitted, with the outlines over it.

struct ViewfinderUniforms {
    float2 scale;    // the picture's size as a fraction of the view, for fitting
    float4 matrix;   // YCbCr → RGB: Cr→R, Cb→G, Cr→G, Cb→B
    float4 color;    // the outlines'
    float4 lines;    // xy: one mask texel in frame coordinates; z: how many texels to thicken by (0 = fine)
};

struct ViewfinderVertex {
    float4 position [[position]];
    float2 view;     // 0…1, top-left origin
};

vertex ViewfinderVertex viewfinderVertex(uint vid [[vertex_id]]) {
    float2 corner = float2((vid << 1) & 2, vid & 2);   // one triangle covering the view
    ViewfinderVertex out;
    out.position = float4(corner * 2 - 1, 0, 1);
    out.view = float2(corner.x, 1 - corner.y);
    return out;
}

fragment float4 viewfinderFragment(ViewfinderVertex in [[stage_in]],
                                   texture2d<float> luma [[texture(0)]],
                                   texture2d<float> chroma [[texture(1)]],
                                   texture2d<float> mask [[texture(2)]],
                                   constant ViewfinderUniforms &u [[buffer(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float2 p = (in.view - 0.5) / u.scale + 0.5;
    if (any(p < 0) || any(p > 1)) return float4(0, 0, 0, 1);
    float2 uv = float2(p.y, 1 - p.x);   // frames arrive landscape: turn a quarter clockwise for portrait
    float y = luma.sample(linear, uv).r;
    float2 c = chroma.sample(linear, uv).rg - 0.5;   // Cb, Cr
    float3 rgb = float3(y + u.matrix.x * c.y,
                        y - u.matrix.y * c.x - u.matrix.z * c.y,
                        y + u.matrix.w * c.x);
    float outline;
    int reach = int(u.lines.z);
    if (reach == 0) {
        outline = saturate(mask.sample(linear, uv).r * 2);   // fine: thin lines survive being scaled down
    } else {
        // Bold: the strongest mark nearby, so lines are a few texels wide and stay whole on screen.
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        outline = 0;
        for (int dy = -reach; dy <= reach; dy++) {
            for (int dx = -reach; dx <= reach; dx++) {
                outline = max(outline, mask.sample(nearest, uv + float2(dx, dy) * u.lines.xy).r);
            }
        }
    }
    return float4(mix(saturate(rgb), u.color.rgb, outline), 1);
}
