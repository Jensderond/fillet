// Modelling features: extrude, revolve, booleans, fillet, chamfer, shell, transforms.
#include "Internal.hpp"

#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <LocOpe_DPrism.hxx>
#include <Precision.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Solid.hxx>
#include <gp_GTrsf.hxx>
#include <gp_Trsf.hxx>

#include <cmath>
#include <functional>

using namespace fk;

namespace {

std::vector<TopoDS_Face> profileFaces(const TopoDS_Shape &profile) {
  if (countOf(profile, TopAbs_SOLID) > 0 || countOf(profile, TopAbs_SHELL) > 0)
    fail("The profile must be a sketch region or a face, not a body");
  std::vector<TopoDS_Face> faces;
  for (TopExp_Explorer ex(profile, TopAbs_FACE); ex.More(); ex.Next()) faces.push_back(TopoDS::Face(ex.Current()));
  if (faces.empty()) fail("The profile is empty: select at least one closed sketch region");
  return faces;
}

/// Fuses the solids of a compound together when there is more than one.
TopoDS_Shape fuseSolids(const TopoDS_Shape &s) {
  std::vector<TopoDS_Shape> solids;
  for (TopExp_Explorer ex(s, TopAbs_SOLID); ex.More(); ex.Next()) solids.push_back(ex.Current());
  if (solids.size() < 2) return s;
  ShapeList args, tools;
  args.Append(solids[0]);
  for (size_t i = 1; i < solids.size(); i++) tools.Append(solids[i]);
  BRepAlgoAPI_Fuse fuse;
  fuse.SetArguments(args);
  fuse.SetTools(tools);
  fuse.SetNonDestructive(true);
  fuse.SetRunParallel(true);
  fuse.Build();
  if (!fuse.IsDone() || fuse.HasErrors()) return s;
  return fuse.Shape();
}

gp_Dir faceNormal(const TopoDS_Face &f) {
  BRepGProp_Face gf(f);
  double u1, u2, v1, v2;
  gf.Bounds(u1, u2, v1, v2);
  gp_Pnt p;
  gp_Vec n;
  gf.Normal((u1 + u2) / 2, (v1 + v2) / 2, p, n);
  if (n.Magnitude() < 1e-12) fail("The profile face has no normal");
  return gp_Dir(n);
}

const TopoDS_Edge &edgeAt(const FKShape *shape, int32_t index) {
  const ShapeMap &edges = shape->edges();
  if (index < 0 || index >= edges.Extent())
    fail("Edge " + std::to_string(index) + " does not exist (the body has " + std::to_string(edges.Extent()) +
         " edges)");
  return TopoDS::Edge(edges(index + 1));
}

const TopoDS_Face &faceAt(const FKShape *shape, int32_t index) {
  const ShapeMap &faces = shape->faces();
  if (index < 0 || index >= faces.Extent())
    fail("Face " + std::to_string(index) + " does not exist (the body has " + std::to_string(faces.Extent()) +
         " faces)");
  return TopoDS::Face(faces(index + 1));
}

/// Validates edge indices for fillet/chamfer: each edge must sit between two faces.
std::vector<TopoDS_Edge> blendEdges(const FKShape *shape, const int32_t *indices, int32_t count, const char *what) {
  if (count <= 0 || !indices) fail(std::string("Select at least one edge to ") + what);
  AncestorMap edgeFaces;
  TopExp::MapShapesAndAncestors(shape->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
  std::vector<TopoDS_Edge> edges;
  NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher> seen;
  for (int32_t i = 0; i < count; i++) {
    const TopoDS_Edge &e = edgeAt(shape, indices[i]);
    if (!seen.Add(e)) continue;
    if (BRep_Tool::Degenerated(e)) fail("Edge " + std::to_string(indices[i]) + " is degenerate and cannot be used");
    const ShapeList *faces = edgeFaces.Seek(e);
    NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher> distinct;
    bool seam = false;
    if (faces)
      for (ShapeList::Iterator it(*faces); it.More(); it.Next()) {
        distinct.Add(it.Value());
        if (BRep_Tool::IsClosed(e, TopoDS::Face(it.Value()))) seam = true;
      }
    if (seam) fail("Edge " + std::to_string(indices[i]) + " is a seam and cannot be used");
    if (distinct.Extent() != 2) fail("Edge " + std::to_string(indices[i]) + " is not between two faces");
    edges.push_back(e);
  }
  return edges;
}

/// Runs a size-dependent blend; on failure probes a much smaller size to tell
/// the user whether the size was simply too large.
TopoDS_Shape blendWithDiagnosis(const std::function<TopoDS_Shape(double)> &attempt, double size,
                                const std::string &tooLarge, const std::string &generic) {
  try {
    return attempt(size);
  } catch (...) {
  }
  bool smallerWorks = false;
  try {
    attempt(size * 0.05);
    smallerWorks = true;
  } catch (...) {
  }
  fail(smallerWorks ? tooLarge : generic);
}

void requireFinite(double v, const char *what) {
  if (!isFinite(v)) fail(std::string(what) + " is not a finite number");
}

} // namespace

// MARK: - Extrude / revolve

extern "C" FKShape *fk_extrude(const FKShape *profile, FKVec3 direction, double distance, double distanceBack,
                               double taperRadians) {
  return guarded("Extrude", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &p = shapeOf(profile, "profile");
    std::vector<TopoDS_Face> faces = profileFaces(p);
    gp_Dir d = dir(direction, "Extrude direction");
    requireFinite(distance, "Extrude distance");
    requireFinite(distanceBack, "Extrude back distance");
    requireFinite(taperRadians, "Taper angle");
    double start = -distanceBack, end = distance;
    if (end < start) std::swap(start, end);
    double length = end - start;
    if (length <= Precision::Confusion()) fail("Extrude distance must be non-zero");
    if (std::fabs(taperRadians) >= M_PI / 2 - 1e-3) fail("Taper angle must be between -90° and 90°");

    BRep_Builder b;
    TopoDS_Compound solids;
    b.MakeCompound(solids);

    if (std::fabs(taperRadians) < 1e-9) {
      gp_Trsf move;
      move.SetTranslation(gp_Vec(d) * start);
      TopoDS_Shape moved = BRepBuilderAPI_Transform(p, move, true).Shape();
      BRepPrimAPI_MakePrism prism(moved, gp_Vec(d) * length, true);
      prism.Build();
      if (!prism.IsDone()) fail("Extrude failed: could not sweep the profile");
      b.Add(solids, prism.Shape());
    } else {
      for (const TopoDS_Face &f0 : faces) {
        TopoDS_Face f = f0;
        TopLoc_Location loc;
        if (BRep_Tool::Surface(f, loc).IsNull() || !BRepTools::OuterWire(f).Closed()) fail("Invalid profile face");
        f.Orientation(TopAbs_FORWARD); // DPrism works along the surface normal
        gp_Dir n = faceNormal(f);
        double cosA = n.Dot(d);
        if (std::fabs(std::fabs(cosA) - 1) > 1e-6)
          fail("A tapered extrusion must be perpendicular to the sketch plane");
        // The draft narrows along +dir. Its neutral plane (where the section equals
        // the profile) is the sketch plane when the range straddles it, else the
        // end of the range nearest to the sketch.
        double neutral = (start <= 0 && end >= 0) ? 0 : (start > 0 ? start : end);
        double sign = cosA > 0 ? 1 : -1;
        // Range and neutral plane measured along the surface normal.
        double s = cosA > 0 ? start : -end, e = cosA > 0 ? end : -start, nOff = sign * neutral;
        if (std::fabs(nOff) > 0) {
          gp_Trsf move;
          move.SetTranslation(gp_Vec(n) * nOff);
          f = TopoDS::Face(BRepBuilderAPI_Transform(f, move, true).Shape());
        }
        // DPrism measures heights along the drafted walls: Height1 in front of
        // the face (along its normal), Height2 behind; a positive angle narrows
        // towards the front.
        double c = std::cos(taperRadians);
        LocOpe_DPrism dp(f, (e - nOff) / c, (nOff - s) / c, sign * taperRadians);
        if (!dp.IsDone()) fail("Extrude failed: the taper angle is too large for this profile");
        b.Add(solids, dp.Shape());
      }
    }
    TopoDS_Shape result = fuseSolids(solids);
    if (countOf(result, TopAbs_SOLID) == 0) fail("Extrude failed: the profile does not enclose an area");
    return wrap(finish(result, "Extrude failed: the result is not a valid solid"));
  });
}

