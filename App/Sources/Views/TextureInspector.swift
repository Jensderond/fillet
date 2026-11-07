import CoreGraphics
import FilletCore
import SwiftUI
import simd

/// Inspector of a texture step: the faces it covers, a pattern picker with a lit swatch of each
/// pattern, and the pattern's values. Everything pattern-specific comes from ``TextureCatalog``
/// (names, swatches, parameter fields, defaults), so a pattern added there shows up here as is.
struct TextureInspector: View {
    @Bindable var session: DesignSession
    let texture: Texture

    private var ev: Evaluator { session.model.parameters.evaluator }

    private func set(_ t: Texture) { session.updateEditing { $0.kind = .texture(t) } }

    private var commonIDs: Set<String> { Set(TextureCatalog.common.map { $0.id }) }

    var body: some View {
        let t = texture
        let parameters = TextureCatalog.parameters(for: t.pattern)
        let resolved = (try? TextureCatalog.resolve(t, using: ev)) ?? TextureValues()
        faces(t)
        Labeled("Pattern") {
            PatternGrid(selection: t.pattern, values: resolved) { id in
                var x = t
                x.pattern = id
                // Values the new pattern shares (the border fade, raised) carry over; the rest start at its defaults.
                let ids = Set(TextureCatalog.parameters(for: id).map { $0.id })
                x.values = x.values.filter { ids.contains($0.key) }
                set(x)
            }
        }
        // On the label's line, where the eyes are while tuning; an overlay, so nothing below moves.
        .overlay(alignment: .topTrailing) { TextureUpdating(shown: session.isEditedTextureUpdating) }
        if let p = TextureCatalog.pattern(t.pattern) {
            Hint(p.summary, symbol: "info.circle")
        } else {
            Hint("The “\(t.pattern)” pattern comes from a newer version of Fillet. Pick one above to replace it.",
                 symbol: "exclamationmark.triangle")
        }
        let own = parameters.filter { !commonIDs.contains($0.id) }
        // Choices that change what the relief looks like (a dot's profile) come first, as lit
        // tiles like the patterns', since they decide the look more than any number below. A
        // value that belongs to one of them (a flat disc's rim rounding) sits right under it.
        let looks = own.filter { TextureSwatch.showsAsTiles($0, t.pattern, resolved) }
        ForEach(looks) { param in
            look(param, t, resolved)
            ForEach(dependents(of: param, in: own, resolved)) { dependent($0, t) }
        }
        let lookIDs = Set(looks.map { $0.id })
        // Every other value in declaration order, each followed by the ones that depend on it;
        // values that belong to a look were shown with it, and ones that don't apply now are left out.
        let ownIDs = Set(own.map { $0.id })
        let rest = own.filter { p in
            !lookIDs.contains(p.id) && (p.shownWhen.map { !ownIDs.contains($0.parameter) } ?? true)
        }
        let fade = TextureCatalog.fadesAtBorders(t.pattern, resolved)
            ? parameters.filter { commonIDs.contains($0.id) } : []
        if !rest.isEmpty || !fade.isEmpty {
            Text("Size and shape").font(Theme.sectionTitle).foregroundStyle(Theme.ink).padding(.top, Theme.Space.xs)
            ForEach(rest) { param in
                field(param, t)
                ForEach(dependents(of: param, in: own, resolved)) { dependent($0, t) }
            }
            ForEach(fade) { field($0, t) }
        }
        if t.values.contains(where: { key, value in
            parameters.first { $0.id == key }.map { value != Expr($0.defaultValue) } ?? false
        }) {
            Button {
                var x = t; x.values = [:]; set(x)
            } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise") }
            .buttonStyle(SecondaryButtonStyle())
        }
        Hint("The texture is part of the printed mesh (3MF and STL export), not the solid, so later steps work on the plain body.",
             symbol: "printer")
        Hint("Keep details at least 0.8 mm across and 0.3 mm deep so a 0.4 mm nozzle shows them.")
    }

    // MARK: Faces

