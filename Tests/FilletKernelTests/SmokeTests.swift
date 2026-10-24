import Testing
import CFilletKernel

@Test func boxVolume() {
    let box = fk_box(FKVec3(x: 0, y: 0, z: 0), FKVec3(x: 10, y: 20, z: 30))
    defer { fk_shape_free(box) }
    #expect(abs(fk_volume(box) - 6000) < 1e-6)
}
