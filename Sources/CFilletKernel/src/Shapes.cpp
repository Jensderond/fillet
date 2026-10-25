// Shape handles, lists, errors, shared post-processing and primitives.
#include "Internal.hpp"

#include <BOPTools_AlgoTools.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRep_Builder.hxx>
#include <GProp_GProps.hxx>
#include <Precision.hxx>
#include <ShapeFix_Shape.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Iterator.hxx>

#include <cmath>
#include <cstring>

// MARK: - FKShape

const ShapeMap &FKShape::faces() const {
  std::call_once(facesOnce, [this] { TopExp::MapShapes(shape, TopAbs_FACE, faceMap); });
  return faceMap;
}

const ShapeMap &FKShape::edges() const {
  std::call_once(edgesOnce, [this] { TopExp::MapShapes(shape, TopAbs_EDGE, edgeMap); });
  return edgeMap;
}

namespace fk {

// MARK: - Errors

static thread_local std::string tlsError;

void setError(const std::string &message) { tlsError = message; }
void clearError() { tlsError.clear(); }

std::string describeFailure(const char *operation, const char *exceptionType, const char *what) {
  std::string op = operation ? operation : "Operation";
  std::string msg = what ? what : "";
  std::string type = exceptionType ? exceptionType : "";
  // OCCT messages are mostly internal ("BRep_API: command not done"); only keep
  // ones that read like a sentence.
  bool readable = !msg.empty() && msg.find("_") == std::string::npos && msg.find("::") == std::string::npos &&
                  msg.find(' ') != std::string::npos && msg.size() < 160;
  if (type == "Standard_OutOfMemory") return op + " failed: out of memory";
  if (type == "Standard_ConstructionError" || type == "gp_VectorWithNullMagnitude")
    return op + " failed: degenerate geometry (zero-length or zero-size input)";
  if (readable) return op + " failed: " + msg;
  return op + " failed: the geometry kernel could not compute a valid result";
}

// MARK: - Conversions

bool isFinite(double v) { return std::isfinite(v); }

gp_Dir dir(const FKVec3 &v, const char *what) {
  if (!isFinite(v.x) || !isFinite(v.y) || !isFinite(v.z)) fail(std::string(what) + " is not a finite vector");
  double l = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  if (l < 1e-12) fail(std::string(what) + " must not be a zero vector");
  return gp_Dir(v.x / l, v.y / l, v.z / l);
}

gp_Ax3 axes(const FKPlane &plane) {
  if (!isFinite(plane.origin.x) || !isFinite(plane.origin.y) || !isFinite(plane.origin.z))
    fail("Plane origin is not finite");
  gp_Dir n = dir(plane.normal, "Plane normal");
  gp_Vec x(plane.xDir.x, plane.xDir.y, plane.xDir.z);
  if (!isFinite(x.X()) || !isFinite(x.Y()) || !isFinite(x.Z())) x = gp_Vec(1, 0, 0);
  gp_Vec xo = x - gp_Vec(n) * x.Dot(gp_Vec(n));
  if (xo.Magnitude() < 1e-9) {
    // Any perpendicular direction.
    gp_Vec helper = std::fabs(n.X()) < 0.9 ? gp_Vec(1, 0, 0) : gp_Vec(0, 1, 0);
    xo = gp_Vec(n).Crossed(helper);
  }
  return gp_Ax3(pnt(plane.origin), n, gp_Dir(xo));
}

// MARK: - Shape helpers

const TopoDS_Shape &shapeOf(const FKShape *s, const char *what) {
  if (!s) fail(std::string("No ") + what + " was given");
  if (s->shape.IsNull()) fail(std::string("The ") + what + " is empty");
  return s->shape;
}

FKShape *wrap(const TopoDS_Shape &s) { return new FKShape(s); }

bool isEmpty(const TopoDS_Shape &s) {
  if (s.IsNull()) return true;
  if (s.ShapeType() == TopAbs_COMPOUND || s.ShapeType() == TopAbs_COMPSOLID) {
    for (TopoDS_Iterator it(s); it.More(); it.Next())
      if (!isEmpty(it.Value())) return false;
    return true;
  }
  return false;
}

int countOf(const TopoDS_Shape &s, TopAbs_ShapeEnum type) {
  if (s.IsNull()) return 0;
  ShapeMap m;
  TopExp::MapShapes(s, type, m);
  return m.Extent();
}

TopoDS_Shape unify(const TopoDS_Shape &s) {
  if (s.IsNull()) return s;
  try {
    ShapeUpgrade_UnifySameDomain u(s, true, true, true);
    u.AllowInternalEdges(false);
    u.Build();
    TopoDS_Shape r = u.Shape();
    if (!r.IsNull()) return r;
  } catch (const Standard_Failure &) {
    // Unification is cosmetic; keep the un-merged result.
  }
  return s;
}

static bool checkValid(const TopoDS_Shape &s) {
  BRepCheck_Analyzer ana(s, true);
  return ana.IsValid();
}

TopoDS_Shape validated(const TopoDS_Shape &s, const std::string &failureMessage) {
  if (isEmpty(s)) fail(failureMessage);
  if (checkValid(s)) return s;
  ShapeFix_Shape fix(s);
  fix.Perform();
  TopoDS_Shape fixed = fix.Shape();
  if (isEmpty(fixed) || !checkValid(fixed)) fail(failureMessage);
  return fixed;
}

/// Whether a (valid, closed) solid is inside out: a point at infinity classifies as inside it.
/// Same answer as a negative volume, but a ray test instead of integrating over every face
/// (about 7x faster on an 88-face B-spline body).
static bool isInsideOut(const TopoDS_Shape &solid) {
  return BOPTools_AlgoTools::IsInvertedSolid(TopoDS::Solid(solid));
}

/// Returns the shape with every inside-out solid reversed (positive volume).
static TopoDS_Shape orientSolids(const TopoDS_Shape &s) {
  if (s.IsNull()) return s;
  if (s.ShapeType() == TopAbs_SOLID) return isInsideOut(s) ? s.Reversed() : s;
  if (s.ShapeType() != TopAbs_COMPOUND && s.ShapeType() != TopAbs_COMPSOLID) return s;
  bool needsFix = false;
  for (TopExp_Explorer ex(s, TopAbs_SOLID); ex.More() && !needsFix; ex.Next())
    needsFix = isInsideOut(ex.Current());
  if (!needsFix) return s;
  BRep_Builder b;
  TopoDS_Compound c;
  b.MakeCompound(c);
  for (TopoDS_Iterator it(s); it.More(); it.Next()) b.Add(c, orientSolids(it.Value()));
  return c;
}

TopoDS_Shape finish(const TopoDS_Shape &input, const std::string &failureMessage, bool doUnify) {
  if (isEmpty(input)) fail(failureMessage);
  TopoDS_Shape s = doUnify ? unify(input) : input;
  s = validated(s, failureMessage);
  return orientSolids(s);
}

double volumeOf(const TopoDS_Shape &s) {
  if (s.IsNull()) return 0;
  GProp_GProps props;
  BRepGProp::VolumeProperties(s, props);
  return props.Mass();
}

} // namespace fk

