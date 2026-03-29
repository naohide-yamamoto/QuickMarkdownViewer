import AppKit
import Foundation

/// Decides how clicked links should be handled from the Markdown web view.
///
/// Routing rules:
/// - In-document anchors: allow internal scrolling
/// - `http/https/mailto`: open externally via default apps
/// - `file:` Markdown: open in a new QuickMarkdownViewer window
/// - `file:` non-Markdown: pass to `NSWorkspace`
struct LinkRoutingService {
    /// Navigation decision used by `WKNavigationDelegate`.
    enum Decision {
        /// Let WKWebView continue navigation.
        case allow

        /// Cancel WKWebView navigation because we handled it ourselves.
        case cancel
    }

    /// Evaluates one clicked URL and returns the preferred navigation policy.
    func route(
        url: URL,
        currentDocumentURL: URL?,
        baseDirectoryURL: URL,
        onOpenMarkdown: (URL) -> Void
    ) -> Decision {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // `about:blank#anchor` is generated internally by the web view for
        // same-document fragment jumps, so it should remain in-webview.
        if url.scheme == "about", let fragment = components?.fragment, !fragment.isEmpty {
            return .allow
        }

        // Also allow explicit same-file anchors such as `file:///x.md#section`.
        if PathResolver.isSameDocumentAnchor(url, currentDocumentURL: currentDocumentURL) {
            return .allow
        }

        guard let scheme = url.scheme?.lowercased() else {
            return .cancel
        }

        switch scheme {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
            return .cancel

        case "file":
            let resolved = PathResolver.resolveLocalURL(url, relativeTo: baseDirectoryURL)
            if PathResolver.isMarkdownFile(url: resolved) {
                onOpenMarkdown(resolved)
            } else {
                NSWorkspace.shared.open(resolved)
            }
            return .cancel

        default:
            // Unknown schemes are intentionally blocked to keep behaviour safe.
            return .cancel
        }
    }
}
