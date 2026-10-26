#if os(macOS)
import SwiftUI

/// Fillet ▸ Check for Updates…: what's new, and the download and install.
struct UpdateWindow: View {
    static let id = "software-update"

    @Bindable private var updater = Updater.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    content
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                        .toggleStyle(.checkbox)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.xl)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: Theme.Space.s) { actions }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
        }
        .frame(width: 560)
        .background(Theme.panel)
        .animation(Theme.Motion.enter, value: updater.phase)
        .task { if updater.phase == .idle { updater.checkForUpdates() } }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            header("Checking for updates…")
            ProgressView().progressViewStyle(.linear).tint(Theme.filletMark)
        case .upToDate:
            header("Fillet is up to date", detail: "Version \(updater.currentVersion) is the newest.")
            if let checked = updater.lastChecked {
                Text("Checked \(checked, format: .relative(presentation: .named))")
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
        case .available(let release):
            header("Fillet \(release.version) is available", detail: "You have \(updater.currentVersion).")
            RevisionBlock(installed: updater.currentVersion, release: release)
            ReleaseNotes(markdown: release.notes)
        case .downloading(let release, let received, let total):
            header("Downloading Fillet \(release.version)…",
                   detail: "\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
            RevisionBlock(installed: updater.currentVersion, release: release)
            ProgressView(value: Double(received), total: Double(max(total, 1))).tint(Theme.filletMark)
        case .preparing(let release):
            header("Preparing Fillet \(release.version)…", detail: "Checking the download and getting it ready to install.")
            RevisionBlock(installed: updater.currentVersion, release: release)
            ProgressView().progressViewStyle(.linear).tint(Theme.filletMark)
        case .ready(let release):
            header("Fillet \(release.version) is ready to install",
                   detail: "It installs when you quit Fillet. Relaunch to start using it now; Fillet asks to save open designs first.")
            RevisionBlock(installed: updater.currentVersion, release: release)
        case .failed(let release, let message):
            header(release.map { "Couldn't install Fillet \($0.version)" } ?? "Couldn't check for updates", detail: message,
                   symbol: "exclamationmark.triangle.fill")
            if let release {
                RevisionBlock(installed: updater.currentVersion, release: release)
                if updater.diskImage != nil {
                    Text("Open the installer and drag Fillet to Applications to update by hand.")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    private func header(_ title: String, detail: String? = nil, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label {
                Text(title).font(Theme.title).foregroundStyle(Theme.ink)
            } icon: {
                if let symbol { Image(systemName: symbol).foregroundStyle(Theme.warn) }
            }
            .labelStyle(TitleWithOptionalIcon(showsIcon: symbol != nil))
            if let detail {
                Text(detail).font(Theme.body).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .blurCrossfade(title)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch updater.phase {
        case .idle, .checking:
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        case .upToDate:
            Spacer()
            Button("OK") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .available(let release):
            Button("Skip This Version") {
                updater.skip(release)
                dismiss()
            }
            .buttonStyle(InlineButtonStyle(tint: Theme.inkSecondary))
            Spacer()
            Button("Later") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Install Update") { updater.install() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Spacer()
            Button("Cancel") { updater.cancelDownload() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        case .preparing:
            Spacer()
            Button("Install Update") {}
                .buttonStyle(PrimaryButtonStyle())
                .disabled(true)
        case .ready:
            Spacer()
            Button("Install on Quit") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Relaunch Now") { updater.relaunch() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .failed(let release, _):
            if let release {
                Button("Release Page") { openURL(release.page) }
                    .buttonStyle(InlineButtonStyle(tint: Theme.inkSecondary))
            }
            Spacer()
            if release != nil, updater.diskImage != nil {
                Button("Open Installer") {
                    updater.openDiskImage()
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Close") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Button("Try Again") {
                if release == nil { updater.checkForUpdates() } else { updater.install() }
            }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A title that only makes room for its icon when there is one.
private struct TitleWithOptionalIcon: LabelStyle {
    let showsIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if showsIcon { configuration.icon }
            configuration.title
        }
    }
}

/// The versions as a drawing's revision block, like the installer's drawing sheet: what's
/// installed, the new revision (the one orange mark), when it came out and how big it is.
private struct RevisionBlock: View {
    let installed: Version
    let release: Release

    var body: some View {
        HStack(spacing: 0) {
            cell("Installed", installed.description)
            cell("New", release.version.description, tint: Theme.filletInk)
            if let published = release.published {
                cell("Released", published.formatted(.dateTime.day().month(.abbreviated).year()))
            }
            cell("Size", release.size.formatted(.byteCount(style: .file)), last: true)
        }
        .overlay(Rectangle().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func cell(_ label: String, _ value: String, tint: Color = Theme.ink, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Theme.micro).tracking(0.6).foregroundStyle(Theme.inkSecondary)
            Text(value).font(Theme.value).foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if !last { Rectangle().fill(Theme.hairlineStrong).frame(width: 1) }
        }
    }
}

/// A release's Markdown notes: headings, lists, code and paragraphs with inline styling and links.
/// The release page's install steps (for a first install) and checksum (the updater checks it)
/// are left out.
private struct ReleaseNotes: View {
    enum Block: Hashable {
        case heading(String)
        case paragraph(AttributedString)
        case bullet(AttributedString)
        case numbered(String, AttributedString)
        case code(String)
    }

    let blocks: [Block]

    init(markdown: String) { blocks = Self.blocks(from: markdown) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if blocks.isEmpty {
                    Text("No release notes.").font(Theme.body).foregroundStyle(Theme.inkSecondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    view(for: block).padding(.top, index > 0 && block.isHeading ? Theme.Space.xs : 0)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(height: 200)
        .scrollEdgeFade(color: Theme.raised)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let title):
            Text(title).font(Theme.sectionTitle).foregroundStyle(Theme.ink)
        case .paragraph(let text):
            Text(text).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("•").font(Theme.body).foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
                Text(text).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("\(number).").font(Theme.value).foregroundStyle(Theme.inkSecondary)
                Text(text).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            Text(text).font(Theme.caption.monospaced()).foregroundStyle(Theme.ink)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.panel))
        }
    }

    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var skipping = false
        var code: [String]?  // inside a ``` fence
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code, !skipping { blocks.append(.code(lines.joined(separator: "\n"))) }
                code = code == nil ? [] : nil
            } else if code != nil {
                code?.append(raw)
            } else if line.isEmpty {
                continue
            } else if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                skipping = title.lowercased().hasPrefix("install") || title.lowercased().hasPrefix("checksum")
                if !skipping { blocks.append(.heading(title)) }
            } else if skipping {
                continue
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(inline(String(line.dropFirst(2)))))
            } else if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                let text = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(String(line[..<dot]), inline(text)))
            } else {
                blocks.append(.paragraph(inline(line)))
            }
        }
        return blocks
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private extension ReleaseNotes.Block {
    var isHeading: Bool { if case .heading = self { true } else { false } }
}

/// Fillet ▸ Check for Updates…
struct CheckForUpdatesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            Updater.shared.checkForUpdates()
            openWindow(id: UpdateWindow.id)
        }
    }
}

/// In the window toolbar while an update is on offer, in the orange of a primary action.
struct UpdateToolbarButton: View {
    let release: Release
    let isReady: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: UpdateWindow.id) } label: {
            Label {
                Text("Update")
            } icon: {
                Image(systemName: isReady ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(Theme.filletInk)
            }
        }
        .help(isReady ? "Fillet \(release.version) installs when you quit" : "Fillet \(release.version) is available")
    }
}
#endif
