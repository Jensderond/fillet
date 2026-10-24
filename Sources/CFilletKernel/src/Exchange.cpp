// Data exchange: STEP import/export (AP214, mm, named products) and BRep text serialisation.
#include "Internal.hpp"

#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Static.hxx>
#include <STEPCAFControl_Controller.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <STEPControl_Controller.hxx>
#include <STEPControl_Reader.hxx>
#include <ShapeFix_Shape.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>

#include <cstdlib>
#include <cstring>
#include <sstream>
#include <sys/stat.h>

using namespace fk;

namespace {

/// The STEP translators use process-wide static parameters; serialise all access.
std::mutex &stepMutex() {
  static std::mutex m;
  return m;
}

void initStep() {
  static std::once_flag once;
  std::call_once(once, [] {
    STEPControl_Controller::Init();
    STEPCAFControl_Controller::Init();
  });
}

bool fileExists(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

} // namespace

extern "C" FKShape *fk_import_step(const char *path) {
  return guarded("STEP import", (FKShape *)nullptr, [&] {
    if (!path || !*path) fail("No file was given");
    if (!fileExists(path)) fail("The STEP file does not exist or cannot be read");
    std::lock_guard<std::mutex> lock(stepMutex());
    initStep();
    Interface_Static::SetCVal("xstep.cascade.unit", "MM");
    STEPControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) fail("The file is not a readable STEP file");
    reader.TransferRoots();
    TopoDS_Shape s = reader.OneShape();
    if (isEmpty(s)) fail("The STEP file contains no geometry");
    // Repair common defects of foreign files; keep the original if fixing fails.
    try {
      ShapeFix_Shape fix(s);
      fix.Perform();
      if (!isEmpty(fix.Shape())) s = fix.Shape();
    } catch (const Standard_Failure &) {
    }
    return wrap(s);
  });
}

extern "C" bool fk_export_step(const FKShape *const *shapes, const char *const *names, int32_t count,
                               const char *path) {
  return guarded("STEP export", false, [&] {
    if (!path || !*path) fail("No file was given");
    if (count <= 0 || !shapes) fail("Nothing to export");
    std::lock_guard<std::mutex> lock(stepMutex());
    initStep();

    occ::handle<TDocStd_Document> doc = new TDocStd_Document("MDTV-XCAF");
    XCAFDoc_DocumentTool::SetLengthUnit(doc, 0.001); // millimetres, expressed in metres
    occ::handle<XCAFDoc_ShapeTool> tool = XCAFDoc_DocumentTool::ShapeTool(doc->Main());
    int added = 0;
    for (int32_t i = 0; i < count; i++) {
      if (!shapes[i] || isEmpty(shapes[i]->shape)) continue;
      TDF_Label label = tool->AddShape(shapes[i]->shape, false);
      std::string name = (names && names[i] && *names[i]) ? names[i] : ("Body " + std::to_string(i + 1));
      TDataStd_Name::Set(label, TCollection_ExtendedString(name.c_str(), true));
      added++;
    }
    if (added == 0) fail("Nothing to export: all bodies are empty");

    Interface_Static::SetCVal("write.step.schema", "AP214IS");
    Interface_Static::SetCVal("write.step.unit", "MM");
    Interface_Static::SetCVal("xstep.cascade.unit", "MM");
    STEPCAFControl_Writer writer;
    writer.SetNameMode(true);
    writer.SetColorMode(false);
    writer.SetLayerMode(false);
    if (!writer.Transfer(doc, STEPControl_AsIs)) fail("The bodies could not be converted to STEP");
    if (writer.Write(path) != IFSelect_RetDone) fail("The STEP file could not be written");
    return true;
  });
}

extern "C" char *fk_brep_write_string(const FKShape *shape) {
  return guarded("BRep export", (char *)nullptr, [&] {
    const TopoDS_Shape &s = shapeOf(shape);
    std::ostringstream out;
    BRepTools::Write(s, out, false, false, TopTools_FormatVersion_CURRENT);
    std::string str = out.str();
    char *buf = (char *)std::malloc(str.size() + 1);
    if (!buf) fail("Out of memory");
    std::memcpy(buf, str.c_str(), str.size() + 1);
    return buf;
  });
}

extern "C" FKShape *fk_brep_read_string(const char *data) {
  return guarded("BRep import", (FKShape *)nullptr, [&] {
    if (!data || !*data) fail("The geometry data is empty");
    std::istringstream in{std::string(data)};
    TopoDS_Shape s;
    BRep_Builder b;
    BRepTools::Read(s, in, b);
    if (s.IsNull()) fail("The geometry data could not be read");
    return wrap(s);
  });
}

extern "C" void fk_string_free(char *s) { std::free(s); }
