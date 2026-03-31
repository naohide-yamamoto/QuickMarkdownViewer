import AppKit
import SwiftUI

/// Notification posted when the app-level Find commands should act on a window.
extension Notification.Name {
    static let quickMarkdownViewerFindCommand = Notification.Name("QuickMarkdownViewer.FindCommand")

    /// Notification posted when the app-level Zoom commands should act on a window.
    static let quickMarkdownViewerZoomCommand = Notification.Name("QuickMarkdownViewer.ZoomCommand")

    /// Notification posted when document actions should act on a window.
    static let quickMarkdownViewerDocumentCommand = Notification.Name("QuickMarkdownViewer.DocumentCommand")
}

/// Supported in-document Find actions for QuickMarkdownViewer windows.
///
/// These values are serialised into notification payloads so menu commands can
/// target the currently active document window without coupling AppCommands to
/// any specific SwiftUI view instance.
enum QuickMarkdownViewerFindCommand: String {
    /// Show/hide the find bar in the active document window.
    case toggleFindBar

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
}

/// Keys used in `quickMarkdownViewerFindCommand` notification payloads.
enum QuickMarkdownViewerFindCommandUserInfoKey: String {
    /// The `QuickMarkdownViewerFindCommand.rawValue` to execute.
    case command

    /// Integer `windowNumber` that should handle the command.
    case targetWindowNumber
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

        if let printItem = firstMenuItem(in: mainMenu) { item in
            item.keyEquivalent.lowercased() == "p" &&
            item.keyEquivalentModifierMask.contains(.command)
        } {
            printItem.target = self
            printItem.action = #selector(printDocument(_:))
        }

        if let exportItem = firstMenuItem(in: mainMenu) { item in
            item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("Export as PDF")
        } {
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

    /// Private init enforces the shared-router model.
    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Presents the standard file chooser for Markdown documents.
    func openDocumentPanel() {
        guard let urls = fileOpenService.selectMarkdownFiles() else { return }
        openFiles(urls)
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

    /// Toggles Find UI in the currently active window (`Cmd+F`).
    func toggleFindInActiveWindow() {
        dispatchFindCommandToActiveWindow(.toggleFindBar)
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
        dispatchFindCommandToActiveWindow(.hideFindBar)
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
            _ = window?.makeFirstResponder(nil)
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

        // Dismiss any visible empty launch windows before opening a real
        // document so the app behaves like Preview (document-first) rather
        // than leaving an empty placeholder window behind.
        closeInitialEmptyWindowsIfPresent()

        showDocumentWindow(for: standardisedFileURL)
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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

        // Keep launch behaviour aligned with Preview-style utilities:
        // no control (including the top search field) should be focused by
        // default when a new QuickMarkdownViewer window appears.
        DispatchQueue.main.async { [weak window] in
            _ = window?.makeFirstResponder(nil)
        }

        // Perform immediate load + render for fast perceived open time.
        documentState.load(
            fileURL: fileURL,
            fileOpenService: fileOpenService,
            renderService: renderService
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
    private func closeInitialEmptyWindowsIfPresent() {
        let emptyWindows = NSApp.windows.filter {
            $0.isVisible &&
            $0.styleMask.contains(.titled) &&
            $0.representedURL == nil &&
            $0.title == "Quick Markdown Viewer"
        }

        guard !emptyWindows.isEmpty else {
            return
        }

        // Close all matching placeholders in case launch timing ever produced
        // more than one empty window. This keeps resulting behaviour tidy.
        emptyWindows.forEach { $0.close() }
    }

    /// Routes a Find command to the currently active titled window.
    ///
    /// Using notifications keeps command handling decoupled from view-tree
    /// ownership while still targeting exactly one window.
    private func dispatchFindCommandToActiveWindow(_ command: QuickMarkdownViewerFindCommand) {
        guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow,
              targetWindow.styleMask.contains(.titled) else {
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
        guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow,
              targetWindow.styleMask.contains(.titled) else {
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
        guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow,
              targetWindow.styleMask.contains(.titled) else {
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
        guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow,
              targetWindow.styleMask.contains(.titled),
              let representedURL = targetWindow.representedURL else {
            return nil
        }

        return representedURL.standardizedFileURL
    }

    /// Returns whether the active titled window currently hosts a document URL.
    private var hasActiveDocumentWindowForCommands: Bool {
        guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow,
              targetWindow.styleMask.contains(.titled) else {
            return false
        }

        return targetWindow.representedURL != nil
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Notify router so it can release the closed window controller.
    func windowWillClose(_ notification: Notification) {
        onClose(id)
    }

    /// Refreshes content when the user re-activates a document window.
    ///
    /// This keeps QuickMarkdownViewer in sync with external edits while staying
    /// low risk: reload occurs only when on-disk file fingerprint changed.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let fileURL = window?.representedURL else {
            return
        }

        documentState.reloadIfFileChanged(
            fileURL: fileURL,
            fileOpenService: fileOpenService,
            renderService: renderService
        )
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
}
