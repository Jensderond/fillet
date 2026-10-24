import CFilletKernel
import Foundation
import simd

// MARK: - Bridging helpers

extension Vec3 {
    init(_ v: FKVec3) { self.init(v.x, v.y, v.z) }
    var fk: FKVec3 { FKVec3(x: x, y: y, z: z) }
}

extension Plane {
    init(_ p: FKPlane) { self.init(origin: Vec3(p.origin), normal: Vec3(p.normal), xDir: Vec3(p.xDir)) }
    var fk: FKPlane { FKPlane(origin: origin.fk, normal: normal.fk, xDir: xDir.fk) }
}

extension KernelError {
    /// The error recorded by the last failing kernel call on this thread.
    static func last(_ fallback: String) -> KernelError {
        let message = fk_last_error().map { String(cString: $0) } ?? ""
        return KernelError(message.isEmpty ? fallback : message)
    }
}

/// Boolean operation kind.
public enum BooleanOperation: Sendable, Hashable {
    case fuse, cut, common

    var fk: FKBoolOp {
        switch self {
        case .fuse: FK_BOOL_FUSE
        case .cut: FK_BOOL_CUT
        case .common: FK_BOOL_COMMON
        }
    }
}

// MARK: - Shape

/// An immutable B-rep shape (solid, compound of solids, face, edge, ...) owned by the kernel.
///
/// Every operation returns a new shape. Face and edge indices are 0-based and
/// only valid for this exact shape (see `faceInfo(_:)` / `edgeInfo(_:)`).
/// A single `Shape` must not be used from several threads at the same time;
/// distinct shapes may be used concurrently.
public final class Shape: @unchecked Sendable {
    let handle: OpaquePointer

    init(owning handle: OpaquePointer) { self.handle = handle }
    deinit { fk_shape_free(handle) }

    /// Wraps a newly returned kernel shape or throws the kernel's error.
    static func make(_ ptr: OpaquePointer?, _ operation: String) throws -> Shape {
        guard let ptr else { throw KernelError.last("\(operation) failed") }
        return Shape(owning: ptr)
    }

    // MARK: Primitives

    /// Axis-aligned box from `corner` spanning `size` (negative components extend the other way).
    public static func box(corner: Vec3, size: Vec3) throws -> Shape {
        try make(fk_box(corner.fk, size.fk), "Box")
    }

    /// Cylinder standing on `base` (axis = base.normal).
    public static func cylinder(base: Plane, radius: Double, height: Double) throws -> Shape {
        try make(fk_cylinder(base.fk, radius, height), "Cylinder")
    }

    public static func sphere(center: Vec3, radius: Double) throws -> Shape {
        try make(fk_sphere(center.fk, radius), "Sphere")
    }

    /// Cone/frustum standing on `base`; either radius may be 0.
    public static func cone(base: Plane, radius1: Double, radius2: Double, height: Double) throws -> Shape {
        try make(fk_cone(base.fk, radius1, radius2, height), "Cone")
    }

    /// Torus centred on `base.origin`, axis = base.normal.
    public static func torus(base: Plane, majorRadius: Double, minorRadius: Double) throws -> Shape {
        try make(fk_torus(base.fk, majorRadius, minorRadius), "Torus")
    }

    /// Compound of several shapes (not fused).
    public static func compound(_ shapes: [Shape]) throws -> Shape {
        let handles: [OpaquePointer?] = shapes.map { $0.handle }
        let result = handles.withUnsafeBufferPointer { fk_compound($0.baseAddress, Int32($0.count)) }
        return try withExtendedLifetime(shapes) { try make(result, "Combine") }
    }

    public func copy() throws -> Shape { try Shape.make(fk_shape_copy(handle), "Copy") }

    // MARK: Features

    /// Prism of this profile (face or faces) along `dir` from `-back` to `+distance`.
    /// `taper` (radians) > 0 narrows the solid as it grows.
    public func extruded(along dir: Vec3, distance: Double, back: Double = 0, taper: Double = 0) throws -> Shape {
        try Shape.make(fk_extrude(handle, dir.fk, distance, back, taper), "Extrude")
    }

    /// Revolves this profile around the axis by `angle` radians (2π = full revolution).
    public func revolved(axisOrigin: Vec3, axisDir: Vec3, angle: Double = 2 * .pi) throws -> Shape {
        try Shape.make(fk_revolve(handle, axisOrigin.fk, axisDir.fk, angle), "Revolve")
    }

    public func boolean(_ op: BooleanOperation, _ other: Shape) throws -> Shape {
        try withExtendedLifetime(other) { try Shape.make(fk_boolean(handle, other.handle, op.fk), "Boolean") }
    }

    public func fused(with other: Shape) throws -> Shape { try boolean(.fuse, other) }
    public func cut(by other: Shape) throws -> Shape { try boolean(.cut, other) }
    public func common(with other: Shape) throws -> Shape { try boolean(.common, other) }

