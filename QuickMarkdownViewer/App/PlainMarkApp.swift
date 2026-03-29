import SwiftUI
import Darwin

/// Main application entry point for QuickMarkdownViewer.
///
/// This app is intentionally document-first and lightweight:
/// - No editor surface
/// - Minimal chrome
/// - One rendered Markdown document per window
@main
struct QuickMarkdownViewerApp: App {
    /// Central routing object shared with the AppKit delegate bridge.
    ///
    /// Using one shared router keeps menu actions, Finder open events,
    /// and manual window creation fully consistent.
    @MainActor private let routing = AppRouting.shared

    /// Bridges SwiftUI lifecycle hooks with `NSApplicationDelegate`
    /// callbacks such as Finder/Dock open-file events.
    @NSApplicationDelegateAdaptor(QuickMarkdownViewerAppDelegate.self) private var appDelegate

    /// Initialiser used for one runtime compatibility safeguard.
    ///
    /// Xcode can inject debugger helper dynamic libraries into the app process.
    /// Clearing these environment variables early helps avoid `WKWebView`
    /// helper-process launch instability in some local debug environments.
    init() {
        unsetenv("DYLD_INSERT_LIBRARIES")
        unsetenv("__XPC_DYLD_INSERT_LIBRARIES")
    }

    var body: some Scene {
        Settings {
            // QuickMarkdownViewer has no preferences window in v1.
            EmptyView()
        }
        .commands {
            // Install a small command set that mirrors standard macOS
            // expectations for a document viewer.
            AppCommands(routing: routing)
        }
    }
}
