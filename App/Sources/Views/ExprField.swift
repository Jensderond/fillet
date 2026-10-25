import FilletCore
import SwiftUI

/// A text field for a dimension expression (`12`, `width / 2 + 3`, `1 in`, `30 deg`).
/// Valid input is pushed live; invalid input shows the reason and is not applied.
struct ExprField: View {
    let label: String
    let value: Expr
    var kind: QuantityKind = .length
    /// Width of the label column; nil lets a short label ("=") hug its text.
    var labelWidth: CGFloat? = 64
    let evaluator: Evaluator
    let onChange: (Expr) -> Void

    @State private var text = ""
    @State private var error: String?
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.touchTargets) private var touch

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: Theme.Space.m) {
                Text(label)
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minWidth: labelWidth, alignment: .leading)
                    .lineLimit(1)
                field
            }
            // The whole row focuses the field, label and the edge of the gaps around it included,
            // so a tap near the field doesn't fall through to a neighbouring control (see `VerticalBleed`).
            .contentShape(VerticalBleed(Theme.Space.xs))
            .onTapGesture { focused = true }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else if !value.isLiteral, let v = try? evaluator.evaluate(value, as: kind) {
                Text("= \(Self.format(v)) \(unit)")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .animation(Theme.Motion.hover, value: error)
        .automationFrame("field.\(label)")
        .onAppear { text = value.source }
        .onChange(of: value) { _, new in if !focused { text = new.source } }
        .onChange(of: text) { _, _ in validate() }
        .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private var field: some View {
        HStack(spacing: Theme.Space.s) {
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.value)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .focused($focused)
                .focusedValue(\.isEditingText, focused ? true : nil)
                .accessibilityLabel(unitName.isEmpty ? label : "\(label), \(unitName)")
                .onSubmit(apply)
            if !unit.isEmpty {
                Text(unit)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: touch ? 44 : 32)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.raised))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(borderColor, lineWidth: focused || error != nil ? 1.5 : 1))
        .shadow(color: focused ? Theme.filletMark.opacity(0.25) : .clear, radius: 4)
        .hoverHighlight(ownsPointerHover: true)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: focused)
    }

    private var borderColor: Color {
        if error != nil { return Theme.danger }
        if focused { return Theme.filletMark }
        return hovering ? Theme.inkTertiary : Theme.fieldBorder
    }

    private var unit: String {
        switch kind {
        case .length: "mm"
        case .angle: "°"
        case .scalar: ""
        }
    }

    private var unitName: String {
        switch kind {
        case .length: "millimetres"
        case .angle: "degrees"
        case .scalar: ""
        }
    }

    private func validate() {
        let expr = Expr(stringLiteral: text.trimmingCharacters(in: .whitespaces))
        do {
            _ = try evaluator.evaluate(expr, as: kind)
            error = nil
            if expr != value { onChange(expr) }
        } catch {
            self.error = text.isEmpty ? nil : error.message
        }
    }

    private func apply() {
        validate()
        if error != nil || text.isEmpty {
            text = value.source
            error = nil
        }
    }

    static func format(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        return r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
    }
}

/// X and Y expression fields for a 2D point.
struct PointField: View {
    let label: String
    let value: Point2Expr
    let evaluator: Evaluator
    let onChange: (Point2Expr) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(label).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
            ExprField(label: "X", value: value.x, evaluator: evaluator) { onChange(Point2Expr($0, value.y)) }
            ExprField(label: "Y", value: value.y, evaluator: evaluator) { onChange(Point2Expr(value.x, $0)) }
        }
    }
}
