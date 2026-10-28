import FilletKernel
import Foundation

/// What the cursor snapped to, for on-screen feedback.
public enum SketchSnap: Hashable, Sendable {
    case grid
    case point(SnapKind)
    /// Horizontal/vertical alignment with a vertex.
    case horizontal, vertical
    /// Along the extension of a straight edge.
    case `extension`
    /// Where two guides cross (horizontal with one vertex, vertical with another…).
    case aligned
    case none
}

/// The families of snap candidates, ranked by `SnapSettings.priorities`.
public enum SnapCandidateKind: String, Hashable, Sendable, CaseIterable {
    /// Endpoints, centres, sketch points and intersections.
    case point
    /// Midpoints of lines and arcs, and circle quadrants.
    case midpoint
    /// Horizontal or vertical alignment with a vertex.
    case alignment
    /// The extension of a straight edge past its ends.
    case `extension`

    init(_ kind: SnapKind) {
        switch kind {
        case .endpoint, .center, .point, .intersection: self = .point
        case .midpoint, .quadrant: self = .midpoint
        }
    }
}

/// How snapping behaves. Radii are in multiples of the snap radius, which the app derives from
/// the pointer's on-screen pick tolerance, so snapping feels the same at every zoom.
public struct SnapSettings: Hashable, Sendable {
    /// The snap radius as a multiple of the pointer's pick tolerance (points on screen).
    public var radiusScale = 1.5
    /// Guides catch within this fraction of the snap radius: they reach across the whole sketch,
    /// so a narrower band keeps them from grabbing every movement.
    public var guideScale = 0.75
    /// A snap holds until the pointer is this many radii away from it, so it doesn't flicker
    /// on the edge of the radius.
    public var holdScale = 1.5
    /// A rival of the same priority takes over from the held snap only when it is closer by this
    /// fraction of the radius.
    public var switchMargin = 0.25
    /// Lower wins. A kind left out is off.
    public var priorities: [SnapCandidateKind: Int] = [.point: 0, .midpoint: 1, .alignment: 2, .extension: 3]
    /// Point kinds a horizontal or vertical guide can come from.
    public var alignmentKinds: Set<SnapKind> = [.endpoint, .center, .point, .midpoint]

    public init() {}

    /// The snap radius in sketch units (mm): the pointer's pick tolerance in on-screen points times
    /// `radiusScale`, at `unitsPerPoint` mm per point (the camera's scale at the sketch plane).
    /// Points, not pixels, so it is the same on every display scale.
    public func radius(pointerTolerance: Double, unitsPerPoint: Double) -> Double {
        unitsPerPoint * pointerTolerance * radiusScale
    }
}

/// A dashed guide line from the vertex or edge end it comes from to the snapped point.
public struct SnapGuide: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case horizontal, vertical, `extension` }
    public var kind: Kind
    public var from: SIMD2<Double>
    public var to: SIMD2<Double>

    public init(kind: Kind, from: SIMD2<Double>, to: SIMD2<Double>) {
        self.kind = kind; self.from = from; self.to = to
    }
}

/// A marker drawn while snapping: the point snapped to (shaped by its kind), or a vertex a guide comes from.
public enum SnapMarker: Hashable, Sendable {
    case target(SIMD2<Double>, SnapKind)
    case anchor(SIMD2<Double>)
}

/// An infinite line the pointer can snap along.
public struct GuideLine: Hashable, Sendable {
    public var kind: SnapGuide.Kind
    /// The vertex (or edge end) the guide comes from.
    public var anchor: SIMD2<Double>
    /// Unit direction.
    public var direction: SIMD2<Double>

    /// Whether `other` is the same infinite line (a horizontal guide at the same height from another vertex is).
    func isSameLine(as other: GuideLine) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .horizontal: return abs(anchor.y - other.anchor.y) < 1e-9
        case .vertical: return abs(anchor.x - other.anchor.x) < 1e-9
        case .extension: return anchor.isClose(to: other.anchor) && direction.isClose(to: other.direction)
        }
    }

    func distance(to p: SIMD2<Double>) -> Double {
        let v = p - anchor
        return abs(v.x * direction.y - v.y * direction.x)
    }

    func project(_ p: SIMD2<Double>) -> SIMD2<Double> {
        anchor + direction * ((p - anchor) * direction).sum()
    }

    func intersection(with o: GuideLine) -> SIMD2<Double>? {
        let denom = direction.x * o.direction.y - direction.y * o.direction.x
        guard abs(denom) > 1e-9 else { return nil }
        let v = o.anchor - anchor
        let t = (v.x * o.direction.y - v.y * o.direction.x) / denom
        return anchor + direction * t
    }
}

/// What a snap held onto, so the next pointer event can keep it (hysteresis).
public enum SnapTarget: Hashable, Sendable {
    case point(SIMD2<Double>, SnapKind)
    case guides([GuideLine])
}

