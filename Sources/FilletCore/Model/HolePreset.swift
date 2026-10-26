import Foundation

/// Metric screw sizes the hole presets cover.
public enum ScrewSize: String, Hashable, Sendable, CaseIterable {
    case m2 = "M2", m2_5 = "M2.5", m3 = "M3", m4 = "M4", m5 = "M5", m6 = "M6"
}

/// What a preset hole is for.
public enum HoleFit: String, Hashable, Sendable, CaseIterable {
    /// The screw passes through freely.
    case clearance
    /// Clearance plus a recess for a socket head cap screw's head (ISO 4762).
    case counterbore
    /// Clearance plus a cone for a flat (countersunk) head (ISO 10642).
    case countersink
    /// Undersized, for a screw that cuts its own thread in the plastic.
    case tap
    /// For a heat-set threaded insert, pressed in with a soldering iron.
    case insert

    public var title: String {
        switch self {
        case .clearance: "clearance"
        case .counterbore: "socket head counterbore"
        case .countersink: "flat head countersink"
        case .tap: "tap (self-tapping)"
        case .insert: "heat-set insert"
        }
    }

    /// Whether the fit adds the design's print clearance (``HolePreset/clearanceParameter``):
    /// fits where the screw must pass, not those that must grip.
    public var usesClearance: Bool { self == .clearance || self == .counterbore || self == .countersink }
}

/// A standard hole for a metric screw in a printed part: picking one fills a hole's sizes, which
/// stay editable. Clearance fits add the `clearance` parameter to their diameters, so tuning it
/// once fits every screw to the printer.
///
/// Sizes (mm):
/// - Clearance: ISO 273 medium (normal) series.
/// - Counterbore: DIN 974-1 diameter for ISO 4762 socket head cap screws; depth = ISO 4762
///   head height k (max), so the head sits flush. DIN 974-1 starts at M3: M2 and M2.5 follow the
///   same ISO 4762-based charts (head dk 3.8 / 4.5 plus room).
/// - Countersink: theoretical (sharp-edged) head diameter dk, 90°, ISO 10642 (M2–M6; the 2019
///   edition added M2 and M2.5, the 2004 one started at M3). ISO 14581 heads are smaller (M2 3.8,
///   M2.5 4.7), so those screws sit a little deeper.
/// - Tap: tap drill (d − pitch, coarse thread) + 0.2 mm, e.g. M3 → 2.7: printed holes come out a
///   little small, and a screw cuts its thread into plastic more easily than into metal.
/// - Heat-set insert: hole diameter for the standard-length CNC Kitchen / Ruthex inserts as their
///   sheets give them (CNC Kitchen "Dimensions & Design Guidelines" PDF, D2; Ruthex spec table, D3),
///   depth = insert length + 1 mm for the plastic the insert pushes ahead. Lengths are Ruthex's
///   (M2 × 4, M2.5 × 5.7; CNC Kitchen's are 3 and 4, so these holes are deeper than needed for those).
///   Where the makers differ (M4–M6: CNC Kitchen 5.7 / 6.5 / 8.1) this uses Ruthex's smaller hole.
///   Other inserts differ; check the maker's sheet.
public struct HolePreset: Hashable, Sendable, Codable, CustomStringConvertible {
    public var size: ScrewSize
    public var fit: HoleFit

    public init(_ size: ScrewSize, _ fit: HoleFit) {
        self.size = size
        self.fit = fit
    }

    /// The parameter clearance fits add to their diameters.
    public static let clearanceParameter = "clearance"
    /// Its starting value: right for most FDM printers with a 0.4 mm nozzle.
    public static let defaultClearance: Expr = "0.2 mm"

    public static let all: [HolePreset] = HoleFit.allCases.flatMap { fit in ScrewSize.allCases.map { HolePreset($0, fit) } }

    /// "m3-clearance", "m2.5-insert": how it's saved and how agents name it.
    public var id: String { "\(size.rawValue.lowercased())-\(fit.rawValue)" }

    /// Reads an id, also written "M3 clearance" or "M3_clearance".
    public init?(id: String) {
        let parts = id.lowercased().split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" })
        guard parts.count == 2, let size = ScrewSize.allCases.first(where: { $0.rawValue.lowercased() == parts[0] }),
              let fit = HoleFit(rawValue: String(parts[1]))
        else { return nil }
        self.init(size, fit)
    }

    /// "M3 clearance".
    public var title: String { "\(size.rawValue) \(fit.title)" }
    public var description: String { id }

    private struct Sizes {
        var clearance, counterbore, counterboreDepth, countersink, tap, insert, insertLength: Double
    }

