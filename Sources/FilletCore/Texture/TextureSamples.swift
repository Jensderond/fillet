import FilletKernel
import Foundation

/// Small textured designs (a cylinder, a vase, a box) built from a few numbers, so a pattern can
/// be tried on a part with a reference model's proportions (texture-lab `sample`, tests).
public enum TextureSamples {
    public enum Base: String, Sendable, CaseIterable {
        /// A cylinder standing on the bed.
        case cylinder
        /// A revolved vase: `diameter` at the foot, bulging to `bulge` × it, `topDiameter` at the rim.
        case vase
        /// A `diameter` × `diameter` × `height` box.
        case box
    }

    public enum Faces: String, Sendable, CaseIterable {
        /// The side walls (not the top or the bottom).
        case sides
        /// Every face but the one on the bed.
        case all
    }

    public struct Options: Sendable {
        public var base: Base = .cylinder
        public var diameter = 60.0
        public var height = 80.0
        /// Vase rim diameter (default: 0.8 × `diameter`).
        public var topDiameter: Double?
        /// Vase belly as a factor of `diameter`.
        public var bulge = 1.25
        /// Wall thickness when hollowed (the top opened); nil = solid.
        public var shell: Double?
        public var faces: Faces = .sides
        public var pattern: TexturePatternID = .knit
        /// Pattern values by parameter id; others take their defaults.
        public var values: [String: Expr] = [:]

        public init() {}
    }

    /// The design: the base body and (unless `pattern` is empty) one texture step on it.
    public static func document(_ o: Options) async throws -> Document {
        var doc = Document(name: "Texture sample")
        let bodyID = UUID()
        switch o.base {
        case .cylinder:
            doc.features.append(Feature(id: bodyID, name: "Cylinder", .primitive(Primitive(
                kind: .cylinder, dimensions: [Expr(o.diameter), Expr(o.height)]))))
        case .box:
            doc.features.append(Feature(id: bodyID, name: "Box", .primitive(Primitive(
                kind: .box, position: Point2Expr(Expr(-o.diameter / 2), Expr(-o.diameter / 2)),
                dimensions: [Expr(o.diameter), Expr(o.diameter), Expr(o.height)]))))
        case .vase:
            let sketchID = UUID()
            let r0 = o.diameter / 2, rt = (o.topDiameter ?? o.diameter * 0.8) / 2, rb = r0 * o.bulge, h = o.height
            let p = { (x: Double, y: Double) in Point2Expr(Expr(x), Expr(y)) }
            let sketch = Sketch(plane: .standard(.xz, offset: 0), shapes: [
                SketchShape(.line(a: p(0, 0), b: p(r0, 0))),
                SketchShape(.spline(points: [p(r0, 0), p(rb, h * 0.35), p((rb + rt) / 2 * 1.02, h * 0.7), p(rt, h)])),
                SketchShape(.line(a: p(rt, h), b: p(0, h))),
                SketchShape(.line(a: p(0, h), b: p(0, 0))),
            ])
            doc.features.append(Feature(id: sketchID, name: "Profile", .sketch(sketch)))
            doc.features.append(Feature(id: bodyID, name: "Vase", .revolve(Revolve(
                sketch: sketchID, regions: [RegionRef(x: r0 * 0.3, y: h * 0.5)], axis: .y))))
        }
        let evaluator = ModelEvaluator()
        var model = await evaluator.evaluate(doc)
        guard let body = model.bodies.first else {
            throw FeatureError(model.status.values.compactMap { if case .failed(let m) = $0 { m } else { nil } }.first
                ?? "The sample body failed")
        }
        let ref = body.ref
        func isCap(_ info: FaceInfo) -> Bool { info.surface == .plane && abs(info.normal.normalized.z) > 0.999 }
        if let thickness = o.shell {
            let top = body.shape.faceInfos.indices.filter { isCap(body.shape.faceInfo($0)) && body.shape.faceInfo($0).normal.z > 0 }
            doc.features.append(Feature(name: "Shell", .shell(Shell(
                body: ref, removeFaces: top.compactMap { model.faceRef(body: ref, face: $0) }, thickness: Expr(thickness)))))
            model = await evaluator.evaluate(doc)
        }
        guard !o.pattern.rawValue.isEmpty, let shape = model.body(ref)?.shape else { return doc }
        var faces: [FaceRef] = []
        if o.faces == .sides {
            // Outer side walls: not the caps, and (when hollowed) not the inside.
            let infos = shape.faceInfos
            let center = shape.bounds.map { ($0.min + $0.max) / 2 } ?? .zero
            for (i, info) in infos.enumerated() where !isCap(info) {
                let out = Vec3(info.centroid.x - center.x, info.centroid.y - center.y, 0)
                if o.shell != nil, out.dot(info.normal) < 0 { continue }
                if let f = model.faceRef(body: ref, face: i) { faces.append(f) }
            }
        }
        doc.features.append(Feature(name: TextureCatalog.pattern(o.pattern)?.displayName ?? "Texture", .texture(Texture(
            body: ref, faces: faces, pattern: o.pattern, values: o.values))))
        return doc
    }
}
