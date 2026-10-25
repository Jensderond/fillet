import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore
import simd
import FilletKernel

/// Errors from setting up the Metal renderer.
public struct ViewportRendererError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// GPU buffers for one body mesh, uploaded once per mesh version.
final class GPUBody {
    let key: MeshKey
    let vertexBuffer: MTLBuffer?
    let indexBuffer: MTLBuffer?
    let indexCount: Int
    let edgeBuffer: MTLBuffer?
    let segmentCount: Int
    let faceCount: Int
    let edgeCount: Int
    let bounds: Bounds3?
    var faceStates: MTLBuffer?
    var edgeStates: MTLBuffer?

    init(device: MTLDevice, mesh: Mesh, key: MeshKey) {
        self.key = key
        let g = GPUBody.build(mesh)
        vertexBuffer = g.vertices.isEmpty ? nil : g.vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        indexBuffer = g.indices.isEmpty ? nil : g.indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        indexCount = g.indices.count
        let segs = GPUBody.segments(mesh.edges)
        edgeBuffer = segs.isEmpty ? nil : segs.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        segmentCount = segs.count
        faceCount = Int((mesh.triangleFaces.max() ?? -1) + 1)
        edgeCount = mesh.edges.count
        bounds = mesh.bounds3
    }

    /// Vertices carrying their B-rep face index. Vertices shared between triangles of
    /// different faces are duplicated so the face id can be a per-vertex attribute.
    static func build(_ mesh: Mesh) -> (vertices: [GPUMeshVertex], indices: [UInt32]) {
        let triCount = mesh.indices.count / 3
        let vcount = mesh.positions.count
        guard triCount > 0, vcount > 0 else { return ([], []) }
        let hasNormals = mesh.normals.count == vcount
        var vertexFace = [Int32](repeating: -1, count: vcount)
        var conflict = false
        for t in 0..<triCount {
            let f = t < mesh.triangleFaces.count ? mesh.triangleFaces[t] : 0
            for k in 0..<3 {
                let v = Int(mesh.indices[3 * t + k])
                if vertexFace[v] == -1 { vertexFace[v] = f } else if vertexFace[v] != f { conflict = true }
            }
        }
        // Flat normals as a fallback when the mesh has none.
        var flat: [SIMD3<Float>] = []
        if !hasNormals {
            flat = .init(repeating: .zero, count: vcount)
            for t in 0..<triCount {
                let a = mesh.positions[Int(mesh.indices[3 * t])], b = mesh.positions[Int(mesh.indices[3 * t + 1])],
                    c = mesh.positions[Int(mesh.indices[3 * t + 2])]
                let n = simd_cross(b - a, c - a)
                for k in 0..<3 { flat[Int(mesh.indices[3 * t + k])] += n }
            }
        }
        func vertex(_ v: Int, face: Int32) -> GPUMeshVertex {
            let p = mesh.positions[v]
            var n = hasNormals ? mesh.normals[v] : flat[v]
            let l = simd_length(n)
            n = l > 0 ? n / l : SIMD3(0, 0, 1)
            return GPUMeshVertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z, face: UInt32(bitPattern: max(face, 0)))
        }
        if !conflict {
            let verts = (0..<vcount).map { vertex($0, face: vertexFace[$0]) }
            return (verts, mesh.indices)
        }
        var verts: [GPUMeshVertex] = []
        verts.reserveCapacity(vcount + vcount / 4)
        var map = [UInt64: UInt32]()
        var indices = [UInt32]()
        indices.reserveCapacity(mesh.indices.count)
        for t in 0..<triCount {
            let f = t < mesh.triangleFaces.count ? mesh.triangleFaces[t] : 0
            for k in 0..<3 {
                let v = Int(mesh.indices[3 * t + k])
                let key = UInt64(v) << 32 | UInt64(UInt32(bitPattern: f))
                if let i = map[key] {
                    indices.append(i)
                } else {
                    let i = UInt32(verts.count)
                    verts.append(vertex(v, face: f))
                    map[key] = i
                    indices.append(i)
                }
            }
        }
        return (verts, indices)
    }

    /// Line segments for polylines, with cumulative length for dashing.
    static func segments(_ polylines: [[SIMD3<Float>]], ids: [UInt32]? = nil) -> [GPULineSeg] {
        var out: [GPULineSeg] = []
        out.reserveCapacity(polylines.reduce(0) { $0 + max($1.count - 1, 0) })
        for (i, poly) in polylines.enumerated() where poly.count >= 2 {
            var dist: Float = 0
            let id = ids?[i] ?? UInt32(i)
            for k in 1..<poly.count {
                out.append(GPULineSeg(poly[k - 1], poly[k], dist: dist, id: id))
                dist += simd_distance(poly[k - 1], poly[k])
            }
        }
        return out
    }
}

/// Metal renderer for a `ViewportScene`. Owned by the viewport view, or used directly
/// for offscreen snapshots.
///
/// Meshes are uploaded only when a body's `(id, version, fingerprint)` changes, so
/// redrawing for camera motion only re-encodes draw calls with small inline uniforms.
@MainActor
public final class ViewportRenderer: NSObject {
    public static let colorFormat: MTLPixelFormat = .bgra8Unorm_srgb
    public static let depthFormat: MTLPixelFormat = .depth32Float
    public static let sampleCount = 4

    public let device: MTLDevice
    let queue: MTLCommandQueue

