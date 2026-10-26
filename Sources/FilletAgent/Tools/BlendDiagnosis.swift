import FilletKernel
import Foundation

/// Why rounding (or bevelling) a set of edges failed: which edges can't take the size even on
/// their own, and the largest size the rest take together. Each probe is a real fillet in the
/// kernel, so the search stops at a time budget and says what it didn't get to.
struct BlendDiagnosis: Sendable, Equatable {
    /// What a search for a size that works found.
    enum Size: Sendable, Equatable {
        /// The largest size that worked.
        case works(Double)
        /// Nothing worked, down to this size.
        case failsDownTo(Double)
    }

    /// Edges that fail on their own at the requested size.
    var badEdges: [Int] = []
    /// Edges that work at the requested size (in groups, at least).
    var goodEdges: [Int] = []
    /// Edges not checked for lack of time.
    var unchecked: [Int] = []
    /// The largest size for the good edges together, or for all edges when none is good.
    var size: Size?
    /// The largest size for the bad edges together, when there are good ones too.
    var badSize: Size?

    /// Probes `shape` with fillets (or chamfers) of `size` on `edges`. Runs off the main actor.
    static func run(shape: Shape, edges: [Int], size: Double, fillet: Bool, budget: Duration = .seconds(8)) async -> BlendDiagnosis {
        await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            return diagnose(edges: edges, size: size, outOfTime: { clock.now - start >= budget * $0 }) { e, s in
                // A blend the kernel returns can still be broken (no solid left, or invalid).
                guard let result = try? fillet ? shape.filleted(edges: e, radius: s) : shape.chamfered(edges: e, distance: s) else { return false }
                return result.solidCount > 0 && result.isValid
            }
        }.value
    }

    /// The search, with the kernel call passed in (so it can be tested without one).
    /// - Parameters:
    ///   - outOfTime: whether the given share of the time budget is used up. Looking for bad
    ///     edges stops at 60 %, so there is time left to look for sizes that work.
    ///   - works: whether `edges` round at `size`.
    static func diagnose(edges: [Int], size: Double, outOfTime: (Double) -> Bool, works: ([Int], Double) -> Bool) -> BlendDiagnosis {
        var d = BlendDiagnosis()
        // Bad edges by halving: a group that works is fine as a whole; one that fails is split
        // until the edges that fail on their own are left. Few bad edges cost few probes.
        if edges.count > 1 {
            var pending: [[Int]] = [Array(edges.prefix(edges.count / 2)), Array(edges.dropFirst(edges.count / 2))]
            while let group = pending.popLast() {
                if outOfTime(0.6) {
                    d.unchecked = (group + pending.flatMap { $0 }).sorted()
                    break
                }
                if works(group, size) {
                    d.goodEdges += group
                } else if group.count == 1 {
                    d.badEdges += group
                } else {
                    pending += [Array(group.prefix(group.count / 2)), Array(group.dropFirst(group.count / 2))]
                }
            }
            d.badEdges.sort()
            d.goodEdges.sort()
        } else {
            d.badEdges = edges
        }
        // Halving the size until one works, then closing in on the largest.
        func largest(_ set: [Int]) -> Size? {
            var lo = 0.0, hi = size
            for _ in 0..<6 {
                if outOfTime(1) { break }
                let mid = (lo + hi) / 2
                if works(set, mid) { lo = mid } else { hi = mid }
                // Close enough for a size someone would type.
                if lo > 0, hi - lo < max(0.05, lo * 0.1) { break }
            }
            return lo > 0 ? .works(lo) : hi < size ? .failsDownTo(hi) : nil
        }
        if d.goodEdges.isEmpty {
            d.size = largest(edges)
            return d
        }
        // The good edges were only checked in groups (unless none failed); together they may clash.
        if !d.badEdges.isEmpty || !d.unchecked.isEmpty {
            if outOfTime(1) { return d }
            d.size = works(d.goodEdges, size) ? .works(size) : largest(d.goodEdges)
        } else {
            d.size = largest(d.goodEdges)
        }
        if !d.badEdges.isEmpty { d.badSize = largest(d.badEdges) }
        return d
    }

    /// A few sentences for the error, e.g. "Edges 12, 14 can't be rounded at 3 mm, even on their
    /// own (they fail even at 0.09 mm); the other 6 take up to 1.8 mm together."
    func message(size requested: Double, fillet: Bool) -> String {
        let verb = fillet ? "rounded" : "bevelled"
        let what = fillet ? "radius" : "distance"
        func mm(_ v: Double) -> String { Self.format(v) + " mm" }
        func list(_ edges: [Int]) -> String { (edges.count == 1 ? "edge " : "edges ") + edges.map(String.init).joined(separator: ", ") }
        /// "take up to 1.8 mm" / "fail even at 0.09 mm"
        func found(_ s: Size?, one: Bool) -> String? {
            switch s {
            case .works(let v): (one ? "takes " : "take ") + (v >= requested ? "the requested \(mm(requested))" : "up to \(mm(Self.floor(v)))")
            case .failsDownTo(let v): (one ? "fails" : "fail") + " even at \(mm(Self.floor(v)))"
            case nil: nil
            }
        }
        var parts: [String] = []
        if badEdges.isEmpty, unchecked.isEmpty {
            parts.append("each edge can be \(verb) at \(mm(requested)) on its own, but not all together (the \(fillet ? "fillets" : "chamfers") collide where they meet)")
            if let f = found(size, one: false) { parts.append("together they " + f) }
        } else if goodEdges.isEmpty, unchecked.isEmpty {
            if badEdges.count == 1 {
                parts.append("\(list(badEdges)) can't be \(verb) at \(mm(requested))")
                if let f = found(size, one: true) { parts.append("it " + f) }
            } else {
                parts.append("none of the edges can be \(verb) at \(mm(requested)), even on their own")
                if let f = found(size, one: false) { parts.append("together they " + f) }
            }
        } else {
            if !badEdges.isEmpty {
                let one = badEdges.count == 1
                var s = "\(list(badEdges)) can't be \(verb) at \(mm(requested)), even on \(one ? "its" : "their") own"
                if let f = found(badSize, one: one) { s += " (\(one ? "it" : "together they") \(f))" }
                parts.append(s)
            }
            if !goodEdges.isEmpty {
                let others = badEdges.isEmpty ? list(goodEdges) : "the other \(goodEdges.count)"
                parts.append(found(size, one: false).map { "\(others) \($0) together" } ?? "\(others) work in groups")
            }
        }
        if !unchecked.isEmpty { parts.append("there was no time left to check \(list(unchecked))") }
        var text = parts.joined(separator: "; ") + "."
        if !badEdges.isEmpty, !goodEdges.isEmpty {
            text += " Leave those out (or give them a step of their own with a smaller \(what)) and \(fillet ? "round" : "bevel") the rest."
        } else if case .works(let v) = size, v < requested {
            text += " Use a \(what) of at most \(mm(Self.floor(v)))."
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Rounded down to a size worth typing: 0.1 mm steps from 1 mm, finer below.
    static func floor(_ v: Double) -> Double {
        v >= 1 ? (v * 10).rounded(.down) / 10 : v >= 0.01 ? (v * 100).rounded(.down) / 100 : (v * 1000).rounded(.down) / 1000
    }

    static func format(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