/// The outcome of snapping one pointer position.
public struct SnapResolution: Hashable, Sendable {
    public var point: SIMD2<Double>
    public var snap: SketchSnap
    public var guides: [SnapGuide] = []
    public var markers: [SnapMarker] = []
    public var target: SnapTarget?

    public init(point: SIMD2<Double>, snap: SketchSnap, guides: [SnapGuide] = [], markers: [SnapMarker] = [],
                target: SnapTarget? = nil) {
        self.point = point; self.snap = snap; self.guides = guides; self.markers = markers; self.target = target
    }
}

/// Snap targets and tolerance for one input event.
public struct SnapContext: Sendable {
    public var targets: SnapTargets
    /// Snap radius in millimetres (derived from the on-screen size).
    public var tolerance: Double
    public var gridSize: Double
    public var settings = SnapSettings()
    /// The sketch being edited, for tools that pick its curves (Offset).
    public var sketch: Sketch?
    public var evaluator: Evaluator = .empty

    public init(targets: SnapTargets, tolerance: Double, gridSize: Double) {
        self.targets = targets; self.tolerance = tolerance; self.gridSize = gridSize
    }

    public init(points: [SnapPoint], tolerance: Double, gridSize: Double) {
        self.init(targets: SnapTargets(points: points), tolerance: tolerance, gridSize: gridSize)
    }

    public var points: [SnapPoint] { targets.points }

    /// Snaps `raw` to the nearest snap point within the tolerance (endpoints, centres and
    /// points before midpoints and quadrants), otherwise to the grid (or to 0.01 mm with the
    /// grid off). `extra` adds candidates; `gridStep` overrides the grid step (half steps for
    /// centre-based sizes). No guides: see `resolve` for those.
    public func snap(_ raw: SIMD2<Double>, extra: [(SIMD2<Double>, SnapKind)] = [], gridStep: Double? = nil)
        -> (point: SIMD2<Double>, snap: SketchSnap)
    {
        if let hit = nearestPoint(raw, extra: extra, previous: nil) { return (hit.0, .point(hit.1)) }
        return (gridded(raw, gridStep), gridSize > 0 ? .grid : .none)
    }

    /// Snaps `raw` in priority order: a point (vertex, intersection, then midpoint) within the
    /// radius, else where two guides cross, else one guide (horizontal or vertical with a vertex,
    /// then an edge's extension), else the grid. `extra` adds points (the shape in progress),
    /// `anchors` adds vertices that guides can come from, and `previous` is the last event's
    /// target, held while the pointer stays near it.
    public func resolve(_ raw: SIMD2<Double>, extra: [(SIMD2<Double>, SnapKind)] = [], anchors: [SIMD2<Double>] = [],
                        gridStep: Double? = nil, previous: SnapTarget? = nil) -> SnapResolution
    {
        if let (p, kind) = nearestPoint(raw, extra: extra, previous: previous) {
            return SnapResolution(point: p, snap: .point(kind), markers: [.target(p, kind)], target: .point(p, kind))
        }
        if let guided = guided(raw, anchors: anchors, gridStep: gridStep, previous: previous) { return guided }
        return SnapResolution(point: gridded(raw, gridStep), snap: gridSize > 0 ? .grid : .none)
    }

    // MARK: Points

    private func nearestPoint(_ raw: SIMD2<Double>, extra: [(SIMD2<Double>, SnapKind)], previous: SnapTarget?)
        -> (SIMD2<Double>, SnapKind)?
    {
        let hold = tolerance * settings.holdScale
        var candidates: [(position: SIMD2<Double>, kind: SnapKind, rank: Int, distance: Double)] = []
        func consider(_ p: SIMD2<Double>, _ kind: SnapKind) {
            guard let rank = settings.priorities[SnapCandidateKind(kind)] else { return }
            let d = snapDistance(p, raw)
            if d <= hold { candidates.append((p, kind, rank, d)) }
        }
        for p in targets.points(near: raw, within: hold) { consider(p.position, p.kind) }
        for (p, kind) in extra { consider(p, kind) }

        var best = candidates.filter { $0.distance <= tolerance }.min { ($0.rank, $0.distance) < ($1.rank, $1.distance) }
        // Hold the last point unless a better kind, or a clearly closer one of its kind, takes over.
        if case .point(let p, let kind)? = previous,
            let held = candidates.first(where: { $0.kind == kind && $0.position.isClose(to: p) })
        {
            if let b = best {
                let wins = b.rank < held.rank || (b.rank == held.rank && b.distance + settings.switchMargin * tolerance < held.distance)
                if !wins { best = held }
            } else {
                best = held
            }
        }
        return best.map { ($0.position, $0.kind) }
    }

    // MARK: Guides

