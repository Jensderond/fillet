import Foundation

/// Inertia after a flick, the way scroll views coast: the velocity decays exponentially by
/// `decelerationRate` per millisecond (0.998 is UIScrollView's normal rate, lower stops sooner),
/// independent of the frame rate.
public struct Momentum: Hashable, Sendable {
    /// Current velocity in points per second.
    public private(set) var velocity: SIMD2<Double>
    /// Fraction of the velocity kept per millisecond.
    public let decelerationRate: Double

    /// Below this speed (points per second) the motion is over.
    public static let stopSpeed = 12.0
    /// Slower releases than this don't start any momentum (the finger came to rest).
    public static let startSpeed = 120.0

    /// Orbiting coasts a little less far than panning: rotation overshoots feel loose.
    public static let orbitRate = 0.994
    public static let panRate = 0.996

    public init(velocity: SIMD2<Double>, decelerationRate: Double) {
        self.velocity = velocity
        self.decelerationRate = min(max(decelerationRate, 0.5), 0.9999)
    }

    /// A flick fast enough to coast, or nil.
    public static func flick(_ velocity: SIMD2<Double>, decelerationRate: Double) -> Momentum? {
        (velocity * velocity).sum().squareRoot() >= startSpeed ? Momentum(velocity: velocity, decelerationRate: decelerationRate) : nil
    }

    public var speed: Double { (velocity * velocity).sum().squareRoot() }
    public var isFinished: Bool { speed < Self.stopSpeed }

    /// Decay constant per second (negative).
    private var k: Double { 1000 * log(decelerationRate) }

    /// Advances `dt` seconds and returns the distance travelled in that time (points).
    public mutating func step(_ dt: Double) -> SIMD2<Double> {
        guard dt > 0, !isFinished else { return .zero }
        let factor = exp(k * dt)
        let travelled = velocity * ((factor - 1) / k)
        velocity *= factor
        return travelled
    }

    /// How far it still travels if left alone (points).
    public var remainingDistance: SIMD2<Double> { velocity / -k }

    /// How far a one-dimensional flick at `velocity` (points per second) travels.
    public static func projectedDistance(velocity: Double, decelerationRate: Double = 0.998) -> Double {
        velocity / (-1000 * log(min(max(decelerationRate, 0.5), 0.9999)))
    }

    /// Where something released at `position` with `velocity` should settle among `stops`
    /// (drawer detents): the stop nearest to where the flick would carry it. A flick faster
    /// than `flickSpeed` always moves at least one stop in its direction (Emil Kowalski's
    /// momentum dismissal: a quick flick is enough, whatever the distance).
    public static func restingPoint(from position: Double, velocity: Double, among stops: [Double],
                                    decelerationRate: Double = 0.998, flickSpeed: Double = 300) -> Double {
        let sorted = stops.sorted()
        guard let first = sorted.first else { return position }
        let projected = position + projectedDistance(velocity: velocity, decelerationRate: decelerationRate)
        var target = sorted.min { abs($0 - projected) < abs($1 - projected) } ?? first
        if abs(velocity) >= flickSpeed {
            let nearest = sorted.min { abs($0 - position) < abs($1 - position) } ?? first
            if velocity > 0, target <= nearest, let next = sorted.first(where: { $0 > nearest + 0.5 }) { target = next }
            if velocity < 0, target >= nearest, let next = sorted.last(where: { $0 < nearest - 0.5 }) { target = next }
        }
        return target
    }

    /// Resistance past a limit: the further it's pulled, the less it gives, up to 100 points.
    public static func rubberBand(_ value: Double, in range: ClosedRange<Double>, stiffness: Double = 0.55) -> Double {
        func damp(_ x: Double) -> Double { 100 * (1 - 1 / (1 + x * stiffness / 100)) }
        if value > range.upperBound { return range.upperBound + damp(value - range.upperBound) }
        if value < range.lowerBound { return range.lowerBound - damp(range.lowerBound - value) }
        return value
    }
}
