import FilletAgent
import FilletCore
import FilletKernel
import Foundation
import simd

/// A named triangle mesh loaded from a file, in millimetres.
struct LoadedMesh {
    var name: String
    var mesh: Mesh
}

enum MeshIOError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): m }
    }
}

enum MeshIO {
    /// Meshes in an STL, 3MF or .fillet file (a .fillet is recomputed and exported like the app
    /// does: textures applied at export quality).
    static func load(_ url: URL, quality: TextureQuality = .export) async throws -> [LoadedMesh] {
        switch url.pathExtension.lowercased() {
        case "stl": return [LoadedMesh(name: url.deletingPathExtension().lastPathComponent, mesh: try stl(Data(contentsOf: url)))]
        case "3mf": return try threeMF(url)
        case "fillet":
            let (_, model) = try await design(url, displayMeshes: false)
            let bodies = model.bodies
            let meshes = try bodies.printMeshes(quality: quality)
            return zip(bodies, meshes).map { LoadedMesh(name: $0.name, mesh: $1) }
        default: throw MeshIOError.message("Unsupported file type .\(url.pathExtension) (use .stl, .3mf or .fillet)")
        }
    }

    /// The design in `url`, recomputed. Without `displayMeshes` the model has no viewport meshes
    /// (so an export doesn't texture every body twice, once at display detail).
    static func design(_ url: URL, displayMeshes: Bool = true) async throws -> (Document, EvaluatedModel) {
        let doc = try Document(data: Data(contentsOf: url))
        let model = await ModelEvaluator(displayMeshes: displayMeshes).evaluate(doc)
        for f in doc.activeFeatures {
            if case .failed(let m) = model.status[f.id] { FileHandle.standardError.write(Data("warning: step “\(f.name)” failed: \(m)\n".utf8)) }
        }
        return (doc, model)
    }

    // MARK: STL

    static func stl(_ data: Data) throws -> Mesh {
        if data.count >= 84 {
            let n = Int(data[80..<84].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            if data.count == 84 + 50 * n { return binarySTL(data, count: n) }
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
            text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("solid")
        else { throw MeshIOError.message("Not a valid STL file") }
        var positions: [SIMD3<Float>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 4, parts[0] == "vertex", let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else { continue }
            positions.append(SIMD3(x, y, z))
        }
        positions.removeLast(positions.count % 3)
        return soup(positions)
    }

    private static func binarySTL(_ data: Data, count: Int) -> Mesh {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(count * 3)
        data.withUnsafeBytes { buf in
            for t in 0..<count {
                let base = 84 + 50 * t + 12
                for k in 0..<3 {
                    let o = base + 12 * k
                    let x = Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
                    let y = Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self)))
                    let z = Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self)))
                    positions.append(SIMD3(x, y, z))
                }
            }
        }
        return soup(positions)
    }

    /// Unindexed triangles as a mesh (one face, flat normals; renders re-derive normals anyway).
    static func soup(_ positions: [SIMD3<Float>]) -> Mesh {
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(positions.count)
        for t in stride(from: 0, to: positions.count, by: 3) {
            let n = simd_cross(positions[t + 1] - positions[t], positions[t + 2] - positions[t])
            let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)
            normals += [u, u, u]
        }
        return Mesh(positions: positions, normals: normals, indices: (0..<UInt32(positions.count)).map { $0 },
                    triangleFaces: [Int32](repeating: 0, count: positions.count / 3), edges: [])
    }

    // MARK: 3MF

    /// Every build item of a 3MF, its components flattened with their transforms (3MF core and
    /// the production extension's multi-file models, as Bambu Studio writes them).
    static func threeMF(_ url: URL) throws -> [LoadedMesh] {
        let entries = try unzipList(url).filter { $0.lowercased().hasSuffix(".model") }
        var objects: [String: ModelParser.Object] = [:]  // "path#id"
        var rootItems: [ModelParser.Item] = []
        for entry in entries {
            let parser = ModelParser(path: "/" + entry)
            let xml = XMLParser(data: try unzip(url, entry))
            xml.delegate = parser
            guard xml.parse() else { throw MeshIOError.message("Couldn't read \(entry) in \(url.lastPathComponent)") }
            for o in parser.objects { objects["\(parser.path)#\(o.id)"] = o }
            if entry.lowercased() == "3d/3dmodel.model" { rootItems = parser.items }
        }
        var result: [LoadedMesh] = []
        func flatten(_ key: String, _ transform: simd_double4x4, into positions: inout [SIMD3<Float>], depth: Int = 0) {
            guard depth < 16, let o = objects[key] else { return }
            for t in o.triangles {
                for v in [t.0, t.1, t.2] where v < o.vertices.count {
                    let p = transform * SIMD4(o.vertices[v], 1)
                    positions.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)))
                }
            }
            for c in o.components {
                let path = c.path ?? String(key.split(separator: "#")[0])
                flatten("\(path)#\(c.objectID)", transform * c.transform, into: &positions, depth: depth + 1)
            }
        }
        for item in rootItems {
            var positions: [SIMD3<Float>] = []
            let path = item.path ?? "/3D/3dmodel.model"
            flatten("\(path)#\(item.objectID)", item.transform, into: &positions)
            guard !positions.isEmpty else { continue }
            let name = objects["\(path)#\(item.objectID)"]?.name ?? "Object \(result.count + 1)"
            result.append(LoadedMesh(name: name, mesh: soup(positions)))
        }
        if result.isEmpty { throw MeshIOError.message("No meshes in \(url.lastPathComponent)") }
        return result
    }

    static func unzipList(_ url: URL) throws -> [String] {
        let out = try run("/usr/bin/zipinfo", ["-1", url.path])
        return String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    static func unzip(_ url: URL, _ entry: String) throws -> Data { try run("/usr/bin/unzip", ["-p", url.path, entry]) }

    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw MeshIOError.message("\(tool) failed on \(arguments.last ?? "")") }
        return data
    }
}

