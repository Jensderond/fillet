import Foundation

/// Unit used to display lengths. Geometry is always stored in millimetres.
public enum LengthUnit: String, Hashable, Sendable, Codable, CaseIterable {
    case mm, cm, `in`
}

/// Errors loading a document file.
public enum DocumentError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file was written by a newer, incompatible version of the app.
    case newerFormat(Int)

    public var description: String {
        switch self {
        case .newerFormat(let v):
            "This design was saved by a newer version of Fillet (format \(v)). Please update the app."
        }
    }
}

/// A complete design: parameters, the feature timeline and print settings.
/// Saved as pretty-printed JSON with sorted keys (the `.fillet` file).
public struct Document: Hashable, Sendable, Codable {
    /// Bumped only for incompatible changes; additive changes keep the version
    /// (unknown keys are ignored, unknown feature types are preserved).
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String?
    public var units: LengthUnit
    /// Id of a ``PrinterPreset`` (or ``PrinterPreset/customID``).
    public var printer: PrinterPreset.ID
    /// Build volume used when `printer` is ``PrinterPreset/customID``.
    public var customBedSize: SIMD3<Double>?
    public var parameters: [Parameter]
    public var features: [Feature]
    /// Timeline marker: only `features[..<rollbackIndex]` are evaluated. `nil` = all.
    public var rollbackIndex: Int?
    /// Display colour per body as `#RRGGBB`; bodies without one use the viewport's default.
    public var bodyColors: [BodyRef: String] = [:]

    /// A new, empty design for the default printer (A1 mini).
    public init(
        name: String? = nil, units: LengthUnit = .mm, printer: PrinterPreset.ID = PrinterPreset.default.id,
        parameters: [Parameter] = [], features: [Feature] = [], rollbackIndex: Int? = nil
    ) {
        self.formatVersion = Document.currentFormatVersion
        self.name = name
        self.units = units
        self.printer = printer
        self.parameters = parameters
        self.features = features
        self.rollbackIndex = rollbackIndex
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, units, printer, customBedSize, parameters, features, rollbackIndex, bodyColors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard formatVersion <= Document.currentFormatVersion else { throw DocumentError.newerFormat(formatVersion) }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        units = (try? c.decodeIfPresent(LengthUnit.self, forKey: .units)) ?? .mm
        printer = try c.decodeIfPresent(String.self, forKey: .printer) ?? PrinterPreset.default.id
        customBedSize = try c.decodeIfPresent(SIMD3<Double>.self, forKey: .customBedSize)
        parameters = try c.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
        features = try c.decodeIfPresent([Feature].self, forKey: .features) ?? []
        rollbackIndex = try c.decodeIfPresent(Int.self, forKey: .rollbackIndex)
        // Keyed by body id string; entries that aren't ids are dropped.
        let colors = (try? c.decodeIfPresent([String: String].self, forKey: .bodyColors)) ?? [:]
        bodyColors = Dictionary(colors.compactMap { k, v in UUID(uuidString: k).map { (BodyRef($0), v) } }, uniquingKeysWith: { a, _ in a })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(units, forKey: .units)
        try c.encode(printer, forKey: .printer)
        try c.encodeIfPresent(customBedSize, forKey: .customBedSize)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(features, forKey: .features)
        try c.encodeIfPresent(rollbackIndex, forKey: .rollbackIndex)
        if !bodyColors.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: bodyColors.map { ($0.feature.uuidString, $1) }), forKey: .bodyColors)
        }
    }

    /// Stable, human-readable JSON (pretty printed, sorted keys).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Loads a document from `.fillet` JSON data.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Document.self, from: data)
    }

    // MARK: Derived

    /// The selected printer (a custom one when `printer` is ``PrinterPreset/customID``).
    public var printerPreset: PrinterPreset {
        if printer == PrinterPreset.customID, let s = customBedSize {
            return .custom(x: s.x, y: s.y, z: s.z)
        }
        return PrinterPreset.preset(id: printer) ?? .default
    }

    /// Evaluated parameters (and an evaluator for feature expressions).
    public var parameterTable: ParameterTable { ParameterTable(parameters) }

    /// Number of features before the rollback marker.
    public var activeFeatureCount: Int { min(rollbackIndex ?? features.count, features.count) }

    /// Features before the rollback marker that are not suppressed — what recompute evaluates.
    public var activeFeatures: [Feature] {
        features[..<activeFeatureCount].filter { !$0.suppressed }
    }

    /// The feature with the given id.
    public func feature(_ id: UUID) -> Feature? { features.first { $0.id == id } }

    /// Position of the feature in the timeline.
    public func index(of id: UUID) -> Int? { features.firstIndex { $0.id == id } }
}
