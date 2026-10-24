import SwiftUI

extension Theme {
    /// Engineering paper, the app icon's background (dark: the icon's dark variant).
    static let paper = Color(light: 0xF5EFE0, dark: 0x14203A)
    /// Blue-green graph-paper ruling on `paper`.
    static let paperRule = Color(light: 0x4F8FB0, dark: 0x8FB6D8)
}

extension Theme.Motion {
    /// The control points behind `Theme.Motion`'s animations, as curves that can be
    /// evaluated at any progress. Time-driven motion (the launch splash) samples
    /// these directly instead of handing an `Animation` to SwiftUI.
    enum Curve {
        /// Strong ease-out, the curve of `enter`, `exit` and `press`.
        static let easeOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.23, y: 1),
                                              endControlPoint: UnitPoint(x: 0.32, y: 1))
        /// Strong ease-in-out, the curve of `move`.
        static let easeInOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.77, y: 0),
                                                endControlPoint: UnitPoint(x: 0.175, y: 1))
        /// iOS-like drawer curve (Ionic): a gentler ease-out for long strokes.
        static let drawer = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.32, y: 0.72),
                                             endControlPoint: UnitPoint(x: 0, y: 1))
    }
}
