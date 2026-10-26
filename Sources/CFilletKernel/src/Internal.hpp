// Shared internals of the Fillet kernel implementation (not part of the C API).
#pragma once

#include "FilletKernel.h"

#include <NCollection_IndexedDataMap.hxx>
#include <NCollection_IndexedMap.hxx>
#include <NCollection_List.hxx>
#include <NCollection_Map.hxx>
#include <Standard_Failure.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Dir.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>

#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using ShapeMap = NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>;
using ShapeList = NCollection_List<TopoDS_Shape>;
using AncestorMap =
    NCollection_IndexedDataMap<TopoDS_Shape, NCollection_List<TopoDS_Shape>, TopTools_ShapeMapHasher>;

/// Owned shape handle. Face/edge index maps are built lazily (the shape itself never changes).
struct FKShape {
  explicit FKShape(const TopoDS_Shape &s) : shape(s) {}
  TopoDS_Shape shape;
  /// Every solid is known to point outwards: the shape came out of finish().
  bool solidsOriented = false;

  const ShapeMap &faces() const;
  const ShapeMap &edges() const;
  const ShapeMap &vertices() const;

private:
  mutable std::once_flag facesOnce, edgesOnce, verticesOnce;
  mutable ShapeMap faceMap, edgeMap, vertexMap;
};

struct FKShapeList {
  std::vector<TopoDS_Shape> items;
};

struct FKMesh {
  std::vector<float> positions;
  std::vector<float> normals;
  std::vector<uint32_t> indices;
  std::vector<int32_t> triangleFaces;
  std::vector<std::vector<float>> edges;
  std::vector<float> brepVertices; // xyz per B-rep vertex
};

namespace fk {

// MARK: Errors

void setError(const std::string &message);
void clearError();

/// Thrown by kernel code to report a user-facing failure.
struct Error : std::exception {
  explicit Error(std::string m) : message(std::move(m)) {}
  const char *what() const noexcept override { return message.c_str(); }
  std::string message;
};

[[noreturn]] inline void fail(const std::string &message) { throw Error(message); }

/// Turns an OCCT exception into something a user can read.
std::string describeFailure(const char *operation, const char *exceptionType, const char *what);

/// Sizes OCCT's thread pool (once per process, before the kernel's first parallel loop).
void ensureThreadPool();

/// Runs `body`, converting every exception into fk_last_error() + `failValue`.
template <typename R, typename F> R guarded(const char *operation, R failValue, F &&body) {
  ensureThreadPool();
  clearError();
  try {
    return body();
  } catch (const Error &e) {
    setError(e.message);
  } catch (const Standard_Failure &e) {
    setError(describeFailure(operation, e.ExceptionType(), e.what()));
  } catch (const std::bad_alloc &) {
    setError(std::string(operation) + " failed: out of memory");
  } catch (const std::exception &e) {
    setError(describeFailure(operation, nullptr, e.what()));
  } catch (...) {
    setError(std::string(operation) + " failed (unknown kernel error)");
  }
  return failValue;
}

// MARK: Conversions

inline gp_Pnt pnt(const FKVec3 &v) { return gp_Pnt(v.x, v.y, v.z); }
inline gp_Vec vec(const FKVec3 &v) { return gp_Vec(v.x, v.y, v.z); }
inline FKVec3 fkv(const gp_XYZ &p) { return FKVec3{p.X(), p.Y(), p.Z()}; }
inline FKVec3 fkv(const gp_Pnt &p) { return fkv(p.XYZ()); }
inline FKVec3 fkv(const gp_Vec &p) { return fkv(p.XYZ()); }
inline FKVec3 fkv(const gp_Dir &p) { return fkv(p.XYZ()); }

/// Validated unit direction (throws a readable error for zero/NaN vectors).
gp_Dir dir(const FKVec3 &v, const char *what);
/// Right-handed placement from an FKPlane (xDir is re-orthogonalised).
gp_Ax3 axes(const FKPlane &plane);
inline gp_Pln pln(const FKPlane &plane) { return gp_Pln(axes(plane)); }

bool isFinite(double v);

// MARK: Shape helpers

const TopoDS_Shape &shapeOf(const FKShape *s, const char *what = "shape");
FKShape *wrap(const TopoDS_Shape &s);
/// wrap() for a shape that went through finish(), so its solids are known to point outwards.
FKShape *wrapFinished(const TopoDS_Shape &s);

bool isEmpty(const TopoDS_Shape &s);
int countOf(const TopoDS_Shape &s, TopAbs_ShapeEnum type);

/// Merges coplanar/co-cylindrical faces and collinear edges.
TopoDS_Shape unify(const TopoDS_Shape &s);
/// Checks the result with BRepCheck_Analyzer, repairs it with ShapeFix_Shape
/// if needed and throws `failureMessage` if it is still invalid.
TopoDS_Shape validated(const TopoDS_Shape &s, const std::string &failureMessage);
/// unify + validate + make every closed solid point outwards. The standard
/// post-processing step for every modelling operation.
TopoDS_Shape finish(const TopoDS_Shape &s, const std::string &failureMessage, bool doUnify = true);

/// Volume and surface area via BRepGProp (default precision), faces integrated in parallel.
/// Bit-identical to BRepGProp::VolumeProperties / SurfaceProperties(s, props).Mass().
double volumeOf(const TopoDS_Shape &s);
double surfaceAreaOf(const TopoDS_Shape &s);

} // namespace fk
