import FilletCore
import FilletKernel
import Foundation

/// `texture-lab bench`: times the texture step as the app runs it, on fixed designs
/// (`Benchmarks/textures/*.fillet`), and prints bit-exact digests of what it makes.
///
/// - **display**: what the viewport recomputes on every texture edit. The fine base tessellation
///   is cached per shape in the app (``ModelEvaluator/texturedBaseDeflection(for:)``), so it is
///   made once outside the timing; timed is ``TextureEngine/apply(_:to:of:quality:)`` at
///   ``TextureQuality/display`` plus `creaseShaded()`.
/// - **export**: what a 3MF/STL export runs once: ``EvaluatedBody/printMesh(quality:)`` of every
///   body (tessellation plus textures at ``TextureQuality/export``).
///
/// The design itself is evaluated once, without display meshes, outside the timing. Bodies run
/// one after another (the app runs them concurrently; every fixture has one).
@MainActor
enum TextureBench {
    enum Mode: String, CaseIterable {
        case display, export
    }

    struct Fixture {
        var name: String
        var bodies: [EvaluatedBody]
        /// Base meshes of the textured bodies for the display mode, by index in `bodies`.
        var bases: [Int: Mesh]
    }

    struct Result {
        var fixture: String
        var mode: Mode
        var milliseconds: [Double]
        var triangles: Int
        var digest: String
        /// False when runs made different meshes.
        var stable: Bool
        /// Per stage, its time in every run (only with `--stages`).
        var stages: [(name: String, milliseconds: [Double])]
    }

    /// The fixture directory: `Benchmarks/textures` under the working directory, or else under the
    /// checkout this tool was built from.
    static func defaultDirectory() -> URL {
        let local = URL(fileURLWithPath: "Benchmarks/textures")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Benchmarks/textures")
    }

    /// Fixture files: every `.fillet` in `directory` by name, or the ones `names` picks (a name
    /// in the directory, or a path to any `.fillet`).
    static func fixtureFiles(in directory: URL, names: [String]) throws -> [URL] {
        if names.isEmpty {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "fillet" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if files.isEmpty { fail("no .fillet fixtures in \(directory.path)") }
            return files
        }
        return names.map { name in
            if name.hasSuffix(".fillet") { return url(name) }
            let u = directory.appendingPathComponent(name + ".fillet")
            guard FileManager.default.fileExists(atPath: u.path) else {
                let known = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                fail("no fixture \(name) in \(directory.path) (have: \(known.filter { $0.hasSuffix(".fillet") }.map { String($0.dropLast(7)) }.sorted().joined(separator: ", ")))")
            }
            return u
        }
    }

