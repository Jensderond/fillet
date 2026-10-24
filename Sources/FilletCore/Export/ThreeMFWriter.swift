import FilletKernel
import Foundation
import simd

/// Writes a 3MF package (3MF Core Specification 1.3): one `<object>` per body
/// in millimetres, placed together so the set rests on the bed (min z = 0) and,
/// when a printer is given, is centred on its bed.
public enum ThreeMFWriter {
    static let modelPath = "3D/3dmodel.model"

    /// Builds the `.3mf` archive.
    /// - Parameters:
    ///   - objects: named meshes, one per body.
    ///   - preset: when given, the build items are centred on this printer's bed.
    ///   - title: written as the `Title` metadata.
    public static func write(objects: [(name: String, mesh: Mesh)], preset: PrinterPreset?, title: String? = nil) throws
        -> Data
    {
        var zip = ZipWriter()
        try zip.add(path: "[Content_Types].xml", data: Data(contentTypes.utf8))
        try zip.add(path: "_rels/.rels", data: Data(relationships.utf8))
        try zip.add(path: modelPath, data: Data(modelXML(objects: objects, preset: preset, title: title).utf8))
        return try zip.finish()
    }

    static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
        </Types>
        """

    static let relationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/\(modelPath)" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """

    /// The `3D/3dmodel.model` XML document.
    static func modelXML(objects: [(name: String, mesh: Mesh)], preset: PrinterPreset?, title: String?) -> String {
        let offset = placementOffset(objects.map(\.mesh), preset: preset)
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
             <metadata name="Title">\(escape(title ?? "Fillet design"))</metadata>
             <metadata name="Application">Fillet</metadata>
             <resources>

            """
        var ids: [Int] = []
        for (i, object) in objects.enumerated() {
            let id = i + 1
            let (vertices, triangles) = weld(object.mesh)
            guard !triangles.isEmpty else { continue }
            ids.append(id)
            xml += "  <object id=\"\(id)\" type=\"model\" name=\"\(escape(object.name))\">\n   <mesh>\n    <vertices>\n"
            for v in vertices {
                xml += "     <vertex x=\"\(number(v.x))\" y=\"\(number(v.y))\" z=\"\(number(v.z))\"/>\n"
            }
            xml += "    </vertices>\n    <triangles>\n"
            for t in triangles {
                xml += "     <triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>\n"
            }
            xml += "    </triangles>\n   </mesh>\n  </object>\n"
        }
        xml += " </resources>\n <build>\n"
        let transform = "1 0 0 0 1 0 0 0 1 \(number(offset.x)) \(number(offset.y)) \(number(offset.z))"
        for id in ids {
            xml += "  <item objectid=\"\(id)\" transform=\"\(transform)\"/>\n"
        }
        xml += " </build>\n</model>\n"
        return xml
    }

    /// Translation that puts the combined bounds on z = 0 and, with a preset,
    /// centres them on the bed (bed origin at the front-left corner).
    static func placementOffset(_ meshes: [Mesh], preset: PrinterPreset?) -> SIMD3<Float> {
        var lo: SIMD3<Float>?
        var hi: SIMD3<Float>?
        for m in meshes {
            guard let b = m.bounds else { continue }
            lo = lo.map { simd_min($0, b.min) } ?? b.min
            hi = hi.map { simd_max($0, b.max) } ?? b.max
        }
        guard let lo, let hi else { return .zero }
        var offset = SIMD3<Float>(0, 0, -lo.z)
        if let preset {
            let center = (lo + hi) / 2
            offset.x = Float(preset.bedSize.x / 2) - center.x
            offset.y = Float(preset.bedSize.y / 2) - center.y
        }
        return offset
    }

    /// Deduplicates vertices by exact position and drops triangles that become
    /// degenerate (the 3MF spec forbids repeated vertex indices).
    static func weld(_ mesh: Mesh) -> (vertices: [SIMD3<Float>], triangles: [(Int, Int, Int)]) {
        var index: [SIMD3<Float>: Int] = [:]
        var vertices: [SIMD3<Float>] = []
        var remap: [Int] = []
        remap.reserveCapacity(mesh.positions.count)
        for p in mesh.positions {
            if let i = index[p] {
                remap.append(i)
            } else {
                index[p] = vertices.count
                remap.append(vertices.count)
                vertices.append(p)
            }
        }
        var triangles: [(Int, Int, Int)] = []
        for t in 0..<(mesh.indices.count / 3) {
            let raw = (Int(mesh.indices[3 * t]), Int(mesh.indices[3 * t + 1]), Int(mesh.indices[3 * t + 2]))
            guard raw.0 < remap.count, raw.1 < remap.count, raw.2 < remap.count else { continue }
            let v = (remap[raw.0], remap[raw.1], remap[raw.2])
            guard v.0 != v.1, v.1 != v.2, v.0 != v.2 else { continue }
            triangles.append(v)
        }
        return (vertices, triangles)
    }

    static func number(_ v: Float) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e7 { return String(Int(v)) }
        return String(v)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }
}
