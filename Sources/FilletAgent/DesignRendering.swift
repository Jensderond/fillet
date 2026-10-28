import CoreGraphics
import FilletCore
import FilletKernel
import FilletViewport
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds a viewport scene from a design and renders it offscreen, for agents to look at.
@MainActor
public enum DesignRendering {
    public struct Options {
        public var hidden: Set<BodyRef> = []
        /// Faces and edges drawn as selected.
        public var highlight: Set<PickTarget> = []
        /// Bodies drawn as selected.
        public var highlightBodies: Set<BodyRef> = []
        /// Sketch whose curves and profiles are overlaid.
        public var sketch: UUID?
        public var visualStyle: VisualStyle = .shadedWithEdges
        public var showBed = true
        /// Product-shot look: no edges, bed or grid; a warm studio backdrop with a soft shadow.
        public var presentation = false
        /// Cuts the bodies open to show their inside.
        public var section: SectionPlane?

        public init() {}
    }

    /// The scene the app would show for this design (body colours, bed, optional sketch).
    public static func scene(document: Document, model: EvaluatedModel, options: Options = Options()) -> ViewportScene {
        var scene = ViewportScene()
        for body in model.bodies {
            scene.bodies.append(SceneBody(
                id: body.ref.feature, mesh: model.meshes[body.ref] ?? .empty,
                version: ObjectIdentifier(body.shape).hashValue,
                color: document.bodyColors[body.ref].flatMap(ViewportColor.init(hexString:)),
                visible: !options.hidden.contains(body.ref),
                highlight: options.highlightBodies.contains(body.ref) ? .selected : .none))
        }
        scene.selection = options.highlight
        if options.showBed, !options.presentation {
            let preset = document.printerPreset
            scene.plate = BuildPlate(name: preset.name, size: preset.bedSize)
        }
        if let id = options.sketch, let sketch = model.sketches[id] {
            var curves: [SketchCurve] = []
            for shape in sketch.source.shapes {
                for poly in sketch.curves[shape.id] ?? [] {
                    curves.append(SketchCurve(shapeID: shape.id, points: poly, style: shape.construction ? .construction : .normal))
                }
            }
            let regions = sketch.regionFills.enumerated().map { SketchRegion(index: $0.offset, triangles: $0.element) }
            scene.sketch = SketchOverlay(plane: sketch.plane, curves: curves, regions: regions, grid: nil)
        }
        scene.visualStyle = options.presentation ? .shaded : options.visualStyle
        // The ground grid stays on for the contact shadow; the presentation palette hides its lines.
        scene.showsGroundGrid = true
        scene.ellipticalShadows = options.presentation
        scene.section = options.section
        return scene
    }

    /// Warm paper backdrop, invisible ground, soft warm shadow and gentler, brighter light.
    public static let presentationPalette: ViewportPalette = {
        var p = ViewportPalette.light
        p.backgroundTop = ViewportColor(hex: 0xFBEFDC)
        p.backgroundBottom = ViewportColor(hex: 0xF4E1C6)
        p.groundMinor = ViewportColor(hex: 0, alpha: 0)
        p.groundMajor = ViewportColor(hex: 0, alpha: 0)
        p.axisX = ViewportColor(hex: 0, alpha: 0)
        p.axisY = ViewportColor(hex: 0, alpha: 0)
        p.axisZ = ViewportColor(hex: 0, alpha: 0)
        p.shadow = ViewportColor(hex: 0x7A5A3A, alpha: 0.42)
        p.skyLight = ViewportColor(hex: 0xFFF8EE)
        p.groundLight = ViewportColor(hex: 0xC9A98A)
        p.ambient = 0.5
        p.key = 0.6
        p.fill = 0.24
        p.rim = 0.3
        p.specular = 0.14
        return p
    }()

    private static var renderer: ViewportRenderer?

    /// Renders the scene from `camera` as PNG data.
    public static func png(scene: ViewportScene, camera: Camera, size: CGSize, appearance: ViewportAppearance = .light,
                           palette: ViewportPalette? = nil) throws -> Data {
        if renderer == nil { renderer = try ViewportRenderer() }
        guard let renderer, let image = renderer.snapshot(scene: scene, camera: camera, size: size, scale: 1, appearance: appearance,
                                                          customPalette: palette) else {
            throw ToolError("Rendering failed (Metal unavailable?)")
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError("PNG encoding failed")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("PNG encoding failed") }
        return data as Data
    }
}
