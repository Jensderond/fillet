import FilletCore
import SwiftUI

/// A text field for a dimension expression (`12`, `width / 2 + 3`, `1 in`, `30 deg`).
/// Valid input is pushed live; invalid input shows the error and is not applied.
struct ExprField: View {
    let label: String
    let value: Expr
    var kind: QuantityKind = .length
    let evaluator: Evaluator
    let onChange: (Expr) -> Void

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .leading)
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .focused($focused)
                    .onSubmit(apply)
                    .frame(minWidth: 90)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .leading)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if !value.isLiteral, let v = try? evaluator.evaluate(value, as: kind) {
                Text("= \(Self.format(v)) \(unit)").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onAppear { text = value.source }
        .onChange(of: value) { _, new in if !focused { text = new.source } }
        .onChange(of: text) { _, _ in validate(pushIfValid: true) }
        .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private var unit: String {
        switch kind {
        case .length: "mm"
        case .angle: "°"
        case .scalar: ""
        }
    }

    private func validate(pushIfValid: Bool) {
        let expr = Expr(stringLiteral: text.trimmingCharacters(in: .whitespaces))
        do {
            _ = try evaluator.evaluate(expr, as: kind)
            error = nil
            if pushIfValid, expr != value { onChange(expr) }
        } catch {
            self.error = text.isEmpty ? nil : error.message
        }
    }

    private func apply() {
        validate(pushIfValid: true)
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

/// Two expression fields side by side for a 2D point.
struct PointField: View {
    let label: String
    let value: Point2Expr
    let evaluator: Evaluator
    let onChange: (Point2Expr) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            ExprField(label: "X", value: value.x, evaluator: evaluator) { onChange(Point2Expr($0, value.y)) }
            ExprField(label: "Y", value: value.y, evaluator: evaluator) { onChange(Point2Expr(value.x, $0)) }
        }
    }
}
