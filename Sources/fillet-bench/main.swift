import FilletCore
import FilletKernel
import Foundation

// `fillet-bench`: recompute benchmark for one design (default: Benchmarks/frog-wizard.fillet).
//
//     swift run -c release fillet-bench [design.fillet] [--runs N] [--query-runs M] [--top K]
//                                       [--no-cascade] [--booleans]
//
// Measures cold evaluation (per step), a warm no-op re-evaluate, an early-edit cascade,
// display tessellation, and the face/edge queries agent tools make; then prints a geometry
// fingerprint and bit-exact digests of the display meshes and face/edge infos, so an
// optimisation can show the result didn't change. See docs/performance.md.
// Output is Markdown on stdout; progress goes to stderr.

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String, default value: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return value }
    args.removeSubrange(i...(i + 1))
    return v
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
if args.contains("-h") || args.contains("--help") {
    print("""
        usage: fillet-bench [design.fillet] [options]
          --runs N        cold evaluates and early-edit cascades to take the median of (default 3)
          --query-runs M  repetitions of the tessellation and face/edge timings (default 10)
          --top K         slowest steps to list (default 15)
          --no-cascade    skip the early-edit cascade
          --booleans      also time the booleans of the 5 slowest combine steps on their own
        """)
    exit(0)
}
let runs = max(1, option("--runs", default: 3))
let queryRuns = max(1, option("--query-runs", default: 10))
let top = option("--top", default: 15)
let skipCascade = flag("--no-cascade")
let booleanDetail = flag("--booleans")
setvbuf(stdout, nil, _IOLBF, 0)
func progress(_ message: String) { FileHandle.standardError.write("… \(message)\n".data(using: .utf8)!) }
let defaultFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Benchmarks/frog-wizard.fillet")
let url = args.first.map { URL(fileURLWithPath: $0) } ?? defaultFixture

let document: Document
do {
    document = try Document(data: Data(contentsOf: url))
} catch {
    FileHandle.standardError.write("Can't read \(url.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Helpers

func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let result = try body()
    let d = ContinuousClock.now - start
    return (result, Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
}

func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let result = try await body()
    let d = ContinuousClock.now - start
    return (result, Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
}

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func ms(_ s: Double) -> String { String(format: "%.1f", s * 1000) }
func pct(_ part: Double, _ whole: Double) -> String { whole > 0 ? String(format: "%.1f%%", part / whole * 100) : "-" }
func f3(_ v: Double) -> String { String(format: "%.3f", v) }

/// 64-bit FNV-1a, stable across runs (unlike `Hasher`).
struct FNV1a {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add<C: Collection>(bytes: C) where C.Element == UInt8 {
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    }
    /// The raw bytes of every element (bit-exact for floats).
    mutating func add<T>(_ values: [T]) { values.withUnsafeBytes { add(bytes: $0) } }
    mutating func add(_ v: Vec3) { add([v.x, v.y, v.z]) }
    var hex: String { String(format: "%016llx", h) }
}
func fnv1a(_ s: String) -> String {
    var h = FNV1a()
    h.add(bytes: s.utf8)
    return h.hex
}

/// Integration precision of the fingerprint's volume and area (see docs/performance.md, Round 2).
let fingerprintPrecision = 1e-9

let active = document.activeFeatures
let featureByID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })

@MainActor func fingerprint(_ model: EvaluatedModel) -> [String] {
    var lines: [String] = []
    for body in model.bodies {
        let s = body.shape
        let b = s.bounds
        let mass = s.massProperties(precision: fingerprintPrecision)
        let lo = b.map { "\(f3($0.min.x)) \(f3($0.min.y)) \(f3($0.min.z))" } ?? "-"
        let hi = b.map { "\(f3($0.max.x)) \(f3($0.max.y)) \(f3($0.max.z))" } ?? "-"
        lines.append("\(body.name) [\(body.ref.feature.uuidString.prefix(8))] solids=\(s.solidCount) faces=\(s.faceCount) "
            + "edges=\(s.edgeCount) volume=\(mass.map { String(format: "%.3f", $0.volume) } ?? "-") "
            + "area=\(mass.map { String(format: "%.3f", $0.area) } ?? "-") "
            + "valid=\(s.isValid) bounds=(\(lo))..(\(hi))")
    }
    let failed = active.filter { if case .failed = model.status[$0.id] { true } else { false } }
    lines.append("failed steps: " + (failed.isEmpty ? "none" : failed.map(\.name).joined(separator: ", ")))
    return lines
}