using namespace fk;

// MARK: - C API: errors, shapes, lists

extern "C" const char *fk_last_error(void) { return tlsError.c_str(); }

extern "C" void fk_shape_free(FKShape *shape) { delete shape; }

extern "C" FKShape *fk_shape_copy(const FKShape *shape) {
  return guarded("Copy", (FKShape *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    return wrap(s);
  });
}

extern "C" FKShape *fk_compound(const FKShape *const *shapes, int32_t count) {
  return guarded("Combine", (FKShape *)nullptr, [&]() -> FKShape * {
    if (count < 0 || (count > 0 && !shapes)) fail("Invalid shape list");
    BRep_Builder b;
    TopoDS_Compound c;
    b.MakeCompound(c);
    for (int32_t i = 0; i < count; i++) {
      if (!shapes[i] || shapes[i]->shape.IsNull()) continue;
      b.Add(c, shapes[i]->shape);
    }
    return wrap(c);
  });
}

extern "C" int32_t fk_solid_count(const FKShape *shape) {
  return guarded("Count solids", (int32_t)0, [&] { return (int32_t)countOf(shapeOf(shape), TopAbs_SOLID); });
}

extern "C" FKShapeList *fk_solids(const FKShape *shape) {
  return guarded("List solids", (FKShapeList *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    auto *list = new FKShapeList;
    ShapeMap m;
    TopExp::MapShapes(s, TopAbs_SOLID, m);
    for (int i = 1; i <= m.Extent(); i++) list->items.push_back(m(i));
    return list;
  });
}

extern "C" int32_t fk_list_count(const FKShapeList *list) { return list ? (int32_t)list->items.size() : 0; }

extern "C" FKShape *fk_list_get(const FKShapeList *list, int32_t index) {
  return guarded("List access", (FKShape *)nullptr, [&]() -> FKShape * {
    if (!list) fail("No list was given");
    if (index < 0 || index >= (int32_t)list->items.size())
      fail("Index " + std::to_string(index) + " is out of range (list has " + std::to_string(list->items.size()) +
           " items)");
    return wrap(list->items[index]);
  });
}

