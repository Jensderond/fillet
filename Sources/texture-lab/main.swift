import FilletAgent
import FilletCore
import FilletKernel
import Foundation

// `texture-lab`: the surface-texture workbench. Renders reference and exported meshes with one
// fixed product-shot look, exports textured designs to 3MF, checks meshes are watertight, and
// builds sample designs. Run `swift run -c release texture-lab help`.

let usage = """
    texture-lab — surface texture workbench

    USAGE
      texture-lab render <file.stl|.3mf|.fillet> -o out.png [--camera hero|front|iso|top|closeup|grazing]
                         [--size 1200x1200] [--color D9D4CB] [--crease 60]
          Product shot with fixed lighting, material and framing (by bounding box), so a reference
          STL and our export render identically. --camera all writes out-<camera>.png for each.
      texture-lab export <design.fillet> -o out.3mf|out.stl [--display]
          Recomputes the design and writes what the app's export writes (textures at export detail;
          --display uses the coarser viewport detail; --edge-scale and --max-triangles override it;
          --viewport writes the app viewport's own meshes as STL).
      texture-lab check <file.stl|.3mf|.fillet> [--no-intersections]
          One-line verdict: PASS/FAIL with open, non-manifold and flipped edges, degenerate and
          self-intersecting triangles, volume and size. Exit status 1 on FAIL.
      texture-lab sample -o sample.fillet [--base cylinder|vase|box] [--diameter 60] [--height 80]
                         [--top-diameter D] [--bulge 1.25] [--shell T] [--faces sides|all]
                         [--pattern <id>|none] [--value id=expr ...] [--3mf out.3mf] [--png out.png]
                         [--camera hero]
          Builds a textured sample design from flags (to match a reference's proportions).
      texture-lab patterns
          Lists the texture catalogue: ids, names and parameters (id, default, unit, range).
      texture-lab bench [--runs 5] [--fixture <name|file.fillet> ...] [--mode display|export]
                        [--stages] [--loop <seconds>] [--dir Benchmarks/textures]
          Times the texture step as the app runs it on the fixtures in Benchmarks/textures:
          display (the viewport's recompute on every edit) and export. Prints the median ms,
          triangles and a bit-exact mesh digest per fixture and mode (markdown; progress on
          stderr). --stages adds the engine's time per stage; --loop re-runs one fixture and
          mode for that long (to attach a profiler). See docs/texture-performance.md.
    """

var arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("texture-lab: \(message)\n".utf8))
    exit(2)
}

@MainActor func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + 1 < arguments.count else { fail("\(name) needs a value") }
    let v = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return v
}

