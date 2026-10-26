import FilletCore
import FilletKernel
import Foundation

extension FilletTools {
    /// Drills holes into a flat face, like Fusion's Hole: simple, counterbored or countersunk.
    var hole: MCPTool {
        MCPTool(
            name: "hole", title: "Hole",
            description: """
                Drills holes into a flat face of a body, all the same size: simple, counterbore (a flat recess for a \
                cap screw head) or countersink (a cone for a flat-head screw). Place them with `points` on the face \
                (world [x, y, z]) or `centers` in the face's own coordinates [u, v] (mm along its u/v axes from its \
                origin, as returned in `face_plane`; axes as for a sketch on a face). The holes go straight in, along \
                the face's inward normal, and follow the face when earlier steps move it.
                """,
            inputSchema: Self.object([
                "body": Self.body,
                "face": ["description": "Flat face index or filter, e.g. {\"type\": \"plane\", \"extreme\": \"+z\"}",
                         "anyOf": [["type": "integer"], Self.filter]],
                "points": ["type": "array", "items": Self.vec3("[x, y, z] on the face"),
                           "description": "Hole centres as world points on the face"],
                "centers": ["type": "array", "items": ["type": "array", "items": ["type": ["number", "string"]], "minItems": 2, "maxItems": 2],
                            "description": "Hole centres in face coordinates [u, v] (numbers or expressions)"],
                "diameter": Self.expr("Hole diameter (default 5)"),
                "depth": Self.expr("Depth of the full-diameter part from the face (default 10); the drill point goes below it"),
                "through_all": Self.boolean("Drill through the whole body (ignores depth and tip_angle)"),
                "tip_angle": Self.expr("Drill point angle in degrees (default 118); 0 = flat bottom"),
                "hole_type": Self.string("Default simple", enum: HoleType.allCases.map(\.rawValue)),
                "counterbore_diameter": Self.expr("Counterbore diameter (default 9)"),
                "counterbore_depth": Self.expr("Counterbore depth (default 3)"),
                "countersink_diameter": Self.expr("Countersink diameter at the face (default 10)"),
                "countersink_angle": Self.expr("Countersink included angle in degrees (default 90)"),
                "name": Self.name,
            ], required: ["body", "face"])
        ) { args in
            let a = Args(args)
            let ws = try host.requireCurrent()
            let r = try await Resolver.load(ws, args)
            let (b, i, ref) = try r.faceRef(["body": .string(try a.string("body")), "face": a["face"] ?? .null], key: "face")
            guard let plane = b.shape.facePlane(i, anchor: .world) else {
                throw ToolError("Face \(i) of “\(r.bodyLabel(b))” isn't flat; pick a planar face (list_faces with {\"type\": \"plane\"})")
            }
            var centers = try (a["centers"]?.array ?? []).map { try Args.point2($0, "centers") }
            for (n, v) in (a["points"]?.array ?? []).enumerated() {
                guard let p = try Args.point3(v, "points[\(n)]") else { continue }
                let off = abs(plane.signedDistance(p))
                guard off <= 0.5 else {
                    throw ToolError("points[\(n)] is \(String(format: "%.2f", off)) mm off the face; give points on it (face_plane: origin \(plane.origin), normal \(plane.normal))")
                }
                let uv = plane.project(p)
                func round(_ v: Double) -> Expr { Expr((v * 10_000).rounded() / 10_000) }
                centers.append(Point2Expr(round(uv.x), round(uv.y)))
            }
            guard !centers.isEmpty else { throw ToolError("Give at least one hole centre in `points` or `centers`") }
            let typeName = a.optionalString("hole_type") ?? HoleType.simple.rawValue
            guard let type = HoleType(rawValue: typeName) else {
                throw ToolError("`hole_type` must be \(HoleType.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let d = Hole(face: nil)
            let hole = Hole(
                face: ref, centers: centers, holeType: type, diameter: try a.expr("diameter", default: d.diameter),
                extent: a.bool("through_all", default: false) ? .throughAll : .distance,
                depth: try a.expr("depth", default: d.depth), tipAngle: try a.expr("tip_angle", default: d.tipAngle),
                counterboreDiameter: try a.expr("counterbore_diameter", default: d.counterboreDiameter),
                counterboreDepth: try a.expr("counterbore_depth", default: d.counterboreDepth),
                countersinkDiameter: try a.expr("countersink_diameter", default: d.countersinkDiameter),
                countersinkAngle: try a.expr("countersink_angle", default: d.countersinkAngle), anchor: .world)
            let feature = Feature(name: Change.uniqueName(a.optionalString("name"), base: "Hole", in: ws.document), .hole(hole))
            let (model, warnings) = try await Change.apply(ws, action: "New \(feature.name)", newFeature: feature.id) { _ = $0.addFeature(feature) }
            let world = (try? hole.worldCenters(on: plane, using: model.parameters.evaluator)) ?? []
            return Report.added(ws, model, warnings: warnings, feature: feature.id, extra: [
                "face_plane": Describe.plane(plane), "hole_centers": .array(world.map { .vec($0, 3) }),
            ])
        }
    }
}