func fingerprintCore(_ model: EvaluatedModel) -> [String] {
    // Without validity (BRepCheck is slow) — used to check every cold run produced the same result.
    model.bodies.map { "\($0.ref) \($0.shape.faceCount) \($0.shape.edgeCount) \(String(format: "%.2f", $0.shape.volume))" }
}

print("# fillet-bench")
print("")
print("design: \(url.lastPathComponent) — \(document.features.count) steps, \(active.count) active; runs: \(runs)")
var typeCounts: [String: Int] = [:]
for f in active { typeCounts[f.kind.typeName, default: 0] += 1 }
print("step types: " + typeCounts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
print("")

// MARK: - Cold full evaluate

var coldTotals: [Double] = []
var coldSteps: [Double] = []
var coldMeshes: [Double] = []
var stepSamples: [Int: [Double]] = [:]
var finalModel: EvaluatedModel!
var warm: ModelEvaluator!
var referenceCore: [String]?
for run in 0..<runs {
    progress("cold evaluate \(run + 1)/\(runs)")
    let ev = ModelEvaluator(recordsTimings: true)
    let (model, total) = await time { await ev.evaluate(document) }
    let steps = await ev.lastStepTimings
    let mesh = await ev.lastMeshSeconds
    coldTotals.append(total)
    coldSteps.append(steps.reduce(0) { $0 + $1.seconds })
    coldMeshes.append(mesh)
    for s in steps { stepSamples[s.index, default: []].append(s.seconds) }
    let core = fingerprintCore(model)
    if let referenceCore, referenceCore != core { print("WARNING: cold runs produced different geometry") }
    referenceCore = core
    finalModel = model
    warm = ev
}
let coldTotal = median(coldTotals)
let coldModelling = median(coldSteps)
let coldMesh = median(coldMeshes)

print("## Cold full evaluate (fresh ModelEvaluator, median of \(runs))")
print("")
print("| | ms | share |")
print("|---|---:|---:|")
print("| total `evaluate` | \(ms(coldTotal)) | 100% |")
print("| modelling (sum of steps) | \(ms(coldModelling)) | \(pct(coldModelling, coldTotal)) |")
print("| display tessellation | \(ms(coldMesh)) | \(pct(coldMesh, coldTotal)) |")
print("| evaluator overhead (hashing, cache, rest) | \(ms(coldTotal - coldModelling - coldMesh)) | \(pct(coldTotal - coldModelling - coldMesh, coldTotal)) |")
print("")
print("runs (total ms): " + coldTotals.map(ms).joined(separator: ", "))
print("")

// MARK: - Per step

let perStep = stepSamples.map { (index: $0.key, seconds: median($0.value)) }
let byType = Dictionary(grouping: perStep) { active[$0.index].kind.typeName }
    .map { (type: $0.key, count: $0.value.count, total: $0.value.reduce(0) { $0 + $1.seconds }, max: $0.value.map(\.seconds).max() ?? 0) }
    .sorted { $0.total > $1.total }

print("## Cost by step type")
print("")
print("| type | steps | total ms | share | mean ms | max ms |")
print("|---|---:|---:|---:|---:|---:|")
for t in byType {
    print("| \(t.type) | \(t.count) | \(ms(t.total)) | \(pct(t.total, coldModelling)) | \(ms(t.total / Double(t.count))) | \(ms(t.max)) |")
}
print("")

print("## Slowest \(top) steps")
print("")
print("| # | step | type | ms | share |")
print("|---:|---|---|---:|---:|")
for s in perStep.sorted(by: { $0.seconds > $1.seconds }).prefix(top) {
    let f = active[s.index]
    print("| \(s.index + 1) | \(f.name) | \(f.kind.typeName) | \(ms(s.seconds)) | \(pct(s.seconds, coldModelling)) |")
}
print("")
// Cumulative curve: how much of the cold evaluate the first n steps take.
let sortedDesc = perStep.map(\.seconds).sorted(by: >)
let top5 = sortedDesc.prefix(5).reduce(0, +), top10 = sortedDesc.prefix(10).reduce(0, +)
print("top 5 steps: \(pct(top5, coldModelling)) of modelling; top 10: \(pct(top10, coldModelling))")
print("")

// MARK: - Warm re-evaluate

var noop: [Double] = []
for _ in 0..<runs {
    let (_, t) = await time { await warm.evaluate(document) }
    noop.append(t)
}
print("## Warm re-evaluate, nothing changed (median of \(runs))")
print("")
print("\(ms(median(noop))) ms (all cache hits: per-step hashing + model assembly)")
print("")

// MARK: - Early-edit cascade

/// The first scale step, its Y factor ×1.01 (else the first primitive's first dimension ×1.01).
@MainActor func earlyEdit(_ doc: Document) -> (Document, String)? {
    var d = doc
    for (i, f) in d.features.enumerated() where !f.suppressed {
        switch f.kind {
        case .scale(var sc):
            sc.factors.y = Expr("(\(sc.factors.y.source)) * 1.01")
            d.features[i].kind = .scale(sc)
            return (d, "step \(i + 1) “\(f.name)” (scale): Y factor ×1.01")
        case .primitive(var p) where !p.dimensions.isEmpty:
            p.dimensions[0] = Expr("(\(p.dimensions[0].source)) * 1.01")
            d.features[i].kind = .primitive(p)
            return (d, "step \(i + 1) “\(f.name)” (primitive): first dimension ×1.01")
        default: continue
        }
    }
    return nil
}

if !skipCascade, let (edited, what) = earlyEdit(document) {
    var totals: [Double] = [], steps: [Double] = [], meshes: [Double] = [], recomputed: [Int] = []
    for run in 0..<runs {
        progress("early-edit cascade \(run + 1)/\(runs)")
        // Alternate edited/original so every timed evaluate is a real cascade from the edit.
        let (_, t) = await time { await warm.evaluate(edited) }
        let st = await warm.lastStepTimings
        totals.append(t)
        steps.append(st.reduce(0) { $0 + $1.seconds })
        meshes.append(await warm.lastMeshSeconds)
        recomputed.append(st.count)
        _ = await warm.evaluate(document)
    }
    print("## Early-edit cascade (warm evaluator, median of \(runs))")
    print("")
    print("edit: \(what); recomputes \(recomputed.first ?? 0) of \(active.count) steps")
    print("")
    print("| | ms |")
    print("|---|---:|")
    print("| total `evaluate` | \(ms(median(totals))) |")
    print("| modelling | \(ms(median(steps))) |")
    print("| display tessellation (changed bodies) | \(ms(median(meshes))) |")
    print("")
}

// MARK: - Tessellation

let bodies = finalModel.bodies
var tessTotals: [Double] = []
var tessPerBody: [Int: [Double]] = [:]
var triangles: [Int: Int] = [:]
progress("tessellation ×\(queryRuns)")
for _ in 0..<queryRuns {
    var total = 0.0
    for (i, body) in bodies.enumerated() {
        let d = ModelEvaluator.displayDeflection(for: body.shape)
        let (mesh, t) = time { try? body.shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular) }
        total += t
        tessPerBody[i, default: []].append(t)
        triangles[i] = mesh?.triangleCount ?? 0
    }
    tessTotals.append(total)
}

