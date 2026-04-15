import Foundation
import UniformTypeIdentifiers

/// Errors thrown when bundled render assets are missing or unreadable.
enum MarkdownRenderError: LocalizedError {
    /// A required template/resource file could not be found in bundle.
    case missingResource(String)

    /// A resource exists but could not be decoded as UTF-8 text.
    case unreadableResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let resource):
            return "Missing renderer resource: \(resource)."
        case .unreadableResource(let resource):
            return "Unable to read renderer resource: \(resource)."
        }
    }
}

/// Builds a complete HTML document from Markdown source.
///
/// Rendering pipeline:
/// 1. Load local HTML/CSS/JS assets from bundle
/// 2. Escape Markdown into a safe JSON string literal
/// 3. Inject all assets into a controlled HTML template
struct MarkdownRenderService {
    /// Bundle from which render assets are loaded.
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Returns a full HTML document string ready for `WKWebView.loadHTMLString`.
    ///
    /// `baseDirectoryURL` is injected into a `<base>` tag so relative image
    /// and link paths in Markdown resolve exactly like filesystem-relative paths.
    func render(markdown: String, baseDirectoryURL: URL) throws -> String {
        let indexTemplate = try loadResource(named: "index", ext: "html")
        let styles = try loadResource(named: "styles", ext: "css")
        let markdownIt = try loadResource(named: "markdown-it.min", ext: "js")
        let highlight = try loadResource(named: "highlight.min", ext: "js")
        let highlightThemeCSSByTheme = try loadHighlightThemeCSSByTheme()
        let renderer = try loadResource(named: "renderer", ext: "js")

        // Inline local image links as `data:` URIs.
        //
        // Why this extra step exists:
        // - Some Xcode/WebKit debug environments can fail to load `file:` image
        //   subresources despite the main document rendering correctly.
        // - Inlining local images makes rendering deterministic and avoids
        //   dependency on helper-process file URL permissions.
        let markdownWithInlinedLocalImages = inlineLocalImages(
            in: markdown,
            baseDirectoryURL: baseDirectoryURL
        )

        // Encode user content safely before embedding into inline script.
        let markdownSource = SecurityHelpers.jsonStringLiteral(markdownWithInlinedLocalImages)
        let documentBaseURL = SecurityHelpers.htmlAttributeLiteral(baseDirectoryURL.absoluteString)
        let syntaxHighlightingEnabledJSON = UserDefaults.standard.bool(
            forKey: AppPreferenceKey.syntaxHighlightingEnabled
        ) ? "true" : "false"
        let syntaxHighlightingThemeRawValue = SyntaxHighlightTheme.resolved(
            from: UserDefaults.standard.string(
                forKey: AppPreferenceKey.syntaxHighlightingTheme
            ) ?? AppPreferenceDefault.syntaxHighlightingTheme
        ).rawValue
        let syntaxHighlightingThemeJSON = SecurityHelpers.jsonStringLiteral(
            syntaxHighlightingThemeRawValue
        )
        let documentTypefaceRawValue = DocumentTypeface.resolved(
            from: UserDefaults.standard.string(
                forKey: AppPreferenceKey.documentTypeface
            ) ?? AppPreferenceDefault.documentTypeface
        ).rawValue
        let documentTypefaceJSON = SecurityHelpers.jsonStringLiteral(
            documentTypefaceRawValue
        )
        let documentDensityRawValue = DocumentDensity.resolved(
            from: UserDefaults.standard.string(
                forKey: AppPreferenceKey.documentDensity
            ) ?? AppPreferenceDefault.documentDensity
        ).rawValue
        let documentDensityJSON = SecurityHelpers.jsonStringLiteral(
            documentDensityRawValue
        )

        return indexTemplate
            .replacingOccurrences(of: "{{STYLES_CSS}}", with: styles)
            .replacingOccurrences(of: "{{MARKDOWN_IT_JS}}", with: markdownIt)
            .replacingOccurrences(of: "{{HIGHLIGHT_JS}}", with: highlight)
            .replacingOccurrences(
                of: "{{HIGHLIGHT_THEME_GITHUB_CSS}}",
                with: highlightThemeCSSByTheme[.github] ?? ""
            )
            .replacingOccurrences(
                of: "{{HIGHLIGHT_THEME_VSCODE_CSS}}",
                with: highlightThemeCSSByTheme[.vscode] ?? ""
            )
            .replacingOccurrences(
                of: "{{HIGHLIGHT_THEME_ATOM_ONE_CSS}}",
                with: highlightThemeCSSByTheme[.atomOne] ?? ""
            )
            .replacingOccurrences(
                of: "{{HIGHLIGHT_THEME_STACKOVERFLOW_CSS}}",
                with: highlightThemeCSSByTheme[.stackOverflow] ?? ""
            )
            .replacingOccurrences(of: "{{RENDERER_JS}}", with: renderer)
            .replacingOccurrences(of: "{{DOCUMENT_BASE_URL}}", with: documentBaseURL)
            .replacingOccurrences(of: "{{MARKDOWN_SOURCE_JSON}}", with: markdownSource)
            .replacingOccurrences(
                of: "{{SYNTAX_HIGHLIGHTING_ENABLED_JSON}}",
                with: syntaxHighlightingEnabledJSON
            )
            .replacingOccurrences(
                of: "{{SYNTAX_HIGHLIGHTING_THEME_JSON}}",
                with: syntaxHighlightingThemeJSON
            )
            .replacingOccurrences(
                of: "{{DOCUMENT_TYPEFACE_JSON}}",
                with: documentTypefaceJSON
            )
            .replacingOccurrences(
                of: "{{DOCUMENT_DENSITY_JSON}}",
                with: documentDensityJSON
            )
    }

