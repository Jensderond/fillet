// FilletKernel — a small C API over OpenCascade.
//
// Swift talks to the kernel only through this header, so no OCCT type ever
// leaks into Swift. All lengths are millimetres, all angles radians unless
// a parameter name says otherwise.
//
// Ownership: every function returning FKShape* / FKMesh* / FKShapeList* hands
// ownership to the caller, who must release it with the matching *_free.
// Errors: functions returning a pointer return NULL on failure, functions
// returning bool return false; fk_last_error() then describes the failure
// (thread-local, valid until the next kernel call on the same thread).
// Thread-safety: distinct shapes may be used from different threads; a single
// shape must not be used concurrently.

#ifndef FILLET_KERNEL_H
#define FILLET_KERNEL_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FKShape FKShape;
typedef struct FKMesh FKMesh;
typedef struct FKShapeList FKShapeList;

typedef struct { double x, y, z; } FKVec3;

/// Right-handed frame. normal and xDir must be unit length and orthogonal;
/// yDir = normal × xDir. Sketch coordinates (u, v) map to origin + u·xDir + v·yDir.
typedef struct { FKVec3 origin, normal, xDir; } FKPlane;

const char *fk_last_error(void);

// MARK: Shapes

void fk_shape_free(FKShape *shape);
FKShape *fk_shape_copy(const FKShape *shape);
/// Compound of several shapes (not fused).
FKShape *fk_compound(const FKShape *const *shapes, int32_t count);
/// Number of solids contained in the shape.
int32_t fk_solid_count(const FKShape *shape);
/// Splits a shape into its solids.
FKShapeList *fk_solids(const FKShape *shape);

int32_t fk_list_count(const FKShapeList *list);
/// Returns a new owned copy of the item.
FKShape *fk_list_get(const FKShapeList *list, int32_t index);
void fk_list_free(FKShapeList *list);

// MARK: Primitives

FKShape *fk_box(FKVec3 corner, FKVec3 size);
/// Cylinder standing on `base` (axis = base.normal).
FKShape *fk_cylinder(FKPlane base, double radius, double height);
FKShape *fk_sphere(FKVec3 center, double radius);
/// Cone/frustum standing on `base`; either radius may be 0.
FKShape *fk_cone(FKPlane base, double radius1, double radius2, double height);
/// Torus centred on `base`, axis = base.normal.
FKShape *fk_torus(FKPlane base, double majorRadius, double minorRadius);

// MARK: Sketch profiles

typedef enum {
  FK_SEG_LINE = 0,    // p = x0,y0, x1,y1
  FK_SEG_ARC = 1,     // p = start x,y, a point on the arc x,y, end x,y
  FK_SEG_CIRCLE = 2,  // p = cx,cy, r
  FK_SEG_BSPLINE = 3, // interpolates `points` (x,y pairs, pointCount pairs)
} FKSegmentKind;

typedef struct {
  FKSegmentKind kind;
  double p[6];
  const double *points;
  int32_t pointCount;
} FKSegment;

/// Splits an arbitrary arrangement of 2D segments drawn on `plane` into the
/// bounded planar regions they enclose (like Fusion's profile detection:
/// overlapping circles yield three regions, a line across a rectangle splits
/// it in two). Each region is a planar face, holes included. Open segments
/// that enclose nothing are ignored. Returns an empty list if there are no
/// closed regions.
FKShapeList *fk_sketch_regions(FKPlane plane, const FKSegment *segments, int32_t count);

/// Index of the region in `regions` containing the plane point (u, v), or -1.
int32_t fk_region_containing(const FKShapeList *regions, FKPlane plane, double u, double v);

/// A point strictly inside the region face, in plane coordinates (for
/// persisting a region selection across recomputes).
bool fk_region_interior_point(const FKShape *region, FKPlane plane, double *u, double *v);

/// Fuses the given faces of a list into one profile shape (faces that touch are merged).
FKShape *fk_profile_from_regions(const FKShapeList *regions, const int32_t *indices, int32_t count);

