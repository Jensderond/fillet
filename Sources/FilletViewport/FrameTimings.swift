import Foundation
import Metal
import QuartzCore

/// Frame times over a stretch of drawing (`ViewportRenderer.beginFrameTimings`), so a scripted run
/// can say how smooth a drag was in numbers that repeat: how long the CPU took to prepare and
/// encode each frame, how long the GPU ran it, how far apart frames reached the screen, and how
/// long from an input (a drag step) to the first frame on screen that shows it. Milliseconds.
public struct FrameTimingReport: Sendable {
    /// CPU time per frame: uploads (`prepare`) and encoding.
    public var cpu: [Double] = []
    /// Time per frame spent waiting for a drawable (all of them still on their way to the screen).
    public var wait: [Double] = []
    /// GPU time per frame, from its command buffer's start and end.
    public var gpu: [Double] = []
    /// Time between consecutive frames reaching the screen.
    public var intervals: [Double] = []
    /// From an input to the frame that first shows it on screen.
    public var latency: [Double] = []
    /// Frames that reached the screen.
    public var presented = 0
    /// First to last present (seconds).
    public var seconds = 0.0

    /// Frames on screen a second over the stretch.
    public var fps: Double { seconds > 0 ? Double(max(presented - 1, 0)) / seconds : 0 }

    /// Frames that took more than one and a half of the usual frame interval to follow the last:
    /// a hitch you can see.
    public var hitches: Int {
        let usual = Self.percentile(intervals, 0.5)
        return intervals.filter { $0 > usual * 1.5 }.count
    }

    /// The `p`th quantile (0…1) by nearest rank, 0 for none.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// One line for a log: "59.9 fps, frame 16.7/17.1 ms (p50/p95), cpu 1.2/2.0, gpu 3.1/3.4, input → screen 24/31, 0 hitches".
    public var summary: String {
        func pair(_ v: [Double]) -> String {
            String(format: "%.1f/%.1f", Self.percentile(v, 0.5), Self.percentile(v, 0.95))
        }
        return String(format: "%.1f fps", fps) + ", frame \(pair(intervals)) ms (p50/p95, max "
            + String(format: "%.1f", intervals.max() ?? 0) + "), cpu \(pair(cpu)) (+ waiting for a drawable \(pair(wait))), gpu \(pair(gpu)), input → screen \(pair(latency)), "
            + "\(hitches) hitches over \(presented) frames"
    }
}

/// Collects `FrameTimingReport`'s samples. Command buffers finish and drawables present on Metal's
/// own threads, so it's locked.
final class FrameTimingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var report = FrameTimingReport()
    private var firstPresent: CFTimeInterval?
    private var lastPresent: CFTimeInterval?

    func addCPU(_ ms: Double, wait: Double) { lock.withLock { report.cpu.append(ms); report.wait.append(wait) } }
    func addGPU(_ ms: Double) { lock.withLock { report.gpu.append(ms) } }

    /// A frame reached the screen at `time` (0 when it never did); `input` is when the earliest
    /// input it shows came in.
    func presented(at time: CFTimeInterval, input: CFTimeInterval?) {
        guard time > 0 else { return }
        lock.withLock {
            if let last = lastPresent { report.intervals.append((time - last) * 1000) }
            if let input { report.latency.append((time - input) * 1000) }
            firstPresent = firstPresent ?? time
            lastPresent = time
            report.presented += 1
            report.seconds = time - (firstPresent ?? time)
        }
    }

    var snapshot: FrameTimingReport { lock.withLock { report } }
}

extension ViewportRenderer {
    /// Starts timing every frame drawn to the view (see `FrameTimingReport`), dropping what an
    /// earlier stretch collected.
    public func beginFrameTimings() {
        frameTimings = FrameTimingLog()
    }

    /// Stops timing and returns what was collected. Frames still on the GPU when it's called are
    /// left out, so let one more display refresh pass first.
    @discardableResult
    public func endFrameTimings() -> FrameTimingReport {
        defer { frameTimings = nil }
        return frameTimings?.snapshot ?? FrameTimingReport()
    }

    /// An input came in that the next frame shows (a drag step): `FrameTimingReport.latency` runs
    /// from here to the screen. Only the earliest since the last frame counts.
    public func noteInput() {
        guard frameTimings != nil, pendingInput == nil else { return }
        pendingInput = CACurrentMediaTime()
    }

    /// Hooks the frame being drawn up to the log: its GPU time and when it reaches the screen.
    func timeFrame(_ cb: MTLCommandBuffer, drawable: MTLDrawable, cpu: CFTimeInterval, wait: CFTimeInterval) {
        guard let log = frameTimings else { return }
        let input = pendingInput
        pendingInput = nil
        cb.addCompletedHandler { cb in
            if cb.gpuEndTime > cb.gpuStartTime { log.addGPU((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        drawable.addPresentedHandler { d in log.presented(at: d.presentedTime, input: input) }
        log.addCPU(cpu * 1000, wait: wait * 1000)
    }
}