    /// Rewrites Markdown image destinations pointing to local files into
    /// `data:` URI destinations.
    ///
    /// This keeps behaviour stable when WebKit declines file subresource loads.
    /// Unsupported/unreadable image paths are left unchanged.
    private func inlineLocalImages(in markdown: String, baseDirectoryURL: URL) -> String {
        // Matches Markdown image syntax and captures the destination section.
        // Example matched destination: `sample-image.png`
        // Example matched destination with title: `sample-image.png "caption"`
        let pattern = #"!\[[^\]]*\]\(([^)\n]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return markdown
        }

        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        let matches = regex.matches(in: markdown, options: [], range: fullRange)

        guard !matches.isEmpty else {
            return markdown
        }

        // Apply replacements from end to start so earlier ranges stay valid.
        let mutable = NSMutableString(string: markdown)
        for match in matches.reversed() {
            let destinationRange = match.range(at: 1)
            guard destinationRange.location != NSNotFound else { continue }

            let destinationWithOptionalTitle = nsMarkdown.substring(with: destinationRange)
            let split = splitMarkdownDestinationAndOptionalTitle(destinationWithOptionalTitle)

            guard let localImageFileURL = resolveLocalImageURL(
                fromMarkdownDestination: split.destination,
                baseDirectoryURL: baseDirectoryURL
            ) else {
                continue
            }

            guard let dataURI = makeDataURI(from: localImageFileURL) else {
                continue
            }

            // Preserve any optional Markdown image title suffix.
            let replacement = dataURI + split.suffix
            mutable.replaceCharacters(in: destinationRange, with: replacement)
        }

