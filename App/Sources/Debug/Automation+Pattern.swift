#if DEBUG
import FilletCore
import FilletKernel
import Foundation
#if os(iOS)
import UIKit
#endif

extension DebugAutomation {
    /// Feature pattern, on its own (`FILLET_SCENARIO=featurePattern`): an 80 × 30 × 10 plate with
    /// a Ø8 cut through it, then Pattern switched to Features. The steps are picked by activating
    /// the timeline stations and inspector buttons like VoiceOver does (the views' own actions),
    /// so the timeline's picker code runs: the cut joins, a second extrude joins and is taken out
    /// with its × in the inspector, a sketch is refused with a toast. Four cuts 20 mm apart are
    /// committed and checked by volume; then the station's context-menu Pattern starts one.
    ///
    /// SwiftUI only builds its accessibility tree with accessibility on, so turn it on in the
    /// simulator first (`xcrun simctl spawn <udid> defaults write com.apple.Accessibility
    /// ApplicationAccessibilityEnabled -bool true`); without it each press logs "no element" and
    /// calls the session directly, which skips the views' actions.
    static func featurePatternScenario(_ session: DesignSession) async {
        let plate = 80.0 * 30 * 10, cut = Double.pi * 16 * 10
        func volume() -> Double { session.model.bodies.reduce(0) { $0 + $1.shape.volume } }
        func picked() -> [UUID] { session.editingFeaturePattern?.pattern.features ?? [] }
        func step(_ name: String) -> (index: Int, id: UUID)? {
            session.document.features.firstIndex { $0.name == name }.map { ($0, session.document.features[$0].id) }
        }
        /// A tap on a timeline station or an inspector button, through the view's own action.
        func press(_ label: String, else fallback: () -> Void) async {
            if !activate(label) {
                log("no element \"\(label)\"; calling the session instead")
                fallback()
            }
            await settle(session)
        }

        // Sketch 1 → Extrude 1: the plate.
        session.startSketch(on: .xy)
        await settle(session)
        session.sketchEditor?.engine.setTool(.rectangle)
        tap(session, SIMD2(0, 0))
        tap(session, SIMD2(80, 30))
        await settle(session)
        session.startExtrude()
        session.updateEditing { f in if case .extrude(var e) = f.kind { e.distance = 10; f.kind = .extrude(e) } }
        await settle(session)
        session.commitEdit()
        // Sketch 2 → Extrude 2: a Ø8 hole cut up through it at x 10.
        session.startSketch(on: .xy)
        await settle(session)
        session.sketchEditor?.engine.setTool(.circle)
        tap(session, SIMD2(10, 15))
        tap(session, SIMD2(14, 15))
        await settle(session)
        session.startExtrude()
        session.updateEditing { f in if case .extrude(var e) = f.kind { e.operation = .cut; e.distance = 10; f.kind = .extrude(e) } }
        await settle(session)
        session.commitEdit()
        await settle(session)
        check(abs(volume() - (plate - cut)) < 0.01 && session.failedFeatures.isEmpty,
              "plate with one cut: \(volume()) ≈ \(plate - cut)")
        guard let sketch2 = step("Sketch 2"), let extrude1 = step("Extrude 1"), let extrude2 = step("Extrude 2") else {
            check(false, "the four steps exist: \(session.document.features.map(\.name))"); return
        }
        await snap(session, "p01-plate")

        // Pattern starts on bodies; Objects → Features hands the picking to the timeline.
        session.startPattern()
        await settle(session)
        check(session.pickMode == .bodies && session.editingFeaturePattern == nil, "Pattern starts as a body pattern")
        await press("Features") {
            session.updateEditing { f in
                if case .pattern(var p) = f.kind { p.objects = .features; p.bodies = []; f.kind = .pattern(p) }
            }
        }
        check(session.editingFeaturePattern != nil && picked().isEmpty && session.pickMode == .idle,
              "Objects → Features: nothing picked, no body picking in the viewport")
        let empty = session.model.error(for: session.editing?.feature ?? UUID())
        check(empty?.contains("Pick at least one step") == true, "an empty feature pattern asks for steps (\(empty ?? "no error"))")
        await snap(session, "p02-features-empty")

        // Tap the cut's station: it joins (count 3 × 20 mm by default).
        await press("Step \(extrude2.index + 1), Extrude 2") { session.toggleEditingPatternFeature(extrude2.id) }
        check(picked() == [extrude2.id], "tapping Extrude 2 on the timeline picks it")
        check(abs(volume() - (plate - 3 * cut)) < 0.01 && session.model.bodies.count == 1,
              "three cuts: \(volume()) ≈ \(plate - 3 * cut), \(session.model.bodies.count) body")
        await snap(session, "p03-cut-picked")

        // A sketch can't be repeated: the pick is refused with a toast.
        session.message = nil
        await press("Step \(sketch2.index + 1), Sketch 2") { session.toggleEditingPatternFeature(sketch2.id) }
        check(picked() == [extrude2.id] && session.message?.text.contains("Sketch 2 can't be patterned") == true,
              "tapping Sketch 2 is refused: \(session.message?.text ?? "no toast")")
        await snap(session, "p04-sketch-refused")

        // A new-body extrude joins too (its copies are new bodies); its × in the list takes it out.
        await press("Step \(extrude1.index + 1), Extrude 1") { session.toggleEditingPatternFeature(extrude1.id) }
        check(picked() == [extrude2.id, extrude1.id] && session.model.bodies.count == 3,
              "Extrude 1 joins: \(picked().count) steps, \(session.model.bodies.count) bodies")
        await snap(session, "p05-two-picked")
        await press("Remove Extrude 1") {
            session.updateEditing { f in if case .pattern(var p) = f.kind { p.features.removeAll { $0 == extrude1.id }; f.kind = .pattern(p) } }
        }
        check(picked() == [extrude2.id] && session.model.bodies.count == 1, "its × takes Extrude 1 out again")

        // Four cuts 20 mm apart, committed.
        session.updateEditing { f in
            if case .pattern(var p) = f.kind { p.layout = .linear(direction: .x, count: 4, spacing: 20); f.kind = .pattern(p) }
        }
        await settle(session)
        check(abs(volume() - (plate - 4 * cut)) < 0.01 && session.model.bodies.count == 1,
              "four cuts: \(volume()) ≈ \(plate - 4 * cut)")
        await snap(session, "p06-four-cuts")
        let pattern = session.editing?.feature
        session.commitEdit()
        await settle(session)
        check(pattern.map { session.model.status[$0] == .ok } == true && session.failedFeatures.isEmpty,
              "Pattern 1 committed and ok")
        check(abs(volume() - (plate - 4 * cut)) < 0.01, "committed volume \(volume())")
        await snap(session, "p07-committed")

        // The station's context menu: Pattern refuses a sketch and starts one on an extrude.
        session.message = nil
        session.startIfAvailable(.pattern) { session.startPattern(features: [sketch2.id]) }
        check(session.editing == nil && session.message?.text.contains("can't be patterned") == true,
              "context-menu Pattern on Sketch 2 is refused: \(session.message?.text ?? "no toast")")
        session.startIfAvailable(.pattern) { session.startPattern(features: [extrude2.id]) }
        await settle(session)
        check(picked() == [extrude2.id] && session.editingFeature?.name == "Pattern 2" && session.failedFeatures.isEmpty,
              "context-menu Pattern on Extrude 2 starts Pattern 2 with it picked")
        await snap(session, "p08-context-menu-pattern")
        // Another pattern can't join it.
        session.message = nil
        if let p1 = pattern { session.toggleEditingPatternFeature(p1) }
        check(picked() == [extrude2.id] && session.message != nil, "Pattern 1 can't join: \(session.message?.text ?? "no toast")")
        session.cancelEdit()
        await settle(session)
        check(session.document.features.count == 5, "cancel drops Pattern 2")
    }

    /// Activates the element on screen with this accessibility label, the way VoiceOver does, so
    /// the control's own action runs. False when there's no such element.
    static func activate(_ label: String) -> Bool {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 60 else { return nil }
            if object.isAccessibilityElement, object.accessibilityLabel == label { return object }
            var children: [NSObject] = (object.accessibilityElements as? [NSObject]) ?? []
            if children.isEmpty, object.accessibilityElementCount() != NSNotFound {
                children = (0..<max(object.accessibilityElementCount(), 0)).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = object as? UIView { children += view.subviews }
            for child in children { if let hit = find(child, depth: depth + 1) { return hit } }
            return nil
        }
        for window in windows { if let element = find(window, depth: 0) { return element.accessibilityActivate() } }
        #endif
        return false
    }
}
#endif
