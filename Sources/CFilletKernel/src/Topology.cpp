// Topology queries and analysis: face/edge info, face planes, bounds, mass properties, distance.
#include "Internal.hpp"

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GProp_GProps.hxx>
#include <GeomLib_IsPlanarSurface.hxx>
#include <OSD_Parallel.hxx>
#include <Geom_Surface.hxx>
#include <Precision.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Vertex.hxx>

#include <cmath>

using namespace fk;

namespace {

const TopoDS_Face &faceAt(const FKShape *shape, int32_t index) {
  const ShapeMap &faces = shape->faces();
  if (index < 0 || index >= faces.Extent())
    fail("Face " + std::to_string(index) + " does not exist (the body has " + std::to_string(faces.Extent()) +
         " faces)");
  return TopoDS::Face(faces(index + 1));
}

const TopoDS_Edge &edgeAt(const FKShape *shape, int32_t index) {
  const ShapeMap &edges = shape->edges();
  if (index < 0 || index >= edges.Extent())
    fail("Edge " + std::to_string(index) + " does not exist (the body has " + std::to_string(edges.Extent()) +
         " edges)");
  return TopoDS::Edge(edges(index + 1));
}

FKSurfaceType surfaceType(GeomAbs_SurfaceType t) {
  switch (t) {
  case GeomAbs_Plane: return FK_SURF_PLANE;
  case GeomAbs_Cylinder: return FK_SURF_CYLINDER;
  case GeomAbs_Cone: return FK_SURF_CONE;
  case GeomAbs_Sphere: return FK_SURF_SPHERE;
  case GeomAbs_Torus: return FK_SURF_TORUS;
  case GeomAbs_BSplineSurface:
  case GeomAbs_BezierSurface: return FK_SURF_BSPLINE;
  default: return FK_SURF_OTHER;
  }
}

FKCurveType curveType(GeomAbs_CurveType t) {
  switch (t) {
  case GeomAbs_Line: return FK_CURVE_LINE;
  case GeomAbs_Circle: return FK_CURVE_CIRCLE;
  case GeomAbs_Ellipse: return FK_CURVE_ELLIPSE;
  case GeomAbs_BSplineCurve:
  case GeomAbs_BezierCurve: return FK_CURVE_BSPLINE;
  default: return FK_CURVE_OTHER;
  }
}

/// Outward normal (respecting face orientation) at the face point closest to `target`.
gp_Dir normalNear(const TopoDS_Face &face, const gp_Pnt &target, gp_Pnt *onFace = nullptr) {
  double u = 0, v = 0;
  bool found = false;
  TopLoc_Location loc;
  occ::handle<Geom_Surface> surf = BRep_Tool::Surface(face, loc);
  if (!surf.IsNull()) {
    ShapeAnalysis_Surface sas(surf);
    gp_Pnt local = target.Transformed(loc.Transformation().Inverted());
    gp_Pnt2d uv = sas.ValueOfUV(local, Precision::Confusion());
    BRepClass_FaceClassifier cls(face, uv, Precision::Confusion());
    if (cls.State() == TopAbs_IN || cls.State() == TopAbs_ON) {
      u = uv.X();
      v = uv.Y();
      found = true;
    }
  }
  if (!found) {
    BRepExtrema_DistShapeShape dist(BRepBuilderAPI_MakeVertex(target).Vertex(), face);
    if (dist.IsDone() && dist.NbSolution() > 0 && dist.SupportTypeShape2(1) == BRepExtrema_IsInFace) {
      dist.ParOnFaceS2(1, u, v);
      found = true;
    }
  }
  if (!found) {
    double u1, u2, v1, v2;
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    u = (u1 + u2) / 2;
    v = (v1 + v2) / 2;
  }
  BRepGProp_Face gf(face); // accounts for the face orientation
  gp_Pnt p;
  gp_Vec n;
  gf.Normal(u, v, p, n);
  if (onFace) *onFace = p;
  if (n.Magnitude() < 1e-12) {
    // Singular point (cone apex, sphere pole): nudge into the face.
    double u1, u2, v1, v2;
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    gf.Normal(u + (((u1 + u2) / 2) - u) * 1e-3, v + (((v1 + v2) / 2) - v) * 1e-3, p, n);
    if (n.Magnitude() < 1e-12) return gp_Dir(0, 0, 1);
  }
  return gp_Dir(n);
}

void boundsOf(const TopoDS_Shape &s, FKVec3 *mn, FKVec3 *mx, const ShapeMap *faces = nullptr) {
  Bnd_Box box;
  // AddOptimal is a union of per-face boxes (plus edges outside faces and vertices outside
  // edges). For a body made only of faces, compute the faces in parallel: the union of boxes
  // does not depend on the order, so the result is identical, and 6x faster on 88 faces.
  const bool onlyFaces = faces && faces->Extent() > 1 && !TopExp_Explorer(s, TopAbs_EDGE, TopAbs_FACE).More() &&
                         !TopExp_Explorer(s, TopAbs_VERTEX, TopAbs_EDGE).More();
  if (onlyFaces) {
    std::vector<Bnd_Box> boxes(faces->Extent());
    OSD_Parallel::For(0, faces->Extent(),
                      [&](int i) { BRepBndLib::AddOptimal(faces->FindKey(i + 1), boxes[i], false, false); });
    for (const Bnd_Box &b : boxes) box.Add(b);
  } else {
    BRepBndLib::AddOptimal(s, box, false, false);
  }
  if (box.IsVoid()) fail("The shape is empty");
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  if (mn) *mn = FKVec3{x0, y0, z0};
  if (mx) *mx = FKVec3{x1, y1, z1};
}

} // namespace

