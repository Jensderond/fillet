import Foundation

/// A hash map from edge keys (``WorkMesh/key(_:_:)``, ``WorkMesh/directedKey(_:_:)``,
/// ``WorkMesh/pointFace(_:_:)``) to values, for the mesh passes that look up every edge of every
/// triangle, often many passes over.
///
/// Open addressing with linear probing in one flat table, hashed by a single multiply: a Swift
/// `Dictionary` hashes each key with SipHash, and that alone was over a third of the texture
/// step's time. Only lookups and inserts, and iteration only where the order can't matter
/// (``forEach(_:)``): the slots' order follows the hash, not the insertions.
struct EdgeMap<Value> {
    /// The keys by slot; ``free`` marks an empty slot (no edge key takes that value: it would be
    /// vertex -1 on face -1).
    private var keys: [UInt64]
    /// The values by slot (`filler` in empty ones).
    private(set) var values: [Value]
    private let filler: Value
    /// 64 less the table's size in bits: a key's home slot is the top bits of its hash.
    private var shift: UInt64
    private(set) var count = 0

    static var free: UInt64 { .max }

    /// Room for about `capacity` keys before it grows; `filler` stands in the empty slots.
    init(capacity: Int, filler: Value) {
        var bits: UInt64 = 4
        while (1 << bits) * 3 / 4 < max(capacity, 1) { bits += 1 }
        keys = [UInt64](repeating: Self.free, count: 1 << bits)
        values = [Value](repeating: filler, count: 1 << bits)
        self.filler = filler
        shift = 64 - bits
    }

    @inline(__always) private func home(_ key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> shift)
    }

    /// The slot holding `key`, or nil.
    @inline(__always) func slot(of key: UInt64) -> Int? {
        let mask = keys.count - 1
        var i = home(key)
        while true {
            let k = keys[i]
            if k == key { return i }
            if k == Self.free { return nil }
            i = (i + 1) & mask
        }
    }

    subscript(key: UInt64) -> Value? {
        guard let i = slot(of: key) else { return nil }
        return values[i]
    }

    /// Whether `key` is in the map.
    func contains(_ key: UInt64) -> Bool { slot(of: key) != nil }

    /// The slot for `key`, added (with the filler value) if it wasn't there, and whether it was.
    @inline(__always) mutating func findOrInsert(_ key: UInt64) -> (slot: Int, found: Bool) {
        if (count + 1) * 4 > keys.count * 3 { grow() }
        let mask = keys.count - 1
        var i = home(key)
        while true {
            let k = keys[i]
            if k == key { return (i, true) }
            if k == Self.free {
                keys[i] = key
                count += 1
                return (i, false)
            }
            i = (i + 1) & mask
        }
    }

    /// Sets `key`'s value, adding it if it wasn't there.
    @inline(__always) mutating func set(_ key: UInt64, _ value: Value) {
        values[findOrInsert(key).slot] = value
    }

    /// Sets the value in a slot from ``findOrInsert(_:)``.
    @inline(__always) mutating func set(slot: Int, _ value: Value) {
        values[slot] = value
    }

    /// Each key and its value, in no particular order.
    func forEach(_ body: (UInt64, Value) -> Void) {
        for i in keys.indices where keys[i] != Self.free { body(keys[i], values[i]) }
    }

    private mutating func grow() {
        let oldKeys = keys, oldValues = values
        let bits = 64 - shift + 1
        keys = [UInt64](repeating: Self.free, count: 1 << bits)
        values = [Value](repeating: filler, count: 1 << bits)
        shift = 64 - bits
        count = 0
        for i in oldKeys.indices where oldKeys[i] != Self.free { set(oldKeys[i], oldValues[i]) }
    }
}
