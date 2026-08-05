#include <metal_stdlib>
using namespace metal;

// ===========================================================================
// The canalisation plant's shading — a Metal port of src/60_render.js from
// github.com/aj-dev-smith/canalisation (WebGL2 there, Metal here).
//
// ONE DELIBERATE DIVERGENCE. The original draws an opaque background gradient
// and composites nothing. kiddyproof's overlay is TRANSPARENT — the child is
// looking at the parent's real desktop — so there is no background pass and the
// output is premultiplied alpha instead:
//
//   * tissue (the mesh pass) is opaque and writes coverage 1
//   * veins, needles and cells are ADDITIVE light and write no coverage, so
//     they read as glow lying over whatever is behind them, which is the same
//     compositing every other calm scene in this app uses
//
// The reference packs linear depth into the scene target's alpha for its
// defocus pass. Alpha here is carrying coverage, so depth goes to a second
// colour attachment instead.
// ===========================================================================

// EVERY field is a float4, and that is not cosmetic. `float3` in MSL has a size
// of SIXTEEN bytes, not twelve, so writing this as alternating `float3`/`float`
// pairs does NOT pack a colour and a scalar into one 16-byte slot the way the
// matching Swift SIMD4 does — the scalar lands in the next slot and every field
// after the first is read from the wrong offset. That shipped once: the plant
// rendered flat magenta because `key`, `keyCol`, `ambTop` and `ambBot` were all
// reading fragments of each other.
struct Uniforms {
    float4x4 vp;
    float4 eyeTime;         // xyz eye, w time
    float4 keySway;         // xyz key direction, w sway amount
    float4 keyColFogD;      // xyz key colour, w fog density
    float4 ambTopFogNear;   // xyz ambient sky, w fog near plane
    float4 ambBotPxScale;   // xyz ambient ground, w point-size scale
    float4 fogPad;          // xyz fog colour
};

struct GradeUniforms {
    float4 bloomExposureGrainVignette;
    float4 focusRangeDofTime;
    float4 thresholdPad;
};

// Every pass that draws world geometry displaces it by the same slow field, so
// stems, blades, veins and cells stay welded together while the whole specimen
// breathes. It also does the quiet work of hiding the fact that the geometry
// itself is only rebuilt a few times a second.
static inline float3 sway(float3 p, float t, float amount)
{
    float h = max(p.y, 0.0);
    float amp = amount * h * h * 0.0011;
    float tt = t * 0.00023;
    float a = sin(tt * 1.00 + p.y * 0.26 + p.x * 0.13);
    float b = sin(tt * 0.71 + p.z * 0.23 - p.y * 0.17);
    float c = sin(tt * 1.63 + p.x * 0.44 + p.z * 0.37);
    return p + float3(a + c * 0.22, c * 0.10, b + c * 0.18) * amp;
}

// --- world geometry ---------------------------------------------------------

struct MeshVertex {
    packed_float3 pos;
    packed_float3 nrm;
    packed_float3 col;
    float emis;
};

struct MeshInOut {
    float4 position [[position]];
    float3 wp;
    float3 nrm;
    float3 col;
    float  emis;
};

struct SceneOut {
    float4 colour [[color(0)]];   // rgb radiance, a coverage
    float  depth  [[color(1)]];   // linear distance from the eye, for defocus
};

vertex MeshInOut canal_mesh_vs(uint vid [[vertex_id]],
                               const device MeshVertex *v [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]])
{
    MeshInOut o;
    float3 p = sway(float3(v[vid].pos), u.eyeTime.w, u.keySway.w);
    o.position = u.vp * float4(p, 1.0);
    o.wp = p;
    o.nrm = float3(v[vid].nrm);
    o.col = float3(v[vid].col);
    o.emis = v[vid].emis;
    return o;
}