extern "C" void fk_list_free(FKShapeList *list) { delete list; }

// MARK: - Primitives

static void requirePositive(double v, const char *what) {
  if (!isFinite(v) || v <= Precision::Confusion()) fail(std::string(what) + " must be greater than zero");
}

extern "C" FKShape *fk_box(FKVec3 corner, FKVec3 size) {
  return guarded("Box", (FKShape *)nullptr, [&] {
    if (!isFinite(corner.x) || !isFinite(corner.y) || !isFinite(corner.z)) fail("Box corner is not finite");
    double sx = std::fabs(size.x), sy = std::fabs(size.y), sz = std::fabs(size.z);
    if (!isFinite(sx) || !isFinite(sy) || !isFinite(sz) || sx <= Precision::Confusion() ||
        sy <= Precision::Confusion() || sz <= Precision::Confusion())
      fail("Box width, depth and height must all be non-zero");
    gp_Pnt c(corner.x + std::fmin(0.0, size.x), corner.y + std::fmin(0.0, size.y),
             corner.z + std::fmin(0.0, size.z));
    BRepPrimAPI_MakeBox mk(c, sx, sy, sz);
    mk.Build();
    if (!mk.IsDone()) fail("Box could not be created");
    return wrap(finish(mk.Shape(), "Box could not be created", false));
  });
}

extern "C" FKShape *fk_cylinder(FKPlane base, double radius, double height) {
  return guarded("Cylinder", (FKShape *)nullptr, [&] {
    requirePositive(radius, "Cylinder radius");
    if (!isFinite(height) || std::fabs(height) <= Precision::Confusion()) fail("Cylinder height must be non-zero");
    gp_Ax3 ax = axes(base);
    gp_Ax2 a2(ax.Location(), ax.Direction(), ax.XDirection());
    if (height < 0) a2 = gp_Ax2(ax.Location(), ax.Direction().Reversed(), ax.XDirection());
    BRepPrimAPI_MakeCylinder mk(a2, radius, std::fabs(height));
    mk.Build();
    if (!mk.IsDone()) fail("Cylinder could not be created");
    return wrap(finish(mk.Shape(), "Cylinder could not be created", false));
  });
}

extern "C" FKShape *fk_sphere(FKVec3 center, double radius) {
  return guarded("Sphere", (FKShape *)nullptr, [&] {
    requirePositive(radius, "Sphere radius");
    if (!isFinite(center.x) || !isFinite(center.y) || !isFinite(center.z)) fail("Sphere center is not finite");
    BRepPrimAPI_MakeSphere mk(pnt(center), radius);
    mk.Build();
    if (!mk.IsDone()) fail("Sphere could not be created");
    return wrap(finish(mk.Shape(), "Sphere could not be created", false));
  });
}

extern "C" FKShape *fk_cone(FKPlane base, double radius1, double radius2, double height) {
  return guarded("Cone", (FKShape *)nullptr, [&] {
    if (!isFinite(radius1) || !isFinite(radius2) || radius1 < 0 || radius2 < 0)
      fail("Cone radii must not be negative");
    if (radius1 <= Precision::Confusion() && radius2 <= Precision::Confusion())
      fail("At least one cone radius must be greater than zero");
    if (std::fabs(radius1 - radius2) <= Precision::Confusion())
      fail("Cone radii must differ (use a cylinder for equal radii)");
    requirePositive(height, "Cone height");
    gp_Ax3 ax = axes(base);
    BRepPrimAPI_MakeCone mk(gp_Ax2(ax.Location(), ax.Direction(), ax.XDirection()), radius1, radius2, height);
    mk.Build();
    if (!mk.IsDone()) fail("Cone could not be created");
    return wrap(finish(mk.Shape(), "Cone could not be created", false));
  });
}

extern "C" FKShape *fk_torus(FKPlane base, double majorRadius, double minorRadius) {
  return guarded("Torus", (FKShape *)nullptr, [&] {
    requirePositive(majorRadius, "Torus major radius");
    requirePositive(minorRadius, "Torus minor radius");
    if (minorRadius >= majorRadius) fail("Torus minor radius must be smaller than the major radius");
    gp_Ax3 ax = axes(base);
    BRepPrimAPI_MakeTorus mk(gp_Ax2(ax.Location(), ax.Direction(), ax.XDirection()), majorRadius, minorRadius);
    mk.Build();
    if (!mk.IsDone()) fail("Torus could not be created");
    return wrap(finish(mk.Shape(), "Torus could not be created", false));
  });
}
