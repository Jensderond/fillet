import Foundation
import Testing
@testable import FilletViewport

@Suite("Momentum")
struct MomentumTests {
    private func coast(_ m: Momentum, fps: Double) -> (distance: SIMD2<Double>, frames: Int) {
        var m = m
        var total = SIMD2<Double>(0, 0)
        var frames = 0
        while !m.isFinished && frames < 10_000 {
            total += m.step(1 / fps)
            frames += 1
        }
        return (total, frames)
    }

    @Test func travelsTheProjectedDistance() {
        let m = Momentum(velocity: SIMD2(1200, -400), decelerationRate: Momentum.panRate)
        let expected = m.remainingDistance
        let (travelled, _) = coast(m, fps: 120)
        // It stops at `stopSpeed`, a hair short of the analytic limit.
        #expect(abs(travelled.x - expected.x) < 5 && abs(travelled.y - expected.y) < 2)
        #expect(abs(Momentum.projectedDistance(velocity: 1200, decelerationRate: Momentum.panRate) - expected.x) < 1e-9)
    }

    @Test func isFrameRateIndependent() {
        let m = Momentum(velocity: SIMD2(900, 300), decelerationRate: Momentum.orbitRate)
        let at60 = coast(m, fps: 60).distance, at120 = coast(m, fps: 120).distance
        #expect(abs(at60.x - at120.x) < 3 && abs(at60.y - at120.y) < 1)
    }

    @Test func decaysMonotonicallyAndStops() {
        var m = Momentum(velocity: SIMD2(2000, 0), decelerationRate: Momentum.orbitRate)
        var last = m.speed
        var frames = 0
        while !m.isFinished {
            _ = m.step(1 / 120)
            #expect(m.speed < last)
            last = m.speed
            frames += 1
        }
        // A fast orbit flick settles in well under a second and a half.
        #expect(frames < 180)
        #expect(m.step(1 / 120) == .zero)
    }

    @Test func slowReleasesDontCoast() {
        #expect(Momentum.flick(SIMD2(60, 40), decelerationRate: Momentum.panRate) == nil)
        #expect(Momentum.flick(SIMD2(600, 0), decelerationRate: Momentum.panRate) != nil)
    }

    @Test func drawerSettlesOnTheNearestDetent() {
        let detents = [150.0, 340, 560]
        // Released slowly between detents: nearest wins.
        #expect(Momentum.restingPoint(from: 420, velocity: 0, among: detents) == 340)
        #expect(Momentum.restingPoint(from: 480, velocity: 20, among: detents) == 560)
    }

    @Test func aFlickMovesAtLeastOneDetent() {
        let detents = [150.0, 340, 560]
        // A short, quick flick up from the middle detent still opens the drawer fully.
        #expect(Momentum.restingPoint(from: 352, velocity: 400, among: detents) == 560)
        // And a quick flick down from the top goes to the middle, not past it.
        #expect(Momentum.restingPoint(from: 548, velocity: -400, among: detents) == 340)
        // A hard flick projects past the next detent and lands further.
        #expect(Momentum.restingPoint(from: 548, velocity: -3000, among: detents) == 150)
        // No detent beyond the last one.
        #expect(Momentum.restingPoint(from: 560, velocity: 900, among: detents) == 560)
    }

    @Test func rubberBandResistsPastTheLimits() {
        let range = 150.0...560
        #expect(Momentum.rubberBand(400, in: range) == 400)
        let over = Momentum.rubberBand(660, in: range)
        #expect(over > 560 && over < 600)
        let further = Momentum.rubberBand(760, in: range)
        #expect(further > over && further - over < over - 560)
        #expect(Momentum.rubberBand(100, in: range) < 150)
    }
}