    /// Constant-radius fillet on the given edge indices.
    public func filleted(edges: [Int], radius: Double) throws -> Shape {
        let idx = edges.map { Int32(clamping: $0) }
        return try Shape.make(idx.withUnsafeBufferPointer { fk_fillet(handle, $0.baseAddress, Int32($0.count), radius) },
                              "Fillet")
    }

    /// Equal-distance chamfer on the given edge indices.
    public func chamfered(edges: [Int], distance: Double) throws -> Shape {
        let idx = edges.map { Int32(clamping: $0) }
        return try Shape.make(
            idx.withUnsafeBufferPointer { fk_chamfer(handle, $0.baseAddress, Int32($0.count), distance) }, "Chamfer")
    }

    /// Hollows the solid, removing the given faces (empty = closed hollow).
    /// Positive thickness grows the wall inward.
    public func shelled(removing faces: [Int], thickness: Double) throws -> Shape {
        let idx = faces.map { Int32(clamping: $0) }
        return try Shape.make(
            idx.withUnsafeBufferPointer { fk_shell(handle, $0.baseAddress, Int32($0.count), thickness) }, "Shell")
    }

    public func transformed(_ transform: Transform) throws -> Shape {
        try Shape.make(transform.m.withUnsafeBufferPointer { fk_transform(handle, $0.baseAddress) }, "Move")
    }

    public func translated(by offset: Vec3) throws -> Shape { try transformed(.translation(offset)) }

    /// Mirrored copy (the original is not included).
    public func mirrored(across plane: Plane) throws -> Shape {
        try Shape.make(fk_mirror(handle, plane.fk), "Mirror")
    }

    // MARK: Topology

    public var faceCount: Int { Int(fk_face_count(handle)) }
    public var edgeCount: Int { Int(fk_edge_count(handle)) }
    public var solidCount: Int { Int(fk_solid_count(handle)) }

    /// Geometric signature of face `index`. Returns a zero `.other` placeholder for an invalid index;
    /// use `faceInfoIfValid(_:)` to distinguish.
    public func faceInfo(_ index: Int) -> FaceInfo {
        faceInfoIfValid(index)
            ?? FaceInfo(surface: .other, centroid: .zero, normal: .zero, area: 0, boundsMin: .zero, boundsMax: .zero)
    }

    public func faceInfoIfValid(_ index: Int) -> FaceInfo? {
        var info = FKFaceInfo()
        guard index >= 0, fk_face_info(handle, Int32(clamping: index), &info) else { return nil }
        return FaceInfo(
            surface: SurfaceType(rawValue: Int32(info.surface.rawValue)) ?? .other, centroid: Vec3(info.centroid),
            normal: Vec3(info.normal), area: info.area, boundsMin: Vec3(info.boundsMin),
            boundsMax: Vec3(info.boundsMax))
    }

    /// Geometric signature of edge `index`. Returns a zero `.other` placeholder for an invalid index;
    /// use `edgeInfoIfValid(_:)` to distinguish.
    public func edgeInfo(_ index: Int) -> EdgeInfo {
        edgeInfoIfValid(index)
            ?? EdgeInfo(curve: .other, start: .zero, mid: .zero, end: .zero, tangentAtMid: .zero, length: 0, radius: 0)
    }

    public func edgeInfoIfValid(_ index: Int) -> EdgeInfo? {
        var info = FKEdgeInfo()
        guard index >= 0, fk_edge_info(handle, Int32(clamping: index), &info) else { return nil }
        return EdgeInfo(
            curve: CurveType(rawValue: Int32(info.curve.rawValue)) ?? .other, start: Vec3(info.start),
            mid: Vec3(info.mid), end: Vec3(info.end), tangentAtMid: Vec3(info.tangentAtMid), length: info.length,
            radius: info.radius)
    }

    /// All face signatures, indexed like `faceInfo(_:)`.
    public var faceInfos: [FaceInfo] { (0..<faceCount).map(faceInfo) }
    /// All edge signatures, indexed like `edgeInfo(_:)`.
    public var edgeInfos: [EdgeInfo] { (0..<edgeCount).map(edgeInfo) }

    /// Plane of a planar face: origin at the centroid, outward normal, xDir along the longest
    /// straight edge. nil for non-planar faces or invalid indices.
    public func facePlane(_ index: Int) -> Plane? {
        var p = FKPlane()
        guard index >= 0, fk_face_plane(handle, Int32(clamping: index), &p) else { return nil }
        return Plane(p)
    }

    /// Standalone copy of one face (e.g. for measuring or as an extrude profile).
    public func face(_ index: Int) throws -> Shape {
        try Shape.make(fk_subshape_face(handle, Int32(clamping: index)), "Face")
    }