extern "C" FKShape *fk_revolve(const FKShape *profile, FKVec3 axisOrigin, FKVec3 axisDir, double angle) {
  return guarded("Revolve", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &p = shapeOf(profile, "profile");
    profileFaces(p);
    gp_Dir d = dir(axisDir, "Revolve axis");
    if (!isFinite(axisOrigin.x) || !isFinite(axisOrigin.y) || !isFinite(axisOrigin.z)) fail("Revolve axis is not finite");
    requireFinite(angle, "Revolve angle");
    if (std::fabs(angle) <= 1e-9) fail("Revolve angle must be non-zero");
    gp_Ax1 axis(pnt(axisOrigin), d);
    bool full = std::fabs(angle) >= 2 * M_PI - 1e-9;
    TopoDS_Shape result;
    if (full) {
      BRepPrimAPI_MakeRevol mk(p, axis, true);
      mk.Build();
      if (!mk.IsDone()) fail("Revolve failed");
      result = mk.Shape();
    } else {
      BRepPrimAPI_MakeRevol mk(p, axis, angle, true);
      mk.Build();
      if (!mk.IsDone()) fail("Revolve failed");
      result = mk.Shape();
    }
    if (countOf(result, TopAbs_SOLID) == 0) fail("Revolve failed: the profile does not enclose an area");
    result = fuseSolids(result);
    return wrap(finish(result, "Revolve failed: the profile must not cross the axis"));
  });
}

