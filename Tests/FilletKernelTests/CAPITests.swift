import CFilletKernel
import Foundation
import Testing
@testable import FilletKernel

/// The C API must never crash on bad input: NULL pointers, bad counts, bad indices.
@Suite("C API robustness")
struct CAPITests {
    private func lastError() -> String { String(cString: fk_last_error()) }

    @Test func nullShapesReturnErrors() {
        #expect(fk_shape_copy(nil) == nil)
        #expect(!lastError().isEmpty)
        #expect(fk_volume(nil) == 0)
        #expect(fk_surface_area(nil) == 0)
        #expect(fk_face_count(nil) == 0)
        #expect(fk_edge_count(nil) == 0)
        #expect(fk_solid_count(nil) == 0)
        #expect(fk_solids(nil) == nil)
        #expect(!fk_is_valid(nil))
        #expect(!fk_bounds(nil, nil, nil))
        #expect(fk_extrude(nil, FKVec3(x: 0, y: 0, z: 1), 1, 0, 0) == nil)
        #expect(fk_revolve(nil, FKVec3(), FKVec3(x: 0, y: 0, z: 1), 1) == nil)
        #expect(fk_boolean(nil, nil, FK_BOOL_FUSE) == nil)
        #expect(fk_fillet(nil, nil, 0, 1) == nil)
        #expect(fk_chamfer(nil, nil, 0, 1) == nil)
        #expect(fk_shell(nil, nil, 0, 1) == nil)
        #expect(fk_transform(nil, nil) == nil)
        #expect(fk_mirror(nil, FKPlane()) == nil)
        #expect(fk_tessellate(nil, 0.1, 0.5) == nil)
        #expect(fk_brep_write_string(nil) == nil)
        #expect(fk_brep_read_string(nil) == nil)
        #expect(fk_import_step(nil) == nil)
        #expect(!fk_export_step(nil, nil, 1, nil))
        #expect(fk_subshape_face(nil, 0) == nil)
        #expect(fk_subshape_edge(nil, 0) == nil)
        #expect(!fk_face_info(nil, 0, nil))
        #expect(!fk_edge_info(nil, 0, nil))
        #expect(!fk_face_plane(nil, 0, nil))
        #expect(!fk_distance(nil, nil, nil, nil, nil))
        #expect(fk_compound(nil, 3) == nil)
        fk_shape_free(nil)
        fk_list_free(nil)
        fk_mesh_free(nil)
        fk_string_free(nil)
    }

    @Test func nullListsAndMeshes() {
        #expect(fk_list_count(nil) == 0)
        #expect(fk_list_get(nil, 0) == nil)
        #expect(fk_region_containing(nil, FKPlane(), 0, 0) == -1)
        var u = 0.0, v = 0.0
        #expect(!fk_region_interior_point(nil, FKPlane(), &u, &v))
        #expect(fk_profile_from_regions(nil, nil, 1) == nil)
        #expect(fk_sketch_regions(FKPlane(), nil, 2) == nil)
        #expect(fk_sketch_regions(FKPlane(), nil, -1) == nil)
        #expect(fk_mesh_vertex_count(nil) == 0)
        #expect(fk_mesh_triangle_count(nil) == 0)
        #expect(fk_mesh_edge_count(nil) == 0)
        #expect(fk_mesh_positions(nil) == nil)
        var count: Int32 = 7
        #expect(fk_mesh_edge_points(nil, 0, &count) == nil)
        #expect(count == 0)
    }

    @Test func badIndicesAndOutputs() throws {
        let box = fk_box(FKVec3(), FKVec3(x: 1, y: 1, z: 1))
        defer { fk_shape_free(box) }
        var info = FKFaceInfo()
        #expect(!fk_face_info(box, 6, &info))
        #expect(lastError().contains("does not exist"))
        #expect(!fk_face_info(box, 0, nil))
        var edge = FKEdgeInfo()
        #expect(!fk_edge_info(box, Int32.max, &edge))
        #expect(!fk_edge_info(box, Int32.min, &edge))
        let mesh = fk_tessellate(box, 0.1, 0.5)
        defer { fk_mesh_free(mesh) }
        var count: Int32 = 0
        #expect(fk_mesh_edge_points(mesh, 12, &count) == nil)
        #expect(fk_mesh_edge_points(mesh, -1, &count) == nil)
        #expect(fk_mesh_edge_points(mesh, 0, &count) != nil && count == 2)
        // Sketch plane with a zero normal.
        var seg = FKSegment()
        seg.kind = FK_SEG_CIRCLE
        seg.p = (0, 0, 1, 0, 0, 0)
        #expect(fk_sketch_regions(FKPlane(), &seg, 1) == nil)
        #expect(lastError().contains("normal"))
        // Bogus segment kind is ignored.
        var plane = FKPlane()
        plane.normal = FKVec3(x: 0, y: 0, z: 1)
        plane.xDir = FKVec3(x: 1, y: 0, z: 0)
        seg.kind = FKSegmentKind(rawValue: 99)
        let list = fk_sketch_regions(plane, &seg, 1)
        defer { fk_list_free(list) }
        #expect(list != nil && fk_list_count(list) == 0)
    }

    @Test func errorIsClearedOnSuccess() {
        #expect(fk_shape_copy(nil) == nil)
        #expect(!lastError().isEmpty)
        let box = fk_box(FKVec3(), FKVec3(x: 1, y: 1, z: 1))
        defer { fk_shape_free(box) }
        #expect(box != nil)
        #expect(lastError().isEmpty)
    }

    @Test func errorIsPerThread() async {
        #expect(fk_shape_copy(nil) == nil)
        let mainError = lastError()
        let other = await Task.detached { () -> String in
            let box = fk_box(FKVec3(), FKVec3(x: 1, y: 1, z: 1))
            fk_shape_free(box)
            return String(cString: fk_last_error())
        }.value
        #expect(other.isEmpty)
        #expect(!mainError.isEmpty)
    }
}
