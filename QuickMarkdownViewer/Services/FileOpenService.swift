import AppKit
import Foundation
import UniformTypeIdentifiers

/// Domain errors surfaced while opening Markdown files.
enum FileOpenError: LocalizedError {
    /// User selected or dropped a file with an unsupported extension.
    case unsupportedType(URL)

    /// File bytes were readable, but text decoding failed.
    case unreadableEncoding(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let url):
            return "Unsupported file type: \(url.lastPathComponent)"
        case .unreadableEncoding(let url):
            return "Could not read text encoding for \(url.lastPathComponent)."
        }
    }
}

/// Handles Markdown file picking, validation, and text loading.
///
/// The service keeps concerns narrow:
/// - Open panel setup
/// - Extension checks
/// - Basic multi-encoding text decode
struct FileOpenService {
    /// Defaults key storing last directory used by the Markdown file chooser.
    private static let markdownOpenPanelLastDirectoryDefaultsKey =
        "qmv.markdownOpenPanel.lastDirectory.v1"

    /// Supported Markdown extensions in the preferred display order.
    ///
    /// We keep this as an ordered list so user-facing warnings can present the
    /// extensions consistently, while runtime lookups still use a `Set`.
    static let allowedExtensionsInDisplayOrder: [String] = [
        "md",
        "markdown",
        "mdown",
        "mkd",
        "mkdn",
        "mdwn"
    ]

    /// Extensions QuickMarkdownViewer supports in v1.
    ///
    /// This includes both modern and historically common Markdown suffixes
    /// used across tooling ecosystems.
    static let allowedExtensions: Set<String> = Set(allowedExtensionsInDisplayOrder)

    /// Markdown-adjacent extensions that users commonly try to open, but which
    /// QuickMarkdownViewer intentionally does not fully support in v1.
    ///
    /// We keep these separate from `allowedExtensions` so routing can show a
    /// clear warning instead of silently failing or opening malformed output.
    static let explicitlyUnsupportedMarkdownVariantExtensions: Set<String> = [
        "rmd",
        "qmd"
    ]

    /// Human-readable extension list used by warning copy.
    ///
    /// Example output: `.md, .markdown, .mdown`
    static var acceptedExtensionsSummary: String {
        allowedExtensionsInDisplayOrder
            .map { ".\($0)" }
            .joined(separator: ", ")
    }

    /// Presents the native macOS file chooser restricted to Markdown files.
    func selectMarkdownFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowsOtherFileTypes = false
        panel.directoryURL = persistedOpenPanelDirectoryURL()

        // Prefer UTType-based filtering on modern macOS.
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = Self.allowedUTTypes
        } else {
            panel.allowedFileTypes = Self.allowedExtensionsInDisplayOrder
        }

        guard panel.runModal() == .OK else {
            return nil
        }

        let selectedURLs = panel.urls
        if let firstSelectedURL = selectedURLs.first {
            persistOpenPanelDirectory(from: firstSelectedURL)
        }

        return selectedURLs
    }

    /// Returns true when the URL extension is one QuickMarkdownViewer can render.
    func supports(url: URL) -> Bool {
        Self.allowedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Returns true when the URL is a known unsupported Markdown variant.
    ///
    /// These files should trigger an explicit user-facing warning.
    func isExplicitlyUnsupportedMarkdownVariant(url: URL) -> Bool {
        Self.explicitlyUnsupportedMarkdownVariantExtensions.contains(url.pathExtension.lowercased())
    }

    /// Reads and decodes Markdown source text from disk.
    func openDocument(at fileURL: URL) throws -> MarkdownDocument {
        guard supports(url: fileURL) else {
            throw FileOpenError.unsupportedType(fileURL)
        }

        // Memory-map where practical for quick startup on local files.
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])

        guard let markdown = decodeString(data) else {
            throw FileOpenError.unreadableEncoding(fileURL)
        }

        return MarkdownDocument(
            fileURL: fileURL,
            rawMarkdown: markdown,
            renderedHTML: nil
        )
    }

    /// Attempts a sensible decoding fallback chain.
    ///
    /// UTF-8 is preferred first, then common UTF-16 and legacy encodings.
    private func decodeString(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1252,
            .macOSRoman
        ]

        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }

        return nil
    }

    /// Converts supported extensions into UTTypes for open-panel filtering.
    @available(macOS 12.0, *)
    private static var allowedUTTypes: [UTType] {
        allowedExtensionsInDisplayOrder.compactMap { UTType(filenameExtension: $0) }
    }

    /// Returns the last directory used by the Markdown chooser, when present.
    private func persistedOpenPanelDirectoryURL() -> URL? {
        guard
            let storedPath = UserDefaults.standard.string(
                forKey: Self.markdownOpenPanelLastDirectoryDefaultsKey
            ),
            !storedPath.isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: storedPath, isDirectory: true)
    }

    /// Stores the directory that should seed the next Markdown chooser open.
    private func persistOpenPanelDirectory(from selectedURL: URL) {
        let directoryURL = selectedURL.hasDirectoryPath
            ? selectedURL
            : selectedURL.deletingLastPathComponent()

        UserDefaults.standard.set(
            directoryURL.standardizedFileURL.path,
            forKey: Self.markdownOpenPanelLastDirectoryDefaultsKey
        )
    }
}
