import Foundation

/// A printer's build volume.
public struct PrinterPreset: Identifiable, Hashable, Sendable, Codable {
    /// Stable identifier stored in documents, e.g. `"bambu-a1-mini"`.
    public var id: String
    public var name: String
    /// Usable build volume in mm (x = width, y = depth, z = height).
    public var bedSize: SIMD3<Double>

    public init(id: String, name: String, bedSize: SIMD3<Double>) {
        self.id = id
        self.name = name
        self.bedSize = bedSize
    }

    public init(id: String, name: String, x: Double, y: Double, z: Double) {
        self.init(id: id, name: name, bedSize: SIMD3(x, y, z))
    }

    public static let bambuA1Mini = PrinterPreset(id: "bambu-a1-mini", name: "Bambu Lab A1 mini", x: 180, y: 180, z: 180)
    public static let bambuA1 = PrinterPreset(id: "bambu-a1", name: "Bambu Lab A1", x: 256, y: 256, z: 256)
    public static let bambuP1P = PrinterPreset(id: "bambu-p1p", name: "Bambu Lab P1P", x: 256, y: 256, z: 256)
    public static let bambuP1S = PrinterPreset(id: "bambu-p1s", name: "Bambu Lab P1S", x: 256, y: 256, z: 256)
    public static let bambuX1C = PrinterPreset(id: "bambu-x1c", name: "Bambu Lab X1 Carbon", x: 256, y: 256, z: 256)
    public static let bambuX1E = PrinterPreset(id: "bambu-x1e", name: "Bambu Lab X1E", x: 256, y: 256, z: 256)
    /// H2D: the full bed is 350×320×325 but a single nozzle can only reach
    /// 325 mm in X (the other nozzle's parking area). We use the
    /// single-nozzle usable area so "fits on bed" is safe for either nozzle.
    public static let bambuH2D = PrinterPreset(id: "bambu-h2d", name: "Bambu Lab H2D", x: 325, y: 320, z: 325)
    public static let prusaMK4 = PrinterPreset(id: "prusa-mk4", name: "Prusa MK4", x: 250, y: 210, z: 220)
    public static let prusaCoreOne = PrinterPreset(id: "prusa-core-one", name: "Prusa Core One", x: 250, y: 220, z: 270)

    /// Identifier of a user-defined build volume (see ``Document/customBedSize``).
    public static let customID = "custom"

    /// A user-defined build volume.
    public static func custom(x: Double, y: Double, z: Double) -> PrinterPreset {
        PrinterPreset(id: customID, name: "Custom", x: x, y: y, z: z)
    }

    /// The built-in presets, in menu order.
    public static let all: [PrinterPreset] = [
        .bambuA1Mini, .bambuA1, .bambuP1P, .bambuP1S, .bambuX1C, .bambuX1E, .bambuH2D, .prusaMK4, .prusaCoreOne,
    ]

    /// The built-in preset with the given id.
    public static func preset(id: String) -> PrinterPreset? { all.first { $0.id == id } }

    /// The default printer for new documents.
    public static let `default` = bambuA1Mini
}
