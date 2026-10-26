// Press Pull: moves faces of a solid along their normals (Fusion's offset face).
#include "Internal.hpp"

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <Precision.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>

#include <cmath>

using namespace fk;

namespace {

/// Outward normal of a planar face (the face's orientation applied).
gp_Dir planeNormal(const TopoDS_Face &f) {
  BRepGProp_Face gf(f);
  double u1, u2, v1, v2;
  gf.Bounds(u1, u2, v1, v2);
  gp_Pnt p;
  gp_Vec n;
  gf.Normal((u1 + u2) / 2, (v1 + v2) / 2, p, n);
  if (n.Magnitude() < 1e-12) fail("A selected face has no normal");
  return gp_Dir(n);
}

bool isPlanar(const TopoDS_Face &f) { return BRepAdaptor_Surface(f, false).GetType() == GeomAbs_Plane; }

/// Offsets only the given faces, every other face at 0: the moved faces' surfaces are
/// intersected with their neighbours, so a pulled top face carries sloped or rounded side
/// walls along, and a pulled hole face changes the hole's radius. Throws when OCCT can't.
TopoDS_Shape byOffset(const TopoDS_Shape &solid, const std::vector<TopoDS_Face> &faces, double distance) {
  BRepOffset_MakeOffset mk;
  mk.Initialize(solid, 0.0, 1e-4, BRepOffset_Skin, false, false, GeomAbs_Intersection, false, true);
  for (const auto &f : faces) mk.SetOffsetOnFace(f, distance);
  mk.MakeOffsetShape();
  if (!mk.IsDone()) fail("offset not done");
  return mk.Shape();
}

/// Planar faces only: a prism of each face along its normal, fused on for a pull and cut away
/// for a push. Exact when the neighbouring faces are perpendicular (the common case of a box
/// or an extrusion); sloped neighbours are not followed.
TopoDS_Shape byPrism(const TopoDS_Shape &solid, const std::vector<TopoDS_Face> &faces, double distance) {
  ShapeList args, tools;
  args.Append(solid);
  for (const auto &f : faces) {
    if (!isPlanar(f)) fail("not planar");
    gp_Vec v(planeNormal(f));
    v *= distance;
    BRepPrimAPI_MakePrism prism(f, v);
    if (!prism.IsDone()) fail("prism not done");
    tools.Append(prism.Shape());
  }
  if (distance > 0) {
    BRepAlgoAPI_Fuse op;
    op.SetArguments(args);
    op.SetTools(tools);
    op.SetNonDestructive(true);
    op.Build();
    if (!op.IsDone() || op.HasErrors()) fail("fuse failed");
    return op.Shape();
  }
  BRepAlgoAPI_Cut op;
  op.SetArguments(args);
  op.SetTools(tools);
  op.SetNonDestructive(true);
  op.Build();
  if (!op.IsDone() || op.HasErrors()) fail("cut failed");
  return op.Shape();
}

/// The result must be one valid solid that grew for a pull and shrank for a push.
TopoDS_Shape checked(const TopoDS_Shape &raw, double before, double distance, const std::string &message) {
  if (isEmpty(raw) || countOf(raw, TopAbs_SOLID) != 1) fail(message);
  TopoDS_Shape result = finish(raw, message);
  if (countOf(result, TopAbs_SOLID) != 1) fail(message);
  double after = volumeOf(result);
  double tol = std::max(Precision::Confusion(), before * 1e-9);
  if (after <= tol || (distance > 0 ? after <= before + tol : after >= before - tol)) fail(message);
  return result;
}

} // namespace

extern "C" FKShape *fk_offset_faces(const FKShape *shape, const int32_t *faceIndices, int32_t count, double distance) {
  return guarded("Press Pull", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape, "body");
    if (!isFinite(distance) || std::fabs(distance) <= Precision::Confusion())
      fail("Press Pull distance must be non-zero");
    if (count <= 0 || !faceIndices) fail("Select at least one face to press or pull");
    if (countOf(s, TopAbs_SOLID) != 1) fail("Press Pull needs a body with exactly one solid");
    TopExp_Explorer ex(s, TopAbs_SOLID);
    TopoDS_Shape solid = ex.Current();

    const ShapeMap &all = shape->faces();
    std::vector<TopoDS_Face> faces;
    NCollection_Map<TopoDS_Shape, TopTools_ShapeMapHasher> seen;
    bool allPlanar = true;
    for (int32_t i = 0; i < count; i++) {
      int32_t index = faceIndices[i];
      if (index < 0 || index >= all.Extent())
        fail("Face " + std::to_string(index) + " does not exist (the body has " + std::to_string(all.Extent()) +
             " faces)");
      const TopoDS_Face &f = TopoDS::Face(all(index + 1));
      if (!seen.Add(f)) continue;
      allPlanar = allPlanar && isPlanar(f);
      faces.push_back(f);
    }
    if (faces.size() >= (size_t)all.Extent()) fail("Press Pull cannot move every face of a body");

    const double before = volumeOf(solid);
    const std::string message = distance > 0
        ? "Press Pull failed: the faces can't be pulled this far"
        : "Press Pull failed: the faces can't be pushed this far";
    // Offsetting follows the neighbouring faces, so it is tried first; a prism is the planar
    // fallback for the cases OCCT's offset algorithm refuses.
    try {
      return wrapFinished(checked(byOffset(solid, faces, distance), before, distance, message));
    } catch (const Error &) {
    } catch (const Standard_Failure &) {
    }
    if (!allPlanar) fail(message);
    try {
      return wrapFinished(checked(byPrism(solid, faces, distance), before, distance, message));
    } catch (const Standard_Failure &) {
      fail(message);
    }
  });
}
