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
                the face's inward normal, and follow the face when earlier steps move it. For screws, give a \
                `preset` ("m3-clearance", "m4-counterbore"…; M2–M6): clearance (ISO 273 normal), counterbore \
                (socket head cap screw, ISO 4762), countersink (flat head, ISO 10642), tap (undersized, for a screw \
                that cuts its own thread in the plastic) or insert (heat-set insert, CNC Kitchen / Ruthex sizes). \
                Clearance, counterbore and countersink add the design's `clearance` parameter (created at 0.2 mm if \
                missing) to their diameters, so set_parameter on it tunes every screw hole to the printer. Size \
                arguments given with a preset override its values.
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
                "preset": Self.string("Screw preset: size-fit, e.g. \"m3-clearance\"", enum: HolePreset.all.map(\.id)),
                "hole_type": Self.string("Default simple (or the preset's)", enum: HoleType.allCases.map(\.rawValue)),
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
            var preset: HolePreset?
            if let name = a.optionalString("preset") {
                guard let p = HolePreset(id: name) else {
                    throw ToolError("Unknown `preset` \"\(name)\": use size-fit, size M2, M2.5, M3, M4, M5 or M6 and fit "
                        + "\(HoleFit.allCases.map(\.rawValue).joined(separator: ", ")) (e.g. \"m3-clearance\")")
                }
                preset = p
            }
            // A preset gives the defaults; explicit arguments still win.
            var d = Hole(face: nil)
            preset?.apply(to: &d)
            let typeName = a.optionalString("hole_type") ?? d.holeType.rawValue
            guard let type = HoleType(rawValue: typeName) else {
                throw ToolError("`hole_type` must be \(HoleType.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            var hole = Hole(
                face: ref, centers: centers, holeType: type, diameter: try a.expr("diameter", default: d.diameter),
                extent: a.bool("through_all", default: false) ? .throughAll : d.extent,
                depth: try a.expr("depth", default: d.depth), tipAngle: try a.expr("tip_angle", default: d.tipAngle),
                counterboreDiameter: try a.expr("counterbore_diameter", default: d.counterboreDiameter),
                counterboreDepth: try a.expr("counterbore_depth", default: d.counterboreDepth),
                countersinkDiameter: try a.expr("countersink_diameter", default: d.countersinkDiameter),
                countersinkAngle: try a.expr("countersink_angle", default: d.countersinkAngle), anchor: .world)
            hole.preset = preset
            let feature = Feature(name: Change.uniqueName(a.optionalString("name"), base: "Hole", in: ws.document), .hole(hole))
            var addedClearance = false
            let (model, warnings) = try await Change.apply(ws, action: "New \(feature.name)", newFeature: feature.id) { doc in
                if preset?.fit.usesClearance == true { addedClearance = doc.addClearanceParameterIfMissing() }
                _ = doc.addFeature(feature)
            }
            var extra: [String: JSONValue] = [:]
            if let title = hole.presetTitle { extra["preset"] = .string(title) }
            if addedClearance { extra["added_parameter"] = .string("\(HolePreset.clearanceParameter) = \(HolePreset.defaultClearance.source)") }
            let world = (try? hole.worldCenters(on: plane, using: model.parameters.evaluator)) ?? []
            return Report.added(ws, model, warnings: warnings, feature: feature.id, extra: extra.merging([
                "face_plane": Describe.plane(plane), "hole_centers": .array(world.map { .vec($0, 3) }),
            ]) { a, _ in a })
        }
    }
}
