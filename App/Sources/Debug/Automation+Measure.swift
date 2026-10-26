#if DEBUG
import FilletCore
import FilletKernel
import FilletViewport
import Foundation

extension DebugAutomation {
    /// Measure on the finished plate (80 × 30 × 12 with a Ø14 hole and a pocket): faces, edges,
    /// vertices picked through the viewport like taps, then bodies; Escape and other tools end it,
    /// and it never touches the document or the undo history.
    static func measureScenario(_ session: DesignSession) async {
        guard let body = session.model.bodies.first else { check(false, "a body to measure"); return }
        let shape = body.shape
        let id = body.ref.feature
        func tap(_ target: PickTarget?) {
            session.viewportDidTap(target: target, hit: nil, ray: Ray(origin: .zero, direction: .unitZ), location: .zero, modifiers: [])
        }
        func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-4) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

        session.selection = []
        session.camera = session.camera.viewing(.iso)
        session.frameBodies()
        await settle(session)
        let documentBefore = session.document
        let undoBefore = (session.canUndo, session.canRedo)

        session.startMeasure()
        await settle(session)
        check(session.measure != nil && session.pickMode == .measure && session.pickFilter == [.faces, .edges, .vertices],
              "Measure picks faces, edges and vertices")

        // Top face (a real pick) to bottom face: the plate's 12 mm, at 180°.
        let topHit = pick(session, at: Vec3(25, 25, 12))
        guard case .face(_, let top)? = topHit?.target else { check(false, "a tap on the top face picks it (\(String(describing: topHit?.target)))"); return }
        tap(topHit?.target)
        let topArea = shape.faceInfo(top).area
        check(near(session.measure?.items.first??.area, topArea), "one face: area \(session.measure?.items.first??.area ?? 0) mm²")
        guard let bottom = shape.faceInfos.firstIndex(where: { $0.surface == .plane && $0.normal.z < -0.99 }) else {
            check(false, "a bottom face"); return
        }
        tap(.face(body: id, index: bottom))
        let faces = session.measure?.pair
        check(near(faces?.distance, 12) && near(abs(faces?.delta.z ?? 0), 12) && near(faces?.angle, .pi),
              "top to bottom face: \(faces?.distance ?? -1) mm, ΔZ \(faces?.delta.z ?? 0), angle \((faces?.angle ?? 0) * 180 / .pi)°")
        let line = session.makeScene().measures.first { $0.id == "measure-distance" }
        check(line?.label == "12 mm" && line?.showsLine == true, "the distance is drawn between the closest points (\(line?.label ?? "none"))")
        check(session.makeScene().selection == [.face(body: id, index: top), .face(body: id, index: bottom)], "both faces show as picked")
        await snap(session, "11-measure-faces")

        // A third pick starts over: a vertical edge, 12 mm long.
        guard let upright = shape.edgeInfos.firstIndex(where: { $0.curve == .line && abs($0.tangentAtMid.z) > 0.99 }) else {
            check(false, "a vertical edge"); return
        }
        tap(.edge(body: id, index: upright))
        check(session.measure?.picks.count == 1 && near(session.measure?.items.first??.length, 12) && session.measure?.pair == nil,
              "a third pick starts over: edge length \(session.measure?.items.first??.length ?? 0) mm")
        check(session.makeScene().edgeHighlights.count == 1, "the picked edge is drawn highlighted")
        tap(.edge(body: id, index: upright))
        check(session.measure?.picks.isEmpty == true, "picking it again takes it back")

        // The hole: its rim radius and its wall's radius, 7 mm.
        if let rim = shape.edgeInfos.firstIndex(where: { $0.curve == .circle && abs($0.radius - 7) < 1e-6 }),
            let wall = shape.faceInfos.indices.first(where: { shape.faceInfo($0).surface == .cylinder && near(shape.faceRadius($0), 7) })
        {
            tap(.edge(body: id, index: rim))
            check(near(session.measure?.items.first??.radius, 7), "circular edge radius \(session.measure?.items.first??.radius ?? 0) mm")
            tap(.face(body: id, index: wall))
            check(near(session.measure?.items.last??.radius, 7), "cylindrical face radius \(session.measure?.items.last??.radius ?? 0) mm")
            session.escape()
            check(session.measure?.picks.isEmpty == true && session.measure != nil, "Escape clears the picks, Measure stays on")
        } else {
            check(false, "the hole's rim and wall")
        }

        // Two vertices, picked where they show: the distance and its parts match their positions.
        let mesh = session.model.meshes[body.ref]
        var picked: [Int] = []
        for i in 0..<shape.vertexCount where picked.count < 2 {
            guard let p = shape.vertexPoint(i), let hit = pick(session, at: p), hit.target == .vertex(body: id, index: i) else { continue }
            if let first = picked.first, let a = shape.vertexPoint(first), a.distance(to: p) < 20 { continue }  // far enough apart to read
            tap(hit.target)
            picked.append(i)
        }
        check(picked.count == 2 && mesh?.brepVertices.count == shape.vertexCount, "two vertices picked in the viewport (\(picked))")
        if picked.count == 2, let a = shape.vertexPoint(picked[0]), let b = shape.vertexPoint(picked[1]), let pair = session.measure?.pair {
            check(near(pair.distance, a.distance(to: b)) && near(pair.delta.x, b.x - a.x) && near(pair.delta.y, b.y - a.y)
                  && near(pair.delta.z, b.z - a.z) && pair.angle == nil,
                  "vertex to vertex \(pair.distance) mm (Δ \(pair.delta))")
        }
        await snap(session, "11b-measure-vertices")

        // Bodies: volume and size.
        session.setMeasurePicksBodies(true)
        await settle(session)  // the viewport picks with the filter it last drew with
        check(session.pickFilter == [.bodies] && session.measure?.picks.isEmpty == true, "the Bodies filter picks whole bodies")
        let bodyHit = pick(session, at: Vec3(25, 25, 12))
        tap(bodyHit?.target)
        let item = session.measure?.items.first ?? nil
        let size = shape.bounds.map { $0.max - $0.min }
        check(bodyHit?.target == .body(id) && near(item?.volume, shape.volume, 1e-3) && item?.size == size,
              "one body: \(item?.volume ?? 0) mm³, \(item?.size.map(String.init(describing:)) ?? "-")")
        await snap(session, "11c-measure-body")

        // It never changed the document or the undo history.
        check(session.document == documentBefore && session.canUndo == undoBefore.0 && session.canRedo == undoBefore.1,
              "Measure leaves the document and the undo history alone")

        // Escape twice leaves; another tool ends it; the tool button toggles it.
        session.escape()
        session.escape()
        check(session.measure == nil && session.pickMode == .idle, "Escape twice leaves Measure")
        session.startMeasure()
        session.startSketch()
        check(session.measure == nil && session.choosingSketchPlane, "starting Sketch ends Measure")
        session.escape()
        session.startMeasure()
        session.startMeasure()
        check(session.measure == nil, "Measure toggles off")
        await settle(session)
    }
}
#endif