extern "C" int32_t fk_face_count(const FKShape *shape) {
  return guarded("Face count", (int32_t)0, [&] {
    shapeOf(shape);
    return (int32_t)shape->faces().Extent();
  });
}

extern "C" int32_t fk_edge_count(const FKShape *shape) {
  return guarded("Edge count", (int32_t)0, [&] {
    shapeOf(shape);
    return (int32_t)shape->edges().Extent();
  });
}

extern "C" bool fk_face_info(const FKShape *shape, int32_t faceIndex, FKFaceInfo *out) {
  return guarded("Face info", false, [&] {
    shapeOf(shape);
    if (!out) fail("Missing output pointer");
    const TopoDS_Face &face = faceAt(shape, faceIndex);
    BRepAdaptor_Surface surf(face, false);
    GProp_GProps props;
    BRepGProp::SurfaceProperties(face, props);
    gp_Pnt c = props.Mass() > 0 ? props.CentreOfMass() : gp_Pnt();
    FKFaceInfo info{};
    info.surface = surfaceType(surf.GetType());
    info.centroid = fkv(c);
    info.normal = fkv(normalNear(face, c));
    info.area = props.Mass();
    boundsOf(face, &info.boundsMin, &info.boundsMax);
    *out = info;
    return true;
  });
}

extern "C" bool fk_edge_info(const FKShape *shape, int32_t edgeIndex, FKEdgeInfo *out) {
  return guarded("Edge info", false, [&] {
    shapeOf(shape);
    if (!out) fail("Missing output pointer");
    const TopoDS_Edge &edge = edgeAt(shape, edgeIndex);
    FKEdgeInfo info{};
    if (BRep_Tool::Degenerated(edge)) {
      TopoDS_Vertex v1, v2;
      TopExp::Vertices(edge, v1, v2);
      gp_Pnt p = v1.IsNull() ? gp_Pnt() : BRep_Tool::Pnt(v1);
      info.curve = FK_CURVE_OTHER;
      info.start = info.mid = info.end = fkv(p);
      info.tangentAtMid = FKVec3{0, 0, 0};
      info.length = 0;
      info.radius = 0;
      *out = info;
      return true;
    }
    BRepAdaptor_Curve c(edge);
    double f = c.FirstParameter(), l = c.LastParameter();
    info.curve = curveType(c.GetType());
    info.start = fkv(c.Value(f));
    info.end = fkv(c.Value(l));
    gp_Pnt mid;
    gp_Vec tan;
    c.D1((f + l) / 2, mid, tan);
    info.mid = fkv(mid);
    info.tangentAtMid = tan.Magnitude() > 1e-12 ? fkv(gp_Dir(tan)) : FKVec3{0, 0, 0};
    info.length = GCPnts_AbscissaPoint::Length(c);
    info.radius = c.GetType() == GeomAbs_Circle ? c.Circle().Radius() : 0;
    *out = info;
    return true;
  });
}

extern "C" bool fk_seam_edges(const FKShape *shape, bool *out, int32_t count) {
  return guarded("Seam edges", false, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    if (!out) fail("Missing output pointer");
    const ShapeMap &edges = shape->edges();
    if (count != edges.Extent())
      fail("Expected " + std::to_string(edges.Extent()) + " edges, got room for " + std::to_string(count));
    // One edge→face map for the whole shape (building it per edge made a full scan quadratic).
    AncestorMap faces;
    TopExp::MapShapesAndUniqueAncestors(s, TopAbs_EDGE, TopAbs_FACE, faces);
    for (int32_t i = 0; i < count; ++i) {
      const TopoDS_Edge &edge = TopoDS::Edge(edges(i + 1));
      if (BRep_Tool::Degenerated(edge)) {
        out[i] = true;
        continue;
      }
      const ShapeList *adjacent = faces.Seek(edge);
      out[i] = !adjacent || adjacent->Extent() < 2;  // a face meeting itself, or a free edge
    }
    return true;
  });
}