    @ViewBuilder private func faces(_ t: Texture) -> some View {
        let sides = session.textureSideFaces(of: t.body)
        let onSides = !sides.isEmpty && Set(sides) == Set(t.faces)
        SelectionCount(count: t.faces.count, noun: "face", plural: "faces",
                       hint: t.faces.isEmpty ? "None picked: every face but the bed face. \(Theme.Copy.pick) faces to texture only those."
                           : onSides ? "The outer sides. \(Theme.Copy.pick) faces to add or drop them."
                           : "\(Theme.Copy.pick) faces to add or drop them.") {
            var x = t; x.faces = []; set(x)
        }
        Labeled("Cover") {
            let options: [(Int, String)] = [(0, "Sides"), (1, "All but bed")] + (t.faces.isEmpty || onSides ? [] : [(2, "Picked")])
            ThemeSegmented("Cover", selection: t.faces.isEmpty ? 1 : onSides ? 0 : 2, options: options) { mode in
                switch mode {
                case 0: session.setTextureFaces(sides)
                case 1: session.setTextureFaces([])
                default: break
                }
            }
        }
    }

    /// The parameters that only apply with certain values of `param`, while they apply.
    private func dependents(of param: TextureParameter, in all: [TextureParameter],
                            _ resolved: TextureValues) -> [TextureParameter] {
        all.filter { $0.shownWhen?.parameter == param.id && $0.shownWhen?.holds(resolved) == true }
    }

    /// A value that refines the one above it, with its help line under it, since it only
    /// shows for some choices and should say what it does there.
    @ViewBuilder private func dependent(_ param: TextureParameter, _ t: Texture) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            field(param, t)
            if !param.help.isEmpty, param.kind != .toggle {
                Text(param.help).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }

    // MARK: Looks

    /// A choice parameter as one lit close-up tile per option, the step's other values kept.
    @ViewBuilder private func look(_ param: TextureParameter, _ t: Texture, _ resolved: TextureValues) -> some View {
        if case .choice(let options) = param.kind {
            let current = Int((try? ev.scalar(t.value(param.id) ?? Expr(param.defaultValue))) ?? param.defaultValue)
            Labeled(param.name) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 60, maximum: 140), spacing: Theme.Space.s),
                                         count: options.count),
                          alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(options.indices, id: \.self) { i in
                        SwatchTile(pattern: t.pattern, values: resolved.setting(param.id, Double(i)), closeUp: true, title: options[i],
                                   selected: i == current, compact: true) {
                            var x = t; x.values[param.id] = Expr(Double(i)); set(x)
                        }
                        .automationFrame("look.\(param.id).\(i)")
                    }
                }
            }
            .help(param.help)
        }
    }

    // MARK: Values

    @ViewBuilder private func field(_ param: TextureParameter, _ t: Texture) -> some View {
        let value = t.value(param.id) ?? Expr(param.defaultValue)
        let update = { (e: Expr) in var x = t; x.values[param.id] = e; set(x) }
        switch param.kind {
        case .toggle:
            TextureToggle(param: param, isOn: ((try? ev.scalar(value)) ?? param.defaultValue) >= 0.5) { update($0 ? 1 : 0) }
        case .choice(let options):
            let current = Int((try? ev.scalar(value)) ?? param.defaultValue)
            Labeled(param.name) {
                if options.count <= 3 {
                    ThemeSegmented(param.name, selection: current, options: options.indices.map { ($0, options[$0]) }) {
                        update(Expr(Double($0)))
                    }
                } else {
                    Picker(param.name, selection: Binding(get: { current }, set: { update(Expr(Double($0))) })) {
                        ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                    }
                }
            }
            .help(param.help)
        case .length, .angle, .count, .number:
            ExprField(label: param.name, value: value, kind: param.quantity, labelWidth: 112, evaluator: ev,
                      range: param.range, onChange: update)
                .help(param.helpWithRange)
        }
    }
}

extension TextureParameter {
    /// The help line with the values the field takes ("… (0 to 10 mm)").
    @MainActor var helpWithRange: String {
        let unit = kind == .length ? " mm" : kind == .angle ? "°" : ""
        let bounds = "\(ExprField.format(range.lowerBound)) to \(ExprField.format(range.upperBound))\(unit)"
        return help.isEmpty ? bounds : "\(help) (\(bounds))"
    }