// MARK: - Booleans

extern "C" FKShape *fk_boolean(const FKShape *a, const FKShape *b, FKBoolOp op) {
  const char *name = op == FK_BOOL_FUSE ? "Join" : op == FK_BOOL_CUT ? "Cut" : "Intersect";
  return guarded(name, (FKShape *)nullptr, [&] {
    const TopoDS_Shape &sa = shapeOf(a, "target body");
    const TopoDS_Shape &sb = shapeOf(b, "tool body");
    ShapeList args, tools;
    args.Append(sa);
    tools.Append(sb);
    std::unique_ptr<BRepAlgoAPI_BooleanOperation> algo;
    switch (op) {
    case FK_BOOL_FUSE: algo.reset(new BRepAlgoAPI_Fuse()); break;
    case FK_BOOL_CUT: algo.reset(new BRepAlgoAPI_Cut()); break;
    case FK_BOOL_COMMON: algo.reset(new BRepAlgoAPI_Common()); break;
    default: fail("Unknown boolean operation");
    }
    algo->SetArguments(args);
    algo->SetTools(tools);
    algo->SetNonDestructive(true);
    algo->SetRunParallel(true);
    algo->Build();
    if (!algo->IsDone() || algo->HasErrors())
      fail(std::string(name) + " failed: the bodies could not be combined");
    TopoDS_Shape r = algo->Shape();
    if (isEmpty(r) || (countOf(r, TopAbs_SOLID) == 0 && countOf(sa, TopAbs_SOLID) > 0 &&
                       countOf(sb, TopAbs_SOLID) > 0)) {
      if (op == FK_BOOL_COMMON) fail("Intersect failed: the bodies do not overlap");
      if (op == FK_BOOL_CUT) fail("Cut failed: nothing is left of the body");
      fail(std::string(name) + " failed: the result is empty");
    }
    return wrap(finish(r, std::string(name) + " failed: the result is not a valid solid"));
  });
}

// MARK: - Fillet / chamfer / shell

extern "C" FKShape *fk_fillet(const FKShape *shape, const int32_t *edgeIndices, int32_t count, double radius) {
  return guarded("Fillet", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape, "body");
    if (!isFinite(radius) || radius <= Precision::Confusion()) fail("Fillet radius must be greater than zero");
    std::vector<TopoDS_Edge> edges = blendEdges(shape, edgeIndices, count, "fillet");
    auto attempt = [&](double r) {
      BRepFilletAPI_MakeFillet mk(s);
      for (auto &e : edges) mk.Add(r, e);
      mk.Build();
      if (!mk.IsDone()) fail("fillet not done");
      return finish(mk.Shape(), "invalid fillet");
    };
    return wrap(blendWithDiagnosis(attempt, radius, "Fillet radius too large for the selected edges",
                                   "Could not fillet the selected edges"));
  });
}

extern "C" FKShape *fk_chamfer(const FKShape *shape, const int32_t *edgeIndices, int32_t count, double distance) {
  return guarded("Chamfer", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape, "body");
    if (!isFinite(distance) || distance <= Precision::Confusion()) fail("Chamfer distance must be greater than zero");
    std::vector<TopoDS_Edge> edges = blendEdges(shape, edgeIndices, count, "chamfer");
    auto attempt = [&](double d) {
      BRepFilletAPI_MakeChamfer mk(s);
      for (auto &e : edges) mk.Add(d, e);
      mk.Build();
      if (!mk.IsDone()) fail("chamfer not done");
      return finish(mk.Shape(), "invalid chamfer");
    };
    return wrap(blendWithDiagnosis(attempt, distance, "Chamfer distance too large for the selected edges",
                                   "Could not chamfer the selected edges"));
  });
}

