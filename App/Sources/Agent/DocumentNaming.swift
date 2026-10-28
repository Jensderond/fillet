import FilletAgent
import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformWindow = NSWindow
#else
import UIKit
typealias PlatformWindow = UIWindow
#endif

extension DesignSession {
    /// The document file's name, without extension.
    var documentName: String? { fileURL?.deletingPathExtension().lastPathComponent }

    /// What the window is called: its file, or (unsaved) the design's own name.
    var title: String { documentName ?? document.name ?? "Untitled" }
}

/// Gives a window's document file the name an agent chose for the design (`rename_design`).
///
/// The window's document keeps tracking its file: on the Mac `NSDocument` moves it, on iPad a
/// coordinated move tells the open `UIDocument` (a file presenter) where it went. An unsaved Mac
/// window takes the name as its display name, which its Save panel proposes. A file that can't be
/// renamed (another app's folder, a name that's taken) keeps its name and the agent is told why;
/// the name is in the design either way.
@MainActor
enum DocumentNaming {
    static func name(_ session: DesignSession, _ name: String) async -> FileNaming {
        guard let window = session.hostWindow else { return .kept("Fillet couldn't find this design's window.") }
        #if os(macOS)
        guard let document = NSDocumentController.shared.document(for: window) else {
            return .kept("Fillet couldn't find this window's document.")
        }
        guard let url = document.fileURL else {
            document.displayName = name
            // The window doesn't pick up a new display name by itself.
            for controller in document.windowControllers { controller.synchronizeWindowTitleWithDocumentName() }
            return .unsaved
        }
        if url.deletingPathExtension().lastPathComponent == name { return .renamed(url.lastPathComponent) }
        let target = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .kept("a file named “\(target.lastPathComponent)” is already in that folder.")
        }
        do {
            try await document.move(to: target)
            return .renamed(document.fileURL?.lastPathComponent ?? target.lastPathComponent)
        } catch {
            return .kept("macOS didn't let Fillet rename it (\(error.localizedDescription)). The user can rename it with File ▸ Rename….")
        }
        #else
        guard let document = document(in: window) else { return .kept("Fillet couldn't find this window's document.") }
        let old = document.fileURL
        if old.deletingPathExtension().lastPathComponent == name { return .renamed(old.lastPathComponent) }
        let target = old.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(old.pathExtension)
        if let problem = await Task.detached(operation: { coordinatedMove(old, to: target) }).value {
            return .kept("\(problem) The user can rename it from the title menu (Rename).")
        }
        // The document hears of the move as a file presenter; wait for it to follow.
        for _ in 0..<40 where document.fileURL == old {
            try? await Task.sleep(for: .milliseconds(50))
        }
        session.fileURL = document.fileURL == old ? target : document.fileURL
        return .renamed(target.lastPathComponent)
        #endif
    }

    #if os(iOS)
    /// The document the window shows.
    private static func document(in window: UIWindow) -> UIDocument? {
        var queue = window.rootViewController.map { [$0] } ?? []
        while !queue.isEmpty {
            let vc = queue.removeFirst()
            if let doc = (vc as? UIDocumentViewController)?.document { return doc }
            queue += vc.children
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        return nil
    }

    /// Moves the file with file coordination, so the open document (a file presenter) follows it.
    /// Nil when it moved, else why not. Works where Fillet may write the folder: its own folders
    /// in Files (On My iPad, iCloud Drive) — not another app's.
    nonisolated private static func coordinatedMove(_ old: URL, to target: URL) -> String? {
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return "A file named “\(target.lastPathComponent)” is already in that folder."
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(writingItemAt: old, options: .forMoving, writingItemAt: target, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        guard let error = coordinationError ?? moveError else { return nil }
        return "iPadOS didn't let Fillet rename it here (\(error.localizedDescription))."
    }
    #endif
}

/// Reports the window the view is in (the editor uses it to reach its document).
struct WindowAnchor {
    let found: (PlatformWindow?) -> Void
}

#if os(macOS)
extension WindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView(found: found) }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.found = found
        if let window = view.window { found(window) }
    }

    final class AnchorView: NSView {
        var found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { found(window) }
    }
}
#else
extension WindowAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> AnchorView { AnchorView(found: found) }
    func updateUIView(_ view: AnchorView, context: Context) {
        view.found = found
        if let window = view.window { found(window) }
    }

    final class AnchorView: UIView {
        var found: (UIWindow?) -> Void
        init(found: @escaping (UIWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() { found(window) }
    }
}
#endif