    /// Standalone copy of one edge.
    public func edge(_ index: Int) throws -> Shape {
        try Shape.make(fk_subshape_edge(handle, Int32(clamping: index)), "Edge")
    }

    /// The solids of this shape as separate shapes.
    public func solids() -> [Shape] {
        guard let list = fk_solids(handle) else { return [] }
        defer { fk_list_free(list) }
        return (0..<fk_list_count(list)).compactMap { i in fk_list_get(list, i).map(Shape.init(owning:)) }
    }

    // MARK: Analysis

    public var bounds: (min: Vec3, max: Vec3)? {
        var lo = FKVec3(), hi = FKVec3()
        guard fk_bounds(handle, &lo, &hi) else { return nil }
        return (Vec3(lo), Vec3(hi))
    }

    public var volume: Double { fk_volume(handle) }
    public var surfaceArea: Double { fk_surface_area(handle) }
    /// BRepCheck validity and closed shells.
    public var isValid: Bool { fk_is_valid(handle) }

    /// Shortest distance between this shape and `other`, with the closest points on each.
    public func distance(to other: Shape) -> (distance: Double, pointA: Vec3, pointB: Vec3)? {
        var d = 0.0
        var a = FKVec3(), b = FKVec3()
        let ok = withExtendedLifetime(other) { fk_distance(handle, other.handle, &d, &a, &b) }
        return ok ? (d, Vec3(a), Vec3(b)) : nil
    }

    // MARK: Tessellation

    /// Triangulates the shape: triangles grouped per face (crisp normals between faces,
    /// smooth within a face, counter-clockwise seen from outside) plus one polyline per edge
    /// (empty for seams and degenerate edges).
    public func tessellate(linearDeflection: Double = 0.05, angularDeflection: Double = 0.3) throws -> Mesh {
        guard let m = fk_tessellate(handle, linearDeflection, angularDeflection) else {
            throw KernelError.last("Tessellation failed")
        }
        defer { fk_mesh_free(m) }
        let vertexCount = Int(fk_mesh_vertex_count(m))
        let triangleCount = Int(fk_mesh_triangle_count(m))

        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        if vertexCount > 0, let p = fk_mesh_positions(m), let n = fk_mesh_normals(m) {
            for i in 0..<vertexCount {
                positions.append(SIMD3(p[3 * i], p[3 * i + 1], p[3 * i + 2]))
                normals.append(SIMD3(n[3 * i], n[3 * i + 1], n[3 * i + 2]))
            }
        }
        var indices = [UInt32]()
        var triangleFaces = [Int32]()
        if triangleCount > 0, let ip = fk_mesh_indices(m), let fp = fk_mesh_triangle_faces(m) {
            indices = Array(UnsafeBufferPointer(start: ip, count: 3 * triangleCount))
            triangleFaces = Array(UnsafeBufferPointer(start: fp, count: triangleCount))
        }
        let edgeCount = Int(fk_mesh_edge_count(m))
        var edges = [[SIMD3<Float>]]()
        edges.reserveCapacity(edgeCount)
        for e in 0..<edgeCount {
            var count: Int32 = 0
            guard let pts = fk_mesh_edge_points(m, Int32(e), &count), count > 0 else {
                edges.append([])
                continue
            }
            edges.append((0..<Int(count)).map { SIMD3(pts[3 * $0], pts[3 * $0 + 1], pts[3 * $0 + 2]) })
        }
        return Mesh(positions: positions, normals: normals, indices: indices, triangleFaces: triangleFaces, edges: edges)
    }

    // MARK: Exchange

    public static func importSTEP(url: URL) throws -> Shape {
        try make(url.withUnsafeFileSystemRepresentation { fk_import_step($0) }, "STEP import")
    }

    /// Writes the shapes as separately named solids into one STEP file (AP214, mm).
    public static func exportSTEP(_ items: [(Shape, String)], url: URL) throws {
        let handles: [OpaquePointer?] = items.map { $0.0.handle }
        let names = items.map { strdup($0.1) }
        defer { names.forEach { free($0) } }
        let constNames: [UnsafePointer<CChar>?] = names.map { $0.map { UnsafePointer($0) } }
        let ok = url.withUnsafeFileSystemRepresentation { path in
            handles.withUnsafeBufferPointer { h in
                constNames.withUnsafeBufferPointer { n in
                    fk_export_step(h.baseAddress, n.baseAddress, Int32(items.count), path)
                }
            }
        }
        withExtendedLifetime(items) {}
        if !ok { throw KernelError.last("STEP export failed") }
    }

    /// Native OCCT text serialisation (geometry only, no triangulation). Empty on failure.
    public func brepString() -> String {
        guard let s = fk_brep_write_string(handle) else { return "" }
        defer { fk_string_free(s) }
        return String(cString: s)
    }

    public static func fromBRep(_ string: String) throws -> Shape {
        try make(string.withCString { fk_brep_read_string($0) }, "BRep import")
    }
}