fragment SceneOut canal_mesh_fs(MeshInOut i [[stage_in]],
                                constant Uniforms &u [[buffer(1)]])
{
    float3 N = normalize(i.nrm);
    float3 V = normalize(u.eyeTime.xyz - i.wp);
    if (dot(N, V) < 0.0) N = -N;
    float d = max(dot(N, u.keySway.xyz), 0.0);
    // light that has passed THROUGH the tissue rather than bounced off it —
    // this is most of why a leaf reads as a leaf
    float back = pow(max(dot(-N, u.keySway.xyz), 0.0), 2.0);
    float rim = pow(1.0 - max(dot(N, V), 0.0), 3.0);
    float3 amb = mix(u.ambBotPxScale.xyz, u.ambTopFogNear.xyz, N.y * 0.5 + 0.5);
    float3 c = i.col * (amb + u.keyColFogD.xyz * d * 0.9)
             + i.col * u.keyColFogD.xyz * back * 0.55
             + rim * u.ambTopFogNear.xyz * 0.7;
    c += i.col * i.emis * 3.0;
    // fog measured from the near face of the subject, not from the eye, so it
    // reads the same whether the camera is close in or pulled right back
    float dist = length(i.wp - u.eyeTime.xyz);
    float f = 1.0 - exp(-max(0.0, dist - u.ambTopFogNear.w) * u.keyColFogD.w);
    c = mix(c, u.fogPad.xyz, clamp(f, 0.0, 1.0) * 0.80);

    SceneOut o;
    o.colour = float4(c, 1.0);
    o.depth = dist;
    return o;
}

// --- vein ribbons and PIN needles (additive light) --------------------------

struct LineVertex {
    packed_float3 pos;
    packed_float3 col;
    float emis;
};

struct LineInOut {
    float4 position [[position]];
    float3 col;
    float  emis;
    float3 wp;
};

vertex LineInOut canal_line_vs(uint vid [[vertex_id]],
                               const device LineVertex *v [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]])
{
    LineInOut o;
    float3 p = sway(float3(v[vid].pos), u.eyeTime.w, u.keySway.w);
    o.position = u.vp * float4(p, 1.0);
    o.col = float3(v[vid].col);
    o.emis = v[vid].emis;
    o.wp = p;
    return o;
}

fragment float4 canal_line_fs(LineInOut i [[stage_in]],
                              constant Uniforms &u [[buffer(1)]])
{
    float3 c = i.col * i.emis;
    float f = 1.0 - exp(-max(0.0, length(i.wp - u.eyeTime.xyz) - u.ambTopFogNear.w) * u.keyColFogD.w);
    c *= (1.0 - clamp(f, 0.0, 1.0) * 0.8);
    return float4(c, 0.0);   // additive: contributes light, never coverage
}

// --- cells and travelling auxin, as round point sprites ---------------------

struct PointVertex {
    packed_float3 pos;
    packed_float3 col;
    float size;
};

struct PointInOut {
    float4 position [[position]];
    float  size [[point_size]];
    float3 col;
};

vertex PointInOut canal_point_vs(uint vid [[vertex_id]],
                                 const device PointVertex *v [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]])
{
    PointInOut o;
    float4 cp = u.vp * float4(sway(float3(v[vid].pos), u.eyeTime.w, u.keySway.w), 1.0);
    o.position = cp;
    o.size = clamp(v[vid].size * u.ambBotPxScale.w / max(0.001, cp.w), 1.0, 64.0);
    o.col = float3(v[vid].col);
    return o;
}

fragment float4 canal_point_fs(PointInOut i [[stage_in]],
                               float2 pc [[point_coord]])
{
    float2 d = pc * 2.0 - 1.0;
    float r = dot(d, d);
    if (r > 1.0) discard_fragment();
    float a = smoothstep(1.0, 0.15, r);
    return float4(i.col * a * 1.12, 0.0);
}

// --- fullscreen passes ------------------------------------------------------

