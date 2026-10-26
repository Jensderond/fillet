#if os(macOS)
import AppKit
import CryptoKit
import Observation
import Synchronization

/// Keeps the Mac app up to date from its GitHub releases.
///
/// Checks once a day while "Check for updates automatically" is on (and from Fillet ▸ Check for
/// Updates… at any time). An update downloads into the app's container, is checked against the
/// SHA-256 GitHub lists for it, and is staged by the `FilletUpdater` XPC service, which runs
/// outside the sandbox. The swap happens when Fillet quits, so a running copy never loads
/// resources from the new one; "Relaunch Now" quits and opens the new copy.
///
/// When the app can't replace itself (macOS runs it from a translocated copy, its folder isn't
/// writable, or App Management refuses), the downloaded disk image opens instead, for the usual
/// drag to Applications.
///
/// Offline, a check fails quietly; nothing else in the app needs the network.
/// `FILLET_UPDATE_AS_VERSION=0.1.0` pretends to be an older version, to try an update.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        /// Nothing to show: no check yet, or the automatic checks found nothing new.
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, received: Int64, total: Int64)
        /// Checking the download and staging the new app.
        case preparing(Release)
        /// Staged: installs when Fillet quits.
        case ready(Release)
        /// `release` is nil when the check itself failed.
        case failed(Release?, message: String)
    }

    private enum Keys {
        static let automatic = "updatesCheckAutomatically"
        static let lastChecked = "updatesLastChecked"
        static let skipped = "updatesSkippedVersion"
    }

    /// How often the automatic checks look.
    private static let interval: TimeInterval = 24 * 60 * 60

    private(set) var phase = Phase.idle
    /// Remembered across launches; on unless turned off.
    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            UserDefaults.standard.set(automaticallyChecks, forKey: Keys.automatic)
            if automaticallyChecks, isDue { checkForUpdates(userInitiated: false) }
        }
    }
    private(set) var lastChecked: Date?
    let currentVersion: Version
    /// The downloaded disk image, once it has passed its checksum. Kept until quit, so a failed
    /// install can hand over to it.
    private(set) var diskImage: URL?

    @ObservationIgnored private var stagedApp: String?
    /// When Relaunch Now was clicked. Quitting can be cancelled (at a save prompt) and AppKit
    /// doesn't say so, so the request lapses rather than reopening Fillet after a later quit.
    @ObservationIgnored private var relaunchRequested: Date?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        automaticallyChecks = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        currentVersion = ProcessInfo.processInfo.environment["FILLET_UPDATE_AS_VERSION"].flatMap(Version.init)
            ?? bundled.flatMap(Version.init) ?? Version("0")!
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Updater.shared.applicationWillTerminate() }
        }
    }

    /// The update the toolbar offers: found, on its way, or waiting for quit.
    var offered: Release? {
        switch phase {
        case .available(let release), .downloading(let release, _, _), .preparing(let release), .ready(let release),
             .failed(let release?, _):
            release
        case .idle, .checking, .upToDate, .failed(nil, _):
            nil
        }
    }

    /// Downloading or staged: a new check would only get in the way.
    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .preparing, .ready: true
        case .idle, .upToDate, .available, .failed: false
        }
    }

    private var isInstalling: Bool {
        switch phase {
        case .downloading, .preparing, .ready: true
        case .idle, .checking, .upToDate, .available, .failed: false
        }
    }

    private var isDue: Bool {
        lastChecked.map { Date.now.timeIntervalSince($0) >= Self.interval } ?? true
    }

    // MARK: Checking

    /// Starts the automatic checks: shortly after launch, then whenever a day has passed.
    func start() {
        #if DEBUG
        if DebugAutomation.isEnabled { return }
        #endif
        guard schedule == nil else { return }
        schedule = Task {
            try? await Task.sleep(for: .seconds(5))  // out of the way of launch
            while !Task.isCancelled {
                if automaticallyChecks, isDue { checkForUpdates(userInitiated: false) }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Looks for a newer release. A check the user asked for reports what it found, even a
    /// skipped version; an automatic one only speaks up when there's something new.
    func checkForUpdates(userInitiated: Bool = true) {
        guard !isBusy else { return }
        if userInitiated { phase = .checking }
        work = Task {
            do {
                let newest = try await Release.newest()
                if isInstalling { return }  // an automatic check that lands after Install Update
                lastChecked = .now
                UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
                let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
                if let newest, newest.version > currentVersion, userInitiated || newest.version.description != skipped {
                    phase = .available(newest)
                } else if userInitiated {
                    phase = .upToDate
                }
            } catch {
                if userInitiated, !isInstalling { phase = .failed(nil, message: Self.message(for: error)) }
            }
        }
    }

    /// Stops offering this version until a newer one comes out.
    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version.description, forKey: Keys.skipped)
        phase = .idle
    }

    // MARK: Installing

    /// Downloads, checks and stages the offered update.
    func install() {
        let release: Release
        switch phase {
        case .available(let r), .failed(let r?, _): release = r
        default: return
        }
        work = Task { await download(release) }
    }

    func cancelDownload() { work?.cancel() }

    /// Quits, installs, and opens the new version. Quitting asks to save open designs first.
    func relaunch() {
        relaunchRequested = .now
        NSApp.terminate(nil)
    }

    /// The downloaded disk image in Finder, to drag Fillet to Applications by hand.
    func openDiskImage() {
        if let diskImage { NSWorkspace.shared.open(diskImage) }
    }

    private func download(_ release: Release) async {
        phase = .downloading(release, received: 0, total: release.size)
        diskImage = nil
        do {
            let image = FileManager.default.temporaryDirectory.appendingPathComponent(release.diskImage.lastPathComponent)
            try await DiskImageDownload(to: image) { received, total in
                Task { @MainActor in Updater.shared.progressed(release, received: received, total: total) }
            }.run(from: release.diskImage)
            phase = .preparing(release)
            guard let sha256 = release.sha256 else {
                diskImage = image
                throw UpdateError("This release lists no checksum to check the download against, so Fillet won't install it itself.")
            }
            guard try await Self.sha256(of: image) == sha256.lowercased() else {
                try? FileManager.default.removeItem(at: image)
                throw UpdateError("The download is damaged: its checksum doesn't match the release. Try again.")
            }
            diskImage = image
            try Task.checkCancellation()
            guard !Bundle.main.bundleURL.path.contains("/AppTranslocation/") else {
                throw UpdateError("macOS runs this copy of Fillet from a temporary location, so it can't replace itself.")
            }
            stagedApp = try await stage(image, sha256: sha256)
            // The swap happens on quit: keep macOS from ending the app without telling it.
            ProcessInfo.processInfo.disableSuddenTermination()
            ProcessInfo.processInfo.disableAutomaticTermination("An update is waiting to install")
            phase = .ready(release)
        } catch is CancellationError {
            phase = .available(release)
        } catch {
            phase = .failed(release, message: Self.message(for: error))
        }
    }

    private func progressed(_ release: Release, received: Int64, total: Int64) {
        guard case .downloading(let current, _, _) = phase, current == release else { return }
        phase = .downloading(release, received: received, total: total > 0 ? total : release.size)
    }

    /// Hands the disk image to the XPC service, which checks it again and stages the app.
    private func stage(_ image: URL, sha256: String) async throws -> String {
        let file = try FileHandle(forReadingFrom: image)
        defer { try? file.close() }
        let connection = Self.connect()
        defer { connection.invalidate() }
        let appPath = Bundle.main.bundleURL.path
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let installer = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(with: .failure(UpdateError("The updater stopped: \(error.localizedDescription)")))
            } as? UpdateInstalling
            guard let installer else {
                once.resume(with: .failure(UpdateError("This copy of Fillet has no updater.")))
                return
            }
            installer.prepare(diskImage: file, sha256: sha256, replacing: appPath) { staged, message in
                if let staged {
                    once.resume(with: .success(staged))
                } else {
                    once.resume(with: .failure(UpdateError(message ?? "The updater couldn't prepare the update.")))
                }
            }
        }
    }

    private func applicationWillTerminate() {
        guard case .ready = phase, let stagedApp else { return }
        let app = Bundle.main.bundleURL
        if let failure = Self.install(stagedApp, replacing: app.path) {
            // Most likely App Management (System Settings ▸ Privacy & Security) or a folder
            // the user can't write to. Finder can still replace it.
            NSLog("Fillet: the update didn't install (%@); opening the disk image instead", failure)
            openDiskImage()
        } else if let relaunchRequested, Date.now.timeIntervalSince(relaunchRequested) < 10 * 60 {
            Self.open(app, afterExitOf: ProcessInfo.processInfo.processIdentifier)
        }
    }

    /// Swaps the staged app in, synchronously: the app is quitting. Returns a failure message, or nil.
    private static func install(_ staged: String, replacing app: String) -> String? {
        let connection = connect()
        defer { connection.invalidate() }
        let outcome = Outcome()
        let installer = connection.synchronousRemoteObjectProxyWithErrorHandler { @Sendable error in
            outcome.message = error.localizedDescription
        } as? UpdateInstalling
        guard let installer else { return "This copy of Fillet has no updater." }
        installer.install(stagedPath: staged, replacing: app) { message in outcome.message = message }
        return outcome.message
    }

    /// Opens `app` once this process has exited, so the new copy doesn't start next to the old
    /// one (and find the agent port taken). A shell outlives the app to do it.
    private static func open(_ app: URL, afterExitOf pid: Int32) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
                           "sh", String(pid), app.path]
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
        } catch {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
    }

    private static func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: UpdateService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstalling.self)
        connection.resume()
        return connection
    }

    private nonisolated static func sha256(of file: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func message(for error: Error) -> String {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                        .cannotConnectToHost, .dnsLookupFailed, .timedOut]
        if let code = (error as? URLError)?.code, offline.contains(code) {
            return "Fillet couldn't reach GitHub. Check your internet connection and try again."
        }
        return error.localizedDescription
    }
}