    /// How its expression field reads input.
    var quantity: QuantityKind {
        switch kind {
        case .length: .length
        case .angle: .angle
        default: .scalar
        }
    }
}

/// "Updating texture…" with a spinner while the step's relief is being rebuilt: until it lands the
/// viewport shows the previous one, which a new profile or size mustn't be mistaken for.
private struct TextureUpdating: View {
    let shown: Bool

    var body: some View {
        ZStack {
            if shown {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().controlSize(.mini)
                    Text("Updating texture…")
                }
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Updating texture")
                .automationMarker("texture-updating")
                .transition(.opacity)
            }
        }
        .animation(shown ? Theme.Motion.enter : Theme.Motion.exit, value: shown)
    }
}

/// An on/off value with its explanation under the name, like the tangent chain switch.
private struct TextureToggle: View {
    let param: TextureParameter
    let isOn: Bool
    let onChange: (Bool) -> Void
    @Environment(\.touchTargets) private var touch

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(param.name).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
                if !param.help.isEmpty {
                    Text(param.help).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.switchOn)
        .frame(minHeight: Theme.Metrics.target(touch: touch))
        .automationFrame("field.\(param.name)")
    }
}

// MARK: - Pattern picker

/// Every pattern in the catalogue as a tile with a lit swatch of its relief. The chosen one shows
/// the step's own values (slant, spacing, raised or recessed), the others their defaults.
private struct PatternGrid: View {
    let selection: TexturePatternID
    let values: TextureValues
    let choose: (TexturePatternID) -> Void

    var body: some View {
        let ids = TextureCatalog.patterns.map { $0.id }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 140), spacing: Theme.Space.s)],
                  alignment: .leading, spacing: Theme.Space.s) {
            ForEach(ids, id: \.self) { id in
                SwatchTile(pattern: id, values: id == selection ? values : TextureValues(), closeUp: false,
                           title: TextureCatalog.pattern(id)?.displayName ?? id.rawValue, selected: id == selection) { choose(id) }
                .automationFrame("pattern.\(id.rawValue)")
                .help(TextureCatalog.pattern(id)?.summary ?? id.rawValue)
            }
        }
    }
}

/// A lit swatch with a name under it and a scale bar on it, chosen or not: the pattern tiles
/// and the tiles of a choice such as a dot's profile.
private struct SwatchTile: View {
    let pattern: TexturePatternID
    let values: TextureValues
    /// One repeat up close (a single dot) instead of a few repeats.
    let closeUp: Bool
    let title: String
    let selected: Bool
    var compact = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let radius = Theme.Radius.control + 2
        Button(action: action) {
            VStack(spacing: compact ? Theme.Space.xs : Theme.Space.xs + 2) {
                Group {
                    if let image = TextureSwatch.image(pattern, values, closeUp: closeUp, dark: colorScheme == .dark) {
                        Image(decorative: image, scale: 2).resizable().interpolation(.high)
                    } else {
                        Theme.hairline
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if let span = TextureSwatch.span(pattern, values, closeUp: closeUp) { ScaleBar(span: span) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous))
                Text(title)
                    .font((compact ? Theme.caption : Theme.body).weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(Theme.Space.xs + 1)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selected ? Theme.raised : Theme.raised.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected ? Theme.ink : Theme.hairlineStrong, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(PressableTileStyle())
        .hoverHighlight(cornerRadius: radius)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Theme.Motion.hover, value: selected)
    }
}

/// A round length ("2 cm", "5 mm") drawn to scale along the bottom of a swatch `span` mm across,
/// so a swatch says how big its dots or stitches are.
private struct ScaleBar: View {
    let span: Double

    var body: some View {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 20, 50, 100, 200]
        let length = steps.last { $0 <= span * 0.45 } ?? steps[0]
        let label = length >= 10 ? "\(Self.format(length / 10)) cm" : "\(Self.format(length)) mm"
        GeometryReader { g in
            let w = g.size.width * length / span
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.62))
                Capsule().fill(Color.black.opacity(0.55)).frame(width: w, height: 2)
            }
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.55)))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

