import AppKit
import Foundation

/// Thin wrapper for native Recent Documents integration.
///
/// Keeping this isolated makes app routing easier to test and keeps
/// direct AppKit calls out of higher-level flow code.
struct RecentDocumentService {
    /// Registers a file URL with the shared macOS recent-documents list.
    func note(_ fileURL: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
    }

    /// Returns current recent-document URLs from macOS.
    ///
    /// These are maintained by `NSDocumentController` and shown in File menu
    /// entries such as "Open Recent". We keep this as a thin passthrough so the
    /// service stays easy to reason about and test.
    func recentDocumentURLs() -> [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    /// Clears the system-managed recent-documents list for this app.
    ///
    /// Using the native controller keeps behaviour consistent with standard
    /// macOS "Clear Menu" expectations.
    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