// MARK: Features

/// Prism of `profile` (face/faces) along unit vector `dir`: from -distanceBack
/// to +distance. taperRadians > 0 narrows the solid as it grows (draft).
FKShape *fk_extrude(const FKShape *profile, FKVec3 dir, double distance, double distanceBack,
                    double taperRadians);

/// Revolves `profile` around the axis by `angle` radians (2π = full).
FKShape *fk_revolve(const FKShape *profile, FKVec3 axisOrigin, FKVec3 axisDir, double angle);

typedef enum { FK_BOOL_FUSE = 0, FK_BOOL_CUT = 1, FK_BOOL_COMMON = 2 } FKBoolOp;

/// a op b. Result is cleaned up (coplanar faces merged).
FKShape *fk_boolean(const FKShape *a, const FKShape *b, FKBoolOp op);
/// a op (all tools) in one operation, so intersections and clean-up run once. Fuse joins
/// everything; cut removes every tool; common keeps what is inside every tool.
FKShape *fk_boolean_tools(const FKShape *a, const FKShape *const *tools, int32_t count, FKBoolOp op);

/// Constant-radius fillet on the edges (indices as in fk_edge_info).
FKShape *fk_fillet(const FKShape *shape, const int32_t *edgeIndices, int32_t count, double radius);
/// Equal-distance chamfer on the edges.
FKShape *fk_chamfer(const FKShape *shape, const int32_t *edgeIndices, int32_t count, double distance);
/// Hollows the solid, removing the given faces (may be empty for a closed
/// hollow). Positive thickness grows the wall inward.
FKShape *fk_shell(const FKShape *shape, const int32_t *faceIndices, int32_t count, double thickness);
/// Press Pull (Fusion's offset face): moves the given faces along their outward normals by
/// `distance`; positive adds material, negative removes it. Neighbouring faces stretch to
/// follow. The body must be one solid and stays one.
FKShape *fk_offset_faces(const FKShape *shape, const int32_t *faceIndices, int32_t count, double distance);

typedef enum { FK_HOLE_SIMPLE = 0, FK_HOLE_COUNTERBORE = 1, FK_HOLE_COUNTERSINK = 2 } FKHoleType;

/// Size of the holes fk_holes drills (like Fusion's hole types).
typedef struct {
  FKHoleType type;
  double diameter;
  /// Depth of the full-diameter part from the face (the drill point adds below it); <= 0 = through all.
  double depth;
  /// Drill point included angle (e.g. 118°); 0 = flat bottom. Through-all holes ignore it.
  double tipAngle;
  /// Counterbore or countersink diameter at the face.
  double headDiameter;
  /// Counterbore depth.
  double headDepth;
  /// Countersink included angle (e.g. 90°).
  double headAngle;
} FKHoleSpec;

/// Drills one hole per centre (points on the face drilled into) along unit vector `dir` (into
/// the material), all the same size, in one boolean cut.
FKShape *fk_holes(const FKShape *shape, const FKVec3 *centers, int32_t count, FKVec3 dir, const FKHoleSpec *spec);

/// One cross-section of a loft: an ellipse in `frame` (width along xDir, height along
/// yDir; equal = circle). Width and height 0 make a point (first or last section only).
typedef struct {
  FKPlane frame;
  double width, height;
} FKLoftSection;

/// Solid skinned through the sections in order: a smooth surface, or straight
/// (ruled) between neighbouring sections.
FKShape *fk_loft(const FKLoftSection *sections, int32_t count, bool ruled);

/// Affine transform, row-major 3×4 matrix [R | t].
FKShape *fk_transform(const FKShape *shape, const double matrix[12]);
FKShape *fk_mirror(const FKShape *shape, FKPlane plane);

// MARK: Topology & analysis
//
// Face and edge indices are the 0-based positions in OCCT's TopExp::MapShapes
// order for that exact shape. They are stable for a given shape but change
// whenever the shape is rebuilt; FilletCore re-resolves references by matching
// the geometric signature below.

