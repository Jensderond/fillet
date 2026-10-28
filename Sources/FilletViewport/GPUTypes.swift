import Foundation
import simd

// Swift mirrors of the shader structs in `Shaders.swift`. Keep layouts in sync.

struct FrameUniforms {
    var viewProj = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var proj = matrix_identity_float4x4
    var eye = SIMD4<Float>()
    var viewport = SIMD4<Float>()
    var forward = SIMD4<Float>()
    var target = SIMD4<Float>()
    var bgTop = SIMD4<Float>()
    var bgBottom = SIMD4<Float>()
    var keyLight = SIMD4<Float>()
    var fillLight = SIMD4<Float>()
    var sky = SIMD4<Float>()
    var ground = SIMD4<Float>()
    var accent = SIMD4<Float>()
    var hover = SIMD4<Float>()
    var overhangColor = SIMD4<Float>()
    var overhang = SIMD4<Float>()
    var misc = SIMD4<Float>()
    var section = SIMD4<Float>()
    var sectionColor = SIMD4<Float>()
}

struct GPUMeshVertex {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var face: UInt32
}

struct MeshDraw {
    var model = matrix_identity_float4x4
    var color = SIMD4<Float>(1, 1, 1, 1)
    var highlight = SIMD4<Float>()
    var faceStateCount: UInt32 = 0
    var flags: UInt32 = 0
    var pad0: Float = 0
    var pad1: Float = 0

    static let overhang: UInt32 = 1
    static let unlit: UInt32 = 2
    static let pull: UInt32 = 4
    static let highlightOnly: UInt32 = 8
}

struct ShadowDraw {
    var center = SIMD4<Float>()
    var halfSize = SIMD4<Float>()
    var params = SIMD4<Float>()
    var color = SIMD4<Float>()
}

struct HullDraw {
    var color = SIMD4<Float>()
    var width: Float = 0
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

/// One screen-space line segment instance.
struct GPULineSeg {
    var ax, ay, az: Float
    var bx, by, bz: Float
    /// Cumulative world length along the polyline at `a` (for dashes).
    var dist: Float
    /// Index into the per-draw state buffer (edge / curve index).
    var id: UInt32

    init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, dist: Float, id: UInt32) {
        ax = a.x; ay = a.y; az = a.z; bx = b.x; by = b.y; bz = b.z
        self.dist = dist; self.id = id
    }
}

struct LineStyle {
    var color = SIMD4<Float>()
    var width: Float = 0
    var dash: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0

    init() {}
    init(_ c: ViewportColor, width: Float, dashed: Bool = false) {
        color = c.linear; self.width = width; dash = dashed ? 1 : 0
    }
}

struct LineDraw {
    var model = matrix_identity_float4x4
    var s0 = LineStyle(), s1 = LineStyle(), s2 = LineStyle(), s3 = LineStyle(), s4 = LineStyle(), s5 = LineStyle()
    var stateCount: UInt32 = 0
    var pull: UInt32 = 0
    var dashPeriod: Float = 0
    var pad: Float = 0

    init(_ s0: LineStyle, _ s1: LineStyle = LineStyle(), _ s2: LineStyle = LineStyle(), _ s3: LineStyle = LineStyle(),
         _ s4: LineStyle = LineStyle(), _ s5: LineStyle = LineStyle()) {
        self.s0 = s0; self.s1 = s1; self.s2 = s2; self.s3 = s3; self.s4 = s4; self.s5 = s5
    }
}

struct GPUPointInst {
    var x, y, z: Float
    var state: UInt32
}

struct PointStyle {
    var color = SIMD4<Float>()
    var ring = SIMD4<Float>()
    var size: Float = 0
    var ringWidth: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0

    init() {}
    init(color: ViewportColor, ring: ViewportColor, size: Float, ringWidth: Float) {
        self.color = color.linear; self.ring = ring.linear; self.size = size; self.ringWidth = ringWidth
    }
}

struct PointDraw {
    var s0 = PointStyle(), s1 = PointStyle(), s2 = PointStyle(), s3 = PointStyle(), s4 = PointStyle()
}

struct GPURegionVertex {
    var x, y, z: Float
    var state: UInt32
}

struct RegionDraw {
    var c0 = SIMD4<Float>(), c1 = SIMD4<Float>(), c2 = SIMD4<Float>()
}

struct GridDraw {
    var origin = SIMD4<Float>()
    var axisU = SIMD4<Float>()
    var axisV = SIMD4<Float>()
    var extent = SIMD4<Float>()
    var fill = SIMD4<Float>()
    var minor = SIMD4<Float>()
    var major = SIMD4<Float>()
    var params = SIMD4<Float>()
    var fadeCenter = SIMD4<Float>()
    var axes = SIMD4<Float>()
    var axisUColor = SIMD4<Float>()
    var axisVColor = SIMD4<Float>()
}

/// CPU reference of the line vertex shader's quad expansion (used by tests and as
/// documentation of the GPU math).
public enum LineExpansion {
    /// Expands segment `a`–`b` (clip-space positions) into the 4 clip-space corners of a
    /// screen-aligned quad `widthPixels` wide (+1 px anti-aliasing margin per side), with
    /// square caps extending half the width. Corner order: a−, a+, b−, b+ (triangle strip).
    /// Returns nil when the segment is entirely behind the near plane.
    public static func quad(a: SIMD4<Float>, b: SIMD4<Float>, widthPixels: Float, viewport: SIMD2<Float>) -> [SIMD4<Float>]? {
        var ca = a, cb = b
        if ca.z < 0 && cb.z < 0 { return nil }
        if ca.z < 0 { let t = ca.z / (ca.z - cb.z); ca = ca + (cb - ca) * t }
        if cb.z < 0 { let t = cb.z / (cb.z - ca.z); cb = cb + (ca - cb) * t }
        let half = viewport * 0.5
        let sa = SIMD2(ca.x, ca.y) / ca.w * half
        let sb = SIMD2(cb.x, cb.y) / cb.w * half
        var d = sb - sa
        let len = simd_length(d)
        d = len > 1e-4 ? d / len : SIMD2(1, 0)
        let n = SIMD2(-d.y, d.x)
        let hw = widthPixels * 0.5
        let ext = hw + 1
        return (0..<4).map { vid in
            let isB = vid >= 2
            let side: Float = vid & 1 != 0 ? 1 : -1
            var c = isB ? cb : ca
            let off = n * side * ext + d * (isB ? 1 : -1) * hw * 0.5
            let o = off / half * c.w
            c.x += o.x; c.y += o.y
            return c
        }
    }
}
