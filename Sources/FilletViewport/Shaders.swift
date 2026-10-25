// Metal shaders, compiled at runtime with `device.makeLibrary(source:options:)` because
// SwiftPM command-line builds don't compile .metal files. Struct layouts must match
// the Swift mirrors in `GPUTypes.swift` (everything is float4/float4x4/uint-aligned).

enum ShaderSource {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProj;
    float4x4 view;
    float4x4 proj;
    float4 eye;          // xyz world eye, w = 1 perspective / 0 orthographic
    float4 viewport;     // xy drawable size (px), z = pixels per point, w = world units per pixel at target
    float4 forward;      // xyz world view direction, w = camera distance
    float4 target;       // xyz camera target
    float4 bgTop;
    float4 bgBottom;
    float4 keyLight;     // xyz view-space direction towards the light, w = intensity
    float4 fillLight;
    float4 sky;          // hemisphere ambient, rgb, a = intensity
    float4 ground;
    float4 accent;       // selected-face fill, a = amount
    float4 hover;        // hovered-face fill, a = amount
    float4 overhangColor;
    float4 overhang;     // x enabled, y sin(threshold), z bed z
    float4 misc;         // x line pull (perspective fraction), y line pull (ortho world units), z rim strength, w specular
};

// MARK: Background

struct BGOut { float4 position [[position]]; float t; };

vertex BGOut bg_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    BGOut o;
    o.position = float4(p, 1.0, 1.0);
    o.t = p.y * 0.5 + 0.5;
    return o;
}

fragment float4 bg_fragment(BGOut in [[stage_in]], constant FrameUniforms& U [[buffer(1)]]) {
    float t = smoothstep(0.0, 1.0, in.t);
    return float4(mix(U.bgBottom.rgb, U.bgTop.rgb, t), 1.0);
}

// MARK: Meshes

static float4 pullView(float4 v, constant FrameUniforms& U) {
    if (U.eye.w > 0.5) { v.xyz *= (1.0 - U.misc.x); }
    else { v.z += U.misc.y; }
    return v;
}


struct MeshVertex { packed_float3 position; packed_float3 normal; uint face; };

struct MeshDraw {
    float4x4 model;
    float4 color;        // linear rgb, a = opacity
    float4 highlight;    // rgb tint, a = amount
    uint faceStateCount;
    uint flags;          // 1 = overhang, 2 = unlit (flat colour), 4 = pull towards the camera,
                         // 8 = only picked / hovered faces (open-face visual styles)
    float pad0;
    float pad1;
};

struct MeshOut {
    float4 position [[position]];
    float3 worldPos;
    float3 worldNormal;
    float overhang;
    uint face [[flat]];
};

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           const device MeshVertex* verts [[buffer(0)]],
                           constant FrameUniforms& U [[buffer(1)]],
                           constant MeshDraw& D [[buffer(2)]]) {
    MeshVertex v = verts[vid];
    float4 wp = D.model * float4(float3(v.position), 1.0);
    float3 n = normalize((D.model * float4(float3(v.normal), 0.0)).xyz);
    MeshOut o;
    if ((D.flags & 4u) != 0u) {
        o.position = U.proj * pullView(pullView(U.view * wp, U), U);
    } else {
        o.position = U.viewProj * wp;
    }
    o.worldPos = wp.xyz;
    o.worldNormal = n;
    o.face = v.face;
    // Overhang per vertex from the normal: steeper than the threshold below horizontal.
    float oh = 0.0;
    if (U.overhang.x > 0.5 && (D.flags & 1u) != 0u) {
        oh = smoothstep(U.overhang.y - 0.02, U.overhang.y + 0.02, -n.z);
    }
    o.overhang = oh;
    return o;
}