    private let pBackground: MTLRenderPipelineState
    private let pMeshOpaque: MTLRenderPipelineState
    private let pMeshBlend: MTLRenderPipelineState
    private let pMeshDepth: MTLRenderPipelineState
    private let pLine: MTLRenderPipelineState
    private let pPoint: MTLRenderPipelineState
    private let pRegion: MTLRenderPipelineState
    private let pGrid: MTLRenderPipelineState
    private let pHull: MTLRenderPipelineState
    private let pShadow: MTLRenderPipelineState
    private let dsGreater: MTLDepthStencilState
    private let dsWrite: MTLDepthStencilState
    private let dsTest: MTLDepthStencilState
    private let dsLess: MTLDepthStencilState
    private let dsAlways: MTLDepthStencilState
    private let zeroBuffer: MTLBuffer
    private let cone: GPUBody

    /// The scene being drawn.
    public private(set) var scene = ViewportScene()
    /// The camera used for the next frame.
    public var camera = Camera.default
    public var palette: ViewportPalette = .light { didSet { if palette != oldValue { overlaysDirty = true } } }
    /// Hover target from the pointer, shown when `scene.hover` is nil.
    public var pointerHover: PickTarget? {
        didSet { if pointerHover != oldValue { statesDirty = true; overlaysDirty = true } }
    }
    /// Handle currently being dragged (drawn highlighted).
    public var activeHandleID: String?

    private var bodies: [UUID: GPUBody] = [:]
    private var sceneBounds: Bounds3?
    private var bodiesDirty = true
    private var statesDirty = true
    private var overlaysDirty = true

    // Overlay buffers.
    private var sketchSegs: MTLBuffer?, sketchSegCount = 0
    private var sketchCurveStates: MTLBuffer?, sketchCurveCount = 0
    private var sketchPoints: MTLBuffer?, sketchPointCount = 0
    private var regionVerts: MTLBuffer?, regionVertCount = 0
    private var plateSegs: MTLBuffer?, plateSegCount = 0
    private var plateStates: MTLBuffer?
    private var measureSegs: MTLBuffer?, measureSegCount = 0
    private var measurePoints: MTLBuffer?, measurePointCount = 0
    private var highlightSegs: MTLBuffer?, highlightSegCount = 0
    private var highlightStates: MTLBuffer?, highlightCount = 0