    static func load(_ file: URL) async throws -> Fixture {
        let doc = try Document(data: Data(contentsOf: file))
        let model = await ModelEvaluator(displayMeshes: false).evaluate(doc)
        for f in doc.activeFeatures {
            if case .failed(let m) = model.status[f.id] { fail("\(file.lastPathComponent): step “\(f.name)” failed: \(m)") }
        }
        var bases: [Int: Mesh] = [:]
        for (i, body) in model.bodies.enumerated() where !body.textures.isEmpty {
            let d = ModelEvaluator.texturedBaseDeflection(for: body.shape)
            bases[i] = try body.shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular)
        }
        if bases.isEmpty { fail("\(file.lastPathComponent) has no textured body") }
        return Fixture(name: file.deletingPathExtension().lastPathComponent, bodies: model.bodies, bases: bases)
    }

    /// One run of `mode` on `fixture`: the meshes it makes.
    static func run(_ fixture: Fixture, _ mode: Mode) throws -> [Mesh] {
        switch mode {
        case .display:
            return fixture.bases.keys.sorted().map { i in
                let body = fixture.bodies[i]
                let mesh = TextureEngine.apply(body.textures, to: fixture.bases[i]!, of: body.shape, quality: .display)
                    .creaseShaded()
                TextureStageTimes.current?.mark("crease shading")
                return mesh
            }
        case .export:
            return try fixture.bodies.map { try $0.printMesh(quality: .export) }
        }
    }

    /// Bit-exact FNV-1a digest of meshes: positions, normals, indices and triangle faces, in order.
    static func digest(_ meshes: [Mesh]) -> String {
        var h = FNV1a()
        for m in meshes {
            h.add([m.positions.count, m.indices.count])
            h.add(m.positions); h.add(m.normals); h.add(m.indices); h.add(m.triangleFaces)
        }
        return h.hex
    }

    /// Times `runs` runs of `mode` on `fixture`.
    static func measure(_ fixture: Fixture, _ mode: Mode, runs: Int, stages: Bool) throws -> Result {
        var times: [Double] = [], digests: [String] = [], triangles = 0
        var stageTimes: [(name: String, milliseconds: [Double])] = []
        for r in 0..<runs {
            let recorder = stages ? TextureStageTimes() : nil
            let start = ContinuousClock.now
            let meshes: [Mesh]
            if let recorder {
                recorder.restart()
                meshes = try TextureStageTimes.$current.withValue(recorder) { try run(fixture, mode) }
            } else {
                meshes = try run(fixture, mode)
            }
            let ms = milliseconds(since: start)
            times.append(ms)
            triangles = meshes.reduce(0) { $0 + $1.triangleCount }
            digests.append(digest(meshes))
            if let recorder {
                for s in recorder.stages {
                    if let i = stageTimes.firstIndex(where: { $0.name == s.name }) {
                        stageTimes[i].milliseconds.append(s.seconds * 1000)
                    } else {
                        stageTimes.append((s.name, [Double](repeating: 0, count: r) + [s.seconds * 1000]))
                    }
                }
                for i in stageTimes.indices where stageTimes[i].milliseconds.count < r + 1 { stageTimes[i].milliseconds.append(0) }
            }
            log("  \(fixture.name) \(mode.rawValue) run \(r + 1)/\(runs): \(String(format: "%.1f", ms)) ms, \(triangles) triangles, \(digests.last!)")
        }
        return Result(fixture: fixture.name, mode: mode, milliseconds: times, triangles: triangles, digest: digests[0],
                      stable: Set(digests).count == 1, stages: stageTimes)
    }

    static func main(directory: URL, names: [String], modes: [Mode], runs: Int, stages: Bool, loop: Double?) async throws {
        let files = try fixtureFiles(in: directory, names: names)
        if let loop {
            guard files.count == 1, modes.count == 1 else { fail("--loop needs one --fixture and one --mode") }
            let fixture = try await load(files[0])
            log("pid \(ProcessInfo.processInfo.processIdentifier): looping \(fixture.name) \(modes[0].rawValue) for \(Int(loop)) s")
            let deadline = ContinuousClock.now + .milliseconds(Int(loop * 1000))
            var times: [Double] = [], last = ""
            repeat {
                let start = ContinuousClock.now
                last = digest(try run(fixture, modes[0]))
                times.append(milliseconds(since: start))
            } while ContinuousClock.now < deadline
            print("\(fixture.name) \(modes[0].rawValue): \(times.count) runs, median \(String(format: "%.1f", median(times))) ms, digest \(last)")
            return
        }

        print("# Texture benchmark")
        print("")
        print("\(machine()), \(runs) runs per fixture and mode (median), release build")
        print("")
        var results: [Result] = []
        for file in files {
            log("loading \(file.lastPathComponent)")
            let fixture = try await load(file)
            for mode in modes { results.append(try measure(fixture, mode, runs: runs, stages: stages)) }
        }
        print("| fixture | mode | median ms | min ms | max ms | triangles | digest |")
        print("|---|---|---:|---:|---:|---:|---|")
        for r in results {
            print("| \(r.fixture) | \(r.mode.rawValue) | \(f1(median(r.milliseconds))) | \(f1(r.milliseconds.min()!)) | "
                + "\(f1(r.milliseconds.max()!)) | \(r.triangles) | `\(r.digest)`\(r.stable ? "" : " **UNSTABLE**") |")
        }
        let unstable = results.filter { !$0.stable }
        if !unstable.isEmpty {
            print("")
            print("**Runs made different meshes:** \(unstable.map { "\($0.fixture) \($0.mode.rawValue)" }.joined(separator: ", "))")
        }
        guard stages else { return }
        for r in results {
            print("")
            print("## \(r.fixture) \(r.mode.rawValue): stages (median ms of \(runs))")
            print("")
            print("| stage | ms | share |")
            print("|---|---:|---:|")
            let total = median(r.milliseconds)
            var sum = 0.0
            for s in r.stages {
                let m = median(s.milliseconds)
                sum += m
                print("| \(s.name) | \(f1(m)) | \(String(format: "%.1f%%", m / total * 100)) |")
            }
            print("| *(outside the stages)* | \(f1(max(total - sum, 0))) | \(String(format: "%.1f%%", max(total - sum, 0) / total * 100)) |")
        }
        if !unstable.isEmpty { exit(1) }
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15
    }

    static func f1(_ v: Double) -> String { String(format: "%.1f", v) }

    static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// The CPU and OS, for the report.
    static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let cpu = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(cpu) (\(ProcessInfo.processInfo.activeProcessorCount) cores), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

/// 64-bit FNV-1a, stable across runs (unlike `Hasher`).
struct FNV1a {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add<C: Collection>(bytes: C) where C.Element == UInt8 {
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    }
    /// The raw bytes of every element (bit-exact for floats).
    mutating func add<T>(_ values: [T]) { values.withUnsafeBytes { add(bytes: $0) } }
    var hex: String { String(format: "%016llx", h) }
}