static float3 shade(float3 base, float3 N, float3 worldPos, constant FrameUniforms& U) {
    float3 V = U.eye.w > 0.5 ? normalize(U.eye.xyz - worldPos) : -U.forward.xyz;
    if (dot(N, V) < 0.0) N = -N;
    float3 Nv = normalize((U.view * float4(N, 0.0)).xyz);
    float3 Vv = normalize((U.view * float4(V, 0.0)).xyz);
    float3 Lk = normalize(U.keyLight.xyz);
    float3 Lf = normalize(U.fillLight.xyz);
    // Slightly wrapped diffuse for a soft studio look.
    float dk = saturate((dot(Nv, Lk) + 0.15) / 1.15);
    float df = saturate((dot(Nv, Lf) + 0.25) / 1.25);
    float hemi = N.z * 0.5 + 0.5;
    float3 ambient = mix(U.ground.rgb, U.sky.rgb, hemi) * U.sky.a;
    float3 H = normalize(Lk + Vv);
    float spec = pow(saturate(dot(Nv, H)), 60.0) * U.misc.w;
    float ndv = saturate(dot(Nv, Vv));
    float rim = pow(1.0 - ndv, 4.0) * U.misc.z;
    float3 c = base * (ambient + dk * U.keyLight.w + df * U.fillLight.w);
    c += spec * U.keyLight.w;
    c += rim * mix(U.sky.rgb, float3(1.0), 0.5);
    return c;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]],
                              constant FrameUniforms& U [[buffer(1)]],
                              constant MeshDraw& D [[buffer(2)]],
                              const device uchar* faceState [[buffer(3)]]) {
    float3 base = D.color.rgb;
    base = mix(base, D.highlight.rgb, D.highlight.a);
    uint st = in.face < D.faceStateCount ? uint(faceState[in.face]) : 0u;
    if ((D.flags & 8u) != 0u && st == 0u && D.highlight.a <= 0.0) discard_fragment();
    if (st == 2u) base = mix(base, U.accent.rgb, U.accent.a);
    else if (st == 1u) base = mix(base, U.hover.rgb, U.hover.a);
    float oh = (in.overhang > 0.0 && in.worldPos.z > U.overhang.z + 0.01) ? in.overhang : 0.0;
    base = mix(base, U.overhangColor.rgb, oh * U.overhangColor.a);
    float3 c = (D.flags & 2u) != 0u ? base : shade(base, normalize(in.worldNormal), in.worldPos, U);
    // Overhangs face down into the shadowed hemisphere; add a little emission so they read clearly.
    c += U.overhangColor.rgb * oh * 0.22;
    return float4(c, D.color.a);
}

// MARK: Silhouette outline ("inverted hull" in screen space)
// Back-facing surfaces (by normal, so independent of triangle winding) are pushed
// outwards by a few pixels; they only show where they peek out past the front
// surface, i.e. along silhouettes of curved faces.

struct HullOut { float4 position [[position]]; float3 worldPos; float3 worldNormal; };
struct HullDraw { float4 color; float width; float pad0; float pad1; float pad2; };

vertex HullOut hull_vertex(uint vid [[vertex_id]],
                           const device MeshVertex* verts [[buffer(0)]],
                           constant FrameUniforms& U [[buffer(1)]],
                           constant MeshDraw& D [[buffer(2)]],
                           constant HullDraw& H [[buffer(4)]]) {
    MeshVertex v = verts[vid];
    float3 p = (D.model * float4(float3(v.position), 1.0)).xyz;
    float3 n = normalize((D.model * float4(float3(v.normal), 0.0)).xyz);
    float4 c = U.viewProj * float4(p, 1.0);
    float4 c2 = U.viewProj * float4(p + n * (U.forward.w * 0.01), 1.0);
    float2 d = c2.xy / c2.w - c.xy / c.w;
    float len = length(d * U.viewport.xy);
    d = len > 1e-3 ? normalize(d * U.viewport.xy) : float2(0.0);
    float px = H.width * U.viewport.z;
    c.xy += d * px * 2.0 / U.viewport.xy * c.w;
    HullOut o;
    o.position = c;
    o.worldPos = p;
    o.worldNormal = n;
    return o;
}