typedef enum {
  FK_SURF_PLANE = 0, FK_SURF_CYLINDER = 1, FK_SURF_CONE = 2, FK_SURF_SPHERE = 3,
  FK_SURF_TORUS = 4, FK_SURF_BSPLINE = 5, FK_SURF_OTHER = 6
} FKSurfaceType;

typedef enum {
  FK_CURVE_LINE = 0, FK_CURVE_CIRCLE = 1, FK_CURVE_ELLIPSE = 2, FK_CURVE_BSPLINE = 3,
  FK_CURVE_OTHER = 4
} FKCurveType;

typedef struct {
  FKSurfaceType surface;
  FKVec3 centroid;  // area centroid
  FKVec3 normal;    // outward normal at the point closest to the centroid
  double area;
  FKVec3 boundsMin, boundsMax;
} FKFaceInfo;

typedef struct {
  FKCurveType curve;
  FKVec3 start, mid, end; // mid = point at half the parameter range
  FKVec3 tangentAtMid;    // unit
  double length;
  double radius;          // circles only, else 0
} FKEdgeInfo;

int32_t fk_face_count(const FKShape *shape);
int32_t fk_edge_count(const FKShape *shape);
/// Vertices are indexed like faces and edges (TopExp::MapShapes order).
int32_t fk_vertex_count(const FKShape *shape);
bool fk_vertex_point(const FKShape *shape, int32_t vertexIndex, FKVec3 *out);
bool fk_face_info(const FKShape *shape, int32_t faceIndex, FKFaceInfo *out);
/// fk_face_info for every face at once, computed in parallel. `out` and `ok` have room for
/// `count` entries, which must equal fk_face_count; ok[i] tells whether out[i] could be computed.
bool fk_face_infos(const FKShape *shape, FKFaceInfo *out, bool *ok, int32_t count);
bool fk_edge_info(const FKShape *shape, int32_t edgeIndex, FKEdgeInfo *out);
/// Marks the edges a fillet or chamfer can't use: degenerate ones (a sphere's pole) and seams
/// where a face meets itself (a cylinder's or sphere's closing line). `out` has room for
/// `count` flags, which must equal fk_edge_count; out[i] is set for edge i.
bool fk_seam_edges(const FKShape *shape, bool *out, int32_t count);
/// Edges joined to edge `edgeIndex` with tangent (G1) continuity, like Fusion's tangent chain:
/// from each end the walk carries on into every edge that leaves the shared vertex in the same
/// direction, within `angleTolerance` radians, and so on from there. Seams and degenerate edges
/// never join a chain. `out` has room for `count` flags, which must equal fk_edge_count; out[i]
/// is set for every edge of the chain, the seed included (a seam seed is its own chain).
bool fk_tangent_chain(const FKShape *shape, int32_t edgeIndex, double angleTolerance, bool *out, int32_t count);
/// The boundary loops (wires) of a face: loopOf[i] is the loop edge i belongs to on that face, 0
/// for the outer boundary and 1, 2… for holes, or -1 when the edge doesn't bound the face.
/// `loopOf` has room for `count` entries, which must equal fk_edge_count.
bool fk_face_loops(const FKShape *shape, int32_t faceIndex, int32_t *loopOf, int32_t count);
/// The faces edge `edgeIndex` bounds (two for an ordinary edge, one for a seam), in face index
/// order. Writes up to `capacity` indices to `faces` and returns how many faces there are, or -1.
int32_t fk_edge_faces(const FKShape *shape, int32_t edgeIndex, int32_t *faces, int32_t capacity);
/// Plane of a planar face, origin at the face centroid, normal outward,
/// xDir aligned with the face's longest straight edge when there is one.
/// Returns false for non-planar faces.
bool fk_face_plane(const FKShape *shape, int32_t faceIndex, FKPlane *out);