/// Reads the objects, components and build items of one 3MF model part.
final class ModelParser: NSObject, XMLParserDelegate {
    struct Component { var objectID: String; var path: String?; var transform: simd_double4x4 }
    struct Object {
        var id: String
        var name: String
        var vertices: [SIMD3<Double>] = []
        var triangles: [(Int, Int, Int)] = []
        var components: [Component] = []
    }
    struct Item { var objectID: String; var path: String?; var transform: simd_double4x4 }

    let path: String
    var objects: [Object] = []
    var items: [Item] = []
    private var current: Object?

    init(path: String) { self.path = path }

    static func transform(_ s: String?) -> simd_double4x4 {
        guard let s else { return matrix_identity_double4x4 }
        let v = s.split(separator: " ").compactMap { Double($0) }
        guard v.count == 12 else { return matrix_identity_double4x4 }
        // 3MF: row vectors, m00 m01 m02 m10 … m32 (last row = translation).
        return simd_double4x4(columns: (SIMD4(v[0], v[1], v[2], 0), SIMD4(v[3], v[4], v[5], 0),
                                        SIMD4(v[6], v[7], v[8], 0), SIMD4(v[9], v[10], v[11], 1)))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        func pathAttribute() -> String? { a.first { $0.key.hasSuffix(":path") || $0.key == "path" }?.value }
        switch local {
        case "object": current = Object(id: a["id"] ?? "", name: a["name"] ?? "")
        case "vertex":
            current?.vertices.append(SIMD3(Double(a["x"] ?? "") ?? 0, Double(a["y"] ?? "") ?? 0, Double(a["z"] ?? "") ?? 0))
        case "triangle":
            if let v1 = Int(a["v1"] ?? ""), let v2 = Int(a["v2"] ?? ""), let v3 = Int(a["v3"] ?? "") { current?.triangles.append((v1, v2, v3)) }
        case "component":
            current?.components.append(Component(objectID: a["objectid"] ?? "", path: pathAttribute(), transform: Self.transform(a["transform"])))
        case "item":
            items.append(Item(objectID: a["objectid"] ?? "", path: pathAttribute(), transform: Self.transform(a["transform"])))
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "object", let o = current {
            objects.append(o)
            current = nil
        }
    }
}
