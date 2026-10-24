// Sketch profile detection: arbitrary 2D segments -> minimal bounded planar regions.
//
// 1. Every segment becomes an edge on the sketch plane.
// 2. General Fuse (BOPAlgo_Builder) splits all edges against each other so
//    that intersections, T-junctions and overlaps share vertices/edges.
// 3. BOPAlgo_BuilderFace on the infinite sketch plane, fed with every split
//    edge in both orientations, builds the minimal loops; counter-clockwise
//    loops become faces and clockwise loops become holes of the nearest
//    enclosing face. Dangling edges are dropped (SetAvoidInternalShapes).
// 4. The single unbounded face that collects the outer boundaries is dropped.
#include "Internal.hpp"

#include <BOPAlgo_Builder.hxx>
#include <BOPAlgo_BuilderFace.hxx>
#include <BOPTools_AlgoTools2D.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GProp_GProps.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_Circle.hxx>
#include <Geom_Plane.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <IntTools_Context.hxx>
#include <NCollection_HArray1.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <gp_Circ.hxx>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

using namespace fk;

namespace {

constexpr double kFuzzy = 1e-6; // mm: endpoints closer than this are considered coincident

gp_Pnt planePoint(const gp_Ax3 &ax, double u, double v) {
  return gp_Pnt(ax.Location().XYZ() + ax.XDirection().XYZ() * u + ax.YDirection().XYZ() * v);
}

bool finitePair(double u, double v) { return isFinite(u) && isFinite(v); }

/// Converts one sketch segment into zero or one edge. Degenerate input is skipped.
void addSegmentEdges(const gp_Ax3 &ax, const FKSegment &seg, ShapeList &out) {
  switch (seg.kind) {
  case FK_SEG_LINE: {
    if (!finitePair(seg.p[0], seg.p[1]) || !finitePair(seg.p[2], seg.p[3])) return;
    gp_Pnt a = planePoint(ax, seg.p[0], seg.p[1]), b = planePoint(ax, seg.p[2], seg.p[3]);
    if (a.Distance(b) <= Precision::Confusion()) return;
    BRepBuilderAPI_MakeEdge mk(a, b);
    if (mk.IsDone()) out.Append(mk.Edge());
    return;
  }
  case FK_SEG_ARC: {
    if (!finitePair(seg.p[0], seg.p[1]) || !finitePair(seg.p[2], seg.p[3]) || !finitePair(seg.p[4], seg.p[5]))
      return;
    gp_Pnt a = planePoint(ax, seg.p[0], seg.p[1]);
    gp_Pnt m = planePoint(ax, seg.p[2], seg.p[3]);
    gp_Pnt b = planePoint(ax, seg.p[4], seg.p[5]);
    if (a.Distance(b) <= Precision::Confusion()) return; // a closed "arc" is ambiguous
    gp_Vec ab(a, b), am(a, m);
    if (ab.Crossed(am).Magnitude() <= Precision::Confusion() * ab.Magnitude()) {
      // Collinear points: treat as a straight line.
      BRepBuilderAPI_MakeEdge mk(a, b);
      if (mk.IsDone()) out.Append(mk.Edge());
      return;
    }
    GC_MakeArcOfCircle arc(a, m, b);
    if (!arc.IsDone()) return;
    BRepBuilderAPI_MakeEdge mk(arc.Value());
    if (mk.IsDone()) out.Append(mk.Edge());
    return;
  }
  case FK_SEG_CIRCLE: {
    double r = seg.p[2];
    if (!finitePair(seg.p[0], seg.p[1]) || !isFinite(r) || r <= Precision::Confusion()) return;
    gp_Ax2 a2(planePoint(ax, seg.p[0], seg.p[1]), ax.Direction(), ax.XDirection());
    BRepBuilderAPI_MakeEdge mk(gp_Circ(a2, r));
    if (mk.IsDone()) out.Append(mk.Edge());
    return;
  }
  case FK_SEG_BSPLINE: {
    if (!seg.points || seg.pointCount < 2) return;
    std::vector<gp_Pnt> pts;
    for (int32_t i = 0; i < seg.pointCount; i++) {
      double u = seg.points[2 * i], v = seg.points[2 * i + 1];
      if (!finitePair(u, v)) return;
      gp_Pnt p = planePoint(ax, u, v);
      if (!pts.empty() && pts.back().Distance(p) <= Precision::Confusion()) continue;
      pts.push_back(p);
    }
    bool closed = pts.size() >= 3 && pts.front().Distance(pts.back()) <= kFuzzy * 10;
    if (closed) pts.pop_back();
    if (pts.size() < 2 || (closed && pts.size() < 3)) return;
    if (pts.size() == 2) {
      BRepBuilderAPI_MakeEdge mk(pts[0], pts[1]);
      if (mk.IsDone()) out.Append(mk.Edge());
      return;
    }
    occ::handle<NCollection_HArray1<gp_Pnt>> arr = new NCollection_HArray1<gp_Pnt>(1, (int)pts.size());
    for (size_t i = 0; i < pts.size(); i++) arr->SetValue((int)i + 1, pts[i]);
    GeomAPI_Interpolate interp(arr, closed, Precision::Confusion());
    interp.Perform();
    if (!interp.IsDone()) return;
    BRepBuilderAPI_MakeEdge mk(interp.Curve());
    if (mk.IsDone()) out.Append(mk.Edge());
    return;
  }
  }
}

/// Builds the bounded faces enclosed by `edges` (already split against each other, lying on `plane`).
std::vector<TopoDS_Shape> facesFromEdges(const ShapeList &edges, const gp_Pln &plane) {
  std::vector<TopoDS_Shape> result;
  if (edges.IsEmpty()) return result;

  BRepBuilderAPI_MakeFace mkFace(plane);
  if (!mkFace.IsDone()) fail("Could not create the sketch plane");
  TopoDS_Face base = mkFace.Face();

  occ::handle<IntTools_Context> ctx = new IntTools_Context;
  ShapeList oriented;
  for (ShapeList::Iterator it(edges); it.More(); it.Next()) {
    TopoDS_Edge e = TopoDS::Edge(it.Value());
    if (BRep_Tool::Degenerated(e)) continue;
    e.Orientation(TopAbs_FORWARD);
    BOPTools_AlgoTools2D::BuildPCurveForEdgeOnFace(e, base, ctx);
    oriented.Append(e);
    oriented.Append(e.Reversed());
  }

  BOPAlgo_BuilderFace bf;
  bf.SetFace(base);
  bf.SetShapes(oriented);
  bf.SetContext(ctx);
  bf.SetAvoidInternalShapes(true);
  bf.SetRunParallel(false);
  bf.Perform();
  if (bf.HasErrors()) fail("Could not detect sketch profiles");

  for (ShapeList::Iterator it(bf.Areas()); it.More(); it.Next()) {
    TopoDS_Face f = TopoDS::Face(it.Value());
    if (ctx->IsInfiniteFace(f)) continue;
    // Drop faces without an outer loop (only holes) and slivers.
    GProp_GProps props;
    BRepGProp::SurfaceProperties(f, props);
    if (props.Mass() <= Precision::Confusion() * Precision::Confusion() * 10) continue;
    Bnd_Box box;
    BRepBndLib::Add(f, box);
    if (box.IsVoid() || box.IsOpen()) continue;
    result.push_back(f);
  }
  return result;
}

/// Even-odd point-in-polygon test against a set of boundary segments.
struct Boundary {
  std::vector<std::array<double, 4>> segs; // u0, v0, u1, v1