private struct PressableTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// A pattern's relief as a small lit image (a few repeats, or one up close), shaded by a light
/// from the top left, in the viewport's model colour.
@MainActor
enum TextureSwatch {
    private static var cache: [String: CGImage] = [:]
    static let pixels = 144

    /// Millimetres across a swatch: two of the repeat's shorter side (a few dots, a couple of
    /// stitches), or one repeat up close. Nil for an unknown pattern.
    static func span(_ id: TexturePatternID, _ values: TextureValues, closeUp: Bool) -> Double? {
        guard let p = TextureCatalog.make(id, values) else { return nil }
        let short = min(p.cell.x, p.cell.y)
        guard short > 0 else { return nil }
        return closeUp ? short : 2 * short
    }

    /// Whether a parameter is a choice whose options each look different enough to show as
    /// tiles (2 to 4 options, every swatch distinct at the pattern's defaults, so the row stays
    /// put while values change). Cached per pattern and parameter.
    static func showsAsTiles(_ param: TextureParameter, _ id: TexturePatternID, _ values: TextureValues) -> Bool {
        guard case .choice(let options) = param.kind, (2...4).contains(options.count) else { return false }
        let key = "\(id.rawValue)|\(param.id)"
        if let hit = distinct[key] { return hit }
        let swatches = options.indices.map { i in
            TextureCatalog.swatch(id, TextureValues().setting(param.id, Double(i)), size: 24, cells: 1)
        }
        var ok = swatches.allSatisfy { $0.count == 24 * 24 }
        for a in swatches.indices where ok {
            for b in swatches.indices where b > a {
                let diff = zip(swatches[a], swatches[b]).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
                if diff < 0.05 { ok = false }
            }
        }
        distinct[key] = ok
        return ok
    }

    private static var distinct: [String: Bool] = [:]

    private static func valuesKey(_ values: TextureValues) -> String {
        values.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    static func image(_ id: TexturePatternID, _ values: TextureValues, closeUp: Bool = false, dark: Bool) -> CGImage? {
        let key = "\(id.rawValue)|\(dark)|\(closeUp)|" + valuesKey(values)
        if let hit = cache[key] { return hit }
        let n = pixels
        guard let span = span(id, values, closeUp: closeUp), let p = TextureCatalog.make(id, values) else { return nil }
        let heights = TextureCatalog.swatch(id, values, size: n, cells: span / max(p.cell.x, p.cell.y))
        guard heights.count == n * n else { return nil }
        // Rows run from v = 0 (bottom) up; the image's first row is its top.
        func h(_ i: Int, _ j: Int) -> Float { heights[min(max(j, 0), n - 1) * n + min(max(i, 0), n - 1)] }
        let light = simd_normalize(SIMD3<Float>(-0.55, 0.65, 0.75))
        let relief = Float(n) / 18
        let base: SIMD3<Float> = dark ? SIMD3(0.80, 0.78, 0.74) : SIMD3(0.86, 0.83, 0.79)
        var rgba = [UInt8](repeating: 255, count: n * n * 4)
        for j in 0..<n {
            for i in 0..<n {
                let dx = (h(i + 1, j) - h(i - 1, j)) * relief / 2
                let dy = (h(i, j + 1) - h(i, j - 1)) * relief / 2
                let normal = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                let diffuse = max(simd_dot(normal, light), 0)
                // A little darker in the valleys, like ambient occlusion.
                let occlusion = 0.82 + 0.18 * h(i, j)
                let c = simd_clamp(base * (0.32 + 0.78 * diffuse) * occlusion, .zero, SIMD3(repeating: 1))
                let o = ((n - 1 - j) * n + i) * 4
                rgba[o] = UInt8(c.x * 255); rgba[o + 1] = UInt8(c.y * 255); rgba[o + 2] = UInt8(c.z * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
            let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

extension TextureValues {
    /// These values with one changed.
    func setting(_ id: String, _ value: Double) -> TextureValues {
        var v = self; v.values[id] = value; return v
    }
}
