import Foundation
import simd

/// Items (points of the mesh, or anything with a position) binned into cubes of side `r`, for the
/// passes that sum over every item within `r` of each point, across the cores
/// (``WorkMesh/smoothDirections(_:where:radius:)``, ``WorkMesh/fairing(along:where:radius:)``).
///
/// The same visiting order as a dictionary from cube to the items in it, walked over the 27 cubes
/// round a point (z, then y, then x, each from -1 to 1) and each cube's items in the order they
/// were given, so sums over them come out to the bit. Only the lookups go: each cube's 27
/// neighbours are found once, not for every point in it (with SipHash, they were most of these
/// passes), and the items of a cube lie next to each other.
struct PointGrid {
    /// The cube of side `r` a position is in.
    let r: Double
    /// Each cube's items are `members[start[c]..<start[c + 1]]`, in the order given.
    private(set) var start: [Int]
    private(set) var members: [Int32]
    /// Each cube's 27 neighbours (itself among them) as cube indices, -1 where none has items.
    private(set) var around: [Int32]
    /// The cube of each item, by its place in the list given.
    private(set) var cellOfItem: [Int32]
    /// The cubes by position.
    private var index: [SIMD3<Int32>: Int32]
    private var keys: [SIMD3<Int32>]

    /// `items` (in this order) at `position(item)`, binned by `r`.
    init(radius r: Double, items: [Int32], position: (Int32) -> SIMD3<Double>) {
        self.r = r
        var index: [SIMD3<Int32>: Int32] = [:]
        var keys: [SIMD3<Int32>] = []
        var cellOfItem = [Int32](repeating: 0, count: items.count)
        var counts: [Int] = []
        for (k, item) in items.enumerated() {
            let key = Self.cell(position(item), r)
            let c: Int32
            if let found = index[key] {
                c = found
            } else {
                c = Int32(keys.count)
                index[key] = c
                keys.append(key)
                counts.append(0)
            }
            cellOfItem[k] = c
            counts[Int(c)] += 1
        }
        var start = [Int](repeating: 0, count: keys.count + 1)
        for c in keys.indices { start[c + 1] = start[c] + counts[c] }
        var fill = start
        var members = [Int32](repeating: 0, count: items.count)
        for (k, item) in items.enumerated() {
            let c = Int(cellOfItem[k])
            members[fill[c]] = item
            fill[c] += 1
        }
        self.index = index
        self.keys = keys
        self.start = start
        self.members = members
        self.cellOfItem = cellOfItem
        self.around = []
        let grid = self
        around = concurrentMap(keys.count, chunk: 256) { grid.neighbours(of: keys[$0]) }.flatMap { $0 }
    }

    static func cell(_ p: SIMD3<Double>, _ r: Double) -> SIMD3<Int32> { SIMD3<Int32>(floor3(p / r)) }

    /// The 27 cubes round cube `key` (which needn't have items itself) in the visiting order, as
    /// indices into this grid, -1 where none has items.
    func neighbours(of key: SIMD3<Int32>) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(27)
        for dz in Int32(-1)...1 {
            for dy in Int32(-1)...1 {
                for dx in Int32(-1)...1 {
                    out.append(index[key &+ SIMD3(dx, dy, dz)] ?? -1)
                }
            }
        }
        return out
    }

    /// The position of cube `c`.
    func key(of c: Int) -> SIMD3<Int32> { keys[c] }
    var cellCount: Int { keys.count }
}