  bool contains(double u, double v) const {
    bool inside = false;
    for (const auto &s : segs) {
      double v0 = s[1], v1 = s[3];
      if ((v0 > v) != (v1 > v)) {
        double t = (v - v0) / (v1 - v0);
        double uc = s[0] + t * (s[2] - s[0]);
        if (uc > u) inside = !inside;
      }
    }
    return inside;
  }

  double distance(double u, double v) const {
    double best = std::numeric_limits<double>::infinity();
    for (const auto &s : segs) {
      double dx = s[2] - s[0], dy = s[3] - s[1];
      double l2 = dx * dx + dy * dy;
      double t = l2 > 0 ? ((u - s[0]) * dx + (v - s[1]) * dy) / l2 : 0;
      t = std::clamp(t, 0.0, 1.0);
      double px = s[0] + t * dx - u, py = s[1] + t * dy - v;
      best = std::min(best, px * px + py * py);
    }
    return std::sqrt(best);
  }
};

void projectToPlane(const gp_Ax3 &ax, const gp_Pnt &p, double &u, double &v) {
  gp_Vec d(ax.Location(), p);
  u = d.Dot(gp_Vec(ax.XDirection()));
  v = d.Dot(gp_Vec(ax.YDirection()));
}

const TopoDS_Face &regionFace(const TopoDS_Shape &s) {
  if (s.IsNull() || s.ShapeType() != TopAbs_FACE) fail("The region is not a face");
  return TopoDS::Face(s);
}

} // namespace