fragment float4 hull_fragment(HullOut in [[stage_in]],
                              constant FrameUniforms& U [[buffer(1)]],
                              constant HullDraw& H [[buffer(4)]]) {
    float3 V = U.eye.w > 0.5 ? normalize(U.eye.xyz - in.worldPos) : -U.forward.xyz;
    if (dot(normalize(in.worldNormal), V) > 0.0) discard_fragment();
    return H.color;
}

// MARK: Screen-space thick lines

struct LineSeg { packed_float3 a; packed_float3 b; float dist; uint id; };

struct LineStyle { float4 color; float width; float dash; float pad0; float pad1; };

struct LineDraw {
    float4x4 model;
    LineStyle styles[6];
    uint stateCount;
    uint pull;           // 1 = pull towards the camera (edges on faces)
    float dashPeriod;    // world units
    float pad;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
    float across;        // signed distance from the centre line (px)
    float halfWidth;     // px
    float along;         // world distance along the polyline
    float dash;
};

vertex LineOut line_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device LineSeg* segs [[buffer(0)]],
                           constant FrameUniforms& U [[buffer(1)]],
                           constant LineDraw& D [[buffer(2)]],
                           const device uchar* states [[buffer(3)]]) {
    LineSeg s = segs[iid];
    uint st = s.id < D.stateCount ? uint(states[s.id]) : 0u;
    LineStyle style = D.styles[min(st, 5u)];
    float3 a = (D.model * float4(float3(s.a), 1.0)).xyz;
    float3 b = (D.model * float4(float3(s.b), 1.0)).xyz;
    float4 va = U.view * float4(a, 1.0);
    float4 vb = U.view * float4(b, 1.0);
    if (D.pull != 0u) { va = pullView(va, U); vb = pullView(vb, U); }
    float4 ca = U.proj * va;
    float4 cb = U.proj * vb;
    LineOut o;
    o.color = style.color;
    o.dash = style.dash;
    // Clip against the near plane (z >= 0 in Metal clip space).
    float za = ca.z, zb = cb.z;
    if ((za < 0.0 && zb < 0.0) || style.width <= 0.0) {
        o.position = float4(0.0, 0.0, -1.0, 1.0);
        o.across = 0; o.halfWidth = 0; o.along = 0;
        return o;
    }
    float segLen = length(b - a);
    float distA = s.dist, distB = s.dist + segLen;
    if (za < 0.0) { float t = za / (za - zb); ca = mix(ca, cb, t); distA = mix(distA, distB, t); }
    if (zb < 0.0) { float t = zb / (zb - za); cb = mix(cb, ca, t); distB = mix(distB, distA, t); }
    float2 half_vp = U.viewport.xy * 0.5;
    float2 sa = ca.xy / ca.w * half_vp;
    float2 sb = cb.xy / cb.w * half_vp;
    float2 d = sb - sa;
    float len = length(d);
    d = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 n = float2(-d.y, d.x);
    float hw = style.width * U.viewport.z * 0.5;
    float ext = hw + 1.0;
    bool isB = vid >= 2u;
    float side = (vid & 1u) != 0u ? 1.0 : -1.0;
    float4 c = isB ? cb : ca;
    float2 off = n * side * ext + d * (isB ? 1.0 : -1.0) * hw * 0.5;
    c.xy += off / half_vp * c.w;
    o.position = c;
    o.across = side * ext;
    o.halfWidth = hw;
    o.along = isB ? distB : distA;
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]], constant LineDraw& D [[buffer(2)]]) {
    float a = saturate(in.halfWidth + 0.5 - abs(in.across));
    if (in.dash > 0.5 && D.dashPeriod > 0.0) {
        float ph = fract(in.along / D.dashPeriod);
        if (ph > 0.6) discard_fragment();
    }
    if (a <= 0.0) discard_fragment();
    return float4(in.color.rgb, in.color.a * a);
}

// MARK: Round points

struct PointInst { packed_float3 p; uint state; };
struct PointStyle { float4 color; float4 ring; float size; float ringWidth; float pad0; float pad1; };
struct PointDraw { PointStyle styles[5]; };

struct PointOut {
    float4 position [[position]];
    float2 uv;           // px from centre
    float4 color;
    float4 ring;
    float radius;
    float ringWidth;
};

