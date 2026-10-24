// Temporary wiring smoke test; replaced by the real kernel implementation.
#include "FilletKernel.h"
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <TopoDS_Shape.hxx>

struct FKShape { TopoDS_Shape shape; };

extern "C" FKShape *fk_box(FKVec3 c, FKVec3 s) {
  return new FKShape{BRepPrimAPI_MakeBox(gp_Pnt(c.x, c.y, c.z), s.x, s.y, s.z).Shape()};
}
extern "C" double fk_volume(const FKShape *shape) {
  GProp_GProps props;
  BRepGProp::VolumeProperties(shape->shape, props);
  return props.Mass();
}
extern "C" void fk_shape_free(FKShape *shape) { delete shape; }
