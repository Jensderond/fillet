import simd

/// Each face's own surface normal at the points on edges between faces
/// (``WorkMesh/edgeNormals``): a map from (point, face) to a normal, kept beside the points.
///
/// A point's first face goes in a slot at the point's index, any further face (only on a real
/// border between faces) in a dictionary. Flat faces and fillet strips start out with every point
/// on a border, and splitting spreads the entries to the points between, so nearly every point
/// has one: as a dictionary keyed by ``WorkMesh/pointFace(_:_:)`` every surface normal hashed, and
/// that was several percent of the texture step. The slots are read at the same index as
/// ``WorkMesh/surfaceNormals``, mostly in point order. The same keys and values as that
/// dictionary: a (point, face) is stored in one place only, the slot when it came first, and
/// setting it again replaces its value there.
struct PointFaceNormals {
    /// The face in each point's slot (``none``: empty), and its normal.
    private var face: [Int32] = []
    private var normal: [SIMD3<Double>] = []
    /// Whether the point has entries in ``more``: checked before hashing.
    private var hasMore: [Bool] = []
    private var more: [UInt64: SIMD3<Double>] = [:]
    /// Whether nothing has been set.
    private(set) var isEmpty = true

    private static var none: Int32 { .min }

    /// The normal at point `v` of face `f`, or nil when none is known.
    @inline(__always) subscript(v: Int32, f: Int32) -> SIMD3<Double>? {
        let i = Int(v)
        guard i >= 0, i < face.count, f != Self.none else { return nil }
        if face[i] == f { return normal[i] }
        return hasMore[i] ? more[WorkMesh.pointFace(v, f)] : nil
    }

    /// Sets the normal at point `v` of face `f` (replacing any before).
    mutating func set(_ v: Int32, _ f: Int32, _ n: SIMD3<Double>) {
        let i = Int(v)
        precondition(i >= 0 && f != Self.none)
        if i >= face.count {
            let grow = max(i + 1 - face.count, face.count / 2)
            face.append(contentsOf: repeatElement(Self.none, count: grow))
            normal.append(contentsOf: repeatElement(.zero, count: grow))
            hasMore.append(contentsOf: repeatElement(false, count: grow))
        }
        isEmpty = false
        if face[i] == Self.none || face[i] == f {
            face[i] = f
            normal[i] = n
        } else {
            more[WorkMesh.pointFace(v, f)] = n
            hasMore[i] = true
        }
    }
}
