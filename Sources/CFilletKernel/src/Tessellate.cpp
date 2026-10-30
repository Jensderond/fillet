// Triangulation for display/export: per-face triangles with smooth normals, per-edge polylines.
#include "Internal.hpp"

#include <BRepAdaptor_Curve.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <Poly_Connect.hxx>
#include <Poly_Polygon3D.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Vertex.hxx>

#include <cmath>

using namespace fk;

namespace {

void pushPoint(std::vector<float> &out, const gp_Pnt &p) {
  out.push_back((float)p.X());
  out.push_back((float)p.Y());
  out.push_back((float)p.Z());
}

/// Polyline of an edge, preferably the polygon-on-triangulation of an adjacent face.
std::vector<float> edgePolyline(const TopoDS_Edge &edge, const ShapeList *faces, double linDefl, double angDefl) {
  std::vector<float> pts;
  if (BRep_Tool::Degenerated(edge)) return pts;
  if (faces) {
    for (ShapeList::Iterator it(*faces); it.More(); it.Next())
      if (BRep_Tool::IsClosed(edge, TopoDS::Face(it.Value()))) return pts; // seam: not drawn
    for (ShapeList::Iterator it(*faces); it.More(); it.Next()) {
      const TopoDS_Face &face = TopoDS::Face(it.Value());
      TopLoc_Location loc;
      occ::handle<Poly_Triangulation> tri = BRep_Tool::Triangulation(face, loc);
      if (tri.IsNull()) continue;
      occ::handle<Poly_PolygonOnTriangulation> poly = BRep_Tool::PolygonOnTriangulation(edge, tri, loc);
      if (poly.IsNull()) continue;
      const gp_Trsf &tr = loc.Transformation();
      const auto &nodes = poly->Nodes();
      for (int i = nodes.Lower(); i <= nodes.Upper(); i++) pushPoint(pts, tri->Node(nodes(i)).Transformed(tr));
      return pts;
    }
  }
  TopLoc_Location loc;
  occ::handle<Poly_Polygon3D> p3d = BRep_Tool::Polygon3D(edge, loc);
  if (!p3d.IsNull()) {
    const gp_Trsf &tr = loc.Transformation();
    const auto &nodes = p3d->Nodes();
    for (int i = nodes.Lower(); i <= nodes.Upper(); i++) pushPoint(pts, nodes(i).Transformed(tr));
    return pts;
  }
  BRepAdaptor_Curve c(edge);
  GCPnts_TangentialDeflection disc(c, angDefl, linDefl);
  for (int i = 1; i <= disc.NbPoints(); i++) pushPoint(pts, disc.Value(i));
  return pts;
}

} // namespace