@MainActor func options(_ name: String) -> [String] {
    var out: [String] = []
    while let v = option(name) { out.append(v) }
    return out
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

@MainActor func number(_ name: String) -> Double? {
    guard let s = option(name) else { return nil }
    guard let v = Double(s) else { fail("\(name) must be a number, not \(s)") }
    return v
}

func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

func size(_ s: String?) -> CGSize {
    guard let s else { return CGSize(width: 1200, height: 1200) }
    let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2, parts[0] >= 16, parts[1] >= 16, parts[0] <= 4096, parts[1] <= 4096 else { fail("--size must be like 1200x1200") }
    return CGSize(width: parts[0], height: parts[1])
}

func cameras(_ s: String?) -> [LabRender.CameraPreset] {
    guard let s else { return [.hero] }
    if s == "all" { return LabRender.CameraPreset.allCases }
    return s.split(separator: ",").map { name in
        guard let c = LabRender.CameraPreset(rawValue: String(name)) else {
            fail("unknown camera \(name); use \(LabRender.CameraPreset.allCases.map(\.rawValue).joined(separator: ", ")) or all")
        }
        return c
    }
}

@MainActor
func render(_ meshes: [Mesh], to out: String, cameraNames: String?, size: CGSize, color: UInt32, crease: Double) throws {
    let list = cameras(cameraNames)
    for c in list {
        var path = out
        if list.count > 1 {
            let u = url(out)
            path = u.deletingPathExtension().path + "-\(c.rawValue)." + (u.pathExtension.isEmpty ? "png" : u.pathExtension)
        }
        try LabRender.png(meshes, camera: c, size: size, color: color, crease: crease).write(to: url(path), options: .atomic)
        print("wrote \(path)")
    }
}

func writeExport(_ bodies: [EvaluatedBody], document: Document, to out: String, quality: TextureQuality) throws {
    let meshes = try bodies.printMeshes(quality: quality)
    let u = url(out)
    switch u.pathExtension.lowercased() {
    case "3mf":
        let title = document.name ?? u.deletingPathExtension().lastPathComponent
        try ThreeMFWriter.write(objects: zip(bodies, meshes).map { (name: $0.name, mesh: $1) }, preset: document.printerPreset, title: title)
            .write(to: u, options: .atomic)
    case "stl": try STLWriter.binary(meshes: meshes).write(to: u, options: .atomic)
    default: fail("export writes .3mf or .stl")
    }
    let triangles = meshes.reduce(0) { $0 + $1.triangleCount }
    print("wrote \(out) (\(bodies.count) \(bodies.count == 1 ? "body" : "bodies"), \(triangles) triangles)")
}

guard let command = arguments.first else { print(usage); exit(0) }
arguments.removeFirst()

do {
    switch command {
    case "help", "-h", "--help":
        print(usage)

    case "patterns":
        for p in TextureCatalog.patterns {
            print("\(p.id.rawValue) — \(p.displayName): \(p.summary)")
            for q in TextureCatalog.parameters(for: p.id) {
                let unit = q.unit.isEmpty ? "" : " \(q.unit)"
                print("  \(q.id) = \(q.defaultValue)\(unit)  [\(q.range.lowerBound)…\(q.range.upperBound)]  \(q.name): \(q.help)")
            }
        }

    case "render":
        let out = option("-o") ?? option("--output")
        let cam = option("--camera"), sz = size(option("--size"))
        let color = option("--color").map { UInt32($0.replacingOccurrences(of: "#", with: ""), radix: 16) ?? LabRender.defaultColor }
            ?? LabRender.defaultColor
        let crease = number("--crease") ?? 60
        guard let input = arguments.first, let out else { fail("render needs an input file and -o out.png") }
        let meshes = try await MeshIO.load(url(input)).map(\.mesh)
        try render(meshes, to: out, cameraNames: cam, size: sz, color: color, crease: crease)

    case "export":
        let out = option("-o") ?? option("--output")
        let display = flag("--display"), viewport = flag("--viewport")
        guard let input = arguments.first, let out else { fail("export needs a .fillet file and -o out.3mf") }
        let (doc, model) = try await MeshIO.design(url(input), displayMeshes: viewport)
        if viewport {
            // Exactly the meshes the app's viewport shows (display tessellation, display texture
            // quality, crease shading), for checking what users see.
            let meshes = model.bodies.compactMap { model.meshes[$0.ref] }
            try STLWriter.binary(meshes: meshes).write(to: url(out), options: .atomic)
            print("wrote \(out) (viewport meshes, \(meshes.reduce(0) { $0 + $1.triangleCount }) triangles)")
            exit(0)
        }
        var quality: TextureQuality = display ? .display : .export
        if let e = number("--edge-scale") { quality.edgeScale = e }
        if let t = number("--max-triangles") { quality.maxTriangles = Int(t) }
        try writeExport(model.bodies, document: doc, to: out, quality: quality)

    case "check":
        let intersections = !flag("--no-intersections")
        guard let input = arguments.first else { fail("check needs a file") }
        let loaded = try await MeshIO.load(url(input))
        var ok = true
        for (i, m) in loaded.enumerated() {
            let result = MeshCheck.check(m.mesh, selfIntersections: intersections)
            ok = ok && result.passes
            print((loaded.count > 1 ? "[\(i + 1)/\(loaded.count) \(m.name)] " : "") + result.description)
        }
        exit(ok ? 0 : 1)

    case "sample":
        var o = TextureSamples.Options()
        if let b = option("--base") {
            guard let base = TextureSamples.Base(rawValue: b) else { fail("--base must be cylinder, vase or box") }
            o.base = base
        }
        o.diameter = number("--diameter") ?? o.diameter
        o.height = number("--height") ?? o.height
        o.topDiameter = number("--top-diameter")
        o.bulge = number("--bulge") ?? o.bulge
        o.shell = number("--shell")
        if let f = option("--faces") {
            guard let faces = TextureSamples.Faces(rawValue: f) else { fail("--faces must be sides or all") }
            o.faces = faces
        }
        let pattern = option("--pattern") ?? "knit"
        o.pattern = TexturePatternID(pattern == "none" ? "" : pattern)
        if !o.pattern.rawValue.isEmpty, TextureCatalog.pattern(o.pattern) == nil {
            fail("unknown pattern \(pattern); texture-lab patterns lists them")
        }
        for v in options("--value") {
            let parts = v.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("--value must be id=expression") }
            guard TextureCatalog.parameters(for: o.pattern).contains(where: { $0.id == parts[0] }) else {
                fail("\(pattern) has no parameter \(parts[0]); it takes \(TextureCatalog.parameters(for: o.pattern).map(\.id).joined(separator: ", "))")
            }
            o.values[parts[0]] = Expr(parts[1])
        }
        let out = option("-o") ?? option("--output") ?? "sample.fillet"
        let threeMF = option("--3mf"), png = option("--png"), cam = option("--camera")
        let doc = try await TextureSamples.document(o)
        try doc.encoded().write(to: url(out), options: .atomic)
        print("wrote \(out)")
        let model = await ModelEvaluator(displayMeshes: false).evaluate(doc)
        for f in doc.features { if let e = model.error(for: f.id) { FileHandle.standardError.write(Data("warning: \(f.name): \(e)\n".utf8)) } }
        if let threeMF { try writeExport(model.bodies, document: doc, to: threeMF, quality: .export) }
        if let png {
            try render(try model.bodies.printMeshes(), to: png, cameraNames: cam, size: CGSize(width: 1200, height: 1200),
                       color: LabRender.defaultColor, crease: 60)
        }

    case "bench":
        let runs = Int(number("--runs") ?? 5)
        guard runs >= 1 else { fail("--runs must be at least 1") }
        let names = options("--fixture")
        let modes: [TextureBench.Mode]
        if let m = option("--mode") {
            guard let mode = TextureBench.Mode(rawValue: m) else { fail("--mode must be display or export") }
            modes = [mode]
        } else {
            modes = TextureBench.Mode.allCases
        }
        let stages = flag("--stages")
        let loop = number("--loop")
        let dir = option("--dir").map(url) ?? TextureBench.defaultDirectory()
        if let extra = arguments.first { fail("bench: unexpected argument \(extra)") }
        try await TextureBench.main(directory: dir, names: names, modes: modes, runs: runs, stages: stages, loop: loop)

    default:
        fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