    // Camera animation.
    private struct Animation { var from: Camera; var to: Camera; var start: CFTimeInterval; var duration: Double }
    private var animation: Animation?
    /// Called on every animated camera step and once more with `finished == true`.
    public var onCameraAnimation: ((Camera, _ finished: Bool) -> Void)?
    /// The view this renderer draws into (used to un-pause during animations).
    public weak var view: MTKView?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw ViewportRendererError(description: "Metal is not available") }
        self.device = device
        guard let q = device.makeCommandQueue() else { throw ViewportRendererError(description: "No command queue") }
        queue = q
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: ShaderSource.source, options: nil)
        } catch {
            throw ViewportRendererError(description: "Shader compilation failed: \(error)")
        }

        func pipeline(_ v: String, _ f: String, blend: Bool, writeColor: Bool = true) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = Self.depthFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.colorFormat
            if !writeColor { c.writeMask = [] }
            if blend {
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pBackground = try pipeline("bg_vertex", "bg_fragment", blend: false)
        pMeshOpaque = try pipeline("mesh_vertex", "mesh_fragment", blend: false)
        pMeshBlend = try pipeline("mesh_vertex", "mesh_fragment", blend: true)
        pMeshDepth = try pipeline("mesh_vertex", "mesh_fragment", blend: false, writeColor: false)
        pLine = try pipeline("line_vertex", "line_fragment", blend: true)
        pPoint = try pipeline("point_vertex", "point_fragment", blend: true)
        pRegion = try pipeline("region_vertex", "region_fragment", blend: true)
        pGrid = try pipeline("grid_vertex", "grid_fragment", blend: true)
        pHull = try pipeline("hull_vertex", "hull_fragment", blend: true)
        pShadow = try pipeline("shadow_vertex", "shadow_fragment", blend: true)

        func depth(_ cmp: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = cmp
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        dsWrite = depth(.less, write: true)
        dsTest = depth(.lessEqual, write: false)
        dsLess = depth(.less, write: false)
        dsAlways = depth(.always, write: false)
        dsGreater = depth(.greater, write: false)
        zeroBuffer = device.makeBuffer(length: 64, options: .storageModeShared)!
        let coneMesh = DemoMeshes.cone(radius: Float(HandleMetrics.headRadius / HandleMetrics.headLength))
        cone = GPUBody(device: device, mesh: coneMesh, key: MeshKey(SceneBody(id: UUID(), mesh: coneMesh)))
        super.init()
    }

    // MARK: Scene updates

    /// Replaces the scene. Mesh buffers are re-uploaded only for bodies whose mesh changed.
    public func update(scene newScene: ViewportScene) {
        scene = newScene
        bodiesDirty = true
        statesDirty = true
        overlaysDirty = true
    }

    /// Identity of the cached GPU buffers for a body (tests).
    func gpuBodyIdentity(_ id: UUID) -> ObjectIdentifier? { bodies[id].map(ObjectIdentifier.init) }

    /// The hover target actually displayed.
    public var effectiveHover: PickTarget? { scene.hover ?? pointerHover }

    /// Uploads whatever changed since the last frame.
    func prepare() {
        if bodiesDirty {
            bodiesDirty = false
            var keep = Set<UUID>()
            for b in scene.bodies { sync(b); keep.insert(b.id) }
            for b in scene.previews { sync(b); keep.insert(b.id) }
            if keep.count != bodies.count { bodies = bodies.filter { keep.contains($0.key) } }
            sceneBounds = computeBounds()
        }
        if statesDirty {
            statesDirty = false
            rebuildStates()
        }
        if overlaysDirty {
            overlaysDirty = false
            rebuildOverlays()
        }
    }

    /// Scene bounds from cached per-body bounds (avoids touching vertices per update).
    private func computeBounds() -> Bounds3? {
        var b: Bounds3?
        func add(_ o: Bounds3?) { if let o { b = b.map { $0.union(o) } ?? o } }
        for x in scene.bodies where x.visible { add(bodies[x.id]?.bounds) }
        for x in scene.previews where x.visible { add(bodies[x.id]?.bounds) }
        var rest = scene
        rest.bodies = []
        rest.previews = []
        add(rest.bounds)
        return b
    }

    private func sync(_ body: SceneBody) {
        let key = MeshKey(body)
        if let g = bodies[body.id], g.key == key { return }
        bodies[body.id] = GPUBody(device: device, mesh: body.mesh, key: key)
        statesDirty = true
    }

    private func rebuildStates() {
        var faceMarks: [UUID: [Int: UInt8]] = [:]
        var edgeMarks: [UUID: [Int: UInt8]] = [:]
        for t in scene.selection {
            switch t {
            case .face(let b, let i): faceMarks[b, default: [:]][i] = 2
            case .edge(let b, let i): edgeMarks[b, default: [:]][i] = 2
            default: break
            }
        }
        switch effectiveHover {
        case .face(let b, let i)? where faceMarks[b]?[i] == nil: faceMarks[b, default: [:]][i] = 1
        case .edge(let b, let i)? where edgeMarks[b]?[i] == nil: edgeMarks[b, default: [:]][i] = 1
        default: break
        }
        for (id, g) in bodies {
            g.faceStates = stateBuffer(faceMarks[id], count: g.faceCount)
            g.edgeStates = stateBuffer(edgeMarks[id], count: g.edgeCount)
        }
    }

    private func stateBuffer(_ marks: [Int: UInt8]?, count: Int) -> MTLBuffer? {
        guard let marks, !marks.isEmpty, count > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        for (i, v) in marks where i >= 0 && i < count { bytes[i] = v }
        return device.makeBuffer(bytes: bytes, length: max(count, 4), options: .storageModeShared)
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    private func rebuildOverlays() {
        let hover = effectiveHover
        // Sketch.
        sketchSegs = nil; sketchSegCount = 0; sketchCurveStates = nil; sketchCurveCount = 0
        sketchPoints = nil; sketchPointCount = 0; regionVerts = nil; regionVertCount = 0
        if let s = scene.sketch {
            let plane = s.plane
            func w(_ p: SIMD2<Double>) -> SIMD3<Float> { plane.point(p).float }
            var polylines: [[SIMD3<Float>]] = []
            var states: [UInt8] = []
            for c in s.curves {
                var pts = c.points.map(w)
                if c.closed, let f = pts.first { pts.append(f) }
                polylines.append(pts)
                var st = c.style
                if st == .construction, scene.selection.contains(.sketchShape(c.shapeID)) {
                    st = .selectedConstruction
                } else if st != .construction && st != .preview && st != .selectedConstruction {
                    if scene.selection.contains(.sketchShape(c.shapeID)) { st = .selected }
                    else if hover == .sketchShape(c.shapeID), st == .normal { st = .hover }
                }
                states.append(st.rawValue)
            }
            let segs = GPUBody.segments(polylines)
            sketchSegs = makeBuffer(segs); sketchSegCount = segs.count
            sketchCurveStates = makeBuffer(states); sketchCurveCount = states.count
            let pts = s.points.map { p -> GPUPointInst in
                let q = w(p.position)
                var st = p.style
                if scene.selection.contains(.sketchPoint(shape: p.shapeID, index: p.index)) { st = .selected }
                else if hover == .sketchPoint(shape: p.shapeID, index: p.index), st == .normal { st = .hover }
                return GPUPointInst(x: q.x, y: q.y, z: q.z, state: UInt32(st.rawValue))
            }
            sketchPoints = makeBuffer(pts); sketchPointCount = pts.count
            var rv: [GPURegionVertex] = []
            for r in s.regions {
                let sel = r.selected || scene.selection.contains(.region(r.index))
                let hov = r.hover || hover == .region(r.index)
                let st: UInt32 = sel ? 2 : (hov ? 1 : 0)
                for p in r.triangles { let q = w(p); rv.append(GPURegionVertex(x: q.x, y: q.y, z: q.z, state: st)) }
            }
            regionVerts = makeBuffer(rv); regionVertCount = rv.count
        }
        // Plate outline and origin marker.
        var plateLines: [[SIMD3<Float>]] = []
        var plateIDs: [UInt32] = []
        let markerLen: Float
        if let p = scene.plate {
            let lo = SIMD2<Float>(p.minXY), hi = SIMD2<Float>(p.maxXY)
            plateLines.append([SIMD3(lo.x, lo.y, 0), SIMD3(hi.x, lo.y, 0), SIMD3(hi.x, hi.y, 0), SIMD3(lo.x, hi.y, 0), SIMD3(lo.x, lo.y, 0)])
            plateIDs.append(3)
            markerLen = Float(min(p.size.x, p.size.y)) * 0.06
        } else {
            markerLen = 10
        }
        plateLines += [[.zero, SIMD3(markerLen, 0, 0)], [.zero, SIMD3(0, markerLen, 0)]]
        plateIDs += [0, 1]
        let ps = GPUBody.segments(plateLines, ids: plateIDs)
        plateSegs = makeBuffer(ps); plateSegCount = ps.count
        plateStates = makeBuffer([UInt8]([0, 1, 2, 3]))
        // Picked-edge highlights: one id per polyline, state 1 = dashed.
        let hl = scene.edgeHighlights.filter { $0.points.count >= 2 }
        let hs = GPUBody.segments(hl.map { $0.points.map(\.float) })
        highlightSegs = makeBuffer(hs); highlightSegCount = hs.count
        highlightStates = makeBuffer(hl.map { UInt8($0.dashed ? 1 : 0) }); highlightCount = hl.count
        // Measures.
        let lined = scene.measures.filter(\.showsLine)
        let ms = GPUBody.segments(lined.map { [$0.from.float, $0.to.float] }, ids: lined.map { _ in 0 })
        measureSegs = makeBuffer(ms); measureSegCount = ms.count
        let mp = lined.flatMap { m in [m.from.float, m.to.float].map { GPUPointInst(x: $0.x, y: $0.y, z: $0.z, state: 0) } }
        measurePoints = makeBuffer(mp); measurePointCount = mp.count
    }

    // MARK: Camera animation

    /// Animates the camera to `target` (ease-in-out). `onCameraAnimation` reports progress.
    public func animateCamera(to target: Camera, duration: Double = 0.35) {
        guard duration > 0, !camera.isApproximatelyEqual(to: target) else {
            camera = target
            onCameraAnimation?(target, true)
            setNeedsDisplay()
            return
        }
        animation = Animation(from: camera, to: target, start: CACurrentMediaTime(), duration: duration)
        if let v = view {
            v.enableSetNeedsDisplay = false
            v.isPaused = false
        }
    }

    /// Whether a camera animation is running.
    public var isAnimating: Bool { animation != nil }

    /// Advances a running animation by wall-clock time without drawing. Animations
    /// normally advance per frame, but an occluded window gets no frames; this lets
    /// the camera still arrive so picking and labels never use a stale camera.
    public func advanceAnimationWithoutDrawing() {
        stepAnimation()
    }

    /// Cancels a running animation, leaving the camera where it is.
    public func cancelAnimation() {
        guard animation != nil else { return }
        animation = nil
        pauseView()
    }

    private func stepAnimation() {
        guard let a = animation else { return }
        let t = min(max((CACurrentMediaTime() - a.start) / a.duration, 0), 1)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        if t >= 1 {
            camera = a.to
            animation = nil
            onCameraAnimation?(camera, true)
            pauseView()
        } else {
            camera = Camera.interpolate(a.from, a.to, t: e)
            onCameraAnimation?(camera, false)
        }
    }

    private func pauseView() {
        guard let v = view else { return }
        v.isPaused = true
        v.enableSetNeedsDisplay = true
    }

    /// Requests a redraw of the attached view.
    public func setNeedsDisplay() {
        guard let v = view else { return }
        #if os(macOS)
        v.needsDisplay = true
        #else
        v.setNeedsDisplay()
        #endif
    }

    // MARK: Encoding

    private func frameUniforms(pixelSize: SIMD2<Float>, pixelsPerPoint: Float) -> FrameUniforms {
        let pal = palette
        let cam = camera
        let aspect = Double(pixelSize.x / max(pixelSize.y, 1))
        let view = cam.viewMatrixD
        let proj = cam.projectionMatrixD(aspect: aspect, bounds: sceneBounds)
        var u = FrameUniforms()
        u.view = Mat.float(view)
        u.proj = Mat.float(proj)
        u.viewProj = Mat.float(proj * view)
        u.eye = SIMD4(cam.eye.float, cam.projection == .perspective ? 1 : 0)
        let pointSize = CGSize(width: Double(pixelSize.x / pixelsPerPoint), height: Double(pixelSize.y / pixelsPerPoint))
        let wpp = cam.worldUnitsPerPoint(viewSize: pointSize)
        u.viewport = SIMD4(pixelSize.x, pixelSize.y, pixelsPerPoint, Float(wpp) / pixelsPerPoint)
        u.forward = SIMD4(cam.forward.float, Float(cam.distance))
        u.target = SIMD4(cam.target.float, 0)
        u.bgTop = pal.backgroundTop.linear
        u.bgBottom = pal.backgroundBottom.linear
        u.keyLight = SIMD4(simd_normalize(SIMD3<Float>(-0.45, 0.6, 0.66)), pal.key)
        u.fillLight = SIMD4(simd_normalize(SIMD3<Float>(0.7, -0.2, 0.5)), pal.fill)
        u.sky = SIMD4(SIMD3(pal.skyLight.linear.x, pal.skyLight.linear.y, pal.skyLight.linear.z), pal.ambient)
        u.ground = pal.groundLight.linear
        u.accent = pal.selectionFill.linear
        u.hover = pal.hoverFill.linear
        if let o = scene.overhang {
            u.overhangColor = SIMD4(SIMD3(o.color.linear.x, o.color.linear.y, o.color.linear.z), 0.85)
            u.overhang = SIMD4(1, Float(sin(o.thresholdDegrees * .pi / 180)), Float(o.bedZ), 0)
        }
        u.misc = SIMD4(0.0008, Float(cam.distance * 0.0008), pal.rim, pal.specular)
        return u
    }

    /// Encodes the whole scene into `enc`. `pixelSize` is the drawable size.
    func encode(_ enc: MTLRenderCommandEncoder, pixelSize: SIMD2<Float>, pixelsPerPoint: Float) {
        var U = frameUniforms(pixelSize: pixelSize, pixelsPerPoint: pixelsPerPoint)
        let pal = palette
        let hover = effectiveHover
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.none)
        enc.setVertexBytes(&U, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&U, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        // Background.
        enc.setRenderPipelineState(pBackground)
        enc.setDepthStencilState(dsAlways)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Opaque bodies.
        enc.setRenderPipelineState(pMeshOpaque)
        enc.setDepthStencilState(dsWrite)
        for b in scene.bodies where b.visible && b.opacity >= 0.999 {
            drawMesh(enc, body: b, hover: hover, overhang: true)
        }
        // Ground grid and bed (after opaque bodies so they occlude it, before outlines so
        // silhouettes draw on top of the bed).
        drawGround(enc, U: U)

        // Silhouettes of curved faces.
        enc.setRenderPipelineState(pHull)
        enc.setDepthStencilState(dsTest)
        var hull = HullDraw()
        hull.color = pal.edge.linear
        hull.width = 1.3
        enc.setVertexBytes(&hull, length: MemoryLayout<HullDraw>.stride, index: 4)
        enc.setFragmentBytes(&hull, length: MemoryLayout<HullDraw>.stride, index: 4)
        for b in scene.bodies where b.visible && b.opacity >= 0.999 && b.showsEdges {
            drawMesh(enc, body: b, hover: hover, overhang: false)
        }
        // Their edges.
        enc.setRenderPipelineState(pLine)
        enc.setDepthStencilState(dsTest)
        let edgeHover = LineStyle(pal.hover, width: 2.6)
        let edgeSel = LineStyle(pal.accent, width: 3.0)
        for b in scene.bodies where b.visible && b.opacity >= 0.999 && b.showsEdges {
            var d = LineDraw(LineStyle(pal.edge, width: 1.4), edgeHover, edgeSel)
            d.pull = 1
            drawEdges(enc, id: b.id, draw: &d)
        }
        drawEdgeHighlights(enc, U: U, pixelsPerPoint: pixelsPerPoint)

        // Translucent bodies and previews: depth pre-pass so only the front layer blends.
        func drawTranslucent(_ b: SceneBody, xray: Bool) {
            if xray {
                // Parts hidden inside/behind opaque bodies, faintly.
                enc.setRenderPipelineState(pMeshBlend)
                enc.setDepthStencilState(dsGreater)
                drawMesh(enc, body: b, hover: hover, overhang: false, alphaScale: 0.35, pull: true)
            }
            enc.setRenderPipelineState(pMeshDepth)
            enc.setDepthStencilState(dsWrite)
            drawMesh(enc, body: b, hover: hover, overhang: false)
            enc.setRenderPipelineState(pMeshBlend)
            enc.setDepthStencilState(dsTest)
            drawMesh(enc, body: b, hover: hover, overhang: false)
            if b.showsEdges {
                let c = b.color.map { ViewportColor($0.r * 0.55, $0.g * 0.55, $0.b * 0.55, 0.8) } ?? pal.previewEdge
                var d = LineDraw(LineStyle(c, width: 1.2), edgeHover, edgeSel)
                d.pull = 1
                enc.setRenderPipelineState(pLine)
                drawEdges(enc, id: b.id, draw: &d)
            }
        }
        for b in scene.bodies where b.visible && b.opacity < 0.999 { drawTranslucent(b, xray: false) }
        for b in scene.previews where b.visible { drawTranslucent(b, xray: true) }

        // Sketch overlay.
        if let s = scene.sketch { drawSketch(enc, sketch: s, U: U) }

        // Measures.
        if measureSegCount > 0, let buf = measureSegs {
            enc.setRenderPipelineState(pLine)
            enc.setDepthStencilState(dsAlways)
            var d = LineDraw(LineStyle(pal.measure, width: 1.5, dashed: true))
            d.dashPeriod = U.viewport.w * pixelsPerPoint * 9
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.setFragmentBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.setVertexBuffer(zeroBuffer, offset: 0, index: 3)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: measureSegCount)
        }
        if measurePointCount > 0, let buf = measurePoints {
            enc.setRenderPipelineState(pPoint)
            enc.setDepthStencilState(dsAlways)
            var d = PointDraw()
            d.s0 = PointStyle(color: pal.measure, ring: pal.sketchPointRing, size: 7, ringWidth: 1.5)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&d, length: MemoryLayout<PointDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: measurePointCount)
        }

        // Handles.
        if !scene.handles.isEmpty { drawHandles(enc, U: U, pixelsPerPoint: pixelsPerPoint, hover: hover) }
    }

    private func drawMesh(_ enc: MTLRenderCommandEncoder, body b: SceneBody, hover: PickTarget?, overhang: Bool,
                          alphaScale: Float = 1, pull: Bool = false) {
        guard let g = bodies[b.id], let vb = g.vertexBuffer, let ib = g.indexBuffer else { return }
        var d = MeshDraw()
        let base = (b.color ?? palette.body)
        d.color = SIMD4(SIMD3(base.linear.x, base.linear.y, base.linear.z), b.opacity * (b.color?.a ?? 1) * alphaScale)
        var hl = b.highlight
        if scene.selection.contains(.body(b.id)) { hl = .selected } else if hl == .none, hover == .body(b.id) { hl = .hover }
        switch hl {
        case .none: break
        case .hover: d.highlight = SIMD4(SIMD3(palette.hover.linear.x, palette.hover.linear.y, palette.hover.linear.z), 0.25)
        case .selected: d.highlight = SIMD4(SIMD3(palette.accent.linear.x, palette.accent.linear.y, palette.accent.linear.z), 0.45)
        }
        if overhang && scene.overhang != nil { d.flags |= MeshDraw.overhang }
        if pull { d.flags |= MeshDraw.pull }
        if let fs = g.faceStates {
            d.faceStateCount = UInt32(g.faceCount)
            enc.setFragmentBuffer(fs, offset: 0, index: 3)
        } else {
            enc.setFragmentBuffer(zeroBuffer, offset: 0, index: 3)
        }
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setVertexBytes(&d, length: MemoryLayout<MeshDraw>.stride, index: 2)
        enc.setFragmentBytes(&d, length: MemoryLayout<MeshDraw>.stride, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: g.indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
    }

    private func drawEdges(_ enc: MTLRenderCommandEncoder, id: UUID, draw d: inout LineDraw) {
        guard let g = bodies[id], let eb = g.edgeBuffer, g.segmentCount > 0 else { return }
        if let es = g.edgeStates {
            d.stateCount = UInt32(g.edgeCount)
            enc.setVertexBuffer(es, offset: 0, index: 3)
        } else {
            enc.setVertexBuffer(zeroBuffer, offset: 0, index: 3)
        }
        enc.setVertexBuffer(eb, offset: 0, index: 0)
        enc.setVertexBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
        enc.setFragmentBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: g.segmentCount)
    }

    /// Picked edges are 3 pt (4 pt on touch, read at arm's length) with a halo, and still
    /// show at 35 % where the model is in front of them.
    #if os(iOS) || os(visionOS)
    static let pickedEdgeWidth: Float = 4
    #else
    static let pickedEdgeWidth: Float = 3
    #endif

    private func drawEdgeHighlights(_ enc: MTLRenderCommandEncoder, U: FrameUniforms, pixelsPerPoint: Float) {
        guard highlightSegCount > 0, let segs = highlightSegs else { return }
        let pal = palette
        let w = Self.pickedEdgeWidth
        let dashPeriod = U.viewport.w * pixelsPerPoint * 10
        enc.setRenderPipelineState(pLine)
        enc.setVertexBuffer(segs, offset: 0, index: 0)
        enc.setVertexBuffer(highlightStates ?? zeroBuffer, offset: 0, index: 3)
        func pass(_ depth: MTLDepthStencilState, _ solid: LineStyle, _ dashed: LineStyle) {
            var d = LineDraw(solid, dashed)
            d.stateCount = UInt32(highlightCount)
            d.pull = 1
            d.dashPeriod = dashPeriod
            enc.setDepthStencilState(depth)
            enc.setVertexBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.setFragmentBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: highlightSegCount)
        }
        let hidden = pal.accent.withAlpha(0.35)
        pass(dsGreater, LineStyle(hidden, width: w - 1), LineStyle(hidden, width: w - 1, dashed: true))
        let halo = LineStyle(pal.edgeHalo, width: w + 3)
        pass(dsTest, halo, halo)
        pass(dsTest, LineStyle(pal.accent, width: w), LineStyle(pal.accent, width: w, dashed: true))
    }

    private func drawGrid(_ enc: MTLRenderCommandEncoder, _ g: inout GridDraw) {
        enc.setVertexBytes(&g, length: MemoryLayout<GridDraw>.stride, index: 2)
        enc.setFragmentBytes(&g, length: MemoryLayout<GridDraw>.stride, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawGround(_ enc: MTLRenderCommandEncoder, U: FrameUniforms) {
        let pal = palette
        let cam = camera
        enc.setRenderPipelineState(pGrid)
        enc.setDepthStencilState(dsLess)
        let sketchGrid = scene.sketch?.grid != nil
        if scene.showsGroundGrid && !sketchGrid {
            let minor = pow(10, ceil(log10(max(cam.distance * 0.012, 1e-3))))
            var r = cam.distance * 2.2
            var c = SIMD2<Float>(Float(cam.target.x), Float(cam.target.y))
            if let p = scene.plate {
                // Keep the ground grid around the bed so the bed reads as an object.
                r = max(simd_length(SIMD2(p.size.x, p.size.y)) * 1.1, r * 0.5)
                c = SIMD2<Float>(p.center)
            }
            var g = GridDraw()
            g.origin = SIMD4(0, 0, 0, 0)
            g.axisU = SIMD4(1, 0, 0, 0)
            g.axisV = SIMD4(0, 1, 0, 0)
            g.extent = SIMD4(c.x - Float(r), c.y - Float(r), c.x + Float(r), c.y + Float(r))
            let dim: Float = scene.plate == nil ? 1 : 0.8
            g.minor = pal.groundMinor.linear * SIMD4(1, 1, 1, dim)
            g.major = pal.groundMajor.linear * SIMD4(1, 1, 1, dim)
            g.params = SIMD4(Float(minor), Float(minor * 10), Float(r), 1)
            g.fadeCenter = SIMD4(c.x, c.y, 0, 0)
            drawGrid(enc, &g)
        }
        if let p = scene.plate {
            var g = GridDraw()
            g.origin = SIMD4(0, 0, 0, 0)
            g.axisU = SIMD4(1, 0, 0, 0)
            g.axisV = SIMD4(0, 1, 0, 0)
            g.extent = SIMD4(Float(p.minXY.x), Float(p.minXY.y), Float(p.maxXY.x), Float(p.maxXY.y))
            g.fill = pal.bedFill.linear
            g.minor = pal.bedMinor.linear
            g.major = pal.bedMajor.linear
            g.axes = SIMD4(0, 1, 0, 0)
            // The sketch grid replaces the bed grid while sketching.
            g.params = sketchGrid ? SIMD4(0, 0, 0, 1) : SIMD4(10, 50, 0, 1)
            drawGrid(enc, &g)
        }
        // Contact shadows for bodies resting on (or near) the bed.
        if scene.plate != nil || scene.showsGroundGrid {
            enc.setRenderPipelineState(pShadow)
            enc.setDepthStencilState(dsLess)
            for b in scene.bodies where b.visible {
                guard let bb = bodies[b.id]?.bounds else { continue }
                let size = bb.size
                let lift = max(bb.min.z, 0)
                let height = max(size.z, 1e-3)
                guard bb.min.z < height * 0.5 + 1, bb.max.z > 0 else { continue }
                let contact = Float(1 - min(lift / (height * 0.5 + 1), 1))
                let soft = max(min(size.x, size.y) * 0.18 + height * 0.12, 1.5)
                // Two layers: a wide soft penumbra, then a tight dark line where the part meets
                // the bed, so it sits on the sheet instead of floating over it.
                for (margin, strength) in [(soft, Float(0.6)), (max(height * 0.15, 1.2), Float(1))] {
                    var sd = ShadowDraw()
                    sd.center = SIMD4(Float(bb.center.x), Float(bb.center.y), 0, 0)
                    sd.halfSize = SIMD4(Float(size.x / 2), Float(size.y / 2), 0, 0)
                    sd.params = SIMD4(Float(margin), contact * strength, 0, 0)
                    sd.color = pal.shadow.linear
                    enc.setVertexBytes(&sd, length: MemoryLayout<ShadowDraw>.stride, index: 2)
                    enc.setFragmentBytes(&sd, length: MemoryLayout<ShadowDraw>.stride, index: 2)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
        }
        if plateSegCount > 0, let buf = plateSegs {
            enc.setRenderPipelineState(pLine)
            enc.setDepthStencilState(dsTest)
            var d = LineDraw(LineStyle(pal.axisX, width: 2), LineStyle(pal.axisY, width: 2), LineStyle(pal.axisZ, width: 2),
                             LineStyle(pal.bedOutline, width: 1.5))
            d.stateCount = 4
            d.pull = 1
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBuffer(plateStates, offset: 0, index: 3)
            enc.setVertexBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.setFragmentBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: plateSegCount)
        }
    }

    private func drawSketch(_ enc: MTLRenderCommandEncoder, sketch s: SketchOverlay, U: FrameUniforms) {
        let pal = palette
        let pl = s.plane
        if let grid = s.grid {
            enc.setRenderPipelineState(pGrid)
            enc.setDepthStencilState(dsTest)
            var g = GridDraw()
            g.origin = SIMD4(pl.origin.float, 0)
            g.axisU = SIMD4(pl.xDir.float, 0)
            g.axisV = SIMD4(pl.yDir.float, 0)
            let e = Float(grid.extent)
            g.extent = SIMD4(-e, -e, e, e)
            g.fill = pal.sketchGridMinor.linear * SIMD4(1, 1, 1, 0.25)
            g.minor = pal.sketchGridMinor.linear
            g.major = pal.sketchGridMajor.linear
            g.params = SIMD4(Float(grid.spacing), Float(grid.spacing * Double(max(grid.majorEvery, 1))), e, 1)
            g.fadeCenter = SIMD4(pl.origin.float, 0)
            g.axes = SIMD4(1, 0, 0, 0)
            g.axisUColor = pal.axisX.linear * SIMD4(1, 1, 1, 0.7)
            g.axisVColor = pal.axisY.linear * SIMD4(1, 1, 1, 0.7)
            drawGrid(enc, &g)
        }
        if regionVertCount > 0, let rb = regionVerts {
            enc.setRenderPipelineState(pRegion)
            enc.setDepthStencilState(dsAlways)
            var d = RegionDraw()
            d.c0 = pal.regionFill.linear
            d.c1 = pal.hover.withAlpha(min(pal.regionPickedFill.a * 0.65, 1)).linear
            d.c2 = pal.regionPickedFill.linear
            enc.setVertexBuffer(rb, offset: 0, index: 0)
            enc.setVertexBytes(&d, length: MemoryLayout<RegionDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: regionVertCount)
        }
        if sketchSegCount > 0, let sb = sketchSegs {
            enc.setRenderPipelineState(pLine)
            enc.setDepthStencilState(dsAlways)
            var d = LineDraw(
                LineStyle(pal.sketchCurve, width: 2.0),
                LineStyle(pal.hover, width: 2.6),
                LineStyle(pal.accent, width: 3.0),
                LineStyle(pal.sketchConstruction, width: 1.6, dashed: true),
                LineStyle(pal.sketchPreview, width: 2.2),
                LineStyle(pal.accent, width: 2.4, dashed: true))
            d.stateCount = UInt32(sketchCurveCount)
            d.dashPeriod = U.viewport.w * U.viewport.z * 10
            enc.setVertexBuffer(sb, offset: 0, index: 0)
            enc.setVertexBuffer(sketchCurveStates ?? zeroBuffer, offset: 0, index: 3)
            enc.setVertexBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.setFragmentBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sketchSegCount)
        }
        if sketchPointCount > 0, let pb = sketchPoints {
            enc.setRenderPipelineState(pPoint)
            enc.setDepthStencilState(dsAlways)
            var d = PointDraw()
            d.s0 = PointStyle(color: pal.sketchPoint, ring: pal.sketchPointRing, size: 7, ringWidth: 1.5)
            d.s1 = PointStyle(color: pal.hover, ring: pal.sketchPointRing, size: 10, ringWidth: 1.5)
            d.s2 = PointStyle(color: pal.accent, ring: pal.sketchPointRing, size: 10, ringWidth: 1.5)
            d.s3 = PointStyle(color: pal.accent, ring: pal.sketchPointRing, size: 7, ringWidth: 1.5)
            d.s4 = PointStyle(color: pal.sketchPointRing, ring: pal.accent, size: 12, ringWidth: 2.5)
            enc.setVertexBuffer(pb, offset: 0, index: 0)
            enc.setVertexBytes(&d, length: MemoryLayout<PointDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sketchPointCount)
        }
    }

    private func drawHandles(_ enc: MTLRenderCommandEncoder, U: FrameUniforms, pixelsPerPoint: Float, hover: PickTarget?) {
        let pal = palette
        let wppPoints = Double(U.viewport.w * pixelsPerPoint)
        for h in scene.handles {
            let active = activeHandleID == h.id
            let hovered = hover == .handle(h.id)
            let base = h.color ?? pal.handle
            // Hover and drag brighten the handle's own colour rather than switching to the selection blue.
            let color = active ? base.lightened(0.3) : (hovered ? base.lightened(0.15) : base)
            // Screen-constant size at the tip's depth.
            let depthScale = camera.projection == .perspective ? max(camera.depth(of: h.tip), 1e-3) / camera.distance : 1
            let wpp = wppPoints * depthScale
            let shaftEnd = h.tip + h.direction * (HandleMetrics.shaftLength * wpp)
            // Shaft.
            enc.setRenderPipelineState(pLine)
            enc.setDepthStencilState(dsAlways)
            var seg = GPULineSeg(h.tip.float, shaftEnd.float, dist: 0, id: 0)
            var d = LineDraw(LineStyle(color, width: active || hovered ? 3.5 : 2.75))
            enc.setVertexBytes(&seg, length: MemoryLayout<GPULineSeg>.stride, index: 0)
            enc.setVertexBuffer(zeroBuffer, offset: 0, index: 3)
            enc.setVertexBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.setFragmentBytes(&d, length: MemoryLayout<LineDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            // Base dot.
            enc.setRenderPipelineState(pPoint)
            var pd = PointDraw()
            pd.s0 = PointStyle(color: color, ring: pal.sketchPointRing, size: 9, ringWidth: 1.5)
            let t = h.tip.float
            var inst = GPUPointInst(x: t.x, y: t.y, z: t.z, state: 0)
            enc.setVertexBytes(&inst, length: MemoryLayout<GPUPointInst>.stride, index: 0)
            enc.setVertexBytes(&pd, length: MemoryLayout<PointDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            // Cone head.
            guard let vb = cone.vertexBuffer, let ib = cone.indexBuffer else { continue }
            let z = h.direction
            let x = Plane(origin: .zero, normal: z, xDir: abs(z.x) < 0.9 ? .unitX : .unitY).xDir
            let y = z.cross(x)
            let s = Float(HandleMetrics.headLength * wpp)
            var md = MeshDraw()
            md.model = simd_float4x4(columns: (SIMD4(x.float * s, 0), SIMD4(y.float * s, 0), SIMD4(z.float * s, 0),
                                               SIMD4(shaftEnd.float, 1)))
            md.color = SIMD4(SIMD3(color.linear.x, color.linear.y, color.linear.z), 1)
            enc.setRenderPipelineState(pMeshOpaque)
            enc.setCullMode(.back)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentBuffer(zeroBuffer, offset: 0, index: 3)
            enc.setVertexBytes(&md, length: MemoryLayout<MeshDraw>.stride, index: 2)
            enc.setFragmentBytes(&md, length: MemoryLayout<MeshDraw>.stride, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: cone.indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            enc.setCullMode(.none)
        }
    }

    // MARK: Offscreen snapshot

    /// Renders `scene` from `camera` into an image of `size` points × `scale`.
    public func snapshot(scene: ViewportScene, camera: Camera, size: CGSize, scale: CGFloat = 2,
                         appearance: ViewportAppearance = .light) -> CGImage? {
        let savedScene = self.scene, savedCamera = self.camera, savedPalette = palette
        defer {
            update(scene: savedScene)
            self.camera = savedCamera
            palette = savedPalette
        }
        update(scene: scene)
        self.camera = camera
        palette = appearance.palette
        prepare()

        let w = max(Int((size.width * scale).rounded()), 1), h = max(Int((size.height * scale).rounded()), 1)
        func tex(_ fmt: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.storageMode = .private
            d.usage = usage
            return device.makeTexture(descriptor: d)
        }
        guard let msaa = tex(Self.colorFormat, samples: Self.sampleCount, usage: .renderTarget),
              let resolve = tex(Self.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead]),
              let depth = tex(Self.depthFormat, samples: Self.sampleCount, usage: .renderTarget),
              let readback = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = msaa
        rp.colorAttachments[0].resolveTexture = resolve
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .multisampleResolve
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        encode(enc, pixelSize: SIMD2(Float(w), Float(h)), pixelsPerPoint: Float(scale))
        enc.endEncoding()
        guard let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: resolve, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        let data = Data(bytes: readback.contents(), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Convenience: renders a snapshot with a fresh renderer on the default device.
    public static func snapshot(scene: ViewportScene, camera: Camera, size: CGSize, scale: CGFloat = 2,
                                appearance: ViewportAppearance = .light) -> CGImage? {
        guard let r = try? ViewportRenderer() else { return nil }
        return r.snapshot(scene: scene, camera: camera, size: size, scale: scale, appearance: appearance)
    }
}

// MARK: - MTKViewDelegate

extension ViewportRenderer: MTKViewDelegate {
    /// Configures an `MTKView` for this renderer (formats, MSAA, on-demand drawing).
    public func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorFormat
        view.depthStencilPixelFormat = Self.depthFormat
        view.sampleCount = Self.sampleCount
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.clearDepth = 1
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = 120
        view.delegate = self
        #if os(macOS)
        if let layer = view.layer as? CAMetalLayer { layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        #endif
        self.view = view
    }

    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { self.setNeedsDisplay() }
    }

    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { self.render(in: view) }
    }

    private func render(in view: MTKView) {
        stepAnimation()
        prepare()
        guard let rp = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        let ds = view.drawableSize
        let pts = view.bounds.size
        let ppp = pts.width > 0 ? Float(ds.width / pts.width) : 1
        encode(enc, pixelSize: SIMD2(Float(ds.width), Float(ds.height)), pixelsPerPoint: ppp)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