extern "C" FKShape *fk_shell(const FKShape *shape, const int32_t *faceIndices, int32_t count, double thickness) {
  return guarded("Shell", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape, "body");
    if (!isFinite(thickness) || std::fabs(thickness) <= Precision::Confusion())
      fail("Shell thickness must be non-zero");
    if (count < 0 || (count > 0 && !faceIndices)) fail("Invalid face list");
    if (countOf(s, TopAbs_SOLID) != 1) fail("Shell needs a body with exactly one solid");
    TopExp_Explorer ex(s, TopAbs_SOLID);
    TopoDS_Shape solid = ex.Current();

    ShapeList removed;
    for (int32_t i = 0; i < count; i++) removed.Append(faceAt(shape, faceIndices[i]));
    if (count > 0 && removed.Extent() >= shape->faces().Extent()) fail("Shell cannot remove every face");

    TopoDS_Shape result;
    const std::string tooThick = "Shell failed: the wall thickness is too large for this body";
    if (count == 0) {
      BRepOffsetAPI_MakeOffsetShape off;
      off.PerformByJoin(solid, -thickness, 1e-3, BRepOffset_Skin, false, false, GeomAbs_Arc);
      if (!off.IsDone()) fail(tooThick);
      TopoDS_Shape inner = off.Shape();
      ShapeList args, tools;
      if (thickness > 0) {
        args.Append(solid);
        tools.Append(inner);
      } else {
        args.Append(inner);
        tools.Append(solid);
      }
      BRepAlgoAPI_Cut cut;
      cut.SetArguments(args);
      cut.SetTools(tools);
      cut.SetNonDestructive(true);
      cut.Build();
      if (!cut.IsDone() || cut.HasErrors()) fail(tooThick);
      result = cut.Shape();
    } else {
      BRepOffsetAPI_MakeThickSolid mk;
      mk.MakeThickSolidByJoin(solid, removed, -thickness, 1e-3, BRepOffset_Skin, false, false, GeomAbs_Arc);
      mk.Build();
      if (!mk.IsDone()) fail(tooThick);
      result = mk.Shape();
    }
    if (countOf(result, TopAbs_SOLID) == 0) fail(tooThick);
    result = finish(result, tooThick);
    // Sanity check: an inward shell must remove material, an outward one add it.
    double before = volumeOf(solid), after = volumeOf(result);
    if (after <= Precision::Confusion() || (thickness > 0 ? after >= before - Precision::Confusion()
                                                          : after <= before + Precision::Confusion()))
      fail(tooThick);
    return wrap(result);
  });
}

// MARK: - Transforms

extern "C" FKShape *fk_transform(const FKShape *shape, const double matrix[12]) {
  return guarded("Move", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape, "body");
    if (!matrix) fail("No transform matrix was given");
    for (int i = 0; i < 12; i++) requireFinite(matrix[i], "Transform matrix");
    const double *m = matrix;
    double det = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8]) +
                 m[2] * (m[4] * m[9] - m[5] * m[8]);
    if (std::fabs(det) < 1e-12) fail("Transform is degenerate (it flattens the body)");
    // Is the linear part a similarity (rotation/reflection × uniform scale)?
    double s2 = std::cbrt(det * det);
    bool similarity = true;
    for (int i = 0; i < 3 && similarity; i++)
      for (int j = 0; j < 3; j++) {
        double dot = m[0 + i] * m[0 + j] + m[4 + i] * m[4 + j] + m[8 + i] * m[8 + j];
        if (std::fabs(dot - (i == j ? s2 : 0)) > 1e-9 * std::max(1.0, s2)) {
          similarity = false;
          break;
        }
      }
    TopoDS_Shape result;
    if (similarity) {
      gp_Trsf t;
      t.SetValues(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
      BRepBuilderAPI_Transform mk(s, t, true);
      if (!mk.IsDone()) fail("Move failed");
      result = mk.Shape();
    } else {
      gp_GTrsf g;
      g.SetValue(1, 1, m[0]); g.SetValue(1, 2, m[1]); g.SetValue(1, 3, m[2]); g.SetValue(1, 4, m[3]);
      g.SetValue(2, 1, m[4]); g.SetValue(2, 2, m[5]); g.SetValue(2, 3, m[6]); g.SetValue(2, 4, m[7]);
      g.SetValue(3, 1, m[8]); g.SetValue(3, 2, m[9]); g.SetValue(3, 3, m[10]); g.SetValue(3, 4, m[11]);
      BRepBuilderAPI_GTransform mk(s, g, true);
      if (!mk.IsDone()) fail("Scale failed");
      result = mk.Shape();
    }
    return wrap(finish(result, "Move failed: the result is not valid", false));
  });
}

extern "C" FKShape *fk_mirror(const FKShape *shape, FKPlane plane) {
  return guarded("Mirror", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape, "body");
    gp_Ax3 ax = axes(plane);
    gp_Trsf t;
    t.SetMirror(gp_Ax2(ax.Location(), ax.Direction(), ax.XDirection()));
    BRepBuilderAPI_Transform mk(s, t, true);
    if (!mk.IsDone()) fail("Mirror failed");
    return wrap(finish(mk.Shape(), "Mirror failed: the result is not valid", false));
  });
}