struct QuadInOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadInOut canal_quad_vs(uint vid [[vertex_id]])
{
    QuadInOut o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.uv = p;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

fragment float4 canal_bright_fs(QuadInOut i [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                constant GradeUniforms &g [[buffer(0)]])
{
    float3 c = src.sample(linearClamp, i.uv).rgb;
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    return float4(c * smoothstep(g.thresholdPad.x, g.thresholdPad.x * 2.2, l), 1.0);
}

fragment float4 canal_blur_fs(QuadInOut i [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant float2 &dir [[buffer(0)]])
{
    float4 s  = src.sample(linearClamp, i.uv) * 0.2270270270;
    s += src.sample(linearClamp, i.uv + dir * 1.3846153846) * 0.3162162162;
    s += src.sample(linearClamp, i.uv - dir * 1.3846153846) * 0.3162162162;
    s += src.sample(linearClamp, i.uv + dir * 3.2307692308) * 0.0702702703;
    s += src.sample(linearClamp, i.uv - dir * 3.2307692308) * 0.0702702703;
    return s;
}

static inline float3 aces(float3 x)
{
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

static inline float hash21(float2 p)
{
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

fragment float4 canal_comp_fs(QuadInOut i [[stage_in]],
                              texture2d<float> scene [[texture(0)]],
                              texture2d<float> bloom [[texture(1)]],
                              texture2d<float> dof   [[texture(2)]],
                              texture2d<float> depth [[texture(3)]],
                              constant GradeUniforms &g [[buffer(0)]])
{
    float2 uv = i.uv;
    float4 sc = scene.sample(linearClamp, uv);
    float3 c = sc.rgb;
    float  a = sc.a;

    // defocus: the plane the camera is looking at stays sharp and everything in
    // front of and behind it softens
    float zdep = depth.sample(linearClamp, uv).r;
    float coc = clamp(abs(zdep - g.focusRangeDofTime.x) / max(0.001, g.focusRangeDofTime.y), 0.0, 1.0);
    coc = coc * coc * (3.0 - 2.0 * coc) * g.focusRangeDofTime.z;
    float4 df = dof.sample(linearClamp, uv);
    c = mix(c, df.rgb, coc);
    a = mix(a, df.a, coc);          // an out-of-focus edge softens its coverage too

    float3 b = bloom.sample(linearClamp, uv).rgb;
    c += b * g.bloomExposureGrainVignette.x;            // bloom is light, so it never adds coverage

    // a touch of lateral chroma, strongest at the edges
    float2 d = uv - 0.5;
    float ca = 0.0016 * dot(d, d) * 4.0;
    c.r = mix(scene.sample(linearClamp, uv + d * ca).r, dof.sample(linearClamp, uv + d * ca).r, coc)
        + bloom.sample(linearClamp, uv + d * ca).r * g.bloomExposureGrainVignette.x;
    c.b = mix(scene.sample(linearClamp, uv - d * ca).b, dof.sample(linearClamp, uv - d * ca).b, coc)
        + bloom.sample(linearClamp, uv - d * ca).b * g.bloomExposureGrainVignette.x;

    c *= g.bloomExposureGrainVignette.y;
    c = aces(c);
    c *= 1.0 - g.bloomExposureGrainVignette.w * dot(d, d) * 1.6;
    c += (hash21(uv * float2(1024.0, 768.0) + fract(g.focusRangeDofTime.w * 0.001)) - 0.5) * g.bloomExposureGrainVignette.z;
    c = pow(max(c, 0.0), float3(1.0 / 2.2));

    // The layer composites premultiplied: dst = src.rgb + dst.rgb * (1 - src.a).
    // `c` is already the light leaving this pixel toward the viewer and `a` is
    // how much of the desktop behind it is occluded, so the pair is premultiplied
    // by construction — where the plant is solid a is 1 and c replaces the
    // desktop; where only glow landed a is 0 and c adds to it.
    return float4(c, clamp(a, 0.0, 1.0));
}
