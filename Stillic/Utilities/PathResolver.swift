import Foundation

/// Path and URL helpers for local Markdown navigation.
///
/// The resolver keeps URL logic in one place so link handling remains
/// predictable and easy to audit.
enum PathResolver {
    /// True when a URL points to a supported Markdown extension.
    static func isMarkdownFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"].contains(ext)
    }

    /// Resolves local file references against a base directory.
    ///
    /// - Absolute `file:` links are normalised directly.
    /// - Relative links are resolved using standard URL semantics.
    /// - Query and fragment are stripped for file-open routing decisions.
    static func resolveLocalURL(_ url: URL, relativeTo baseURL: URL) -> URL {
        if url.isFileURL {
            return strippingFragmentAndQuery(from: url).standardizedFileURL
        }

        let resolved = URL(string: url.relativeString, relativeTo: baseURL) ?? url
        return strippingFragmentAndQuery(from: resolved).standardizedFileURL
    }

    /// Returns true when the URL targets an anchor within the current document.
    static func isSameDocumentAnchor(_ url: URL, currentDocumentURL: URL?) -> Bool {
        guard let currentDocumentURL else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              !fragment.isEmpty else {
            return false
        }

        let standardisedCurrent = strippingFragmentAndQuery(from: currentDocumentURL).standardizedFileURL
        let standardisedURL = strippingFragmentAndQuery(from: url).standardizedFileURL

        return standardisedCurrent == standardisedURL
    }

    /// Removes query string and fragment from a URL for path equivalence checks.
    static func strippingFragmentAndQuery(from url: URL) -> URL {
        // Resolve against any base URL first so we do not accidentally turn an
        // absolute file URL back into a relative path while stripping parts.
        let absoluteURL = url.absoluteURL

        guard var components = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: true) else {
            return absoluteURL
        }

        components.fragment = nil
        components.query = nil
        return (components.url ?? absoluteURL).absoluteURL
    }
}
