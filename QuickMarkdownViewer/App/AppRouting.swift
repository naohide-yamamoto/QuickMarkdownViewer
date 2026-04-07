import AppKit
import Combine
import SwiftUI
import WebKit

/// Notification posted when the app-level Find commands should act on a window.
extension Notification.Name {
    static let quickMarkdownViewerFindCommand = Notification.Name("QuickMarkdownViewer.FindCommand")

    /// Notification posted when the app-level Zoom commands should act on a window.
    static let quickMarkdownViewerZoomCommand = Notification.Name("QuickMarkdownViewer.ZoomCommand")

    /// Notification posted when document actions should act on a window.
    static let quickMarkdownViewerDocumentCommand = Notification.Name("QuickMarkdownViewer.DocumentCommand")

    /// Notification posted when a document window publishes Find state updates.
    static let quickMarkdownViewerFindStateDidChange = Notification.Name("QuickMarkdownViewer.FindStateDidChange")
}

/// Supported in-document Find actions for QuickMarkdownViewer windows.
///
/// These values are serialised into notification payloads so menu commands can
/// target the currently active document window without coupling AppCommands to
/// any specific SwiftUI view instance.
enum QuickMarkdownViewerFindCommand: String {
    /// Move to the next match for the current search query.
    case findNext

    /// Move to the previous match for the current search query.
    case findPrevious

    /// Capture current text selection and use it as the Find query.
    case useSelectionForFind

    /// Jump to the next match for current selection/query.
    case jumpToSelection

    /// Hide the find bar while preserving the current query text.
    case hideFindBar

    /// Updates the active Find query text.
    case setFindQuery

    /// Updates whether Find uses case-sensitive matching.
    case setFindCaseSensitivity
}

/// Keys used in `quickMarkdownViewerFindCommand` notification payloads.
enum QuickMarkdownViewerFindCommandUserInfoKey: String {
    /// The `QuickMarkdownViewerFindCommand.rawValue` to execute.
    case command

    /// Integer `windowNumber` that should handle the command.
    case targetWindowNumber

    /// Updated Find query value supplied by toolbar/panel UI.
    case query

    /// Updated case-sensitivity state supplied by toolbar/panel UI.
    case isCaseSensitive

    /// True when the query update should trigger an immediate search.
    case shouldRunSearch

    /// True when Find failures should beep.
    case shouldBeepOnNoMatch
}

/// Supported in-document zoom actions for QuickMarkdownViewer windows.
///
/// These values are carried through notifications so `AppCommands` can trigger
/// zoom behaviour on whichever document window is currently active.
enum QuickMarkdownViewerZoomCommand: String {
    /// Increase document zoom by one step.
    case zoomIn

    /// Decrease document zoom by one step.
    case zoomOut

    /// Reset document zoom to the default 100%.
    case resetToActualSize

    /// Scale document zoom so the content column fits the current window.
    case zoomToFit
}

/// Keys used in `quickMarkdownViewerZoomCommand` notification payloads.
enum QuickMarkdownViewerZoomCommandUserInfoKey: String {
    /// The `QuickMarkdownViewerZoomCommand.rawValue` to execute.
    case command

    /// Integer `windowNumber` that should handle the command.
    case targetWindowNumber
}

/// Supported document actions for QuickMarkdownViewer windows.
///
/// These actions are dispatched from app-level commands and handled by the
/// currently active document window, keeping menu code decoupled from views.
enum QuickMarkdownViewerDocumentCommand: String {
    /// Print the currently rendered Markdown document.
    case printRenderedDocument

    /// Export the currently rendered Markdown document as PDF.
    case exportRenderedPDF

    /// Open the source Markdown file in the system default text editor.
    case viewSourceExternally

    /// Start speaking selected text, or fall back to full document content.
    case startSpeaking

    /// Stop any in-progress document speech.
    case stopSpeaking
}

/// Keys used in `quickMarkdownViewerDocumentCommand` notification payloads.
enum QuickMarkdownViewerDocumentCommandUserInfoKey: String {
    /// The `QuickMarkdownViewerDocumentCommand.rawValue` to execute.
    case command

    /// Integer `windowNumber` that should handle the command.
    case targetWindowNumber
}

/// AppKit delegate bridge used for Finder and Dock open-file events.
///
/// We keep it intentionally thin: collect incoming file URLs and hand them
/// to the shared `AppRouting` instance on the main actor.
final class QuickMarkdownViewerAppDelegate: NSObject, NSApplicationDelegate {
    /// File URLs received before launch has fully completed.
    private var pendingURLs: [URL] = []

    /// True once any file-open event has been delivered by macOS.
    private var hasReceivedFileOpenRequest = false

    /// True after `applicationDidFinishLaunching` fires.
    private var didFinishLaunching = false

    /// Deferred task that opens the initial empty window when appropriate.
    private var initialEmptyWindowWorkItem: DispatchWorkItem?

    /// Fallback print action used when AppKit routes `printDocument:` through
    /// the responder chain (for example, default File > Print behaviour).
    ///
    /// This keeps `Cmd+P` reliable even if a system-provided print command is
    /// active in the exported app menu structure.
    @objc func printDocument(_ sender: Any?) {
        Task { @MainActor in
            AppRouting.shared.printRenderedDocumentInActiveWindow()
        }
    }

    /// Additional compatibility selector for templates that use `print:`.
    @objc func print(_ sender: Any?) {
        Task { @MainActor in
            AppRouting.shared.printRenderedDocumentInActiveWindow()
        }
    }

    /// Fallback export action for menu templates that route through selectors.
    @objc func exportRenderedPDF(_ sender: Any?) {
        Task { @MainActor in
            AppRouting.shared.exportRenderedPDFInActiveWindow()
        }
    }

    /// Finalises launch state and opens an empty window only when needed.
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRouting.shared.applyPersistedAppearanceMode()
        AppRouting.shared.prewarmWebViewIfNeeded()
        didFinishLaunching = true
        flushPendingFilesIfNeeded()
        retargetMainMenuDocumentActionsIfNeeded()
        scheduleInitialEmptyWindowIfNeeded()
    }

    /// Handles modern URL-based open events from Finder and Dock.
    ///
    /// On newer macOS versions, document opens can arrive through this API
    /// rather than `application(_:openFiles:)`. Routing both paths keeps
    /// QuickMarkdownViewer reliable when users double-click Markdown files.
    func application(_ application: NSApplication, open urls: [URL]) {
        routeIncomingURLs(urls)
    }

    /// Handles multi-file "Open With" events (legacy AppKit path).
    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        routeIncomingURLs(urls)
        application.reply(toOpenOrPrint: .success)
    }

    /// Handles single-file open events (legacy AppKit path).
    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        routeIncomingURLs([URL(fileURLWithPath: filename)])
        return true
    }

    /// Handles single-file open events requested without UI presentation.
    ///
    /// This can be used by some automation/system flows, so routing it keeps
    /// behaviour consistent with normal Finder opens.
    func application(_ sender: Any, openFileWithoutUI filename: String) -> Bool {
        routeIncomingURLs([URL(fileURLWithPath: filename)])
        return true
    }

    /// Prevents AppKit from attempting to restore prior window state.
    ///
    /// QuickMarkdownViewer controls fresh-window behaviour explicitly at launch, so
    /// restoration is disabled to avoid stale/duplicate windows.
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    /// Prevents AppKit from writing restoration state for next launch.
    ///
    /// This keeps startup deterministic during development and aligns with the
    /// tiny utility behaviour expected from QuickMarkdownViewer.
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    /// Disables AppKit's default "open untitled document" behaviour.
    ///
    /// QuickMarkdownViewer controls its own empty/document window flow, so allowing this
    /// AppKit path could create duplicate windows.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopens a fresh empty window when the dock icon is clicked and all
    /// windows are currently closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        Task { @MainActor in
            AppRouting.shared.openInitialEmptyWindowIfNeeded()
        }

        return true
    }

    /// Delivers any queued file-open requests after launch completes.
    private func flushPendingFilesIfNeeded() {
        guard !pendingURLs.isEmpty else { return }

        let urls = pendingURLs
        pendingURLs.removeAll()

        Task { @MainActor in
            AppRouting.shared.openFiles(urls)
        }
    }

    /// Routes incoming file URLs immediately or queues them until ready.
    ///
    /// We normalise and de-duplicate URLs to avoid accidental duplicate
    /// windows when macOS delivers equivalent open events more than once.
    private func routeIncomingURLs(_ urls: [URL]) {
        let normalisedFileURLs = deduplicatedFileURLs(from: urls)
        guard !normalisedFileURLs.isEmpty else { return }

        hasReceivedFileOpenRequest = true
        initialEmptyWindowWorkItem?.cancel()

        if didFinishLaunching {
            // Hop to the main actor because `AppRouting` is main-actor isolated.
            Task { @MainActor in
                AppRouting.shared.openFiles(normalisedFileURLs)
            }
        } else {
            // If launch has not finished yet, queue file opens temporarily.
            pendingURLs.append(contentsOf: normalisedFileURLs)
            pendingURLs = deduplicatedFileURLs(from: pendingURLs)
        }
    }

    /// Opens the initial empty window when app launch had no file-open request.
    ///
    /// We wait briefly to avoid flashing an empty window during Finder
    /// double-click flows, where open-file events can arrive a moment later.
    private func scheduleInitialEmptyWindowIfNeeded() {
        guard !hasReceivedFileOpenRequest else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingURLs.isEmpty, !self.hasReceivedFileOpenRequest else { return }

            Task { @MainActor in
                AppRouting.shared.openInitialEmptyWindowIfNeeded()
            }
        }

        initialEmptyWindowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    /// Rebinds key File-menu actions to explicit app handlers.
    ///
    /// In some exported-app menu configurations, AppKit can route Print to a
    /// default responder action that shows "application does not support
    /// printing". Explicit targets keep behaviour deterministic.
    private func retargetMainMenuDocumentActionsIfNeeded() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let printItem = firstMenuItem(in: mainMenu, where: { item in
            item.keyEquivalent.lowercased() == "p" &&
                item.keyEquivalentModifierMask.contains(.command)
        }) {
            printItem.target = self
            printItem.action = #selector(printDocument(_:))
        }

        if let exportItem = firstMenuItem(in: mainMenu, where: { item in
            item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("Export as PDF")
        }) {
            exportItem.target = self
            exportItem.action = #selector(exportRenderedPDF(_:))
        }
    }

    /// Returns the first menu item matching `predicate`, searching recursively.
    private func firstMenuItem(in menu: NSMenu, where predicate: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu.items {
            if predicate(item) {
                return item
            }

            if let submenu = item.submenu,
               let match = firstMenuItem(in: submenu, where: predicate) {
                return match
            }
        }

        return nil
    }

    /// Returns unique, standardised file URLs in stable input order.
    private func deduplicatedFileURLs(from urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var ordered: [URL] = []

        for url in urls where url.isFileURL {
            let standardised = url.standardizedFileURL
            let path = standardised.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            ordered.append(standardised)
        }

        return ordered
    }
}