vertex PointOut point_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device PointInst* pts [[buffer(0)]],
                             constant FrameUniforms& U [[buffer(1)]],
                             constant PointDraw& D [[buffer(2)]]) {
    PointInst p = pts[iid];
    PointStyle s = D.styles[min(p.state, 4u)];
    float4 c = U.viewProj * float4(float3(p.p), 1.0);
    float r = s.size * 0.5 * U.viewport.z;
    float2 corner = float2((vid & 1u) != 0u ? 1.0 : -1.0, vid >= 2u ? 1.0 : -1.0);
    float2 px = corner * (r + 1.5);
    PointOut o;
    o.position = c;
    o.position.xy += px / (U.viewport.xy * 0.5) * c.w;
    if (c.z < 0.0) o.position = float4(0, 0, -1, 1);
    o.uv = px;
    o.color = s.color;
    o.ring = s.ring;
    o.radius = r;
    o.ringWidth = s.ringWidth * U.viewport.z;
    return o;
}

fragment float4 point_fragment(PointOut in [[stage_in]]) {
    float d = length(in.uv);
    float a = saturate(in.radius + 0.5 - d);
    if (a <= 0.0) discard_fragment();
    float inner = saturate(in.radius - in.ringWidth + 0.5 - d);
    float4 c = mix(in.ring, in.color, inner);
    return float4(c.rgb, c.a * a);
}

// MARK: Sketch regions

struct RegionVertex { packed_float3 p; uint state; };
struct RegionDraw { float4 colors[3]; };
struct RegionOut { float4 position [[position]]; float4 color; };

vertex RegionOut region_vertex(uint vid [[vertex_id]],
                               const device RegionVertex* verts [[buffer(0)]],
                               constant FrameUniforms& U [[buffer(1)]],
                               constant RegionDraw& D [[buffer(2)]]) {
    RegionVertex v = verts[vid];
    RegionOut o;
    o.position = U.viewProj * float4(float3(v.p), 1.0);
    o.color = D.colors[min(v.state, 2u)];
    return o;
}

fragment float4 region_fragment(RegionOut in [[stage_in]]) { return in.color; }

// MARK: Soft contact shadows on the bed

struct ShadowDraw {
    float4 center;       // xy centre, z = plane height
    float4 halfSize;     // xy half extents of the footprint
    float4 params;       // x blur margin, y strength
    float4 color;
};

struct ShadowOut { float4 position [[position]]; float2 local; };

vertex ShadowOut shadow_vertex(uint vid [[vertex_id]],
                               constant FrameUniforms& U [[buffer(1)]],
                               constant ShadowDraw& S [[buffer(2)]]) {
    float2 ext = S.halfSize.xy + S.params.x;
    float2 corner = float2((vid & 1u) != 0u ? 1.0 : -1.0, vid >= 2u ? 1.0 : -1.0) * ext;
    float3 w = float3(S.center.xy + corner, S.center.z);
    ShadowOut o;
    o.position = U.proj * pullView(U.view * float4(w, 1.0), U);
    o.local = corner;
    return o;
}

fragment float4 shadow_fragment(ShadowOut in [[stage_in]], constant ShadowDraw& S [[buffer(2)]]) {
    float d;
    if (S.params.z > 0.5) {
        // Elliptical footprint (rounded, organic parts): approximate distance to the ellipse.
        float2 r = max(S.halfSize.xy, float2(1e-3));
        d = (length(in.local / r) - 1.0) * min(r.x, r.y);
    } else {
        float2 q = abs(in.local) - S.halfSize.xy;
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);   // signed distance to the footprint
    }
    float a = 1.0 - smoothstep(-S.params.x * 0.35, S.params.x, d);
    a *= a;
    if (a <= 0.001) discard_fragment();
    return float4(S.color.rgb, S.color.a * a * S.params.y);
}

// MARK: Procedural plane grids (ground, bed, sketch)

