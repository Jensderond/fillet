import CoreGraphics
import Foundation
import simd
import FilletKernel

/// Orbit camera for a Z-up world (3D-printing convention: Z = up, XY = bed).
///
/// The eye sits on a sphere around `target`: `yaw` rotates around +Z (0 = looking
/// from the front, i.e. from -Y towards +Y), `pitch` is the elevation above the XY
/// plane (+90° = looking straight down). There is no roll.
public struct Camera: Codable, Hashable, Sendable {
    /// Perspective or parallel projection.
    public enum Projection: String, Codable, Sendable, CaseIterable {
        case perspective, orthographic
    }

    /// Named view directions (the camera looks *from* that side).
    public enum StandardView: String, Codable, Sendable, CaseIterable {
        case front, back, left, right, top, bottom, iso

        /// (yaw, pitch) in radians.
        public var angles: (yaw: Double, pitch: Double) {
            switch self {
            case .front: (0, 0)
            case .back: (.pi, 0)
            case .right: (.pi / 2, 0)
            case .left: (-.pi / 2, 0)
            case .top: (0, .pi / 2)
            case .bottom: (0, -.pi / 2)
            case .iso: (.pi / 4, atan(1 / 2.0.squareRoot()))
            }
        }
    }

    /// Point the camera orbits around and looks at.
    public var target: Vec3
    /// Distance from the eye to `target` in mm (also sets the orthographic scale).
    public var distance: Double
    /// Rotation around +Z in radians.
    public var yaw: Double
    /// Elevation in radians, clamped to [-π/2, π/2].
    public var pitch: Double
    public var projection: Projection
    /// Vertical field of view in degrees (orthographic uses it to derive the view height at `distance`).
    public var fovDegrees: Double

    public init(target: Vec3 = .zero, distance: Double = 300, yaw: Double = StandardView.iso.angles.yaw,
                pitch: Double = StandardView.iso.angles.pitch, projection: Projection = .perspective,
                fovDegrees: Double = 30) {
        self.target = target
        self.distance = distance
        self.yaw = yaw
        self.pitch = pitch
        self.projection = projection
        self.fovDegrees = fovDegrees
    }

    /// Isometric view of the origin from 300 mm.
    public static let `default` = Camera()

    /// Smallest / largest allowed `distance`.
    public static let distanceRange: ClosedRange<Double> = 0.5...200_000

    /// Rays of an orthographic camera start this far behind the view plane so they
    /// cover geometry behind the eye.
    static let orthoRayBackoff = 10_000.0

    // MARK: Basis

    var fovRadians: Double { fovDegrees * .pi / 180 }

