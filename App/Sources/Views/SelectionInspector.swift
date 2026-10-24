import FilletCore
import FilletKernel
import SwiftUI

/// Measurements of the current selection, or a design summary when nothing is selected.
struct SelectionInspector: View {
    @Bindable var session: DesignSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.selection.isEmpty {
                summary
            } else {
                ForEach(Array(session.selection.prefix(4).enumerated()), id: \.offset) { _, item in
                    describe(item)
                }
                if session.selection.count == 2 { distance }
                actions
            }
        }
    }

    @ViewBuilder private var summary: some View {
        Text("Design").font(.headline)
        if session.model.bodies.isEmpty {
            Hint("Start with a sketch: pick Sketch in the toolbar, draw a profile, then Extrude it.")
        } else {
            let analysis = session.printAnalysis
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Bodies", "\(session.model.bodies.count)")
                if let a = analysis {
                    row("Size", "\(fmt(a.size.x)) × \(fmt(a.size.y)) × \(fmt(a.size.z)) mm")
                    row("Volume", "\(fmt(a.volume / 1000)) cm³")
                    row("PLA", "≈ \(fmt(a.grams(.pla))) g")
                    row("Fits \(session.document.printerPreset.name)", a.fitsOnBed ? (a.fitsOnlyRotated ? "Yes, rotated 90°" : "Yes") : "No")
                    row("Overhangs", a.overhangCount == 0 ? "None" : "\(fmt(a.overhangArea)) mm²")
                    row("Watertight", a.isWatertight ? "Yes" : "No (\(a.boundaryEdgeCount) open edges)")
                }
            }
            .font(.callout)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
    }

    @ViewBuilder private func describe(_ s: Selection) -> some View {
        switch s {
        case .face(let b, let i):
            if let shape = session.model.body(b)?.shape, let info = shape.faceInfoIfValid(i) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(info.surface.title) face", systemImage: "square.fill").font(.subheadline.weight(.medium))
                    Text("Area \(fmt(info.area)) mm²").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .edge(let b, let i):
            if let shape = session.model.body(b)?.shape, let info = shape.edgeInfoIfValid(i) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(info.curve.title) edge", systemImage: "line.diagonal").font(.subheadline.weight(.medium))
                    Text(info.curve == .circle ? "Radius \(fmt(info.radius)) mm · Ø \(fmt(info.radius * 2)) mm · length \(fmt(info.length)) mm"
                                               : "Length \(fmt(info.length)) mm")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .body(let b):
            if let body = session.model.body(b) {
                Label(body.name, systemImage: "cube").font(.subheadline.weight(.medium))
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var distance: some View {
        if let d = session.selectionDistance {
            Label("Distance \(fmt(d)) mm", systemImage: "ruler").font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.selectedEdges.isEmpty {
                Button { session.startEdgeFeature(fillet: true) } label: { Label("Fillet edges", systemImage: "rectangle.roundedtop") }
                Button { session.startEdgeFeature(fillet: false) } label: { Label("Chamfer edges", systemImage: "skew") }
            }
            if let (b, f) = session.selectedFaces.first, session.model.body(b)?.shape.facePlane(f) != nil {
                Button { session.startSketch() } label: { Label("Sketch on face", systemImage: "pencil.and.outline") }
                Button { session.startLayFlat() } label: { Label("Lay flat on bed", systemImage: "arrow.down.to.line") }
            }
            if !session.selectedFaces.isEmpty {
                Button { session.startShell() } label: { Label("Shell (remove faces)", systemImage: "cube.transparent") }
            }
            Button("Clear selection") { session.selection = [] }.foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.top, 6)
    }

    private func fmt(_ v: Double) -> String { ExprField.format((v * 100).rounded() / 100) }
}

extension DesignSession {
    /// Print analysis of all visible bodies.
    var printAnalysis: PrintAnalysis? {
        let meshes = model.bodies.filter { !hiddenBodies.contains($0.ref) }.compactMap { model.meshes[$0.ref] }
        guard !meshes.isEmpty else { return nil }
        return PrintAnalysis.analyze(meshes: meshes, preset: document.printerPreset, overhangAngleDegrees: overhangAngle)
    }

    /// Minimum distance between two selected faces/edges/bodies.
    var selectionDistance: Double? {
        guard selection.count == 2 else { return nil }
        func shape(_ s: Selection) -> Shape? {
            switch s {
            case .face(let b, let i): try? model.body(b)?.shape.face(i)
            case .edge(let b, let i): try? model.body(b)?.shape.edge(i)
            case .body(let b): model.body(b)?.shape
            default: nil
            }
        }
        guard let a = shape(selection[0]), let b = shape(selection[1]) else { return nil }
        return a.distance(to: b)?.distance
    }
}

extension SurfaceType {
    var title: String {
        switch self {
        case .plane: "Flat"
        case .cylinder: "Cylindrical"
        case .cone: "Conical"
        case .sphere: "Spherical"
        case .torus: "Toroidal"
        case .bspline: "Freeform"
        case .other: "Curved"
        }
    }
}

extension CurveType {
    var title: String {
        switch self {
        case .line: "Straight"
        case .circle: "Circular"
        case .ellipse: "Elliptical"
        case .bspline: "Curved"
        case .other: "Curved"
        }
    }
}