bool fk_bounds(const FKShape *shape, FKVec3 *min, FKVec3 *max);
double fk_volume(const FKShape *shape);
double fk_surface_area(const FKShape *shape);
/// Volume and surface area by adaptive integration to a relative error of `eps` per face
/// (e.g. 1e-9). Much slower than fk_volume/fk_surface_area, but stable when only how a curve
/// is represented changes. Either output may be null.
bool fk_mass_properties(const FKShape *shape, double eps, double *volume, double *area);
/// BRepCheck validity (true = valid closed geometry).
bool fk_is_valid(const FKShape *shape);

/// Shortest distance between two (sub)shapes, with the closest points.
bool fk_distance(const FKShape *a, const FKShape *b, double *distance, FKVec3 *pointA, FKVec3 *pointB);
/// Copy of one face or edge of a shape as a standalone shape (for measuring).
FKShape *fk_subshape_face(const FKShape *shape, int32_t faceIndex);
FKShape *fk_subshape_edge(const FKShape *shape, int32_t edgeIndex);
FKShape *fk_subshape_vertex(const FKShape *shape, int32_t vertexIndex);

/// Radius of a cylindrical or spherical face. Returns false for any other surface.
bool fk_face_radius(const FKShape *shape, int32_t faceIndex, double *radius);
/// Angle between two (sub)shapes, each a flat face or a straight edge, in radians. Between two
/// edges, or an edge and a face, 0…π/2 (a line has no direction); between two faces, the angle
/// between their outward normals, 0…π (adjacent box faces 90°, opposite ones 180°). Returns
/// false for any other pair.
bool fk_angle(const FKShape *a, const FKShape *b, double *radians);

// MARK: Tessellation

/// Triangulates the shape. Triangles are grouped per face so every triangle
/// knows the face index it came from; every topological edge also gets a
/// polyline for drawing crisp outlines. `parallel` meshes the faces on OCCT's thread pool, which
/// the kernel sizes so that several shapes meshed at once each get threads. The mesh is the same
/// either way.
FKMesh *fk_tessellate(const FKShape *shape, double linearDeflection, double angularDeflection, bool parallel);
void fk_mesh_free(FKMesh *mesh);

int32_t fk_mesh_vertex_count(const FKMesh *mesh);
const float *fk_mesh_positions(const FKMesh *mesh);       // xyz × vertexCount
const float *fk_mesh_normals(const FKMesh *mesh);         // xyz × vertexCount
int32_t fk_mesh_triangle_count(const FKMesh *mesh);
const uint32_t *fk_mesh_indices(const FKMesh *mesh);      // 3 × triangleCount
const int32_t *fk_mesh_triangle_faces(const FKMesh *mesh); // face index × triangleCount
int32_t fk_mesh_edge_count(const FKMesh *mesh);            // == fk_edge_count(shape)
/// Polyline points of edge i (xyz × *pointCount).
const float *fk_mesh_edge_points(const FKMesh *mesh, int32_t edgeIndex, int32_t *pointCount);
/// Position of every B-rep vertex, indexed like fk_vertex_point (xyz × *count).
const float *fk_mesh_brep_vertices(const FKMesh *mesh, int32_t *count);

/// Where `plane` cuts the shape: the exact lines it meets the faces in (a section view's outline),
/// as polylines discretised like fk_tessellate's edges, one per section edge, in the mesh's edge
/// lists (it has no triangles). No edges when the plane misses the shape.
FKMesh *fk_section(const FKShape *shape, FKPlane plane, double linearDeflection, double angularDeflection);

// MARK: Exchange

FKShape *fk_import_step(const char *path);
/// Writes the shapes as separate named solids in one STEP file (AP214).
bool fk_export_step(const FKShape *const *shapes, const char *const *names, int32_t count,
                    const char *path);
/// Native OCCT text serialisation (used to embed imported geometry in documents).
char *fk_brep_write_string(const FKShape *shape); // free with fk_string_free
FKShape *fk_brep_read_string(const char *data);
void fk_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