        return mutable as String
    }

    /// Splits a Markdown destination segment into URL part plus optional suffix.
    ///
    /// Examples:
    /// - `sample.png` -> destination=`sample.png`, suffix=``
    /// - `sample.png "caption"` -> destination=`sample.png`, suffix=` "caption"`
    /// - `<folder/sample image.png>` -> destination=`folder/sample image.png`, suffix=``
    private func splitMarkdownDestinationAndOptionalTitle(_ rawValue: String) -> (destination: String, suffix: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (rawValue, "") }

        // Angle-bracket form allows spaces in path.
        if trimmed.hasPrefix("<"), let closingBracketIndex = trimmed.firstIndex(of: ">") {
            let start = trimmed.index(after: trimmed.startIndex)
            let destination = String(trimmed[start..<closingBracketIndex])
            let suffix = String(trimmed[trimmed.index(after: closingBracketIndex)...])
            return (destination, suffix)
        }

        // Standard form: destination followed by optional title.
        // We detect title suffix by the first whitespace.
        if let firstWhitespaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) {
            let destination = String(trimmed[..<firstWhitespaceIndex])
            let suffix = String(trimmed[firstWhitespaceIndex...])
            return (destination, suffix)
        }

        return (trimmed, "")
    }

    /// Resolves a Markdown image destination into a local file URL, if possible.
    ///
    /// Remote URLs are ignored because they should remain external references.
    private func resolveLocalImageURL(fromMarkdownDestination destination: String, baseDirectoryURL: URL) -> URL? {
        let decodedDestination = (destination.removingPercentEncoding ?? destination)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !decodedDestination.isEmpty else {
            return nil
        }

        // Keep remote/data URIs untouched.
        if let scheme = URL(string: decodedDestination)?.scheme?.lowercased(),
           ["http", "https", "data"].contains(scheme) {
            return nil
        }

        let resolvedURL: URL

        if decodedDestination.hasPrefix("file://"), let fileURL = URL(string: decodedDestination) {
            resolvedURL = fileURL
        } else if decodedDestination.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: decodedDestination)
        } else {
            // Use path-component joining for relative image paths so local file
            // destinations remain explicit absolute file URLs.
            resolvedURL = baseDirectoryURL.appendingPathComponent(decodedDestination)
        }

        let cleanURL = PathResolver
            .strippingFragmentAndQuery(from: resolvedURL.absoluteURL)
            .standardizedFileURL
        guard cleanURL.isFileURL else {
            return nil
        }

        return cleanURL
    }

    /// Converts a local image file URL into a `data:` URI string.
    ///
    /// Very large images are skipped to avoid unreasonable memory expansion.
    private func makeDataURI(from fileURL: URL) -> String? {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              resourceValues.isRegularFile == true else {
            return nil
        }

        // Avoid inflating massive images inline.
        if let fileSize = resourceValues.fileSize, fileSize > 8_000_000 {
            return nil
        }

        guard let imageData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }

        let mimeType = mimeTypeForImage(at: fileURL)
        let base64 = imageData.base64EncodedString()
        return "data:\(mimeType);base64,\(base64)"
    }

    /// Attempts to map a file extension to a MIME type for `data:` URIs.
    private func mimeTypeForImage(at fileURL: URL) -> String {
        let ext = fileURL.pathExtension
        if let type = UTType(filenameExtension: ext),
           let preferredMIMEType = type.preferredMIMEType {
            return preferredMIMEType
        }

        // Conservative fallback for unknown image extensions.
        return "application/octet-stream"
    }

    /// Reads one UTF-8 text resource from `QuickMarkdownViewer/Web` in the app bundle.
    private func loadResource(named name: String, ext: String) throws -> String {
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Web")
            ?? bundle.url(forResource: name, withExtension: ext)

        guard let url else {
            throw MarkdownRenderError.missingResource("\(name).\(ext)")
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MarkdownRenderError.unreadableResource("\(name).\(ext)")
        }

        return text
    }

    /// Wraps highlight.js themes so screen uses light/dark variants and print uses light.
    private func makeHighlightThemeCSS(lightThemeCSS: String, darkThemeCSS: String) -> String {
        """
        \(lightThemeCSS)

        @media screen and (prefers-color-scheme: dark) {
          \(darkThemeCSS)
        }
        """
    }

    /// Loads all bundled highlight.js theme families.
    private func loadHighlightThemeCSSByTheme() throws -> [SyntaxHighlightTheme: String] {
        let githubLight = try loadResource(named: "highlight-github.min", ext: "css")
        let githubDark = try loadResource(named: "highlight-github-dark.min", ext: "css")
        let vscodeLight = try loadResource(named: "highlight-vs.min", ext: "css")
        let vscodeDark = try loadResource(named: "highlight-vs2015.min", ext: "css")
        let atomOneLight = try loadResource(named: "highlight-atom-one-light.min", ext: "css")
        let atomOneDark = try loadResource(named: "highlight-atom-one-dark.min", ext: "css")
        let stackOverflowLight = try loadResource(named: "highlight-stackoverflow-light.min", ext: "css")
        let stackOverflowDark = try loadResource(named: "highlight-stackoverflow-dark.min", ext: "css")

        return [
            .github: makeHighlightThemeCSS(
                lightThemeCSS: githubLight,
                darkThemeCSS: githubDark
            ),
            .vscode: makeHighlightThemeCSS(
                lightThemeCSS: vscodeLight,
                darkThemeCSS: vscodeDark
            ),
            .atomOne: makeHighlightThemeCSS(
                lightThemeCSS: atomOneLight,
                darkThemeCSS: atomOneDark
            ),
            .stackOverflow: makeHighlightThemeCSS(
                lightThemeCSS: stackOverflowLight,
                darkThemeCSS: stackOverflowDark
            )
        ]
    }
}