extern "C" FKShapeList *fk_sketch_regions(FKPlane plane, const FKSegment *segments, int32_t count) {
  return guarded("Profile detection", (FKShapeList *)nullptr, [&] {
    if (count < 0 || (count > 0 && !segments)) fail("Invalid sketch segment list");
    gp_Ax3 ax = axes(plane);
    auto *list = new FKShapeList;
    std::unique_ptr<FKShapeList> guard(list);

    ShapeList edges;
    for (int32_t i = 0; i < count; i++) addSegmentEdges(ax, segments[i], edges);
    if (edges.IsEmpty()) return guard.release();

    // Split every edge against every other edge (General Fuse needs >= 2 arguments).
    ShapeList splitEdges;
    if (edges.Extent() == 1) {
      splitEdges = edges;
    } else {
      BOPAlgo_Builder gf;
      gf.SetArguments(edges);
      gf.SetFuzzyValue(kFuzzy);
      gf.SetNonDestructive(true);
      gf.SetRunParallel(false);
      gf.Perform();
      if (gf.HasErrors()) fail("Could not intersect the sketch curves");
      ShapeMap split;
      TopExp::MapShapes(gf.Shape(), TopAbs_EDGE, split);
      for (int i = 1; i <= split.Extent(); i++) splitEdges.Append(split(i));
    }

    for (auto &f : facesFromEdges(splitEdges, gp_Pln(ax))) list->items.push_back(f);
    return guard.release();
  });
}

extern "C" int32_t fk_region_containing(const FKShapeList *regions, FKPlane plane, double u, double v) {
  return guarded("Region lookup", (int32_t)-1, [&]() -> int32_t {
    if (!regions) fail("No region list was given");
    if (!finitePair(u, v)) fail("Point is not finite");
    gp_Ax3 ax = axes(plane);
    gp_Pnt p = planePoint(ax, u, v);
    for (size_t i = 0; i < regions->items.size(); i++) {
      const TopoDS_Shape &s = regions->items[i];
      if (s.IsNull() || s.ShapeType() != TopAbs_FACE) continue;
      BRepClass_FaceClassifier cls(TopoDS::Face(s), p, Precision::Confusion());
      if (cls.State() == TopAbs_IN) return (int32_t)i;
    }
    return -1;
  });
}

extern "C" bool fk_region_interior_point(const FKShape *region, FKPlane plane, double *u, double *v) {
  return guarded("Region interior point", false, [&] {
    if (!u || !v) fail("Missing output pointer");
    const TopoDS_Face &face = regionFace(shapeOf(region, "region"));
    gp_Ax3 ax = axes(plane);

    Bnd_Box box;
    BRepBndLib::Add(face, box);
    if (box.IsVoid()) fail("The region is empty");
    double diag = std::sqrt(box.SquareExtent());
    double deflection = std::max(diag * 1e-3, 1e-6);

    // Discretised boundary in plane coordinates.
    Boundary boundary;
    double umin = 1e300, umax = -1e300, vmin = 1e300, vmax = -1e300;
    for (TopExp_Explorer ex(face, TopAbs_EDGE); ex.More(); ex.Next()) {
      const TopoDS_Edge &e = TopoDS::Edge(ex.Current());
      if (BRep_Tool::Degenerated(e)) continue;
      BRepAdaptor_Curve c(e);
      GCPnts_QuasiUniformDeflection disc(c, deflection);
      std::vector<std::pair<double, double>> pts;
      if (disc.IsDone() && disc.NbPoints() >= 2) {
        for (int i = 1; i <= disc.NbPoints(); i++) {
          double pu, pv;
          projectToPlane(ax, disc.Value(i), pu, pv);
          pts.emplace_back(pu, pv);
        }
      } else {
        const int n = 64;
        for (int i = 0; i <= n; i++) {
          double t = c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * i / n;
          double pu, pv;
          projectToPlane(ax, c.Value(t), pu, pv);
          pts.emplace_back(pu, pv);
        }
      }
      for (size_t i = 0; i + 1 < pts.size(); i++) {
        boundary.segs.push_back({pts[i].first, pts[i].second, pts[i + 1].first, pts[i + 1].second});
        umin = std::min({umin, pts[i].first, pts[i + 1].first});
        umax = std::max({umax, pts[i].first, pts[i + 1].first});
        vmin = std::min({vmin, pts[i].second, pts[i + 1].second});
        vmax = std::max({vmax, pts[i].second, pts[i + 1].second});
      }
    }
    if (boundary.segs.empty()) fail("The region has no boundary");

    // Candidates: centroids of a fine triangulation (always inside) plus a grid.
    std::vector<std::pair<double, double>> candidates;
    TopoDS_Shape meshCopy = BRepBuilderAPI_Copy(face, false, false).Shape();
    BRepMesh_IncrementalMesh mesher(meshCopy, std::max(diag * 0.01, 1e-4), false, 0.3, false);
    TopLoc_Location loc;
    occ::handle<Poly_Triangulation> tri = BRep_Tool::Triangulation(TopoDS::Face(meshCopy), loc);
    if (!tri.IsNull()) {
      const gp_Trsf &tr = loc.Transformation();
      for (int i = 1; i <= tri->NbTriangles(); i++) {
        int a, b, c;
        tri->Triangle(i).Get(a, b, c);
        gp_XYZ ctr = (tri->Node(a).XYZ() + tri->Node(b).XYZ() + tri->Node(c).XYZ()) / 3.0;
        gp_Pnt p(ctr);
        p.Transform(tr);
        double pu, pv;
        projectToPlane(ax, p, pu, pv);
        candidates.emplace_back(pu, pv);
      }
    }
    const int grid = 24;
    for (int i = 0; i < grid; i++)
      for (int j = 0; j < grid; j++)
        candidates.emplace_back(umin + (umax - umin) * (i + 0.5) / grid, vmin + (vmax - vmin) * (j + 0.5) / grid);

    // Pick the candidate farthest from the boundary (robust against later edits).
    double bestScore = -1, bu = 0, bv = 0;
    for (const auto &c : candidates) {
      if (!boundary.contains(c.first, c.second)) continue;
      double d = boundary.distance(c.first, c.second);
      if (d > bestScore) {
        bestScore = d;
        bu = c.first;
        bv = c.second;
      }
    }
    if (bestScore <= 0) fail("Could not find a point inside the region");
    BRepClass_FaceClassifier cls(face, planePoint(ax, bu, bv), Precision::Confusion());
    if (cls.State() != TopAbs_IN) fail("Could not find a point inside the region");
    *u = bu;
    *v = bv;
    return true;
  });
}