struct GridDraw {
    float4 origin;
    float4 axisU;
    float4 axisV;
    float4 extent;       // minU, minV, maxU, maxV
    float4 fill;
    float4 minor;
    float4 major;
    float4 params;       // x minor spacing, y major spacing, z fade radius (0 = none), w line width (pt)
    float4 fadeCenter;   // xyz
    float4 axes;         // x = draw u/v axis lines through origin (1/0), y = thin out when seen from behind
    float4 axisUColor;
    float4 axisVColor;
};

struct GridOut { float4 position [[position]]; float2 uv; float3 world; };

vertex GridOut grid_vertex(uint vid [[vertex_id]],
                           constant FrameUniforms& U [[buffer(1)]],
                           constant GridDraw& G [[buffer(2)]]) {
    float u = (vid & 1u) != 0u ? G.extent.z : G.extent.x;
    float v = vid >= 2u ? G.extent.w : G.extent.y;
    float3 w = G.origin.xyz + G.axisU.xyz * u + G.axisV.xyz * v;
    GridOut o;
    float4 vp = U.view * float4(w, 1.0);
    vp = pullView(vp, U);
    o.position = U.proj * vp;
    o.uv = float2(u, v);
    o.world = w;
    return o;
}

static float gridLines(float2 uv, float spacing, float widthPx) {
    float2 c = uv / spacing;
    float2 fw = max(fwidth(c), float2(1e-6));
    float2 g = abs(fract(c - 0.5) - 0.5) / fw;
    float dist = min(g.x, g.y);
    float a = saturate(widthPx * 0.5 + 0.5 - dist);
    // Fade out when cells get too dense on screen.
    float cellPx = 1.0 / max(fw.x, fw.y);
    return a * smoothstep(3.0, 10.0, cellPx);
}

fragment float4 grid_fragment(GridOut in [[stage_in]],
                              constant FrameUniforms& U [[buffer(1)]],
                              constant GridDraw& G [[buffer(2)]]) {
    float w = G.params.w * U.viewport.z;
    float4 c = G.fill;
    float minorA = G.params.x > 0.0 ? gridLines(in.uv, G.params.x, w) : 0.0;
    float majorA = G.params.y > 0.0 ? gridLines(in.uv, G.params.y, w * 1.25) : 0.0;
    float4 minorC = float4(G.minor.rgb, G.minor.a * minorA);
    float4 majorC = float4(G.major.rgb, G.major.a * majorA);
    c = float4(mix(c.rgb, minorC.rgb, minorC.a), c.a + minorC.a * (1.0 - c.a));
    c = float4(mix(c.rgb, majorC.rgb, majorC.a), c.a + majorC.a * (1.0 - c.a));
    if (G.axes.x > 0.5) {
        float2 fw = max(fwidth(in.uv), float2(1e-6));
        float au = saturate(w * 0.75 + 0.5 - abs(in.uv.y) / fw.y);   // u axis: v == 0
        float av = saturate(w * 0.75 + 0.5 - abs(in.uv.x) / fw.x);
        c = float4(mix(c.rgb, G.axisUColor.rgb, au * G.axisUColor.a), max(c.a, au * G.axisUColor.a));
        c = float4(mix(c.rgb, G.axisVColor.rgb, av * G.axisVColor.a), max(c.a, av * G.axisVColor.a));
    }
    if (G.params.z > 0.0) {
        float d = distance(in.world, G.fadeCenter.xyz);
        c.a *= 1.0 - smoothstep(G.params.z * 0.35, G.params.z, d);
    }
    // Grazing angles: fade so the plane doesn't turn into a solid sheet near the horizon.
    float3 V = U.eye.w > 0.5 ? normalize(U.eye.xyz - in.world) : -U.forward.xyz;
    float3 N = normalize(cross(G.axisU.xyz, G.axisV.xyz));
    c.a *= smoothstep(0.0, 0.12, abs(dot(V, N)));
    // An opaque sheet seen from underneath would hide the model: from below it's tracing paper.
    if (G.axes.y > 0.5 && dot(V, N) < 0.0) c.a *= 0.22;
    if (c.a <= 0.001) discard_fragment();
    return c;
}
"""#
}
