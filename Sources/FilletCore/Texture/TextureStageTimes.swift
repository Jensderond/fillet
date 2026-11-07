import Foundation

/// Wall-clock time per stage of ``TextureEngine/apply(_:to:of:quality:)``, for benchmarks
/// (texture-lab `bench --stages`); off in the app.
///
/// Bound with `TextureStageTimes.$current.withValue(times) { … }` around a call on the same
/// thread. Unbound (the default), each stage boundary costs one task-local read, and nothing
/// the engine computes depends on it.
public final class TextureStageTimes: @unchecked Sendable {
    // Unchecked: only the thread running the engine call it is bound around marks it.

    /// The recorder the engine marks its stages on, if any.
    @TaskLocal public static var current: TextureStageTimes?

    /// Seconds per stage, in the order the stages first ran; a stage that runs more than once
    /// adds up.
    public private(set) var stages: [(name: String, seconds: Double)] = []
    private var last = ContinuousClock.now

    public init() {}

    /// Starts timing the next stage from now (time since the last mark is dropped).
    public func restart() { last = .now }

    /// Ends the stage `name`: the time since the last mark (or ``restart()``) is added to it.
    public func mark(_ name: String) {
        let now = ContinuousClock.now
        let d = now - last
        last = now
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        if let i = stages.firstIndex(where: { $0.name == name }) {
            stages[i].seconds += seconds
        } else {
            stages.append((name, seconds))
        }
    }
}
