import SwiftUI

/// The notices for the open-source software inside Fillet. Open CASCADE's LGPL 2.1 asks for its
/// licence text and a way to get its source and rebuild it; its exception asks for prominent notice
/// that Fillet uses it. Mac: Fillet ▸ Acknowledgements (a window). iPad: the launch screen, or
/// Fillet ▸ Acknowledgements in the menu bar (a sheet).
struct AcknowledgementsView: View {
    static let windowID = "acknowledgements"

    /// Fillet's GitHub project, where the OCCT build script and patches live.
    private static let project = URL(string: "https://github.com/Jensderond/fillet")!
    private static let occtSource = URL(string: "https://github.com/Open-Cascade-SAS/OCCT/tree/V8_0_1")!
    private static let buildScript = project.appending(path: "blob/master/scripts/build-occt.sh")
    private static let patches = project.appending(path: "tree/master/scripts/occt-patches")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                // TODO: Fillet's own licence. The owner hasn't chosen one yet; once they have, say
                // so here (and bundle its text) ahead of the third-party notices.
                occt
                LicenceText(.lgpl)
                LicenceText(.exception)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
        .tint(Theme.filletInk)
        .dynamicTypeSize(...Theme.TypeLimit.panel)
        .navigationTitle("Acknowledgements")
    }

    private var occt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Open CASCADE Technology").font(Theme.title).foregroundStyle(Theme.ink)
            Group {
                Text("Fillet uses Open CASCADE Technology 8.0.1, licensed under the GNU Lesser General Public License version 2.1 with the Open CASCADE exception. Fillet links it as a separate dynamic framework (OCCT.framework) that can be replaced.")
                Text("Fillet builds it from the 8.0.1 source with a few patches of its own. The build script and the patches are in Fillet's repository.")
            }
            .font(Theme.body)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                link("Open CASCADE Technology 8.0.1 source", Self.occtSource)
                link("Fillet's OCCT build script", Self.buildScript)
                link("Fillet's OCCT patches", Self.patches)
            }
        }
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Link(title, destination: url)
            .font(Theme.body)
            .help(url.absoluteString)
    }
}

/// A licence text bundled with the app (App/Resources/Licenses, copied unchanged from the OCCT
/// V8_0_1 source).
enum Licence: String {
    case lgpl = "LICENSE_LGPL_21"
    case exception = "OCCT_LGPL_EXCEPTION"

    var title: String {
        switch self {
        case .lgpl: "GNU Lesser General Public License, version 2.1"
        case .exception: "Open CASCADE exception, version 1.0"
        }
    }

    /// Where the same file is in the OCCT source, for when the bundled copy can't be read.
    var source: URL { URL(string: "https://github.com/Open-Cascade-SAS/OCCT/blob/V8_0_1/\(rawValue).txt")! }

    /// The text from the app bundle; nil when it's missing (a resource left out of the build).
    func load() -> String? {
        Bundle.main.url(forResource: rawValue, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// A licence's full text, as written: monospaced (its line breaks and indents line up) and selectable.
private struct LicenceText: View {
    let licence: Licence
    private let text: String?

    init(_ licence: Licence) {
        self.licence = licence
        text = licence.load()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(licence.title).font(Theme.sectionTitle).foregroundStyle(Theme.ink)
            Group {
                if let text {
                    Text(text)
                        .font(Theme.caption.monospaced())
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Couldn't read the licence text from the app.")
                            .font(Theme.caption).foregroundStyle(Theme.dangerInk)
                        Link("Read it in the OCCT source", destination: licence.source).font(Theme.caption)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
        }
    }
}

#if os(macOS)
/// Fillet ▸ Acknowledgements
struct AcknowledgementsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Acknowledgements") { openWindow(id: AcknowledgementsView.windowID) }
    }
}
#else
/// The iPad sheet, from the launch screen or Fillet ▸ Acknowledgements.
struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AcknowledgementsView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationSizing(.page)
    }
}
#endif
