import AppKit
import Foundation

/// Observable state container for one document window.
///
/// Each window owns one `DocumentState` instance which drives:
/// - empty state
/// - loading indicator
/// - rendered document view
/// - error presentation
@MainActor
final class DocumentState: ObservableObject {
    /// Rendering lifecycle phases for a document window.
    enum Phase: Equatable {
        /// Window has no loaded document yet.
        case empty

        /// A file is currently being read and rendered.
        case loading

        /// A document rendered successfully and is ready to display.
        case loaded

        /// File read or render failed, with user-facing message.
        case failed(String)
    }

    /// Current lifecycle phase used by the view layer.
    @Published var phase: Phase

    /// Loaded document model, if available.
    @Published var document: MarkdownDocument?

    /// Rendered HTML consumed by the `WKWebView` wrapper.
    @Published var html: String = ""

    /// Active security-scoped session kept alive while a document is open.
    ///
    /// This is especially important when App Sandbox is enabled, because
    /// `WKWebView` may need ongoing access for relative local images.
    private var securityScopedSession: SecurityScopedSession?

    /// Lightweight on-disk fingerprint for reload checks.
    ///
    /// We use both modification time and file size so focus-triggered refresh
    /// can cheaply detect external edits without re-reading unchanged files.
    private struct FileFingerprint: Equatable {
        let modificationDate: Date?
        let fileSize: Int64?
    }

    /// Fingerprint captured after the most recent successful load.
    private var lastLoadedFingerprint: FileFingerprint?

    /// Initialises state as empty or loading, depending on launch context.
    init(fileURL: URL? = nil) {
        if fileURL == nil {
            phase = .empty
        } else {
            phase = .loading
        }
    }

    /// Reads and renders a Markdown document for display.
    ///
    /// This method is intentionally synchronous for a tiny utility app,
    /// keeping flow easy to reason about.
    func load(
        fileURL: URL,
        fileOpenService: FileOpenService,
        renderService: MarkdownRenderService
    ) {
        let loadStart = DispatchTime.now()
        phase = .loading

        // Reset any prior scoped access before loading a new file.
        securityScopedSession?.stop()
        securityScopedSession = nil

        let documentDirectoryURL = fileURL.deletingLastPathComponent()

        // Reuse previously approved directory access when available so the
        // app does not repeatedly prompt for the same folder across launches.
        var securityScopedURLs: [URL] = [fileURL, documentDirectoryURL]
        if let bookmarkedDirectoryURL = SecurityScopedBookmarkStore.shared
            .resolvedDirectoryURL(for: documentDirectoryURL) {
            securityScopedURLs.append(bookmarkedDirectoryURL)
        }

        // Keep both the file and its parent directory scoped for the document
        // lifetime so relative image/link paths remain readable.
        var scopedSession = SecurityScopedSession(urls: securityScopedURLs)
        securityScopedSession = scopedSession

        do {
            // 1) Read source text from disk.
            let readStart = DispatchTime.now()
            var opened = try fileOpenService.openDocument(at: fileURL)
            let readMilliseconds = elapsedMilliseconds(since: readStart)

            var directoryAccessPromptMilliseconds: Double?

            // In sandboxed builds, selecting a file may not always grant scope
            // to sibling files in the same folder. If the Markdown appears to
            // reference local relative resources, ask once for folder access.
            if SecurityHelpers.isRunningSandboxed,
               !scopedSession.hasActiveAccess(to: documentDirectoryURL),
               containsLikelyRelativeLocalReferences(in: opened.rawMarkdown) {
                let directoryAccessPromptStart = DispatchTime.now()
                let grantedDirectoryURL = requestDirectoryAccess(
                    preferredDirectoryURL: documentDirectoryURL,
                    fileName: fileURL.lastPathComponent
                )
                directoryAccessPromptMilliseconds = elapsedMilliseconds(since: directoryAccessPromptStart)

                if let grantedDirectoryURL {
                    // Recreate the session so both the file and granted directory
                    // stay in scope while this document window remains open.
                    SecurityScopedBookmarkStore.shared.storeBookmark(for: grantedDirectoryURL)
                    scopedSession.stop()
                    scopedSession = SecurityScopedSession(
                        urls: [fileURL, documentDirectoryURL, grantedDirectoryURL]
                    )
                    securityScopedSession = scopedSession
                }
            }

            // 2) Render Markdown to a full HTML document.
            let renderStart = DispatchTime.now()
            let rendered = try renderService.render(
                markdown: opened.rawMarkdown,
                baseDirectoryURL: opened.baseDirectoryURL
            )
            let renderMilliseconds = elapsedMilliseconds(since: renderStart)

            // 3) Publish successful state to the UI.
            opened.renderedHTML = rendered
            document = opened
            html = rendered
            lastLoadedFingerprint = currentFileFingerprint(for: fileURL)
            phase = .loaded

            let totalMilliseconds = elapsedMilliseconds(since: loadStart)
            let directoryAccessPromptComponent: String
            if let directoryAccessPromptMilliseconds {
                directoryAccessPromptComponent =
                    " directoryPromptMs=\(formatMilliseconds(directoryAccessPromptMilliseconds))"
            } else {
                directoryAccessPromptComponent = ""
            }

            Logger.info(
                "[PERF] document-state-load file=\(fileURL.lastPathComponent) outcome=success readMs=\(formatMilliseconds(readMilliseconds)) renderMs=\(formatMilliseconds(renderMilliseconds)) totalMs=\(formatMilliseconds(totalMilliseconds))\(directoryAccessPromptComponent)"
            )
        } catch {
            // Fall back to a clean error state without crashing.
            document = nil
            html = ""
            phase = .failed(error.localizedDescription)
            securityScopedSession?.stop()
            securityScopedSession = nil
            lastLoadedFingerprint = nil
            let totalMilliseconds = elapsedMilliseconds(since: loadStart)
            Logger.info(
                "[PERF] document-state-load file=\(fileURL.lastPathComponent) outcome=failure totalMs=\(formatMilliseconds(totalMilliseconds))"
            )
            Logger.error("Failed to load document: \(error.localizedDescription)")
        }
    }