    private func guided(_ raw: SIMD2<Double>, anchors: [SIMD2<Double>], gridStep: Double?, previous: SnapTarget?)
        -> SnapResolution?
    {
        let radius = tolerance * settings.guideScale
        let hold = radius * settings.holdScale
        typealias Candidate = (line: GuideLine, rank: Int, distance: Double)
        var candidates: [Candidate] = []

        if let rank = settings.priorities[.alignment] {
            // Every vertex lined up with the pointer, nearest along the guide first, so each guide
            // comes from the closest vertex on it.
            var vertices = anchors
            vertices += targets.points(xWithin: hold, of: raw.x).filter { settings.alignmentKinds.contains($0.kind) }.map(\.position)
            vertices += targets.points(yWithin: hold, of: raw.y).filter { settings.alignmentKinds.contains($0.kind) }.map(\.position)
            for v in vertices.sorted(by: { snapDistance($0, raw) < snapDistance($1, raw) }) {
                for line in [GuideLine(kind: .vertical, anchor: v, direction: SIMD2(0, 1)),
                             GuideLine(kind: .horizontal, anchor: v, direction: SIMD2(1, 0))]
                {
                    let d = line.distance(to: raw)
                    guard d <= hold, !candidates.contains(where: { $0.line.isSameLine(as: line) }) else { continue }
                    candidates.append((line, rank, d))
                }
            }
        }
        if let rank = settings.priorities[.extension] {
            for edge in targets.lines {
                let v = edge.b - edge.a
                let length = snapDistance(edge.a, edge.b)
                // Horizontal and vertical edges already guide from their ends.
                guard length > 1e-9, abs(v.x) > 1e-9 * length, abs(v.y) > 1e-9 * length else { continue }
                let direction = v / length
                let along = ((raw - edge.a) * direction).sum()
                guard along < 0 || along > length else { continue }  // past an end only
                let line = GuideLine(kind: .extension, anchor: along < 0 ? edge.a : edge.b, direction: direction)
                let d = line.distance(to: raw)
                guard d <= hold, !candidates.contains(where: { $0.line.isSameLine(as: line) }) else { continue }
                candidates.append((line, rank, d))
            }
        }
        guard !candidates.isEmpty else { return nil }

        var heldLines: [GuideLine] = []
        if case .guides(let lines)? = previous {
            heldLines = lines.compactMap { held in candidates.first { $0.line.isSameLine(as: held) }?.line }
            if heldLines.count != lines.count { heldLines = [] }
        }
        let inRange = candidates.filter { $0.distance <= radius }

        // Two guides that cross near the pointer satisfy both: the held pair, else the best pair.
        if heldLines.count == 2, let q = heldLines[0].intersection(with: heldLines[1]), snapDistance(q, raw) <= tolerance * settings.holdScale {
            return resolution(q, heldLines)
        }
        let ranked = Array(inRange.sorted { ($0.rank, $0.distance) < ($1.rank, $1.distance) }.prefix(8))
        var bestPair: (lines: [GuideLine], score: (Int, Double), point: SIMD2<Double>)?
        for i in ranked.indices {
            for j in (i + 1)..<ranked.count {
                guard let q = ranked[i].line.intersection(with: ranked[j].line) else { continue }
                let d = snapDistance(q, raw)
                guard d <= tolerance else { continue }
                let score = (ranked[i].rank + ranked[j].rank, d)
                if bestPair == nil || score < bestPair!.score { bestPair = ([ranked[i].line, ranked[j].line], score, q) }
            }
        }
        if let bestPair { return resolution(bestPair.point, bestPair.lines) }

        // One guide: the held one unless a better kind or a clearly closer one takes over.
        var best = ranked.first
        if heldLines.count == 1, let held = candidates.first(where: { $0.line.isSameLine(as: heldLines[0]) }) {
            if let b = best {
                let wins = b.rank < held.rank || (b.rank == held.rank && b.distance + settings.switchMargin * radius < held.distance)
                if !wins { best = held }
            } else {
                best = held
            }
        }
        guard let line = best?.line else { return nil }
        var p = line.project(raw)
        // Along a horizontal or vertical guide the free coordinate still snaps to the grid.
        let g = gridded(raw, gridStep)
        if line.kind == .horizontal { p.x = g.x }
        if line.kind == .vertical { p.y = g.y }
        return resolution(p, [line])
    }

    private func resolution(_ p: SIMD2<Double>, _ lines: [GuideLine]) -> SnapResolution {
        let snap: SketchSnap
        if lines.count == 2 {
            snap = .aligned
        } else {
            switch lines[0].kind {
            case .horizontal: snap = .horizontal
            case .vertical: snap = .vertical
            case .extension: snap = .extension
            }
        }
        return SnapResolution(point: p, snap: snap,
                              guides: lines.map { SnapGuide(kind: $0.kind, from: $0.anchor, to: p) },
                              markers: lines.map { .anchor($0.anchor) }, target: .guides(lines))
    }

    // MARK: Grid

    private func gridded(_ raw: SIMD2<Double>, _ gridStep: Double?) -> SIMD2<Double> {
        if gridSize > 0 {
            let step = gridStep ?? gridSize
            return (raw / step).rounded(.toNearestOrAwayFromZero) * step
        }
        return (raw * 100).rounded(.toNearestOrAwayFromZero) / 100
    }
}