    /// Unit vector from the target towards the eye.
    public var back: Vec3 {
        Vec3(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
    }

    /// Viewing direction (from the eye towards the target).
    public var forward: Vec3 { -back }

    /// Screen-up direction in world space.
    public var up: Vec3 {
        Vec3(-sin(yaw) * sin(pitch), cos(yaw) * sin(pitch), cos(pitch))
    }

    /// Screen-right direction in world space.
    public var right: Vec3 { up.cross(back) }

    /// Eye position in world space.
    public var eye: Vec3 { target + back * distance }

    /// Half the visible height (mm) of the view plane at `depth` along the view direction.
    public func halfHeight(atDepth depth: Double) -> Double {
        switch projection {
        case .perspective: max(depth, 1e-6) * tan(fovRadians / 2)
        case .orthographic: distance * tan(fovRadians / 2)
        }
    }

    /// Size of one screen point in mm at the depth of `point` (or of the target).
    public func worldUnitsPerPoint(at point: Vec3? = nil, viewSize: CGSize) -> Double {
        let depth = point.map { ($0 - eye).dot(forward) } ?? distance
        return 2 * halfHeight(atDepth: depth) / max(Double(viewSize.height), 1)
    }

    /// View-space depth of a point (distance along `forward` from the eye).
    public func depth(of p: Vec3) -> Double { (p - eye).dot(forward) }

    // MARK: Matrices

    /// World → view matrix (right-handed, camera looks down -Z).
    public var viewMatrix: simd_float4x4 { Mat.float(viewMatrixD) }

    var viewMatrixD: simd_double4x4 {
        Mat.lookAt(eye: eye.simd, right: right.simd, up: up.simd, back: back.simd)
    }

    /// Near/far clip distances covering `bounds` (and the ground grid around the target).
    func clipRange(bounds: Bounds3?) -> (near: Double, far: Double) {
        var lo = distance * 0.5, hi = distance * 6
        if let b = bounds {
            let zc = depth(of: b.center)
            let r = max(b.radius, 1)
            lo = min(lo, zc - r)
            hi = max(hi, zc + r)
        }
        switch projection {
        case .perspective:
            return (max(max(lo * 0.9, distance * 0.01), 0.01), hi * 1.1 + 1)
        case .orthographic:
            let margin = max(distance, 10)
            return (lo - margin, hi + margin)
        }
    }

    /// View → clip matrix for the given aspect ratio (width / height).
    public func projectionMatrix(aspect: Double, bounds: Bounds3? = nil) -> simd_float4x4 {
        Mat.float(projectionMatrixD(aspect: aspect, bounds: bounds))
    }

    func projectionMatrixD(aspect: Double, bounds: Bounds3?) -> simd_double4x4 {
        let (n, f) = clipRange(bounds: bounds)
        let a = max(aspect, 1e-6)
        switch projection {
        case .perspective:
            return Mat.perspective(fovY: fovRadians, aspect: a, near: n, far: f)
        case .orthographic:
            let hh = halfHeight(atDepth: distance)
            return Mat.orthographic(halfWidth: hh * a, halfHeight: hh, near: n, far: f)
        }
    }

    // MARK: Rays & projection

    /// The pick ray through a point in view coordinates (points, origin top-left).
    public func ray(at point: CGPoint, viewSize: CGSize) -> Ray {
        let w = max(Double(viewSize.width), 1), h = max(Double(viewSize.height), 1)
        let nx = 2 * Double(point.x) / w - 1
        let ny = 1 - 2 * Double(point.y) / h
        let aspect = w / h
        switch projection {
        case .perspective:
            let t = tan(fovRadians / 2)
            let dir = forward + right * (nx * t * aspect) + up * (ny * t)
            return Ray(origin: eye, direction: dir)
        case .orthographic:
            let hh = halfHeight(atDepth: distance)
            let o = eye + right * (nx * hh * aspect) + up * (ny * hh) + back * Self.orthoRayBackoff
            return Ray(origin: o, direction: forward)
        }
    }

    /// Projects a world point to view coordinates (points, origin top-left).
    /// Nil when the point is behind a perspective camera.
    public func project(_ p: Vec3, viewSize: CGSize) -> CGPoint? {
        let w = Double(viewSize.width), h = Double(viewSize.height)
        guard w > 0, h > 0 else { return nil }
        let rel = p - eye
        let x = rel.dot(right), y = rel.dot(up), z = rel.dot(forward)
        let hh: Double
        switch projection {
        case .perspective:
            guard z > 1e-9 else { return nil }
            hh = z * tan(fovRadians / 2)
        case .orthographic:
            hh = halfHeight(atDepth: distance)
        }
        let nx = x / (hh * w / h), ny = y / hh
        return CGPoint(x: (nx + 1) * 0.5 * w, y: (1 - ny) * 0.5 * h)
    }

    // MARK: Navigation

    /// Rotates the view by the given angles (radians). With a `pivot`, the pivot keeps
    /// its screen position (orbit around the point under the cursor).
    public mutating func orbit(deltaYaw: Double, deltaPitch: Double, pivot: Vec3? = nil) {
        let r0 = right, u0 = up, b0 = back, e0 = eye
        yaw = Self.wrapAngle(yaw + deltaYaw)
        pitch = min(max(pitch + deltaPitch, -.pi / 2), .pi / 2)
        guard let p = pivot else { return }
        let rel = p - e0
        let c = (rel.dot(r0), rel.dot(u0), rel.dot(b0))
        let newEye = p - (right * c.0 + up * c.1 + back * c.2)
        target = newEye - back * distance
    }

    /// Orbits by a drag of `translation` points (0.3° per point).
    public mutating func orbit(drag translation: CGSize, pivot: Vec3? = nil) {
        let k = 0.3 * Double.pi / 180
        orbit(deltaYaw: -Double(translation.width) * k, deltaPitch: Double(translation.height) * k, pivot: pivot)
    }

    /// Moves the camera parallel to the view plane so that content follows a drag of
    /// `translation` points. `depthPoint` sets the depth at which motion is 1:1.
    public mutating func pan(translation: CGSize, viewSize: CGSize, depthPoint: Vec3? = nil) {
        let wpp = worldUnitsPerPoint(at: depthPoint, viewSize: viewSize)
        target = target - right * (Double(translation.width) * wpp) + up * (Double(translation.height) * wpp)
    }

    /// Scales the distance by `factor` (< 1 zooms in) keeping `anchor` fixed on screen.
    public mutating func zoom(factor: Double, anchor: Vec3? = nil) {
        let newDistance = min(max(distance * factor, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        let f = newDistance / distance
        if let a = anchor {
            target = a + (target - a) * f
        }
        distance = newDistance
    }

    /// Zooms towards the point under `location`: `anchor` if provided (e.g. a geometry
    /// hit), else the intersection with the plane through the target facing the camera.
    public mutating func zoom(factor: Double, at location: CGPoint, viewSize: CGSize, anchor: Vec3? = nil) {
        var a = anchor
        if a == nil {
            let plane = Plane(origin: target, normal: back, xDir: right)
            a = ray(at: location, viewSize: viewSize).intersect(plane)
        }
        zoom(factor: factor, anchor: a)
    }

    // MARK: Views

    /// Sets yaw/pitch to a standard view (target and distance unchanged).
    public mutating func setView(_ view: StandardView) {
        (yaw, pitch) = view.angles
    }

    /// Copy looking from a standard view.
    public func viewing(_ view: StandardView) -> Camera {
        var c = self
        c.setView(view)
        return c
    }

    /// Centres `bounds` and sets the distance so it fills the view (with a small margin).
    public mutating func fit(bounds: Bounds3, aspect: Double = 1, margin: Double = 1.1) {
        let r = max(bounds.radius, 0.5)
        let fovV = fovRadians
        let fovH = 2 * atan(tan(fovV / 2) * max(aspect, 1e-3))
        let f = min(fovV, fovH)
        target = bounds.center
        distance = min(max(r / sin(f / 2) * margin, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
    }

    /// Copy fitted to `bounds`.
    public func fitted(to bounds: Bounds3, aspect: Double = 1, margin: Double = 1.1) -> Camera {
        var c = self
        c.fit(bounds: bounds, aspect: aspect, margin: margin)
        return c
    }

    /// Camera looking straight at a plane from its normal side (used when entering
    /// sketch mode). Keeps the current distance unless one is given; the screen-up
    /// direction follows the plane's y axis when the plane is horizontal.
    public func looking(at plane: Plane, distance: Double? = nil, center: Vec3? = nil) -> Camera {
        var c = self
        let n = plane.normal
        let pitch = asin(min(max(n.z, -1), 1))
        var yaw: Double
        if abs(n.z) > 0.999 {
            // Horizontal plane: choose yaw so screen-up aligns with the plane's y axis.
            let y = plane.yDir
            // up at pitch = ±90°: (∓sin(yaw), ±cos(yaw), 0)
            yaw = n.z > 0 ? atan2(-y.x, y.y) : atan2(y.x, -y.y)
        } else {
            // back = (sin(yaw) cos(p), -cos(yaw) cos(p), sin(p)) == n
            yaw = atan2(n.x, -n.y)
        }
        c.yaw = Self.wrapAngle(yaw)
        c.pitch = pitch
        c.target = center ?? plane.origin
        if let d = distance { c.distance = d }
        return c
    }

    /// Interpolates two cameras (shortest yaw path, log-scaled distance).
    public static func interpolate(_ a: Camera, _ b: Camera, t: Double) -> Camera {
        var c = b
        let dy = wrapAngle(b.yaw - a.yaw)
        c.yaw = wrapAngle(a.yaw + dy * t)
        c.pitch = lerp(a.pitch, b.pitch, t)
        c.distance = exp(lerp(log(a.distance), log(b.distance), t))
        c.target = a.target + (b.target - a.target) * t
        c.fovDegrees = lerp(a.fovDegrees, b.fovDegrees, t)
        c.projection = t < 0.5 ? a.projection : b.projection
        return c
    }

    /// Whether two cameras are visually the same.
    public func isApproximatelyEqual(to o: Camera, tolerance: Double = 1e-6) -> Bool {
        abs(Self.wrapAngle(yaw - o.yaw)) < tolerance && abs(pitch - o.pitch) < tolerance
            && abs(distance - o.distance) < tolerance * max(distance, 1)
            && target.distance(to: o.target) < tolerance * max(distance, 1)
            && projection == o.projection && abs(fovDegrees - o.fovDegrees) < tolerance
    }

    static func wrapAngle(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x < -.pi { x += 2 * .pi }
        return x
    }
}