    private var sizes: Sizes {
        switch size {
        case .m2: Sizes(clearance: 2.4, counterbore: 4.4, counterboreDepth: 2, countersink: 4.7, tap: 1.8, insert: 3.2, insertLength: 4)
        case .m2_5: Sizes(clearance: 2.9, counterbore: 5.5, counterboreDepth: 2.5, countersink: 5.88, tap: 2.25, insert: 4, insertLength: 5.7)
        case .m3: Sizes(clearance: 3.4, counterbore: 6.5, counterboreDepth: 3, countersink: 6.72, tap: 2.7, insert: 4, insertLength: 5.7)
        case .m4: Sizes(clearance: 4.5, counterbore: 8, counterboreDepth: 4, countersink: 8.96, tap: 3.5, insert: 5.6, insertLength: 8.1)
        case .m5: Sizes(clearance: 5.5, counterbore: 10, counterboreDepth: 5, countersink: 11.2, tap: 4.4, insert: 6.4, insertLength: 9.5)
        case .m6: Sizes(clearance: 6.6, counterbore: 11, counterboreDepth: 6, countersink: 13.44, tap: 5.2, insert: 8, insertLength: 12.7)
        }
    }

    /// `value` plus the print clearance: "3.4 + clearance".
    private static func withClearance(_ value: Double) -> Expr { Expr("\(Expr(value).source) + \(clearanceParameter)") }

    /// Fills the hole's type and the sizes this preset decides (the rest stays), and records the preset.
    public func apply(to hole: inout Hole) {
        let s = sizes
        hole.preset = self
        switch fit {
        case .clearance:
            hole.holeType = .simple
            hole.diameter = Self.withClearance(s.clearance)
        case .counterbore:
            hole.holeType = .counterbore
            hole.diameter = Self.withClearance(s.clearance)
            hole.counterboreDiameter = Self.withClearance(s.counterbore)
            hole.counterboreDepth = Expr(s.counterboreDepth)
        case .countersink:
            hole.holeType = .countersink
            hole.diameter = Self.withClearance(s.clearance)
            hole.countersinkDiameter = Self.withClearance(s.countersink)
            hole.countersinkAngle = 90
        case .tap:
            hole.holeType = .simple
            hole.diameter = Expr(s.tap)
        case .insert:
            hole.holeType = .simple
            hole.diameter = Expr(s.insert)
            hole.extent = .distance
            hole.depth = Expr(s.insertLength + 1)
        }
    }

    /// Whether the hole still has exactly the sizes this preset gives it (spaces aside).
    public func matches(_ hole: Hole) -> Bool {
        var expected = hole
        apply(to: &expected)
        func same(_ a: Expr, _ b: Expr) -> Bool { a.source.filter { !$0.isWhitespace } == b.source.filter { !$0.isWhitespace } }
        return expected.holeType == hole.holeType && expected.extent == hole.extent
            && [(expected.diameter, hole.diameter), (expected.depth, hole.depth),
                (expected.counterboreDiameter, hole.counterboreDiameter), (expected.counterboreDepth, hole.counterboreDepth),
                (expected.countersinkDiameter, hole.countersinkDiameter), (expected.countersinkAngle, hole.countersinkAngle)]
                .allSatisfy(same)
    }

    // Saved as its id; see `Hole` for how an unknown one reads.
    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let preset = HolePreset(id: id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown hole preset '\(id)'"))
        }
        self = preset
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}

extension Hole {
    /// "M3 clearance", with "(edited)" once a size no longer matches the preset; nil without one.
    public var presetTitle: String? {
        preset.map { $0.matches(self) ? $0.title : "\($0.title) (edited)" }
    }
}

extension Document {
    /// The print clearance parameter clearance-fit hole presets use.
    public var clearanceParameter: Parameter? { parameters.first { $0.name == HolePreset.clearanceParameter } }

    /// Adds the `clearance` parameter (0.2 mm) unless the design has one; returns whether it did.
    @discardableResult
    public mutating func addClearanceParameterIfMissing() -> Bool {
        guard clearanceParameter == nil else { return false }
        parameters.append(Parameter(
            name: HolePreset.clearanceParameter, expression: HolePreset.defaultClearance,
            comment: "Print clearance, added to the diameter of preset screw holes. Tune it once for your printer."))
        return true
    }

    /// Gives the hole `preset`'s sizes and, for a clearance fit, adds the `clearance` parameter.
    public mutating func apply(_ preset: HolePreset, to hole: inout Hole) {
        preset.apply(to: &hole)
        if preset.fit.usesClearance { addClearanceParameterIfMissing() }
    }
}
