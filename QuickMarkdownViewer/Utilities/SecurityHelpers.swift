import Foundation

/// Small security-oriented helpers used by the render pipeline.
enum SecurityHelpers {
    /// Converts a Swift string into a JSON string literal body.
    ///
    /// The returned value excludes surrounding array brackets, so callers can
    /// embed it safely in templates where JSON escaping is required.
    static func jsonStringLiteral(_ value: String) -> String {
        let array = [value]

        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else {
            return "\"\""
        }

        // Remove the leading `[` and trailing `]` from encoded single-item array.
        return String(json.dropFirst().dropLast())
    }

    /// Escapes text for safe insertion into an HTML attribute value.
    ///
    /// This is used for values such as `<base href="...">`, where unescaped
    /// quote or angle-bracket characters could otherwise break markup.
    static func htmlAttributeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Returns true when the process is running under App Sandbox.
    ///
    /// Xcode debug runs with sandbox disabled in this project, while Release
    /// archives run with sandbox enabled. We use this check to decide when to
    /// show folder-access prompts that are only relevant in sandboxed builds.
    static var isRunningSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

/// Holds active security-scoped file access for the lifetime of a document.
///
/// Why this exists:
/// - `NSOpenPanel` and drag/drop can hand us security-scoped URLs when
///   App Sandbox is enabled.
/// - `WKWebView` needs the scope to remain active while rendering local images
///   and following local links.
/// - Wrapping the lifetime in one object keeps start/stop calls balanced.
final class SecurityScopedSession {
    /// URLs for which `startAccessingSecurityScopedResource()` succeeded.
    private var activeURLs: [URL] = []

    /// Canonical file-system paths currently covered by this session.
    ///
    /// Keeping a path set lets callers quickly verify whether directory scope
    /// was granted (for example, to support relative image references).
    private var activePaths: Set<String> = []

    /// Starts a session for the provided URLs.
    ///
    /// Duplicate paths are collapsed to avoid redundant start/stop calls.
    init(urls: [URL]) {
        var seenPaths = Set<String>()

        for url in urls where url.isFileURL {
            let standardisedURL = url.standardizedFileURL
            let path = standardisedURL.path

            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)

            if standardisedURL.startAccessingSecurityScopedResource() {
                activeURLs.append(standardisedURL)
                activePaths.insert(path)
            }
        }
    }

    /// Ends the active security scope when the document window closes
    /// or when a different file is loaded into the same state object.
    deinit {
        stop()
    }

    /// Explicitly stops all active security-scoped accesses.
    func stop() {
        guard !activeURLs.isEmpty else { return }

        for url in activeURLs {
            url.stopAccessingSecurityScopedResource()
        }

        activeURLs.removeAll()
        activePaths.removeAll()
    }

    /// Returns true when this session has active scope for the URL path.
    ///
    /// We compare standardised file paths so equivalent URLs resolve
    /// consistently (for example, with or without `.` path components).
    func hasActiveAccess(to url: URL) -> Bool {
        let standardisedPath = url.standardizedFileURL.path
        return activePaths.contains(standardisedPath)
    }
}

/// Persists security-scoped directory bookmarks for previously approved folders.
///
/// Why this exists:
/// - In sandboxed builds, selecting a Markdown file does not always grant
///   access to sibling files (for example local images in the same folder).
/// - Prompting for folder access every launch is clumsy.
/// - Storing folder bookmarks allows QuickMarkdownViewer to restore read access
///   automatically on later launches for the same folder.
final class SecurityScopedBookmarkStore {
    /// Shared bookmark store instance.
    static let shared = SecurityScopedBookmarkStore()

    /// User defaults key storing `[canonicalFolderPath: bookmarkData]`.
    private let defaultsKey = "QuickMarkdownViewer.SecurityScopedDirectoryBookmarks.v1"

    /// Backing defaults store.
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns a resolved security-scoped directory URL if one is stored.
    ///
    /// If bookmark resolution fails or stale data cannot be refreshed,
    /// the invalid bookmark entry is removed quietly.
    func resolvedDirectoryURL(for directoryURL: URL) -> URL? {
        let canonicalDirectoryURL = canonicalisedDirectoryURL(directoryURL)
        let pathKey = canonicalDirectoryURL.path

        guard let bookmarkData = bookmarkMap()[pathKey] else {
            return nil
        }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            removeBookmark(forPathKey: pathKey)
            return nil
        }

        let canonicalResolvedURL = canonicalisedDirectoryURL(resolvedURL)

        if isStale {
            storeBookmark(for: canonicalResolvedURL)
        }

        return canonicalResolvedURL
    }

    /// Stores or refreshes the bookmark for a directory URL.
    ///
    /// Errors are intentionally ignored because bookmark persistence is a
    /// usability optimisation, not a correctness requirement.
    func storeBookmark(for directoryURL: URL) {
        let canonicalDirectoryURL = canonicalisedDirectoryURL(directoryURL)
        guard let bookmarkData = try? canonicalDirectoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }

        var map = bookmarkMap()
        map[canonicalDirectoryURL.path] = bookmarkData
        defaults.set(map, forKey: defaultsKey)
    }

    /// Normalises a directory URL to a stable canonical form.
    private func canonicalisedDirectoryURL(_ url: URL) -> URL {
        let standardised = url.standardizedFileURL
        return standardised.hasDirectoryPath
            ? standardised
            : standardised.deletingLastPathComponent()
    }

    /// Returns the in-memory bookmark map from defaults.
    private func bookmarkMap() -> [String: Data] {
        defaults.object(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    /// Removes one stored bookmark entry.
    private func removeBookmark(forPathKey pathKey: String) {
        var map = bookmarkMap()
        map.removeValue(forKey: pathKey)
        defaults.set(map, forKey: defaultsKey)
    }
}
