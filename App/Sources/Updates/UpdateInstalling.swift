#if os(macOS)
import Foundation

/// The Mac updater's installer: the `FilletUpdater` XPC service inside the app
/// (`Contents/XPCServices`). It runs outside the app's sandbox, so it can swap the new
/// app in for the old one, which the sandboxed app can't write to. Compiled into both the
/// app and the service.
@objc protocol UpdateInstalling {
    /// Copies the update's disk image out of `diskImage`, checks it against `sha256` (hex),
    /// mounts it privately and copies the app inside it next to `appPath`, ready to swap in.
    /// Replies with the staged app's path, or with a message saying what went wrong.
    func prepare(diskImage: FileHandle, sha256: String, replacing appPath: String,
                 reply: @escaping @Sendable (_ stagedPath: String?, _ error: String?) -> Void)

    /// Swaps the staged app in for the one at `appPath`. Replies with nil, or a message.
    func install(stagedPath: String, replacing appPath: String, reply: @escaping @Sendable (_ error: String?) -> Void)
}

enum UpdateService {
    /// The XPC service's bundle identifier (`project.yml`).
    static let name = "app.fillet.Fillet.Updater"
}
#endif
