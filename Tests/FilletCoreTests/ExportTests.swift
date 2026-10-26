import FilletKernel
import Foundation
import Testing

@testable import FilletCore

@Suite("Export")
struct ExportTests {
    @Test func crc32() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func binarySTL() throws {
        let cube = TestMeshes.cube(size: 10)
        let pyramid = TestMeshes.invertedPyramid(a: 5, h: 5)
        let data = STLWriter.binary(meshes: [cube, pyramid])
        let n = 12 + 6
        #expect(data.count == 84 + 50 * n)
        let count = data[80..<84].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: count) == UInt32(n))
        // First triangle is the cube bottom: normal -Z.
        let normal = data[84..<96].withUnsafeBytes { buf in
            (0..<3).map { Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        #expect(normal == [0, 0, -1])
        #expect(!String(decoding: data.prefix(5), as: UTF8.self).hasPrefix("solid"))
    }

    @Test func threeMFModelXML() throws {
        let soup = TestMeshes.soup(TestMeshes.cube(SIMD3(-5, -5, 5), size: 10))
        let other = TestMeshes.cube(SIMD3(10, 0, 5), size: 4)
        let xml = ThreeMFWriter.modelXML(
            objects: [(name: "Body <1>", mesh: soup), (name: "Pin", mesh: other)], preset: .bambuA1Mini, title: "Hook & Clip")
        let model = try ModelXML.parse(Data(xml.utf8))
        #expect(model.unit == "millimeter")
        #expect(model.metadata["Title"] == "Hook & Clip")
        #expect(model.metadata["Application"] == "Fillet")
        #expect(model.objects.count == 3)
        #expect(model.objects[0].name == "Body <1>")
        #expect(model.objects[0].type == "model")
        #expect(model.objects[0].vertexCount == 8)  // welded from 36
        #expect(model.objects[0].triangleCount == 12)
        // The bodies are parts of one build object, so slicers load a single multi-part object.
        #expect(model.objects[2].name == "Hook & Clip")
        #expect(model.objects[2].components == ["1", "2"])
        #expect(model.objects[2].triangleCount == 0)
        #expect(model.items.map(\.objectID) == ["3"])
        // Combined bounds x -5…14, y -5…5, z 5…15 → centred on the 180×180 bed, resting on z = 0.
        let t = try #require(model.items.first?.transform.split(separator: " ").compactMap { Double($0) })
        #expect(t.count == 12)
        #expect(Array(t[0..<9]) == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        #expect(abs(t[9] - (90 - 4.5)) < 1e-4)
        #expect(abs(t[10] - 90) < 1e-4)
        #expect(abs(t[11] + 5) < 1e-6)
    }

    @Test func threeMFWithoutPresetOnlyDropsToBed() throws {
        let xml = ThreeMFWriter.modelXML(
            objects: [(name: "A", mesh: TestMeshes.cube(SIMD3(3, 4, -2), size: 1))], preset: nil, title: nil)
        let model = try ModelXML.parse(Data(xml.utf8))
        #expect(model.objects.count == 1)  // a single body needs no assembly
        #expect(model.items.map(\.objectID) == ["1"])
        #expect(model.items.first?.transform == "1 0 0 0 1 0 0 0 1 0 0 2")
    }

    @Test func emptyMeshesAreSkipped() throws {
        let xml = ThreeMFWriter.modelXML(objects: [(name: "Empty", mesh: .empty)], preset: nil, title: nil)
        let model = try ModelXML.parse(Data(xml.utf8))
        #expect(model.objects.isEmpty && model.items.isEmpty)
    }

    #if os(macOS)
        @Test func zipArchiveIsValid() throws {
            var zip = ZipWriter()
            let text = Data(String(repeating: "Fillet makes parts. ", count: 500).utf8)
            try zip.add(path: "a/deflated.txt", data: text, method: .deflate)
            try zip.add(path: "stored.bin", data: Data([0, 1, 2, 3]), method: .stored)
            try zip.add(path: "empty.txt", data: Data(), method: .deflate)
            let archive = try zip.finish()
            #expect(archive.count < text.count)  // deflate actually compressed
            let url = try Unzip.write(archive, name: "test.zip")
            #expect(try Unzip.run(["-t", url.path]).status == 0)
            #expect(try Unzip.run(["-p", url.path, "a/deflated.txt"]).output == text)
            #expect(try Unzip.run(["-p", url.path, "stored.bin"]).output == Data([0, 1, 2, 3]))
        }

        @Test func threeMFPackageUnzipsAndParses() throws {
            let objects = [
                (name: "Holder", mesh: TestMeshes.soup(TestMeshes.cube(size: 20))),
                (name: "Clip", mesh: TestMeshes.invertedPyramid(a: 5, h: 5)),
            ]
            let data = try ThreeMFWriter.write(objects: objects, preset: .bambuA1, title: "Toothpaste holder")
            let url = try Unzip.write(data, name: "part.3mf")
            #expect(try Unzip.run(["-t", url.path]).status == 0)
            let listing = String(decoding: try Unzip.run(["-l", url.path]).output, as: UTF8.self)
            for entry in ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"] {
                #expect(listing.contains(entry))
            }
            let model = try ModelXML.parse(try Unzip.run(["-p", url.path, "3D/3dmodel.model"]).output)
            #expect(model.objects.map(\.name) == ["Holder", "Clip", "Toothpaste holder"])
            #expect(model.objects.map(\.vertexCount) == [8, 5, 0])
            #expect(model.objects.map(\.triangleCount) == [12, 6, 0])
            #expect(model.metadata["Title"] == "Toothpaste holder")
            let rels = String(decoding: try Unzip.run(["-p", url.path, "_rels/.rels"]).output, as: UTF8.self)
            #expect(rels.contains("Target=\"/3D/3dmodel.model\""))
        }
    #endif
}

#if os(macOS)
    enum Unzip {
        static func write(_ data: Data, name: String) throws -> URL {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FilletCoreTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        static func run(_ arguments: [String]) throws -> (status: Int32, output: Data) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = arguments
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try p.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, output)
        }
    }
#endif

/// Tiny 3MF model parser for assertions.
final class ModelXML: NSObject, XMLParserDelegate {
    struct Object {
        var name = "", type = "", vertexCount = 0, triangleCount = 0
        var components: [String] = []
    }
    struct Item { var objectID = "", transform = "" }

    var unit = ""
    var metadata: [String: String] = [:]
    var objects: [Object] = []
    var items: [Item] = []
    private var currentMetadata: String?
    private var text = ""

    static func parse(_ data: Data) throws -> ModelXML {
        let model = ModelXML()
        let parser = XMLParser(data: data)
        parser.delegate = model
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return model
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes a: [String: String] = [:]
    ) {
        switch name {
        case "model": unit = a["unit"] ?? ""
        case "metadata": currentMetadata = a["name"]; text = ""
        case "object": objects.append(Object(name: a["name"] ?? "", type: a["type"] ?? ""))
        case "vertex": objects[objects.count - 1].vertexCount += 1
        case "triangle": objects[objects.count - 1].triangleCount += 1
        case "component": objects[objects.count - 1].components.append(a["objectid"] ?? "")
        case "item": items.append(Item(objectID: a["objectid"] ?? "", transform: a["transform"] ?? ""))
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "metadata", let key = currentMetadata { metadata[key] = text }
        currentMetadata = nil
    }
}
