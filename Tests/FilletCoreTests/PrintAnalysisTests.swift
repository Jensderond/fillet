import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Print analysis")
struct PrintAnalysisTests {
    @Test func presets() {
        #expect(PrinterPreset.bambuA1Mini.bedSize == SIMD3(180, 180, 180))
        #expect(PrinterPreset.bambuH2D.bedSize == SIMD3(325, 320, 325))
        #expect(PrinterPreset.prusaMK4.bedSize == SIMD3(250, 210, 220))
        #expect(PrinterPreset.prusaCoreOne.bedSize == SIMD3(250, 220, 270))
        #expect(Set(PrinterPreset.all.map(\.id)).count == PrinterPreset.all.count)
        #expect(PrinterPreset.preset(id: "bambu-p1s") == .bambuP1S)
        #expect(PrinterPreset.default == .bambuA1Mini)
    }

    @Test func cubeVolumeWeightAndWatertight() {
        let r = PrintAnalysis.analyze(meshes: [TestMeshes.cube(size: 10)], preset: .bambuA1Mini)
        #expect(abs(r.volume - 1000) < 1e-6)
        #expect(abs(r.grams(.pla) - 1.24) < 1e-9)
        #expect(abs(r.grams(.petg) - 1.27) < 1e-9)
        #expect(r.isWatertight)
        #expect(r.boundaryEdgeCount == 0)
        #expect(r.watertightIssue == nil)
        #expect(r.overhangCount == 0)  // bottom rests on the bed
        #expect(r.size == SIMD3(10, 10, 10))
        #expect(r.fitsOnBed && !r.fitsOnlyRotated)
    }

    @Test func soupIsWeldedForWatertightness() {
        let soup = TestMeshes.soup(TestMeshes.cube(size: 10))
        #expect(soup.positions.count == 36)
        #expect(PrintAnalysis.analyze(meshes: [soup], preset: .bambuA1).isWatertight)

        // Tiny gaps below the 1e-4 weld tolerance are closed too.
        var jittered = soup
        jittered.positions[5] += SIMD3(0.00003, 0, 0)
        #expect(PrintAnalysis.analyze(meshes: [jittered], preset: .bambuA1).isWatertight)
    }

    @Test func holesAndFlippedTrianglesAreNotWatertight() {
        var open = TestMeshes.cube(size: 10)
        open.indices.removeLast(3)
        let r1 = PrintAnalysis.analyze(meshes: [open], preset: .bambuA1)
        #expect(!r1.isWatertight)
        #expect(r1.boundaryEdgeCount == 3)
        #expect(r1.watertightIssue == "3 open edges")

        var flipped = TestMeshes.cube(size: 10)
        flipped.indices.swapAt(0, 1)
        let r2 = PrintAnalysis.analyze(meshes: [flipped], preset: .bambuA1)
        #expect(!r2.isWatertight)
        #expect(r2.nonManifoldEdgeCount == 3)
        // No holes, so the message names the non-manifold edges rather than "0 open edges".
        #expect(r2.boundaryEdgeCount == 0)
        #expect(r2.watertightIssue == "3 non-manifold edges")
        #expect(!PrintAnalysis.analyze(meshes: [], preset: .bambuA1).isWatertight)
    }

    @Test func overhangsOfInvertedPyramid() throws {
        let flat = PrintAnalysis.analyze(meshes: [TestMeshes.invertedPyramid(a: 10, h: 5)], preset: .bambuA1Mini)
        #expect(flat.overhangCount == 4)
        #expect(Set(flat.overhangTriangles.map(\.triangle)) == [2, 3, 4, 5])
        #expect(abs(flat.overhangArea - 4 * 10 * (125.0).squareRoot()) < 1e-3)
        #expect(abs(flat.volume - 400.0 * 5 / 3) < 1e-3)
        #expect(flat.isWatertight)

        // Steep sides (~27° from vertical) are fine at 45°, but not at 20°.
        let steep = [TestMeshes.invertedPyramid(a: 10, h: 20)]
        #expect(PrintAnalysis.analyze(meshes: steep, preset: .bambuA1Mini).overhangCount == 0)
        #expect(PrintAnalysis.analyze(meshes: steep, preset: .bambuA1Mini, overhangAngleDegrees: 20).overhangCount == 4)
    }

    @Test func floatingBodyBottomIsAnOverhangButBedContactIsNot() {
        let onBed = TestMeshes.cube(size: 10)
        let floating = TestMeshes.cube(SIMD3(20, 0, 5), size: 10)
        let r = PrintAnalysis.analyze(meshes: [onBed, floating], preset: .bambuA1Mini)
        #expect(r.overhangTriangles == [MeshTriangle(mesh: 1, triangle: 0), MeshTriangle(mesh: 1, triangle: 1)])
        #expect(abs(r.overhangArea - 100) < 1e-6)
        #expect(abs(r.volume - 2000) < 1e-6)
        #expect(r.boundsMin == SIMD3(0, 0, 0))
        #expect(r.boundsMax == SIMD3(30, 10, 15))
    }

    @Test func fitsOnBedWithRotation() {
        let mk4 = PrinterPreset.prusaMK4  // 250 × 210 × 220
        let wide = TestMeshes.box(size: SIMD3(230, 100, 10))
        let deep = TestMeshes.box(size: SIMD3(100, 230, 10))
        let huge = TestMeshes.box(size: SIMD3(260, 100, 10))
        let tall = TestMeshes.box(size: SIMD3(10, 10, 221))
        let a = PrintAnalysis.analyze(meshes: [wide], preset: mk4)
        #expect(a.fitsOnBed && !a.fitsOnlyRotated)
        let b = PrintAnalysis.analyze(meshes: [deep], preset: mk4)
        #expect(b.fitsOnBed && b.fitsOnlyRotated)
        #expect(!PrintAnalysis.analyze(meshes: [huge], preset: mk4).fitsOnBed)
        #expect(!PrintAnalysis.analyze(meshes: [tall], preset: mk4).fitsOnBed)
        #expect(PrintAnalysis.analyze(meshes: [TestMeshes.cube(size: 180)], preset: .bambuA1Mini).fitsOnBed)
    }
}