/// The installer's answer to a synchronous call: nil when it installed, else what went wrong.
private final class Outcome: Sendable {
    private let value = Mutex<String?>("The updater didn't answer.")

    var message: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Resumes a continuation once, whichever of an XPC reply and its error handler comes first.
private final class Once<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Error>?>

    init(_ c: CheckedContinuation<Value, Error>) { continuation = Mutex(c) }

    func resume(with result: Result<Value, Error>) {
        continuation.withLock { c in
            c?.resume(with: result)
            c = nil
        }
    }
}

/// Downloads the disk image with progress.
private final class DiskImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (_ received: Int64, _ total: Int64) -> Void
    // The rest is only touched on `queue`, the session's serial delegate queue.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var saved: Result<Void, Error>?
    private var lastReported: Int64 = 0

    init(to destination: URL, onProgress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    guard !self.cancelled else { return continuation.resume(throwing: CancellationError()) }
                    self.continuation = continuation
                    let task = session.downloadTask(with: url)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            queue.addOperation {
                self.cancelled = true
                self.task?.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // About every 256 KB, not every packet.
        guard totalBytesWritten - lastReported >= 1 << 18 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastReported = totalBytesWritten
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns, so the file moves now.
        saved = Result {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
                throw UpdateError("GitHub didn't send the update (\(status)). Try again later.")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Void, Error>
        if let error {
            let cancellation = cancelled || (error as? URLError)?.code == .cancelled
            result = .failure(cancellation ? CancellationError() as Error : error)
        } else {
            result = saved ?? .failure(UpdateError("The download didn't finish."))
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}
#endif