// MARK: - Face / edge queries

struct QueryTimes { var faces: [Double] = []; var edges: [Double] = []; var seams: [Double] = [] }
var queries: [Int: QueryTimes] = [:]
progress("face/edge queries ×\(queryRuns)")
for _ in 0..<queryRuns {
    for (i, body) in bodies.enumerated() {
        // A fresh handle, so the kernel's face/edge index maps are rebuilt like for a new result.
        guard let fresh = try? body.shape.copy() else { continue }
        let (_, tf) = time { fresh.faceInfos }
        let (_, te) = time { fresh.edgeInfos }
        let (_, ts) = time { (0..<fresh.edgeCount).filter { fresh.isSeamEdge($0) }.count }
        queries[i, default: QueryTimes()].faces.append(tf)
        queries[i, default: QueryTimes()].edges.append(te)
        queries[i, default: QueryTimes()].seams.append(ts)
    }
}

print("## Final bodies: tessellation and face/edge queries (median of \(queryRuns))")
print("")
print("| body | faces | edges | triangles | tessellate ms | faceInfos ms | edgeInfos ms | isSeamEdge (all) ms |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
var sumTess = 0.0, sumF = 0.0, sumE = 0.0, sumS = 0.0
for (i, body) in bodies.enumerated() {
    let q = queries[i] ?? QueryTimes()
    let t = median(tessPerBody[i] ?? []), f = median(q.faces), e = median(q.edges), s = median(q.seams)
    sumTess += t; sumF += f; sumE += e; sumS += s
    print("| \(body.name) | \(body.shape.faceCount) | \(body.shape.edgeCount) | \(triangles[i] ?? 0) | \(ms(t)) | \(ms(f)) | \(ms(e)) | \(ms(s)) |")
}
print("| **all** | | | \(triangles.values.reduce(0, +)) | \(ms(sumTess)) | \(ms(sumF)) | \(ms(sumE)) | \(ms(sumS)) |")
print("")

// MARK: - Report queries

// What agent tools report for every changed body on each request: first call on a fresh handle,
// then the same call again.
struct ReportTimes { var first: [Double] = []; var repeated: [Double] = [] }
let reportQueries: [(String, (Shape) -> Void)] = [
    ("volume", { _ = $0.volume }), ("surfaceArea", { _ = $0.surfaceArea }),
    ("bounds", { _ = $0.bounds }), ("isValid", { _ = $0.isValid }),
]
var reportAll = [ReportTimes](repeating: ReportTimes(), count: reportQueries.count)
var reportLargest = reportAll
let largestBody = bodies.indices.max { bodies[$0].shape.faceCount < bodies[$1].shape.faceCount }
progress("report queries ×\(queryRuns)")
for _ in 0..<queryRuns {
    var first = [Double](repeating: 0, count: reportQueries.count), again = first
    for (i, body) in bodies.enumerated() {
        guard let fresh = try? body.shape.copy() else { continue }
        for (q, query) in reportQueries.enumerated() {
            let (_, t1) = time { query.1(fresh) }
            let (_, t2) = time { query.1(fresh) }
            first[q] += t1; again[q] += t2
            if i == largestBody { reportLargest[q].first.append(t1); reportLargest[q].repeated.append(t2) }
        }
    }
    for q in reportQueries.indices { reportAll[q].first.append(first[q]); reportAll[q].repeated.append(again[q]) }
}
print("## Report queries: first / repeated call on a fresh handle (median of \(queryRuns))")
print("")
print("| query | all bodies ms | \(largestBody.map { bodies[$0].name } ?? "-") ms |")
print("|---|---:|---:|")
for (q, query) in reportQueries.enumerated() {
    let a = reportAll[q], l = reportLargest[q]
    print("| `\(query.0)` | \(ms(median(a.first))) / \(ms(median(a.repeated))) | \(ms(median(l.first))) / \(ms(median(l.repeated))) |")
}
print("")

// MARK: - Fillet reference resolution

// Each fillet step resolves its edge references against edgeInfos of the body before it.
var resolveTotal = 0.0, filletTotal = 0.0
var filletRows: [String] = []
for (i, f) in active.enumerated() {
    guard case .fillet(let ef) = f.kind else { continue }
    let model = await warm.evaluate(document, before: f.id)
    guard let body = model.bodiesBefore?.first(where: { $0.ref == ef.body }), let fresh = try? body.shape.copy() else { continue }
    let (_, t) = time { fresh.edgeInfos }
    let step = median(stepSamples[i] ?? [])
    resolveTotal += t
    filletTotal += step
    filletRows.append("| \(i + 1) | \(f.name) | \(ef.edges.count) | \(fresh.edgeCount) | \(ms(step)) | \(ms(t)) |")
}
if !filletRows.isEmpty {
    print("## Fillet steps: edge lookup vs whole step")
    print("")
    print("| # | step | edges filleted | body edges | step ms | edgeInfos of input ms |")
    print("|---:|---|---:|---:|---:|---:|")
    filletRows.forEach { print($0) }
    print("")
    print("edge lookup is \(pct(resolveTotal, filletTotal)) of fillet step time")
    print("")
}

// MARK: - Boolean breakdown

if booleanDetail {
    // Replays each boolean of the slowest combine steps on the bodies before the step: one
    // boolean per tool, in order, then (for several tools) all tools in one boolean, which is
    // what ModelEvaluator.combine does.
    let slowCombines = perStep.filter { if case .combine = active[$0.index].kind { true } else { false } }
        .sorted { $0.seconds > $1.seconds }.prefix(5)
    print("## Slowest combine steps: one boolean per tool, then all tools in one")
    print("")
    print("| # | step | op | tool | target faces | tool faces | ms |")
    print("|---:|---|---|---|---:|---:|---:|")
    for s in slowCombines {
        let f = active[s.index]
        guard case .combine(let c) = f.kind else { continue }
        progress("booleans of “\(f.name)”")
        let before = await warm.evaluate(document, before: f.id).bodiesBefore ?? []
        guard let targetShape = before.first(where: { $0.ref == c.target })?.shape else { continue }
        var shape = targetShape
        let op: BooleanOperation = c.operation == .cut ? .cut : c.operation == .intersect ? .common : .fuse
        for tool in c.tools where tool != c.target {
            guard let t = before.first(where: { $0.ref == tool }) else { continue }
            let toolName = featureByID[tool.feature]?.name ?? t.name
            let faces = shape.faceCount
            let (result, sec) = time { try? shape.boolean(op, t.shape) }
            print("| \(s.index + 1) | \(f.name) | \(c.operation) | \(toolName) | \(faces) | \(t.shape.faceCount) | \(ms(sec)) |")
            guard let result else { break }
            shape = result
        }
        let tools = c.tools.filter { $0 != c.target }.compactMap { ref in before.first { $0.ref == ref }?.shape }
        if tools.count > 1 {
            let (_, sec) = time { try? targetShape.boolean(op, tools) }
            let toolFaces = tools.reduce(0) { $0 + $1.faceCount }
            print("| \(s.index + 1) | \(f.name) | \(c.operation) | all \(tools.count) tools in one boolean | \(targetShape.faceCount) | \(toolFaces) | \(ms(sec)) |")
        }
    }
    print("")
}

// MARK: - Fingerprint

let lines = fingerprint(finalModel)
print("## Geometry fingerprint")
print("")
print("```")
lines.forEach { print($0) }
print("digest: \(fnv1a(lines.joined(separator: "\n")))")
print("```")
print("")

// Bit-exact digests of what the optimisations must not change: the evaluator's display meshes,
// and every final body's face and edge infos (which feed persistent reference signatures).
var meshHash = FNV1a(), infoHash = FNV1a()
var meshTriangles = 0
for body in finalModel.bodies {
    let m = finalModel.meshes[body.ref] ?? .empty
    meshTriangles += m.triangleCount
    meshHash.add(m.positions); meshHash.add(m.normals); meshHash.add(m.indices); meshHash.add(m.triangleFaces)
    for e in m.edges { meshHash.add([e.count]); meshHash.add(e) }
    guard let fresh = try? body.shape.copy() else { continue }
    for f in fresh.faceInfos {
        infoHash.add([f.surface.rawValue]); infoHash.add(f.centroid); infoHash.add(f.normal)
        infoHash.add([f.area]); infoHash.add(f.boundsMin); infoHash.add(f.boundsMax)
    }
    for e in fresh.edgeInfos {
        infoHash.add([e.curve.rawValue]); infoHash.add(e.start); infoHash.add(e.mid); infoHash.add(e.end)
        infoHash.add(e.tangentAtMid); infoHash.add([e.length, e.radius])
    }
}
print("display meshes: \(meshTriangles) triangles, digest \(meshHash.hex); face/edge infos digest \(infoHash.hex)")