    /// Reloads only when the on-disk file appears to have changed.
    ///
    /// This is designed for low-risk "refresh on window focus" behaviour:
    /// if file timestamp/size are unchanged, the document remains untouched.
    func reloadIfFileChanged(
        fileURL: URL,
        fileOpenService: FileOpenService,
        renderService: MarkdownRenderService
    ) {
        // Avoid overlapping synchronous loads while one is already in flight.
        guard phase != .loading else {
            return
        }

        let standardisedFileURL = fileURL.standardizedFileURL

        guard let currentFingerprint = currentFileFingerprint(for: standardisedFileURL) else {
            // If fingerprint metadata is unavailable, do nothing here to avoid
            // noisy repeated reload attempts from focus changes.
            return
        }

        if let lastLoadedFingerprint, lastLoadedFingerprint == currentFingerprint {
            return
        }

        load(
            fileURL: standardisedFileURL,
            fileOpenService: fileOpenService,
            renderService: renderService
        )
    }

    /// Returns a tiny file fingerprint used for change detection.
    private func currentFileFingerprint(for fileURL: URL) -> FileFingerprint? {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey
        ]

        guard let resourceValues = try? fileURL.resourceValues(forKeys: keys) else {
            return nil
        }

        let modificationDate = resourceValues.contentModificationDate
        let fileSize = resourceValues.fileSize.map(Int64.init)

        guard modificationDate != nil || fileSize != nil else {
            return nil
        }

        return FileFingerprint(
            modificationDate: modificationDate,
            fileSize: fileSize
        )
    }

    /// Returns elapsed wall-clock time in milliseconds for profiling logs.
    private func elapsedMilliseconds(since start: DispatchTime) -> Double {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsedNanoseconds) / 1_000_000
    }

    /// Formats elapsed millisecond values for compact console logs.
    private func formatMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    /// Returns true when Markdown appears to contain local file references.
    ///
    /// We detect both images and normal links because either can depend on
    /// sibling files in the document folder while sandboxing is active.
    private func containsLikelyRelativeLocalReferences(in markdown: String) -> Bool {
        let pattern = #"!?\[[^\]]*\]\(([^)\n]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        let matches = regex.matches(in: markdown, options: [], range: fullRange)

        for match in matches {
            let destinationRange = match.range(at: 1)
            guard destinationRange.location != NSNotFound else { continue }

            let rawDestination = nsMarkdown.substring(with: destinationRange)
            let destination = extractDestinationWithoutOptionalTitle(rawDestination)
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else { continue }

            // Fragment-only links never require additional file-system access.
            if trimmed.hasPrefix("#") {
                continue
            }

            // Absolute filesystem and file-scheme URLs are local references.
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("file://") {
                return true
            }

            // Skip common remote schemes; treat everything else as local.
            if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
               ["http", "https", "mailto", "data"].contains(scheme) {
                continue
            }

            return true
        }

        return false
    }

    /// Extracts the destination URL/path component from Markdown link syntax.
    ///
    /// Examples:
    /// - `file.png` -> `file.png`
    /// - `<folder/file one.png>` -> `folder/file one.png`
    /// - `file.png "caption"` -> `file.png`
    private func extractDestinationWithoutOptionalTitle(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Angle-bracket form supports spaces within the destination.
        if trimmed.hasPrefix("<"), let closingBracketIndex = trimmed.firstIndex(of: ">") {
            let start = trimmed.index(after: trimmed.startIndex)
            return String(trimmed[start..<closingBracketIndex])
        }

        // Standard form may include optional title after first whitespace.
        if let firstWhitespaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) {
            return String(trimmed[..<firstWhitespaceIndex])
        }

        return trimmed
    }

    /// Asks the user for read-only access to the Markdown file's folder.
    ///
    /// This is a fallback path only used when sandbox scope for the folder was
    /// not inherited from file selection and local relative resources exist.
    private func requestDirectoryAccess(preferredDirectoryURL: URL, fileName: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Allow Folder Access"
        panel.message =
            "To display local images and links for \(fileName), Quick Markdown Viewer needs read-only access to its folder."
        panel.prompt = "Allow Access"
        panel.directoryURL = preferredDirectoryURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url?.standardizedFileURL
    }
}