extern "C" FKMesh *fk_tessellate(const FKShape *shape, double linearDeflection, double angularDeflection,
                                 bool parallel) {
  return guarded("Tessellation", (FKMesh *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    if (!isFinite(linearDeflection) || linearDeflection <= 0) fail("Tessellation tolerance must be positive");
    if (!isFinite(angularDeflection) || angularDeflection <= 0) angularDeflection = 0.5;
    linearDeflection = std::max(linearDeflection, 1e-4);
    angularDeflection = std::min(std::max(angularDeflection, 0.01), 1.0);

    // Mesh a copy so the shared input topology is never mutated (other threads
    // may be reading shapes that share sub-shapes with this one).
    BRepBuilderAPI_Copy copier(s, false, false);
    TopoDS_Shape work = copier.Shape();
    BRepMesh_IncrementalMesh mesher(work, linearDeflection, false, angularDeflection, parallel);
    if (!mesher.IsDone()) fail("Tessellation failed");

    auto mesh = std::make_unique<FKMesh>();
    const ShapeMap &faces = shape->faces();
    const ShapeMap &edges = shape->edges();

    Poly_Connect connect;
    for (int fi = 1; fi <= faces.Extent(); fi++) {
      const TopoDS_Shape &orig = faces(fi);
      TopoDS_Face face = TopoDS::Face(copier.ModifiedShape(orig));
      face.Orientation(orig.Orientation());
      TopLoc_Location loc;
      occ::handle<Poly_Triangulation> tri = BRep_Tool::Triangulation(face, loc);
      if (tri.IsNull() || tri->NbTriangles() == 0) continue;
      BRepLib_ToolTriangulatedShape::ComputeNormals(face, tri, connect);
      const gp_Trsf &tr = loc.Transformation();
      const bool reversed = face.Orientation() == TopAbs_REVERSED;
      const uint32_t base = (uint32_t)(mesh->positions.size() / 3);
      for (int i = 1; i <= tri->NbNodes(); i++) {
        pushPoint(mesh->positions, tri->Node(i).Transformed(tr));
        gp_Dir n = tri->HasNormals() ? tri->Normal(i) : gp_Dir(0, 0, 1);
        n.Transform(tr);
        if (reversed) n.Reverse();
        mesh->normals.push_back((float)n.X());
        mesh->normals.push_back((float)n.Y());
        mesh->normals.push_back((float)n.Z());
      }
      for (int i = 1; i <= tri->NbTriangles(); i++) {
        int a, b, c;
        tri->Triangle(i).Get(a, b, c);
        if (reversed) std::swap(b, c);
        mesh->indices.push_back(base + a - 1);
        mesh->indices.push_back(base + b - 1);
        mesh->indices.push_back(base + c - 1);
        mesh->triangleFaces.push_back(fi - 1);
      }
    }

    AncestorMap edgeFaces;
    TopExp::MapShapesAndAncestors(work, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    mesh->edges.reserve(edges.Extent());
    for (int ei = 1; ei <= edges.Extent(); ei++) {
      TopoDS_Edge edge = TopoDS::Edge(copier.ModifiedShape(edges(ei)));
      mesh->edges.push_back(edgePolyline(edge, edgeFaces.Seek(edge), linearDeflection, angularDeflection));
    }
    const ShapeMap &vertices = shape->vertices();
    mesh->brepVertices.reserve(3 * vertices.Extent());
    for (int vi = 1; vi <= vertices.Extent(); vi++) pushPoint(mesh->brepVertices, BRep_Tool::Pnt(TopoDS::Vertex(vertices(vi))));
    return mesh.release();
  });
}

// MARK: Sections

extern "C" FKMesh *fk_section(const FKShape *shape, FKPlane plane, double linearDeflection, double angularDeflection) {
  return guarded("Section", (FKMesh *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    if (!isFinite(linearDeflection) || linearDeflection <= 0) fail("Section tolerance must be positive");
    if (!isFinite(angularDeflection) || angularDeflection <= 0) angularDeflection = 0.1;
    linearDeflection = std::max(linearDeflection, 1e-4);
    angularDeflection = std::min(std::max(angularDeflection, 0.01), 1.0);
    // The plane's own face is made by the algorithm, sized to the shape; the shape is only read
    // (other threads may be drawing or measuring it meanwhile).
    BRepAlgoAPI_Section section(s, pln(plane), false);
    section.SetNonDestructive(true);
    section.SetRunParallel(true);
    section.ComputePCurveOn1(false);
    section.ComputePCurveOn2(false);
    // Curved faces meet the plane in curves that are fitted to the exact intersection, not
    // left as the walking line's points.
    section.Approximation(true);
    section.Build();
    if (!section.IsDone() || section.HasErrors()) fail("The plane could not be intersected with the body");
    auto mesh = std::make_unique<FKMesh>();
    for (TopExp_Explorer ex(section.Shape(), TopAbs_EDGE); ex.More(); ex.Next()) {
      std::vector<float> pts = edgePolyline(TopoDS::Edge(ex.Current()), nullptr, linearDeflection, angularDeflection);
      if (pts.size() >= 6) mesh->edges.push_back(std::move(pts));
    }
    return mesh.release();
  });
}

extern "C" void fk_mesh_free(FKMesh *mesh) { delete mesh; }

extern "C" int32_t fk_mesh_vertex_count(const FKMesh *mesh) { return mesh ? (int32_t)(mesh->positions.size() / 3) : 0; }
extern "C" const float *fk_mesh_positions(const FKMesh *mesh) {
  return mesh && !mesh->positions.empty() ? mesh->positions.data() : nullptr;
}
extern "C" const float *fk_mesh_normals(const FKMesh *mesh) {
  return mesh && !mesh->normals.empty() ? mesh->normals.data() : nullptr;
}
extern "C" int32_t fk_mesh_triangle_count(const FKMesh *mesh) { return mesh ? (int32_t)(mesh->indices.size() / 3) : 0; }
extern "C" const uint32_t *fk_mesh_indices(const FKMesh *mesh) {
  return mesh && !mesh->indices.empty() ? mesh->indices.data() : nullptr;
}
extern "C" const int32_t *fk_mesh_triangle_faces(const FKMesh *mesh) {
  return mesh && !mesh->triangleFaces.empty() ? mesh->triangleFaces.data() : nullptr;
}
extern "C" int32_t fk_mesh_edge_count(const FKMesh *mesh) { return mesh ? (int32_t)mesh->edges.size() : 0; }
extern "C" const float *fk_mesh_edge_points(const FKMesh *mesh, int32_t edgeIndex, int32_t *pointCount) {
  if (pointCount) *pointCount = 0;
  if (!mesh || edgeIndex < 0 || edgeIndex >= (int32_t)mesh->edges.size()) return nullptr;
  const auto &e = mesh->edges[edgeIndex];
  if (pointCount) *pointCount = (int32_t)(e.size() / 3);
  return e.empty() ? nullptr : e.data();
}
extern "C" const float *fk_mesh_brep_vertices(const FKMesh *mesh, int32_t *count) {
  if (count) *count = mesh ? (int32_t)(mesh->brepVertices.size() / 3) : 0;
  return mesh && !mesh->brepVertices.empty() ? mesh->brepVertices.data() : nullptr;
}
