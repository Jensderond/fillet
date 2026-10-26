import CFilletKernel
import Foundation

/// Size and shape of drilled holes (see ``Shape/drilled(at:direction:_:)``). Lengths in mm,
/// angles in radians.
public struct HoleSpec: Hashable, Sendable {
    /// What the hole looks like at the face, like Fusion's hole types.
    public enum Head: Hashable, Sendable {
        case simple
        /// A wider, flat-bottomed recess for a cap screw head.
        case counterbore(diameter: Double, depth: Double)
        /// A cone for a flat-head screw; `angle` is the included angle (90° for metric screws).
        case countersink(diameter: Double, angle: Double)
    }

    public var diameter: Double
    /// Depth of the full-diameter part from the face; nil drills through all.
    public var depth: Double?
    /// Drill point included angle (118° for a standard drill); 0 = flat bottom.
    public var tipAngle: Double
    public var head: Head

    public init(diameter: Double, depth: Double?, tipAngle: Double = 118 * .pi / 180, head: Head = .simple) {
        self.diameter = diameter; self.depth = depth; self.tipAngle = tipAngle; self.head = head
    }

    var fk: FKHoleSpec {
        var s = FKHoleSpec()
        s.diameter = diameter
        s.depth = depth ?? 0
        s.tipAngle = tipAngle
        switch head {
        case .simple:
            s.type = FK_HOLE_SIMPLE
        case .counterbore(let d, let depth):
            s.type = FK_HOLE_COUNTERBORE; s.headDiameter = d; s.headDepth = depth
        case .countersink(let d, let angle):
            s.type = FK_HOLE_COUNTERSINK; s.headDiameter = d; s.headAngle = angle
        }
        return s
    }
}

extension Shape {
    /// Drills a hole at each centre (points on the face) along `direction`, into the material.
    public func drilled(at centers: [Vec3], direction: Vec3, _ spec: HoleSpec) throws -> Shape {
        let points = centers.map(\.fk)
        var s = spec.fk
        return try Shape.make(
            points.withUnsafeBufferPointer { fk_holes(handle, $0.baseAddress, Int32($0.count), direction.fk, &s) }, "Hole")
    }
}
