import CryptoKit
import Foundation

/// Stages and installs an update for the app that contains this service. The app has
/// already checked the download; this checks it again, since it's what gets installed.
final class Installer: NSObject, UpdateInstalling {
    func prepare(diskImage: FileHandle, sha256: String, replacing appPath: String,
                 reply: @escaping @Sendable (String?, String?) -> Void) {
        do {
            let staged = try stage(diskImage: diskImage, sha256: sha256, replacing: URL(fileURLWithPath: appPath))
            reply(staged.path, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func install(stagedPath: String, replacing appPath: String, reply: @escaping @Sendable (String?) -> Void) {
        let fm = FileManager.default
        let app = URL(fileURLWithPath: appPath)
        let staged = URL(fileURLWithPath: stagedPath)
        // Beside the staged app, so both moves are renames on one volume.
        let previous = staged.deletingLastPathComponent().appendingPathComponent("Previous \(app.lastPathComponent)")
        do {
            try fm.moveItem(at: app, to: previous)
            do {
                try fm.moveItem(at: staged, to: app)
            } catch {
                try? fm.moveItem(at: previous, to: app)
                throw error
            }
        } catch {
            reply(error.localizedDescription)
            return
        }
        reply(nil)
        try? fm.removeItem(at: previous)
    }

    // MARK: Staging

    private func stage(diskImage: FileHandle, sha256: String, replacing app: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw InstallError("Fillet can't replace itself in \(app.deletingLastPathComponent().lastPathComponent).")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("Fillet Update \(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Copy the image out of the app's container, hashing it on the way.
        let image = work.appendingPathComponent("Fillet.dmg")
        guard fm.createFile(atPath: image.path, contents: nil) else { throw InstallError("Couldn't save the update.") }
        let out = try FileHandle(forWritingTo: image)
        var hash = SHA256()
        while let chunk = try diskImage.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            try out.write(contentsOf: chunk)
        }
        try out.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw InstallError("The download is damaged: its checksum doesn't match the release.") }

        // Mounted privately: not in Finder, and its window doesn't open.
        let mount = work.appendingPathComponent("Volume", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", "attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-noautoopen", "-readonly", "-quiet")
        defer { _ = try? run("/usr/bin/hdiutil", "detach", mount.path, "-force", "-quiet") }

        let apps = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard let source = apps.first else { throw InstallError("The download has no app in it.") }
        guard let identifier = Bundle(url: source)?.bundleIdentifier, identifier == Bundle(url: app)?.bundleIdentifier else {
            throw InstallError("The download isn't Fillet.")
        }
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", source.path)

        // On the app's volume, so installing is a rename. Without the quarantine flag: this
        // copy came from the release's own checksum, and the app was approved to run before.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", "--noqtn", source.path, staged.path)
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged.path)
        return staged
    }

    /// Runs a command line tool, throwing with its output when it fails.
    @discardableResult
    private func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw InstallError("\(name) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}

struct InstallError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
