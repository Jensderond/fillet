#if os(macOS)
import Foundation

/// A Mac release on GitHub with a disk image to install from.
struct Release: Equatable, Sendable {
    let version: Version
    /// Markdown, from the release page.
    let notes: String
    let published: Date?
    /// The release page.
    let page: URL
    let diskImage: URL
    let size: Int64
    /// Hex SHA-256 of the disk image, which GitHub computes on upload.
    let sha256: String?

    /// Fillet's GitHub project, shown in the About panel and Software Update.
    static let project = URL(string: "https://github.com/Jensderond/fillet")!

    /// Where the app looks for releases. Every release so far is a prerelease, which
    /// `/releases/latest` leaves out, so this lists them and picks the newest.
    static let feed = URL(string: "https://api.github.com/repos/Jensderond/fillet/releases?per_page=10")!

    /// The newest release with a disk image, or nil when there is none.
    static func newest() async throws -> Release? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw UpdateError("GitHub didn't list the releases (\((response as? HTTPURLResponse)?.statusCode ?? 0)). Try again later.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
            .compactMap(Release.init)
            .max { $0.version < $1.version }
    }

    private init?(_ release: GitHubRelease) {
        guard !release.draft, let version = Version(release.tagName),
              let image = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return nil }
        self.version = version
        notes = release.body ?? ""
        published = release.publishedAt
        page = release.htmlUrl
        diskImage = image.browserDownloadUrl
        size = image.size
        sha256 = image.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let draft: Bool
    let htmlUrl: URL
    let publishedAt: Date?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int64
        /// "sha256:…"
        let digest: String?
    }
}

/// A dotted version ("0.3.1", or a tag like "v0.3.1"). Missing parts count as zero, so 0.3 == 0.3.0;
/// a suffix after "-" is ignored.
struct Version: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let core = text.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private func part(_ i: Int) -> Int { i < parts.count ? parts[i] : 0 }

    static func == (a: Version, b: Version) -> Bool {
        (0..<max(a.parts.count, b.parts.count)).allSatisfy { a.part($0) == b.part($0) }
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) where a.part(i) != b.part(i) {
            return a.part(i) < b.part(i)
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
#endif
