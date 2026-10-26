// Holes: drilled, counterbored and countersunk holes cut into a body (like Fusion's Hole).
#include "Internal.hpp"

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <Bnd_Box.hxx>
#include <Precision.hxx>
#include <gp_Ax1.hxx>

#include <cmath>
#include <utility>

using namespace fk;

namespace {

/// How far the tool starts above the face, so the cut never shares the face's plane.
constexpr double kAbove = 0.01;

/// The full-diameter depth of a through-all hole: past the far side of the body's bounding box.
double throughDepth(const TopoDS_Shape &body, const gp_Pnt &center, const gp_Dir &dir) {
  Bnd_Box box;
  BRepBndLib::Add(body, box);
  if (box.IsVoid()) fail("Hole failed: the body is empty");
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  double far = 0;
  for (int i = 0; i < 8; i++) {
    gp_Pnt corner(i & 1 ? x1 : x0, i & 2 ? y1 : y0, i & 4 ? z1 : z0);
    far = std::max(far, gp_Vec(center, corner).Dot(gp_Vec(dir)));
  }
  return far + 1;
}

/// The solid a hole removes: its half cross-section (radius r, depth z along `dir`, z = 0 on
/// the face) revolved around the hole axis. Planes, cylinders and cones come out as such, so
/// the hole's faces read as cylinders afterwards.
TopoDS_Shape holeTool(const gp_Pnt &center, const gp_Dir &dir, const FKHoleSpec &spec, double depth, bool through) {
  const double r = spec.diameter / 2;
  std::vector<std::pair<double, double>> rz;  // (radius, depth)
  rz.push_back({0, -kAbove});
  switch (spec.type) {
  case FK_HOLE_COUNTERBORE: {
    const double rh = spec.headDiameter / 2;
    rz.push_back({rh, -kAbove});
    rz.push_back({rh, spec.headDepth});
    rz.push_back({r, spec.headDepth});
    break;
  }
  case FK_HOLE_COUNTERSINK: {
    const double rh = spec.headDiameter / 2, t = std::tan(spec.headAngle / 2);
    rz.push_back({rh + kAbove * t, -kAbove});
    rz.push_back({r, (rh - r) / t});
    break;
  }
  default:
    rz.push_back({r, -kAbove});
    break;
  }
  rz.push_back({r, depth});
  if (!through && spec.tipAngle > 0) {
    rz.push_back({0, depth + r / std::tan(spec.tipAngle / 2)});
  } else {
    rz.push_back({0, depth});
  }

  // Any direction across the axis works: the section is revolved all the way round.
  gp_Ax2 frame(center, dir);
  const gp_Vec across(frame.XDirection()), along(dir);
  BRepBuilderAPI_MakePolygon poly;
  for (auto &[rad, z] : rz) poly.Add(center.Translated(across * rad + along * z));
  poly.Close();
  if (!poly.IsDone()) fail("Hole failed: the hole's cross-section is invalid");
  BRepBuilderAPI_MakeFace face(poly.Wire(), true);
  if (!face.IsDone()) fail("Hole failed: the hole's cross-section is invalid");
  BRepPrimAPI_MakeRevol revol(face.Face(), gp_Ax1(center, dir), 2 * M_PI);
  revol.Build();
  if (!revol.IsDone()) fail("Hole failed: the hole shape could not be built");
  return revol.Shape();
}

void checkSpec(const FKHoleSpec &spec) {
  const bool through = spec.depth <= 0;
  if (!isFinite(spec.diameter) || spec.diameter <= Precision::Confusion()) fail("Hole diameter must be greater than zero");
  if (!isFinite(spec.depth)) fail("Hole depth is not a number");
  if (!isFinite(spec.tipAngle) || spec.tipAngle < 0 || spec.tipAngle >= M_PI)
    fail("Drill point angle must be between 0° and 180°");
  switch (spec.type) {
  case FK_HOLE_SIMPLE:
    break;
  case FK_HOLE_COUNTERBORE:
    if (!isFinite(spec.headDiameter) || spec.headDiameter <= spec.diameter + Precision::Confusion())
      fail("Counterbore diameter must be larger than the hole diameter");
    if (!isFinite(spec.headDepth) || spec.headDepth <= Precision::Confusion())
      fail("Counterbore depth must be greater than zero");
    if (!through && spec.headDepth >= spec.depth - Precision::Confusion())
      fail("Counterbore depth must be less than the hole depth");
    break;
  case FK_HOLE_COUNTERSINK: {
    if (!isFinite(spec.headDiameter) || spec.headDiameter <= spec.diameter + Precision::Confusion())
      fail("Countersink diameter must be larger than the hole diameter");
    if (!isFinite(spec.headAngle) || spec.headAngle <= Precision::Angular() || spec.headAngle >= M_PI)
      fail("Countersink angle must be between 0° and 180°");
    const double sink = (spec.headDiameter - spec.diameter) / 2 / std::tan(spec.headAngle / 2);
    if (!through && sink >= spec.depth - Precision::Confusion())
      fail("The countersink is deeper than the hole: make the hole deeper or the countersink smaller");
    break;
  }
  default:
    fail("Unknown hole type");
  }
}

} // namespace

extern "C" FKShape *fk_holes(const FKShape *shape, const FKVec3 *centers, int32_t count, FKVec3 direction,
                             const FKHoleSpec *spec) {
  return guarded("Hole", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &body = shapeOf(shape, "body");
    if (!spec) fail("No hole size was given");
    if (count < 1 || !centers) fail("Place at least one hole");
    if (countOf(body, TopAbs_SOLID) == 0) fail("Holes need a solid body");
    checkSpec(*spec);
    const gp_Dir d = dir(direction, "hole direction");
    const bool through = spec->depth <= 0;

    ShapeList args, tools;
    args.Append(body);
    for (int32_t i = 0; i < count; i++) {
      if (!isFinite(centers[i].x) || !isFinite(centers[i].y) || !isFinite(centers[i].z))
        fail("Hole " + std::to_string(i + 1) + " has no valid centre");
      const gp_Pnt c = pnt(centers[i]);
      const double depth = through ? throughDepth(body, c, d) : spec->depth;
      tools.Append(holeTool(c, d, *spec, depth, through));
    }

    BRepAlgoAPI_Cut cut;
    cut.SetArguments(args);
    cut.SetTools(tools);
    cut.SetNonDestructive(true);
    cut.SetRunParallel(true);
    cut.SetCheckInverted(!shape->solidsOriented);
    cut.Build();
    if (!cut.IsDone() || cut.HasErrors()) fail("Hole failed: the holes could not be cut into the body");
    TopoDS_Shape result = cut.Shape();
    if (isEmpty(result) || countOf(result, TopAbs_SOLID) == 0) fail("Hole failed: nothing is left of the body");
    result = finish(result, "Hole failed: the result is not a valid solid");
    if (volumeOf(result) >= volumeOf(body) - Precision::Confusion())
      fail("Hole failed: the holes miss the body (are they on the face?)");
    return wrapFinished(result);
  });
}