extern "C" FKShape *fk_profile_from_regions(const FKShapeList *regions, const int32_t *indices, int32_t count) {
  return guarded("Profile", (FKShape *)nullptr, [&]() -> FKShape * {
    if (!regions) fail("No region list was given");
    if (count <= 0 || !indices) fail("Select at least one sketch region");
    std::vector<int32_t> idx(indices, indices + count);
    std::sort(idx.begin(), idx.end());
    idx.erase(std::unique(idx.begin(), idx.end()), idx.end());
    for (int32_t i : idx)
      if (i < 0 || i >= (int32_t)regions->items.size())
        fail("Region " + std::to_string(i) + " does not exist (the sketch has " +
             std::to_string(regions->items.size()) + " regions)");

    if (idx.size() == 1) return wrap(regionFace(regions->items[idx[0]]));

    // Count how many selected faces use each edge; edges shared by two
    // selected faces are interior and disappear when the faces merge.
    BRep_Builder b;
    TopoDS_Compound comp;
    b.MakeCompound(comp);
    for (int32_t i : idx) b.Add(comp, regionFace(regions->items[i]));
    AncestorMap edgeFaces;
    TopExp::MapShapesAndAncestors(comp, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    ShapeList boundaryEdges;
    for (int i = 1; i <= edgeFaces.Extent(); i++) {
      NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher> distinct;
      for (ShapeList::Iterator it(edgeFaces(i)); it.More(); it.Next()) distinct.Add(it.Value());
      if (distinct.Extent() == 1) boundaryEdges.Append(edgeFaces.FindKey(i));
    }

    TopLoc_Location loc;
    occ::handle<Geom_Plane> surf =
        occ::down_cast<Geom_Plane>(BRep_Tool::Surface(regionFace(regions->items[idx[0]]), loc));
    if (surf.IsNull()) fail("Regions are not planar");
    gp_Pln pl = surf->Pln().Transformed(loc.Transformation());

    std::vector<TopoDS_Shape> faces = facesFromEdges(boundaryEdges, pl);
    if (faces.empty()) fail("The selected regions do not form a profile");
    // Merge edges that were only split by the now-removed interior edges.
    for (auto &f : faces) {
      TopoDS_Shape u = unify(f);
      if (!u.IsNull() && u.ShapeType() == TopAbs_FACE) f = u;
    }
    if (faces.size() == 1) return wrap(faces[0]);
    TopoDS_Compound out;
    b.MakeCompound(out);
    for (auto &f : faces) b.Add(out, f);
    return wrap(out);
  });
}