extern "C" bool fk_face_plane(const FKShape *shape, int32_t faceIndex, FKPlane *out) {
  return guarded("Face plane", false, [&] {
    shapeOf(shape);
    if (!out) fail("Missing output pointer");
    const TopoDS_Face &face = faceAt(shape, faceIndex);
    TopLoc_Location loc;
    occ::handle<Geom_Surface> surf = BRep_Tool::Surface(face, loc);
    if (surf.IsNull()) fail("The face has no surface");
    GeomLib_IsPlanarSurface planar(surf, 1e-6);
    if (!planar.IsPlanar()) {
      fk::setError("The face is not planar");
      return false;
    }
    gp_Pln pl = planar.Plan().Transformed(loc.Transformation());

    GProp_GProps props;
    BRepGProp::SurfaceProperties(face, props);
    gp_Pnt c = props.CentreOfMass();

    gp_Dir n = pl.Axis().Direction();
    // Outward normal: compare with the orientation-aware normal of the face.
    gp_Dir faceN = normalNear(face, c);
    if (faceN.Dot(n) < 0) n.Reverse();

    // xDir: longest straight edge, else the plane's own X direction.
    gp_Vec xdir = gp_Vec(pl.XAxis().Direction());
    double longest = 0;
    for (TopExp_Explorer ex(face, TopAbs_EDGE); ex.More(); ex.Next()) {
      const TopoDS_Edge &e = TopoDS::Edge(ex.Current());
      if (BRep_Tool::Degenerated(e)) continue;
      BRepAdaptor_Curve curve(e);
      if (curve.GetType() != GeomAbs_Line) continue;
      gp_Vec d(curve.Value(curve.FirstParameter()), curve.Value(curve.LastParameter()));
      if (d.Magnitude() > longest + 1e-9) {
        longest = d.Magnitude();
        xdir = d;
      }
    }
    xdir = xdir - gp_Vec(n) * xdir.Dot(gp_Vec(n));
    if (xdir.Magnitude() < 1e-9) {
      gp_Vec helper = std::fabs(n.X()) < 0.9 ? gp_Vec(1, 0, 0) : gp_Vec(0, 1, 0);
      xdir = gp_Vec(n).Crossed(helper);
    }
    gp_Dir x(xdir);
    // Project the centroid onto the plane (it lies on it already for planar faces).
    out->origin = fkv(c);
    out->normal = fkv(n);
    out->xDir = fkv(x);
    return true;
  });
}

extern "C" bool fk_bounds(const FKShape *shape, FKVec3 *min, FKVec3 *max) {
  return guarded("Bounds", false, [&] {
    boundsOf(shapeOf(shape), min, max, &shape->faces());
    return true;
  });
}

extern "C" double fk_volume(const FKShape *shape) {
  return guarded("Volume", 0.0, [&] { return volumeOf(shapeOf(shape)); });
}

extern "C" double fk_surface_area(const FKShape *shape) {
  return guarded("Surface area", 0.0, [&] {
    GProp_GProps props;
    BRepGProp::SurfaceProperties(shapeOf(shape), props);
    return props.Mass();
  });
}

extern "C" bool fk_mass_properties(const FKShape *shape, double eps, double *volume, double *area) {
  return guarded("Mass properties", false, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    if (!isFinite(eps) || eps <= 0) fail("Integration precision must be positive");
    if (volume) {
      GProp_GProps props;
      BRepGProp::VolumeProperties(s, props, eps);
      *volume = props.Mass();
    }
    if (area) {
      GProp_GProps props;
      BRepGProp::SurfaceProperties(s, props, eps);
      *area = props.Mass();
    }
    return true;
  });
}

extern "C" bool fk_is_valid(const FKShape *shape) {
  return guarded("Validity check", false, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    if (isEmpty(s)) return false;
    BRepCheck_Analyzer ana(s, true);
    if (!ana.IsValid()) return false;
    // Closed geometry: every solid must be closed (each edge shared by two faces).
    for (TopExp_Explorer ex(s, TopAbs_SHELL); ex.More(); ex.Next())
      if (!BRep_Tool::IsClosed(ex.Current())) return false;
    return true;
  });
}

extern "C" bool fk_distance(const FKShape *a, const FKShape *b, double *distance, FKVec3 *pointA, FKVec3 *pointB) {
  return guarded("Distance", false, [&] {
    const TopoDS_Shape &sa = shapeOf(a, "first shape");
    const TopoDS_Shape &sb = shapeOf(b, "second shape");
    BRepExtrema_DistShapeShape dist(sa, sb);
    if (!dist.IsDone() || dist.NbSolution() < 1) fail("Could not measure the distance");
    if (distance) *distance = dist.Value();
    if (pointA) *pointA = fkv(dist.PointOnShape1(1));
    if (pointB) *pointB = fkv(dist.PointOnShape2(1));
    return true;
  });
}

extern "C" FKShape *fk_subshape_face(const FKShape *shape, int32_t faceIndex) {
  return guarded("Face", (FKShape *)nullptr, [&] {
    shapeOf(shape);
    return wrap(faceAt(shape, faceIndex));
  });
}

extern "C" FKShape *fk_subshape_edge(const FKShape *shape, int32_t edgeIndex) {
  return guarded("Edge", (FKShape *)nullptr, [&] {
    shapeOf(shape);
    return wrap(edgeAt(shape, edgeIndex));
  });
}