/// One-shot hidden `WKWebView` warmup to reduce first-document latency.
@MainActor
private final class WebViewPrewarmer: NSObject, WKNavigationDelegate {
    /// Retained hidden web view while warmup is in progress.
    private var prewarmWebView: WKWebView?

    /// Ensures prewarm executes at most once per app run.
    private var hasStarted = false

    /// Starts prewarming WebKit/WebContent process state once.
    func prewarmIfNeeded() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        prewarmWebView = webView

        Logger.info("[PERF] webview-prewarm-start")
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head><body></body></html>
            """,
            baseURL: nil
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Logger.info("[PERF] webview-prewarm-finish")
        releasePrewarmWebView()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Logger.error("WKWebView prewarm failed: \(error.localizedDescription)")
        releasePrewarmWebView()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Logger.error("WKWebView prewarm provisional failure: \(error.localizedDescription)")
        releasePrewarmWebView()
    }

    /// Releases temporary warmup state once the one-shot load completes.
    private func releasePrewarmWebView() {
        prewarmWebView?.stopLoading()
        prewarmWebView?.navigationDelegate = nil
        prewarmWebView = nil
    }
}

/// Main app router responsible for opening files and creating document windows.
@MainActor
final class AppRouting: ObservableObject {
    /// One native share-service entry shown under File > Share.
    struct ShareServiceEntry: Identifiable {
        /// Stable identifier used by SwiftUI menu rendering.
        let id: String

        /// User-visible menu title from `NSSharingService`.
        let title: String

        /// Optional menu icon from `NSSharingService`.
        let image: NSImage?

        /// Backing AppKit share service invoked on selection.
        let service: NSSharingService

        /// Document URL associated with this menu snapshot.
        let fileURL: URL
    }
    /// Shared router instance used by SwiftUI commands and AppKit delegate flow.
    static let shared = AppRouting()

    /// Explicit appearance override mode applied to the app.
    ///
    /// We keep this intentionally binary for now because the user request is a
    /// direct light/dark toggle rather than a full appearance preferences UI.
    private enum AppearanceMode: String {
        /// Force light appearance for app chrome and rendered content.
        case light

        /// Force dark appearance for app chrome and rendered content.
        case dark
    }

    /// Reason a file open request is being rejected.
    private enum UnsupportedOpenReason {
        /// The file is Markdown-adjacent but intentionally unsupported in v1.
        case unsupportedMarkdownVariant

        /// The file extension is not one QuickMarkdownViewer accepts.
        case unsupportedFileType
    }

    /// Service that validates and reads Markdown files.
    private let fileOpenService = FileOpenService()

    /// Service that renders Markdown into a complete HTML document string.
    private let renderService = MarkdownRenderService()

    /// One-shot runtime prewarmer for initial `WKWebView` startup overhead.
    private let webViewPrewarmer = WebViewPrewarmer()

    /// Thin wrapper over native macOS "Recent Documents" behaviour.
    private let recentDocumentService = RecentDocumentService()

    /// Defaults key storing the last user-selected appearance mode.
    private let appearanceModeDefaultsKey = "QuickMarkdownViewer.AppearanceMode.v1"

    /// Defaults store used for tiny viewer preferences.
    private let defaults: UserDefaults

    /// Strong references for open windows.
    ///
    /// We retain controllers explicitly so windows remain alive until closed.
    private var windowControllers: [UUID: DocumentWindowController] = [:]

    /// Last document-window frame used for cascade placement fallback.
    ///
    /// If no key document window exists (for example, while opening multiple
    /// files from Finder at launch), we still want subsequent windows to shift
    /// slightly rather than stack perfectly on top of each other.
    private var lastDocumentWindowFrame: NSRect?

    /// Tiny published token used to refresh command menus when recents change.
    ///
    /// SwiftUI command views observe this router object. Bumping this value
    /// triggers a lightweight menu refresh so "Open Recent" always reflects
    /// the latest native recent-documents state.
    @Published private var recentDocumentsRevision: UInt = 0

    /// Tiny published token used to refresh toolbar-related command labels.
    @Published private var toolbarVisibilityRevision: UInt = 0

    /// Read-only token consumed by SwiftUI commands to refresh toolbar labels.
    var toolbarVisibilityMenuRevision: UInt {
        toolbarVisibilityRevision
    }

    /// Most recent document window used for menu-state fallback routing.
    private weak var lastRoutedDocumentWindow: NSWindow?

    /// Private init enforces the shared-router model.
    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Presents the standard file chooser for Markdown documents.
    func openDocumentPanel() {
        guard let urls = fileOpenService.selectMarkdownFiles() else { return }
        openFiles(urls)
    }

    /// Runs one-time hidden `WKWebView` warmup after launch.
    func prewarmWebViewIfNeeded() {
        webViewPrewarmer.prewarmIfNeeded()
    }

    /// Opens the app's registered Apple Help Book.
    ///
    /// This path integrates with the native Help menu search field shown in
    /// macOS menu bar UI, so users can search indexed Help topics directly.
    /// If Help Viewer cannot resolve the book in local/dev environments, we
    /// gracefully fall back to the bundled README rendered in-app.
    func openHelpDocumentation() {
        let helpBookName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleHelpBookName"
        ) as? String
        let helpBookFolder = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleHelpBookFolder"
        ) as? String

        guard
            let helpBookName, !helpBookName.isEmpty,
            let helpBookFolder, !helpBookFolder.isEmpty
        else {
            openBundledHelpFallbackWithWarning()
            Logger.error("Help book keys are missing in Info.plist.")
            return
        }

        // Resolve the bundled Help Book identifier from the `.help` bundle
        // itself. The `help:` URL scheme expects `bookID` to be this bundle
        // identifier, not the display title.
        guard
            let helpBookBundleURL = Bundle.main.url(forResource: helpBookFolder, withExtension: nil),
            let helpBookBundle = Bundle(url: helpBookBundleURL),
            let helpBookIdentifier = helpBookBundle.bundleIdentifier,
            !helpBookIdentifier.isEmpty
        else {
            openBundledHelpFallbackWithWarning()
            Logger.error("Unable to resolve Help Book bundle identifier.")
            return
        }

        // Explicitly register the main bundle's Help Book before opening.
        // This improves reliability for local debug runs.
        let didRegisterHelpBook = NSHelpManager.shared.registerBooks(in: .main)
        guard didRegisterHelpBook else {
            openBundledHelpFallbackWithWarning()
            Logger.error("Failed to register Help Book from main bundle.")
            return
        }
        Logger.info("Help Book registered successfully: \(helpBookName)")
        Logger.info("Resolved Help Book identifier: \(helpBookIdentifier)")

        // Open the bundled in-app help document directly for deterministic
        // behaviour across local runs. On some systems, Help Viewer can report
        // "selected content unavailable" even after successful registration and
        // anchor dispatch; this avoids that user-facing failure mode.
        Logger.info(
            "Opening bundled in-app help view (book name '\(helpBookName)', id: \(helpBookIdentifier))."
        )
        openBundledHelpFallbackSilently()
    }

    /// Opens each file URL in its own window.
    func openFiles(_ urls: [URL]) {
        urls.forEach { openFile($0) }
    }

    /// Returns native recent-document URLs for the File > Open Recent menu.
    ///
    /// Ordering is managed by `NSDocumentController` (most-recent first).
    func recentDocumentURLsForMenu() -> [URL] {
        recentDocumentService.recentDocumentURLs()
    }

    /// Opens a selected recent document using the normal open-file flow.
    ///
    /// Routing through `openFile` keeps all validation and warning behaviour
    /// identical to every other open path (Finder, drag-and-drop, Open panel).
    func openRecentDocument(_ fileURL: URL) {
        openFile(fileURL)
    }

    /// Clears File > Open Recent entries via native macOS behaviour.
    ///
    /// After clearing, we bump the refresh token so SwiftUI command menus
    /// immediately redraw with "No Recent Documents".
    func clearRecentDocuments() {
        recentDocumentService.clear()
        notifyRecentDocumentsChanged()
    }

    /// Opens/focuses Find UI in the currently active window (`Cmd+F`).
    ///
    /// When toolbar is visible, this focuses the toolbar search field.
    /// When toolbar is hidden, this shows/focuses the floating Find panel.
    func toggleFindInActiveWindow() {
        guard let controller = activeDocumentWindowController() else {
            NSSound.beep()
            return
        }

        controller.toggleFindUI()
    }

    /// Advances Find to the next match in the active window (`Cmd+G`).
    func findNextInActiveWindow() {
        dispatchFindCommandToActiveWindow(.findNext)
    }

    /// Moves Find to the previous match in the active window (`Shift+Cmd+G`).
    func findPreviousInActiveWindow() {
        dispatchFindCommandToActiveWindow(.findPrevious)
    }

    /// Hides Find UI in the active window.
    func hideFindInActiveWindow() {
        if let controller = activeDocumentWindowController() {
            controller.hideFindUI()
        }

        dispatchFindCommandToActiveWindow(.hideFindBar)
    }

    /// Toggles toolbar visibility for the currently active window.
    func toggleToolbarInActiveWindow() {
        guard let targetWindow = activeDocumentWindow() else {
            NSSound.beep()
            return
        }

        if let controller = controller(for: targetWindow) {
            controller.toggleToolbarVisibility()
            notifyToolbarVisibilityChanged()
            DispatchQueue.main.async { [weak self] in
                self?.notifyToolbarVisibilityChanged()
            }
            return
        }

        targetWindow.toggleToolbarShown(nil)
        notifyToolbarVisibilityChanged()
        DispatchQueue.main.async { [weak self] in
            self?.notifyToolbarVisibilityChanged()
        }
    }

    /// Returns whether the active routed window currently shows its toolbar.
    func isToolbarVisibleInActiveWindow() -> Bool {
        guard let targetWindow = activeDocumentWindow() else {
            return lastRoutedDocumentWindow?.toolbar?.isVisible ?? true
        }

        return targetWindow.toolbar?.isVisible ?? true
    }

    /// Opens native toolbar customisation for the active window.
    func customiseToolbarInActiveWindow() {
        guard let targetWindow = activeDocumentWindow() else {
            NSSound.beep()
            return
        }

        if let controller = controller(for: targetWindow) {
            controller.openToolbarCustomisation()
            return
        }

        if let toolbar = targetWindow.toolbar {
            toolbar.runCustomizationPalette(nil)
            return
        }

        NSSound.beep()
    }

    /// Copies current selection into Find query in the active window (`Cmd+E`).
    func useSelectionForFindInActiveWindow() {
        dispatchFindCommandToActiveWindow(.useSelectionForFind)
    }

    /// Jumps to selection/query match in the active window (`Cmd+J`).
    func jumpToSelectionInActiveWindow() {
        dispatchFindCommandToActiveWindow(.jumpToSelection)
    }

    /// Increases zoom in the currently active window (`Cmd` + `+`).
    func zoomInActiveWindow() {
        dispatchZoomCommandToActiveWindow(.zoomIn)
    }

    /// Decreases zoom in the currently active window (`Cmd` + `-`).
    func zoomOutActiveWindow() {
        dispatchZoomCommandToActiveWindow(.zoomOut)
    }

    /// Resets zoom in the currently active window to 100% (`Cmd` + `0`).
    func resetZoomInActiveWindow() {
        dispatchZoomCommandToActiveWindow(.resetToActualSize)
    }

    /// Fits zoom in the currently active window to available width (`Cmd` + `9`).
    func zoomToFitInActiveWindow() {
        dispatchZoomCommandToActiveWindow(.zoomToFit)
    }

    /// Dispatches a print command for the active document window (`Cmd+P`).
    func printRenderedDocumentInActiveWindow() {
        dispatchDocumentCommandToActiveWindow(.printRenderedDocument)
    }

    /// Dispatches an export-as-PDF command for the active document window.
    func exportRenderedPDFInActiveWindow() {
        dispatchDocumentCommandToActiveWindow(.exportRenderedPDF)
    }

    /// Dispatches a view-source command for the active document window.
    func viewSourceExternallyInActiveWindow() {
        dispatchDocumentCommandToActiveWindow(.viewSourceExternally)
    }

    /// Returns true when Start Speaking should be available for the active window.
    func canStartSpeechInActiveWindow() -> Bool {
        hasActiveDocumentWindowForCommands
    }

    /// Returns true when Stop Speaking should be available for the active window.
    func canStopSpeechInActiveWindow() -> Bool {
        hasActiveDocumentWindowForCommands
    }

    /// Starts speech from the active document.
    func startSpeakingInActiveWindow() {
        dispatchDocumentCommandToActiveWindow(.startSpeaking)
    }

    /// Stops active speech for the current document.
    func stopSpeakingInActiveWindow() {
        dispatchDocumentCommandToActiveWindow(.stopSpeaking)
    }

    /// Returns native share services for the currently active document window.
    ///
    /// This powers the File > Share submenu so users see system-provided share
    /// destinations directly in the menu hierarchy (Preview-like behaviour).
    func shareServicesForActiveDocument() -> [ShareServiceEntry] {
        guard let fileURL = activeDocumentFileURLForCommands() else {
            return []
        }

        return NSSharingService.sharingServices(forItems: [fileURL]).enumerated().map { index, service in
            let identifierComponent = service.title.replacingOccurrences(of: " ", with: "-").lowercased()
            return ShareServiceEntry(
                id: "\(identifierComponent)-\(index)",
                title: service.title,
                image: service.image,
                service: service,
                fileURL: fileURL
            )
        }
    }

    /// Executes one share service selected from File > Share.
    func performShareService(_ entry: ShareServiceEntry) {
        entry.service.perform(withItems: [entry.fileURL])
    }

    /// Applies the persisted appearance mode after app launch.
    ///
    /// We call this once from `applicationDidFinishLaunching` so the app opens
    /// immediately in the previously selected light/dark mode.
    func applyPersistedAppearanceMode() {
        guard let rawValue = defaults.string(forKey: appearanceModeDefaultsKey),
              let mode = AppearanceMode(rawValue: rawValue) else {
            return
        }

        applyAppearance(mode)
    }

    /// Toggles appearance between light and dark modes and persists the choice.
    ///
    /// If no prior explicit selection exists, we infer current effective mode
    /// and switch to the opposite mode so behaviour feels natural.
    func toggleLightDarkAppearance() {
        let currentMode = persistedAppearanceMode() ?? effectiveAppearanceMode()
        let nextMode: AppearanceMode = currentMode == .dark ? .light : .dark
        setPersistedAppearanceMode(nextMode)
        applyAppearance(nextMode)
    }

    /// Forces the app into light appearance and persists the selection.
    ///
    /// This supports explicit one-tap mode selection from the document
    /// toolbar without requiring users to cycle through a toggle action.
    func setLightAppearanceMode() {
        setPersistedAppearanceMode(.light)
        applyAppearance(.light)
    }

    /// Forces the app into dark appearance and persists the selection.
    ///
    /// This supports explicit one-tap mode selection from the document
    /// toolbar without requiring users to cycle through a toggle action.
    func setDarkAppearanceMode() {
        setPersistedAppearanceMode(.dark)
        applyAppearance(.dark)
    }

    /// Opens the initial empty-state window when no other windows are present.
    ///
    /// This is used for plain app launches and dock-icon reopen behaviour.
    func openInitialEmptyWindowIfNeeded() {
        let hasVisibleTitledWindow = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled)
        }

        guard !hasVisibleTitledWindow else { return }
        showEmptyWindow()
    }

    /// Builds and shows one empty-state window.
    private func showEmptyWindow() {
        let emptyState = DocumentState(fileURL: nil)

        let rootView = DocumentWindowView(
            documentState: emptyState,
            onOpenFile: { [weak self] url in
                self?.openFile(url)
            },
            onOpenAnotherFile: { [weak self] in
                self?.openDocumentPanel()
            },
            onSetLightAppearance: { [weak self] in
                self?.setLightAppearanceMode()
            },
            onSetDarkAppearance: { [weak self] in
                self?.setDarkAppearanceMode()
            }
        )

        let hostingController = NSHostingController(rootView: rootView)

        let initialFrame = NSRect(x: 0, y: 0, width: 940, height: 760)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Quick Markdown Viewer"
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(origin: .zero, size: initialFrame.size), display: false)
        window.center()

        let windowID = UUID()
        let controller = DocumentWindowController(
            window: window,
            id: windowID,
            documentState: emptyState,
            fileOpenService: fileOpenService,
            renderService: renderService
        ) { [weak self] closedID in
            self?.windowControllers.removeValue(forKey: closedID)
        }
        window.delegate = controller
        windowControllers[windowID] = controller

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        // Keep launch behaviour aligned with Preview-style utilities:
        // no control (including the top search field) should be focused by
        // default when a new QuickMarkdownViewer window appears.
        DispatchQueue.main.async { [weak window] in
            guard let window else {
                return
            }

            // Avoid stealing focus from explicit user actions (for example Cmd+F
            // immediately after opening a document).
            if window.firstResponder is NSSearchField {
                return
            }

            _ = window.makeFirstResponder(nil)
        }
    }

    /// Validates and opens one file URL.
    func openFile(_ fileURL: URL) {
        let standardisedFileURL = fileURL.standardizedFileURL

        // R Markdown and Quarto files are intentionally not supported in v1.
        // Show a clear warning rather than only beeping.
        if fileOpenService.isExplicitlyUnsupportedMarkdownVariant(url: standardisedFileURL) {
            presentUnsupportedFileWarning(
                for: standardisedFileURL,
                reason: .unsupportedMarkdownVariant
            )
            Logger.info("Blocked unsupported Markdown variant: \(standardisedFileURL.path)")
            return
        }

        guard fileOpenService.supports(url: standardisedFileURL) else {
            presentUnsupportedFileWarning(
                for: standardisedFileURL,
                reason: .unsupportedFileType
            )
            Logger.info("Ignored unsupported file: \(standardisedFileURL.path)")
            return
        }

        // If this exact file is already open, bring that window to front
        // instead of creating a duplicate document window.
        if focusExistingDocumentWindowIfOpen(for: standardisedFileURL) {
            return
        }

        if reuseInitialEmptyWindowIfPossible(for: standardisedFileURL) {
            return
        }

        // Dismiss any visible empty launch windows before opening a real
        // document so the app behaves like Preview (document-first) rather
        // than leaving an empty placeholder window behind.
        let emptyWindowCloseStart = DispatchTime.now()
        let closedEmptyWindowCount = closeInitialEmptyWindowsIfPresent()
        let emptyWindowCloseMilliseconds = elapsedMilliseconds(since: emptyWindowCloseStart)
        Logger.info(
            "[PERF] empty-window-close file=\(standardisedFileURL.lastPathComponent) closed=\(closedEmptyWindowCount) ms=\(formatMilliseconds(emptyWindowCloseMilliseconds))"
        )

        showDocumentWindow(for: standardisedFileURL)
    }

    /// Reuses an existing empty launch window as the first document window.
    ///
    /// This avoids close-and-create transition work that can cause visible
    /// flashing and extra latency on first document open after app launch.
    private func reuseInitialEmptyWindowIfPossible(for fileURL: URL) -> Bool {
        guard let emptyController = reusableInitialEmptyWindowController() else {
            return false
        }

        if let reusedWindow = emptyController.window {
            let closeOthersStart = DispatchTime.now()
            let closedOtherEmptyWindows = closeInitialEmptyWindowsIfPresent(excluding: reusedWindow)
            let closeOthersMilliseconds = elapsedMilliseconds(since: closeOthersStart)
            Logger.info(
                "[PERF] empty-window-close file=\(fileURL.lastPathComponent) closed=\(closedOtherEmptyWindows) ms=\(formatMilliseconds(closeOthersMilliseconds))"
            )
        }

        let reuseStart = DispatchTime.now()
        let didLoadDocument = emptyController.openDocumentInCurrentWindow(fileURL: fileURL)
        let reuseMilliseconds = elapsedMilliseconds(since: reuseStart)
        Logger.info(
            "[PERF] empty-window-reuse file=\(fileURL.lastPathComponent) success=\(didLoadDocument) ms=\(formatMilliseconds(reuseMilliseconds))"
        )

        if didLoadDocument {
            recentDocumentService.note(fileURL)
            notifyRecentDocumentsChanged()
        }

        if let reusedWindow = emptyController.window {
            if reusedWindow.isMiniaturized {
                reusedWindow.deminiaturize(nil)
            }
            reusedWindow.makeKeyAndOrderFront(nil)
        }

        return true
    }

    /// Returns a visible empty launch-window controller that can be repurposed.
    private func reusableInitialEmptyWindowController() -> DocumentWindowController? {
        let candidates = windowControllers.values.filter { controller in
            guard let window = controller.window else {
                return false
            }

            return window.isVisible &&
                window.styleMask.contains(.titled) &&
                window.representedURL == nil &&
                window.title == "Quick Markdown Viewer"
        }

        guard !candidates.isEmpty else {
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let keyCandidate = candidates.first(where: { $0.window === keyWindow }) {
            return keyCandidate
        }

        return candidates.first
    }

    /// Brings an already-open document window to the front when file matches.
    ///
    /// Returns `true` when a matching window is found and focused, otherwise
    /// `false` so the normal new-window open path can continue.
    private func focusExistingDocumentWindowIfOpen(for fileURL: URL) -> Bool {
        let matchingController = windowControllers.values
            .first(where: { controller in
                guard let representedURL = controller.window?.representedURL else { return false }
                return urlsReferenceSameFile(representedURL, fileURL)
            })

        guard let matchingController, let matchingWindow = matchingController.window else {
            return false
        }

        // Re-opening an already open file should not duplicate the window, but
        // it should refresh the rendered content from disk so external edits
        // become visible immediately.
        matchingController.reloadDocument(
            from: fileURL
        )
        recentDocumentService.note(fileURL)
        notifyRecentDocumentsChanged()

        if matchingWindow.isMiniaturized {
            matchingWindow.deminiaturize(nil)
        }

        matchingWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Returns `true` when two URLs point at the same on-disk file.
    ///
    /// Why this is needed:
    /// - Markdown link clicks can produce URLs that differ textually from the
    ///   original open URL (for example percent-encoding, symlink path style,
    ///   or equivalent standardisation differences).
    /// - Plain string/path equality can miss those equivalents and open a
    ///   duplicate window for the same logical document.
    ///
    /// Matching strategy:
    /// 1. Compare canonicalised paths (standardised + symlink-resolved).
    /// 2. If still different, compare file resource identifiers from metadata.
    /// 3. Fall back to `false` when metadata is unavailable.
    private func urlsReferenceSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsCanonical = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let rhsCanonical = rhs.standardizedFileURL.resolvingSymlinksInPath()

        if lhsCanonical.path == rhsCanonical.path {
            return true
        }

        let keys: Set<URLResourceKey> = [
            .fileResourceIdentifierKey,
            .volumeIdentifierKey
        ]

        guard
            let lhsValues = try? lhsCanonical.resourceValues(forKeys: keys),
            let rhsValues = try? rhsCanonical.resourceValues(forKeys: keys),
            let lhsFileID = lhsValues.fileResourceIdentifier as? NSObject,
            let rhsFileID = rhsValues.fileResourceIdentifier as? NSObject
        else {
            return false
        }

        // File IDs are only safely comparable on the same volume.
        if let lhsVolumeID = lhsValues.volumeIdentifier as? NSObject,
           let rhsVolumeID = rhsValues.volumeIdentifier as? NSObject,
           !lhsVolumeID.isEqual(rhsVolumeID) {
            return false
        }

        return lhsFileID.isEqual(rhsFileID)
    }

    /// Builds and displays a document window, then loads and renders content.
    private func showDocumentWindow(for fileURL: URL) {
        let windowCreateStart = DispatchTime.now()

        // Each window owns its own document state object.
        let documentState = DocumentState(fileURL: fileURL)

        let rootView = DocumentWindowView(
            documentState: documentState,
            onOpenFile: { [weak self] url in
                self?.openFile(url)
            },
            onOpenAnotherFile: { [weak self] in
                self?.openDocumentPanel()
            },
            onSetLightAppearance: { [weak self] in
                self?.setLightAppearanceMode()
            },
            onSetDarkAppearance: { [weak self] in
                self?.setDarkAppearanceMode()
            }
        )

        let hostingController = NSHostingController(rootView: rootView)

        // Keep window chrome minimal while preserving native controls.
        let initialFrame = NSRect(x: 0, y: 0, width: 940, height: 760)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = fileURL.lastPathComponent
        window.titleVisibility = .visible
        window.representedURL = fileURL
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false

        // Apply deterministic sizing plus cascade positioning so new windows
        // open with a small offset from the current document window.
        positionNewDocumentWindow(window, size: initialFrame.size)

        // Track controller lifetime so windows are not deallocated unexpectedly.
        let windowID = UUID()
        let controller = DocumentWindowController(
            window: window,
            id: windowID,
            documentState: documentState,
            fileOpenService: fileOpenService,
            renderService: renderService
        ) { [weak self] closedID in
            self?.windowControllers.removeValue(forKey: closedID)
        }
        window.delegate = controller
        windowControllers[windowID] = controller

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let windowCreateMilliseconds = elapsedMilliseconds(since: windowCreateStart)
        Logger.info(
            "[PERF] document-window-create file=\(fileURL.lastPathComponent) ms=\(formatMilliseconds(windowCreateMilliseconds))"
        )

        // Keep launch behaviour aligned with Preview-style utilities:
        // no control (including the top search field) should be focused by
        // default when a new QuickMarkdownViewer window appears.
        DispatchQueue.main.async { [weak window] in
            guard let window else {
                return
            }

            // Avoid stealing focus from explicit user actions (for example Cmd+F
            // immediately after opening a document).
            if window.firstResponder is NSSearchField {
                return
            }

            _ = window.makeFirstResponder(nil)
        }

        // Perform immediate load + render for fast perceived open time.
        let documentLoadStart = DispatchTime.now()
        documentState.load(
            fileURL: fileURL,
            fileOpenService: fileOpenService,
            renderService: renderService
        )
        let documentLoadMilliseconds = elapsedMilliseconds(since: documentLoadStart)
        Logger.info(
            "[PERF] document-state-load-call file=\(fileURL.lastPathComponent) ms=\(formatMilliseconds(documentLoadMilliseconds))"
        )

        if let loadedDocument = documentState.document {
            recentDocumentService.note(loadedDocument.fileURL)
            notifyRecentDocumentsChanged()
            window.title = loadedDocument.filename
        }
    }

    /// Presents a user-facing warning for unsupported file-open attempts.
    ///
    /// The message explicitly lists accepted Markdown extensions so users have
    /// immediate guidance on what QuickMarkdownViewer can open.
    private func presentUnsupportedFileWarning(for fileURL: URL, reason: UnsupportedOpenReason) {
        let ext = fileURL.pathExtension.lowercased()
        let acceptedList = FileOpenService.acceptedExtensionsSummary

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        switch reason {
        case .unsupportedMarkdownVariant:
            switch ext {
            case "rmd":
                alert.messageText = "Quick Markdown Viewer does not support .rmd files."
                alert.informativeText =
                    "Quick Markdown Viewer is a plain Markdown viewer. R Markdown files usually require knitr/pandoc rendering, which Quick Markdown Viewer does not run in v1."

            case "qmd":
                alert.messageText = "Quick Markdown Viewer does not support .qmd files."
                alert.informativeText =
                    "Quick Markdown Viewer is a plain Markdown viewer. Quarto files usually require Quarto rendering features that are outside Quick Markdown Viewer v1."

            default:
                alert.messageText = "Quick Markdown Viewer cannot open .\(ext) files."
                alert.informativeText =
                    "Quick Markdown Viewer only accepts Markdown documents with these extensions: \(acceptedList)."
            }

        case .unsupportedFileType:
            if ext.isEmpty {
                alert.messageText = "Quick Markdown Viewer cannot open this file type."
                alert.informativeText =
                    "Quick Markdown Viewer only accepts Markdown documents with these extensions: \(acceptedList)."
            } else {
                alert.messageText = "Quick Markdown Viewer cannot open .\(ext) files."
                alert.informativeText =
                    "Quick Markdown Viewer only accepts Markdown documents with these extensions: \(acceptedList)."
            }
        }

        alert.runModal()
    }

    /// Presents a compact warning when bundled Help content is unavailable.
    private func presentMissingHelpWarning() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Help content is unavailable."
        alert.informativeText =
            "Quick Markdown Viewer could not find a registered Apple Help Book."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Opens bundled README help when Apple Help Book launch fails.
    ///
    /// This keeps Help usable in edge cases (for example, local dev
    /// registration/index mismatches) while still prioritising native Help.
    private func openBundledHelpFallbackWithWarning() {
        openBundledHelpFallback(showWarning: true)
    }

    /// Opens bundled README help without showing a warning first.
    ///
    /// This is used when Help is intentionally opened in-app as the primary
    /// path rather than a degraded fallback.
    private func openBundledHelpFallbackSilently() {
        openBundledHelpFallback(showWarning: false)
    }

    /// Shared bundled-help opener used by warning and non-warning paths.
    ///
    /// Parameter showWarning: True to show the "Help content is unavailable"
    /// alert before opening the in-app help document.
    private func openBundledHelpFallback(showWarning: Bool) {
        if showWarning {
            presentMissingHelpWarning()
        }

        guard let helpREADMEURL = Bundle.main.url(forResource: "README", withExtension: "md")?
            .standardizedFileURL else {
            Logger.error("Fallback help README.md was not found in app bundle resources.")
            return
        }

        // Keep fallback behaviour tidy by focusing an existing help window.
        if focusExistingDocumentWindowIfOpen(for: helpREADMEURL) {
            return
        }

        closeInitialEmptyWindowsIfPresent()
        showDocumentWindow(for: helpREADMEURL)
    }

    /// Positions a newly created document window with gentle cascade behaviour.
    ///
    /// Placement rules:
    /// - Prefer offsetting from the currently key document-style window.
    /// - Otherwise offset from the previous document frame we opened.
    /// - Otherwise centre the first document window.
    /// - Always clamp into the visible screen frame to avoid off-screen windows.
    private func positionNewDocumentWindow(_ window: NSWindow, size: NSSize) {
        let cascadeOffset = NSSize(width: 28, height: 28)

        if let anchorWindow = keyDocumentLikeWindow() {
            var frame = NSRect(
                x: anchorWindow.frame.origin.x + cascadeOffset.width,
                y: anchorWindow.frame.origin.y - cascadeOffset.height,
                width: size.width,
                height: size.height
            )
            frame = clampedToVisibleScreen(frame, preferredScreen: anchorWindow.screen)
            window.setFrame(frame, display: false)
            lastDocumentWindowFrame = frame
            return
        }

        if let priorFrame = lastDocumentWindowFrame {
            var frame = NSRect(
                x: priorFrame.origin.x + cascadeOffset.width,
                y: priorFrame.origin.y - cascadeOffset.height,
                width: size.width,
                height: size.height
            )
            frame = clampedToVisibleScreen(frame, preferredScreen: NSScreen.main)
            window.setFrame(frame, display: false)
            lastDocumentWindowFrame = frame
            return
        }

        // First document window uses centred placement for a tidy initial feel.
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        window.center()
        lastDocumentWindowFrame = window.frame
    }

    /// Returns the current key window if it looks like a normal document window.
    ///
    /// We intentionally filter to titled, visible windows to avoid using
    /// transient panels or utility windows as a cascade anchor.
    private func keyDocumentLikeWindow() -> NSWindow? {
        guard let keyWindow = NSApp.keyWindow else {
            return nil
        }

        guard keyWindow.isVisible, keyWindow.styleMask.contains(.titled) else {
            return nil
        }

        return keyWindow
    }

    /// Clamps a frame into the visible area of the provided screen (or main).
    ///
    /// This prevents cascaded windows from drifting out of bounds when many
    /// local links are opened in sequence.
    private func clampedToVisibleScreen(_ frame: NSRect, preferredScreen: NSScreen?) -> NSRect {
        guard let visibleFrame = preferredScreen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return frame
        }

        var clamped = frame
        clamped.origin.x = min(max(clamped.origin.x, visibleFrame.minX), visibleFrame.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, visibleFrame.minY), visibleFrame.maxY - clamped.height)
        return clamped
    }

    /// Closes all plain untitled launch windows that are still visible.
    ///
    /// The SwiftUI `WindowGroup` empty-state window is useful on normal launch
    /// with no files, but when a file-open event arrives we prefer a single
    /// document window experience with no empty placeholder left behind.
    @discardableResult
    private func closeInitialEmptyWindowsIfPresent(excluding excludedWindow: NSWindow? = nil) -> Int {
        let emptyWindows = NSApp.windows.filter {
            $0.isVisible &&
            $0.styleMask.contains(.titled) &&
            $0.representedURL == nil &&
            $0.title == "Quick Markdown Viewer" &&
            $0 !== excludedWindow
        }

        guard !emptyWindows.isEmpty else {
            return 0
        }

        // Close all matching placeholders in case launch timing ever produced
        // more than one empty window. This keeps resulting behaviour tidy.
        emptyWindows.forEach { $0.close() }
        return emptyWindows.count
    }

    /// Returns elapsed wall-clock time in milliseconds for lightweight profiling.
    private func elapsedMilliseconds(since start: DispatchTime) -> Double {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsedNanoseconds) / 1_000_000
    }

    /// Formats elapsed millisecond values for compact console logs.
    private func formatMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    /// Returns the retained controller that owns a given window instance.
    private func controller(for window: NSWindow) -> DocumentWindowController? {
        windowControllers.values.first(where: { $0.window === window })
    }

    /// Resolves the active document window used for routed commands.
    ///
    /// If a child utility panel (for example, floating Find) is key, we route
    /// to its parent document window.
    private func activeDocumentWindow() -> NSWindow? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if controller(for: candidate) != nil {
                lastRoutedDocumentWindow = candidate
                return candidate
            }

            if let parentWindow = candidate.parent,
               controller(for: parentWindow) != nil {
                lastRoutedDocumentWindow = parentWindow
                return parentWindow
            }
        }

        if let fallbackWindow = lastRoutedDocumentWindow,
           controller(for: fallbackWindow) != nil {
            return fallbackWindow
        }

        return nil
    }

    /// Returns the controller for the active routed document window.
    private func activeDocumentWindowController() -> DocumentWindowController? {
        guard let targetWindow = activeDocumentWindow() else {
            return nil
        }

        return controller(for: targetWindow)
    }

    /// Routes a Find command to the currently active titled window.
    ///
    /// Using notifications keeps command handling decoupled from view-tree
    /// ownership while still targeting exactly one window.
    private func dispatchFindCommandToActiveWindow(_ command: QuickMarkdownViewerFindCommand) {
        guard let targetWindow = activeDocumentWindow() else {
            NSSound.beep()
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerFindCommand,
            object: targetWindow,
            userInfo: [
                QuickMarkdownViewerFindCommandUserInfoKey.command.rawValue: command.rawValue
            ]
        )
    }

    /// Routes a Zoom command to the currently active titled window.
    ///
    /// Targeting by concrete window object ensures only one document window
    /// responds, even when multiple Markdown documents are open at the same
    /// time.
    private func dispatchZoomCommandToActiveWindow(_ command: QuickMarkdownViewerZoomCommand) {
        guard let targetWindow = activeDocumentWindow() else {
            NSSound.beep()
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerZoomCommand,
            object: targetWindow,
            userInfo: [
                QuickMarkdownViewerZoomCommandUserInfoKey.command.rawValue: command.rawValue
            ]
        )
    }

    /// Routes a document command to the currently active titled window.
    ///
    /// Targeting by concrete window object keeps behaviour deterministic when
    /// multiple Markdown windows are open at the same time.
    private func dispatchDocumentCommandToActiveWindow(_ command: QuickMarkdownViewerDocumentCommand) {
        guard let targetWindow = activeDocumentWindow() else {
            NSSound.beep()
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerDocumentCommand,
            object: targetWindow,
            userInfo: [
                QuickMarkdownViewerDocumentCommandUserInfoKey.command.rawValue: command.rawValue
            ]
        )
    }

    /// Returns the active document URL suitable for command-driven actions.
    ///
    /// We intentionally use window `representedURL` here because it tracks the
    /// currently open source file for each QuickMarkdownViewer document window.
    private func activeDocumentFileURLForCommands() -> URL? {
        guard let targetWindow = activeDocumentWindow(),
              let representedURL = targetWindow.representedURL else {
            return nil
        }

        return representedURL.standardizedFileURL
    }

    /// Returns whether the active titled window currently hosts a document URL.
    private var hasActiveDocumentWindowForCommands: Bool {
        guard let targetWindow = activeDocumentWindow() else {
            return false
        }

        return targetWindow.representedURL != nil
    }

    /// Records the active document window when key focus changes.
    func noteDocumentWindowBecameKey(_ window: NSWindow) {
        guard controller(for: window) != nil else {
            return
        }

        lastRoutedDocumentWindow = window
        notifyToolbarVisibilityChanged()
    }

    /// Triggers command menu refresh after toolbar visibility changes.
    func notifyToolbarVisibilityDidChange() {
        notifyToolbarVisibilityChanged()
    }

    /// Returns the persisted explicit appearance mode, if any.
    private func persistedAppearanceMode() -> AppearanceMode? {
        guard let rawValue = defaults.string(forKey: appearanceModeDefaultsKey) else {
            return nil
        }

        return AppearanceMode(rawValue: rawValue)
    }

    /// Stores the user-selected appearance mode.
    private func setPersistedAppearanceMode(_ mode: AppearanceMode) {
        defaults.set(mode.rawValue, forKey: appearanceModeDefaultsKey)
    }

    /// Applies a specific appearance mode to the running app.
    ///
    /// Setting `NSApp.appearance` updates both SwiftUI chrome and the embedded
    /// web content environment, including `prefers-color-scheme` CSS queries.
    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)

        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Detects current effective app appearance as a light/dark enum.
    ///
    /// We use this when no persisted preference exists yet.
    private func effectiveAppearanceMode() -> AppearanceMode {
        let bestMatch = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return bestMatch == .darkAqua ? .dark : .light
    }

    /// Bumps an observed token so command menus refresh their dynamic content.
    private func notifyRecentDocumentsChanged() {
        recentDocumentsRevision &+= 1
    }

    /// Bumps toolbar command refresh token.
    private func notifyToolbarVisibilityChanged() {
        toolbarVisibilityRevision &+= 1
    }
}

/// Small controller used to cleanly drop retained window references on close.
@MainActor
private final class DocumentWindowToolbar: NSToolbar {
    /// Callback fired whenever display mode changes.
    var onDisplayModeChanged: ((NSToolbar) -> Void)?

    override var displayMode: NSToolbar.DisplayMode {
        didSet {
            guard oldValue != displayMode else {
                return
            }
            onDisplayModeChanged?(self)
        }
    }
}

/// Small controller used to cleanly drop retained window references on close.
@MainActor
private final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    /// Stable identifier used by `AppRouting.windowControllers`.
    private let id: UUID

    /// State object backing the window's current document view.
    ///
    /// Keeping a reference here lets `AppRouting` refresh an already open file
    /// instead of opening a duplicate window when users choose the same file
    /// again after editing it elsewhere.
    private let documentState: DocumentState

    /// Callback invoked when the window closes.
    private let onClose: (UUID) -> Void

    /// Services used for document refresh/reload actions.
    private let fileOpenService: FileOpenService
    private let renderService: MarkdownRenderService

    /// Combine cancellables for document-state observation.
    private var cancellables: Set<AnyCancellable> = []

    /// Observation token for document-window Find state updates.
    private var findStateObserver: NSObjectProtocol?

    /// Current query mirrored between toolbar and optional Find panel.
    private var currentFindQuery = ""

    /// Current case-sensitive mode mirrored between toolbar and Find panel.
    private var isFindCaseSensitive = false

    /// True while syncing AppKit search controls programmatically.
    private var isSyncingFindControls = false

    /// True while this window is actively toggling toolbar visibility.
    private var isTogglingToolbarVisibility = false

    /// True when the next toolbar display-mode callback should be ignored.
    private var ignoreNextDisplayModeChange = false

    /// Deadline used to suppress search-item rebuilds around toolbar toggles.
    private var suppressSearchItemRebuildUntil = Date.distantPast

    /// Managed native toolbar for this window.
    private weak var managedToolbar: NSToolbar?

    /// Search field hosted in the currently inserted toolbar search item.
    ///
    /// This intentionally excludes non-inserted palette preview instances.
    private weak var toolbarSearchField: NSSearchField?

    /// Floating Find panel shown when toolbar is hidden.
    private var floatingFindPanel: NSPanel?

    /// Search field hosted in the floating Find panel.
    private weak var floatingFindSearchField: NSSearchField?

    /// Toolbar items requiring enabled-state refreshes.
    private weak var shareToolbarItem: NSToolbarItem?
    private weak var viewSourceToolbarItem: NSToolbarItem?
    private weak var zoomToFitToolbarItem: NSToolbarItem?
    private weak var actualSizeToolbarItem: NSToolbarItem?
    private weak var printToolbarItem: NSToolbarItem?
    private weak var exportPDFToolbarItem: NSToolbarItem?
    private weak var searchToolbarGenericItem: NSToolbarItem?
    private weak var zoomLegacyGroupItem: NSToolbarItemGroup?
    private weak var zoomOutInGroupItem: NSToolbarItemGroup?
    private weak var printExportGroupItem: NSToolbarItemGroup?
    private weak var appearanceGroupItem: NSToolbarItemGroup?

    /// Stable toolbar identifiers for customisation/default layouts.
    private enum ToolbarItemIdentifier {
        static let toolbar = NSToolbar.Identifier("QuickMarkdownViewer.MainToolbar")

        static let open = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.Open")
        static let zoomLegacy = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.ZoomLegacy")
        static let appearance = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.Appearance")
        static let printExportGroup = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.PrintExportGroup")
        static let search = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.Search")

        static let share = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.Share")
        static let viewSource = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.ViewSource")
        static let zoomToFit = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.ZoomToFit")
        static let actualSize = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.ActualSize")
        static let zoomOutIn = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.ZoomOutIn")
        static let print = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.Print")
        static let exportPDF = NSToolbarItem.Identifier("QuickMarkdownViewer.Toolbar.ExportPDF")
    }

    /// Tags used by case-mode menu items.
    private enum FindMenuTag {
        static let caseInsensitive = 9101
        static let caseSensitive = 9102
    }

    init(
        window: NSWindow,
        id: UUID,
        documentState: DocumentState,
        fileOpenService: FileOpenService,
        renderService: MarkdownRenderService,
        onClose: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.documentState = documentState
        self.fileOpenService = fileOpenService
        self.renderService = renderService
        self.onClose = onClose
        super.init(window: window)
        configureToolbar(on: window)
        installDocumentStateObservers()
        installFindStateObserver(for: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Notify router so it can release the closed window controller.
    func windowWillClose(_ notification: Notification) {
        closeFloatingFindPanel()
        onClose(id)
    }

    /// Refreshes content when the user re-activates a document window.
    ///
    /// This keeps QuickMarkdownViewer in sync with external edits while staying
    /// low risk: reload occurs only when on-disk file fingerprint changed.
    func windowDidBecomeKey(_ notification: Notification) {
        if let window {
            AppRouting.shared.noteDocumentWindowBecameKey(window)
        }

        guard let fileURL = window?.representedURL else {
            refreshToolbarItemState()
            refreshAppearanceSelection()
            return
        }

        documentState.reloadIfFileChanged(
            fileURL: fileURL,
            fileOpenService: fileOpenService,
            renderService: renderService
        )

        refreshToolbarItemState()
        refreshAppearanceSelection()
        DispatchQueue.main.async { [weak self] in
            self?.refreshToolbarItemState()
        }
    }

    /// Reloads the document displayed in this window from disk.
    ///
    /// This is used when users open a file that is already open in
    /// QuickMarkdownViewer. We reuse the same window, but refresh content so
    /// externally saved edits are reflected immediately.
    func reloadDocument(
        from fileURL: URL
    ) {
        documentState.load(
            fileURL: fileURL,
            fileOpenService: fileOpenService,
            renderService: renderService
        )
    }

    /// Reuses this existing window to open a document in-place.
    ///
    /// This is used to retarget the initial empty launch window into the first
    /// real document window, avoiding a close/create transition flash.
    @discardableResult
    func openDocumentInCurrentWindow(fileURL: URL) -> Bool {
        guard let window else {
            return false
        }

        window.representedURL = fileURL
        window.title = fileURL.lastPathComponent

        let loadStart = DispatchTime.now()
        documentState.load(
            fileURL: fileURL,
            fileOpenService: fileOpenService,
            renderService: renderService
        )
        let loadMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1_000_000
        Logger.info(
            "[PERF] document-state-load-call file=\(fileURL.lastPathComponent) ms=\(String(format: "%.1f", loadMilliseconds))"
        )

        if let loadedDocument = documentState.document {
            window.title = loadedDocument.filename
        }

        refreshToolbarItemState()
        DispatchQueue.main.async { [weak self] in
            self?.refreshToolbarItemState()
        }

        return documentState.document != nil
    }

    /// Handles Cmd+F behaviour for this window.
    ///
    /// Toolbar visible: focus toolbar search field.
    /// Toolbar hidden: show/focus floating Find panel.
    func toggleFindUI() {
        guard canUseDocumentControls else {
            NSSound.beep()
            return
        }

        if shouldPresentFloatingFindPanelForCurrentToolbarMode() {
            showFloatingFindPanel()
            return
        }

        focusToolbarSearchField()
    }

    /// Hides any active Find UI owned by this controller.
    func hideFindUI() {
        closeFloatingFindPanel()
        if let searchField = toolbarSearchField,
           searchField.window?.firstResponder === searchField {
            window?.makeFirstResponder(nil)
        }
    }

    /// Toggles window toolbar visibility.
    func toggleToolbarVisibility() {
        guard let window else {
            return
        }

        guard let toolbar = window.toolbar else {
            return
        }

        isTogglingToolbarVisibility = true
        ignoreNextDisplayModeChange = true
        suppressSearchItemRebuildUntil = Date().addingTimeInterval(1.0)

        if toolbar.isVisible {
            closeFloatingFindPanel()
        }
        window.toggleToolbarShown(nil)

        DispatchQueue.main.async {
            AppRouting.shared.notifyToolbarVisibilityDidChange()
        }

        // Keep mode-change rebuilds paused until AppKit finishes this toggle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isTogglingToolbarVisibility = false
            self?.ignoreNextDisplayModeChange = false
        }
    }

    /// Opens native toolbar customisation palette.
    func openToolbarCustomisation() {
        if let toolbar = window?.toolbar {
            toolbar.runCustomizationPalette(nil)
            return
        }

        NSSound.beep()
    }

    /// True when document-driven controls should be enabled.
    private var canUseDocumentControls: Bool {
        if case .loaded = documentState.phase, documentState.document != nil {
            return true
        }

        return false
    }

    /// True when this window's toolbar is currently visible.
    private var isToolbarVisible: Bool {
        window?.toolbar?.isVisible ?? false
    }

    /// Configures one native, customisable toolbar for this document window.
    private func configureToolbar(on window: NSWindow) {
        let toolbar = DocumentWindowToolbar(identifier: ToolbarItemIdentifier.toolbar)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = true
        }
        toolbar.autosavesConfiguration = true
        toolbar.sizeMode = .small
        toolbar.showsBaselineSeparator = true

        if !hasSavedToolbarConfiguration() {
            toolbar.displayMode = .iconOnly
        }

        window.toolbar = toolbar
        window.toolbarStyle = .automatic
        managedToolbar = toolbar

        toolbar.onDisplayModeChanged = { [weak self] toolbar in
            guard let self else {
                return
            }

            guard Date() >= self.suppressSearchItemRebuildUntil else {
                return
            }

            if self.ignoreNextDisplayModeChange {
                self.ignoreNextDisplayModeChange = false
                return
            }

            guard !self.isTogglingToolbarVisibility else {
                return
            }

            guard toolbar.isVisible else {
                return
            }

            self.rebuildSearchToolbarItemIfNeeded(in: toolbar)
        }
    }

    /// Returns true when AppKit already persisted user toolbar customisation.
    private func hasSavedToolbarConfiguration() -> Bool {
        let defaultsKey = "NSToolbar Configuration \(ToolbarItemIdentifier.toolbar)"
        return UserDefaults.standard.object(forKey: defaultsKey) != nil
    }

    /// Installs observation hooks used for toolbar enabled-state refreshes.
    private func installDocumentStateObservers() {
        documentState.$phase
            .sink { [weak self] _ in
                self?.refreshToolbarItemState()
            }
            .store(in: &cancellables)

        documentState.$document
            .sink { [weak self] _ in
                self?.refreshToolbarItemState()
            }
            .store(in: &cancellables)
    }

    /// Installs observer for Find state updates published by DocumentWindowView.
    private func installFindStateObserver(for window: NSWindow) {
        findStateObserver = NotificationCenter.default.addObserver(
            forName: .quickMarkdownViewerFindStateDidChange,
            object: window,
            queue: .main
        ) { [weak self] notification in
            let query =
                notification.userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.query.rawValue] as? String ?? ""
            let caseSensitive =
                notification.userInfo?[QuickMarkdownViewerFindCommandUserInfoKey.isCaseSensitive.rawValue] as? Bool ?? false

            Task { @MainActor in
                guard let self else {
                    return
                }

                self.currentFindQuery = query
                self.isFindCaseSensitive = caseSensitive
                self.syncFindControlsFromState()
            }
        }
    }

    /// Applies current query/case state to toolbar and floating panel fields.
    private func syncFindControlsFromState() {
        resolveToolbarSearchReferences()
        isSyncingFindControls = true
        defer { isSyncingFindControls = false }

        if let toolbarField = toolbarSearchField {
            let isEditingToolbarField = toolbarField.currentEditor() != nil
            if !isEditingToolbarField, toolbarField.stringValue != currentFindQuery {
                toolbarField.stringValue = currentFindQuery
            }
        }

        if let panelField = floatingFindSearchField,
           panelField.stringValue != currentFindQuery {
            panelField.stringValue = currentFindQuery
        }

        syncFindMenuCheckmarks(for: toolbarSearchField?.searchMenuTemplate)
        syncFindMenuCheckmarks(for: floatingFindSearchField?.searchMenuTemplate)
    }

    /// Refreshes enabled/disabled state for document-bound toolbar items.
    private func refreshToolbarItemState() {
        resolveToolbarSearchReferences()
        let isEnabled = canUseDocumentControls

        shareToolbarItem?.isEnabled = isEnabled
        viewSourceToolbarItem?.isEnabled = isEnabled
        zoomToFitToolbarItem?.isEnabled = isEnabled
        actualSizeToolbarItem?.isEnabled = isEnabled
        printToolbarItem?.isEnabled = isEnabled
        exportPDFToolbarItem?.isEnabled = isEnabled
        searchToolbarGenericItem?.isEnabled = isEnabled
        toolbarSearchField?.isEnabled = isEnabled

        zoomLegacyGroupItem?.isEnabled = isEnabled
        zoomLegacyGroupItem?.subitems.forEach { $0.isEnabled = isEnabled }

        zoomOutInGroupItem?.isEnabled = isEnabled
        zoomOutInGroupItem?.subitems.forEach { $0.isEnabled = isEnabled }

        printExportGroupItem?.isEnabled = isEnabled
        printExportGroupItem?.subitems.forEach { $0.isEnabled = isEnabled }

        if !isEnabled {
            closeFloatingFindPanel()
        }
    }

    /// Resolves the currently inserted toolbar search field, if available.
    ///
    /// AppKit may build preview toolbar items for customisation contexts. We
    /// only keep references to fields actually inserted in this window toolbar.
    private func resolveToolbarSearchReferences() {
        guard let toolbar = managedToolbar,
              let searchItem = toolbar.items.first(where: { $0.itemIdentifier == ToolbarItemIdentifier.search }) else {
            toolbarSearchField = nil
            return
        }

        toolbarSearchField = searchItem.view as? NSSearchField
        searchToolbarGenericItem = searchItem
    }

    /// Rebuilds Search toolbar item when display mode changes.
    ///
    /// This lets label-only mode use a plain action item (Preview-like) while
    /// icon-containing modes use a toolbar-hosted native `NSSearchField`.
    private func rebuildSearchToolbarItemIfNeeded(in toolbar: NSToolbar) {
        guard toolbar.isVisible else {
            return
        }

        guard let searchIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == ToolbarItemIdentifier.search }) else {
            return
        }

        let isTextOnlyMode = toolbar.displayMode == .labelOnly
        let hasSearchFieldView = toolbar.items[searchIndex].view is NSSearchField
        if (isTextOnlyMode && !hasSearchFieldView) || (!isTextOnlyMode && hasSearchFieldView) {
            return
        }

        toolbar.removeItem(at: searchIndex)
        toolbar.insertItem(withItemIdentifier: ToolbarItemIdentifier.search, at: searchIndex)
        refreshToolbarItemState()
        syncFindControlsFromState()
    }

    /// Returns true when Search is currently represented as a text-only action.
    private func isSearchPresentedAsActionItem() -> Bool {
        guard let toolbar = managedToolbar,
              let searchItem = toolbar.items.first(where: { $0.itemIdentifier == ToolbarItemIdentifier.search }) else {
            return false
        }

        return searchItem.view == nil
    }

    /// Returns true when the floating Find panel should be used.
    ///
    /// This guards text-only toolbar mode and edge-cases where AppKit keeps the
    /// search field item cached but detaches its view hierarchy.
    private func shouldPresentFloatingFindPanelForCurrentToolbarMode() -> Bool {
        guard isToolbarVisible else {
            return true
        }

        if isSearchPresentedAsActionItem() {
            return true
        }

        if managedToolbar?.displayMode == .labelOnly {
            return true
        }

        resolveToolbarSearchReferences()
        guard let toolbarSearchField else {
            return true
        }

        if toolbarSearchField.window == nil || toolbarSearchField.superview == nil {
            return true
        }

        return false
    }

    /// Keeps appearance controls visually stable across mode switches.
    private func refreshAppearanceSelection() {
        // No-op by design: the appearance toolbar group is momentary so it
        // keeps capsule styling instead of latching selected segments.
    }

    /// Creates one SF Symbol image or a plain placeholder fallback.
    private func toolbarSymbolImage(_ symbolName: String, fallbackAccessibilityLabel: String) -> NSImage {
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: fallbackAccessibilityLabel) {
            return image
        }

        return NSImage(size: NSSize(width: 16, height: 16))
    }

    /// Creates one native Find menu template used by search fields.
    private func makeFindModeMenu() -> NSMenu {
        let menu = NSMenu(title: "Search Mode")
        menu.autoenablesItems = true
        menu.delegate = self

        let caseInsensitiveItem = NSMenuItem(
            title: "Case Insensitive",
            action: #selector(selectCaseInsensitiveFindMode(_:)),
            keyEquivalent: ""
        )
        caseInsensitiveItem.tag = FindMenuTag.caseInsensitive
        caseInsensitiveItem.target = self
        menu.addItem(caseInsensitiveItem)

        let caseSensitiveItem = NSMenuItem(
            title: "Case Sensitive",
            action: #selector(selectCaseSensitiveFindMode(_:)),
            keyEquivalent: ""
        )
        caseSensitiveItem.tag = FindMenuTag.caseSensitive
        caseSensitiveItem.target = self
        menu.addItem(caseSensitiveItem)

        syncFindMenuCheckmarks(for: menu)
        return menu
    }

    /// Applies Find mode checkmarks to a menu.
    private func syncFindMenuCheckmarks(for menu: NSMenu?) {
        guard let menu else {
            return
        }

        menu.item(withTag: FindMenuTag.caseInsensitive)?.state = isFindCaseSensitive ? .off : .on
        menu.item(withTag: FindMenuTag.caseSensitive)?.state = isFindCaseSensitive ? .on : .off
    }

    /// Focuses and selects the toolbar search field.
    private func focusToolbarSearchField(allowRetry: Bool = true) {
        refreshToolbarItemState()
        resolveToolbarSearchReferences()

        guard let toolbarSearchField, toolbarSearchField.isEnabled else {
            if allowRetry {
                DispatchQueue.main.async { [weak self] in
                    self?.focusToolbarSearchField(allowRetry: false)
                }
                return
            }
            NSSound.beep()
            return
        }

        closeFloatingFindPanel()
        syncFindControlsFromState()
        window?.makeFirstResponder(toolbarSearchField)
        toolbarSearchField.selectText(nil)
    }

    /// Shows the floating Find panel near the owning document window.
    private func showFloatingFindPanel() {
        guard let hostWindow = window else {
            return
        }

        let panel = ensureFloatingFindPanel()
        let wasVisible = panel.isVisible
        syncFindControlsFromState()

        if !wasVisible {
            let panelSize = panel.frame.size
            let origin = NSPoint(
                x: hostWindow.frame.midX - (panelSize.width / 2),
                y: hostWindow.frame.midY - (panelSize.height / 2)
            )
            panel.setFrameOrigin(origin)
        }

        if panel.parent !== hostWindow {
            hostWindow.addChildWindow(panel, ordered: NSWindow.OrderingMode.above)
        }

        panel.makeKeyAndOrderFront(nil)
        if let searchField = floatingFindSearchField {
            panel.makeFirstResponder(searchField)
            searchField.selectText(nil)
        }
    }

    /// Closes the floating Find panel if currently visible.
    private func closeFloatingFindPanel() {
        guard let panel = floatingFindPanel else {
            return
        }

        if let parentWindow = panel.parent {
            parentWindow.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    /// Lazily creates the floating Find panel UI.
    private func ensureFloatingFindPanel() -> NSPanel {
        if let existingPanel = floatingFindPanel {
            return existingPanel
        }

        let panelSize = NSSize(width: 320, height: 110)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Search:")
        label.translatesAutoresizingMaskIntoConstraints = false

        let searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(submitFindFromSearchField(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = true
        searchField.searchMenuTemplate = makeFindModeMenu()
        floatingFindSearchField = searchField

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelFloatingFindPanel(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded

        let okButton = NSButton(title: "OK", target: self, action: #selector(confirmFloatingFindPanel(_:)))
        okButton.translatesAutoresizingMaskIntoConstraints = false
        okButton.keyEquivalent = "\r"
        okButton.bezelStyle = .rounded

        container.addSubview(label)
        container.addSubview(searchField)
        container.addSubview(cancelButton)
        container.addSubview(okButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),

            okButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            okButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            okButton.widthAnchor.constraint(equalToConstant: 70),

            cancelButton.trailingAnchor.constraint(equalTo: okButton.leadingAnchor, constant: -10),
            cancelButton.bottomAnchor.constraint(equalTo: okButton.bottomAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 70)
        ])

        panel.contentView = container
        floatingFindPanel = panel
        return panel
    }

    /// Dispatches one Find query update to this window's view layer.
    private func dispatchFindQueryUpdate(
        shouldBeepOnNoMatch: Bool,
        shouldRunSearch: Bool = true
    ) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerFindCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerFindCommandUserInfoKey.command.rawValue: QuickMarkdownViewerFindCommand.setFindQuery.rawValue,
                QuickMarkdownViewerFindCommandUserInfoKey.query.rawValue: currentFindQuery,
                QuickMarkdownViewerFindCommandUserInfoKey.shouldRunSearch.rawValue: shouldRunSearch,
                QuickMarkdownViewerFindCommandUserInfoKey.shouldBeepOnNoMatch.rawValue: shouldBeepOnNoMatch
            ]
        )
    }

    /// Dispatches one case-sensitivity update to this window's view layer.
    private func dispatchFindCaseSensitivityUpdate() {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerFindCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerFindCommandUserInfoKey.command.rawValue:
                    QuickMarkdownViewerFindCommand.setFindCaseSensitivity.rawValue,
                QuickMarkdownViewerFindCommandUserInfoKey.isCaseSensitive.rawValue: isFindCaseSensitive
            ]
        )
    }

    /// Returns true when Find query text is non-empty after trimming.
    private func hasNonEmptyFindQuery() -> Bool {
        !currentFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Handles Open toolbar action.
    @objc private func openDocumentFromToolbar(_ sender: Any?) {
        AppRouting.shared.openDocumentPanel()
    }

    /// Handles Zoom In toolbar action.
    @objc private func zoomInFromToolbar(_ sender: Any?) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerZoomCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerZoomCommandUserInfoKey.command.rawValue: QuickMarkdownViewerZoomCommand.zoomIn.rawValue
            ]
        )
    }

    /// Handles Zoom Out toolbar action.
    @objc private func zoomOutFromToolbar(_ sender: Any?) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerZoomCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerZoomCommandUserInfoKey.command.rawValue: QuickMarkdownViewerZoomCommand.zoomOut.rawValue
            ]
        )
    }

    /// Handles Actual Size toolbar action.
    @objc private func actualSizeFromToolbar(_ sender: Any?) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerZoomCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerZoomCommandUserInfoKey.command.rawValue:
                    QuickMarkdownViewerZoomCommand.resetToActualSize.rawValue
            ]
        )
    }

    /// Handles Zoom to Fit toolbar action.
    @objc private func zoomToFitFromToolbar(_ sender: Any?) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerZoomCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerZoomCommandUserInfoKey.command.rawValue: QuickMarkdownViewerZoomCommand.zoomToFit.rawValue
            ]
        )
    }

    /// Handles Print toolbar action.
    @objc private func printFromToolbar(_ sender: Any?) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerDocumentCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerDocumentCommandUserInfoKey.command.rawValue:
                    QuickMarkdownViewerDocumentCommand.printRenderedDocument.rawValue
            ]
        )
    }

    /// Handles Export PDF toolbar action.
    @objc private func exportPDFFromToolbar(_ sender: Any?) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerDocumentCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerDocumentCommandUserInfoKey.command.rawValue:
                    QuickMarkdownViewerDocumentCommand.exportRenderedPDF.rawValue
            ]
        )
    }

    /// Handles View Source toolbar action.
    @objc private func viewSourceFromToolbar(_ sender: Any?) {
        guard let hostWindow = window else {
            return
        }

        NotificationCenter.default.post(
            name: .quickMarkdownViewerDocumentCommand,
            object: hostWindow,
            userInfo: [
                QuickMarkdownViewerDocumentCommandUserInfoKey.command.rawValue:
                    QuickMarkdownViewerDocumentCommand.viewSourceExternally.rawValue
            ]
        )
    }

    /// Handles selecting light appearance from toolbar.
    @objc private func setLightAppearanceFromToolbar(_ sender: Any?) {
        AppRouting.shared.setLightAppearanceMode()
        refreshAppearanceSelection()
    }

    /// Handles selecting dark appearance from toolbar.
    @objc private func setDarkAppearanceFromToolbar(_ sender: Any?) {
        AppRouting.shared.setDarkAppearanceMode()
        refreshAppearanceSelection()
    }

    /// Handles legacy 3-button zoom group (out / actual / in).
    @objc private func handleZoomLegacyGroupSelection(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0:
            zoomOutFromToolbar(sender)
        case 1:
            actualSizeFromToolbar(sender)
        case 2:
            zoomInFromToolbar(sender)
        default:
            break
        }
    }

    /// Handles 2-button appearance group (light / dark).
    @objc private func handleAppearanceGroupSelection(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0:
            setLightAppearanceFromToolbar(sender)
        case 1:
            setDarkAppearanceFromToolbar(sender)
        default:
            break
        }
    }

    /// Handles grouped Print + Export action.
    @objc private func handlePrintExportGroupSelection(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0:
            printFromToolbar(sender)
        case 1:
            exportPDFFromToolbar(sender)
        default:
            break
        }
    }

    /// Handles 2-button zoom-out/in group.
    @objc private func handleZoomOutInGroupSelection(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0:
            zoomOutFromToolbar(sender)
        case 1:
            zoomInFromToolbar(sender)
        default:
            break
        }
    }

    /// Handles submitted Find from toolbar/panel fields.
    @objc private func submitFindFromSearchField(_ sender: NSSearchField) {
        // Toolbar field Enter is handled in doCommandBy( insertNewline: ) to
        // avoid re-introducing stale text during normal editing/clear actions.
        guard sender.window === floatingFindPanel else {
            return
        }

        currentFindQuery = sender.stringValue
        syncFindControlsFromState()
        dispatchFindQueryUpdate(shouldBeepOnNoMatch: hasNonEmptyFindQuery())
    }

    /// Handles toolbar Search item activation in text-only mode.
    ///
    /// In label-only display mode, macOS-style behaviour is to show a compact
    /// Find panel rather than switching the toolbar presentation mode.
    @objc private func handleSearchToolbarItemActivation(_ sender: Any?) {
        if shouldPresentFloatingFindPanelForCurrentToolbarMode() {
            showFloatingFindPanel()
            return
        }

        focusToolbarSearchField()
    }

    /// Handles Cancel button in floating Find panel.
    @objc private func cancelFloatingFindPanel(_ sender: Any?) {
        closeFloatingFindPanel()
    }

    /// Handles OK button in floating Find panel.
    @objc private func confirmFloatingFindPanel(_ sender: Any?) {
        if let searchField = floatingFindSearchField {
            currentFindQuery = searchField.stringValue
        }
        syncFindControlsFromState()
        dispatchFindQueryUpdate(shouldBeepOnNoMatch: hasNonEmptyFindQuery())
        closeFloatingFindPanel()
    }

    /// Handles selecting case-insensitive mode from search menu.
    @objc private func selectCaseInsensitiveFindMode(_ sender: NSMenuItem) {
        isFindCaseSensitive = false
        syncFindControlsFromState()
        dispatchFindCaseSensitivityUpdate()
        dispatchFindQueryUpdate(shouldBeepOnNoMatch: false)
    }

    /// Handles selecting case-sensitive mode from search menu.
    @objc private func selectCaseSensitiveFindMode(_ sender: NSMenuItem) {
        isFindCaseSensitive = true
        syncFindControlsFromState()
        dispatchFindCaseSensitivityUpdate()
        dispatchFindQueryUpdate(shouldBeepOnNoMatch: false)
    }

deinit {
        if let findStateObserver {
            NotificationCenter.default.removeObserver(findStateObserver)
        }
    }
}

extension DocumentWindowController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        syncFindMenuCheckmarks(for: menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        syncFindMenuCheckmarks(for: menu)
    }
}

extension DocumentWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectCaseInsensitiveFindMode(_:)) {
            menuItem.state = isFindCaseSensitive ? .off : .on
            return true
        }

        if menuItem.action == #selector(selectCaseSensitiveFindMode(_:)) {
            menuItem.state = isFindCaseSensitive ? .on : .off
            return true
        }

        return true
    }
}

extension DocumentWindowController: NSToolbarDelegate {
    private static let defaultToolbarItemIdentifiers: [NSToolbarItem.Identifier] = [
        ToolbarItemIdentifier.open,
        ToolbarItemIdentifier.zoomLegacy,
        ToolbarItemIdentifier.appearance,
        ToolbarItemIdentifier.printExportGroup,
        .flexibleSpace,
        ToolbarItemIdentifier.search
    ]

    private static let allowedToolbarItemIdentifiers: [NSToolbarItem.Identifier] = [
        ToolbarItemIdentifier.open,
        ToolbarItemIdentifier.zoomOutIn,
        ToolbarItemIdentifier.zoomLegacy,
        ToolbarItemIdentifier.zoomToFit,
        ToolbarItemIdentifier.actualSize,
        ToolbarItemIdentifier.appearance,
        ToolbarItemIdentifier.printExportGroup,
        ToolbarItemIdentifier.print,
        ToolbarItemIdentifier.exportPDF,
        ToolbarItemIdentifier.share,
        ToolbarItemIdentifier.viewSource,
        ToolbarItemIdentifier.search,
        .space,
        .flexibleSpace
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultToolbarItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedToolbarItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarItemIdentifier.open:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open"
            item.paletteLabel = "Open"
            item.toolTip = "Open a Markdown file"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open")
            item.target = self
            item.action = #selector(openDocumentFromToolbar(_:))
            return item

        case ToolbarItemIdentifier.zoomLegacy:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    toolbarSymbolImage("minus.magnifyingglass", fallbackAccessibilityLabel: "Zoom Out"),
                    toolbarSymbolImage("1.magnifyingglass", fallbackAccessibilityLabel: "Actual Size"),
                    toolbarSymbolImage("plus.magnifyingglass", fallbackAccessibilityLabel: "Zoom In")
                ],
                selectionMode: .momentary,
                labels: ["Zoom Out", "Actual Size", "Zoom In"],
                target: self,
                action: #selector(handleZoomLegacyGroupSelection(_:))
            )
            group.label = "Zoom"
            group.paletteLabel = "Zoom"
            group.toolTip = "Zoom controls"
            group.controlRepresentation = .expanded
            group.isEnabled = canUseDocumentControls
            if flag {
                zoomLegacyGroupItem = group
            }
            return group

        case ToolbarItemIdentifier.appearance:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    toolbarSymbolImage("sun.max", fallbackAccessibilityLabel: "Light Mode"),
                    toolbarSymbolImage("moon.fill", fallbackAccessibilityLabel: "Dark Mode")
                ],
                selectionMode: .momentary,
                labels: ["Light Mode", "Dark Mode"],
                target: self,
                action: #selector(handleAppearanceGroupSelection(_:))
            )
            group.label = "Appearance"
            group.paletteLabel = "Appearance"
            group.toolTip = "Appearance controls"
            group.controlRepresentation = .expanded
            if flag {
                appearanceGroupItem = group
            }
            refreshAppearanceSelection()
            return group

        case ToolbarItemIdentifier.printExportGroup:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    toolbarSymbolImage("printer", fallbackAccessibilityLabel: "Print"),
                    toolbarSymbolImage("square.and.arrow.up.on.square", fallbackAccessibilityLabel: "Export as PDF")
                ],
                selectionMode: .momentary,
                labels: ["Print", "Export as PDF"],
                target: self,
                action: #selector(handlePrintExportGroupSelection(_:))
            )
            group.label = "Print and Export"
            group.paletteLabel = "Print and Export"
            group.toolTip = "Print and export controls"
            group.controlRepresentation = .expanded
            group.isEnabled = canUseDocumentControls
            if flag {
                printExportGroupItem = group
            }
            return group

        case ToolbarItemIdentifier.search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search"
            item.toolTip = "Search the current document"
            item.isEnabled = canUseDocumentControls

            if toolbar.displayMode == .labelOnly {
                item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
                item.target = self
                item.action = #selector(handleSearchToolbarItemActivation(_:))

                if flag {
                    toolbarSearchField = nil
                    searchToolbarGenericItem = item
                }

                return item
            }

            let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 0))
            searchField.controlSize = .small
            searchField.delegate = self
            searchField.sendsSearchStringImmediately = true
            searchField.sendsWholeSearchString = true
            searchField.placeholderString = "Search"
            searchField.searchMenuTemplate = makeFindModeMenu()
            searchField.stringValue = currentFindQuery
            searchField.isEnabled = canUseDocumentControls

            item.view = searchField
            item.target = self
            item.action = #selector(handleSearchToolbarItemActivation(_:))

            if flag {
                toolbarSearchField = searchField
                searchToolbarGenericItem = item
            }

            syncFindControlsFromState()
            return item

        case ToolbarItemIdentifier.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Share"
            item.paletteLabel = "Share"
            item.toolTip = "Share the current Markdown file"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
            item.delegate = self
            item.isEnabled = canUseDocumentControls
            if flag {
                shareToolbarItem = item
            }
            return item

        case ToolbarItemIdentifier.viewSource:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "View Source"
            item.paletteLabel = "View Source"
            item.toolTip = "Open source in default text editor"
            item.image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "View Source")
            item.target = self
            item.action = #selector(viewSourceFromToolbar(_:))
            item.isEnabled = canUseDocumentControls
            if flag {
                viewSourceToolbarItem = item
            }
            return item

        case ToolbarItemIdentifier.zoomToFit:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Zoom to Fit"
            item.paletteLabel = "Zoom to Fit"
            item.toolTip = "Fit content to window width"
            item.image = NSImage(
                systemSymbolName: "arrow.up.left.and.down.right.magnifyingglass",
                accessibilityDescription: "Zoom to Fit"
            )
            item.target = self
            item.action = #selector(zoomToFitFromToolbar(_:))
            item.isEnabled = canUseDocumentControls
            if flag {
                zoomToFitToolbarItem = item
            }
            return item

        case ToolbarItemIdentifier.actualSize:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Actual Size"
            item.paletteLabel = "Actual Size"
            item.toolTip = "Reset zoom to 100%"
            item.image = NSImage(systemSymbolName: "1.magnifyingglass", accessibilityDescription: "Actual Size")
            item.target = self
            item.action = #selector(actualSizeFromToolbar(_:))
            item.isEnabled = canUseDocumentControls
            if flag {
                actualSizeToolbarItem = item
            }
            return item

        case ToolbarItemIdentifier.zoomOutIn:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    toolbarSymbolImage("minus.magnifyingglass", fallbackAccessibilityLabel: "Zoom Out"),
                    toolbarSymbolImage("plus.magnifyingglass", fallbackAccessibilityLabel: "Zoom In")
                ],
                selectionMode: .momentary,
                labels: ["Zoom Out", "Zoom In"],
                target: self,
                action: #selector(handleZoomOutInGroupSelection(_:))
            )
            group.label = "Zoom Out/In"
            group.paletteLabel = "Zoom Out/In"
            group.toolTip = "Zoom controls"
            group.controlRepresentation = .expanded
            group.isEnabled = canUseDocumentControls
            if flag {
                zoomOutInGroupItem = group
            }
            return group

        case ToolbarItemIdentifier.print:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Print"
            item.paletteLabel = "Print"
            item.toolTip = "Print rendered Markdown"
            item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "Print")
            item.target = self
            item.action = #selector(printFromToolbar(_:))
            item.isEnabled = canUseDocumentControls
            if flag {
                printToolbarItem = item
            }
            return item

        case ToolbarItemIdentifier.exportPDF:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Export as PDF"
            item.paletteLabel = "Export as PDF"
            item.toolTip = "Export rendered Markdown as PDF"
            item.image = NSImage(
                systemSymbolName: "square.and.arrow.up.on.square",
                accessibilityDescription: "Export as PDF"
            )
            item.target = self
            item.action = #selector(exportPDFFromToolbar(_:))
            item.isEnabled = canUseDocumentControls
            if flag {
                exportPDFToolbarItem = item
            }
            return item

        default:
            return nil
        }
    }
}

extension DocumentWindowController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let searchField = control as? NSSearchField else {
            return false
        }

        guard !isSyncingFindControls else {
            return false
        }

        // Keep floating-panel Enter behaviour unchanged (OK button path).
        guard searchField.window !== floatingFindPanel else {
            return false
        }

        currentFindQuery = searchField.stringValue
        syncFindControlsFromState()
        dispatchFindQueryUpdate(shouldBeepOnNoMatch: false, shouldRunSearch: false)

        if let hostWindow = window {
            NotificationCenter.default.post(
                name: .quickMarkdownViewerFindCommand,
                object: hostWindow,
                userInfo: [
                    QuickMarkdownViewerFindCommandUserInfoKey.command.rawValue:
                        QuickMarkdownViewerFindCommand.findNext.rawValue
                ]
            )
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let searchField = notification.object as? NSSearchField else {
            return
        }

        guard !isSyncingFindControls else {
            return
        }

        currentFindQuery = searchField.stringValue
        syncFindControlsFromState()
        dispatchFindQueryUpdate(shouldBeepOnNoMatch: false)
    }
}

extension DocumentWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for item: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let fileURL = documentState.document?.fileURL else {
            return []
        }

        return [fileURL]
    }
}
